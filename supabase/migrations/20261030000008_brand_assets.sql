-- Company brand assets held in the database, not in the code repository (a stamp image in a public repo could be misused).
-- 'stamp' is printed only on issued invoices and notes.
create table public.brand_assets (
  code text primary key check (code in ('stamp')),
  mime_type text not null check (mime_type in ('image/png', 'image/jpeg')),
  data bytea not null check (octet_length(data) <= 1048576),
  sha256 text not null,
  uploaded_by uuid references public.app_users (id) default auth.uid(),
  uploaded_at timestamptz not null default now()
);

create or replace function public.brand_assets_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.log_event('brand_assets', coalesce(new.code, old.code), lower(tg_op),
    case when tg_op = 'DELETE' then null else jsonb_build_object('sha256', new.sha256, 'bytes', octet_length(new.data)) end);
  return null;
end $$;
create trigger brand_assets_audit after insert or update or delete on public.brand_assets
  for each row execute function public.brand_assets_audit();

grant select, insert, update, delete on public.brand_assets to authenticated;
grant all on public.brand_assets to service_role;
alter table public.brand_assets enable row level security;
-- Read by anyone who can read invoices (needed to render issued invoice PDFs); changed only by settings managers.
create policy brand_assets_select on public.brand_assets for select to authenticated
  using (public.has_permission('invoices.read') or public.has_permission('settings.manage'));
create policy brand_assets_write on public.brand_assets for all to authenticated
  using (public.has_permission('settings.manage')) with check (public.has_permission('settings.manage'));
