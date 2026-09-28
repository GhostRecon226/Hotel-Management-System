-- HMS 0001: platform, tenancy, identity, permissions, audit.
-- Rules this file establishes:
--   * every tenant-owned row carries tenant_id (and property_id where property-scoped)
--   * isolation is enforced by row-level security, not only by application code
--   * helper functions live in schema "app" (not exposed by the API); callable RPCs live in "public"

create extension if not exists btree_gist with schema extensions;
create schema if not exists app;
grant usage on schema app to anon, authenticated, service_role;

-- ---------------------------------------------------------------- errors
-- Error message convention: '[E_CODE] human text'. The UI can branch on the code.
create or replace function app.fail(p_code text, p_msg text) returns void
language plpgsql as $$
begin
  raise exception '[%] %', p_code, p_msg using errcode = 'P0001';
end $$;

-- ---------------------------------------------------------------- platform
create table public.plans (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique,
  name           text not null,
  max_rooms      int,            -- null = unlimited
  max_properties int,
  max_users      int,
  price_ngn      numeric(14,2),  -- null = not priced yet (assumption A16)
  price_usd      numeric(14,2),
  trial_days     int not null default 30,
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);

create table public.tenants (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  slug          text not null unique,
  country_code  char(2) not null,
  base_currency text not null,
  created_at    timestamptz not null default now()
);

create table public.tenant_subscriptions (
  tenant_id          uuid primary key references public.tenants(id) on delete cascade,
  plan_id            uuid not null references public.plans(id),
  status             text not null check (status in
                       ('trial','active','past_due','suspended','expired','cancelled','closed')),
  trial_ends_at      timestamptz,
  current_period_end timestamptz,
  cancel_at          timestamptz,
  updated_at         timestamptz not null default now()
);

create table public.subscription_events (
  id           bigint generated always as identity primary key,
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  from_status  text,
  to_status    text not null,
  trigger      text not null,
  actor_id     uuid,
  reason       text,
  occurred_at  timestamptz not null default now()
);

-- Sign-up uses Supabase Auth for email verification. A verified user calls public.create_hotel (0009).

-- ---------------------------------------------------------------- permissions
create table public.permissions (
  key         text primary key,
  module      text not null,
  release     text not null,
  description text not null,
  sensitive   boolean not null default false
);

create table public.roles (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references public.tenants(id) on delete cascade,  -- null = system role
  code        text not null,
  name        text not null,
  description text,
  first_release text,
  is_system   boolean not null default false,
  created_at  timestamptz not null default now(),
  unique nulls not distinct (tenant_id, code),
  check ((is_system and tenant_id is null) or (not is_system and tenant_id is not null))
);

create table public.role_permissions (
  role_id        uuid not null references public.roles(id) on delete cascade,
  permission_key text not null references public.permissions(key),
  grant_level    text not null check (grant_level in ('Y','L','O')),
  primary key (role_id, permission_key)
);

create table public.platform_staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role_id uuid not null references public.roles(id)
);

-- ---------------------------------------------------------------- tenant structure
create table public.properties (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  name             text not null,
  code             text not null,                     -- short prefix for document numbers
  address          text,
  city             text,
  country_code     char(2) not null,
  timezone         text not null,
  base_currency    text not null,
  business_date    date not null,                     -- the open business date
  rollover_time    time not null default '03:00',     -- local cut-off after which the date rolls
  inspection_required boolean not null default true,  -- assumption A9
  stayover_service boolean not null default true,
  settings         jsonb not null default '{}',
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  tenant_id  uuid references public.tenants(id) on delete cascade,   -- null for platform staff
  full_name  text not null,
  email      text,
  phone      text,
  status     text not null default 'active' check (status in ('active','disabled')),
  created_at timestamptz not null default now()
);
create index on public.profiles (tenant_id);

create table public.user_property_roles (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  property_id uuid,                                   -- null = every property in the tenant
  role_id     uuid not null references public.roles(id),
  created_by  uuid,
  created_at  timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  unique nulls not distinct (user_id, property_id, role_id)
);
create index on public.user_property_roles (user_id);

-- Limit for 'L' grants. No row means limit 0, so the action always needs approval (assumption A6).
create table public.approval_limits (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  property_id    uuid,
  role_id        uuid not null references public.roles(id),
  permission_key text not null references public.permissions(key),
  max_amount     numeric(20,4) not null check (max_amount >= 0),   -- in property base currency
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  unique nulls not distinct (tenant_id, property_id, role_id, permission_key)
);

-- ---------------------------------------------------------------- audit
create table public.audit_events (
  id           bigint generated always as identity primary key,
  tenant_id    uuid,
  property_id  uuid,
  actor_id     uuid,
  occurred_at  timestamptz not null default now(),
  action       text not null,
  entity_table text,
  entity_id    uuid,
  before_data  jsonb,
  after_data   jsonb,
  reason       text,
  meta         jsonb
);
create index on public.audit_events (tenant_id, occurred_at desc);
create index on public.audit_events (entity_table, entity_id);

create or replace function app.block_mutation() returns trigger language plpgsql as $$
begin
  perform app.fail('E_IMMUTABLE', format('%s rows cannot be changed or deleted (%s)', tg_table_name, tg_op));
  return null;
end $$;

create trigger audit_events_immutable
  before update or delete on public.audit_events
  for each row execute function app.block_mutation();
create trigger audit_events_no_truncate
  before truncate on public.audit_events
  for each statement execute function app.block_mutation();

-- ---------------------------------------------------------------- helpers
create or replace function app.uid() returns uuid language sql stable as $$ select auth.uid() $$;

-- True when the call comes from the platform itself (Edge Function with service role, or pg_cron), not a user.
create or replace function app.is_service() returns boolean language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), '') = 'service_role'
      or (auth.uid() is null and session_user in ('postgres', 'supabase_admin'))
$$;

create or replace function app.my_tenant() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select tenant_id from public.profiles where id = auth.uid() and status = 'active'
$$;

create or replace function app.is_platform_staff() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.platform_staff where user_id = auth.uid())
$$;

create or replace function app.platform_can(p_key text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.platform_staff ps
    join public.role_permissions rp on rp.role_id = ps.role_id
    where ps.user_id = auth.uid() and rp.permission_key = p_key)
$$;

create or replace function app.property_tenant(p_property uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select tenant_id from public.properties where id = p_property
$$;

-- Best grant level ('Y' > 'L' > 'O') the current user holds for a permission at a property, or null.
create or replace function app.grant_level(p_property uuid, p_key text) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select rp.grant_level
  from public.user_property_roles upr
  join public.profiles pr on pr.id = upr.user_id and pr.status = 'active'
  join public.role_permissions rp on rp.role_id = upr.role_id
  join public.properties p on p.id = p_property and p.tenant_id = upr.tenant_id
  where upr.user_id = auth.uid()
    and rp.permission_key = p_key
    and (upr.property_id is null or upr.property_id = p_property)
  order by case rp.grant_level when 'Y' then 3 when 'L' then 2 else 1 end desc
  limit 1
$$;

create or replace function app.can(p_property uuid, p_key text) returns boolean
language sql stable as $$ select app.grant_level(p_property, p_key) is not null $$;

-- Tenant-wide permission (assignment with property_id null).
create or replace function app.tenant_can(p_key text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.user_property_roles upr
    join public.profiles pr on pr.id = upr.user_id and pr.status = 'active'
    join public.role_permissions rp on rp.role_id = upr.role_id
    where upr.user_id = auth.uid() and upr.property_id is null and rp.permission_key = p_key)
$$;

create or replace function app.has_property_access(p_property uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.user_property_roles upr
    join public.profiles pr on pr.id = upr.user_id and pr.status = 'active'
    join public.properties p on p.id = p_property and p.tenant_id = upr.tenant_id
    where upr.user_id = auth.uid() and (upr.property_id is null or upr.property_id = p_property))
$$;

-- Approval limit for an 'L' grant, in base currency. 'Y' = unlimited (null). No row = 0.
create or replace function app.approval_limit(p_property uuid, p_key text) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_level text; v_limit numeric;
begin
  v_level := app.grant_level(p_property, p_key);
  if v_level is null then return -1; end if;   -- no access at all
  if v_level = 'Y' then return null; end if;   -- unlimited
  select max(al.max_amount) into v_limit
  from public.approval_limits al
  join public.user_property_roles upr on upr.role_id = al.role_id and upr.user_id = auth.uid()
  where al.permission_key = p_key
    and al.tenant_id = app.property_tenant(p_property)
    and (al.property_id is null or al.property_id = p_property)
    and (upr.property_id is null or upr.property_id = p_property);
  return coalesce(v_limit, 0);
end $$;

-- Raises unless the current user holds the permission (any level) at the property.
create or replace function app.require(p_property uuid, p_key text) returns text
language plpgsql stable as $$
declare v text;
begin
  v := app.grant_level(p_property, p_key);
  if v is null then
    perform app.fail('E_PERM', format('You do not have permission: %s', p_key));
  end if;
  return v;
end $$;

create or replace function app.require_tenant(p_key text) returns void
language plpgsql stable as $$
begin
  if not app.tenant_can(p_key) then
    perform app.fail('E_PERM', format('You do not have permission: %s', p_key));
  end if;
end $$;

create or replace function app.audit(
  p_tenant uuid, p_property uuid, p_action text, p_table text, p_id uuid,
  p_before jsonb default null, p_after jsonb default null, p_reason text default null, p_meta jsonb default null
) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.audit_events (tenant_id, property_id, actor_id, action, entity_table, entity_id, before_data, after_data, reason, meta)
  values (p_tenant, p_property, auth.uid(), p_action, p_table, p_id, p_before, p_after, p_reason, p_meta)
$$;

-- Generic row-change audit for configuration tables. Reason comes from the session setting app.reason if the API sets it.
create or replace function app.audit_change() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_new jsonb; v_old jsonb; v_tenant uuid; v_prop uuid; v_id uuid;
begin
  v_old := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_new := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
  v_tenant := coalesce((v_new->>'tenant_id')::uuid, (v_old->>'tenant_id')::uuid);
  v_prop   := nullif(coalesce(v_new->>'property_id', v_old->>'property_id'), '')::uuid;
  v_id     := nullif(coalesce(v_new->>'id', v_old->>'id'), '')::uuid;
  insert into public.audit_events (tenant_id, property_id, actor_id, action, entity_table, entity_id, before_data, after_data, reason)
  values (v_tenant, v_prop, auth.uid(), lower(tg_op), tg_table_name, v_id, v_old, v_new, nullif(current_setting('app.reason', true), ''));
  return coalesce(new, old);
end $$;

-- ---------------------------------------------------------------- subscription state
create or replace function app.tenant_status(p_tenant uuid) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select status from public.tenant_subscriptions where tenant_id = p_tenant
$$;

-- Read-only tenants (expired, suspended, cancelled past period end, closed) cannot write,
-- except that in-house guests can still be checked out and settled (p_allow_settlement).
create or replace function app.assert_writable(p_tenant uuid, p_allow_settlement boolean default false) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.tenant_subscriptions;
begin
  select * into s from public.tenant_subscriptions where tenant_id = p_tenant;
  if not found then return; end if;
  if s.status in ('trial','active','past_due') then return; end if;
  if s.status = 'cancelled' and s.cancel_at is not null and s.cancel_at > now() then return; end if;
  if p_allow_settlement then return; end if;
  perform app.fail('E_READ_ONLY', format('This account is read-only (%s). Contact your administrator.', s.status));
end $$;

create or replace function app.tenant_writable(p_tenant uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.tenant_subscriptions;
begin
  select * into s from public.tenant_subscriptions where tenant_id = p_tenant;
  if not found then return true; end if;
  return s.status in ('trial','active','past_due')
      or (s.status = 'cancelled' and s.cancel_at is not null and s.cancel_at > now());
end $$;

-- ---------------------------------------------------------------- RLS
alter table public.plans                enable row level security;
alter table public.tenants              enable row level security;
alter table public.tenant_subscriptions enable row level security;
alter table public.subscription_events  enable row level security;
alter table public.permissions          enable row level security;
alter table public.roles                enable row level security;
alter table public.role_permissions     enable row level security;
alter table public.platform_staff       enable row level security;
alter table public.properties           enable row level security;
alter table public.profiles             enable row level security;
alter table public.user_property_roles  enable row level security;
alter table public.approval_limits      enable row level security;
alter table public.audit_events         enable row level security;

create policy plans_read on public.plans for select to authenticated using (true);

create policy tenants_read on public.tenants for select to authenticated
  using (id = app.my_tenant() or app.platform_can('platform.tenant.manage'));
create policy subs_read on public.tenant_subscriptions for select to authenticated
  using (tenant_id = app.my_tenant() or app.platform_can('platform.tenant.manage'));
create policy subevents_read on public.subscription_events for select to authenticated
  using (tenant_id = app.my_tenant() or app.platform_can('platform.tenant.manage'));

create policy permissions_read on public.permissions for select to authenticated using (true);

create policy roles_read on public.roles for select to authenticated
  using (tenant_id is null or tenant_id = app.my_tenant());
create policy roles_write_ins on public.roles for insert to authenticated
  with check (tenant_id = app.my_tenant() and not is_system and app.tenant_can('adm.role.manage') and app.tenant_writable(tenant_id));
create policy roles_write_upd on public.roles for update to authenticated
  using (tenant_id = app.my_tenant() and not is_system and app.tenant_can('adm.role.manage') and app.tenant_writable(tenant_id))
  with check (tenant_id = app.my_tenant() and not is_system);
create policy roles_write_del on public.roles for delete to authenticated
  using (tenant_id = app.my_tenant() and not is_system and app.tenant_can('adm.role.manage') and app.tenant_writable(tenant_id));

create policy role_perms_read on public.role_permissions for select to authenticated
  using (exists (select 1 from public.roles r where r.id = role_id and (r.tenant_id is null or r.tenant_id = app.my_tenant())));
create policy role_perms_write_ins on public.role_permissions for insert to authenticated
  with check (exists (select 1 from public.roles r where r.id = role_id and r.tenant_id = app.my_tenant() and not r.is_system)
              and app.tenant_can('adm.role.manage'));
create policy role_perms_write_upd on public.role_permissions for update to authenticated
  using (exists (select 1 from public.roles r where r.id = role_id and r.tenant_id = app.my_tenant() and not r.is_system)
         and app.tenant_can('adm.role.manage'));
create policy role_perms_write_del on public.role_permissions for delete to authenticated
  using (exists (select 1 from public.roles r where r.id = role_id and r.tenant_id = app.my_tenant() and not r.is_system)
         and app.tenant_can('adm.role.manage'));

create policy platform_staff_self on public.platform_staff for select to authenticated using (user_id = auth.uid());

create policy properties_read on public.properties for select to authenticated
  using (app.has_property_access(id));
create policy properties_update on public.properties for update to authenticated
  using (app.can(id, 'setup.property.manage') and app.tenant_writable(tenant_id))
  with check (app.can(id, 'setup.property.manage'));

create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or tenant_id = app.my_tenant() and (app.tenant_can('adm.user.manage') or app.tenant_can('adm.role.assign')));
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy upr_read on public.user_property_roles for select to authenticated
  using (user_id = auth.uid() or tenant_id = app.my_tenant() and (app.tenant_can('adm.user.manage') or app.tenant_can('adm.role.assign')));

create policy limits_read on public.approval_limits for select to authenticated
  using (tenant_id = app.my_tenant() and app.tenant_can('adm.config.manage'));
create policy limits_write_ins on public.approval_limits for insert to authenticated
  with check (tenant_id = app.my_tenant() and app.tenant_can('adm.config.manage') and app.tenant_writable(tenant_id));
create policy limits_write_upd on public.approval_limits for update to authenticated
  using (tenant_id = app.my_tenant() and app.tenant_can('adm.config.manage') and app.tenant_writable(tenant_id));
create policy limits_write_del on public.approval_limits for delete to authenticated
  using (tenant_id = app.my_tenant() and app.tenant_can('adm.config.manage') and app.tenant_writable(tenant_id));

-- Audit log: GM, System Administrator, Accountant see their tenant's events. Platform staff see platform events only (tenant_id null).
create policy audit_read on public.audit_events for select to authenticated
  using ((tenant_id is not null and tenant_id = app.my_tenant() and app.tenant_can('adm.audit.view'))
      or (tenant_id is null and app.platform_can('platform.audit.view')));

create trigger properties_audit after insert or update or delete on public.properties
  for each row execute function app.audit_change();
create trigger user_property_roles_audit after insert or update or delete on public.user_property_roles
  for each row execute function app.audit_change();
create trigger approval_limits_audit after insert or update or delete on public.approval_limits
  for each row execute function app.audit_change();
create trigger roles_audit after insert or update or delete on public.roles
  for each row execute function app.audit_change();
-- role_permissions has no id or tenant_id column, so it gets its own audit function.
create or replace function app.audit_change_rp() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_role uuid; v_tenant uuid;
begin
  v_role := coalesce(new.role_id, old.role_id);
  select tenant_id into v_tenant from public.roles where id = v_role;
  insert into public.audit_events (tenant_id, actor_id, action, entity_table, entity_id, before_data, after_data, reason)
  values (v_tenant, auth.uid(), lower(tg_op), 'role_permissions', v_role,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end,
          nullif(current_setting('app.reason', true), ''));
  return coalesce(new, old);
end $$;
create trigger role_permissions_audit after insert or update or delete on public.role_permissions
  for each row execute function app.audit_change_rp();

-- No privilege escalation: a tenant admin can only put a permission into a custom role if they hold it themselves.
create or replace function app.role_perm_no_escalation() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tenant uuid; v_ok boolean;
begin
  if app.is_service() then return new; end if;
  select tenant_id into v_tenant from public.roles where id = new.role_id;
  -- system roles are seeded by migrations; users cannot write to them (row-level security)
  if v_tenant is null then return new; end if;
  select exists (
    select 1 from public.user_property_roles upr
    join public.role_permissions rp on rp.role_id = upr.role_id
    where upr.user_id = auth.uid() and upr.tenant_id = v_tenant and rp.permission_key = new.permission_key
  ) into v_ok;
  if not v_ok then
    perform app.fail('E_ESCALATION', format('You cannot grant a permission you do not hold: %s', new.permission_key));
  end if;
  return new;
end $$;
create trigger role_permissions_no_escalation before insert or update on public.role_permissions
  for each row execute function app.role_perm_no_escalation();
