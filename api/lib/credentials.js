// lib/credentials.js: the ten credentials, as Vault describes them.
//
// The list comes from config/credentials.json (the same file make onboard
// reads). Everything else comes from Vault: configuration, last and next
// rotation, version, rotation policy, orphan record, health-check result.
//
// STATE is derived from Vault's own fields, because 2.2.1 keeps an orphan
// record in sys/rotation/orphans after a credential was re-registered and
// rotates again (prompt 05):
//   ok          next rotation in the future
//   overdue     next rotation in the past, not listed: Vault is retrying
//   orphaned    next rotation in the past and listed in sys/rotation/orphans
//   recovered   listed, but rotating on time again (stale orphan record)
//   on-read     rotate-on-read only, no schedule
//   missing     not onboarded (make onboard)
import { readFileSync } from "node:fs";
import { vault, VaultError } from "./vault.js";
import { vaultFanout } from "./limit.js";

const FILE = process.env.CREDENTIALS_FILE || "/app/config/credentials.json";
const GRACE_S = 15; // a due rotation can take a few seconds to run

export class NotFound extends Error {}

let catalogue = null;
export function all() {
  if (!catalogue) {
    catalogue = JSON.parse(readFileSync(FILE, "utf8")).credentials;
  }
  return catalogue;
}

export function byId(id) {
  const c = all().find((x) => x.id === id);
  if (!c) throw new NotFound(`unknown credential: ${String(id).slice(0, 80)}`);
  return c;
}

const BASE_DN = "dc=dance,dc=lab";
export const dnOf = (c) => `cn=${c.account},ou=service-accounts,${BASE_DN}`;

export function configPath(c) {
  return c.engine === "os"
    ? `${c.mount}/hosts/${c.host}/accounts/${c.account}`
    : `${c.mount}/static-role/${c.account}`;
}

export function secretPath(c) {
  return c.engine === "os"
    ? `${configPath(c)}/creds`
    : `${c.mount}/static-cred/${c.account}`;
}

export function rotatePath(c) {
  return c.engine === "os"
    ? `${configPath(c)}/rotate`
    : `${c.mount}/rotate-role/${c.account}`;
}

// The id Vault's rotation manager uses (and lists in sys/rotation/orphans).
export const rotationId = (c) => configPath(c);

const seconds = (iso) => {
  if (!iso || iso.startsWith("0001-")) return null;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? null : Math.floor(t / 1000);
};

// Pure: Vault's config + whether the orphan list names it → a state.
export function deriveState(cfg, listed, nowS = Math.floor(Date.now() / 1000)) {
  if (!cfg) return "missing";
  const scheduled =
    (cfg.rotation_schedule || "") !== "" || Number(cfg.rotation_period) > 0;
  if (!scheduled) return cfg.rotate_on_read ? "on-read" : "manual";
  const next = seconds(cfg.next_vault_rotation);
  const onTime = next !== null && next > nowS - GRACE_S;
  if (onTime) return listed ? "recovered" : "ok";
  return listed ? "orphaned" : "overdue";
}

export function schedule(cfg) {
  if (!cfg) return null;
  if (cfg.rotation_schedule)
    return { kind: "schedule", cron: cfg.rotation_schedule, window: cfg.rotation_window || 0 };
  if (Number(cfg.rotation_period) > 0)
    return { kind: "period", seconds: Number(cfg.rotation_period) };
  if (cfg.rotate_on_read)
    return { kind: "on-read", cooldown: Number(cfg.rotate_on_read_cooldown) || 0 };
  return { kind: "manual" };
}

export async function orphans() {
  const r = await vault("GET", "sys/rotation/orphans");
  return r?.data?.orphans || [];
}

async function readOrNull(path) {
  try {
    return (await vault("GET", path))?.data || null;
  } catch (e) {
    if (e instanceof VaultError && e.status === 404) return null;
    throw e;
  }
}

// One credential, described. `listed` is the orphan list (fetched once).
export async function describe(c, listed) {
  const cfg = await vaultFanout.run(() => readOrNull(configPath(c)));
  const isListed = listed.includes(rotationId(c));
  const out = {
    id: c.id,
    engine: c.engine,
    mount: c.mount,
    host: c.host || null,
    account: c.account,
    dn: c.engine === "ldap" ? dnOf(c) : null,
    mode: c.mode,
    parent: c.parent || cfg?.parent_account_ref || null,
    scenario: c.scenario || null,
    rotationPolicy: cfg ? cfg.rotation_policy || "default" : null,
    schedule: schedule(cfg),
    lastRotation: cfg?.last_vault_rotation || null,
    nextRotation: cfg?.next_vault_rotation || null,
    version: cfg?.current_version ?? null,
    orphanListed: isListed,
    state: deriveState(cfg, isListed),
    rotationId: rotationId(c),
    vault: cfg,
  };
  if (c.engine === "ldap" && cfg) {
    out.healthCheck = await vaultFanout
      .run(() => readOrNull(`${configPath(c)}/health-check/last`))
      .then((h) => h?.last_result || null)
      .catch((e) => ({ error: e.message }));
  }
  return out;
}

export async function describeAll() {
  const listed = await orphans();
  const items = await Promise.all(all().map((c) => describe(c, listed)));
  return { orphans: listed, credentials: items };
}

export async function versions(c) {
  if (c.engine !== "os") return null;
  return vaultFanout.run(() => readOrNull(`${configPath(c)}/versions`));
}

// Vault 2.2.1 has no LIST for sys/policies/rotation ("unsupported path",
// prompt 06), so the policies read are the ones the credentials name.
export async function rotationPolicies() {
  const names = [...new Set(all().map((c) => c.rotation_policy).filter(Boolean))];
  const out = [
    {
      name: "default",
      maxRetriesPerCycle: 6,
      maxRetryCycles: 3,
      builtIn: true,
    },
  ];
  for (const name of names) {
    const p = (await vault("GET", `sys/policies/rotation/${name}`))?.data || {};
    out.push({
      name,
      maxRetriesPerCycle: p.max_retries_per_cycle,
      maxRetryCycles: p.max_retry_cycles,
      builtIn: false,
      vault: p,
    });
  }
  const used = all().map((c) => ({ id: c.id, policy: c.rotation_policy || "default" }));
  for (const p of out) p.usedBy = used.filter((u) => u.policy === p.name).map((u) => u.id);
  return out;
}

// ── Person actions (run inside session.asPerson: the person's token) ────────

export async function rotate(c) {
  await vault("POST", rotatePath(c), { body: {} });
  return { rotated: true, path: rotatePath(c) };
}

export async function healthCheck(c) {
  if (c.engine !== "ldap")
    throw new NotFound("health checks exist for LDAP static roles only");
  const r = await vault("POST", `${configPath(c)}/health-check/exec`, { body: {} });
  return { result: r?.data || null };
}

export async function unlock(c) {
  if (c.engine !== "ldap")
    throw new NotFound("unlock exists for LDAP static roles only");
  // On OpenLDAP Vault refuses (Active Directory only); the refusal is the answer.
  await vault("PUT", `${configPath(c)}/unlock`, { body: {} });
  return { unlocked: true };
}

// The documented restore: write the stored configuration again, including
// rotation_policy. It re-queues the credential with the rotation manager.
export async function reregister(c) {
  const cfg = await readOrNull(configPath(c));
  if (!cfg) throw new NotFound(`${c.id} is not onboarded (make onboard)`);
  const body = {};
  for (const k of [
    "rotation_period",
    "rotation_schedule",
    "rotation_window",
    "rotation_policy",
    "disable_automated_rotation",
  ]) {
    if (cfg[k] !== undefined && cfg[k] !== null && cfg[k] !== "" && cfg[k] !== 0) body[k] = cfg[k];
  }
  if (c.engine === "os") {
    body.username = cfg.username;
    if (cfg.parent_account_ref) body.parent_account_ref = cfg.parent_account_ref;
  } else {
    body.username = cfg.username;
    body.dn = cfg.dn;
    if (cfg.rotate_on_read) {
      body.rotate_on_read = true;
      body.rotate_on_read_cooldown = cfg.rotate_on_read_cooldown;
    }
  }
  await vault("POST", configPath(c), { body });
  return { reregistered: true, wrote: Object.keys(body).sort() };
}
