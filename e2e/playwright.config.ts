// playwright.config.ts: the live stack, a real browser, nothing mocked.
import { defineConfig, devices } from '@playwright/test';
import { labCaSpkiArg, urls } from './helpers/env';

export default defineConfig({
  testDir: './tests',
  globalSetup: './global-setup.ts',
  fullyParallel: false,
  workers: 1, // journeys share one Vault and its credentials
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    ...devices['Desktop Chrome'],
    baseURL: urls.web,
    viewport: { width: 1440, height: 900 },
    trace: 'retain-on-failure',
    // Signed in as ada (all three groups) by global-setup. Tests that need
    // another person or none open their own context.
    storageState: '.auth/ada.json',
    screenshot: 'only-on-failure',
    // Trust the lab CA's and the console leaf's keys, never ignoreHTTPSErrors.
    launchOptions: { args: [labCaSpkiArg()] },
  },
});
