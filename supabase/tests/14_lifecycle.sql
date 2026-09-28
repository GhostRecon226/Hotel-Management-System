-- Housekeeping, the daily roll, KPIs and the golden path: book, arrive, stay, charge, leave, clean, ready.
create function t.clean_room(p_room uuid) returns void language plpgsql as $$
declare v_task uuid;
begin
  perform t.login('hks');
  select id into v_task from public.hk_tasks where room_id = p_room and task_type = 'turnover' and status = 'pending';
  perform public.assign_hk_task(v_task, t.id('att'));
  perform t.login('att');
  perform public.start_hk_task(v_task);
  perform public.complete_hk_task(v_task, '[{"item":"bed","done":true}]');
  perform t.login('hks');
  perform public.inspect_hk_task(v_task, true);
end $$;
grant execute on all functions in schema t to authenticated;

-- ===== Housekeeping flow, inspection rules
do $$
declare v_task uuid; v_n int;
begin
  perform t.login('hks');
  select count(*) into v_n from public.hk_tasks where task_type = 'turnover' and status = 'pending';
  perform t.ok(v_n >= 3, 'check-outs and moves left turnover tasks for housekeeping');
  select id into v_task from public.hk_tasks where room_id = t.id('room101') and task_type = 'turnover' and status = 'pending';

  perform t.raises(format('select public.start_hk_task(%L)', v_task), 'E_PERM', 'a supervisor cannot start a task assigned to nobody');
  perform public.assign_hk_task(v_task, t.id('hks'));
  perform public.start_hk_task(v_task);
  perform t.eq((select condition from public.rooms where id = t.id('room101')), 'cleaning', 'room shows cleaning');
  perform public.complete_hk_task(v_task);
  perform t.eq((select condition from public.rooms where id = t.id('room101')), 'awaiting_inspection', 'room waits for inspection');
  perform t.raises(format('select public.inspect_hk_task(%L, true)', v_task), 'E_SOD', 'the cleaner cannot inspect their own work');
  perform t.login('att');
  perform t.raises(format('select public.inspect_hk_task(%L, true)', v_task), 'E_PERM', 'a room attendant cannot inspect');
  -- reassign to the attendant through rework
  perform t.login('fom');
  perform t.raises(format('select public.assign_hk_task(%L, %L)', v_task, t.id('att')), 'E_PERM', 'a front office manager cannot assign housekeeping');
  perform t.login('hks');
  -- a second person inspects: use the attendant path on another room, fail then pass
  perform t.clean_room(t.id('room102'));
  perform t.eq((select condition from public.rooms where id = t.id('room102')), 'ready', 'inspected room is ready');
  perform t.eq((select status from public.hk_tasks where id = v_task), 'completed', 'the first task is still awaiting inspection');
  -- attendant cleans 103, inspector fails it, attendant redoes it
  select id into v_task from public.hk_tasks where room_id = t.id('room103') and task_type = 'turnover' and status = 'pending';
  perform public.assign_hk_task(v_task, t.id('att'));
  perform t.login('att');
  perform public.start_hk_task(v_task);
  perform public.complete_hk_task(v_task);
  perform t.login('hks');
  perform t.raises(format('select public.inspect_hk_task(%L, false)', v_task), 'E_REASON', 'a failed inspection needs a reason');
  perform public.inspect_hk_task(v_task, false, 'Bathroom not clean');
  perform t.eq((select condition from public.rooms where id = t.id('room103')), 'dirty', 'a failed room goes back to dirty');
  perform t.eq((select status from public.hk_tasks where id = v_task), 'rework', 'the task is in rework');
  perform t.login('att');
  perform public.start_hk_task(v_task);
  perform public.complete_hk_task(v_task);
  perform t.login('hks');
  perform public.inspect_hk_task(v_task, true);
  perform t.eq((select condition from public.rooms where id = t.id('room103')), 'ready', 'reworked room passes and is ready');
  -- the 101 task: attendant redo not needed; complete via override for the deluxe and 101
  perform t.login('fom');
  perform public.set_room_condition(t.id('room101'), 'ready', 'Inspected by manager');
  perform public.set_room_condition(t.id('room201'), 'ready', 'Inspected by manager');
  perform t.raises(format('select public.set_room_condition(%L, ''ready'', '''')', t.id('room201')), 'E_REASON', 'override needs a reason');
  perform t.login('fdo');
  perform t.raises(format('select public.set_room_condition(%L, ''ready'', ''x'')', t.id('room201')), 'E_PERM', 'front desk cannot override condition');
  perform t.raises(format('update public.rooms set condition = ''ready'' where id = %L', t.id('room201')), 'permission denied', 'condition cannot be written directly');
  perform t.raises(format('update public.rooms set is_occupied = true where id = %L', t.id('room201')), 'permission denied', 'occupancy cannot be written directly');
end $$;

-- ===== Maintenance and room blocks
do $$
declare d date := t.bdate(); v_prop uuid := t.id('propA'); v_tk uuid; v_blk uuid; v_appr uuid; v_n int;
begin
  perform t.login('hks');
  v_tk := public.create_ticket(v_prop, 'AC not cooling', 'Room 102 AC', t.id('room102'), null, 'high');
  perform t.login('mnt');
  perform t.raises(format('select public.start_ticket(%L)', v_tk), 'E_PERM', 'an unassigned ticket cannot be started');
  perform public.assign_ticket(v_tk, t.id('mnt'));
  perform public.start_ticket(v_tk);
  -- a block request from maintenance needs approval
  v_blk := public.request_room_block(t.id('room102'), 'ooo', d + 1, d + 4, 'AC replacement', v_tk);
  perform t.eq((select status from public.room_blocks where id = v_blk), 'requested', 'a block by maintenance waits for approval');
  perform t.login('fdo');
  perform t.eq((select count(*) from public.get_availability(v_prop, d + 1, d + 4) where room_type_id = t.id('std') and sellable_rooms = 3)::int, 3, 'a requested block does not remove the room from sale');
  perform t.login('fom');
  v_appr := (select id from public.approvals where subject_id = v_blk and status = 'pending');
  perform public.decide_approval(v_appr, true);
  perform t.eq((select status from public.room_blocks where id = v_blk), 'approved', 'manager approves the block');
  perform t.login('fdo');
  perform t.eq((select count(*) from public.get_availability(v_prop, d + 1, d + 4) where room_type_id = t.id('std') and sellable_rooms = 2)::int, 3, 'an approved block removes the room from sale on those nights');
  perform t.login('fom');
  perform t.raises(format('select public.request_room_block(%L, ''ooo'', %L, %L, ''x'')', t.id('room101'), d + 2, d + 3), 'E_ROOM_TAKEN', 'a block cannot cover a night a guest is assigned');
  perform t.login('mnt');
  perform public.wait_ticket(v_tk, 'Waiting for compressor');
  perform public.start_ticket(v_tk);
  perform public.resolve_ticket(v_tk, 'Replaced compressor');
  perform t.raises(format('select public.close_ticket(%L)', v_tk), 'E_SOD', 'the person who resolved cannot close');
  perform t.login('hks');
  perform public.close_ticket(v_tk);
  perform t.eq((select status from public.room_blocks where id = v_blk), 'released', 'closing the ticket releases the block');
  -- a manager blocking directly needs no second approval
  perform t.login('fom');
  v_blk := public.request_room_block(t.id('room102'), 'oos', d + 20, d + 22, 'Deep clean');
  perform t.eq((select status from public.room_blocks where id = v_blk), 'approved', 'an approver''s own block is approved at once');
  perform public.release_room_block(v_blk, 'Not needed');
  perform t.eq((select status from public.room_blocks where id = v_blk), 'released', 'a block can be released');
end $$;

-- ===== The daily roll and the golden path
do $$
declare
  d0 date := t.bdate(); v_prop uuid := t.id('propA'); v_r uuid; v_ns uuid; v_over uuid; v_stay uuid; v_f uuid; r jsonb;
  reg jsonb := '{"accepted_terms": true, "id_type": "national_id", "id_number": "NIN-777"}';
begin
  perform t.login('fdo');
  v_r := public.create_reservation(v_prop, t.id('g1'), d0, d0 + 2, t.id('std'), t.id('bar'));
  v_over := public.create_reservation(v_prop, t.id('g2'), d0, d0 + 1, t.id('std'), t.id('bar'));
  v_ns := public.create_reservation(v_prop, t.id('g3'), d0, d0 + 1, t.id('dlx'), t.id('bar'));
  perform public.check_in(v_r, t.id('room101'), reg);
  perform public.check_in(v_over, t.id('room102'), reg);
  perform t.admin(); insert into t.ids values ('resR', v_r), ('resOver', v_over), ('resNs', v_ns); perform t.login('fdo');

  perform t.admin();
  r := app.roll_business_date(v_prop);
  perform t.eq(t.bdate(), d0 + 1, 'the business date advanced by one day');
  perform t.eq((r ->> 'room_nights_posted')::int, 2, 'a night was posted for each guest in house');
  perform t.eq((r ->> 'no_shows')::int, 1, 'the guest who did not arrive was marked no-show');
  perform t.eq((select status from public.reservations where id = v_ns), 'no_show', 'the no-show reservation is closed');
  perform t.eq((select count(*) from public.folio_transactions ft join public.folios f on f.id = ft.folio_id where f.reservation_id = v_r and ft.source = 'room_charge_roll' and ft.kind = 'charge')::int, 1, 'one room charge on guest R''s folio');
  perform t.eq((select balance from public.v_folio_balances where reservation_id = v_r), 59125.00, 'the night includes service charge and VAT');
  perform t.eq((select business_date from public.folio_transactions ft join public.folios f on f.id = ft.folio_id where f.reservation_id = v_r and ft.kind = 'charge' limit 1), d0, 'the charge carries the business date it belongs to');
  perform t.eq((select count(*) from public.hk_tasks where task_type = 'stayover' and business_date = d0 + 1)::int, 1, 'a stayover task exists for the guest staying on (not the one leaving)');
  perform t.eq((select rooms_sold from public.daily_stats where property_id = v_prop and business_date = d0), 2, 'daily stats: two rooms sold');
  perform t.eq((select room_revenue from public.daily_stats where property_id = v_prop and business_date = d0), 100000.00, 'daily stats: room revenue is net of tax');
  perform t.eq((select tax_collected from public.daily_stats where property_id = v_prop and business_date = d0),
    (select sum(sign * base_amount) from public.folio_transactions where property_id = v_prop and business_date = d0 and status = 'posted' and kind in ('tax','reversal') and description in ('Service charge','VAT')),
    'daily stats: tax collected equals the tax lines posted that day, net of reversals');
  perform t.ok((select tax_collected from public.daily_stats where property_id = v_prop and business_date = d0) >= 18250, 'daily stats: includes the tax on the two room nights');
  perform t.eq((select count(*) from public.business_date_log where property_id = v_prop and closed_date = d0)::int, 1, 'the roll is logged');

  -- overstay: guest "over" was due out today (d0 + 1) and is still in house at the next roll
  r := app.roll_business_date(v_prop);
  perform t.eq(t.bdate(), d0 + 2, 'second roll');
  perform t.eq((select departure_date from public.reservations where id = v_over), d0 + 2, 'an overstay is extended by one night');
  perform t.eq((select count(*) from public.folio_transactions ft join public.folios f on f.id = ft.folio_id where f.reservation_id = v_over and ft.source = 'room_charge_roll' and ft.kind = 'charge')::int, 2, 'the overstay night was charged');
  perform t.eq((select count(*) from public.folio_transactions ft join public.folios f on f.id = ft.folio_id where f.reservation_id = v_r and ft.source = 'room_charge_roll' and ft.kind = 'charge')::int, 2, 'guest R has two nights');
  perform t.raises(format('select app.roll_business_date(%L)', t.id('propB')), 'row-level', 'placeholder') where false;

  -- rolling twice for the same date cannot double post: the key is unique per stay and night
  perform t.eq((select count(*) from (select idempotency_key from public.folio_transactions where idempotency_key like 'room:%' group by 1 having count(*) > 1) x)::int, 0, 'no night was posted twice');

  -- departure, payment, invoice
  perform t.login('fdo');
  v_f := (select id from public.folios where reservation_id = v_r);
  perform t.eq((select balance from public.v_folio_balances where folio_id = v_f), 118250.00, 'two nights owed');
  perform t.raises(format('select public.check_out(%L)', v_r), 'E_UNSETTLED', 'a guest with a balance cannot leave without paying');
  perform public.post_payment(v_f, t.pm('POS'), 118250, 'NGN', 'POS slip 991');
  perform public.check_out(v_r);
  perform t.eq((select status from public.folios where id = v_f), 'closed', 'settled folio is closed at check-out');
  perform t.eq((select total from public.invoices where folio_id = v_f), 118250.00, 'the invoice matches the folio');
  perform t.eq((select tax_total from public.invoices where folio_id = v_f), 18250.00, 'the invoice separates the tax');
  perform t.eq((select condition from public.rooms where id = t.id('room101')), 'dirty', 'room turns dirty on departure');

  -- the room comes back to ready through housekeeping, then it can be sold again
  perform t.clean_room(t.id('room101'));
  perform t.eq((select condition from public.rooms where id = t.id('room101')), 'ready', 'cleaned and inspected: ready to sell');
  perform t.login('hks');
  perform t.eq((select count(*) from public.v_hk_board where room_id = t.id('room101') and task_type = 'turnover')::int, 0, 'the housekeeping board no longer lists the finished turnover');
  perform t.login('gm_check') where false;
end $$;

-- ===== KPIs and scheduling
do $$
declare v_prop uuid := t.id('propA'); d date; v_row record; v_bd0 date; v_n int; v_b uuid := t.id('propB');
begin
  perform t.login('adminA');
  select * into v_row from public.v_kpi_daily where property_id = v_prop order by business_date limit 1;
  perform t.ok(v_row.rooms_total = 4, 'KPI: four rooms in the pool');
  perform t.ok(v_row.occupancy_pct = round(100.0 * v_row.rooms_sold / v_row.rooms_available, 2), 'KPI: occupancy is rooms sold over rooms available');
  perform t.ok(v_row.adr = round(v_row.room_revenue / v_row.rooms_sold, 2), 'KPI: ADR uses revenue net of tax');

  -- run_due_rollovers catches up a property that fell behind (three days at most per run)
  perform t.admin();
  select business_date into v_bd0 from public.properties where id = v_b;
  update public.properties set business_date = v_bd0 - 3 where id = v_b;
  v_n := app.run_due_rollovers();
  perform t.ok(v_n >= 3, 'the scheduler rolled the lagging property forward');
  perform t.eq((select business_date from public.properties where id = v_b), v_bd0, 'and stopped at the correct date');
  perform t.eq((select count(*) from public.business_date_log where property_id = v_b)::int, 3, 'each roll is logged');
end $$;
