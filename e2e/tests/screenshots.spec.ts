// @shots: refresh docs/screenshots (make screenshots). Not part of make test-ui.
import { test, expect } from '@playwright/test';
import path from 'node:path';
import { ROOT } from '../helpers/env';

const OUT = path.join(ROOT, 'docs/screenshots');

for (const id of ['overview', 'hosts', 'directory', 'orphans', 'timeline']) {
  test(`@shots ${id}`, async ({ browser }) => {
    for (const vp of [{ n: 'desktop', width: 1440, height: 900 }, { n: 'phone', width: 390, height: 844 }]) {
      const ctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, bypassCSP: true, storageState: path.join(__dirname, '../.auth/ada.json') });
      const page = await ctx.newPage();
      await page.goto(`/#/${id}`);
      await expect(page.locator('.vg-hero')).toBeVisible();
      await page.waitForLoadState('networkidle');
      await page.waitForTimeout(600);
      // Full-page captures paint sticky elements mid-page; unstick them (docs only).
      await page.addStyleTag({ content: '.topbar-wrap{position:static!important}.vg-sidebar{position:static!important;height:auto!important;min-height:100%!important}.skip-link{display:none!important}' });
      await page.screenshot({ path: path.join(OUT, `${id}${vp.n === 'phone' ? '-phone' : ''}.png`), fullPage: true });
      await ctx.close();
    }
  });
}
