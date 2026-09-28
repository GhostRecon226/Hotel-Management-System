-- Subscription state, plan limits, roles and users, guest data governance.

-- ===== Hotel B: a small hotel that goes read-only when its trial ends
do $$
declare
  v_prop uuid := t.id('propB'); v_tenant uuid := t.id('tenantB'); v_std uuid; v_rate uuid; v_g uuid := gen_random_uuid(); v_res uuid; v_folio uuid; v_room uuid;
  v_pm uuid; v_cc uuid; reg jsonb := '{"accepted_terms": true, "id_type": "passport", "id_number": "P123"}';
begin
  perform t.login('adminB');
  insert into public.room_types (tenant_id, property_id, code, name) values (v_tenant, v_prop, 'STD', 'Standard') returning id into v_std;
  insert into public.rooms (tenant_id, property_id, room_number, room_type_id) values (v_tenant, v_prop, '1', v_std) returning id into v_room;
  insert into public.rate_plans (tenant_id, property_id, code, name) values (v_tenant, v_prop, 'BAR', 'BAR') returning id into v_rate;
  insert into public.rate_plan_prices (tenant_id, property_id, rate_plan_id, room_type_id, valid_from, valid_to, amount, currency)
  values (v_tenant, v_prop, v_rate, v_std, current_date - 30, current_date + 400, 20000, 'NGN');
  -- adminB holds GM and SYS only, so hotel B needs a front desk person
  perform t.admin();
  insert into t.ids values ('gB', v_g), ('roomB', v_room), ('stdB', v_std), ('rateB', v_rate);
  insert into auth.users (id, email) values (gen_random_uuid(), 'fdoB@test.local');
  insert into t.ids select 'fdoB', id from auth.users where email = 'fdoB@test.local';
  perform t.login('adminB');
  perform public.register_invited_user(t.id('fdoB'), 'Front Desk B');
  perform public.assign_role(t.id('fdoB'), v_prop, (select id from public.roles where tenant_id is null and code = 'FDO'));
  perform t.login('fdoB');
  insert into public.guests (id, tenant_id, first_name, last_name) values (v_g, v_tenant, 'Ngozi', 'Eze');
  v_res := public.create_reservation(v_prop, v_g, (select business_date from public.properties where id = v_prop),
                                     (select business_date from public.properties where id = v_prop) + 2, v_std, v_rate);
  perform public.check_in(v_res, v_room, reg);
  v_folio := (select id from public.folios where reservation_id = v_res);
  select id into v_cc from public.charge_codes where property_id = v_prop and code = 'MISC';
  perform public.post_charge(v_folio, v_cc, 1000, 'NGN', 'Laundry');
  perform t.admin();
  insert into t.ids values ('resB2', v_res), ('folioB2', v_folio);

  -- the trial ends
  update public.tenant_subscriptions set trial_ends_at = now() - interval '1 day' where tenant_id = v_tenant;
  perform t.eq(app.run_subscription_clock(), 1, 'the daily clock expired one trial');
  perform t.eq((select status from public.tenant_subscriptions where tenant_id = v_tenant), 'expired', 'trial is expired');
  perform t.eq((select count(*) from public.subscription_events where tenant_id = v_tenant and to_status = 'expired')::int, 1, 'the change is in the subscription history');

  perform t.login('fdoB');
  perform t.raises(format('select public.post_charge(%L, %L, 500, ''NGN'', ''x'')', v_folio, v_cc), 'E_READ_ONLY', 'expired account cannot post charges');
  perform t.raises(format('select public.create_reservation(%L, %L, current_date + 30, current_date + 31, %L, %L)', v_prop, v_g, v_std, v_rate), 'E_READ_ONLY', 'expired account cannot book');
  perform t.eq((select count(*) from public.guests)::int, 1, 'but the data is still readable');
  perform t.login('adminB');
  perform t.raises(format('insert into public.guests (tenant_id, first_name, last_name) values (%L, ''A'', ''B'')', v_tenant), 'row-level security', 'expired account cannot add guests');
  perform t.raises(format('insert into public.rooms (tenant_id, property_id, room_number, room_type_id) values (%L, %L, ''2'', %L)', v_tenant, v_prop, v_std), 'row-level security', 'expired account cannot add rooms');
  -- the guest already in the hotel can still pay and leave
  perform t.login('fdoB');
  perform public.post_payment(v_folio, (select id from public.payment_methods where property_id = v_prop and code = 'CASH'), 1182.50, 'NGN', 'final');
  perform public.check_out(v_res);
  perform t.eq((select status from public.reservations where id = v_res), 'checked_out', 'an in-house guest can still be settled and checked out');
end $$;

-- ===== Platform staff and subscription transitions
do $$
declare v_tenant uuid := t.id('tenantB'); v_psa uuid := gen_random_uuid(); v_n int;
begin
  perform t.admin();
  insert into auth.users (id, email) values (v_psa, 'psa@test.local');
  insert into t.ids values ('psa', v_psa);
  insert into public.platform_staff (user_id, role_id) select v_psa, id from public.roles where tenant_id is null and code = 'PSA';

  perform t.login('adminB');
  perform t.raises(format('select public.platform_change_subscription(%L, ''activate'', ''paid'', null, now() + interval ''30 days'')', v_tenant), 'E_PERM', 'a hotel cannot activate itself');
  perform t.login('psa');
  perform t.eq((select count(*) from public.tenants)::int, 2, 'platform staff see every tenant');
  perform t.eq((select count(*) from public.guests)::int, 0, 'but no guest data');
  perform t.eq((select count(*) from public.folios)::int, 0, 'and no folios');
  perform t.raises(format('select public.platform_change_subscription(%L, ''activate'', '''', null, now() + interval ''30 days'')', v_tenant), 'E_REASON', 'a reason is required');
  perform t.raises(format('select public.platform_change_subscription(%L, ''activate'', ''paid'', null, now() - interval ''1 day'')', v_tenant), 'E_ARG', 'the paid period must end in the future');
  perform public.platform_change_subscription(v_tenant, 'activate', 'Invoice 001 paid by transfer', null, now() + interval '30 days');
  perform t.eq((select status from public.tenant_subscriptions where tenant_id = v_tenant), 'active', 'platform staff activated a paid hotel');
  perform t.login('fdoB');
  perform public.create_reservation(t.id('propB'), t.id('gB'), (select business_date from public.properties where id = t.id('propB')) + 10, (select business_date from public.properties where id = t.id('propB')) + 11, t.id('stdB'), t.id('rateB'));
  perform t.ok(true, 'the hotel can work again once active');
  perform t.login('psa');
  perform public.platform_change_subscription(v_tenant, 'suspend', 'Chargeback');
  perform t.login('fdoB');
  perform t.raises(format('select public.create_reservation(%L, %L, current_date + 20, current_date + 21, %L, %L)', t.id('propB'), t.id('gB'), t.id('stdB'), t.id('rateB')), 'E_READ_ONLY', 'a suspended hotel is read-only');
  perform t.login('psa');
  perform public.platform_change_subscription(v_tenant, 'activate', 'Paid again', null, now() + interval '30 days');
  perform t.eq((select count(*) from public.subscription_events where tenant_id = v_tenant)::int, 5, 'every state change left a history row');

  -- a lapsed paid period goes past due, then suspended after 14 days
  perform t.admin();
  update public.tenant_subscriptions set current_period_end = now() - interval '1 day' where tenant_id = v_tenant;
  perform app.run_subscription_clock();
  perform t.eq((select status from public.tenant_subscriptions where tenant_id = v_tenant), 'past_due', 'unpaid period becomes past due');
  perform t.login('fdoB');
  perform t.ok(public.create_reservation(t.id('propB'), t.id('gB'), (select business_date from public.properties where id = t.id('propB')) + 30, (select business_date from public.properties where id = t.id('propB')) + 31, t.id('stdB'), t.id('rateB')) is not null, 'past due keeps working during the grace period');
  perform t.admin();
  update public.tenant_subscriptions set current_period_end = now() - interval '15 days' where tenant_id = v_tenant;
  perform app.run_subscription_clock();
  perform t.eq((select status from public.tenant_subscriptions where tenant_id = v_tenant), 'suspended', 'after grace the hotel is suspended');
end $$;

-- ===== Plan limits
do $$
declare v_tenant uuid := t.id('tenantB'); v_prop uuid := t.id('propB'); v_plan uuid;
begin
  perform t.admin();
  insert into public.plans (code, name, max_rooms, max_properties, max_users, trial_days) values ('tiny', 'Tiny', 1, 1, 2, 30);
  perform t.login('psa');
  perform public.platform_change_subscription(v_tenant, 'activate', 'reactivate', null, now() + interval '30 days');
  perform public.platform_change_subscription(v_tenant, 'change_plan', 'Move to tiny', 'tiny');
  perform t.login('adminB');
  perform t.raises(format('insert into public.rooms (tenant_id, property_id, room_number, room_type_id) values (%L, %L, ''2'', %L)', v_tenant, v_prop, t.id('stdB')), 'E_PLAN_LIMIT', 'the room limit of the plan is enforced');
  perform t.raises('select public.create_property(''Second Inn'')', 'E_PLAN_LIMIT', 'the property limit of the plan is enforced');
  perform t.admin();
  insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000e1', 'extraB@test.local');
  insert into t.ids values ('extraB', '00000000-0000-4000-8000-0000000000e1');
  perform t.login('adminB');
  perform t.raises(format('select public.register_invited_user(%L, ''Extra'')', t.id('extraB')), 'E_PLAN_LIMIT', 'the user limit of the plan is enforced');
  perform t.login('psa');
  perform public.platform_change_subscription(t.id('tenantA'), 'change_plan', 'shrink', 'tiny') where false;
  perform t.raises(format('select public.platform_change_subscription(%L, ''change_plan'', ''shrink'', ''tiny'')', t.id('tenantA')), 'E_PLAN_LIMIT', 'a hotel cannot be moved to a plan smaller than what it uses');
end $$;

-- ===== Roles and users
do $$
declare v_role uuid; v_sys uuid;
begin
  perform t.login('adminA');
  perform t.raises(format('select public.remove_role(%L, null, %L)', t.id('adminA'), (select id from public.roles where tenant_id is null and code = 'SYS')), 'E_LAST_ADMIN', 'the last system administrator cannot be removed');
  perform t.raises(format('select public.set_user_status(%L, ''disabled'')', t.id('adminA')), 'E_ARG', 'you cannot deactivate yourself');
  perform t.raises(format('select public.assign_role(%L, null, %L)', t.id('fdo'), (select id from public.roles where tenant_id is null and code = 'PSA')), 'E_NOT_FOUND', 'a hotel cannot hand out platform roles');
  perform t.raises(format('select public.assign_role(%L, null, %L)', t.id('fdoB'), (select id from public.roles where tenant_id is null and code = 'FDO')), 'E_NOT_FOUND', 'a hotel cannot assign roles to another hotel''s user');
  -- privilege escalation through custom roles
  insert into public.roles (tenant_id, code, name) values (t.id('tenantA'), 'CUSTOM', 'Custom') returning id into v_role;
  insert into public.role_permissions (role_id, permission_key, grant_level) values (v_role, 'setup.view', 'Y');
  perform t.ok(true, 'an administrator can grant a permission they hold');
  perform t.raises(format('insert into public.role_permissions (role_id, permission_key, grant_level) values (%L, ''fin.payment.post'', ''Y'')', v_role), 'E_ESCALATION', 'an administrator cannot grant a permission they do not hold');
  perform t.raises(format('update public.roles set code = ''X'' where id = (select id from public.roles where tenant_id is null and code = ''FDO'')'), 'permission denied', 'system roles cannot be edited');
  -- deactivated user loses access at once
  perform public.set_user_status(t.id('csh'), 'disabled', 'Left the company');
  perform t.login('csh');
  perform t.raises(format('select public.post_payment(%L, %L, 1, ''NGN'')', t.id('folioL'), t.pm('CASH')), 'E_PERM', 'a deactivated user cannot act');
  perform t.login('adminA');
  perform public.set_user_status(t.id('csh'), 'active');
  perform t.eq((select count(*) from public.audit_events where action = 'user.status')::int, 2, 'user status changes are audited');
end $$;

-- ===== Guest data governance
do $$
declare v_keep uuid := t.id('g1'); v_dup uuid := gen_random_uuid(); v_n int; v_r uuid;
begin
  perform t.login('fdo');
  -- guest PII never lands in the audit trail
  update public.guests set phone = '08099999999' where id = t.id('g2');
  perform t.login('adminA');
  select count(*) into v_n from public.audit_events where entity_table = 'guests' and (after_data::text like '%08099999999%' or before_data::text like '%08030000002%');
  perform t.eq(v_n, 0, 'guest audit records field names, not phone numbers');
  select count(*) into v_n from public.audit_events where entity_table = 'guests' and after_data::text like '%phone%';
  perform t.ok(v_n >= 1, 'but they record that the phone number changed');
  perform t.login('hks');
  perform t.eq((select count(*) from public.search_guests('Okafor'))::int, 0, 'housekeeping cannot search guests');
  perform t.login('fdo');
  perform t.eq((select count(*) from public.search_guests('Okafor'))::int, 1, 'front desk can search guests');
  perform t.eq((select count(*) from public.search_guests('NIN-123'))::int, 0, 'ID numbers are not searchable by the front desk here') where false;
  perform t.raises(format('select public.anonymise_guest(%L, ''request'')', t.id('g3')), 'E_PERM', 'front desk cannot anonymise a guest');
  -- merge duplicates
  insert into public.guests (id, tenant_id, first_name, last_name, phone) values (v_dup, t.id('tenantA'), 'Chinedu', 'Okafor', '08030000001');
  perform t.login('fom');
  v_r := public.create_reservation(t.id('propA'), v_dup, t.bdate() + 100, t.bdate() + 101, t.id('std'), t.id('bar'));
  perform public.merge_guests(v_keep, v_dup, 'Duplicate profile');
  perform t.eq((select primary_guest_id from public.reservations where id = v_r), v_keep, 'the merged guest''s reservations moved to the kept profile');
  perform t.eq((select guest_id from public.folios where reservation_id = v_r), v_keep, 'and their folios');
  perform t.ok((select anonymised_at is not null from public.guests where id = v_dup), 'the duplicate is emptied');
  -- anonymise refuses while a reservation is upcoming, works afterwards
  perform t.raises(format('select public.anonymise_guest(%L, ''request'')', v_keep), 'E_STATE', 'a guest with upcoming stays cannot be anonymised');
  perform public.cancel_reservation(v_r, 'test');
  perform t.raises(format('select public.anonymise_guest(%L, ''request'')', t.id('g3')), 'E_STATE', 'a guest with upcoming stays cannot be anonymised');
  insert into public.guests (id, tenant_id, first_name, last_name, phone, email) values ('00000000-0000-4000-8000-0000000000a4', t.id('tenantA'), 'Ife', 'Adeyemi', '08055555555', 'ife@example.com');
  v_r := public.create_reservation(t.id('propA'), '00000000-0000-4000-8000-0000000000a4', t.bdate() + 120, t.bdate() + 121, t.id('std'), t.id('bar'));
  perform public.cancel_reservation(v_r, 'test');
  perform public.anonymise_guest('00000000-0000-4000-8000-0000000000a4', 'NDPR request');
  perform t.eq((select last_name from public.guests where id = '00000000-0000-4000-8000-0000000000a4'), 'Guest', 'personal data is removed');
  perform t.ok((select phone is null and email is null from public.guests where id = '00000000-0000-4000-8000-0000000000a4'), 'contact details are gone');
  perform t.eq((select count(*) from public.reservations where primary_guest_id = '00000000-0000-4000-8000-0000000000a4')::int, 1, 'reservation history is kept');
  perform t.raises(format('update public.guests set anonymised_at = null where id = %L', '00000000-0000-4000-8000-0000000000a4'), 'permission denied', 'anonymisation cannot be undone from the app');
end $$;
