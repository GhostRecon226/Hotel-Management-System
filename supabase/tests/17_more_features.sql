-- Remaining R1 behaviours that the requirement list cites.

-- ===== Signup edges, country template, subscription cancel (hotel C in Ghana)
select t.admin();
do $$
declare v_unv uuid := gen_random_uuid(); v_c uuid := gen_random_uuid(); r jsonb; v_n int;
begin
  perform t.admin();
  insert into auth.users (id, email, email_confirmed_at) values (v_unv, 'unverified@test.local', null);
  insert into t.ids values ('unv', v_unv);
  perform t.login('unv');
  perform t.raises('select public.create_hotel(''X Ltd'', ''NG'', ''X Inn'')', 'E_EMAIL_UNVERIFIED', 'an unconfirmed email cannot create a hotel');
  perform t.login('adminA');
  perform t.raises('select public.create_hotel(''Again'', ''NG'', ''Again Inn'')', 'E_ALREADY_HAS_HOTEL', 'an account can only belong to one hotel');
  perform t.eq((select count(*) from public.tax_rates where property_id = t.id('propA'))::int, 3, 'Nigeria template seeded three tax lines');
  perform t.eq((select count(*) from public.tax_rates where property_id = t.id('propA') and verified)::int, 0, 'all seeded tax lines start unverified');
  perform t.eq((select rate from public.tax_rates where property_id = t.id('propA') and code = 'VAT'), 7.5, 'VAT is seeded at 7.5%');
  perform t.eq((select base_currency from public.properties where id = t.id('propA')), 'NGN', 'Nigeria property uses naira');
  perform t.eq((select timezone from public.properties where id = t.id('propA')), 'Africa/Lagos', 'and the Lagos timezone');

  perform t.admin();
  insert into auth.users (id, email) values (v_c, 'ownerC@test.local');
  insert into t.ids values ('ownerC', v_c);
  perform t.login('ownerC');
  r := public.create_hotel('Accra Stay Ltd', 'GH', 'Accra Stay', 'Kofi Mensah', 'Accra');
  perform t.eq((select base_currency from public.properties where id = (r ->> 'property_id')::uuid), 'GHS', 'Ghana property uses cedi');
  perform t.eq((select count(*) from public.tax_rates where property_id = (r ->> 'property_id')::uuid)::int, 0, 'no tax lines are guessed for other countries');
  perform t.ok(exists (select 1 from public.charge_codes where property_id = (r ->> 'property_id')::uuid and code = 'ROOM'), 'the engine''s charge codes exist for every property');
  perform t.eq((select status from public.tenant_subscriptions where tenant_id = (r ->> 'tenant_id')::uuid), 'trial', 'a new hotel starts on trial');
  perform t.ok((select trial_ends_at > now() + interval '29 days' from public.tenant_subscriptions where tenant_id = (r ->> 'tenant_id')::uuid), 'for thirty days');
  perform public.cancel_subscription('Not continuing');
  perform t.eq((select status from public.tenant_subscriptions where tenant_id = (r ->> 'tenant_id')::uuid), 'cancelled', 'the hotel can cancel its own subscription');
  perform t.raises('select public.create_property(''Another'')', 'E_READ_ONLY', 'a cancelled account is read-only');
end $$;

-- ===== Reservation variants
select t.admin();
do $$
declare d date := t.bdate(); v_prop uuid := t.id('propA'); v_r uuid; v_t uuid;
begin
  perform t.login('fdo');
  v_r := public.create_reservation(v_prop, t.id('g2'), d + 150, d + 152, t.id('std'), t.id('bar'), 2, 0, 'corporate', 'confirmed', 'Dangote Group');
  perform t.eq((select company_name from public.reservations where id = v_r), 'Dangote Group', 'a corporate booking keeps the company name (no company entity in R1)');
  perform t.eq((select booking_source from public.reservations where id = v_r), 'corporate', 'and its booking source');
  perform public.set_reservation_guests(v_r, array[t.id('g3')]);
  perform t.eq((select count(*) from public.reservation_guests where reservation_id = v_r)::int, 2, 'additional guests can be added to a booking');
  perform public.set_arrival_ready(v_r, true);
  perform t.eq((select arrival_ready from public.reservations where id = v_r), true, 'the arrival-ready flag is a flag, not a status');
  perform t.raises(format('select public.create_reservation(%L, %L, %L, %L, %L, %L, 1, 0, ''direct'', ''confirmed'', null, null, null, ''none'', 24, 30000, ''Manager deal'')', v_prop, t.id('g2'), d + 160, d + 161, t.id('std'), t.id('bar')), 'E_PERM', 'a rate override is refused without permission');
  perform t.login('fom');
  v_r := public.create_reservation(v_prop, t.id('g2'), d + 160, d + 161, t.id('std'), t.id('bar'), 1, 0, 'direct', 'confirmed', null, null, null, 'none', 24, 30000, 'Manager deal');
  perform t.eq((select total_amount from public.reservations where id = v_r), 30000.00, 'an authorised override sets the rate');
  perform t.raises(format('select public.create_reservation(%L, %L, %L, %L, %L, %L, 1, 0, ''direct'', ''confirmed'', null, null, null, ''none'', 24, 30000, '''')', v_prop, t.id('g2'), d + 162, d + 163, t.id('std'), t.id('bar')), 'E_REASON', 'an override needs a reason');
  perform t.login('adminA');
  perform t.eq((select count(*) from public.audit_events where action = 'res.rate.override')::int, 1, 'the override is audited');
  -- tentative hold, confirm
  perform t.login('fdo');
  v_t := public.create_reservation(v_prop, t.id('g1'), d + 170, d + 171, t.id('std'), t.id('bar'), 1, 0, 'phone', 'tentative', null, null, null, 'none', 48);
  perform t.ok((select hold_expires_at > now() + interval '47 hours' from public.reservations where id = v_t), 'a tentative booking has a hold expiry');
  perform public.confirm_reservation(v_t);
  perform t.ok((select status = 'confirmed' and hold_expires_at is null from public.reservations where id = v_t), 'confirming removes the hold expiry');
  perform t.raises(format('select public.confirm_reservation(%L)', v_t), 'E_STATE', 'a confirmed booking cannot be confirmed again');
end $$;

-- ===== Stay in house: views, void check-in, service requests, receipts, ID document access
select t.admin();
do $$
declare
  d date := t.bdate(); v_prop uuid := t.id('propA'); v_r uuid; v_stay uuid; v_sr uuid; v_bal numeric; v_f uuid; v_inv uuid;
  reg jsonb := '{"accepted_terms": true, "id_type": "passport", "id_number": "P-9988"}';
begin
  perform t.login('fdo');
  v_r := public.create_reservation(v_prop, t.id('g1'), d, d + 2, t.id('dlx'), t.id('bar'));
  perform t.eq((select count(*) from public.v_arrivals where reservation_id = v_r and last_name = 'Okafor')::int, 1, 'the arrivals list shows the guest due today');
  v_stay := public.check_in(v_r, t.id('room201'), reg);
  perform t.eq((select count(*) from public.v_arrivals where reservation_id = v_r)::int, 0, 'a checked-in guest leaves the arrivals list');
  perform t.eq((select count(*) from public.v_in_house where reservation_id = v_r and room_number = '201')::int, 1, 'and appears in house with the room number');
  perform t.eq((select board_status from public.v_room_board where room_id = t.id('room201')), 'occupied', 'the room board shows occupied');
  -- void a check-in on the same day
  perform t.raises(format('select public.void_check_in(%L, ''x'')', v_stay), 'E_PERM', 'front desk cannot void a check-in');
  perform t.login('fom');
  perform public.void_check_in(v_stay, 'Wrong reservation');
  perform t.eq((select status from public.stays where id = v_stay), 'voided', 'a same-day check-in can be voided');
  perform t.eq((select status from public.reservations where id = v_r), 'confirmed', 'the booking is confirmed again');
  perform t.eq((select is_occupied from public.rooms where id = t.id('room201')), false, 'the room is vacant');
  perform t.eq((select status from public.room_assignments where reservation_id = v_r and status = 'held' limit 1), 'held', 'and held for the guest');
  perform t.login('fdo');
  v_stay := public.check_in(v_r, t.id('room201'), reg);
  perform t.ok(true, 'the guest can be checked in again');
  
  -- ID documents are visible only to roles with guest.idocs.view
  perform t.ok((select count(*) from public.guest_documents where guest_id = t.id('g1')) >= 1, 'front desk sees ID documents');
  perform t.login('rsv');
  perform t.eq((select count(*) from public.guest_documents where guest_id = t.id('g1'))::int, 0, 'reservation officers do not see ID documents');

  -- service request with a charge
  perform t.login('fdo');
  v_f := (select id from public.folios where reservation_id = v_r);
  v_bal := (select balance from public.v_folio_balances where folio_id = v_f);
  v_sr := public.create_service_request(v_r, 'laundry', 'Wash two shirts', true, 3000, 'NGN', t.cc('LAUNDRY'));
  perform t.eq((select room_id from public.service_requests where id = v_sr), t.id('room201'), 'the request is tied to the guest''s room');
  perform public.assign_service_request(v_sr, t.id('att'));
  perform public.start_service_request(v_sr);
  perform public.complete_service_request(v_sr);
  perform t.eq((select balance from public.v_folio_balances where folio_id = v_f), v_bal + 3000 * 1.1825, 'completing a chargeable request posts the charge with tax');
  perform t.eq((select status from public.service_requests where id = v_sr), 'completed', 'the request is completed');
  perform t.raises(format('select public.complete_service_request(%L)', v_sr), 'E_STATE', 'a request completes once');
  v_sr := public.create_service_request(v_r, 'extra towels', 'Two towels');
  perform public.cancel_service_request(v_sr, 'Guest changed mind');
  perform t.eq((select status from public.service_requests where id = v_sr), 'cancelled', 'a request can be cancelled');

  -- receipt
  v_inv := public.issue_invoice(v_f, 'receipt');
  perform t.ok((select kind = 'receipt' and invoice_no like '%-RCT-%' from public.invoices where id = v_inv), 'receipts have their own number series');
  perform t.ok((select balance_due > 0 from public.invoices where id = v_inv), 'an interim document shows what is still due');
end $$;

-- ===== Housekeeping extras: own-task scope, inspection switched off
select t.admin();
do $$
declare v_task uuid;
begin
  perform t.login('att');
  perform t.eq((select count(*) from public.hk_tasks where assigned_to is distinct from t.id('att'))::int, 0, 'an attendant sees only their own tasks');
  perform t.ok((select count(*) from public.hk_tasks) > 0, 'and does see their own');
  perform t.login('adminA');
  update public.properties set inspection_required = false where id = t.id('propA');
  perform t.login('hks');
  v_task := public.create_hk_task(t.id('room102'), 'deep_clean', 'Quarterly');
  perform public.assign_hk_task(v_task, t.id('att'));
  perform t.login('att');
  perform public.start_hk_task(v_task);
  perform public.complete_hk_task(v_task);
  perform t.login('hks');
  perform t.eq((select condition from public.rooms where id = t.id('room102')), 'ready', 'with inspection switched off a finished room is ready at once');
  perform t.eq((select status from public.hk_tasks where id = v_task), 'inspected', 'and the task closes itself');
  perform t.login('adminA');
  update public.properties set inspection_required = true where id = t.id('propA');
end $$;

-- ===== Maintenance extras and oversold protection
select t.admin();
do $$
declare d date := t.bdate(); v_prop uuid := t.id('propA'); v_tk uuid; v_r uuid;
begin
  perform t.login('mnt');
  v_tk := public.create_ticket(v_prop, 'Loose handle', null, t.id('room103'));
  perform public.assign_ticket(v_tk, t.id('mnt'));
  perform public.start_ticket(v_tk);
  perform public.resolve_ticket(v_tk, 'Tightened');
  perform public.reopen_ticket(v_tk, 'Handle loose again');
  perform t.eq((select status from public.maintenance_tickets where id = v_tk), 'assigned', 'a resolved ticket can be reopened with a reason');
  perform public.cancel_ticket(v_tk, 'Duplicate of another ticket');
  perform t.eq((select status from public.maintenance_tickets where id = v_tk), 'cancelled', 'a ticket can be cancelled with a reason');
  perform t.login('hks');
  perform t.raises(format('select public.cancel_ticket(%L, ''again'')', v_tk), 'E_PERM', 'housekeeping cannot cancel tickets');

  -- blocking the only deluxe room while it is sold out is refused
  perform t.login('fdo');
  v_r := public.create_reservation(v_prop, t.id('g3'), d + 90, d + 92, t.id('dlx'), t.id('bar'));
  perform t.login('fom');
  perform t.raises(format('select public.request_room_block(%L, ''ooo'', %L, %L, ''Renovation'')', t.id('room201'), d + 90, d + 92), 'E_OVERSOLD', 'a block that would leave the type oversold is refused');
end $$;

-- ===== Roll failure is reported, expired holds are released (runs last: it moves business dates)
select t.admin();
do $$
declare v_b uuid := t.id('propB'); v_bd date; v_prop uuid := t.id('propA'); v_t uuid; v_n int;
begin
  perform t.login('fdo');
  v_t := public.create_reservation(v_prop, t.id('g1'), t.bdate() + 200, t.bdate() + 201, t.id('std'), t.id('bar'), 1, 0, 'phone', 'tentative', null, null, null, 'none', 1);
  perform t.admin();
  update public.reservations set hold_expires_at = now() - interval '1 hour' where id = v_t;
  perform app.roll_business_date(v_prop);
  perform t.eq((select status from public.reservations where id = v_t), 'cancelled', 'an expired hold is released at the roll');
  perform t.eq((select cancellation_reason from public.reservations where id = v_t), 'Hold expired', 'with the reason recorded');

  select business_date into v_bd from public.properties where id = v_b;
  delete from public.charge_codes where property_id = v_b and code = 'ROOM';
  update public.properties set business_date = v_bd - 1 where id = v_b;
  perform app.run_due_rollovers();
  perform t.eq((select business_date from public.properties where id = v_b), v_bd - 1, 'a failed roll changes nothing');
  select count(*) into v_n from public.notifications where property_id = v_b and kind = 'rollover_failed';
  perform t.ok(v_n >= 1, 'and tells the managers');
end $$;
