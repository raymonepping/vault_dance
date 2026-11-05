// helpers/env.ts: where things are. Ports come from the same two files the
// stack reads (config/defaults.conf, overridden by .env).
import fs from 'node:fs';
import path from 'node:path';
import tls from 'node:tls';
import https from 'node:https';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

export const ROOT = path.resolve(__dirname, '../..');

function readEnvFile(file: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line);
    if (m && m[1] !== 'VAULT_LICENSE') out[m[1]] = m[2];
  }
  return out;
}

const merged = { ...readEnvFile(path.join(ROOT, 'config/defaults.conf')), ...readEnvFile(path.join(ROOT, '.env')) };

export function conf(name: string): string {
  const v = merged[name];
  if (v === undefined) throw new Error(`configuration value ${name} is not set`);
  return v;
}

export const urls = {
  web: `https://localhost:${conf('VDNC_PORT_WEB')}`,
  api: `http://127.0.0.1:${conf('VDNC_PORT_API')}`,
};
export const keycloak = `http://localhost:${conf('VDNC_PORT_KEYCLOAK')}`;

const LAB_CA = path.join(ROOT, 'vault-tls/ca-chain.pem');
const LEAF = path.join(ROOT, 'vault-tls/vault.crt');

const spki = (pem: string) =>
  crypto.createHash('sha256').update(crypto.createPublicKey(pem).export({ type: 'spki', format: 'der' })).digest('base64');

/**
 * Chromium flag that makes the browser trust exactly the console leaf's and
 * the lab CA's keys (the lab CA is in no browser trust store) instead of
 * ignoring certificate errors.
 */
export function labCaSpkiArg(): string {
  return `--ignore-certificate-errors-spki-list=${spki(fs.readFileSync(LEAF, 'utf8'))},${spki(fs.readFileSync(LAB_CA, 'utf8'))}`;
}

/** TLS to the console the strict way: hostname checked, chain verified against the lab CA only. */
export function servedLeaf(): Promise<{ cert: tls.PeerCertificate; protocol: string | null }> {
  return new Promise((resolve, reject) => {
    const s = tls.connect({ host: 'localhost', port: Number(conf('VDNC_PORT_WEB')), servername: 'localhost', ca: [fs.readFileSync(LAB_CA)] }, () => {
      const out = { cert: s.getPeerCertificate(), protocol: s.getProtocol() };
      s.end();
      resolve(out);
    });
    s.on('error', reject);
  });
}

/** A persona's password, straight from Vault KV (never logged). */
export function personaPassword(user: string): string {
  return execFileSync(path.join(ROOT, 'scripts/identity-secrets.sh'), ['--print', user], { encoding: 'utf8', timeout: 20_000 }).trim();
}

/** Response headers from the console, TLS verified against the lab CA only. */
export function servedHeaders(p: string): Promise<Record<string, string | string[] | undefined>> {
  return new Promise((resolve, reject) => {
    https
      .get({ host: 'localhost', port: Number(conf('VDNC_PORT_WEB')), path: p, ca: [fs.readFileSync(LAB_CA)] }, (r) => {
        r.resume();
        resolve(r.headers);
      })
      .on('error', reject);
  });
}
