-- Test helpers and fixtures. Two hotels (A and B), staff for hotel A, rooms, rates.
create schema t;
create table t.ids (name text primary key, id uuid not null);
create function t.id(n text) returns uuid language sql stable as $$ select id from t.ids where name = n $$;
create function t.login(n text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', t.id(n)::text, false);
  execute 'set role authenticated';
end $$;
create function t.admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', false);
end $$;
create function t.ok(c boolean, msg text) returns void language plpgsql as $$
begin
  if c is not true then raise exception 'TEST FAIL: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;
create function t.eq(a anyelement, b anyelement, msg text) returns void language plpgsql as $$
begin
  if a is distinct from b then raise exception 'TEST FAIL: % (got %, expected %)', msg, a, b; end if;
  raise notice 'ok - %', msg;
end $$;
create function t.raises(p_sql text, p_frag text, msg text default null) returns void language plpgsql as $$
declare v_failed boolean := false; v_msg text;
begin
  begin execute p_sql; exception when others then v_failed := true; v_msg := sqlerrm; end;
  if not v_failed then raise exception 'TEST FAIL: expected [%] but it succeeded: %', p_frag, coalesce(msg, p_sql); end if;
  if position(p_frag in v_msg) = 0 then
    raise exception 'TEST FAIL: expected [%] got [%] for %', p_frag, v_msg, coalesce(msg, p_sql);
  end if;
  raise notice 'ok - % (%)', coalesce(msg, p_sql), p_frag;
end $$;
create function t.bdate() returns date language sql stable as $$ select business_date from public.properties where id = t.id('propA') $$;
create function t.pm(p_code text) returns uuid language sql stable as $$ select id from public.payment_methods where property_id = t.id('propA') and code = p_code $$;
create function t.cc(p_code text) returns uuid language sql stable as $$ select id from public.charge_codes where property_id = t.id('propA') and code = p_code $$;
grant usage on schema t to authenticated, anon;
grant select on t.ids to authenticated, anon;
grant execute on all functions in schema t to authenticated, anon;

do $$
declare
  n text; v jsonb; v_prop uuid; v_prop_b uuid; v_uid uuid; v_role uuid; v_std uuid; v_dlx uuid; v_bar uuid; v_i int;
  v_tenant uuid; v_tenant_b uuid;
begin
  foreach n in array array['adminA','adminB','fdo','fom','acc','hks','att','mnt','rsv','csh','nobody'] loop
    v_uid := gen_random_uuid();
    insert into auth.users (id, email) values (v_uid, n || '@test.local');
    insert into t.ids values (n, v_uid);
  end loop;

  -- hotel A and hotel B sign up
  perform t.login('adminA');
  v := public.create_hotel('Sunrise Lodge Ltd', 'NG', 'Sunrise Lodge', 'Ada Obi', 'Lagos');
  v_tenant := (v ->> 'tenant_id')::uuid; v_prop := (v ->> 'property_id')::uuid;
  perform t.login('adminB');
  v := public.create_hotel('Coastal Inn Ltd', 'NG', 'Coastal Inn', 'Bayo Ade', 'Port Harcourt');
  v_tenant_b := (v ->> 'tenant_id')::uuid; v_prop_b := (v ->> 'property_id')::uuid;
  perform t.admin();
  insert into t.ids values ('tenantA', v_tenant), ('propA', v_prop), ('tenantB', v_tenant_b), ('propB', v_prop_b);

  -- staff for hotel A
  perform t.login('adminA');
  foreach n in array array['fdo','fom','acc','hks','att','mnt','rsv','csh'] loop
    perform public.register_invited_user(t.id(n), initcap(n) || ' Staff');
    select id into v_role from public.roles where tenant_id is null and code = case n
      when 'fdo' then 'FDO' when 'fom' then 'FOM' when 'acc' then 'ACC' when 'hks' then 'HKS' when 'att' then 'ATT'
      when 'mnt' then 'MNT' when 'rsv' then 'RSV' when 'csh' then 'CSH' end;
    perform public.assign_role(t.id(n), v_prop, v_role);
  end loop;

  -- configuration: room types, rooms, rate plan, prices, limits, exchange rate
  insert into public.room_types (tenant_id, property_id, code, name, max_adults, max_children)
  values (v_tenant, v_prop, 'STD', 'Standard', 2, 1) returning id into v_std;
  insert into public.room_types (tenant_id, property_id, code, name, max_adults, max_children)
  values (v_tenant, v_prop, 'DLX', 'Deluxe', 3, 2) returning id into v_dlx;
  insert into public.rooms (tenant_id, property_id, room_number, room_type_id) values
    (v_tenant, v_prop, '101', v_std), (v_tenant, v_prop, '102', v_std), (v_tenant, v_prop, '103', v_std),
    (v_tenant, v_prop, '201', v_dlx);
  insert into public.rate_plans (tenant_id, property_id, code, name, cancellation, no_show, deposit)
  values (v_tenant, v_prop, 'BAR', 'Best available', '{"type":"nights","value":1,"free_until_days":2}',
          '{"type":"nights","value":1}', '{"type":"none","value":0}') returning id into v_bar;
  insert into public.rate_plans (tenant_id, property_id, code, name, deposit)
  values (v_tenant, v_prop, 'PREPAID', 'Deposit rate', '{"type":"percent","value":50}');
  insert into public.rate_plan_prices (tenant_id, property_id, rate_plan_id, room_type_id, valid_from, valid_to, amount, currency)
  select v_tenant, v_prop, rp.id, rt.id, current_date - 30, current_date + 400, case rt.code when 'STD' then 50000 else 90000 end, 'NGN'
    from public.rate_plans rp cross join public.room_types rt where rp.property_id = v_prop and rt.property_id = v_prop;
  insert into public.approval_limits (tenant_id, property_id, role_id, permission_key, max_amount)
  select v_tenant, null, r.id, x.k, x.amt from (values ('FDO','fin.discount.apply',5000),('FOM','fin.discount.approve',20000),
     ('FOM','fin.adjust.approve',20000),('FOM','fin.refund.approve',20000)) x(code, k, amt)
  join public.roles r on r.tenant_id is null and r.code = x.code;
  perform public.set_exchange_rate(v_prop, 'USD', current_date - 5, 1500);
  perform t.admin();
  insert into t.ids values ('std', v_std), ('dlx', v_dlx), ('bar', v_bar),
    ('prepaid', (select id from public.rate_plans where property_id = v_prop and code = 'PREPAID'));
  for v_i in 1..4 loop
    insert into t.ids select 'room' || rm.room_number, rm.id from public.rooms rm
     where rm.property_id = v_prop and rm.room_number = (array['101','102','103','201'])[v_i];
  end loop;
  -- rooms start ready (default). Guests for tests.
  perform t.login('fdo');
  insert into public.guests (id, tenant_id, first_name, last_name, phone) values
    ('00000000-0000-4000-8000-0000000000a1', v_tenant, 'Chinedu', 'Okafor', '08030000001'),
    ('00000000-0000-4000-8000-0000000000a2', v_tenant, 'Amina', 'Bello', '08030000002'),
    ('00000000-0000-4000-8000-0000000000a3', v_tenant, 'Tunde', 'Balogun', '08030000003');
  perform t.admin();
  insert into t.ids values ('g1','00000000-0000-4000-8000-0000000000a1'),('g2','00000000-0000-4000-8000-0000000000a2'),('g3','00000000-0000-4000-8000-0000000000a3');
  raise notice 'fixtures ready';
end $$;
