import { test, expect } from '@playwright/test';

const PAGES: [string, string, string][] = [
  ['Overview', 'overview', 'Every credential, proved.'],
  ['Linux hosts', 'hosts', 'Local passwords that change on time.'],
  ['Directory', 'directory', 'Service accounts, rotated by Vault.'],
  ['Retries & orphans', 'orphans', 'Retry, back off, then stop and say so.'],
  ['Timeline', 'timeline', "What happened, in Vault's words."],
];

test('every page is one click away, with exactly one ink hero', async ({ page }) => {
  await page.goto('/');
  for (const [link, , heading] of PAGES) {
    await page.locator('.vg-sidebar').getByRole('link', { name: link }).click();
    await expect(page.getByRole('heading', { name: heading })).toBeVisible();
    await expect(page.locator('.vg-hero')).toHaveCount(1);
  }
});

test('the topbar shows three unsealed nodes', async ({ page }) => {
  await page.goto('/');
  await expect(page.getByRole('status').filter({ hasText: /3\/3 unsealed · 2\.2\.\d+\+ent/ })).toBeVisible();
});

test('phone: no horizontal page scroll, pages reachable from the top nav', async ({ browser }) => {
  // Not isMobile: a mobile layout viewport widens to fit overflowing content.
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, storageState: '.auth/ada.json' });
  const page = await ctx.newPage();
  for (const [, id] of PAGES) {
    await page.goto(`/#/${id}`);
    await expect(page.locator('.vg-hero')).toBeVisible();
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(300);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(overflow, `${id} scrolls sideways by ${overflow}px`).toBeLessThanOrEqual(0);
  }
  await page.locator('.mobile-nav').getByRole('link', { name: 'Directory' }).click();
  await expect(page.getByRole('heading', { name: 'Service accounts, rotated by Vault.' })).toBeVisible();
  await ctx.close();
});

test('the Vault said drawer records every answer and closes with Escape', async ({ page }) => {
  await page.goto('/#/hosts');
  const row = page.getByRole('row', { name: /app-deploy/ }).first();
  await row.getByRole('button', { name: 'Prove' }).click();
  await expect(row.getByRole('status')).toContainText('login PASS');
  await page.getByRole('button', { name: /Vault said/ }).click();
  const drawer = page.getByRole('dialog', { name: 'Vault said' });
  await expect(drawer).toContainText('POST /api/credential/proof?id=host-rocky%2Fapp-deploy');
  await expect(drawer).not.toContainText('"password"');
  await page.keyboard.press('Escape');
  await expect(drawer).toHaveCount(0);
});
