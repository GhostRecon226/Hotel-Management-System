-- Tenant isolation: hotel B must never see or change anything of hotel A.
do $$
declare v_res uuid; v_n int;
begin
  perform t.login('fdo');
  v_res := public.create_reservation(t.id('propA'), t.id('g1'), t.bdate() + 10, t.bdate() + 12, t.id('std'), t.id('bar'));
  perform t.admin();
  insert into t.ids values ('resIso', v_res);

  perform t.login('adminB');
  select count(*) into v_n from public.guests;              perform t.eq(v_n, 0, 'B sees none of A''s guests');
  select count(*) into v_n from public.reservations;        perform t.eq(v_n, 0, 'B sees none of A''s reservations');
  select count(*) into v_n from public.folios;              perform t.eq(v_n, 0, 'B sees none of A''s folios');
  select count(*) into v_n from public.properties;          perform t.eq(v_n, 1, 'B sees only its own property');
  select count(*) into v_n from public.rooms;               perform t.eq(v_n, 0, 'B sees none of A''s rooms');
  select count(*) into v_n from public.audit_events where tenant_id = t.id('tenantA'); perform t.eq(v_n, 0, 'B cannot read A''s audit trail');
  select count(*) into v_n from public.tenants;             perform t.eq(v_n, 1, 'B sees only its own tenant');
  select count(*) into v_n from public.v_folio_balances;    perform t.eq(v_n, 0, 'B sees no folio balances of A');

  perform t.raises(format('select public.cancel_reservation(%L, ''x'')', t.id('resIso')), 'E_PERM', 'B cannot cancel A''s reservation');
  perform t.raises(format('select public.post_charge((select id from public.folios limit 1), %L, 100, ''NGN'', ''x'')', t.cc('MISC')), 'E_NOT_FOUND', 'B cannot post to A''s folio');
  perform t.raises(format('insert into public.guests (tenant_id, first_name, last_name) values (%L, ''X'', ''Y'')', t.id('tenantA')), 'row-level security', 'B cannot insert a guest into A');
  perform t.raises(format('insert into public.room_types (tenant_id, property_id, code, name) values (%L, %L, ''ZZ'', ''Z'')', t.id('tenantA'), t.id('propA')), 'row-level security', 'B cannot add a room type to A');
  perform t.raises(format('select * from public.get_availability(%L, current_date, current_date + 1)', t.id('propA')), 'E_PERM', 'B cannot read A''s availability');

  -- update of another tenant's rows silently affects nothing
  update public.guests set first_name = 'Hacked' where id = t.id('g1');
  perform t.admin();
  perform t.eq((select first_name from public.guests where id = t.id('g1')), 'Chinedu', 'B update of A''s guest changed nothing');

  -- a user without a hotel sees nothing and cannot act
  perform t.login('nobody');
  select count(*) into v_n from public.properties; perform t.eq(v_n, 0, 'user without a hotel sees no properties');
  perform t.raises(format('select public.create_reservation(%L, %L, current_date, current_date + 1, %L, %L)', t.id('propA'), t.id('g1'), t.id('std'), t.id('bar')), 'E_PERM', 'user without a hotel cannot book');

  -- anon has no access at all
  perform t.admin();
  execute 'set role anon';
  perform t.raises('select count(*) from public.guests', 'permission denied', 'anon cannot read guests');
  perform t.raises('select public.create_hotel(''x'', ''NG'', ''y'')', 'permission denied', 'anon cannot call create_hotel');
  perform t.admin();

  -- staff scope: hotel A staff without the permission is refused
  perform t.login('hks');
  perform t.raises(format('select public.create_reservation(%L, %L, current_date + 3, current_date + 4, %L, %L)', t.id('propA'), t.id('g1'), t.id('std'), t.id('bar')), 'E_PERM', 'housekeeping supervisor cannot book');
  select count(*) into v_n from public.folio_transactions; perform t.eq(v_n, 0, 'housekeeping cannot read ledger rows');
  perform t.admin();
end $$;
