// lib/watch.js: the timeline. Every few seconds the API's own identity reads
// every credential and records what changed, in Vault's words:
//
//   rotation   version or last_vault_rotation moved on
//   overdue    next_vault_rotation passed without a rotation (Vault retries)
//   orphaned   listed in sys/rotation/orphans and still overdue
//   recovered  on time again (after a re-register), even if still listed
//   failure    a "rotation failed" line in Vault's own log (lib/vaultlog.js)
//   proof      a login with Vault's current password, PASS or FAIL
//
// After every rotation the credential is proved, so the console shows the
// fingerprint change and the login still work. Rotate-on-read credentials are
// never read here. In memory, newest first, capped.
import { describeAll, byId } from "./credentials.js";
import { prove } from "./proof.js";
import { readFailures } from "./vaultlog.js";

const INTERVAL_MS = Number(process.env.WATCH_INTERVAL_MS || 5000);
const CAP = 500;

const events = [];
const last = new Map(); // id → { version, lastRotation, state }
export const proofs = new Map(); // id → latest proof result
let snapshot = { at: null, orphans: [], credentials: [] };
let running = false;

export function record(ev) {
  events.unshift({ at: new Date().toISOString(), ...ev });
  if (events.length > CAP) events.length = CAP;
}

export function timeline({ id, kind, limit = 200 } = {}) {
  return events
    .filter((e) => (!id || e.id === id) && (!kind || e.kind === kind))
    .slice(0, Math.min(Number(limit) || 200, CAP));
}

export const current = () => snapshot;

// Pure: one credential's previous and current view → the events it implies.
export function diff(prev, cur) {
  const out = [];
  if (!prev) return out;
  const moved =
    (cur.version !== null && prev.version !== null && cur.version !== prev.version) ||
    (cur.lastRotation && prev.lastRotation && cur.lastRotation !== prev.lastRotation);
  if (moved)
    out.push({
      kind: "rotation",
      id: cur.id,
      detail: `rotated${cur.version !== null ? ` to version ${cur.version}` : ""} at ${cur.lastRotation}`,
    });
  if (prev.state !== cur.state) {
    const kinds = { overdue: "overdue", orphaned: "orphaned" };
    if (kinds[cur.state])
      out.push({
        kind: kinds[cur.state],
        id: cur.id,
        detail:
          cur.state === "orphaned"
            ? "Vault stopped retrying: listed in sys/rotation/orphans"
            : `next rotation (${cur.nextRotation}) passed; Vault is retrying`,
      });
    else if (["overdue", "orphaned"].includes(prev.state) && ["ok", "recovered"].includes(cur.state))
      out.push({
        kind: "recovered",
        id: cur.id,
        detail:
          cur.state === "recovered"
            ? "rotating on time again; Vault still lists an orphan record (2.2.1)"
            : "rotating on time again",
      });
  }
  return out;
}

export async function proveAndRecord(c, opts) {
  const p = await prove(c, opts);
  proofs.set(c.id, p);
  record({
    kind: "proof",
    id: c.id,
    result: p.result,
    fingerprint: p.fingerprint,
    detail: p.detail,
  });
  return p;
}

async function tick() {
  if (running) return;
  running = true;
  try {
    const now = await describeAll();
    snapshot = { at: new Date().toISOString(), ...now };
    for (const cur of now.credentials) {
      const prev = last.get(cur.id);
      // First sighting: prove it once, so the console starts with a result.
      if (!prev && cur.state !== "missing" && !byId(cur.id).rotate_on_read)
        proveAndRecord(byId(cur.id)).catch(() => {});
      for (const ev of diff(prev, cur)) {
        record(ev);
        if (ev.kind === "rotation") {
          const c = byId(cur.id);
          if (!c.rotate_on_read) proveAndRecord(c).catch(() => {});
        }
      }
      last.set(cur.id, {
        version: cur.version,
        lastRotation: cur.lastRotation,
        state: cur.state,
      });
    }
    for (const f of readFailures()) record({ kind: "failure", ...f });
  } catch (e) {
    record({ kind: "watch-error", detail: e.message });
  } finally {
    running = false;
  }
}

export function start() {
  tick();
  setInterval(tick, INTERVAL_MS).unref();
}
