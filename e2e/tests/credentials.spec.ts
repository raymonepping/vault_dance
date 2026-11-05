// The ten credentials, as the console shows them, against the live stack.
import { test, expect } from '@playwright/test';

test('overview: ten credentials, every scheduled one on time, cluster of three plus vault-s', async ({ page }) => {
  await page.goto('/#/overview');
  const tiles = page.locator('.vg-hero .vg-tile');
  await expect(tiles.filter({ hasText: 'Credentials' })).toContainText('10');
  await expect(tiles.filter({ hasText: 'Orphaned' })).toContainText('0');
  const cluster = page.getByRole('region', { name: 'Cluster' });
  await expect(cluster.locator('.node')).toHaveCount(4);
  await expect(cluster).toContainText('active (rotation manager)');
  await expect(page.getByRole('region', { name: 'Next rotations' }).locator('li')).toHaveCount(5);
});

test('Linux hosts: both distros, three accounts each, every proof PASS', async ({ page }) => {
  await page.goto('/#/hosts');
  for (const host of ['host-rocky', 'host-ubuntu']) {
    const card = page.getByRole('region', { name: new RegExp(host) });
    await expect(card.getByRole('row')).toHaveCount(4); // header + three accounts
    await expect(card.getByText('PASS', { exact: true })).toHaveCount(3);
    await expect(card).toContainText('by mgmt-vault (sudo chpasswd)');
  }
});

test('Linux hosts: a version history drawer, and a rotation the proof follows', async ({ page }) => {
  await page.goto('/#/hosts');
  const row = page.getByRole('region', { name: /host-ubuntu/ }).getByRole('row', { name: /app-deploy/ });
  const before = await row.locator('.fp').first().textContent();
  await row.getByRole('button', { name: 'Rotate now' }).click();
  await expect(row.getByRole('button', { name: 'Rotate now' })).toBeEnabled();
  await row.getByRole('button', { name: 'Prove' }).click();
  await expect(row.getByRole('status')).toContainText('login PASS');
  await expect(row.getByRole('status').locator('.fp')).not.toHaveText(before || '');
  await row.getByRole('button', { name: /version/ }).click();
  const drawer = page.getByRole('dialog', { name: /Versions of host-ubuntu\/app-deploy/ });
  await expect(drawer.getByRole('row').nth(1)).toContainText('current');
  await page.keyboard.press('Escape');
});

test('Directory: rotate on read keeps its password inside the cooldown', async ({ page }) => {
  await page.goto('/#/directory');
  const row = page.getByRole('row', { name: /svc-reports/ });
  await row.getByRole('button', { name: 'Check out' }).click();
  const first = row.getByRole('status').first();
  await expect(first).toContainText('login PASS');
  const fp1 = await first.locator('.fp').textContent();
  await row.getByRole('button', { name: 'Check out' }).click();
  await expect(row.getByRole('status').first()).toContainText('inside the cooldown: same password');
  await expect(row.getByRole('status').first().locator('.fp')).toHaveText(fp1 || '');
});

test('Directory: a live health check, and unlock is refused for OpenLDAP', async ({ page }) => {
  await page.goto('/#/directory');
  const row = page.getByRole('row', { name: /svc-batch/ });
  await row.getByRole('button', { name: 'Health check' }).click();
  await expect(row.getByRole('status')).toContainText('healthy: credentials for role "svc-batch" are valid');
  const unlock = page.getByRole('region', { name: 'Account unlock' });
  await unlock.getByRole('button', { name: /Unlock/ }).click();
  await expect(unlock.getByRole('alert')).toContainText('unlock not supported for schema "openldap"');
  await expect(page.getByRole('region', { name: /Self-managed/ })).toContainText('svc-backup');
});

test('Retries and orphans: both policies, and who uses them', async ({ page }) => {
  await page.goto('/#/orphans');
  const policies = page.getByRole('region', { name: 'Rotation policies' });
  await expect(policies.getByRole('row', { name: /default/ })).toContainText('6');
  await expect(policies.getByRole('row', { name: /quick-step/ })).toContainText('ldap/svc-billing');
});

test('Timeline: proofs and rotations, filterable', async ({ page }) => {
  await page.goto('/#/timeline');
  await page.getByRole('button', { name: 'proofs' }).click();
  await expect(page.getByRole('button', { name: 'proofs' })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('.timeline li').first()).toContainText('proof');
  await page.getByRole('button', { name: 'everything' }).click();
  await expect(page.locator('.timeline li').first()).toBeVisible();
});
