// dance-api: the vault_dance API. Plain node:http; two dependencies (ssh2,
// ldapts) for the proofs, see README.md.
//
//   GET  /api/health                         nodes, agent token, Vault logs readable
//   GET  /api/cluster                        vault-s + vault-1..3, leader, Raft voters, licence
//   GET  /api/credentials                    all ten, as Vault describes them, + last proof
//   GET  /api/credential?id=                 one, with versions (OS) or health check (LDAP)
//   POST /api/credential/proof?id=           log in with Vault's current password (API identity)
//   POST /api/credential/rotate?id=          person: rotate now
//   POST /api/credential/reregister?id=      person: write the stored config again (clears an orphan)
//   POST /api/credential/checkout?id=        person: read the password (rotate-on-read rotates), prove it
//   POST /api/credential/health-check?id=    person: LDAP health check, live
//   POST /api/credential/unlock?id=          person: LDAP unlock (Vault refuses on OpenLDAP)
//   GET  /api/policies                       rotation policies and who uses them
//   GET  /api/orphans                        sys/rotation/orphans, verbatim
//   GET  /api/timeline?id=&kind=&limit=      what the watcher saw, newest first
//   GET  /auth/login | /auth/callback | /auth/logout   sign-in (Keycloak, PKCE)
//   GET  /api/me                             the person, groups, policies, what Vault allows
//
// Reads and proofs use the API's own token (vault-agent). Person routes run on
// the signed-in person's Vault token: Vault decides, and its error text is
// returned verbatim. No route ever returns a password.
import http from "node:http";
import {
  vault,
  VaultError,
  VAULT_NODES,
  VAULT_SEAL_ADDR,
  nodeHealth,
  tokenPresent,
  activeAddr,
} from "./lib/vault.js";
import * as creds from "./lib/credentials.js";
import * as watch from "./lib/watch.js";
import { ProofRefused, fingerprint } from "./lib/proof.js";
import { logsAvailable } from "./lib/vaultlog.js";
import * as session from "./lib/session.js";

const PORT = Number(process.env.PORT || 3000);
const MAX_BODY = 16 * 1024;

export class BadRequest extends Error {}

function send(res, code, obj) {
  res.writeHead(code, {
    "content-type": "application/json",
    "cache-control": "no-store",
  });
  res.end(JSON.stringify(obj));
}

async function drain(req) {
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > MAX_BODY) throw new BadRequest("request body too large");
  }
}

// ?id= must name one of the ten credentials, exactly.
export function credentialParam(url) {
  const id = url.searchParams.get("id") || "";
  if (!/^[a-z0-9-]+\/[a-z0-9-]+$/.test(id))
    throw new BadRequest("id: a credential id such as host-rocky/app-deploy or ldap/svc-billing");
  try {
    return creds.byId(id);
  } catch (e) {
    if (e instanceof creds.NotFound) throw new BadRequest(e.message);
    throw e;
  }
}

// ── Handlers ─────────────────────────────────────────────────────────────────
async function health() {
  const nodes = await Promise.all(VAULT_NODES.map(nodeHealth));
  const agentToken = tokenPresent();
  const usable = nodes.some((n) => n.reachable && !n.sealed);
  return {
    ok: usable && agentToken,
    nodes: VAULT_NODES.map((addr, i) => ({ addr, ...nodes[i] })),
    agent: { tokenPresent: agentToken },
    vaultLogs: logsAvailable(),
    watch: { lastTick: watch.current().at },
    vaultUi: `${(process.env.VAULT_UI_URL || "https://localhost:18901").replace(/\/$/, "")}/ui/`,
  };
}

async function cluster() {
  const [seal, ...nodes] = await Promise.all([
    nodeHealth(VAULT_SEAL_ADDR),
    ...VAULT_NODES.map(nodeHealth),
  ]);
  let leader = null;
  try {
    leader = await activeAddr();
  } catch {
    leader = null;
  }
  const raft = await vault("GET", "sys/storage/raft/configuration").catch((e) => ({ error: e.message }));
  const license = await vault("GET", "sys/license/status").catch((e) => ({ error: e.message }));
  const lic = license?.data?.autoloaded || null;
  return {
    seal: { addr: VAULT_SEAL_ADDR, ...seal },
    nodes: VAULT_NODES.map((addr, i) => ({
      addr,
      name: addr.replace(/^https:\/\/([^:]+):.*/, "$1"),
      active: addr === leader,
      ...nodes[i],
    })),
    raft: raft?.data?.config?.servers || null,
    raftError: raft?.error || null,
    license: lic
      ? {
          expirationTime: lic.expiration_time,
          features: lic.features,
          needs: {
            "OS secrets engine": "Vault Enterprise 2.0+ (plugin vault-plugin-secrets-os +ent)",
            "LDAP static roles, self-managed": "OpenLDAP Secrets Engine",
            "Rotation policies, orphans": "Vault Enterprise",
          },
        }
      : { error: license?.error || "not readable" },
  };
}

function withProofs(list) {
  return list.map((c) => ({ ...c, proof: watch.proofs.get(c.id) || null }));
}

async function credentials() {
  const s = watch.current().at ? watch.current() : { ...(await creds.describeAll()), at: new Date().toISOString() };
  return { at: s.at, orphans: s.orphans, credentials: withProofs(s.credentials) };
}

async function credential(_req, url) {
  const c = credentialParam(url);
  const listed = await creds.orphans();
  const d = await creds.describe(c, listed);
  return {
    credential: { ...d, proof: watch.proofs.get(c.id) || null },
    versions: await creds.versions(c),
    timeline: watch.timeline({ id: c.id, limit: 50 }),
  };
}

async function proof(req, url) {
  await drain(req);
  const c = credentialParam(url);
  return { proof: await watch.proveAndRecord(c) };
}

// Person actions. Each is recorded on the timeline with who did it.
const personAction = (name, fn) => async (req, url) => {
  await drain(req);
  const c = credentialParam(url);
  return session.asPerson(req, async () => {
    const who = (await session.person(req))?.user || "?";
    try {
      const r = await fn(c, req);
      watch.record({ kind: name, id: c.id, by: who, detail: "accepted by Vault" });
      return r;
    } catch (e) {
      watch.record({ kind: name, id: c.id, by: who, result: "refused", detail: e.message });
      throw e;
    }
  });
};

const checkout = async (c) => {
  // The person's token reads the secret: for svc-reports that rotates it
  // (outside the cooldown). The API proves what was read and returns only the
  // fingerprint.
  const data = (await vault("GET", creds.secretPath(c)))?.data;
  const p = await watch.proveAndRecord(c, { secret: data });
  return {
    checkout: {
      fingerprint: fingerprint(data?.password || ""),
      rotatedOnRead: data?.rotated_on_read ?? null,
      version: data?.version ?? data?.password_version ?? null,
      lastRotation: data?.last_vault_rotation || null,
    },
    proof: p,
  };
};

const PLATFORM = new Set([
  "GET /api/health",
  "GET /api/cluster",
  "GET /api/credentials",
  "GET /api/credential",
  "POST /api/credential/proof",
  "GET /api/policies",
  "GET /api/orphans",
  "GET /api/timeline",
  "GET /api/me",
]);

const routes = {
  "GET /api/health": health,
  "GET /api/cluster": cluster,
  "GET /api/credentials": credentials,
  "GET /api/credential": credential,
  "POST /api/credential/proof": proof,
  "GET /api/policies": async () => ({ policies: await creds.rotationPolicies() }),
  "GET /api/orphans": async () => {
    const r = await vault("GET", "sys/rotation/orphans");
    return { orphans: r?.data?.orphans || [], vault: r?.data || null };
  },
  "GET /api/timeline": (_req, url) => ({
    events: watch.timeline({
      id: url.searchParams.get("id") || undefined,
      kind: url.searchParams.get("kind") || undefined,
      limit: url.searchParams.get("limit") || 200,
    }),
  }),
  "GET /api/me": (req) => session.me(req),
  "POST /api/credential/rotate": personAction("rotate", (c) => creds.rotate(c)),
  "POST /api/credential/reregister": personAction("reregister", (c) => creds.reregister(c)),
  "POST /api/credential/checkout": personAction("checkout", checkout),
  "POST /api/credential/health-check": personAction("health-check", (c) => creds.healthCheck(c)),
  "POST /api/credential/unlock": personAction("unlock", (c) => creds.unlock(c)),
};

function redirect(res, location, cookie) {
  const h = { location, "cache-control": "no-store" };
  if (cookie) h["set-cookie"] = cookie;
  res.writeHead(302, h);
  res.end();
}

async function authRoute(req, res, url) {
  try {
    if (url.pathname === "/auth/login") return redirect(res, session.login(url));
    if (url.pathname === "/auth/callback") {
      const { sid, returnTo } = await session.callback(url);
      return redirect(res, `${session.CONSOLE_URL}${returnTo}`, session.sessionCookie(sid, 8 * 3600));
    }
    if (url.pathname === "/auth/logout")
      return redirect(res, await session.logout(req), session.sessionCookie("", 0));
  } catch (e) {
    console.error(`[dance-api] ${url.pathname}: ${e.message}`);
    return redirect(res, `${session.CONSOLE_URL}/#/overview?signin=failed`);
  }
  return send(res, 404, { ok: false, error: "not found" });
}

export const server = http.createServer(async (req, res) => {
  res.setHeader("x-content-type-options", "nosniff");
  const url = new URL(req.url, "http://api");
  if (req.method === "GET" && url.pathname.startsWith("/auth/")) return authRoute(req, res, url);
  try {
    const key = `${req.method} ${url.pathname}`;
    const handler = routes[key];
    if (!handler) {
      const known = Object.keys(routes).some((k) => k.endsWith(` ${url.pathname}`));
      return send(res, known ? 405 : 404, {
        ok: false,
        error: known ? "method not allowed" : "not found",
      });
    }
    const out = PLATFORM.has(key) ? await handler(req, url) : await handler(req, url);
    return send(res, url.pathname === "/api/health" && !out.ok ? 503 : 200, { ok: true, ...out });
  } catch (e) {
    if (e instanceof BadRequest) return send(res, 400, { ok: false, error: e.message, status: 400 });
    if (e instanceof ProofRefused) return send(res, 409, { ok: false, error: e.message, status: 409 });
    if (e instanceof creds.NotFound) return send(res, 404, { ok: false, error: e.message, status: 404 });
    if (e instanceof session.Unauthenticated)
      return send(res, 401, { ok: false, error: e.message, status: 401, signIn: "/auth/login" });
    if (e instanceof VaultError) {
      const code = e.status >= 500 ? 502 : e.status;
      return send(res, code, { ok: false, error: e.message, status: e.status, vault: e.errors });
    }
    console.error(`[dance-api] ${req.method} ${url.pathname}:`, e);
    return send(res, 500, { ok: false, error: String(e?.message || e), status: 500 });
  }
});

if (process.env.NODE_ENV !== "test") {
  watch.start();
  server.listen(PORT, () => console.log(`[dance-api] listening on :${PORT}, Vault ${VAULT_NODES.join(" ")}`));
}
