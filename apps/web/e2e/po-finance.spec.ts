// Purchase order and finance cycle through the screens: customer PO → project → budget → requisition → supplier quotes →
// approved and issued supplier PO → partial delivery → matched supplier invoice → payment → progress claim → receipt → dashboards.
import { expect, test, type Browser, type Page } from '@playwright/test';

const SHOTS = process.env.SHOTS_DIR;
let shot = 0;
const snap = async (page: Page, name: string) => {
  if (SHOTS) await page.screenshot({ path: `${SHOTS}/${String(++shot).padStart(2, '0')}-${name}.png`, fullPage: true });
};

async function loginAs(browser: Browser, email: string): Promise<Page> {
  const page = await (await browser.newContext()).newPage();
  page.on('pageerror', (e) => { throw e; });
  await page.goto('/');
  await page.getByTestId(`dev-login-${email}`).click();
  await expect(page.getByRole('button', { name: 'Sign out' })).toBeVisible();
  return page;
}

async function setSelfApproval(page: Page, on: boolean) {
  await page.getByRole('link', { name: 'Settings' }).click();
  await page.getByLabel(/approve their own/).setChecked(on);
  const saved = page.waitForResponse((r) => r.request().method() === 'PATCH' && r.url().endsWith('/api/admin/settings'));
  await page.getByRole('button', { name: 'Save' }).first().click();
  expect((await saved).ok()).toBe(true);
}

const done = (page: Page, re: RegExp) => page.waitForResponse((r) => re.test(r.url()) && r.request().method() !== 'GET' && r.ok());

test('customer PO to project, supplier PO to payment, progress claim to receipt', async ({ browser }) => {
  test.setTimeout(180_000);
  const stamp = Date.now().toString().slice(-6);
  const page = await loginAs(browser, 'admin@reqaz.test');
  await setSelfApproval(page, true);

  // An approved quotation.
  await page.getByRole('link', { name: 'Quotations' }).click();
  await page.getByRole('button', { name: 'New quotation' }).click();
  await page.locator('.fixed select[name=customer_id]').selectOption({ label: 'Al Noor Real Estate Development — شركة النور للتطوير العقاري' });
  await page.locator('input[name=quote_title]').fill(`Steel canopy ${stamp}`);
  await page.locator('.fixed').getByRole('button', { name: 'Create' }).click();
  await page.waitForURL(/\/quotations\/[0-9a-f-]{36}/);
  const quotationId = page.url().split('/quotations/')[1].slice(0, 36);
  await page.getByTestId('add-line').click();
  await page.getByTestId('line-0-description_en').fill('Steel canopy supply and erection');
  await page.getByTestId('line-0-description_en').blur();
  await page.getByTestId('line-0-quantity').fill('10');
  await page.getByTestId('line-0-quantity').blur();
  const priced = done(page, /\/api\/lines\//);
  await page.getByTestId('line-0-manual_rate').fill('10000');
  await page.getByTestId('line-0-manual_rate').blur();
  await priced;
  await page.getByTestId('quick-approve').click();
  await expect(page.getByTestId('rev-status')).toHaveText('Approved');

  // 1–3. Register the customer PO against it, review, accept, create the project.
  await page.getByRole('link', { name: 'PO Center' }).click();
  await expect(page.getByTestId('po-center-stats')).toContainText('Customer POs to review');
  await page.goto('/customer-pos');
  await page.getByTestId('new-cpo').click();
  await page.locator('.fixed input[name=customer_po_number]').fill(`ALN-PO-${stamp}`);
  await page.locator('.fixed select[name=quotation_id]').selectOption(quotationId);
  await page.getByTestId('save-cpo').click();
  await page.waitForURL(/\/customer-pos\/[0-9a-f-]{36}/);
  await expect(page.getByTestId('cpo-amount')).toHaveText('100,000.00');
  await expect(page.getByText('Matches the quotation')).toBeVisible();
  await snap(page, 'customer-po-registered');
  await page.getByTestId('cpo-review').click();
  await expect(page.getByText('Under review').first()).toBeVisible();
  await page.getByTestId('cpo-accept').click();
  await page.getByTestId('reason-confirm').click();
  await expect(page.getByText('Accepted').first()).toBeVisible();
  await page.getByTestId('cpo-convert').click();
  await page.locator('.fixed input[name=project_name]').fill(`Canopy project ${stamp}`);
  await page.locator('.fixed input[name=retention_pct]').fill('5');
  await page.getByTestId('convert-confirm').click();
  await expect(page.getByText('Active').first()).toBeVisible();
  await snap(page, 'customer-po-active');
  const projectHref = await page.locator('a[href^="/projects/"]').first().getAttribute('href');
  const projectId = projectHref!.split('/projects/')[1];

  // 4. Budget change on the project, approved.
  await page.goto(projectHref!);
  await page.getByTestId('new-bc').click();
  await page.locator('.fixed input[name=reason]').fill('Initial budget');
  await page.locator('.fixed input[name=bc_materials]').fill('60000');
  await page.getByTestId('save-bc').click();
  await page.getByTestId('doc-submit').click();
  await expect(page.locator('.fixed').getByText('Waiting approval')).toBeVisible();
  await page.getByTestId('doc-approve').click();
  await expect(page.locator('.fixed').getByText('Approved').first()).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('sum-budget')).toHaveText('60,000.00');

  // Requisition against the project and its materials budget.
  await page.goto('/purchases');
  await page.getByRole('button', { name: 'New purchase request' }).click();
  await page.locator('.fixed input[name=title]').fill(`Canopy steel ${stamp}`);
  await page.locator('.fixed').getByRole('button', { name: 'Create' }).click();
  await page.waitForURL(/\/purchases\/requests\//);
  const setProject = done(page, /\/api\/purchase-requests\//);
  await page.locator('select[name=project_id]').selectOption(projectId);
  await setProject;
  const setCat = done(page, /\/api\/purchase-requests\//);
  await page.locator('select[name=cost_category]').selectOption('materials');
  await setCat;
  await page.locator('textarea[name=justification]').fill('Canopy frames');
  await page.locator('textarea[name=justification]').blur();
  await page.locator('input[name=new_description]').fill('Steel sections');
  await page.locator('input[name=new_quantity]').fill('8');
  await page.locator('input[name=new_price]').fill('5000');
  await page.getByTestId('add-item').click();
  await expect(page.getByText('Estimated total: SAR 40,000.00')).toBeVisible();
  await page.getByTestId('approve-pr').click();
  await expect(page.getByTestId('budget-result')).toHaveText('Within budget');

  // 5. Two supplier quotations compared; the lowest compliant one is selected.
  for (const [name, price, vat] of [[`Dammam Steel ${stamp}`, '4800', `3${stamp}00000003`], [`Jubail Metals ${stamp}`, '4950', `3${stamp}10000003`]]) {
    await page.getByTestId('add-quote').click();
    await page.locator('.fixed input[name=supplier_name]').fill(name);
    await page.locator('.fixed input[name=supplier_vat]').fill(vat);
    await page.locator('.fixed input[name=delivery_days]').fill('10');
    await page.locator('.fixed input[name=price_0]').fill(price);
    await page.getByTestId('save-quote').click();
    await expect(page.getByRole('dialog')).toHaveCount(0);
  }
  await expect(page.getByTestId('quote-comparison')).toContainText('44,160.00'); // 8 × 4,800 + 15% VAT
  await snap(page, 'supplier-quote-comparison');
  await page.getByTestId('quote-comparison').getByRole('button', { name: 'Select' }).first().click();
  await page.getByTestId('reason-confirm').click();
  await page.waitForURL(/\/purchases\/orders\//);

  // 6. The supplier PO is approved, then issued.
  await expect(page.getByTestId('po-total')).toContainText('44,160.00');
  await page.getByTestId('submit-po').click();
  await expect(page.getByText('Waiting approval').first()).toBeVisible();
  await page.getByTestId('approve-po').click();
  await page.getByTestId('reason-confirm').click();
  await expect(page.getByTestId('issue-po')).toBeVisible();
  await page.getByTestId('issue-po').click();
  await expect(page.getByText(/PO-\d{4}-\d{5}/).first()).toBeVisible();

  // 7. Partial delivery.
  await page.getByTestId('receive-po').click();
  await page.locator('.fixed input[name=delivery_note_ref]').fill(`DN-${stamp}`);
  await page.locator('.fixed input[name=qty_10]').fill('5');
  await page.getByTestId('grn-confirm').click();
  await expect(page.getByText('Partly received').first()).toBeVisible();
  await expect(page.getByTestId('grn-row')).toHaveCount(1);
  await snap(page, 'supplier-po-partly-received');

  // 8–9. Supplier invoice for what arrived, matched, posted and paid.
  await page.getByTestId('bill-po').click();
  await page.locator('.fixed textarea[name=reason]').fill(`INV-${stamp}`);
  await page.getByTestId('reason-confirm').click();
  await page.waitForURL(/\/supplier-invoices\//);
  await expect(page.getByTestId('bill-total')).toHaveText('27,600.00'); // 5 × 4,800 + VAT
  await expect(page.getByText('Matched').first()).toBeVisible();
  await snap(page, 'supplier-invoice-matched');
  await page.getByTestId('post-bill').click();
  await expect(page.getByText('Posted').first()).toBeVisible();
  await page.getByTestId('pay-bill').click();
  await page.getByTestId('pay-confirm').click();
  await expect(page.getByTestId('bill-open')).toHaveText('0.00');

  // 10–11. Progress claim of 40% on the customer order, issued, and part paid.
  await page.goto('/customer-pos');
  await page.getByRole('link', { name: /^CPO-/ }).first().click();
  await page.getByTestId('bill-progress').click();
  await page.locator('.fixed input[name^=pct_]').first().fill('40');
  await page.getByTestId('bill-confirm').click();
  await page.waitForURL(/\/invoices\//);
  await expect(page.getByTestId('total')).toHaveText('SAR 46,000.00'); // 40,000 + VAT
  await page.getByTestId('issue').click();
  await page.getByTestId('confirm-issue').click();
  await expect(page.getByText(/INV-\d{4}-\d{5}/).first()).toBeVisible();
  await page.getByTestId('record-payment').click();
  await page.locator('.fixed input[type=number]').fill('20000');
  await page.locator('.fixed').getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('20,000.00').first()).toBeVisible();

  // 12. The project's financial position.
  await page.goto(projectHref!);
  await expect(page.getByTestId('sum-contract')).toHaveText('100,000.00');
  await expect(page.getByTestId('sum-committed')).toHaveText('14,400.00');   // 3 t × 4,800 still to come
  await expect(page.getByTestId('sum-actual')).toHaveText('24,000.00');      // 5 t × 4,800 received
  await expect(page.getByTestId('sum-remaining')).toHaveText('21,600.00');   // 60,000 − 24,000 − 14,400
  await expect(page.getByTestId('sum-gp')).toHaveText('40,000.00');          // 100,000 − 60,000 forecast
  await snap(page, 'project-financials');

  // Dashboards and the ledger.
  await page.getByRole('link', { name: 'PO Center' }).click();
  await page.locator('input[name=po_search]').fill(`ALN-PO-${stamp}`);
  await expect(page.getByTestId('po-center-orders')).toContainText('From customers');
  await snap(page, 'po-center');
  await page.goto('/accounting');
  await expect(page.getByTestId('trial-balance')).toContainText('Balanced');
  await expect(page.getByTestId('tb-debit')).toHaveText(await page.getByTestId('tb-credit').innerText());
  await snap(page, 'trial-balance');

  await setSelfApproval(page, false);
});
