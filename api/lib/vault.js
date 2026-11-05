// lib/vault.js: the only place the API talks to Vault.
//
// The token comes from vault-agent's sink and is read on EVERY call: when the
// agent re-authenticates, the next request simply uses the new token. There is
// no VAULT_TOKEN environment variable anywhere in this service. A signed-in
// person's request carries their own Vault token instead (lib/session.js).
//
// Every call goes to the ACTIVE node. Performance standbys answer some reads
// themselves, and the rotation manager runs only on the active node:
// sys/rotation/orphans on a standby says "rotation manager is not
// initialized" (prompt 05). The active node is found through sys/leader and
// cached for a few seconds; a failed request clears the cache.
//
// TLS: every node presents the lab listener certificate; NODE_EXTRA_CA_CERTS
// adds the lab CA to Node's trust store. Nothing disables verification.
import { AsyncLocalStorage } from "node:async_hooks";
import { readFileSync } from "node:fs";

export const VAULT_NODES = (
  process.env.VAULT_NODES ||
  "https://vault-1:8200,https://vault-2:8200,https://vault-3:8200"
)
  .split(",")
  .map((s) => s.trim().replace(/\/$/, ""))
  .filter(Boolean);
export const VAULT_SEAL_ADDR = (
  process.env.VAULT_SEAL_ADDR || "https://vault-s:8200"
).replace(/\/$/, "");
const TOKEN_FILE = process.env.VAULT_TOKEN_FILE || "/run/vault/token";
const ACTIVE_TTL_MS = 5_000;

export class VaultError extends Error {
  constructor(status, message, errors = []) {
    super(message);
    this.status = status;
    this.errors = errors;
  }
}

// Set by lib/session.js for a person's request: their Vault token. Without
// it the API's own agent token is used.
export const userContext = new AsyncLocalStorage();

export function readToken() {
  const person = userContext.getStore()?.token;
  if (person) return person;
  let token = "";
  try {
    token = readFileSync(TOKEN_FILE, "utf8").trim();
  } catch (e) {
    throw new VaultError(
      503,
      `Vault Agent token sink not readable (${TOKEN_FILE}): ${e.code || e.message}`,
    );
  }
  if (!token)
    throw new VaultError(
      503,
      `Vault Agent token sink is empty (${TOKEN_FILE}): is vault-agent healthy?`,
    );
  return token;
}

export function tokenPresent() {
  try {
    return readFileSync(TOKEN_FILE, "utf8").trim().length > 0;
  } catch {
    return false;
  }
}

// fetch with a timeout that always fires: a referenced setTimeout aborts the
// request (AbortSignal.timeout was seen to never fire on a hung connection).
// The deadline covers the whole exchange, body included.
async function fetchWithTimeout(url, opts, timeoutMs, read) {
  const ac = new AbortController();
  const t = setTimeout(
    () => ac.abort(new Error(`timed out after ${timeoutMs} ms`)),
    timeoutMs,
  );
  try {
    const res = await fetch(url, { ...opts, signal: ac.signal });
    return { res, body: await read(res) };
  } catch (e) {
    if (ac.signal.aborted)
      throw new VaultError(
        504,
        `Vault ${opts.method} ${url.replace(/^.*\/v1\//, "")}: ${ac.signal.reason?.message || "timed out"}`,
      );
    throw e;
  } finally {
    clearTimeout(t);
  }
}

// ── The active node ──────────────────────────────────────────────────────────
let active = { addr: null, at: 0 };

export async function activeAddr() {
  if (active.addr && Date.now() - active.at < ACTIVE_TTL_MS) return active.addr;
  for (const addr of VAULT_NODES) {
    try {
      const { body } = await fetchWithTimeout(
        `${addr}/v1/sys/leader`,
        { method: "GET" },
        3_000,
        (r) => r.json(),
      );
      if (body?.is_self) {
        active = { addr, at: Date.now() };
        return addr;
      }
    } catch {
      // try the next node
    }
  }
  active = { addr: null, at: 0 };
  throw new VaultError(503, "no active Vault node among vault-1..3");
}

export function forgetActive() {
  active = { addr: null, at: 0 };
}

// vault(method, path, { body, auth=true, addr, headers, timeoutMs })
//   path is relative to /v1/. Returns parsed JSON (null for 204). Vault's own
//   error text is kept verbatim in the thrown VaultError.
export async function vault(
  method,
  path,
  { body, auth = true, addr, headers = {}, timeoutMs = 15_000 } = {},
) {
  const h = { ...headers };
  if (auth) h["X-Vault-Token"] = readToken();
  if (body !== undefined) h["content-type"] = "application/json";
  const target = addr || (await activeAddr());
  let res, buf;
  try {
    ({ res, body: buf } = await fetchWithTimeout(
      `${target}/v1/${path}`,
      {
        method,
        headers: h,
        body: body === undefined ? undefined : JSON.stringify(body),
      },
      timeoutMs,
      async (r) => Buffer.from(await r.arrayBuffer()),
    ));
  } catch (e) {
    if (!addr) forgetActive();
    if (e instanceof VaultError) throw e;
    throw new VaultError(
      503,
      `Vault ${method} ${path}: ${e?.cause?.code || e.message}`,
    );
  }
  const text = buf.toString("utf8");
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  if (!res.ok) {
    if (!addr && (res.status === 503 || res.status === 500)) forgetActive();
    const errors = (json?.errors || []).map((e) =>
      String(e).replace(/\s+/g, " ").trim(),
    );
    const detail = errors.length
      ? errors.join("; ")
      : text.trim() || res.statusText;
    throw new VaultError(
      res.status,
      `Vault ${method} ${path}: ${res.status} ${detail}`,
      errors,
    );
  }
  return json;
}

// LIST that answers [] for an empty path (Vault answers 404).
export async function list(path) {
  try {
    const j = await vault("LIST", path);
    return j?.data?.keys || [];
  } catch (e) {
    if (e instanceof VaultError && e.status === 404) return [];
    throw e;
  }
}

// Unauthenticated sys/health of one node, shaped for the overview.
export async function nodeHealth(addr) {
  try {
    const { body: j } = await fetchWithTimeout(
      `${addr}/v1/sys/health?standbyok=true&perfstandbyok=true&sealedcode=200&uninitcode=200`,
      { method: "GET" },
      4_000,
      (r) => r.json(),
    );
    return {
      reachable: true,
      initialized: Boolean(j.initialized),
      sealed: Boolean(j.sealed),
      standby: Boolean(j.standby),
      performanceStandby: Boolean(j.performance_standby),
      version: j.version || null,
      clusterName: j.cluster_name || null,
      serverTime: j.server_time_utc || null,
    };
  } catch (e) {
    return {
      reachable: false,
      error: String(e?.cause?.code || e?.message || e),
    };
  }
}
