import { test, expect } from '@playwright/test';
import { servedHeaders, servedLeaf } from '../helpers/env';

test('the console is served over TLS 1.3 with a certificate from the lab CA', async () => {
  const { cert, protocol } = await servedLeaf();
  expect(protocol).toBe('TLSv1.3');
  expect(cert.issuer.CN).toBe('Vault Dance Lab CA');
  expect(cert.subjectaltname).toContain('DNS:localhost');
});

test('the console sends a strict Content-Security-Policy', async () => {
  const h = await servedHeaders('/');
  expect(h['content-security-policy']).toContain("default-src 'self'");
  expect(h['x-content-type-options']).toBe('nosniff');
});
