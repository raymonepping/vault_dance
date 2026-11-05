// helpers/auth.ts: sign in the way a person does: the console's "Sign in",
// Keycloak's own login form, back to the console with a session cookie.
import { expect, type Page } from '@playwright/test';
import { keycloak, personaPassword, urls } from './env';

export async function signIn(page: Page, user: string, route = 'overview') {
  await page.goto(`${urls.web}/auth/login?return=${encodeURIComponent(`/#/${route}`)}`);
  await page.waitForURL((u) => u.toString().startsWith(keycloak), { timeout: 30_000 });
  await page.locator('#username').fill(user);
  await page.locator('#password').fill(personaPassword(user));
  await page.locator('#kc-login').click();
  await page.waitForURL((u) => u.toString().startsWith(urls.web), { timeout: 30_000 });
  await expect(page.locator('.persona')).toBeVisible();
}
