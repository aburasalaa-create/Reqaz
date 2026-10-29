import { expect, test } from '@playwright/test';

test('finance prepares and issues a tax invoice through the UI', async ({ browser }) => {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  page.on('pageerror', (e) => { throw e; });
  await page.goto('/');
  await page.getByTestId('dev-login-finance@reqaz.test').click();
  await page.getByRole('link', { name: 'Invoices' }).click();

  await page.getByTestId('new-invoice').click();
  await page.locator('select[name="customer_id"]').selectOption({ label: 'Al Noor Real Estate Development — شركة النور للتطوير العقاري' });
  await page.getByRole('button', { name: 'Create' }).click();
  await page.waitForURL(/\/invoices\/[0-9a-f-]{36}$/);

  await page.getByTestId('add-line').click();
  await page.locator('textarea[name="description_en"]').fill('Concrete works');
  await page.locator('input[name="quantity"]').fill('2');
  await page.locator('input[name="unit_price"]').fill('1000');
  await page.getByTestId('save-line').click();
  await expect(page.getByTestId('total')).toHaveText('SAR 2,300.00');

  await page.getByTestId('issue').click();
  await page.getByTestId('confirm-issue').click();
  await expect(page.getByText(/INV-\d{4}-\d{5}/).first()).toBeVisible();
  await expect(page.getByText('Issued', { exact: true }).first()).toBeVisible();
  await expect(page.getByTestId('add-line')).toHaveCount(0);
});
