// lib/proof.js: log in with the password Vault holds right now.
//
//   os    SSH as the account (ssh2: password, then keyboard-interactive),
//         host key pinned to what make hosts-keyscan read through podman exec
//   ldap  a simple bind as the entry (ldapts)
//
// The password lives only inside this function: never logged, never
// returned. The answer carries a fingerprint (first 8 hex of SHA-256).
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import ssh2 from "ssh2";
import { Client as LdapClient } from "ldapts";
import { vault } from "./vault.js";
import { vaultFanout } from "./limit.js";
import { dnOf, secretPath } from "./credentials.js";

const HOST_KEYS_DIR = process.env.HOST_KEYS_DIR || "/etc/vdnc/hosts";
const LDAP_URL = process.env.LDAP_URL || "ldap://openldap:389";
const TIMEOUT_MS = 8_000;

export const fingerprint = (secret) =>
  createHash("sha256").update(String(secret)).digest("hex").slice(0, 8);

export class ProofRefused extends Error {}

// The pinned key blob (base64 part of "ssh-ed25519 AAAA..."), per host.
export function pinnedKey(host) {
  const line = readFileSync(`${HOST_KEYS_DIR}/${host}.pub`, "utf8").trim();
  const [type, b64] = line.split(/\s+/);
  if (!type || !b64) throw new Error(`no pinned host key for ${host}`);
  return { type, blob: Buffer.from(b64, "base64") };
}

export function sshLogin(host, username, password) {
  const pinned = pinnedKey(host);
  return new Promise((resolve) => {
    const conn = new ssh2.Client();
    let settled = false;
    const done = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      conn.end();
      resolve(result);
    };
    const timer = setTimeout(
      () => done({ ok: false, error: `SSH to ${host}: timed out after ${TIMEOUT_MS} ms` }),
      TIMEOUT_MS,
    );
    conn.on("ready", () => {
      conn.exec("id -un", (err, stream) => {
        if (err) return done({ ok: false, error: `SSH exec: ${err.message}` });
        let out = "";
        stream.on("data", (d) => (out += d));
        stream.on("close", () =>
          done(
            out.trim() === username
              ? { ok: true, detail: `logged in as ${out.trim()} on ${host}` }
              : { ok: false, error: `logged in, but id -un said "${out.trim()}"` },
          ),
        );
      });
    });
    conn.on("keyboard-interactive", (_n, _i, _l, prompts, finish) =>
      finish(prompts.map(() => password)),
    );
    conn.on("error", (e) => done({ ok: false, error: `SSH to ${host}: ${e.message}` }));
    conn.connect({
      host,
      port: 22,
      username,
      password,
      tryKeyboard: true,
      readyTimeout: TIMEOUT_MS,
      // The host must present exactly the pinned key: no trust on first use.
      hostVerifier: (key) => Buffer.isBuffer(key) && key.equals(pinned.blob),
    });
  });
}

export async function ldapBind(dn, password) {
  const client = new LdapClient({ url: LDAP_URL, timeout: TIMEOUT_MS, connectTimeout: TIMEOUT_MS });
  try {
    await client.bind(dn, password);
    return { ok: true, detail: `bound as ${dn}` };
  } catch (e) {
    return { ok: false, error: `LDAP bind as ${dn}: ${e.message}` };
  } finally {
    await client.unbind().catch(() => {});
  }
}

// Prove one credential with a password already read (checkout path) or read
// now with the current token (the API's own, or the person's).
export async function prove(c, { secret } = {}) {
  let data = secret;
  if (!data) {
    if (c.rotate_on_read)
      throw new ProofRefused(
        `${c.id} rotates when it is read; check it out instead (an operator action)`,
      );
    data = (await vaultFanout.run(() => vault("GET", secretPath(c))))?.data;
  }
  const password = data?.password;
  if (!password) return { ok: false, error: "Vault returned no password" };
  const result =
    c.engine === "os"
      ? await sshLogin(c.host, c.account, password)
      : await ldapBind(dnOf(c), password);
  return {
    id: c.id,
    ok: result.ok,
    result: result.ok ? "PASS" : "FAIL",
    detail: result.detail || result.error,
    fingerprint: fingerprint(password),
    version: data.version ?? data.password_version ?? null,
    lastRotation: data.last_vault_rotation || null,
    rotatedOnRead: data.rotated_on_read ?? null,
    at: new Date().toISOString(),
  };
}
