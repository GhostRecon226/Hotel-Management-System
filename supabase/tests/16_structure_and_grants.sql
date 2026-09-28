-- Structural guarantees. These fail if a future migration forgets row-level security, a search_path,
-- a tenant column, or opens a write path by accident.
do $$
declare v text; v_list text[];
begin
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  perform t.ok(v is null, 'every public table has row-level security enabled' || coalesce(' (missing: ' || v || ')', ''));

  select string_agg(p.proname, ', ') into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public','app') and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%');
  perform t.ok(v is null, 'every security definer function pins its search_path' || coalesce(' (missing: ' || v || ')', ''));

  select array_agg(c.relname order by c.relname) into v_list from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and not exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped);
    perform t.ok(v_list <@ array['country_templates','currencies','permissions','plans','platform_staff','role_permissions','tenants']::text[],
               'only reference and platform tables lack a tenant column: ' || array_to_string(v_list, ','));

  -- tables the logged-in role can write to directly
  select array_agg(distinct table_name order by table_name) into v_list from (
    select table_name from information_schema.table_privileges
     where grantee = 'authenticated' and table_schema = 'public' and privilege_type in ('INSERT','UPDATE','DELETE')
    union
    select table_name from information_schema.column_privileges
     where grantee = 'authenticated' and table_schema = 'public' and privilege_type in ('INSERT','UPDATE')) x;
  perform t.eq(v_list, array['approval_limits','charge_codes','exchange_rates','group_bookings','guest_documents','guest_feedback','guests',
     'lost_found_items','notifications','payment_methods','profiles','properties','rate_plan_prices','rate_plans','role_permissions','roles',
     'room_types','rooms','tax_rates']::text[], 'the browser can write directly to configuration tables only');
  perform t.ok(not exists (select 1 from information_schema.table_privileges where grantee = 'anon' and table_schema = 'public'), 'anon holds no table privileges');
end $$;

do $$
begin
  perform t.login('adminA');
  perform t.raises(format('update public.properties set business_date = business_date + 5 where id = %L', t.id('propA')), 'permission denied', 'nobody edits the business date by hand');
  perform t.raises(format('update public.properties set base_currency = ''USD'' where id = %L', t.id('propA')), 'permission denied', 'base currency cannot change after setup');
  perform t.raises(format('update public.profiles set status = ''active'', tenant_id = %L where id = %L', t.id('tenantB'), t.id('adminA')), 'permission denied', 'a user cannot move themselves to another hotel');
  update public.profiles set full_name = 'Ada Obi-Okoro' where id = t.id('adminA');
  perform t.ok(true, 'a user can edit their own name');
  perform t.raises(format('insert into public.audit_events (tenant_id, action) values (%L, ''x'')', t.id('tenantA')), 'permission denied', 'the audit trail cannot be written by users');
  perform t.login('fom');
  perform t.raises(format('update public.reservations set status = ''confirmed'' where id = %L', t.id('resIso')), 'permission denied', 'reservations cannot be edited directly');
  perform t.raises(format('delete from public.reservations where id = %L', t.id('resIso')), 'permission denied', 'reservations cannot be deleted');
  perform t.raises(format('update public.approvals set status = ''approved''', ''), 'permission denied', 'approvals cannot be edited directly');
  perform t.raises(format('update public.stays set status = ''voided'''), 'permission denied', 'stays cannot be edited directly');
  perform t.raises(format('update public.room_assignments set status = ''released'''), 'permission denied', 'assignments cannot be edited directly');
  perform t.raises(format('update public.hk_tasks set status = ''inspected'''), 'permission denied', 'housekeeping tasks cannot be edited directly');
  perform t.raises(format('update public.daily_stats set rooms_sold = 999'), 'permission denied', 'daily numbers cannot be edited');
  perform t.raises(format('insert into public.guests (tenant_id, first_name, last_name, anonymised_at) values (%L, ''A'', ''B'', now())', t.id('tenantA')), 'permission denied', 'a guest cannot be created pre-anonymised');
  -- a user reads only their own notifications and can mark them read
  perform t.ok((select count(*) from public.notifications) > 0, 'the manager has notifications');
  perform t.ok((select count(*) from public.notifications where user_id <> t.id('fom')) = 0, 'and sees only their own');
  update public.notifications set read_at = now() where user_id = t.id('fom');
  perform t.raises(format('update public.notifications set title = ''x'' where user_id = %L', t.id('fom')), 'permission denied', 'notification text cannot be edited');
  perform t.login('hks');
  insert into public.lost_found_items (tenant_id, property_id, description, notes, found_on, status)
  values (t.id('tenantA'), t.id('propA'), 'Black umbrella', 'Lobby', t.bdate(), 'found');
  perform t.ok(true, 'housekeeping logs a lost and found item');
  perform t.admin();
  perform t.raises('update public.audit_events set action = ''x''', 'E_IMMUTABLE', 'the audit trail cannot be changed, even by the owner');
  perform t.raises('delete from public.audit_events', 'E_IMMUTABLE', 'the audit trail cannot be deleted');
end $$;
