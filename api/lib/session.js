// lib/session.js: sign-in for the console (the API is its BFF), and the
// person's own Vault token for every action. From vault_crypto and Project Durin.
//
//   /auth/login     Authorization Code + PKCE (S256) with the confidential
//                   Keycloak client dance-console
//   /auth/callback  code exchange server-to-server; tokens stay here, the
//                   browser holds only an opaque httpOnly cookie (dance_sid)
//   per request     the person's Keycloak access token → Vault auth/jwt/login
//                   (role console). Vault verifies signature, issuer and
//                   audience and attaches policies from the person's groups.
//
// Scripted callers (api-test, verify) may send `Authorization: Bearer <access
// token>` instead of a cookie; Vault validates it the same way.
import { createHash, randomBytes } from "node:crypto";
import { vault, VaultError, userContext } from "./vault.js";

const KC_PUBLIC = (
  process.env.KEYCLOAK_PUBLIC_URL || "http://localhost:13602"
).replace(/\/$/, "");
const KC_INTERNAL = (
  process.env.KEYCLOAK_INTERNAL_URL || "http://keycloak:8080"
).replace(/\/$/, "");
const REALM = process.env.KEYCLOAK_REALM || "dance";
const CLIENT_ID = process.env.OIDC_CLIENT_ID || "dance-console";
export const CONSOLE_URL = (
  process.env.CONSOLE_URL || "https://localhost:13601"
).replace(/\/$/, "");
const REDIRECT_URI = `${CONSOLE_URL}/auth/callback`;
const COOKIE = "dance_sid";
const SESSION_IDLE_MS = 60 * 60 * 1000;
const PENDING_MS = 10 * 60 * 1000;

export class Unauthenticated extends Error {}

// ── helpers (exported for unit tests) ────────────────────────────────────────
export const b64url = (buf) => Buffer.from(buf).toString("base64url");
export const randomToken = (bytes = 32) => b64url(randomBytes(bytes));
export const pkceChallenge = (verifier) =>
  b64url(createHash("sha256").update(verifier).digest());

export function decodeJwt(token) {
  const part = String(token || "").split(".")[1];
  if (!part) throw new Error("not a JWT");
  return JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
}

export function parseCookies(header) {
  const out = {};
  for (const part of String(header || "").split(";")) {
    const i = part.indexOf("=");
    if (i < 1) continue;
    const k = part.slice(0, i).trim();
    if (!(k in out)) out[k] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

export function sessionCookie(id, maxAgeSeconds) {
  return `${COOKIE}=${id}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAgeSeconds}`;
}

// Only a same-origin, hash-route return path survives the round trip.
export function safeReturn(v) {
  const s = String(v || "/");
  return /^\/(#\/[a-z]+)?$/.test(s) ? s : "/";
}

// ── state ────────────────────────────────────────────────────────────────────
const pending = new Map(); // state → { verifier, nonce, returnTo, at }
const sessions = new Map(); // sid → session
const bearerCache = new Map(); // sha256(access token) → { vault, exp }
const BEARER_CACHE_MAX = 256;
// In-flight Vault logins/refreshes, so concurrent requests from the SAME
// credential share one (prompt 09). Keyed by session id or token hash, never
// by username or groups: two people never share an entry.
const inflight = new Map();
export function once(key, fn) {
  if (inflight.has(key)) return inflight.get(key);
  const p = Promise.resolve()
    .then(fn)
    .finally(() => inflight.delete(key));
  inflight.set(key, p);
  return p;
}

function sweep() {
  const now = Date.now();
  for (const [k, v] of pending) if (now - v.at > PENDING_MS) pending.delete(k);
  for (const [k, v] of sessions)
    if (now - v.seen > SESSION_IDLE_MS) sessions.delete(k);
  for (const [k, v] of bearerCache)
    if (v.exp * 1000 < now) bearerCache.delete(k);
}
setInterval(sweep, 60_000).unref();

// The client secret is read from Vault KV with the API's own (agent) token,
// outside any person's context.
let clientSecret = null;
async function secret() {
  if (clientSecret) return clientSecret;
  const r = await userContext.exit(() =>
    vault("GET", "kv/data/dance/identity/console-client-secret"),
  );
  clientSecret = r?.data?.data?.value;
  if (!clientSecret)
    throw new VaultError(
      503,
      "console client secret missing in kv/dance/identity",
    );
  return clientSecret;
}

async function tokenEndpoint(params) {
  const body = new URLSearchParams(params);
  const auth = Buffer.from(`${CLIENT_ID}:${await secret()}`).toString("base64");
  const ac = new AbortController();
  const t = setTimeout(
    () => ac.abort(new Error("Keycloak token endpoint timed out")),
    10_000,
  );
  try {
    const r = await fetch(
      `${KC_INTERNAL}/realms/${REALM}/protocol/openid-connect/token`,
      {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          authorization: `Basic ${auth}`,
        },
        body,
        signal: ac.signal,
      },
    );
    const j = await r.json().catch(() => ({}));
    if (!r.ok)
      throw new Unauthenticated(
        `Keycloak refused: ${j.error_description || j.error || r.status}`,
      );
    return j;
  } finally {
    clearTimeout(t);
  }
}

// Keycloak access token → a Vault token issued to the person.
async function vaultLogin(accessToken) {
  const r = await vault("POST", "auth/jwt/login", {
    auth: false,
    body: { role: "console", jwt: accessToken },
  });
  const a = r.auth;
  return {
    token: a.client_token,
    accessor: a.accessor,
    policies: [
      ...new Set([...(a.identity_policies || []), ...(a.token_policies || [])]),
    ]
      .filter((p) => p !== "default")
      .sort(),
    exp: Math.floor(Date.now() / 1000) + a.lease_duration,
    entityId: a.entity_id,
  };
}

// ── routes ───────────────────────────────────────────────────────────────────
export function login(url) {
  const state = randomToken(24);
  const verifier = randomToken(48);
  const nonce = randomToken(16);
  pending.set(state, {
    verifier,
    nonce,
    returnTo: safeReturn(url.searchParams.get("return")),
    at: Date.now(),
  });
  const q = new URLSearchParams({
    client_id: CLIENT_ID,
    response_type: "code",
    scope: "openid profile email",
    redirect_uri: REDIRECT_URI,
    state,
    nonce,
    code_challenge: pkceChallenge(verifier),
    code_challenge_method: "S256",
  });
  return `${KC_PUBLIC}/realms/${REALM}/protocol/openid-connect/auth?${q}`;
}

export async function callback(url) {
  const state = url.searchParams.get("state");
  const p = state && pending.get(state);
  pending.delete(state);
  if (!p)
    throw new Unauthenticated(
      "sign-in expired or was not started here; try again",
    );
  if (url.searchParams.get("error"))
    throw new Unauthenticated(
      `Keycloak: ${url.searchParams.get("error_description") || url.searchParams.get("error")}`,
    );
  const tokens = await tokenEndpoint({
    grant_type: "authorization_code",
    code: url.searchParams.get("code") || "",
    redirect_uri: REDIRECT_URI,
    code_verifier: p.verifier,
  });
  const idc = decodeJwt(tokens.id_token);
  if (idc.nonce !== p.nonce) throw new Unauthenticated("nonce mismatch");
  const s = newSession(tokens);
  s.vault = await vaultLogin(tokens.access_token);
  return { sid: s.id, returnTo: p.returnTo };
}

function newSession(tokens) {
  const c = decodeJwt(tokens.access_token);
  const s = {
    id: randomToken(32),
    user: c.preferred_username,
    name: c.name || c.preferred_username,
    groups: [...(c.groups || [])].sort(),
    accessToken: tokens.access_token,
    accessExp: c.exp,
    refreshToken: tokens.refresh_token,
    idToken: tokens.id_token,
    vault: null,
    seen: Date.now(),
  };
  sessions.set(s.id, s);
  return s;
}

export async function logout(req) {
  const sid = parseCookies(req.headers.cookie)[COOKIE];
  const s = sid && sessions.get(sid);
  sessions.delete(sid);
  if (s?.vault?.token)
    await vault("POST", "auth/token/revoke-self", {
      auth: false,
      headers: { "X-Vault-Token": s.vault.token },
    }).catch(() => {});
  const q = new URLSearchParams({
    client_id: CLIENT_ID,
    post_logout_redirect_uri: `${CONSOLE_URL}/`,
  });
  if (s?.idToken) q.set("id_token_hint", s.idToken);
  return `${KC_PUBLIC}/realms/${REALM}/protocol/openid-connect/logout?${q}`;
}

// What a person may do, asked of Vault (sys/capabilities-self on the paths
// behind each console action), the capability the action needs, and the
// directory group that grants it. One representative path per action: the
// policies grant the same capability on every credential of that kind.
export const ACTIONS = {
  view: { path: "sys/rotation/orphans", cap: "read", group: "dance-viewers" },
  "os.rotate": {
    path: "os/hosts/host-rocky/accounts/app-deploy/rotate",
    cap: "update",
    group: "dance-operators",
  },
  "os.reregister": {
    path: "os/hosts/host-rocky/accounts/app-deploy",
    cap: "update",
    group: "dance-operators",
  },
  "os.checkout": {
    path: "os/hosts/host-rocky/accounts/ops-breakglass/creds",
    cap: "read",
    group: "dance-operators",
  },
  "ldap.rotate": {
    path: "ldap/rotate-role/svc-billing",
    cap: "update",
    group: "dance-operators",
  },
  "ldap.reregister": {
    path: "ldap/static-role/svc-billing",
    cap: "update",
    group: "dance-operators",
  },
  "ldap.checkout": {
    path: "ldap/static-cred/svc-reports",
    cap: "read",
    group: "dance-operators",
  },
  "ldap.healthcheck": {
    path: "ldap/static-role/svc-billing/health-check/exec",
    cap: "create",
    group: "dance-operators",
  },
  "ldap.unlock": {
    path: "ldap/static-role/svc-billing/unlock",
    cap: "update",
    group: "dance-operators",
  },
  "policy.edit": {
    path: "sys/policies/rotation/quick-step",
    cap: "update",
    group: "dance-admins",
  },
};

// capabilities-self answer (paths → capability lists) → action → allowed.
export function capabilityMap(answer) {
  const out = {};
  for (const [action, { path, cap, group }] of Object.entries(ACTIONS)) {
    const caps = answer?.[path] || [];
    out[action] = {
      allowed: caps.includes(cap) || caps.includes("root"),
      capabilities: caps,
      path,
      cap,
      group,
    };
  }
  return out;
}

export async function me(req) {
  const p = await person(req);
  if (!p) return { signedIn: false, signIn: "/auth/login" };
  const r = await userContext.run({ token: p.vault.token }, () =>
    vault("POST", "sys/capabilities-self", {
      body: { paths: Object.values(ACTIONS).map((a) => a.path) },
    }),
  );
  return {
    signedIn: true,
    user: p.user,
    name: p.name,
    groups: p.groups,
    policies: p.vault.policies,
    vaultTokenExpires: new Date(p.vault.exp * 1000).toISOString(),
    via: p.via,
    actions: capabilityMap(r.data || r),
  };
}

// The person behind a request, with a valid Vault token, or null.
export async function person(req) {
  const now = Math.floor(Date.now() / 1000);
  const bearer = /^Bearer (.+)$/.exec(req.headers.authorization || "")?.[1];
  if (bearer) {
    const key = createHash("sha256").update(bearer).digest("hex");
    let hit = bearerCache.get(key);
    if (!hit || hit.vault.exp - 60 < now) {
      hit = await once(`bearer:${key}`, async () => {
        const c = decodeJwt(bearer);
        const fresh = {
          vault: await vaultLogin(bearer),
          exp: c.exp,
          user: c.preferred_username,
          name: c.name || c.preferred_username,
          groups: [...(c.groups || [])].sort(),
        };
        bearerCache.delete(key);
        bearerCache.set(key, fresh);
        while (bearerCache.size > BEARER_CACHE_MAX)
          bearerCache.delete(bearerCache.keys().next().value);
        return fresh;
      });
    }
    return {
      user: hit.user,
      name: hit.name,
      groups: hit.groups,
      vault: hit.vault,
      via: "bearer",
    };
  }
  const sid = parseCookies(req.headers.cookie)[COOKIE];
  const s = sid && sessions.get(sid);
  if (!s) return null;
  s.seen = Date.now();
  if (!s.vault || s.vault.exp - 60 < now) {
    const ok = await once(`session:${s.id}`, async () => {
      if (s.accessExp - 30 < Math.floor(Date.now() / 1000)) {
        try {
          const t = await tokenEndpoint({
            grant_type: "refresh_token",
            refresh_token: s.refreshToken,
          });
          const c = decodeJwt(t.access_token);
          Object.assign(s, {
            accessToken: t.access_token,
            accessExp: c.exp,
            refreshToken: t.refresh_token || s.refreshToken,
            idToken: t.id_token || s.idToken,
            groups: [...(c.groups || [])].sort(),
          });
        } catch {
          sessions.delete(s.id);
          return false;
        }
      }
      s.vault = await vaultLogin(s.accessToken);
      return true;
    });
    if (!ok || !sessions.has(s.id)) return null;
  }
  return {
    user: s.user,
    name: s.name,
    groups: s.groups,
    vault: s.vault,
    via: "session",
  };
}

// Run fn with the person's Vault token as the token every vault() call uses.
export async function asPerson(req, fn) {
  const p = await person(req);
  if (!p) throw new Unauthenticated("sign in to act on a credential");
  return userContext.run({ token: p.vault.token, person: p }, fn);
}

export { COOKIE };
