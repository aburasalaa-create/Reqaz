-- RMS open access: a small team works without role restrictions.
-- With company_settings.open_access on (the default), every active user holds every permission except the admin ones
-- (users, company settings, audit log), and people may approve their own quotations and purchase requests.
-- Turning it off falls back to the role permissions. Legal locks (issued invoices, document numbers) never change.

alter table public.company_settings add column open_access boolean not null default true;
alter table public.company_settings alter column allow_self_approval set default true;
update public.company_settings set open_access = true, allow_self_approval = true;

create or replace function public.admin_only_permission(p_code text) returns boolean
language sql immutable as $$
  select p_code in ('users.manage', 'settings.manage', 'audit.read')
$$;

create or replace function public.has_permission(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.app_users u
    where u.id = auth.uid()
      and u.is_active
      and (
        (not public.admin_only_permission(p_code)
         and coalesce((select open_access from public.company_settings), false)
         and exists (select 1 from public.permissions p where p.code = p_code))
        or exists (select 1 from public.user_roles ur join public.role_permissions rp on rp.role_id = ur.role_id
                   where ur.user_id = u.id and rp.permission_code = p_code)
      )
  )
$$;

create or replace function public.current_permissions() returns setof text
language sql stable security definer set search_path = public as $$
  select rp.permission_code
  from public.app_users u
  join public.user_roles ur on ur.user_id = u.id
  join public.role_permissions rp on rp.role_id = ur.role_id
  where u.id = auth.uid() and u.is_active
  union
  select p.code
  from public.permissions p, public.app_users u
  where u.id = auth.uid() and u.is_active
    and not public.admin_only_permission(p.code)
    and coalesce((select open_access from public.company_settings), false)
$$;
