import { expect, test, type Browser, type Page } from '@playwright/test';

async function loginAs(browser: Browser, email: string): Promise<Page> {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  page.on('pageerror', (e) => { throw e; });
  await page.goto('/');
  await page.getByTestId(`dev-login-${email}`).click();
  await expect(page.getByRole('button', { name: 'Sign out' })).toBeVisible();
  return page;
}

const apiAs = async (page: Page, path: string) => {
  const token = await page.evaluate(() => sessionStorage.getItem('rms.devToken'));
  const r = await page.request.get(`/api${path}`, { headers: { Authorization: `Bearer ${token}` } });
  expect(r.ok()).toBeTruthy();
  return r.json();
};

test('CRM to quotation to contract through the UI', async ({ browser }) => {
  const stamp = Date.now().toString().slice(-6);
  const customerName = `E2E Builders ${stamp}`;

  // 1. Sales creates a customer and an opportunity, then records the tender.
  const sales = await loginAs(browser, 'sales@reqaz.test');
  await sales.getByRole('link', { name: 'Customers' }).click();
  await sales.getByRole('button', { name: 'New customer' }).click();
  await sales.locator('input[name=name_en]').fill(customerName);
  await sales.locator('input[name=name_ar]').fill('شركة البنائين');
  await sales.locator('input[name=vat_number]').fill('123');
  await sales.getByRole('button', { name: 'Create' }).click();
  await expect(sales.getByRole('alert')).toContainText('15 digits');
  await sales.locator('input[name=vat_number]').fill(`3${stamp}00000003`.slice(0, 14) + '3');
  await sales.locator('input[name=city]').fill('Riyadh');
  await sales.getByRole('button', { name: 'Create' }).click();
  await expect(sales.getByRole('heading', { name: customerName })).toBeVisible();

  await sales.getByRole('link', { name: 'Pipeline' }).click();
  await sales.getByRole('button', { name: 'New opportunity' }).click();
  await sales.locator('input[name=title]').fill(`Showroom fit-out ${stamp}`);
  await sales.locator('select[name=customer_id]').selectOption({ label: `${customerName} — شركة البنائين` });
  await sales.locator('input[name=expected_value]').fill('1500000');
  await sales.getByRole('button', { name: 'Create' }).click();
  // Wait for the detail page itself: the new number also appears on the pipeline card before navigation finishes.
  await sales.waitForURL(/\/opportunities\/[0-9a-f-]{36}$/);
  await expect(sales.getByText(/OPP-\d{4}-\d{4}/).first()).toBeVisible();
  const oppUrl = sales.url();

  // Drag the card from New lead to Qualified on the Kanban board.
  await sales.getByRole('link', { name: 'Pipeline' }).click();
  const card = sales.locator('[data-testid^=opp-card]').filter({ hasText: `Showroom fit-out ${stamp}` });
  await expect(card).toBeVisible();
  const box = (await card.boundingBox())!;
  const target = (await sales.getByTestId('col-qualified').boundingBox())!;
  await sales.mouse.move(box.x + 20, box.y + box.height - 8);
  await sales.mouse.down();
  await sales.mouse.move(box.x + 60, box.y + 40, { steps: 5 });
  await sales.mouse.move(target.x + target.width / 2, target.y + 60, { steps: 15 });
  const moved = sales.waitForResponse((r) => r.request().method() === 'PATCH' && /\/api\/opportunities\//.test(r.url()));
  await sales.mouse.up();
  expect((await moved).ok()).toBe(true);
  await expect(sales.getByTestId('col-qualified').locator('[data-testid^=opp-card]').filter({ hasText: `Showroom fit-out ${stamp}` })).toBeVisible();

  await sales.goto(oppUrl);
  await expect(sales.getByRole('heading', { level: 1 }).getByText('Qualified')).toBeVisible();
  await sales.getByRole('button', { name: 'Record tender' }).click();
  await sales.locator('.fixed input[name=title]').fill('Showroom RFQ');
  await sales.locator('input[name=client_reference]').fill(`RFQ-${stamp}`);
  await sales.locator('input[name=submission_deadline]').fill('2026-12-15T12:00');
  await sales.getByRole('button', { name: 'Create' }).click();
  await expect(sales.getByText(/TND-\d{4}-\d{4}/)).toBeVisible();
  await expect(sales.getByText('Tender received').first()).toBeVisible();

  // 2. Estimator prices the quotation from templates and submits it for approval.
  const est = await loginAs(browser, 'estimator@reqaz.test');
  await est.goto(oppUrl);
  await est.getByRole('button', { name: 'New quotation' }).click();
  await est.locator('select[name=template_id]').selectOption({ label: 'Standard construction terms' });
  await est.getByRole('button', { name: 'Create' }).click();
  await expect(est.getByText(/QTN-\d{4}-\d{4}/).first()).toBeVisible();
  await est.getByLabel('Insert BOQ template').selectOption({ index: 1 });
  await expect(est.locator('[data-testid^=line-][data-testid$=-total]')).toHaveCount(7);
  await est.getByTestId('add-line').click();
  await expect(est.locator('[data-testid^=line-][data-testid$=-total]')).toHaveCount(8);
  await est.getByTestId('line-7-description_en').fill('Gypsum ceiling with access panels');
  await est.getByTestId('line-7-description_ar').fill('أسقف جبسية مع فتحات صيانة');
  await est.getByTestId('line-7-unit').fill('m2');
  await est.getByTestId('line-7-quantity').fill('420');
  await est.getByTestId('line-7-material_unit_cost').fill('48.5');
  await est.getByTestId('line-7-labour_unit_cost').fill('22');
  await est.getByTestId('line-7-labour_unit_cost').blur();
  await est.locator('input[name=markup_pct]').fill('18');
  await est.locator('input[name=markup_pct]').blur();
  await est.waitForLoadState('networkidle');

  // The on-screen total equals the server-calculated total.
  const qid = est.url().split('/quotations/')[1].split('?')[0];
  const quote = await apiAs(est, `/quotations/${qid}`);
  const rev = await apiAs(est, `/revisions/${quote.revisions[0].id}`);
  expect(rev.lines).toHaveLength(8);
  expect(rev.markup_pct).toBe('18.000');
  const fmt = (v: string) => Number(v).toLocaleString('en-US', { minimumFractionDigits: 2 });
  await expect(est.getByTestId('grand-total')).toHaveText(`SAR ${fmt(rev.total_amount)}`);
  await expect(est.getByTestId('vat')).toHaveText(fmt(rev.vat_amount));

  // Proposal content in Reqaz's format; milestones must reach 100% before approval.
  await est.locator('input[name=reference_prefix]').fill(`SHR/RUH-${stamp}-`);
  await est.locator('input[name=project_name]').fill('Showroom fit-out, ground floor');
  await est.locator('select[name=price_display]').selectOption('lump_sum_sections');
  await est.locator('textarea[name=cover_letter_en]').fill('We are pleased to submit our proposal.');
  await est.getByTestId('schedule-add').click();
  await est.getByTestId('schedule-0-label').fill('Milestone 1');
  await est.getByTestId('schedule-0-description').fill('Mobilisation and shop drawings');
  await est.getByTestId('schedule-0-duration').fill('10 days');
  await est.getByTestId('milestones-add').click();
  await est.getByTestId('milestones-0-description').fill('Advance payment');
  await est.getByTestId('milestones-0-percent').fill('30');
  await est.getByTestId('milestones-add').click();
  await est.getByTestId('milestones-1-description').fill('On completion');
  await est.getByTestId('milestones-1-percent').fill('60');
  await expect(est.getByTestId('milestones-total')).toHaveText('90%');
  await est.getByTestId('save-proposal').click();
  await expect(est.getByText('Saved').first()).toBeVisible();
  await est.getByRole('button', { name: 'Submit for approval' }).click();
  await expect(est.getByText(/100/).first()).toBeVisible();
  await expect(est.getByTestId('rev-status')).toHaveText('Draft');
  await est.getByTestId('milestones-1-percent').fill('70');
  await expect(est.getByTestId('milestones-total')).toHaveText('100%');
  await est.getByTestId('save-proposal').click();
  await est.waitForLoadState('networkidle');
  const saved = await apiAs(est, `/revisions/${quote.revisions[0].id}`);
  expect(saved.reference).toBe(`SHR/RUH-${stamp}-R00`);
  expect(saved.payment_milestones.map((m: any) => m.percent)).toEqual([30, 70]);

  await est.getByRole('button', { name: 'Submit for approval' }).click();
  await expect(est.getByTestId('rev-status')).toHaveText('Pending approval');
  await expect(est.getByRole('button', { name: 'Approve' })).toHaveCount(0); // estimators cannot approve
  await expect(est.getByTestId('line-0-quantity')).toHaveCount(0); // grid is locked

  // 3. General manager rejects once, estimator fixes, GM approves.
  const gm = await loginAs(browser, 'gm@reqaz.test');
  await expect(gm.getByText(quote.number).first()).toBeVisible(); // dashboard: awaiting approval
  await gm.getByText(quote.number).first().click();
  await gm.getByRole('button', { name: 'Reject' }).click();
  await gm.locator('textarea[name=reject_comment]').fill('Add 3% discount for this client');
  await gm.locator('.fixed').getByRole('button', { name: 'Reject' }).click();
  await expect(gm.getByTestId('rev-status')).toHaveText('Draft');

  await est.reload();
  await est.locator('select[name=discount_type]').selectOption('percent');
  await est.locator('input[name=discount_value]').fill('3');
  await est.locator('input[name=discount_value]').blur();
  await est.waitForLoadState('networkidle');
  await est.getByRole('button', { name: 'Submit for approval' }).click();
  await expect(est.getByTestId('rev-status')).toHaveText('Pending approval');

  await gm.reload();
  await gm.getByRole('button', { name: 'Approve' }).click();
  await expect(gm.getByTestId('rev-status')).toHaveText('Approved');
  await expect(gm.getByText('Add 3% discount for this client')).toBeVisible();

  // 4. Sales records the quotation as sent; the final PDF is archived.
  await sales.goto(`/quotations/${qid}`);
  await sales.getByRole('button', { name: 'Record as sent to client' }).click();
  await expect(sales.getByTestId('rev-status')).toHaveText('Submitted to client');
  const dl = sales.waitForEvent('download');
  await sales.getByRole('button', { name: 'PDF sent to client' }).click();
  expect((await dl).suggestedFilename()).toBe(`SHR-RUH-${stamp}-R00.pdf`);

  // 5. GM awards: contract + project are created and the deal shows as won.
  await gm.reload();
  await gm.getByRole('button', { name: /Award/ }).click();
  await gm.locator('select[name=project_manager_id]').selectOption({ label: 'Faisal Project Manager' });
  await gm.locator('input[name=start_date]').fill('2027-01-03');
  await gm.locator('input[name=target_completion_date]').fill('2027-06-30');
  await gm.locator('.fixed').getByRole('button', { name: 'Confirm' }).click();
  await expect(gm.getByText(/CON-\d{4}-\d{3}/)).toBeVisible();
  await expect(gm.getByText('Won').first()).toBeVisible();
  const awarded = await apiAs(gm, `/revisions/${rev.id}`);
  expect(awarded.status).toBe('awarded');
  expect(Number(awarded.discount_amount)).toBeGreaterThan(0);

  const pm = await loginAs(browser, 'pm@reqaz.test');
  await pm.getByRole('link', { name: 'Contracts & projects' }).click();
  await expect(pm.getByText(`Showroom fit-out ${stamp}`).first()).toBeVisible();

  // 6. Arabic interface switches to right-to-left.
  await gm.getByRole('button', { name: 'العربية' }).click();
  await expect(gm.locator('html')).toHaveAttribute('dir', 'rtl');
  await expect(gm.getByRole('heading', { name: 'جدول الكميات' })).toBeVisible();
  await expect(gm.getByText('الإجمالي شامل الضريبة')).toBeVisible();
  await gm.screenshot({ path: 'test-results/quotation-ar.png', fullPage: true });
  await gm.getByRole('button', { name: 'English' }).click();
  await expect(gm.locator('html')).toHaveAttribute('dir', 'ltr');
});

test('a quotation can be started from the Quotations page', async ({ browser }) => {
  const stamp = Date.now().toString().slice(-6);
  const est = await loginAs(browser, 'sales@reqaz.test');
  await est.getByRole('link', { name: 'Quotations' }).click();
  await est.getByRole('button', { name: 'New quotation' }).click();
  await est.locator('.fixed select[name=customer_id]').selectOption({ label: 'Al Noor Real Estate Development — شركة النور للتطوير العقاري' });
  await expect(est.locator('select[name=opportunity_id]')).toHaveValue('new');
  await est.locator('input[name=quote_title]').fill(`Villa extension ${stamp}`);
  await est.getByRole('button', { name: 'Create' }).click();
  await est.waitForURL(/\/quotations\/[0-9a-f-]{36}/);
  await expect(est.getByText(/QTN-\d{4}-\d{4}/).first()).toBeVisible();
  // A new opportunity for the customer was opened alongside it.
  const qid = est.url().split('/quotations/')[1].split('?')[0];
  const quote = await apiAs(est, `/quotations/${qid}`);
  expect(quote.customer_name).toBe('Al Noor Real Estate Development');
  expect(quote.opportunity_title).toBe(`Villa extension ${stamp}`);

  // An estimator cannot open opportunities, so the dialog offers the customer's open ones instead.
  const est2 = await loginAs(browser, 'estimator@reqaz.test');
  await est2.getByRole('link', { name: 'Quotations' }).click();
  await est2.getByRole('button', { name: 'New quotation' }).click();
  await est2.locator('.fixed select[name=customer_id]').selectOption({ label: 'Al Noor Real Estate Development — شركة النور للتطوير العقاري' });
  await expect(est2.locator('select[name=opportunity_id] option', { hasText: 'New opportunity' })).toHaveCount(0);
  await est2.locator('select[name=opportunity_id]').selectOption({ label: `${quote.opportunity_number} — Villa extension ${stamp}` });
  await est2.locator('input[name=quote_title]').fill(`Villa extension option B ${stamp}`);
  await est2.getByRole('button', { name: 'Create' }).click();
  await est2.waitForURL(/\/quotations\/[0-9a-f-]{36}/);
  await expect(est2.getByText(`Villa extension option B ${stamp}`).first()).toBeVisible();
});

test('site engineers cannot reach sales screens', async ({ browser }) => {
  const site = await loginAs(browser, 'site@reqaz.test');
  await expect(site.getByRole('link', { name: 'Customers' })).toHaveCount(0);
  await expect(site.getByRole('link', { name: 'Quotations' })).toHaveCount(0);
  await site.goto('/customers');
  await expect(site.getByText('You do not have access to this page.')).toBeVisible();
  // Even calling the API directly returns nothing.
  const data = await apiAs(site, '/customers');
  expect(data).toEqual([]);
});
