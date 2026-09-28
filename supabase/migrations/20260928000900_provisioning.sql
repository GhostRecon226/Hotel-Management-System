-- HMS 0009: hotel signup, provisioning, plan limits, subscription transitions, user and role administration.
-- Sign-up flow (R1): the person signs up with Supabase Auth (email verification is Supabase's).
-- Then the app calls public.create_hotel(). Billing integration is R1b; until then Peter activates pilots by hand.

-- ---------------------------------------------------------------- profile for every auth user
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id, coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)), new.email)
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function app.handle_new_user();

-- ---------------------------------------------------------------- helpers
create or replace function app.local_business_date(p_tz text, p_rollover time) returns date
language sql stable as $$ select ((now() at time zone p_tz) - p_rollover::interval)::date $$;

create or replace function app.log_subscription_event(p_tenant uuid, p_from text, p_to text, p_trigger text, p_reason text) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.subscription_events (tenant_id, from_status, to_status, trigger, actor_id, reason)
  values (p_tenant, p_from, p_to, p_trigger, auth.uid(), p_reason)
$$;

-- Copies the country template into a new property. Every seeded tax line starts unverified.
create or replace function app.seed_property_defaults(p_property uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.properties; t public.country_templates; x jsonb;
begin
  select * into p from public.properties where id = p_property;
  select * into t from public.country_templates where country_code = p.country_code;
  if not found then select * into t from public.country_templates where country_code = 'ZZ'; end if;
  for x in select * from jsonb_array_elements(t.tax_lines) loop
    insert into public.tax_rates (tenant_id, property_id, code, name, rate, calc_base, seq, applies_to, verified)
    values (p.tenant_id, p.id, x ->> 'code', x ->> 'name', (x ->> 'rate')::numeric, coalesce(x ->> 'calc_base', 'net'),
            coalesce((x ->> 'seq')::int, 1),
            coalesce(array(select jsonb_array_elements_text(x -> 'applies_to')), '{room,fnb,other}'),
            coalesce((x ->> 'verified')::boolean, false))
    on conflict do nothing;
  end loop;
  for x in select * from jsonb_array_elements(t.payment_methods) loop
    insert into public.payment_methods (tenant_id, property_id, code, name, kind)
    values (p.tenant_id, p.id, x ->> 'code', x ->> 'name', x ->> 'kind') on conflict do nothing;
  end loop;
  for x in select * from jsonb_array_elements(t.charge_codes) loop
    insert into public.charge_codes (tenant_id, property_id, code, name, revenue_group, taxable, is_system)
    values (p.tenant_id, p.id, x ->> 'code', x ->> 'name', x ->> 'revenue_group', coalesce((x ->> 'taxable')::boolean, true),
            coalesce((x ->> 'is_system')::boolean, false)) on conflict do nothing;
  end loop;
  -- the engine needs these three whatever the template says
  insert into public.charge_codes (tenant_id, property_id, code, name, revenue_group, taxable, is_system) values
    (p.tenant_id, p.id, 'ROOM',       'Room charge',      'room', true,  true),
    (p.tenant_id, p.id, 'FEE_CXL',    'Cancellation fee', 'fee',  false, true),
    (p.tenant_id, p.id, 'FEE_NOSHOW', 'No-show fee',      'fee',  false, true)
  on conflict do nothing;
end $$;

create or replace function app.new_property(
  p_tenant uuid, p_name text, p_country text, p_city text, p_address text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.country_templates; v_id uuid; v_code text; v_n int; v_roll time := '03:00';
begin
  select * into t from public.country_templates where country_code = p_country;
  if not found then select * into t from public.country_templates where country_code = 'ZZ'; end if;
  select count(*) + 1 into v_n from public.properties where tenant_id = p_tenant;
  v_code := coalesce(nullif(upper(left(regexp_replace(p_name, '[^A-Za-z]', '', 'g'), 3)), ''), 'HTL') || v_n;
  insert into public.properties (tenant_id, name, code, city, address, country_code, timezone, base_currency, business_date, rollover_time)
  values (p_tenant, p_name, v_code, p_city, p_address, p_country, t.timezone, t.currency,
          app.local_business_date(t.timezone, v_roll), v_roll)
  returning id into v_id;
  perform app.seed_property_defaults(v_id);
  return v_id;
end $$;

-- ---------------------------------------------------------------- provisioning
create or replace function app.provision_tenant(
  p_user uuid, p_business_name text, p_country text, p_property_name text, p_plan_code text default 'starter',
  p_city text default null, p_full_name text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  t public.country_templates; v_tenant uuid; v_slug text; v_plan public.plans; v_prop uuid; v_role uuid; r text;
begin
  select * into t from public.country_templates where country_code = p_country;
  if not found then select * into t from public.country_templates where country_code = 'ZZ'; end if;
  select * into v_plan from public.plans where code = p_plan_code and active;
  if not found then perform app.fail('E_PLAN', 'Plan not found.'); end if;
  v_slug := trim(both '-' from lower(regexp_replace(p_business_name, '[^A-Za-z0-9]+', '-', 'g')));
  if v_slug = '' then v_slug := 'hotel'; end if;
  if exists (select 1 from public.tenants where slug = v_slug) then
    v_slug := v_slug || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 5);
  end if;
  insert into public.tenants (name, slug, country_code, base_currency) values (p_business_name, v_slug, p_country, t.currency)
  returning id into v_tenant;
  insert into public.tenant_subscriptions (tenant_id, plan_id, status, trial_ends_at)
  values (v_tenant, v_plan.id, 'trial', now() + make_interval(days => v_plan.trial_days));
  insert into public.subscription_events (tenant_id, from_status, to_status, trigger, actor_id, reason)
  values (v_tenant, null, 'trial', 'signup', p_user, 'Self-service signup');
  update public.profiles set tenant_id = v_tenant, full_name = coalesce(nullif(btrim(p_full_name), ''), full_name) where id = p_user;
  v_prop := app.new_property(v_tenant, p_property_name, p_country, p_city, null);
  foreach r in array array['SYS','GM'] loop
    select id into v_role from public.roles where tenant_id is null and code = r;
    insert into public.user_property_roles (tenant_id, user_id, property_id, role_id, created_by)
    values (v_tenant, p_user, null, v_role, p_user);
  end loop;
  perform app.audit(v_tenant, v_prop, 'tenant.provision', 'tenants', v_tenant, null,
                    jsonb_build_object('plan', p_plan_code, 'country', p_country), null, null);
  return jsonb_build_object('tenant_id', v_tenant, 'property_id', v_prop);
end $$;

create or replace function public.create_hotel(
  p_business_name text, p_country text, p_property_name text, p_full_name text default null,
  p_city text default null, p_plan_code text default 'starter')
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_confirmed timestamptz; pr public.profiles;
begin
  if v_uid is null then perform app.fail('E_AUTH', 'Sign in first.'); end if;
  select email_confirmed_at into v_confirmed from auth.users where id = v_uid;
  if v_confirmed is null then perform app.fail('E_EMAIL_UNVERIFIED', 'Confirm your email address first.'); end if;
  select * into pr from public.profiles where id = v_uid for update;
  if not found then perform app.fail('E_AUTH', 'Profile not found.'); end if;
  if pr.tenant_id is not null then perform app.fail('E_ALREADY_HAS_HOTEL', 'This account already belongs to a hotel.'); end if;
  if coalesce(btrim(p_business_name), '') = '' or coalesce(btrim(p_property_name), '') = '' then
    perform app.fail('E_ARG', 'Business name and property name are required.');
  end if;
  return app.provision_tenant(v_uid, btrim(p_business_name), upper(p_country), btrim(p_property_name), p_plan_code, p_city, p_full_name);
end $$;

create or replace function public.create_property(p_name text, p_country text default null, p_city text default null, p_address text default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tenant uuid := app.my_tenant(); v_country text; v_id uuid;
begin
  if v_tenant is null then perform app.fail('E_PERM', 'No hotel account.'); end if;
  perform app.require_tenant('org.property.create');
  perform app.assert_writable(v_tenant);
  select coalesce(upper(p_country), country_code) into v_country from public.tenants where id = v_tenant;
  v_id := app.new_property(v_tenant, p_name, v_country, p_city, p_address);
  perform app.audit(v_tenant, v_id, 'property.create', 'properties', v_id, null, jsonb_build_object('name', p_name), null, null);
  return v_id;
end $$;

-- ---------------------------------------------------------------- plan limits
create or replace function app.plan_of(p_tenant uuid) returns public.plans
language sql stable security definer set search_path = public, pg_temp as $$
  select pl.* from public.tenant_subscriptions ts join public.plans pl on pl.id = ts.plan_id where ts.tenant_id = p_tenant
$$;

create or replace function app.limit_rooms() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare pl public.plans; v_n int;
begin
  if new.status <> 'active' then return new; end if;
  pl := app.plan_of(new.tenant_id);
  if pl.max_rooms is null then return new; end if;
  select count(*) into v_n from public.rooms where tenant_id = new.tenant_id and status = 'active' and id <> new.id;
  if v_n + 1 > pl.max_rooms then
    perform app.fail('E_PLAN_LIMIT', format('Your %s plan allows %s rooms. Upgrade to add more.', pl.name, pl.max_rooms));
  end if;
  return new;
end $$;
create trigger rooms_plan_limit before insert or update of status on public.rooms for each row execute function app.limit_rooms();

create or replace function app.limit_properties() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare pl public.plans; v_n int;
begin
  pl := app.plan_of(new.tenant_id);
  if pl.max_properties is null then return new; end if;
  select count(*) into v_n from public.properties where tenant_id = new.tenant_id;
  if v_n + 1 > pl.max_properties then
    perform app.fail('E_PLAN_LIMIT', format('Your %s plan allows %s propert%s. Upgrade to add more.', pl.name, pl.max_properties,
                     case when pl.max_properties = 1 then 'y' else 'ies' end));
  end if;
  return new;
end $$;
create trigger properties_plan_limit before insert on public.properties for each row execute function app.limit_properties();

create or replace function app.limit_users() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare pl public.plans; v_n int;
begin
  if new.tenant_id is null or new.status <> 'active' then return new; end if;
  if tg_op = 'UPDATE' and old.tenant_id = new.tenant_id and old.status = 'active' then return new; end if;
  pl := app.plan_of(new.tenant_id);
  if pl.max_users is null then return new; end if;
  select count(*) into v_n from public.profiles where tenant_id = new.tenant_id and status = 'active' and id <> new.id;
  if v_n + 1 > pl.max_users then
    perform app.fail('E_PLAN_LIMIT', format('Your %s plan allows %s users. Upgrade to add more.', pl.name, pl.max_users));
  end if;
  return new;
end $$;
create trigger profiles_plan_limit before insert or update of tenant_id, status on public.profiles for each row execute function app.limit_users();

-- ---------------------------------------------------------------- subscription transitions
-- Manual until billing integration (R1b). Every change writes a subscription event.
create or replace function public.platform_change_subscription(
  p_tenant uuid, p_action text, p_reason text, p_plan_code text default null, p_period_end timestamptz default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.tenant_subscriptions; v_to text; v_plan public.plans;
begin
  if p_action in ('close','suspend','expire') then
    if not app.platform_can('platform.tenant.manage') then perform app.fail('E_PERM', 'You do not have permission: platform.tenant.manage'); end if;
  else
    if not app.platform_can('platform.billing.manage') then perform app.fail('E_PERM', 'You do not have permission: platform.billing.manage'); end if;
  end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  select * into s from public.tenant_subscriptions where tenant_id = p_tenant for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Tenant not found.'); end if;
  if s.status = 'closed' and p_action <> 'activate' then perform app.fail('E_STATE', 'A closed account cannot change.'); end if;

  if p_action = 'activate' then
    if p_period_end is null or p_period_end <= now() then perform app.fail('E_ARG', 'Give the end of the paid period.'); end if;
    v_to := 'active';
    update public.tenant_subscriptions set status = 'active', current_period_end = p_period_end, cancel_at = null, updated_at = now()
     where tenant_id = p_tenant;
  elsif p_action = 'mark_past_due' then
    if s.status <> 'active' then perform app.fail('E_STATE', 'Only an active account can become past due.'); end if;
    v_to := 'past_due'; update public.tenant_subscriptions set status = v_to, updated_at = now() where tenant_id = p_tenant;
  elsif p_action = 'suspend' then
    if s.status not in ('trial','active','past_due') then perform app.fail('E_STATE', 'This account cannot be suspended now.'); end if;
    v_to := 'suspended'; update public.tenant_subscriptions set status = v_to, updated_at = now() where tenant_id = p_tenant;
  elsif p_action = 'expire' then
    if s.status <> 'trial' then perform app.fail('E_STATE', 'Only a trial can expire.'); end if;
    v_to := 'expired'; update public.tenant_subscriptions set status = v_to, updated_at = now() where tenant_id = p_tenant;
  elsif p_action = 'close' then
    v_to := 'closed'; update public.tenant_subscriptions set status = v_to, updated_at = now() where tenant_id = p_tenant;
  elsif p_action = 'change_plan' then
    select * into v_plan from public.plans where code = p_plan_code and active;
    if not found then perform app.fail('E_PLAN', 'Plan not found.'); end if;
    if v_plan.max_rooms is not null and (select count(*) from public.rooms where tenant_id = p_tenant and status = 'active') > v_plan.max_rooms then
      perform app.fail('E_PLAN_LIMIT', 'The hotel has more rooms than this plan allows.');
    end if;
    if v_plan.max_properties is not null and (select count(*) from public.properties where tenant_id = p_tenant) > v_plan.max_properties then
      perform app.fail('E_PLAN_LIMIT', 'The hotel has more properties than this plan allows.');
    end if;
    if v_plan.max_users is not null and (select count(*) from public.profiles where tenant_id = p_tenant and status = 'active') > v_plan.max_users then
      perform app.fail('E_PLAN_LIMIT', 'The hotel has more users than this plan allows.');
    end if;
    v_to := s.status; update public.tenant_subscriptions set plan_id = v_plan.id, updated_at = now() where tenant_id = p_tenant;
  else
    perform app.fail('E_ARG', 'Unknown action.');
  end if;
  perform app.log_subscription_event(p_tenant, s.status, v_to, 'manual:' || p_action, p_reason);
end $$;

create or replace function public.cancel_subscription(p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tenant uuid := app.my_tenant(); s public.tenant_subscriptions;
begin
  if v_tenant is null then perform app.fail('E_PERM', 'No hotel account.'); end if;
  perform app.require_tenant('org.subscription.manage');
  select * into s from public.tenant_subscriptions where tenant_id = v_tenant for update;
  if s.status not in ('trial','active','past_due') then perform app.fail('E_STATE', 'This account cannot be cancelled now.'); end if;
  update public.tenant_subscriptions set status = 'cancelled', cancel_at = coalesce(s.current_period_end, now()), updated_at = now()
   where tenant_id = v_tenant;
  perform app.log_subscription_event(v_tenant, s.status, 'cancelled', 'customer', p_reason);
end $$;

-- Daily: trials that ran out expire; unpaid periods go past due, then suspended after 14 days.
create or replace function app.run_subscription_clock() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int := 0; s public.tenant_subscriptions;
begin
  for s in select * from public.tenant_subscriptions
            where (status = 'trial' and trial_ends_at < now())
               or (status = 'active' and current_period_end < now())
               or (status = 'past_due' and current_period_end + interval '14 days' < now()) loop
    update public.tenant_subscriptions set status = case s.status when 'trial' then 'expired' when 'active' then 'past_due' else 'suspended' end,
           updated_at = now() where tenant_id = s.tenant_id;
    perform app.log_subscription_event(s.tenant_id, s.status,
            case s.status when 'trial' then 'expired' when 'active' then 'past_due' else 'suspended' end, 'clock', null);
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('hms-subscription-clock', '15 1 * * *', 'select app.run_subscription_clock()');
  end if;
end $$;

-- ---------------------------------------------------------------- users and roles
-- The Edge Function creates the auth user with the admin API, then the tenant admin's session calls this.
create or replace function public.register_invited_user(p_user uuid, p_full_name text, p_phone text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tenant uuid := app.my_tenant(); pr public.profiles;
begin
  if v_tenant is null then perform app.fail('E_PERM', 'No hotel account.'); end if;
  perform app.require_tenant('adm.user.manage');
  perform app.assert_writable(v_tenant);
  select * into pr from public.profiles where id = p_user for update;
  if not found then perform app.fail('E_NOT_FOUND', 'User not found.'); end if;
  if pr.tenant_id is not null then perform app.fail('E_ALREADY_HAS_HOTEL', 'This person already belongs to a hotel account.'); end if;
  update public.profiles set tenant_id = v_tenant, full_name = coalesce(nullif(btrim(p_full_name), ''), full_name), phone = p_phone where id = p_user;
  perform app.audit(v_tenant, null, 'user.invite', 'profiles', p_user, null, jsonb_build_object('email', pr.email), null, null);
end $$;

create or replace function public.assign_role(p_user uuid, p_property uuid, p_role uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tenant uuid := app.my_tenant(); ro public.roles;
begin
  if v_tenant is null then perform app.fail('E_PERM', 'No hotel account.'); end if;
  perform app.require_tenant('adm.role.assign');
  perform app.assert_writable(v_tenant);
  select * into ro from public.roles where id = p_role and (tenant_id is null or tenant_id = v_tenant);
  if not found or ro.code = 'PSA' then perform app.fail('E_NOT_FOUND', 'Role not found.'); end if;
  if not exists (select 1 from public.profiles where id = p_user and tenant_id = v_tenant) then perform app.fail('E_NOT_FOUND', 'User not found.'); end if;
  if p_property is not null and not exists (select 1 from public.properties where id = p_property and tenant_id = v_tenant) then
    perform app.fail('E_NOT_FOUND', 'Property not found.');
  end if;
  insert into public.user_property_roles (tenant_id, user_id, property_id, role_id, created_by)
  values (v_tenant, p_user, p_property, p_role, auth.uid()) on conflict do nothing;
  perform app.audit(v_tenant, p_property, 'role.assign', 'user_property_roles', p_user, null,
                    jsonb_build_object('role', ro.code, 'user', p_user), null, null);
end $$;

create or replace function public.remove_role(p_user uuid, p_property uuid, p_role uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tenant uuid := app.my_tenant(); ro public.roles;
begin
  if v_tenant is null then perform app.fail('E_PERM', 'No hotel account.'); end if;
  perform app.require_tenant('adm.role.assign');
  perform app.assert_writable(v_tenant);
  select * into ro from public.roles where id = p_role;
  if ro.code = 'SYS' and not exists (
       select 1 from public.user_property_roles u join public.profiles pr on pr.id = u.user_id and pr.status = 'active'
        where u.tenant_id = v_tenant and u.role_id = p_role and u.property_id is null
          and not (u.user_id = p_user and u.property_id is not distinct from p_property)) then
    perform app.fail('E_LAST_ADMIN', 'A hotel needs at least one system administrator.');
  end if;
  delete from public.user_property_roles where tenant_id = v_tenant and user_id = p_user and role_id = p_role
     and property_id is not distinct from p_property;
  perform app.audit(v_tenant, p_property, 'role.remove', 'user_property_roles', p_user, null,
                    jsonb_build_object('role', ro.code, 'user', p_user), null, null);
end $$;

create or replace function public.set_user_status(p_user uuid, p_status text, p_reason text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tenant uuid := app.my_tenant(); v_sys uuid;
begin
  if v_tenant is null then perform app.fail('E_PERM', 'No hotel account.'); end if;
  perform app.require_tenant('adm.user.manage');
  perform app.assert_writable(v_tenant);
  if p_status not in ('active','disabled') then perform app.fail('E_ARG', 'Status must be active or disabled.'); end if;
  if p_user = auth.uid() and p_status = 'disabled' then perform app.fail('E_ARG', 'You cannot disable yourself.'); end if;
  if not exists (select 1 from public.profiles where id = p_user and tenant_id = v_tenant) then perform app.fail('E_NOT_FOUND', 'User not found.'); end if;
  select id into v_sys from public.roles where tenant_id is null and code = 'SYS';
  if p_status = 'disabled' and not exists (
       select 1 from public.user_property_roles u join public.profiles pr on pr.id = u.user_id and pr.status = 'active'
        where u.tenant_id = v_tenant and u.role_id = v_sys and u.property_id is null and u.user_id <> p_user) then
    perform app.fail('E_LAST_ADMIN', 'A hotel needs at least one active system administrator.');
  end if;
  update public.profiles set status = p_status where id = p_user;
  perform app.audit(v_tenant, null, 'user.status', 'profiles', p_user, null, jsonb_build_object('status', p_status), p_reason, null);
end $$;

-- Exchange rates are entered by the property, one row per currency per day.
create or replace function public.set_exchange_rate(p_property uuid, p_currency text, p_date date, p_rate numeric)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tenant uuid := app.property_tenant(p_property); v_base text;
begin
  perform app.require(p_property, 'setup.fx.manage');
  perform app.assert_writable(v_tenant);
  select base_currency into v_base from public.properties where id = p_property;
  if p_currency = v_base then perform app.fail('E_ARG', 'The base currency always has a rate of 1.'); end if;
  if p_rate <= 0 then perform app.fail('E_ARG', 'The rate must be greater than zero.'); end if;
  insert into public.exchange_rates (tenant_id, property_id, currency, rate_date, rate, created_by)
  values (v_tenant, p_property, p_currency, p_date, p_rate, auth.uid())
  on conflict (property_id, currency, rate_date) do update set rate = excluded.rate;
  perform app.audit(v_tenant, p_property, 'fx.set', 'exchange_rates', null, null,
                    jsonb_build_object('currency', p_currency, 'date', p_date, 'rate', p_rate), null, null);
end $$;
