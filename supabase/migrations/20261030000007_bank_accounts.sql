-- Company bank accounts: Reqaz banks with more than one bank, and invoices print all accounts marked for invoices.
alter table public.company_settings add column bank_accounts jsonb not null default '[]'::jsonb
  check (jsonb_typeof(bank_accounts) = 'array');

update public.company_settings
   set bank_accounts = jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
         'bank_name', bank_name, 'account_name', bank_account_name, 'iban', bank_iban, 'show_on_invoices', true)))
 where bank_iban is not null;

alter table public.company_settings drop column bank_name, drop column bank_iban, drop column bank_account_name;
