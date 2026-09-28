-- Reservations, availability, check-in guards, room moves, stay changes, check-out.

-- ===== Part 1: booking, availability, cancellation, no-show
do $$
declare
  d date := t.bdate(); v_prop uuid := t.id('propA'); v_a uuid; v_b uuid; v_ns uuid; v_c uuid; v_fee numeric; v_n int; v_ids uuid[] := '{}';
begin
  perform t.login('fdo');
  for v_n in 1..3 loop
    v_ids := v_ids || public.create_reservation(v_prop, t.id('g1'), d + 40, d + 42, t.id('std'), t.id('bar'));
  end loop;
  perform t.raises(format('select public.create_reservation(%L, %L, %L, %L, %L, %L)', v_prop, t.id('g2'), d + 40, d + 42, t.id('std'), t.id('bar')),
                   'E_UNAVAILABLE', 'a fourth booking for three rooms is refused');
  perform t.eq((select count(*) from public.get_availability(v_prop, d + 40, d + 42) where available = 0 and room_type_id = t.id('std'))::int, 2, 'availability shows the type is full on both nights');
  perform public.create_reservation(v_prop, t.id('g2'), d + 42, d + 43, t.id('std'), t.id('bar'));
  perform t.ok(true, 'the check-out day of other bookings is open for a new arrival');
  perform t.raises(format('select public.create_reservation(%L, %L, %L, %L, %L, %L, 5)', v_prop, t.id('g2'), d + 60, d + 61, t.id('std'), t.id('bar')), 'E_OCCUPANCY', 'occupancy limit is enforced');
  perform t.raises(format('select public.create_reservation(%L, %L, %L, %L, %L, %L)', v_prop, t.id('g2'), d - 1, d + 1, t.id('std'), t.id('bar')), 'E_DATES', 'arrival in the past is refused');
  perform t.raises(format('select public.create_reservation(%L, %L, %L, %L, %L, %L)', v_prop, t.id('g2'), d + 5, d + 5, t.id('std'), t.id('bar')), 'E_DATES', 'departure must be after arrival');

  v_a := public.create_reservation(v_prop, t.id('g3'), d + 70, d + 72, t.id('dlx'), t.id('bar'), 2, 0, 'phone', 'confirmed', null, null, null, 'none', 24, null, null, null, 'idem-1');
  v_b := public.create_reservation(v_prop, t.id('g3'), d + 70, d + 72, t.id('dlx'), t.id('bar'), 2, 0, 'phone', 'confirmed', null, null, null, 'none', 24, null, null, null, 'idem-1');
  perform t.eq(v_a, v_b, 'the same idempotency key returns the same reservation');
  perform t.eq((select total_amount from public.reservations where id = v_a), 180000.00, 'two nights priced from the rate plan');

  perform public.assign_room(v_ids[1], t.id('room101'));
  perform t.raises(format('select public.assign_room(%L, %L)', v_ids[2], t.id('room101')), 'E_ROOM_TAKEN', 'a room cannot be given to two overlapping stays');
  perform t.raises(format('select public.assign_room(%L, %L)', v_ids[2], t.id('room201')), 'E_ROOM_TYPE', 'room type must match the booking');
  perform t.raises(format('select public.create_reservation(%L, %L, %L, %L, %L, %L, 1, 0, ''direct'', ''confirmed'', null, null, null, ''none'', 24, 30000)', v_prop, t.id('g2'), d + 80, d + 81, t.id('std'), t.id('bar')), 'E_PERM', 'front desk cannot override a rate');

  perform public.modify_reservation(v_ids[3], p_departure => d + 41);
  perform t.eq((select total_amount from public.reservations where id = v_ids[3]), 50000.00, 'shortening the stay reprices it');
  perform t.eq((select count(*) from public.reservation_nights where reservation_id = v_ids[3])::int, 1, 'the released night is gone');

  -- cancellation: free more than two days before, one night's fee inside the window
  v_c := public.create_reservation(v_prop, t.id('g2'), d + 10, d + 12, t.id('dlx'), t.id('bar'));
  perform t.eq(public.cancel_reservation(v_c, 'Change of plans'), 0::numeric, 'cancelling early is free');
  perform t.eq((select status from public.folios where reservation_id = v_c), 'closed', 'a cancelled reservation with no balance closes its folio');
  v_c := public.create_reservation(v_prop, t.id('g2'), d + 1, d + 3, t.id('dlx'), t.id('bar'));
  perform t.raises(format('select public.cancel_reservation(%L, ''x'', true)', v_c), 'E_PERM', 'front desk cannot waive a fee');
  perform t.raises(format('select public.cancel_reservation(%L, '''')', v_c), 'E_REASON', 'cancelling needs a reason');
  v_fee := public.cancel_reservation(v_c, 'Late cancellation');
  perform t.eq(v_fee, 90000.00, 'late cancellation costs one night');
  perform t.eq((select balance from public.v_folio_balances where reservation_id = v_c), 90000.00, 'the fee is on the folio');
  perform t.raises(format('select public.cancel_reservation(%L, ''again'')', v_c), 'E_STATE', 'a cancelled reservation cannot be cancelled again');
  perform t.login('fom');
  perform public.reinstate_reservation(v_c, 'Guest called back');
  perform t.eq((select status from public.reservations where id = v_c), 'confirmed', 'manager reinstates a cancelled reservation');
  perform t.eq(public.cancel_reservation(v_c, 'Cleanup', true), 0::numeric, 'manager can waive a fee');

  -- no-show
  perform t.login('fdo');
  v_ns := public.create_reservation(v_prop, t.id('g3'), d, d + 1, t.id('std'), t.id('bar'));
  v_c := public.create_reservation(v_prop, t.id('g1'), d + 1, d + 2, t.id('std'), t.id('bar'));
  perform t.raises(format('select public.mark_no_show(%L)', v_c), 'E_DATES', 'a guest who is not yet due cannot be a no-show');
  v_fee := public.mark_no_show(v_ns);
  perform t.eq(v_fee, 50000.00, 'no-show costs one night');
  perform t.eq((select status from public.reservations where id = v_ns), 'no_show', 'reservation is marked no-show');
  perform t.eq((select count(*) from public.folio_transactions t2 join public.folios f on f.id = t2.folio_id where f.reservation_id = v_ns and t2.source = 'no_show_fee')::int, 1, 'no-show fee is posted once');
  perform t.admin();
  insert into t.ids values ('resHeld', v_ids[1]);
  perform t.login('fdo');
end $$;

-- ===== Part 2: check-in guards
do $$
declare
  d date := t.bdate(); v_prop uuid := t.id('propA'); v_a uuid; v_b uuid; v_stay uuid; v_fut uuid;
  reg jsonb := '{"accepted_terms": true, "id_type": "national_id", "id_number": "NIN-123"}';
begin
  perform t.login('fdo');
  v_a := public.create_reservation(v_prop, t.id('g1'), d, d + 3, t.id('std'), t.id('bar'));
  v_b := public.create_reservation(v_prop, t.id('g2'), d, d + 2, t.id('std'), t.id('prepaid'));
  perform t.admin(); insert into t.ids values ('resA', v_a), ('resB', v_b); perform t.login('fdo');

  perform t.eq((select deposit_required from public.reservations where id = v_b), 50000.00, 'deposit rate plan asks for half of the stay');
  perform t.raises(format('select public.check_in(%L, %L, ''{"accepted_terms": true}'')', v_a, t.id('room101')), 'E_ID_REQUIRED', 'check-in needs an ID');
  perform t.raises(format('select public.check_in(%L, %L, ''{"id_type":"passport","id_number":"A1"}'')', v_a, t.id('room101')), 'E_REGISTRATION', 'check-in needs the registration card accepted');
  perform t.raises(format('select public.check_in(%L, null, %L)', v_a, reg), 'E_ROOM', 'check-in needs a room');
  perform t.admin(); update public.rooms set condition = 'dirty' where id = t.id('room101'); perform t.login('fdo');
  perform t.raises(format('select public.check_in(%L, %L, %L)', v_a, t.id('room101'), reg), 'E_ROOM_NOT_READY', 'a dirty room cannot be checked into');
  perform t.admin(); update public.rooms set condition = 'ready' where id = t.id('room101'); perform t.login('fdo');
  perform t.raises(format('select public.check_in(%L, %L, %L)', (select id from public.reservations where arrival_date = d + 1 and status = 'confirmed' limit 1), t.id('room101'), reg), 'E_DATES', 'check-in before the arrival date is refused');

  v_stay := public.check_in(v_a, t.id('room101'), reg);
  perform t.eq((select status from public.reservations where id = v_a), 'checked_in', 'reservation is checked in');
  perform t.eq((select is_occupied from public.rooms where id = t.id('room101')), true, 'room becomes occupied');
  perform t.eq((select count(*) from public.guest_documents where doc_number = 'NIN-123')::int, 1, 'the ID was recorded once');
  perform t.ok(not (select registration ? 'id_number' from public.stays where id = v_stay), 'the ID number is not copied into the stay record');
  perform t.raises(format('select public.check_in(%L, %L, %L)', v_a, t.id('room101'), reg), 'E_STATE', 'a guest cannot check in twice');

  perform t.raises(format('select public.check_in(%L, %L, %L)', v_b, t.id('room102'), reg), 'E_DEPOSIT', 'a deposit guarantee must be paid before check-in');
  perform public.post_payment((select id from public.folios where reservation_id = v_b), t.pm('TRANSFER'), 50000, 'NGN', 'deposit', true);
  perform t.raises(format('select public.check_in(%L, %L, %L)', v_b, t.id('room101'), reg), 'E_ROOM_OCCUPIED', 'an occupied room cannot be checked into');
  perform public.check_in(v_b, t.id('room102'), reg);
  perform t.eq((select status from public.reservations where id = v_b), 'checked_in', 'deposit paid, guest checks in');

  -- walk-in takes the last standard room
  v_fut := public.walk_in_check_in(v_prop, t.id('g3'), d + 1, t.id('room103'), t.id('bar'), 1, 0, reg);
  perform t.eq((select booking_source from public.reservations r join public.stays s on s.reservation_id = r.id where s.id = v_fut), 'walk_in', 'walk-in is recorded as a walk-in booking');
  perform t.admin(); insert into t.ids values ('stayW', v_fut); perform t.login('fdo');
end $$;

-- ===== Part 3: room moves and stay changes
do $$
declare
  d date := t.bdate(); v_prop uuid := t.id('propA'); v_a uuid := t.id('resA'); v_b uuid := t.id('resB'); v_fut uuid; v_n numeric;
begin
  perform t.login('fdo');
  -- move guest A from 101 (STD) to the deluxe 201 as a free upgrade
  perform t.raises(format('select public.move_room(%L, %L, ''Upgrade'', true)', v_a, t.id('room201')), 'E_PERM', 'front desk cannot give a free upgrade');
  perform t.raises(format('select public.move_room(%L, %L, '''')', v_a, t.id('room201')), 'E_REASON', 'a move needs a reason');
  perform t.login('fom');
  perform public.move_room(v_a, t.id('room201'), 'VIP upgrade', true);
  perform t.eq((select is_occupied from public.rooms where id = t.id('room201')), true, 'new room is occupied');
  perform t.eq((select is_occupied from public.rooms where id = t.id('room101')), false, 'old room is vacant');
  perform t.eq((select condition from public.rooms where id = t.id('room101')), 'dirty', 'old room is dirty');
  perform t.eq((select count(*) from public.hk_tasks where room_id = t.id('room101') and task_type = 'turnover' and status = 'pending')::int, 1, 'a cleaning task was created for the old room');
  perform t.eq((select rate_amount from public.reservation_nights where reservation_id = v_a and stay_date = d), 50000.00, 'a free upgrade keeps the booked rate');
  perform t.eq((select room_type_id from public.reservation_nights where reservation_id = v_a and stay_date = d), t.id('dlx'), 'but the night counts against the deluxe inventory');
  perform t.eq((select count(*) from public.room_assignments where reservation_id = v_a and status = 'active')::int, 1, 'one active room at a time');
  -- guest B cannot move into the still-dirty room 101
  perform t.raises(format('select public.move_room(%L, %L, ''Noisy room'')', v_b, t.id('room101')), 'E_ROOM_NOT_READY', 'a dirty room is not a move target');
  perform public.set_room_condition(t.id('room101'), 'ready', 'Cleaned early');
  perform public.move_room(v_b, t.id('room101'), 'Noisy room');
  perform t.login('adminA');
  perform t.eq((select count(*) from public.audit_events where action = 'room.status.override')::int, 1, 'condition override is audited');
  perform t.login('fom');

  -- extend and shorten
  perform t.login('fdo');
  v_fut := public.create_reservation(v_prop, t.id('g1'), d + 2, d + 4, t.id('std'), t.id('bar'));
  perform public.assign_room(v_fut, t.id('room101'));
  perform t.raises(format('select public.extend_stay(%L, %L)', v_b, d + 3), 'E_ROOM_TAKEN', 'a stay cannot extend into a room promised to another guest');
  perform public.extend_stay(v_a, d + 4);
  perform t.eq((select departure_date from public.reservations where id = v_a), d + 4, 'guest A extended by a night');
  perform t.eq((select count(*) from public.reservation_nights where reservation_id = v_a)::int, 4, 'the extra night is priced');
  perform public.extend_stay(v_a, d + 2);
  perform t.eq((select count(*) from public.reservation_nights where reservation_id = v_a)::int, 2, 'shortening removes unused nights');
  perform t.raises(format('select public.extend_stay(%L, %L)', v_a, d), 'E_DATES', 'a stay cannot be shortened to today or earlier');
  perform t.raises(format('select public.modify_reservation(%L, p_notes => ''x'')', v_a), 'E_STATE', 'an in-house reservation cannot be edited as a booking');
end $$;

-- ===== Part 4: check-out
do $$
declare
  d date := t.bdate(); v_a uuid := t.id('resA'); v_b uuid := t.id('resB'); v_w uuid; v_appr uuid; v_stayw uuid := t.id('stayW');
  v_folio uuid; v_bal numeric;
begin
  perform t.login('fdo');
  -- walk-in with nothing owed leaves; the room turns over
  select reservation_id into v_w from public.stays where id = v_stayw;
  perform public.check_out(v_w);
  perform t.eq((select status from public.reservations where id = v_w), 'checked_out', 'guest checked out');
  perform t.eq((select condition from public.rooms where id = t.id('room103')), 'dirty', 'room is dirty after check-out');
  perform t.eq((select is_occupied from public.rooms where id = t.id('room103')), false, 'room is vacant after check-out');
  perform t.login('hks');
  perform t.eq((select count(*) from public.hk_tasks where room_id = t.id('room103') and status = 'pending')::int, 1, 'housekeeping gets a turnover task');
  perform t.login('fdo');
  perform t.eq((select status from public.folios where reservation_id = v_w), 'closed', 'a settled folio closes');
  perform t.raises(format('select public.check_out(%L)', v_w), 'E_STATE', 'a guest cannot check out twice');
  -- undo on the same day
  perform t.raises(format('select public.undo_checkout(%L, ''oops'')', v_stayw), 'E_PERM', 'front desk cannot undo a check-out');
  perform t.login('fom');
  perform public.undo_checkout(v_stayw, 'Guest came back for luggage');
  perform t.eq((select status from public.reservations where id = v_w), 'checked_in', 'check-out undone');
  perform t.eq((select is_occupied from public.rooms where id = t.id('room103')), true, 'room is occupied again');
  perform t.login('hks');
  perform t.eq((select count(*) from public.hk_tasks where room_id = t.id('room103') and status = 'pending')::int, 0, 'the cleaning task was cancelled');
  perform t.login('fom');
  perform t.eq((select status from public.folios where reservation_id = v_w), 'open', 'folio reopened');
  perform public.check_out(v_w);

  -- guest B paid a deposit and has no charges: the credit must be refunded first
  perform t.login('fdo');
  perform t.raises(format('select public.check_out(%L)', v_b), 'E_CREDIT', 'a credit balance blocks check-out until refunded');
  perform t.login('csh');
  v_appr := public.request_refund((select id from public.folios where reservation_id = v_b), t.pm('TRANSFER'), 50000, 'NGN', 'Guest left early');
  perform t.login('acc');
  perform public.decide_approval(v_appr, true);
  perform t.login('fdo');
  perform public.check_out(v_b);
  perform t.eq((select status from public.reservations where id = v_b), 'checked_out', 'guest B checked out after the refund');
  perform t.eq((select count(*) from public.reservation_nights where reservation_id = v_b)::int, 0, 'leaving early releases the unused nights');

  -- guest A owes money: needs an approved exception
  perform public.post_charge((select id from public.folios where reservation_id = v_a), t.cc('RESTAURANT'), 20000, 'NGN', 'Dinner');
  v_bal := (select balance from public.v_folio_balances where reservation_id = v_a);
  perform t.raises(format('select public.check_out(%L)', v_a), 'E_UNSETTLED', 'an unpaid balance blocks check-out');
  v_appr := public.request_unsettled_checkout(v_a, 'Company will pay by transfer');
  perform t.raises(format('select public.check_out(%L, %L)', v_a, v_appr), 'E_UNSETTLED', 'a pending approval is not enough');
  perform t.raises(format('select public.decide_approval(%L, true)', v_appr), 'E_PERM', 'front desk cannot approve the exception');
  perform t.login('fom');
  perform public.decide_approval(v_appr, true);
  perform t.login('fdo');
  perform public.check_out(v_a, v_appr);
  perform t.eq((select status from public.reservations where id = v_a), 'checked_out', 'guest A checked out with an approved exception');
  perform t.eq((select status from public.folios where reservation_id = v_a), 'open', 'the folio stays open so the balance can be collected');
  perform t.eq((select count(*) from public.invoices i join public.folios f on f.id = i.folio_id where f.reservation_id = v_a)::int, 1, 'an invoice was issued');
  perform t.eq((select balance_due from public.invoices i join public.folios f on f.id = i.folio_id where f.reservation_id = v_a), v_bal, 'the invoice shows what is still owed');
  perform t.raises(format('select public.check_out(%L, %L)', v_a, v_appr), 'E_STATE', 'the approval cannot be used twice');
  perform public.post_payment((select id from public.folios where reservation_id = v_a), t.pm('TRANSFER'), v_bal, 'NGN', 'settled later');
  perform t.eq((select balance from public.v_folio_balances where reservation_id = v_a), 0.00, 'late payment settles the folio');
end $$;
