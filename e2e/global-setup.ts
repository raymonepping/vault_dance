// global-setup.ts: fail fast, with the make target that fixes it, when the
// stack is not up; then sign in once as ada through the real Keycloak form
// and keep the session for every journey.
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { chromium } from '@playwright/test';
import { labCaSpkiArg, urls } from './helpers/env';
import { signIn } from './helpers/auth';

const CORE = ['vdnc-vault-s', 'vdnc-vault-1', 'vdnc-vault-2', 'vdnc-vault-3', 'vdnc-host-rocky', 'vdnc-host-ubuntu', 'vdnc-openldap', 'vdnc-keycloak', 'vdnc-rotator', 'vdnc-vault-agent', 'vdnc-api', 'vdnc-web'];
export const STORAGE = path.join(__dirname, '.auth/ada.json');

export default async function globalSetup(): Promise<void> {
  const running = execFileSync('podman', ['ps', '--filter', 'name=^vdnc-', '--format', '{{.Names}}'], { encoding: 'utf8' }).split('\n');
  const down = CORE.filter((c) => !running.includes(c));
  if (down.length) throw new Error(`not running: ${down.join(', ')}: run "make up" (or "make bootstrap" on a fresh machine)`);
  const r = await fetch(`${urls.api}/api/health`);
  const h = await r.json();
  if (!h.ok) throw new Error(`api /api/health is not ok: ${JSON.stringify(h)}: run "make doctor"`);

  const browser = await chromium.launch({ args: [labCaSpkiArg()] });
  const page = await browser.newPage();
  await signIn(page, 'ada');
  await page.context().storageState({ path: STORAGE });
  await browser.close();
}
