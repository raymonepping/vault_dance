import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  pkceChallenge,
  parseCookies,
  sessionCookie,
  safeReturn,
  decodeJwt,
  capabilityMap,
  ACTIONS,
  login,
} from "../lib/session.js";

test("PKCE S256: base64url(sha256(verifier)), RFC 7636 appendix B", () => {
  assert.equal(
    pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
    "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
  );
  assert.equal(
    pkceChallenge("x"),
    createHash("sha256").update("x").digest("base64url"),
  );
});

test("cookies: parse, first value wins, session cookie is httpOnly Secure SameSite=Lax", () => {
  assert.deepEqual(parseCookies("a=1; dance_sid=abc; dance_sid=evil"), {
    a: "1",
    dance_sid: "abc",
  });
  assert.deepEqual(parseCookies(""), {});
  const c = sessionCookie("abc", 60);
  for (const part of [
    "dance_sid=abc",
    "HttpOnly",
    "Secure",
    "SameSite=Lax",
    "Path=/",
    "Max-Age=60",
  ])
    assert.ok(c.includes(part), part);
});

test("return path after sign-in: same origin, hash routes only", () => {
  assert.equal(safeReturn("/#/hosts"), "/#/hosts");
  assert.equal(safeReturn("/"), "/");
  for (const bad of [
    "https://evil.example/",
    "//evil.example",
    "/#/pki?x=1",
    "/../x",
    "javascript:alert(1)",
  ])
    assert.equal(safeReturn(bad), "/");
});

test("login redirect: code flow with PKCE S256, state and nonce", () => {
  const u = new URL(
    login(new URL("http://api/auth/login?return=/%23/directory")),
  );
  assert.match(u.pathname, /\/realms\/dance\/protocol\/openid-connect\/auth$/);
  assert.equal(u.searchParams.get("response_type"), "code");
  assert.equal(u.searchParams.get("code_challenge_method"), "S256");
  assert.equal(u.searchParams.get("client_id"), "dance-console");
  assert.ok(u.searchParams.get("state").length >= 32);
  assert.ok(u.searchParams.get("nonce").length >= 16);
  assert.match(u.searchParams.get("redirect_uri"), /\/auth\/callback$/);
});

test("decodeJwt reads the payload, rejects non-JWTs", () => {
  const p = Buffer.from(
    JSON.stringify({ preferred_username: "tess", groups: ["dance-viewers"] }),
  ).toString("base64url");
  assert.equal(decodeJwt(`h.${p}.s`).preferred_username, "tess");
  assert.throws(() => decodeJwt("nope"), /not a JWT/);
});

test("capability map: the action's own capability decides, not any capability", () => {
  const answer = Object.fromEntries(
    Object.values(ACTIONS).map((a) => [a.path, ["read", "list"]]),
  );
  const m = capabilityMap(answer);
  assert.equal(m.view.allowed, true, "view needs read");
  assert.equal(m["os.checkout"].allowed, true, "checkout needs read");
  assert.equal(m["os.rotate"].allowed, false, "rotate needs update, read is not enough");
  assert.equal(m["ldap.reregister"].allowed, false, "a viewer can read a role, not rewrite it");
  const root = capabilityMap({ [ACTIONS["policy.edit"].path]: ["root"] });
  assert.equal(root["policy.edit"].allowed, true);
  assert.equal(capabilityMap({})["os.rotate"].allowed, false, "no answer means not allowed");
});
