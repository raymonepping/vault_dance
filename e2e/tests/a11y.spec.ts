// WCAG 2.1 AA on every screen, desktop and phone, after real data loaded.
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

const SCREENS = [
  { id: 'overview', ready: 'Every credential, proved.' },
  { id: 'hosts', ready: 'Local passwords that change on time.' },
  { id: 'directory', ready: 'Service accounts, rotated by Vault.' },
  { id: 'orphans', ready: 'Retry, back off, then stop and say so.' },
  { id: 'timeline', ready: "What happened, in Vault's words." },
];
const TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'];
const summary = (r: { violations: { id: string; nodes: { target: unknown[] }[] }[] }) =>
  r.violations.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(' | ')}`);

for (const vp of [{ name: 'desktop', width: 1440, height: 900 }, { name: 'phone', width: 390, height: 844 }]) {
  for (const s of SCREENS) {
    test(`axe: ${s.id} (${vp.name})`, async ({ page }) => {
      await page.setViewportSize({ width: vp.width, height: vp.height });
      await page.goto(`/#/${s.id}`);
      await expect(page.getByRole('heading', { name: s.ready })).toBeVisible();
      await page.waitForLoadState('networkidle');
      await page.waitForTimeout(400);
      const r = await new AxeBuilder({ page }).withTags(TAGS).analyze();
      expect(summary(r), summary(r).join('\n')).toEqual([]);
    });
  }
}

test('axe: hosts (signed out)', async ({ browser }) => {
  const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
  const page = await ctx.newPage();
  await page.goto('/#/hosts');
  await expect(page.getByRole('link', { name: 'Sign in' }).first()).toBeVisible();
  await page.waitForLoadState('networkidle');
  const r = await new AxeBuilder({ page }).withTags(TAGS).analyze();
  expect(summary(r), summary(r).join('\n')).toEqual([]);
  await ctx.close();
});
