// Who may do what: Vault decides, the console only shows it.
import { test, expect } from '@playwright/test';
import { signIn } from '../helpers/auth';

const fresh = { storageState: { cookies: [], origins: [] } };

test('signed out: pages read, actions ask you to sign in', async ({ browser }) => {
  const ctx = await browser.newContext(fresh);
  const page = await ctx.newPage();
  await page.goto('/#/hosts');
  await expect(page.getByRole('link', { name: 'Sign in' }).first()).toBeVisible();
  await page.getByRole('row', { name: /app-deploy/ }).first().getByRole('button', { name: 'Rotate now' }).click();
  await expect(page.getByText('Sign in to use this room.').first()).toBeVisible();
  await ctx.close();
});

test('tess (viewer) sees her limits, and Vault refuses her rotation', async ({ browser }) => {
  const ctx = await browser.newContext(fresh);
  const page = await ctx.newPage();
  await signIn(page, 'tess', 'hosts');
  const authority = page.getByRole('region', { name: 'Your authority in this room' });
  await expect(authority).toContainText('dance-viewer');
  await expect(authority.locator('.vg-pill--rejected').first()).toContainText('rotate');
  const row = page.getByRole('region', { name: /host-rocky/ }).getByRole('row', { name: /app-deploy/ });
  await expect(row.getByRole('button', { name: /Rotate now.*Vault will refuse/ })).toBeVisible();
  await row.getByRole('button', { name: /Rotate now/ }).click();
  await expect(row.getByRole('alert')).toContainText('permission denied');
  await expect(row.getByRole('alert')).toContainText('HTTP 403');
  await ctx.close();
});

test('otto (operator) may rotate; the timeline names him', async ({ browser }) => {
  const ctx = await browser.newContext(fresh);
  const page = await ctx.newPage();
  await signIn(page, 'otto', 'directory');
  const row = page.getByRole('row', { name: /svc-billing/ });
  await row.getByRole('button', { name: 'Rotate now' }).click();
  await expect(row.getByRole('alert')).toHaveCount(0);
  await page.goto('/#/timeline');
  await expect(page.locator('.timeline li').filter({ hasText: 'by otto' }).first()).toBeVisible();
  await ctx.close();
});

test('ada signs out through Keycloak and is signed out of the console', async ({ browser }) => {
  const ctx = await browser.newContext(fresh);
  const page = await ctx.newPage();
  await signIn(page, 'ada');
  await page.locator('.persona').click();
  await expect(page.getByRole('dialog', { name: 'Signed in' })).toContainText('dance-admins');
  await page.getByRole('link', { name: 'Sign out' }).click();
  await expect(page.getByRole('link', { name: 'Sign in' }).first()).toBeVisible({ timeout: 30_000 });
  await ctx.close();
});
