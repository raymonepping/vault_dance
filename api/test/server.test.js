import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";

process.env.CREDENTIALS_FILE = fileURLToPath(new URL("../../config/credentials.json", import.meta.url));
const { credentialParam, BadRequest } = await import("../server.js");
const { prove, ProofRefused, fingerprint } = await import("../lib/proof.js");
const { byId } = await import("../lib/credentials.js");

const u = (id) => new URL(`http://api/x?id=${encodeURIComponent(id)}`);

test("id parameter: one of the ten, exactly", () => {
  assert.equal(credentialParam(u("host-ubuntu/ops-breakglass")).account, "ops-breakglass");
  for (const bad of ["", "host-rocky", "host-rocky/../x", "host-rocky/app-deploy/creds", "HOST/x", "host-rocky/root", "a/b\nc"])
    assert.throws(() => credentialParam(u(bad)), BadRequest, bad);
});

test("a rotate-on-read credential is never proved by reading it", async () => {
  await assert.rejects(prove(byId("ldap/svc-reports")), ProofRefused);
});

test("fingerprint: first 8 hex of SHA-256, never the secret", () => {
  assert.equal(fingerprint("abc"), "ba7816bf");
  assert.equal(fingerprint("abc").length, 8);
});
