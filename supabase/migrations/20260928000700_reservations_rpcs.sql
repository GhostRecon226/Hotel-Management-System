-- HMS 0007: reservation lifecycle, check-in, room moves, stay changes, check-out.
-- Every change to a reservation, stay or room assignment goes through one of these functions.

-- ---------------------------------------------------------------- helpers
create or replace function app.load_res(p_id uuid, p_lock boolean default true) returns public.reservations
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations;
begin
  if p_lock then select * into r from public.reservations where id = p_id for update;
  else select * into r from public.reservations where id = p_id; end if;
  if not found then perform app.fail('E_NOT_FOUND', 'Reservation not found.'); end if;
  return r;
end $$;

create or replace function app.main_folio(p_res uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from public.folios where reservation_id = p_res order by opened_at, folio_no limit 1
$$;

-- Prices every night from p_from to the day before departure and rewrites reservation_nights and total_amount.
create or replace function app.write_nights(p_res uuid, p_from date, p_override numeric default null, p_room_type uuid default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations; rp public.rate_plans; d date; v_amt numeric; v_cur text; v_type uuid;
begin
  select * into r from public.reservations where id = p_res;
  select * into rp from public.rate_plans where id = r.rate_plan_id;
  v_type := coalesce(p_room_type, r.room_type_id);
  delete from public.reservation_nights where reservation_id = r.id and stay_date >= p_from;
  d := p_from;
  while d < r.departure_date loop
    if p_override is not null then
      v_amt := p_override; v_cur := r.currency;
    else
      select n.amount, n.currency into v_amt, v_cur from app.night_price(r.property_id, r.rate_plan_id, v_type, d) n;
      if v_amt is null then
        perform app.fail('E_NO_RATE', format('No rate is set for this room type and rate plan on %s.', d));
      end if;
      if v_cur <> r.currency then
        perform app.fail('E_CURRENCY', 'All nights of a reservation must be priced in one currency.');
      end if;
    end if;
    insert into public.reservation_nights (tenant_id, property_id, reservation_id, stay_date, room_type_id, rate_amount, currency, price_includes_tax)
    values (r.tenant_id, r.property_id, r.id, d, v_type, v_amt, r.currency, rp.price_includes_tax);
    d := d + 1;
  end loop;
  update public.reservations set total_amount = (select coalesce(sum(rate_amount), 0) from public.reservation_nights where reservation_id = r.id),
         updated_at = now() where id = r.id;
end $$;

create or replace function app.policy_fee(p_policy jsonb, r public.reservations, p_days_before int) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_type text := coalesce(p_policy ->> 'type', 'none'); v_val numeric := coalesce((p_policy ->> 'value')::numeric, 0); v_fee numeric := 0;
begin
  if v_type = 'none' then return 0; end if;
  if p_days_before is not null and p_days_before >= coalesce((p_policy ->> 'free_until_days')::int, 0)
     and p_policy ? 'free_until_days' and (p_policy ->> 'free_until_days')::int > 0 then
    return 0;
  end if;
  if v_type = 'fixed' then v_fee := v_val;
  elsif v_type = 'percent' then v_fee := r.total_amount * v_val / 100;
  elsif v_type = 'nights' then
    select coalesce(sum(rate_amount), 0) into v_fee from (
      select rate_amount from public.reservation_nights where reservation_id = r.id order by stay_date limit v_val::int) s;
  end if;
  return app.round_money(v_fee, r.currency);
end $$;

create or replace function app.post_fee(r public.reservations, p_code text, p_amount numeric, p_desc text, p_source text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cc uuid; v_folio uuid;
begin
  if p_amount <= 0 then return; end if;
  select id into v_cc from public.charge_codes where property_id = r.property_id and code = p_code;
  if v_cc is null then perform app.fail('E_CHARGE_CODE', format('Charge code %s is missing for this property.', p_code)); end if;
  v_folio := app.main_folio(r.id);
  perform app.insert_with_tax(v_folio, 'charge', 1::smallint, v_cc, p_amount, r.currency, p_desc, false, 'posted', null, null,
                              null, p_source, p_source || ':' || r.id);
end $$;

create or replace function app.end_assignment(p_res uuid, p_date date, p_status text default 'ended') returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.room_assignments;
begin
  for a in select * from public.room_assignments where reservation_id = p_res and status in ('held','active') loop
    if a.status = 'active' and lower(a.stay_range) < p_date then
      update public.room_assignments set status = p_status, stay_range = daterange(lower(a.stay_range), p_date) where id = a.id;
    else
      update public.room_assignments set status = p_status where id = a.id;
    end if;
  end loop;
end $$;

create or replace function app.create_turnover_task(p_room uuid, p_stay uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare rm public.rooms; v_bdate date;
begin
  select * into rm from public.rooms where id = p_room;
  select business_date into v_bdate from public.properties where id = rm.property_id;
  -- an older turnover that was never finished is superseded by this one
  update public.hk_tasks set status = 'cancelled', cancelled_reason = 'Superseded by a new departure'
   where room_id = rm.id and task_type = 'turnover' and status not in ('inspected','cancelled');
  insert into public.hk_tasks (tenant_id, property_id, room_id, task_type, status, stay_id, business_date, created_by)
  values (rm.tenant_id, rm.property_id, rm.id, 'turnover', 'pending', p_stay, v_bdate, auth.uid());
  perform app.notify_permission(rm.property_id, 'hk.task.assign', 'room_dirty', 'Room ' || rm.room_number || ' needs cleaning',
                                null, 'rooms', rm.id);
end $$;

create or replace function app.assign_room_internal(r public.reservations, p_room uuid, p_status text, p_stay uuid, p_from date)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare rm public.rooms; v_id uuid; v_range daterange;
begin
  select * into rm from public.rooms where id = p_room and property_id = r.property_id;
  if not found or rm.status <> 'active' then perform app.fail('E_ROOM', 'Room not found or retired.'); end if;
  if exists (select 1 from public.room_blocks b where b.room_id = rm.id and b.status in ('approved','active')
             and b.block_range && daterange(p_from, r.departure_date)) then
    perform app.fail('E_ROOM_BLOCKED', format('Room %s is out of order or out of service for these dates.', rm.room_number));
  end if;
  v_range := daterange(p_from, r.departure_date);
  update public.room_assignments set status = 'released' where reservation_id = r.id and status = 'held';
  begin
    insert into public.room_assignments (tenant_id, property_id, reservation_id, stay_id, room_id, status, stay_range, created_by)
    values (r.tenant_id, r.property_id, r.id, p_stay, rm.id, p_status, v_range, auth.uid()) returning id into v_id;
  exception when exclusion_violation then
    perform app.fail('E_ROOM_TAKEN', format('Room %s is already allocated for part of these dates.', rm.room_number));
  end;
  return v_id;
end $$;

-- ---------------------------------------------------------------- create and modify
create or replace function app.create_reservation(
  p_property uuid, p_guest uuid, p_arrival date, p_departure date, p_room_type uuid, p_rate_plan uuid,
  p_adults int, p_children int, p_source text, p_status text, p_company text, p_special text, p_notes text,
  p_guarantee text, p_hold_hours int, p_rate_override numeric, p_group uuid, p_key text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p public.properties; rt public.room_types; rp public.rate_plans; v_id uuid; v_cur text; v_amt numeric; v_dep numeric;
  v_tenant uuid; r public.reservations; v_folio_no text;
begin
  select * into p from public.properties where id = p_property;
  v_tenant := p.tenant_id;
  if p_key is not null then
    select id into v_id from public.reservations where tenant_id = v_tenant and idempotency_key = p_key;
    if found then return v_id; end if;
  end if;
  if p_departure <= p_arrival then perform app.fail('E_DATES', 'Departure must be after arrival.'); end if;
  if p_arrival < p.business_date then perform app.fail('E_DATES', format('Arrival cannot be before the business date (%s).', p.business_date)); end if;
  if p_status not in ('inquiry','tentative','confirmed') then perform app.fail('E_STATE', 'A new reservation starts as inquiry, tentative or confirmed.'); end if;
  select * into rt from public.room_types where id = p_room_type and property_id = p_property;
  if not found then perform app.fail('E_ROOM_TYPE', 'Room type not found.'); end if;
  if p_adults > rt.max_adults or p_children > rt.max_children then
    perform app.fail('E_OCCUPANCY', format('%s sleeps up to %s adults and %s children.', rt.name, rt.max_adults, rt.max_children));
  end if;
  select * into rp from public.rate_plans where id = p_rate_plan and property_id = p_property;
  if not found or not rp.active then perform app.fail('E_RATE_PLAN', 'Rate plan not found or inactive.'); end if;
  if (p_departure - p_arrival) < rp.min_stay or (rp.max_stay is not null and (p_departure - p_arrival) > rp.max_stay) then
    perform app.fail('E_STAY_LENGTH', 'The stay length is outside this rate plan''s limits.');
  end if;
  if (rp.valid_from is not null and p_arrival < rp.valid_from) or (rp.valid_to is not null and p_departure - 1 > rp.valid_to) then
    perform app.fail('E_RATE_PLAN', 'This rate plan is not valid for these dates.');
  end if;
  if p_rate_override is null then
    select n.currency into v_cur from app.night_price(p_property, p_rate_plan, p_room_type, p_arrival) n;
    if v_cur is null then perform app.fail('E_NO_RATE', format('No rate is set for this room type and rate plan on %s.', p_arrival)); end if;
  else
    v_cur := p.base_currency;
  end if;
  if p_status in ('tentative','confirmed') then
    perform app.lock_inventory(p_property, p_room_type);
    perform app.assert_available(p_property, p_room_type, p_arrival, p_departure, null);
  end if;
  insert into public.reservations (tenant_id, property_id, reservation_no, status, booking_source, company_name, group_id,
      primary_guest_id, arrival_date, departure_date, adults, children, room_type_id, rate_plan_id, currency,
      guarantee_type, hold_expires_at, special_requests, notes, created_by, idempotency_key)
  values (v_tenant, p_property, app.next_doc_no(p_property, 'reservation', 'R'), p_status, p_source, p_company, p_group,
      p_guest, p_arrival, p_departure, p_adults, p_children, p_room_type, p_rate_plan, v_cur,
      coalesce(p_guarantee, 'none'),
      case when p_status = 'tentative' then now() + make_interval(hours => coalesce(p_hold_hours, 24)) end,
      p_special, p_notes, auth.uid(), p_key)
  returning id into v_id;
  insert into public.reservation_guests (reservation_id, tenant_id, guest_id, is_primary) values (v_id, v_tenant, p_guest, true);
  perform app.write_nights(v_id, p_arrival, p_rate_override);
  select * into r from public.reservations where id = v_id;
  -- deposit policy from the rate plan
  v_dep := case coalesce(rp.deposit ->> 'type', 'none')
    when 'fixed' then (rp.deposit ->> 'value')::numeric
    when 'percent' then r.total_amount * (rp.deposit ->> 'value')::numeric / 100
    when 'nights' then (select coalesce(sum(rate_amount), 0) from (select rate_amount from public.reservation_nights
                         where reservation_id = v_id order by stay_date limit (rp.deposit ->> 'value')::int) s)
    else 0 end;
  update public.reservations set deposit_required = app.round_money(v_dep, v_cur),
         guarantee_type = case when v_dep > 0 and coalesce(p_guarantee, 'none') = 'none' then 'deposit' else guarantee_type end
   where id = v_id;
  insert into public.folios (tenant_id, property_id, folio_no, label, reservation_id, guest_id, opened_business_date, created_by)
  values (v_tenant, p_property, app.next_doc_no(p_property, 'folio', 'F'), 'Guest', v_id, p_guest, p.business_date, auth.uid());
  perform app.audit(v_tenant, p_property, 'res.create', 'reservations', v_id, null,
                    jsonb_build_object('status', p_status, 'arrival', p_arrival, 'departure', p_departure), null, null);
  return v_id;
end $$;

create or replace function public.create_reservation(
  p_property uuid, p_guest uuid, p_arrival date, p_departure date, p_room_type uuid, p_rate_plan uuid,
  p_adults int default 1, p_children int default 0, p_source text default 'direct', p_status text default 'confirmed',
  p_company text default null, p_special text default null, p_notes text default null, p_guarantee text default 'none',
  p_hold_hours int default 24, p_rate_override numeric default null, p_rate_override_reason text default null,
  p_group uuid default null, p_idempotency_key text default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_tenant uuid := app.property_tenant(p_property);
begin
  perform app.require(p_property, 'res.create');
  perform app.assert_writable(v_tenant);
  if p_source = 'walk_in' then perform app.fail('E_ARG', 'Use walk_in_check_in for walk-in guests.'); end if;
  if p_rate_override is not null then
    perform app.require(p_property, 'res.rate.override');
    if coalesce(btrim(p_rate_override_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required to override the rate.'); end if;
  end if;
  if not exists (select 1 from public.guests where id = p_guest and tenant_id = v_tenant and anonymised_at is null) then
    perform app.fail('E_NOT_FOUND', 'Guest not found.');
  end if;
  v_id := app.create_reservation(p_property, p_guest, p_arrival, p_departure, p_room_type, p_rate_plan, p_adults, p_children,
            p_source, p_status, p_company, p_special, p_notes, p_guarantee, p_hold_hours, p_rate_override, p_group, p_idempotency_key);
  if p_rate_override is not null then
    perform app.audit(v_tenant, p_property, 'res.rate.override', 'reservations', v_id, null,
                      jsonb_build_object('rate', p_rate_override), p_rate_override_reason, null);
  end if;
  return v_id;
end $$;

create or replace function public.modify_reservation(
  p_id uuid, p_arrival date default null, p_departure date default null, p_room_type uuid default null,
  p_rate_plan uuid default null, p_adults int default null, p_children int default null,
  p_special text default null, p_notes text default null, p_company text default null, p_guarantee text default null,
  p_rate_override numeric default null, p_rate_override_reason text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations; n public.reservations; p public.properties; rt public.room_types; v_reprice boolean; v_cur text;
begin
  r := app.load_res(p_id);
  perform app.require(r.property_id, 'res.edit');
  perform app.assert_writable(r.tenant_id);
  if r.status not in ('inquiry','tentative','confirmed') then
    perform app.fail('E_STATE', 'Only reservations that have not checked in can be edited. Use extend stay or move room for guests in house.');
  end if;
  select * into p from public.properties where id = r.property_id;
  n := r;
  n.arrival_date := coalesce(p_arrival, r.arrival_date);
  n.departure_date := coalesce(p_departure, r.departure_date);
  n.room_type_id := coalesce(p_room_type, r.room_type_id);
  n.rate_plan_id := coalesce(p_rate_plan, r.rate_plan_id);
  n.adults := coalesce(p_adults, r.adults);
  n.children := coalesce(p_children, r.children);
  if n.departure_date <= n.arrival_date then perform app.fail('E_DATES', 'Departure must be after arrival.'); end if;
  if n.arrival_date < p.business_date then perform app.fail('E_DATES', format('Arrival cannot be before the business date (%s).', p.business_date)); end if;
  select * into rt from public.room_types where id = n.room_type_id and property_id = r.property_id;
  if not found then perform app.fail('E_ROOM_TYPE', 'Room type not found.'); end if;
  if n.adults > rt.max_adults or n.children > rt.max_children then
    perform app.fail('E_OCCUPANCY', format('%s sleeps up to %s adults and %s children.', rt.name, rt.max_adults, rt.max_children));
  end if;
  v_reprice := (n.arrival_date, n.departure_date, n.room_type_id, n.rate_plan_id) is distinct from
               (r.arrival_date, r.departure_date, r.room_type_id, r.rate_plan_id) or p_rate_override is not null;
  if p_rate_override is not null then
    perform app.require(r.property_id, 'res.rate.override');
    if coalesce(btrim(p_rate_override_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required to override the rate.'); end if;
  end if;
  if v_reprice then
    if r.status in ('tentative','confirmed') then
      perform app.lock_inventory(r.property_id, n.room_type_id);
      perform app.assert_available(r.property_id, n.room_type_id, n.arrival_date, n.departure_date, r.id);
    end if;
    -- a held room no longer fits changed dates or room type
    update public.room_assignments set status = 'released' where reservation_id = r.id and status = 'held';
    if p_rate_override is null then
      select x.currency into v_cur from app.night_price(r.property_id, n.rate_plan_id, n.room_type_id, n.arrival_date) x;
      if v_cur is null then perform app.fail('E_NO_RATE', format('No rate is set for this room type and rate plan on %s.', n.arrival_date)); end if;
      n.currency := v_cur;
    end if;
  end if;
  update public.reservations set arrival_date = n.arrival_date, departure_date = n.departure_date, room_type_id = n.room_type_id,
         rate_plan_id = n.rate_plan_id, adults = n.adults, children = n.children, currency = n.currency,
         special_requests = coalesce(p_special, special_requests), notes = coalesce(p_notes, notes),
         company_name = coalesce(p_company, company_name), guarantee_type = coalesce(p_guarantee, guarantee_type),
         updated_at = now() where id = r.id;
  if v_reprice then perform app.write_nights(r.id, n.arrival_date, p_rate_override); end if;
  perform app.audit(r.tenant_id, r.property_id, 'res.edit', 'reservations', r.id,
     jsonb_build_object('arrival', r.arrival_date, 'departure', r.departure_date, 'room_type', r.room_type_id, 'rate_plan', r.rate_plan_id),
     jsonb_build_object('arrival', n.arrival_date, 'departure', n.departure_date, 'room_type', n.room_type_id, 'rate_plan', n.rate_plan_id),
     p_rate_override_reason, null);
end $$;

create or replace function public.confirm_reservation(p_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations;
begin
  r := app.load_res(p_id);
  perform app.require(r.property_id, 'res.edit');
  perform app.assert_writable(r.tenant_id);
  if r.status not in ('inquiry','tentative') then perform app.fail('E_STATE', 'Only an inquiry or tentative booking can be confirmed.'); end if;
  perform app.lock_inventory(r.property_id, r.room_type_id);
  perform app.assert_available(r.property_id, r.room_type_id, r.arrival_date, r.departure_date, r.id);
  update public.reservations set status = 'confirmed', hold_expires_at = null, updated_at = now() where id = r.id;
end $$;

create or replace function public.set_reservation_guests(p_id uuid, p_guests uuid[])
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations; g uuid;
begin
  r := app.load_res(p_id);
  perform app.require(r.property_id, 'res.edit');
  perform app.assert_writable(r.tenant_id);
  if r.status in ('checked_out','cancelled','no_show') then perform app.fail('E_STATE', 'This reservation is closed.'); end if;
  delete from public.reservation_guests where reservation_id = r.id and not is_primary;
  foreach g in array coalesce(p_guests, '{}') loop
    if g <> r.primary_guest_id then
      insert into public.reservation_guests (reservation_id, tenant_id, guest_id) values (r.id, r.tenant_id, g) on conflict do nothing;
    end if;
  end loop;
end $$;

create or replace function public.set_arrival_ready(p_id uuid, p_ready boolean)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations;
begin
  r := app.load_res(p_id);
  perform app.require(r.property_id, 'res.edit');
  perform app.assert_writable(r.tenant_id);
  update public.reservations set arrival_ready = p_ready, updated_at = now() where id = r.id;
end $$;

-- ---------------------------------------------------------------- cancel, no-show, reinstate
create or replace function app.cancel_internal(r public.reservations, p_reason text, p_waive boolean, p_source text) returns numeric
language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.properties; rp public.rate_plans; v_fee numeric := 0; v_folio uuid; v_bal numeric; v_pending int;
begin
  select * into p from public.properties where id = r.property_id;
  select * into rp from public.rate_plans where id = r.rate_plan_id;
  if not p_waive then
    v_fee := app.policy_fee(rp.cancellation, r, r.arrival_date - p.business_date);
    perform app.post_fee(r, 'FEE_CXL', v_fee, 'Cancellation fee', 'cancellation_fee');
  end if;
  update public.reservations set status = 'cancelled', cancelled_at = now(), cancellation_reason = p_reason,
         hold_expires_at = null, updated_at = now() where id = r.id;
  update public.room_assignments set status = 'released' where reservation_id = r.id and status = 'held';
  v_folio := app.main_folio(r.id);
  select balance, pending_count into v_bal, v_pending from public.v_folio_balances where folio_id = v_folio;
  if v_bal = 0 and v_pending = 0 then
    update public.folios set status = 'closed', closed_at = now(), closed_by = auth.uid(), closed_business_date = p.business_date
     where reservation_id = r.id and status = 'open';
  end if;
  return v_fee;
end $$;

create or replace function public.cancel_reservation(p_id uuid, p_reason text, p_waive_fee boolean default false)
returns numeric
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations; v_fee numeric;
begin
  r := app.load_res(p_id);
  perform app.require(r.property_id, 'res.cancel');
  perform app.assert_writable(r.tenant_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required to cancel.'); end if;
  if r.status not in ('inquiry','tentative','confirmed') then
    perform app.fail('E_STATE', 'Only a reservation that has not checked in can be cancelled.');
  end if;
  if p_waive_fee then perform app.require(r.property_id, 'res.rate.override'); end if;
  v_fee := app.cancel_internal(r, p_reason, p_waive_fee, 'cancellation_fee');
  perform app.audit(r.tenant_id, r.property_id, 'res.cancel', 'reservations', r.id, null,
                    jsonb_build_object('fee', v_fee, 'waived', p_waive_fee), p_reason, null);
  return v_fee;
end $$;

create or replace function app.no_show_internal(r public.reservations, p_reason text, p_waive boolean) returns numeric
language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.properties; rp public.rate_plans; v_fee numeric := 0; v_folio uuid; v_bal numeric; v_pending int;
begin
  select * into p from public.properties where id = r.property_id;
  select * into rp from public.rate_plans where id = r.rate_plan_id;
  if not p_waive then
    v_fee := app.policy_fee(rp.no_show, r, null);
    perform app.post_fee(r, 'FEE_NOSHOW', v_fee, 'No-show fee', 'no_show_fee');
  end if;
  update public.reservations set status = 'no_show', no_show_at = now(), cancellation_reason = p_reason, updated_at = now() where id = r.id;
  update public.room_assignments set status = 'released' where reservation_id = r.id and status = 'held';
  v_folio := app.main_folio(r.id);
  select balance, pending_count into v_bal, v_pending from public.v_folio_balances where folio_id = v_folio;
  if v_bal = 0 and v_pending = 0 then
    update public.folios set status = 'closed', closed_at = now(), closed_by = auth.uid(), closed_business_date = p.business_date
     where reservation_id = r.id and status = 'open';
  end if;
  return v_fee;
end $$;

create or replace function public.mark_no_show(p_id uuid, p_reason text default 'Guest did not arrive', p_waive_fee boolean default false)
returns numeric
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations; v_bdate date; v_fee numeric;
begin
  r := app.load_res(p_id);
  perform app.require(r.property_id, 'res.noshow.mark');
  perform app.assert_writable(r.tenant_id);
  select business_date into v_bdate from public.properties where id = r.property_id;
  if r.status <> 'confirmed' then perform app.fail('E_STATE', 'Only a confirmed reservation can be marked no-show.'); end if;
  if r.arrival_date > v_bdate then perform app.fail('E_DATES', 'The guest is not due yet.'); end if;
  if p_waive_fee then perform app.require(r.property_id, 'res.rate.override'); end if;
  v_fee := app.no_show_internal(r, p_reason, p_waive_fee);
  perform app.audit(r.tenant_id, r.property_id, 'res.noshow', 'reservations', r.id, null,
                    jsonb_build_object('fee', v_fee, 'waived', p_waive_fee), p_reason, null);
  return v_fee;
end $$;

create or replace function public.reinstate_reservation(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations; v_bdate date;
begin
  r := app.load_res(p_id);
  perform app.require(r.property_id, 'res.reinstate');
  perform app.assert_writable(r.tenant_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  if r.status not in ('cancelled','no_show') then perform app.fail('E_STATE', 'Only a cancelled or no-show reservation can be reinstated.'); end if;
  select business_date into v_bdate from public.properties where id = r.property_id;
  if r.arrival_date < v_bdate then
    perform app.fail('E_DATES', 'The arrival date has passed. Create a new reservation or change the dates first.');
  end if;
  perform app.lock_inventory(r.property_id, r.room_type_id);
  perform app.assert_available(r.property_id, r.room_type_id, r.arrival_date, r.departure_date, r.id);
  update public.reservations set status = 'confirmed', cancelled_at = null, no_show_at = null, cancellation_reason = null, updated_at = now() where id = r.id;
  update public.folios set status = 'open', closed_at = null, closed_by = null, closed_business_date = null
   where reservation_id = r.id and status = 'closed';
  perform app.audit(r.tenant_id, r.property_id, 'res.reinstate', 'reservations', r.id, null, null, p_reason, null);
end $$;

-- ---------------------------------------------------------------- room assignment
create or replace function public.assign_room(p_id uuid, p_room uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations; rm public.rooms;
begin
  r := app.load_res(p_id);
  perform app.require(r.property_id, 'fo.room.assign');
  perform app.assert_writable(r.tenant_id);
  if r.status not in ('tentative','confirmed') then
    perform app.fail('E_STATE', 'Rooms are assigned to bookings before check-in. Use move room for guests in house.');
  end if;
  select * into rm from public.rooms where id = p_room and property_id = r.property_id;
  if not found then perform app.fail('E_ROOM', 'Room not found.'); end if;
  if rm.room_type_id <> r.room_type_id then
    perform app.fail('E_ROOM_TYPE', 'The room is a different type from the booking. Change the booking''s room type first.');
  end if;
  perform app.assign_room_internal(r, p_room, 'held', null, r.arrival_date);
end $$;

create or replace function public.unassign_room(p_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations;
begin
  r := app.load_res(p_id);
  perform app.require(r.property_id, 'fo.room.assign');
  perform app.assert_writable(r.tenant_id);
  update public.room_assignments set status = 'released' where reservation_id = r.id and status = 'held';
end $$;

-- ---------------------------------------------------------------- check-in
create or replace function app.check_in_internal(r public.reservations, p_room uuid, p_registration jsonb, p_walk_in boolean)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p public.properties; rm public.rooms; v_stay uuid; v_room uuid; a public.room_assignments; v_dep_base numeric; v_need numeric;
  v_has_doc boolean;
begin
  select * into p from public.properties where id = r.property_id;
  if r.status <> 'confirmed' then perform app.fail('E_STATE', 'Only a confirmed reservation can check in.'); end if;
  if r.arrival_date > p.business_date then
    perform app.fail('E_DATES', format('Arrival is %s. The business date is %s.', r.arrival_date, p.business_date));
  end if;
  if r.departure_date <= p.business_date then perform app.fail('E_DATES', 'The departure date has passed.'); end if;

  -- identity and registration
  v_has_doc := exists (select 1 from public.guest_documents where guest_id = r.primary_guest_id and tenant_id = r.tenant_id)
               or (coalesce(p_registration ->> 'id_type', '') <> '' and coalesce(p_registration ->> 'id_number', '') <> '');
  if not v_has_doc then perform app.fail('E_ID_REQUIRED', 'Record the guest''s ID before check-in.'); end if;
  if coalesce((p_registration ->> 'accepted_terms')::boolean, false) is not true then
    perform app.fail('E_REGISTRATION', 'The registration card must be accepted before check-in.');
  end if;

  -- deposit guarantee
  if r.guarantee_type = 'deposit' and r.deposit_required > 0 then
    select coalesce(sum(t.base_amount), 0) into v_dep_base from public.folio_transactions t
     where t.folio_id in (select id from public.folios where reservation_id = r.id)
       and t.kind = 'deposit' and t.status = 'posted'
       and not exists (select 1 from public.folio_transactions x where x.reverses_id = t.id and x.status <> 'rejected');
    v_need := round(r.deposit_required * app.fx_rate(r.property_id, r.currency, p.business_date), app.currency_decimals(p.base_currency));
    if v_dep_base < v_need then
      perform app.fail('E_DEPOSIT', format('A deposit of %s %s is required before check-in.', r.deposit_required, r.currency));
    end if;
  end if;

  -- room
  select room_id into v_room from public.room_assignments where reservation_id = r.id and status = 'held';
  v_room := coalesce(p_room, v_room);
  if v_room is null then perform app.fail('E_ROOM', 'Assign a room before check-in.'); end if;
  select * into rm from public.rooms where id = v_room and property_id = r.property_id for update;
  if not found or rm.status <> 'active' then perform app.fail('E_ROOM', 'Room not found or retired.'); end if;
  if rm.is_occupied then perform app.fail('E_ROOM_OCCUPIED', format('Room %s is occupied.', rm.room_number)); end if;
  if rm.condition <> 'ready' then
    perform app.fail('E_ROOM_NOT_READY', format('Room %s is %s. It must be ready before check-in.', rm.room_number, replace(rm.condition, '_', ' ')));
  end if;

  insert into public.stays (tenant_id, property_id, reservation_id, status, business_date_in, registration, created_by)
  values (r.tenant_id, r.property_id, r.id, 'in_house', p.business_date, coalesce(p_registration, '{}') - 'id_number', auth.uid())
  returning id into v_stay;

  if coalesce(p_registration ->> 'id_number', '') <> '' and not exists (
       select 1 from public.guest_documents where guest_id = r.primary_guest_id and doc_number = p_registration ->> 'id_number') then
    insert into public.guest_documents (tenant_id, guest_id, doc_type, doc_number, issuing_country, created_by)
    values (r.tenant_id, r.primary_guest_id, coalesce(p_registration ->> 'id_type', 'other'), p_registration ->> 'id_number',
            p_registration ->> 'id_country', auth.uid());
  end if;

  select * into a from public.room_assignments where reservation_id = r.id and status = 'held';
  if found and a.room_id = v_room then
    update public.room_assignments set status = 'active', stay_id = v_stay where id = a.id;
  else
    perform app.assign_room_internal(r, v_room, 'active', v_stay, least(r.arrival_date, p.business_date));
  end if;

  update public.rooms set is_occupied = true, condition_updated_at = now() where id = v_room;
  update public.reservations set status = 'checked_in', updated_at = now() where id = r.id;
  update public.folios set stay_id = v_stay where reservation_id = r.id and stay_id is null;
  perform app.audit(r.tenant_id, r.property_id, 'fo.checkin', 'stays', v_stay, null,
                    jsonb_build_object('room', v_room, 'walk_in', p_walk_in), null, null);
  return v_stay;
end $$;

create or replace function public.check_in(p_id uuid, p_room uuid default null, p_registration jsonb default '{}')
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations;
begin
  r := app.load_res(p_id);
  perform app.require(r.property_id, 'fo.checkin');
  perform app.assert_writable(r.tenant_id);
  return app.check_in_internal(r, p_room, p_registration, false);
end $$;

create or replace function public.walk_in_check_in(
  p_property uuid, p_guest uuid, p_departure date, p_room uuid, p_rate_plan uuid,
  p_adults int default 1, p_children int default 0, p_registration jsonb default '{}',
  p_rate_override numeric default null, p_rate_override_reason text default null, p_idempotency_key text default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tenant uuid := app.property_tenant(p_property); p public.properties; rm public.rooms; v_id uuid; r public.reservations;
begin
  perform app.require(p_property, 'fo.checkin.walkin');
  perform app.assert_writable(v_tenant);
  select * into p from public.properties where id = p_property;
  select * into rm from public.rooms where id = p_room and property_id = p_property;
  if not found then perform app.fail('E_ROOM', 'Room not found.'); end if;
  if p_rate_override is not null then
    perform app.require(p_property, 'res.rate.override');
    if coalesce(btrim(p_rate_override_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required to override the rate.'); end if;
  end if;
  if not exists (select 1 from public.guests where id = p_guest and tenant_id = v_tenant and anonymised_at is null) then
    perform app.fail('E_NOT_FOUND', 'Guest not found.');
  end if;
  v_id := app.create_reservation(p_property, p_guest, p.business_date, p_departure, rm.room_type_id, p_rate_plan, p_adults, p_children,
            'walk_in', 'confirmed', null, null, null, 'none', null, p_rate_override, null, p_idempotency_key);
  r := app.load_res(v_id);
  return app.check_in_internal(r, p_room, p_registration, true);
end $$;

create or replace function public.void_check_in(p_stay uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.stays; r public.reservations; v_bdate date;
begin
  select * into s from public.stays where id = p_stay for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Stay not found.'); end if;
  perform app.require(s.property_id, 'fo.checkout.reverse');
  perform app.assert_writable(s.tenant_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  r := app.load_res(s.reservation_id);
  select business_date into v_bdate from public.properties where id = s.property_id;
  if s.status <> 'in_house' then perform app.fail('E_STATE', 'The guest is not in house.'); end if;
  if s.business_date_in <> v_bdate then perform app.fail('E_DATES', 'A check-in can only be voided on the day it happened.'); end if;
  if exists (select 1 from public.folio_transactions t join public.folios f on f.id = t.folio_id
              where f.reservation_id = r.id and t.status <> 'rejected' and t.kind not in ('deposit','payment','refund')
                and not (t.kind = 'reversal')) then
    perform app.fail('E_STATE', 'Charges are already posted. Check the guest out instead.');
  end if;
  update public.stays set status = 'voided' where id = s.id;
  update public.reservations set status = 'confirmed', updated_at = now() where id = r.id;
  update public.room_assignments set status = 'held', stay_id = null where reservation_id = r.id and status = 'active';
  update public.rooms set is_occupied = false, condition_updated_at = now()
   where id = (select room_id from public.room_assignments where reservation_id = r.id and status = 'held');
  update public.folios set stay_id = null where reservation_id = r.id;
  perform app.audit(s.tenant_id, s.property_id, 'fo.checkin.void', 'stays', s.id, null, null, p_reason, null);
end $$;

-- ---------------------------------------------------------------- room move
create or replace function public.move_room(p_reservation uuid, p_new_room uuid, p_reason text, p_complimentary boolean default false)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r public.reservations; p public.properties; old_a public.room_assignments; old_rm public.rooms; new_rm public.rooms; v_stay uuid;
begin
  r := app.load_res(p_reservation);
  perform app.require(r.property_id, 'fo.roommove');
  perform app.assert_writable(r.tenant_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  if r.status <> 'checked_in' then perform app.fail('E_STATE', 'Only guests in house can move rooms.'); end if;
  select * into p from public.properties where id = r.property_id;
  select * into old_a from public.room_assignments where reservation_id = r.id and status = 'active';
  select * into new_rm from public.rooms where id = p_new_room and property_id = r.property_id for update;
  select * into old_rm from public.rooms where id = old_a.room_id for update;
  if new_rm.id is null or new_rm.status <> 'active' then perform app.fail('E_ROOM', 'Room not found or retired.'); end if;
  if new_rm.id = old_rm.id then perform app.fail('E_ARG', 'Choose a different room.'); end if;
  if new_rm.is_occupied or new_rm.condition <> 'ready' then
    perform app.fail('E_ROOM_NOT_READY', format('Room %s is not ready.', new_rm.room_number));
  end if;
  if new_rm.room_type_id <> old_rm.room_type_id then
    if p_complimentary then perform app.require(r.property_id, 'fo.roommove.complimentary'); end if;
    perform app.lock_inventory(r.property_id, new_rm.room_type_id);
    perform app.assert_available(r.property_id, new_rm.room_type_id, p.business_date, r.departure_date, r.id);
  end if;
  v_stay := old_a.stay_id;
  perform app.end_assignment(r.id, p.business_date);
  perform app.assign_room_internal(r, new_rm.id, 'active', v_stay, p.business_date);
  -- reprice from tonight unless complimentary
  if new_rm.room_type_id <> old_rm.room_type_id then
    if p_complimentary then
      update public.reservation_nights set room_type_id = new_rm.room_type_id where reservation_id = r.id and stay_date >= p.business_date;
    else
      perform app.write_nights(r.id, p.business_date, null, new_rm.room_type_id);
    end if;
  end if;
  update public.rooms set is_occupied = false, condition = 'dirty', condition_updated_at = now() where id = old_rm.id;
  update public.rooms set is_occupied = true, condition_updated_at = now() where id = new_rm.id;
  perform app.create_turnover_task(old_rm.id, v_stay);
  perform app.audit(r.tenant_id, r.property_id, 'fo.roommove', 'reservations', r.id,
                    jsonb_build_object('room', old_rm.id), jsonb_build_object('room', new_rm.id, 'complimentary', p_complimentary), p_reason, null);
end $$;

-- ---------------------------------------------------------------- extend or shorten
create or replace function public.extend_stay(p_reservation uuid, p_new_departure date, p_reason text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations; p public.properties; a public.room_assignments; v_old date;
begin
  r := app.load_res(p_reservation);
  perform app.require(r.property_id, 'fo.stay.extend');
  perform app.assert_writable(r.tenant_id);
  if r.status <> 'checked_in' then perform app.fail('E_STATE', 'Only guests in house can change their departure.'); end if;
  select * into p from public.properties where id = r.property_id;
  select * into a from public.room_assignments where reservation_id = r.id and status = 'active';
  v_old := r.departure_date;
  if p_new_departure = v_old then return; end if;
  if p_new_departure <= p.business_date then perform app.fail('E_DATES', 'The new departure must be after the business date. Use check-out to leave today.'); end if;
  if p_new_departure > v_old then
    perform app.lock_inventory(r.property_id, (select room_type_id from public.rooms where id = a.room_id));
    perform app.assert_available(r.property_id, (select room_type_id from public.rooms where id = a.room_id), v_old, p_new_departure, null);
    if exists (select 1 from public.room_blocks b where b.room_id = a.room_id and b.status in ('approved','active')
               and b.block_range && daterange(v_old, p_new_departure)) then
      perform app.fail('E_ROOM_BLOCKED', 'The room is blocked for the extra nights. Move the guest or release the block.');
    end if;
    begin
      update public.room_assignments set stay_range = daterange(lower(a.stay_range), p_new_departure) where id = a.id;
    exception when exclusion_violation then
      perform app.fail('E_ROOM_TAKEN', 'The room is booked by another guest for the extra nights. Move the guest to extend.');
    end;
    update public.reservations set departure_date = p_new_departure, updated_at = now() where id = r.id;
    perform app.write_nights(r.id, v_old, null, (select room_type_id from public.rooms where id = a.room_id));
  else
    update public.reservations set departure_date = p_new_departure, updated_at = now() where id = r.id;
    update public.room_assignments set stay_range = daterange(lower(a.stay_range), p_new_departure) where id = a.id;
    delete from public.reservation_nights where reservation_id = r.id and stay_date >= p_new_departure;
    update public.reservations set total_amount = (select coalesce(sum(rate_amount), 0) from public.reservation_nights where reservation_id = r.id) where id = r.id;
  end if;
  perform app.audit(r.tenant_id, r.property_id, 'fo.stay.change', 'reservations', r.id,
                    jsonb_build_object('departure', v_old), jsonb_build_object('departure', p_new_departure), p_reason, null);
end $$;

-- ---------------------------------------------------------------- check-out
create or replace function public.request_unsettled_checkout(p_reservation uuid, p_reason text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations; v_bal numeric;
begin
  r := app.load_res(p_reservation, false);
  perform app.require(r.property_id, 'fo.checkout');
  perform app.assert_writable(r.tenant_id, true);
  select coalesce(sum(b.balance), 0) into v_bal from public.v_folio_balances b where b.reservation_id = r.id;
  if v_bal <= 0 then perform app.fail('E_STATE', 'The folios are settled. No approval is needed.'); end if;
  return app.new_approval(r.property_id, 'checkout_unsettled', 'reservations', r.id, v_bal, 'fo.checkout.unsettled.approve', p_reason);
end $$;

create or replace function public.check_out(p_reservation uuid, p_approval uuid default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r public.reservations; p public.properties; s public.stays; a public.room_assignments; f public.folios;
  v_unsettled numeric; v_pending int; ap public.approvals; v_bal numeric;
begin
  r := app.load_res(p_reservation);
  perform app.require(r.property_id, 'fo.checkout');
  perform app.assert_writable(r.tenant_id, true);   -- checkout of in-house guests is always allowed
  if r.status <> 'checked_in' then perform app.fail('E_STATE', 'The guest is not in house.'); end if;
  select * into p from public.properties where id = r.property_id;
  select * into s from public.stays where reservation_id = r.id and status = 'in_house' for update;
  select * into a from public.room_assignments where reservation_id = r.id and status = 'active';

  select count(*) into v_pending from public.folio_transactions t join public.folios fo on fo.id = t.folio_id
   where fo.reservation_id = r.id and t.status = 'pending_approval';
  if v_pending > 0 then perform app.fail('E_PENDING_APPROVAL', format('%s posting(s) are waiting for approval.', v_pending)); end if;

  select coalesce(sum(greatest(b.balance, 0)), 0) into v_unsettled from public.v_folio_balances b where b.reservation_id = r.id;
  if v_unsettled > 0 then
    select * into ap from public.approvals where id = p_approval;
    if p_approval is null or not found or ap.kind <> 'checkout_unsettled' or ap.subject_id <> r.id
       or ap.status <> 'approved' or coalesce((ap.meta ->> 'used')::boolean, false) then
      perform app.fail('E_UNSETTLED', format('The folio has an unpaid balance of %s. Collect payment or get approval to check out.', v_unsettled));
    end if;
    update public.approvals set meta = meta || '{"used": true}' where id = ap.id;
  end if;
  -- overpaid folios must be refunded first
  if exists (select 1 from public.v_folio_balances b where b.reservation_id = r.id and b.balance < 0) then
    perform app.fail('E_CREDIT', 'A folio has a credit balance. Refund it or transfer it before check-out.');
  end if;

  -- leaving early releases the unused nights
  if r.departure_date > p.business_date then
    -- (a same-day arrival and departure keeps its dates: a stay must span at least one night on paper)
    if p.business_date > r.arrival_date then
      update public.reservations set departure_date = p.business_date where id = r.id;
    end if;
    delete from public.reservation_nights where reservation_id = r.id and stay_date >= p.business_date;
    update public.reservations set total_amount = (select coalesce(sum(rate_amount), 0) from public.reservation_nights where reservation_id = r.id) where id = r.id;
  end if;

  for f in select * from public.folios where reservation_id = r.id and status = 'open' order by opened_at loop
    if exists (select 1 from public.folio_transactions where folio_id = f.id and status = 'posted') then
      perform app.issue_invoice(f.id, 'invoice');
    end if;
    select balance into v_bal from public.v_folio_balances where folio_id = f.id;
    if v_bal = 0 then perform app.close_folio(f.id); end if;
  end loop;

  update public.stays set status = 'checked_out', checked_out_at = now(), business_date_out = p.business_date where id = s.id;
  update public.reservations set status = 'checked_out', updated_at = now() where id = r.id;
  perform app.end_assignment(r.id, p.business_date);
  update public.rooms set is_occupied = false, condition = 'dirty', condition_updated_at = now() where id = a.room_id;
  perform app.create_turnover_task(a.room_id, s.id);
  perform app.audit(r.tenant_id, r.property_id, 'fo.checkout', 'stays', s.id, null,
                    jsonb_build_object('unsettled', v_unsettled, 'approval', p_approval), null, null);
end $$;

create or replace function public.undo_checkout(p_stay uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.stays; r public.reservations; a public.room_assignments; v_bdate date; t public.hk_tasks;
begin
  select * into s from public.stays where id = p_stay for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Stay not found.'); end if;
  perform app.require(s.property_id, 'fo.checkout.reverse');
  perform app.assert_writable(s.tenant_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  r := app.load_res(s.reservation_id);
  select business_date into v_bdate from public.properties where id = s.property_id;
  if s.status <> 'checked_out' or s.business_date_out <> v_bdate then
    perform app.fail('E_STATE', 'A check-out can only be undone on the day it happened.');
  end if;
  select * into a from public.room_assignments where reservation_id = r.id and status = 'ended' order by created_at desc limit 1;
  select * into t from public.hk_tasks where room_id = a.room_id and task_type = 'turnover' and stay_id = s.id
    and status not in ('cancelled','inspected') order by created_at desc limit 1;
  if found and t.status <> 'pending' and t.status <> 'assigned' then
    perform app.fail('E_STATE', 'Housekeeping has already started on the room.');
  end if;
  if found then update public.hk_tasks set status = 'cancelled', cancelled_reason = 'Check-out undone' where id = t.id; end if;
  begin
    update public.room_assignments set status = 'active' where id = a.id;
  exception when exclusion_violation then
    perform app.fail('E_ROOM_TAKEN', 'The room has been given to another guest.');
  end;
  update public.rooms set is_occupied = true, condition = 'ready', condition_updated_at = now() where id = a.room_id;
  update public.stays set status = 'in_house', checked_out_at = null, business_date_out = null where id = s.id;
  update public.reservations set status = 'checked_in', updated_at = now() where id = r.id;
  update public.folios set status = 'open', closed_at = null, closed_by = null, closed_business_date = null
   where reservation_id = r.id and closed_business_date = v_bdate;
  perform app.audit(s.tenant_id, s.property_id, 'fo.checkout.undo', 'stays', s.id, null, null, p_reason, null);
end $$;

-- ---------------------------------------------------------------- guest data governance
-- Erasure request (NDPR): personal fields are removed, ledger and stay history stay, linked to a blank profile.
create or replace function public.anonymise_guest(p_guest uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g public.guests;
begin
  select * into g from public.guests where id = p_guest for update;
  if not found or g.tenant_id is distinct from app.my_tenant() then perform app.fail('E_NOT_FOUND', 'Guest not found.'); end if;
  if not app.can_any('guest.merge') then perform app.fail('E_PERM', 'You do not have permission: guest.merge'); end if;
  perform app.assert_writable(g.tenant_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  if g.anonymised_at is not null then perform app.fail('E_STATE', 'This guest is already anonymised.'); end if;
  if exists (select 1 from public.reservations where primary_guest_id = g.id and status in ('checked_in','confirmed','tentative'))
     or exists (select 1 from public.reservation_guests rg join public.reservations r on r.id = rg.reservation_id
                 where rg.guest_id = g.id and r.status in ('checked_in','confirmed','tentative')) then
    perform app.fail('E_STATE', 'This guest has a current or upcoming reservation.');
  end if;
  delete from public.guest_documents where guest_id = g.id;
  update public.guests set first_name = 'Anonymised', last_name = 'Guest', phone = null, email = null, nationality = null,
         date_of_birth = null, preferences = '{}', notes = null, marketing_consent = false, anonymised_at = now(), updated_at = now()
   where id = g.id;
  perform app.audit(g.tenant_id, null, 'guest.anonymise', 'guests', g.id, null, null, p_reason, null);
end $$;

-- Duplicate guests: everything moves to the guest that is kept, the other becomes an empty anonymised record.
create or replace function public.merge_guests(p_keep uuid, p_remove uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare k public.guests; x public.guests;
begin
  select * into k from public.guests where id = p_keep for update;
  select * into x from public.guests where id = p_remove for update;
  if k.id is null or x.id is null or k.tenant_id is distinct from app.my_tenant() or x.tenant_id <> k.tenant_id then
    perform app.fail('E_NOT_FOUND', 'Guest not found.');
  end if;
  if not app.can_any('guest.merge') then perform app.fail('E_PERM', 'You do not have permission: guest.merge'); end if;
  perform app.assert_writable(k.tenant_id);
  if p_keep = p_remove then perform app.fail('E_ARG', 'Choose two different guests.'); end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  if k.anonymised_at is not null or x.anonymised_at is not null then perform app.fail('E_STATE', 'An anonymised guest cannot be merged.'); end if;
  update public.reservations set primary_guest_id = k.id where primary_guest_id = x.id;
  delete from public.reservation_guests rg where rg.guest_id = x.id
     and exists (select 1 from public.reservation_guests o where o.reservation_id = rg.reservation_id and o.guest_id = k.id);
  update public.reservation_guests set guest_id = k.id where guest_id = x.id;
  update public.folios set guest_id = k.id where guest_id = x.id;
  update public.guest_documents set guest_id = k.id where guest_id = x.id;
  update public.guest_feedback set guest_id = k.id where guest_id = x.id;
  update public.guests set phone = coalesce(phone, x.phone), email = coalesce(email, x.email),
         nationality = coalesce(nationality, x.nationality), date_of_birth = coalesce(date_of_birth, x.date_of_birth),
         updated_at = now() where id = k.id;
  update public.guests set first_name = 'Merged', last_name = 'Duplicate', phone = null, email = null, nationality = null,
         date_of_birth = null, notes = null, preferences = '{}', anonymised_at = now() where id = x.id;
  perform app.audit(k.tenant_id, null, 'guest.merge', 'guests', k.id, null, jsonb_build_object('merged', x.id), p_reason, null);
end $$;
