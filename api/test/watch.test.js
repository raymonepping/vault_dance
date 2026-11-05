import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

process.env.CREDENTIALS_FILE = fileURLToPath(new URL("../../config/credentials.json", import.meta.url));
const { diff, record, timeline } = await import("../lib/watch.js");
const { parseLine, parseLog } = await import("../lib/vaultlog.js");

const base = { id: "host-rocky/app-deploy", version: 3, lastRotation: "t1", nextRotation: "t2", state: "ok" };

test("diff: a new version is a rotation", () => {
  assert.deepEqual(diff(base, { ...base, version: 4, lastRotation: "t3" }).map((e) => e.kind), ["rotation"]);
  assert.deepEqual(diff(base, base), []);
  assert.deepEqual(diff(undefined, base), [], "the first sighting is not an event");
});

test("diff: an LDAP role has no version; last_vault_rotation moving is a rotation", () => {
  const l = { ...base, id: "ldap/svc-billing", version: null };
  assert.deepEqual(diff(l, { ...l, lastRotation: "t9" }).map((e) => e.kind), ["rotation"]);
});

test("diff: overdue, orphaned, recovered", () => {
  assert.deepEqual(diff(base, { ...base, state: "overdue" }).map((e) => e.kind), ["overdue"]);
  assert.deepEqual(diff({ ...base, state: "overdue" }, { ...base, state: "orphaned" }).map((e) => e.kind), ["orphaned"]);
  const rec = diff({ ...base, state: "orphaned" }, { ...base, state: "recovered" });
  assert.equal(rec[0].kind, "recovered");
  assert.match(rec[0].detail, /orphan record/);
  assert.deepEqual(diff({ ...base, state: "overdue" }, { ...base, state: "ok" }).map((e) => e.kind), ["recovered"]);
});

test("timeline: newest first, filters by id and kind", () => {
  record({ kind: "rotation", id: "a" });
  record({ kind: "proof", id: "b", result: "PASS" });
  assert.equal(timeline()[0].id, "b");
  assert.deepEqual(timeline({ id: "a" }).map((e) => e.kind), ["rotation"]);
  assert.deepEqual(timeline({ kind: "proof" }).map((e) => e.id), ["b"]);
});

test("Vault log: a rotation failure line, and nothing else", () => {
  const line =
    '2026-11-05T09:36:23.461Z [ERROR] rotation-job-manager: rotation failed, attempting to re-queue: rotationID=os/hosts/host-rocky/accounts/app-deploy error="failed to rotate credential for account \\"app-deploy\\": ssh: handshake failed"';
  const f = parseLine(line);
  assert.equal(f.rotationId, "os/hosts/host-rocky/accounts/app-deploy");
  assert.equal(f.at, "2026-11-05T09:36:23.461Z");
  assert.match(f.error, /account "app-deploy": ssh: handshake failed/);
  assert.equal(parseLine("2026-11-05T09:36:23.461Z [ERROR] rotation-job-manager: other rotate error: err=\"x\""), null);
  assert.equal(parseLine("[INFO] core: unsealed"), null);
});

test("Vault log: a multi-line error is collected from its continuation lines", () => {
  const text = [
    '2026-11-05T11:02:17.471Z [ERROR] rotation-job-manager: other rotate error:',
    "  err=",
    '  | failed to rotate credential for account "ops-breakglass": You must wait longer to change your password.',
    "  | Process exited with status 10",
    "  ",
    "2026-11-05T11:02:17.471Z [ERROR] rotation-job-manager: rotation failed, attempting to re-queue: rotationID=os/hosts/host-ubuntu/accounts/ops-breakglass",
    "  error=",
    '  | failed to rotate credential for account "ops-breakglass": You must wait longer to change your password.',
    "  | Process exited with status 10",
    "  ",
    '2026-11-05T11:03:00.000Z [ERROR] rotation-job-manager: rotation failed, attempting to re-queue: rotationID=ldap/static-role/svc-billing error="LDAP Result Code 50"',
  ].join("\n");
  const f = parseLog(text);
  assert.equal(f.length, 2);
  assert.equal(f[0].rotationId, "os/hosts/host-ubuntu/accounts/ops-breakglass");
  assert.equal(f[0].error, 'failed to rotate credential for account "ops-breakglass": You must wait longer to change your password. Process exited with status 10');
  assert.equal(f[1].error, "LDAP Result Code 50");
});
