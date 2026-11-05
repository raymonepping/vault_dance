import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

process.env.CREDENTIALS_FILE = fileURLToPath(
  new URL("../../config/credentials.json", import.meta.url),
);
const c = await import("../lib/credentials.js");

const now = 1_800_000_000;
const iso = (s) => new Date(s * 1000).toISOString();

test("the catalogue: ten credentials, unique ids, every parent exists on its host", () => {
  const all = c.all();
  assert.equal(all.length, 10);
  assert.equal(new Set(all.map((x) => x.id)).size, 10);
  for (const x of all.filter((x) => x.parent)) {
    const parent = all.find((p) => p.host === x.host && p.account === x.parent);
    assert.ok(parent, `${x.id}: parent ${x.parent} on ${x.host}`);
    assert.ok(
      all.indexOf(parent) < all.indexOf(x),
      `${x.id}: parent comes first (onboard order)`,
    );
  }
});

test("Vault paths per engine", () => {
  const os = c.byId("host-rocky/app-deploy");
  assert.equal(c.configPath(os), "os/hosts/host-rocky/accounts/app-deploy");
  assert.equal(
    c.secretPath(os),
    "os/hosts/host-rocky/accounts/app-deploy/creds",
  );
  assert.equal(
    c.rotatePath(os),
    "os/hosts/host-rocky/accounts/app-deploy/rotate",
  );
  const self = c.byId("ldap-self/svc-backup");
  assert.equal(c.configPath(self), "ldap-self/static-role/svc-backup");
  assert.equal(c.secretPath(self), "ldap-self/static-cred/svc-backup");
  assert.equal(c.rotatePath(self), "ldap-self/rotate-role/svc-backup");
  assert.equal(
    c.dnOf(self),
    "cn=svc-backup,ou=service-accounts,dc=dance,dc=lab",
  );
  assert.throws(() => c.byId("host-rocky/root"), c.NotFound);
});

test("state: ok, overdue, orphaned, recovered (stale orphan record), on-read, missing", () => {
  const due = (next) => ({
    rotation_period: 120,
    next_vault_rotation: iso(next),
  });
  assert.equal(c.deriveState(due(now + 60), false, now), "ok");
  assert.equal(
    c.deriveState(due(now - 5), false, now),
    "ok",
    "inside the grace period",
  );
  assert.equal(c.deriveState(due(now - 60), false, now), "overdue");
  assert.equal(c.deriveState(due(now - 60), true, now), "orphaned");
  assert.equal(c.deriveState(due(now + 60), true, now), "recovered");
  assert.equal(
    c.deriveState(
      {
        rotate_on_read: true,
        rotation_period: 0,
        next_vault_rotation: iso(now - 999),
      },
      false,
      now,
    ),
    "on-read",
  );
  assert.equal(
    c.deriveState(
      { rotation_schedule: "*/5 * * * *", next_vault_rotation: iso(now + 10) },
      false,
      now,
    ),
    "ok",
  );
  assert.equal(c.deriveState(null, false, now), "missing");
  assert.equal(
    c.deriveState(
      { rotation_period: 120, next_vault_rotation: "0001-01-01T00:00:00Z" },
      false,
      now,
    ),
    "overdue",
  );
});

test("schedule in words Vault's fields imply", () => {
  assert.deepEqual(c.schedule({ rotation_period: 120 }), {
    kind: "period",
    seconds: 120,
  });
  assert.deepEqual(
    c.schedule({ rotation_schedule: "*/5 * * * *", rotation_window: 0 }),
    { kind: "schedule", cron: "*/5 * * * *", window: 0 },
  );
  assert.deepEqual(
    c.schedule({ rotate_on_read: true, rotate_on_read_cooldown: 60 }),
    { kind: "on-read", cooldown: 60 },
  );
  assert.deepEqual(c.schedule({}), { kind: "manual" });
});
