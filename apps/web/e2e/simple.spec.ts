import { expect, test, type Browser, type Page } from '@playwright/test';

async function loginAs(browser: Browser, email: string): Promise<Page> {
  const page = await (await browser.newContext()).newPage();
  page.on('pageerror', (e) => { throw e; });
  await page.goto('/');
  await page.getByTestId(`dev-login-${email}`).click();
  await expect(page.getByRole('button', { name: 'Sign out' })).toBeVisible();
  return page;
}

async function setOpenAccess(browser: Browser, on: boolean) {
  const admin = await loginAs(browser, 'admin@reqaz.test');
  await admin.getByRole('link', { name: 'Settings' }).click();
  await admin.getByLabel(/Open access/).setChecked(on);
  await admin.getByLabel(/approve their own/).setChecked(on);
  const saved = admin.waitForResponse((r) => r.request().method() === 'PATCH' && r.url().endsWith('/api/admin/settings'));
  await admin.getByRole('button', { name: 'Save' }).first().click();
  expect((await saved).ok()).toBe(true);
  await admin.context().close();
}

test.afterAll(async ({ browser }) => { await setOpenAccess(browser, false); });

test('open access: a site engineer quotes and buys on their own', async ({ browser }) => {
  const stamp = Date.now().toString().slice(-6);
  await setOpenAccess(browser, true);
  const site = await loginAs(browser, 'site@reqaz.test');

  // Simple quote: customer, items with typed rates, approve in one click.
  await site.getByRole('link', { name: 'Quotations' }).click();
  await site.getByRole('button', { name: 'New quotation' }).click();
  await site.locator('.fixed select[name=customer_id]').selectOption({ label: 'Al Noor Real Estate Development — شركة النور للتطوير العقاري' });
  await site.locator('input[name=quote_title]').fill(`Car park shade ${stamp}`);
  await site.locator('.fixed').getByRole('button', { name: 'Create' }).click();
  await site.waitForURL(/\/quotations\/[0-9a-f-]{36}/);
  await expect(site.getByTestId('show-costs')).not.toBeChecked();
  await expect(site.getByText('Overhead %')).toHaveCount(0);
  await site.getByTestId('add-line').click();
  await site.getByTestId('line-0-description_en').fill('Steel shade structure');
  await site.getByTestId('line-0-description_en').blur();
  await site.getByTestId('line-0-quantity').fill('12');
  await site.getByTestId('line-0-quantity').blur();
  const priced = site.waitForResponse((r) => r.request().method() === 'PATCH' && /\/api\/lines\//.test(r.url()));
  await site.getByTestId('line-0-manual_rate').fill('1450');
  await site.getByTestId('line-0-manual_rate').blur();
  expect((await priced).ok()).toBe(true);
  await expect(site.getByTestId('line-0-total')).toHaveText('17,400.00');
  await expect(site.getByTestId('grand-total')).toContainText('20,010.00'); // 17,400 + 15% VAT
  await site.getByTestId('quick-approve').click();
  await expect(site.getByTestId('rev-status')).toHaveText('Approved');

  // Purchase request approved by the requester, turned into an order for a new supplier.
  await site.getByRole('link', { name: 'Purchases' }).click();
  await site.getByRole('button', { name: 'New purchase request' }).click();
  await site.locator('.fixed input[name=title]').fill(`Shade fabric ${stamp}`);
  await site.locator('.fixed').getByRole('button', { name: 'Create' }).click();
  await site.waitForURL(/\/purchases\/requests\//);
  await site.locator('input[name=new_description]').fill('HDPE shade fabric');
  await site.locator('input[name=new_quantity]').fill('300');
  await site.locator('input[name=new_price]').fill('18');
  await site.getByTestId('add-item').click();
  await expect(site.getByText('Estimated total: SAR 5,400.00')).toBeVisible();
  await site.getByTestId('approve-pr').click();
  await expect(site.getByText('Approved').first()).toBeVisible();
  await site.getByTestId('order-pr').click();
  await site.locator('.fixed input[name=supplier_name]').fill(`Gulf Fabrics ${stamp}`);
  await site.locator('.fixed').getByRole('button', { name: 'Create' }).click();
  await site.waitForURL(/\/purchases\/orders\//);
  await expect(site.getByTestId('po-total')).toContainText('6,210.00'); // 5,400 + 15% VAT
  // Supplier orders are approved before they are issued; with self-approval on, the buyer can approve their own.
  await site.getByTestId('submit-po').click();
  await site.getByTestId('approve-po').click();
  await site.getByTestId('reason-confirm').click();
  await site.getByTestId('issue-po').click();
  await expect(site.getByText(/PO-\d{4}-\d{5}/).first()).toBeVisible();
  await expect(site.getByText('Issued').first()).toBeVisible();

  // Expense with a receipt photo, approved and paid.
  await site.getByRole('link', { name: 'Expenses' }).click();
  await site.getByRole('button', { name: 'New expense' }).click();
  await site.getByTestId('receipt-input').setInputFiles({ name: 'receipt.png', mimeType: 'image/png', buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', 'base64') });
  await site.locator('.fixed input[name=description]').fill(`Diesel ${stamp}`);
  await site.locator('.fixed input[name=amount]').fill('400');
  await site.locator('.fixed').getByRole('button', { name: '15%' }).click();
  await expect(site.locator('.fixed input[name=vat_amount]')).toHaveValue('60.00');
  await expect(site.getByTestId('exp-total')).toHaveText('SAR 460.00');
  await site.locator('.fixed input[name=supplier_name]').fill('Petrol station');
  await site.locator('.fixed').getByRole('button', { name: 'Save' }).click();
  await site.waitForURL(/\/expenses\/[0-9a-f-]{36}/);
  await expect(site.getByText('receipt.png')).toBeVisible();
  await site.getByTestId('approve-expense').click();
  await expect(site.getByText('Approved').first()).toBeVisible();
  await site.getByTestId('pay-expense').click();
  await expect(site.getByText('Paid').first()).toBeVisible();

  // Admin areas stay closed.
  await expect(site.getByRole('link', { name: 'Settings' })).toHaveCount(0);
});
