-- HMS 0008: housekeeping, maintenance, room blocks, service requests, business date roll, KPIs, boards.

-- ---------------------------------------------------------------- shared helpers
create or replace function app.user_in_property(p_user uuid, p_property uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.user_property_roles upr
                 where upr.user_id = p_user and upr.tenant_id = app.property_tenant(p_property)
                   and (upr.property_id is null or upr.property_id = p_property))
$$;

create or replace function app.assert_not_oversold(p_property uuid, p_type uuid, p_from date, p_to date) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_night date;
begin
  select g.d::date into v_night
  from generate_series(p_from, p_to - 1, interval '1 day') g(d)
  where (select count(*) from public.rooms r
          where r.property_id = p_property and r.room_type_id = p_type and r.status = 'active'
            and not exists (select 1 from public.room_blocks b
                            where b.room_id = r.id and b.status in ('approved','active') and b.block_range @> g.d::date))
      + (select overbooking_limit from public.room_types where id = p_type)
      < (select count(*) from public.reservation_nights rn join public.reservations res on res.id = rn.reservation_id
          where rn.property_id = p_property and rn.room_type_id = p_type and rn.stay_date = g.d::date
            and app.holds_inventory(res.status, res.hold_expires_at))
  order by 1 limit 1;
  if v_night is not null then
    perform app.fail('E_OVERSOLD', format('Blocking this room would leave more bookings than rooms on %s. Move or cancel a booking first.', v_night));
  end if;
end $$;

-- ---------------------------------------------------------------- housekeeping
create or replace function app.load_task(p_id uuid) returns public.hk_tasks
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.hk_tasks;
begin
  select * into t from public.hk_tasks where id = p_id for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Task not found.'); end if;
  return t;
end $$;

create or replace function public.create_hk_task(p_room uuid, p_type text, p_notes text default null, p_priority int default 0)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare rm public.rooms; v_id uuid; v_bdate date;
begin
  select * into rm from public.rooms where id = p_room;
  if not found then perform app.fail('E_NOT_FOUND', 'Room not found.'); end if;
  perform app.require(rm.property_id, 'hk.task.assign');
  perform app.assert_writable(rm.tenant_id);
  select business_date into v_bdate from public.properties where id = rm.property_id;
  if p_type = 'turnover' and rm.condition <> 'dirty' then
    perform app.fail('E_STATE', 'A turnover task is for a dirty room.');
  end if;
  insert into public.hk_tasks (tenant_id, property_id, room_id, task_type, status, priority, notes, business_date, created_by)
  values (rm.tenant_id, rm.property_id, rm.id, p_type, 'pending', p_priority, p_notes, v_bdate, auth.uid())
  returning id into v_id;
  return v_id;
exception when unique_violation then
  perform app.fail('E_DUPLICATE', 'This room already has an open turnover task.');
end $$;

create or replace function public.assign_hk_task(p_task uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.hk_tasks;
begin
  t := app.load_task(p_task);
  perform app.require(t.property_id, 'hk.task.assign');
  perform app.assert_writable(t.tenant_id);
  if t.status not in ('pending','assigned','rework') then perform app.fail('E_STATE', 'This task can no longer be assigned.'); end if;
  if not app.user_in_property(p_user, t.property_id) then perform app.fail('E_ARG', 'That user does not work at this property.'); end if;
  update public.hk_tasks set status = 'assigned', assigned_to = p_user, assigned_at = now() where id = t.id;
  perform app.notify_user(p_user, t.property_id, 'task_assigned', 'New cleaning task', null, 'hk_tasks', t.id);
end $$;

create or replace function public.start_hk_task(p_task uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.hk_tasks;
begin
  t := app.load_task(p_task);
  perform app.require(t.property_id, 'hk.task.execute');
  perform app.assert_writable(t.tenant_id);
  if t.assigned_to is distinct from auth.uid() then perform app.fail('E_PERM', 'This task is assigned to someone else.'); end if;
  if t.status not in ('assigned','rework') then perform app.fail('E_STATE', 'This task cannot be started.'); end if;
  update public.hk_tasks set status = 'in_progress', started_at = now() where id = t.id;
  if t.task_type in ('turnover','deep_clean') then
    update public.rooms set condition = 'cleaning', condition_updated_at = now() where id = t.room_id;
  end if;
end $$;

create or replace function public.complete_hk_task(p_task uuid, p_checklist jsonb default '[]', p_notes text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.hk_tasks; p public.properties;
begin
  t := app.load_task(p_task);
  perform app.require(t.property_id, 'hk.task.execute');
  perform app.assert_writable(t.tenant_id);
  if t.assigned_to is distinct from auth.uid() then perform app.fail('E_PERM', 'This task is assigned to someone else.'); end if;
  if t.status <> 'in_progress' then perform app.fail('E_STATE', 'Start the task first.'); end if;
  select * into p from public.properties where id = t.property_id;
  if t.task_type in ('turnover','deep_clean') and p.inspection_required then
    update public.hk_tasks set status = 'completed', completed_at = now(), checklist = coalesce(p_checklist, '[]'), notes = coalesce(p_notes, notes) where id = t.id;
    update public.rooms set condition = 'awaiting_inspection', condition_updated_at = now() where id = t.room_id;
    perform app.notify_permission(t.property_id, 'hk.inspect', 'inspection_due', 'Room ready for inspection', null, 'hk_tasks', t.id);
  else
    update public.hk_tasks set status = case when t.task_type in ('turnover','deep_clean') then 'inspected' else 'completed' end,
           completed_at = now(), checklist = coalesce(p_checklist, '[]'), notes = coalesce(p_notes, notes) where id = t.id;
    if t.task_type in ('turnover','deep_clean') then
      update public.rooms set condition = 'ready', condition_updated_at = now() where id = t.room_id;
    end if;
  end if;
end $$;

-- Inspection. The inspector cannot be the person who cleaned the room.
create or replace function public.inspect_hk_task(p_task uuid, p_pass boolean, p_reason text default null, p_defects jsonb default '[]')
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.hk_tasks;
begin
  t := app.load_task(p_task);
  perform app.require(t.property_id, 'hk.inspect');
  perform app.assert_writable(t.tenant_id);
  if t.status <> 'completed' then perform app.fail('E_STATE', 'Only a completed task can be inspected.'); end if;
  if t.assigned_to = auth.uid() then perform app.fail('E_SOD', 'You cannot inspect a room you cleaned.'); end if;
  if not p_pass and coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required when a room fails inspection.'); end if;
  if p_pass then
    update public.hk_tasks set status = 'inspected', inspection_result = 'pass', inspected_by = auth.uid(), inspected_at = now() where id = t.id;
    update public.rooms set condition = 'ready', condition_updated_at = now() where id = t.room_id;
  else
    update public.hk_tasks set status = 'rework', inspection_result = 'fail', inspected_by = auth.uid(), inspected_at = now(),
           fail_reason = p_reason, defects = coalesce(p_defects, '[]') where id = t.id;
    update public.rooms set condition = 'dirty', condition_updated_at = now() where id = t.room_id;
    if t.assigned_to is not null then
      perform app.notify_user(t.assigned_to, t.property_id, 'rework', 'Room needs rework', p_reason, 'hk_tasks', t.id);
    end if;
  end if;
end $$;

create or replace function public.cancel_hk_task(p_task uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.hk_tasks;
begin
  t := app.load_task(p_task);
  perform app.require(t.property_id, 'hk.task.assign');
  perform app.assert_writable(t.tenant_id);
  if t.status in ('inspected','cancelled') then perform app.fail('E_STATE', 'This task is finished.'); end if;
  update public.hk_tasks set status = 'cancelled', cancelled_reason = p_reason where id = t.id;
end $$;

-- Supervisor override of room condition. Sensitive: needs a reason and is audited.
create or replace function public.set_room_condition(p_room uuid, p_condition text, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare rm public.rooms;
begin
  select * into rm from public.rooms where id = p_room for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Room not found.'); end if;
  perform app.require(rm.property_id, 'room.status.override');
  perform app.assert_writable(rm.tenant_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  if p_condition not in ('dirty','cleaning','awaiting_inspection','ready') then perform app.fail('E_ARG', 'Unknown room condition.'); end if;
  update public.rooms set condition = p_condition, condition_updated_at = now() where id = rm.id;
  perform app.audit(rm.tenant_id, rm.property_id, 'room.status.override', 'rooms', rm.id,
                    jsonb_build_object('condition', rm.condition), jsonb_build_object('condition', p_condition), p_reason, null);
end $$;

-- ---------------------------------------------------------------- room blocks
create or replace function public.request_room_block(
  p_room uuid, p_type text, p_from date, p_to date, p_reason text, p_ticket uuid default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare rm public.rooms; p public.properties; v_id uuid; v_auto boolean; v_appr uuid;
begin
  select * into rm from public.rooms where id = p_room;
  if not found then perform app.fail('E_NOT_FOUND', 'Room not found.'); end if;
  perform app.require(rm.property_id, 'room.block.request');
  perform app.assert_writable(rm.tenant_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  if p_to <= p_from then perform app.fail('E_DATES', 'The block must end after it starts.'); end if;
  select * into p from public.properties where id = rm.property_id;
  if p_from < p.business_date then perform app.fail('E_DATES', 'A block cannot start in the past.'); end if;
  if exists (select 1 from public.room_assignments a where a.room_id = rm.id and a.status in ('held','active')
             and a.stay_range && daterange(p_from, p_to)) then
    perform app.fail('E_ROOM_TAKEN', 'A guest is allocated to this room in that period. Move the guest first.');
  end if;
  v_auto := app.grant_level(rm.property_id, 'room.block.approve') = 'Y';
  insert into public.room_blocks (tenant_id, property_id, room_id, block_type, block_range, status, reason, ticket_id, requested_by,
                                  decided_by, decided_at)
  values (rm.tenant_id, rm.property_id, rm.id, p_type, daterange(p_from, p_to),
          case when v_auto then case when p_from <= p.business_date then 'active' else 'approved' end else 'requested' end,
          p_reason, p_ticket, auth.uid(), case when v_auto then auth.uid() end, case when v_auto then now() end)
  returning id into v_id;
  if p_ticket is not null then update public.maintenance_tickets set block_id = v_id where id = p_ticket; end if;
  if v_auto then
    perform app.assert_not_oversold(rm.property_id, rm.room_type_id, p_from, p_to);
    perform app.audit(rm.tenant_id, rm.property_id, 'room.block.auto_approved', 'room_blocks', v_id, null, null, p_reason, null);
  else
    v_appr := app.new_approval(rm.property_id, 'room_block', 'room_blocks', v_id, null, 'room.block.approve', p_reason);
  end if;
  return v_id;
end $$;

-- Extends the shared approval outcome with an oversold check for blocks.
create or replace function public.release_room_block(p_block uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.room_blocks;
begin
  select * into b from public.room_blocks where id = p_block for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Block not found.'); end if;
  perform app.require(b.property_id, 'room.block.release');
  perform app.assert_writable(b.tenant_id);
  if b.status in ('requested') then
    update public.room_blocks set status = 'cancelled' where id = b.id;
    update public.approvals set status = 'withdrawn', decided_at = now() where subject_table = 'room_blocks' and subject_id = b.id and status = 'pending';
  elsif b.status in ('approved','active') then
    update public.room_blocks set status = 'released', released_by = auth.uid(), released_at = now() where id = b.id;
  else
    perform app.fail('E_STATE', 'This block is already finished.');
  end if;
  perform app.audit(b.tenant_id, b.property_id, 'room.block.release', 'room_blocks', b.id, null, null, p_reason, null);
end $$;

-- ---------------------------------------------------------------- maintenance
create or replace function app.load_ticket(p_id uuid) returns public.maintenance_tickets
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.maintenance_tickets;
begin
  select * into t from public.maintenance_tickets where id = p_id for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Ticket not found.'); end if;
  return t;
end $$;

create or replace function public.create_ticket(
  p_property uuid, p_title text, p_description text default null, p_room uuid default null,
  p_location text default null, p_priority text default 'medium')
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_tenant uuid := app.property_tenant(p_property);
begin
  perform app.require(p_property, 'mnt.ticket.create');
  perform app.assert_writable(v_tenant);
  if coalesce(btrim(p_title), '') = '' then perform app.fail('E_ARG', 'A title is required.'); end if;
  if p_room is not null and not exists (select 1 from public.rooms where id = p_room and property_id = p_property) then
    perform app.fail('E_NOT_FOUND', 'Room not found.');
  end if;
  insert into public.maintenance_tickets (tenant_id, property_id, ticket_no, room_id, location, title, description, priority, reported_by)
  values (v_tenant, p_property, app.next_doc_no(p_property, 'ticket', 'MT'), p_room, p_location, p_title, p_description, p_priority, auth.uid())
  returning id into v_id;
  perform app.notify_permission(p_property, 'mnt.ticket.manage', 'ticket_new', 'New maintenance ticket', p_title, 'maintenance_tickets', v_id);
  return v_id;
end $$;

create or replace function public.assign_ticket(p_ticket uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.maintenance_tickets;
begin
  t := app.load_ticket(p_ticket);
  perform app.require(t.property_id, 'mnt.ticket.manage');
  perform app.assert_writable(t.tenant_id);
  if t.status not in ('open','assigned','waiting') then perform app.fail('E_STATE', 'This ticket cannot be assigned now.'); end if;
  if not app.user_in_property(p_user, t.property_id) then perform app.fail('E_ARG', 'That user does not work at this property.'); end if;
  update public.maintenance_tickets set status = 'assigned', assigned_to = p_user, assigned_at = now() where id = t.id;
  perform app.notify_user(p_user, t.property_id, 'ticket_assigned', 'Ticket assigned to you', t.title, 'maintenance_tickets', t.id);
end $$;

create or replace function public.start_ticket(p_ticket uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.maintenance_tickets;
begin
  t := app.load_ticket(p_ticket);
  perform app.require(t.property_id, 'mnt.ticket.work');
  perform app.assert_writable(t.tenant_id);
  if t.assigned_to is distinct from auth.uid() then perform app.fail('E_PERM', 'This ticket is assigned to someone else.'); end if;
  if t.status not in ('assigned','waiting') then perform app.fail('E_STATE', 'This ticket cannot be started.'); end if;
  update public.maintenance_tickets set status = 'in_progress', started_at = coalesce(started_at, now()), waiting_reason = null where id = t.id;
end $$;

create or replace function public.wait_ticket(p_ticket uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.maintenance_tickets;
begin
  t := app.load_ticket(p_ticket);
  perform app.require(t.property_id, 'mnt.ticket.work');
  perform app.assert_writable(t.tenant_id);
  if t.assigned_to is distinct from auth.uid() then perform app.fail('E_PERM', 'This ticket is assigned to someone else.'); end if;
  if t.status <> 'in_progress' then perform app.fail('E_STATE', 'Only work in progress can be put on hold.'); end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'Say what you are waiting for.'); end if;
  update public.maintenance_tickets set status = 'waiting', waiting_reason = p_reason where id = t.id;
end $$;

create or replace function public.resolve_ticket(p_ticket uuid, p_note text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.maintenance_tickets;
begin
  t := app.load_ticket(p_ticket);
  perform app.require(t.property_id, 'mnt.ticket.work');
  perform app.assert_writable(t.tenant_id);
  if t.assigned_to is distinct from auth.uid() then perform app.fail('E_PERM', 'This ticket is assigned to someone else.'); end if;
  if t.status <> 'in_progress' then perform app.fail('E_STATE', 'Only work in progress can be resolved.'); end if;
  if coalesce(btrim(p_note), '') = '' then perform app.fail('E_REASON', 'Describe what was done.'); end if;
  update public.maintenance_tickets set status = 'resolved', resolution_note = p_note, resolved_by = auth.uid(), resolved_at = now() where id = t.id;
  perform app.notify_permission(t.property_id, 'mnt.ticket.close', 'ticket_resolved', 'Ticket ready to close', t.title, 'maintenance_tickets', t.id);
end $$;

-- Closing releases the linked room block. The closer cannot be the person who resolved it.
create or replace function public.close_ticket(p_ticket uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.maintenance_tickets;
begin
  t := app.load_ticket(p_ticket);
  perform app.require(t.property_id, 'mnt.ticket.close');
  perform app.assert_writable(t.tenant_id);
  if t.status <> 'resolved' then perform app.fail('E_STATE', 'Only a resolved ticket can be closed.'); end if;
  if t.resolved_by = auth.uid() then perform app.fail('E_SOD', 'You cannot close a ticket you resolved.'); end if;
  update public.maintenance_tickets set status = 'closed', closed_by = auth.uid(), closed_at = now() where id = t.id;
  if t.block_id is not null then
    update public.room_blocks set status = 'released', released_by = auth.uid(), released_at = now()
     where id = t.block_id and status in ('approved','active');
  end if;
end $$;

create or replace function public.reopen_ticket(p_ticket uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.maintenance_tickets;
begin
  t := app.load_ticket(p_ticket);
  perform app.require(t.property_id, 'mnt.ticket.manage');
  perform app.assert_writable(t.tenant_id);
  if t.status not in ('resolved','closed') then perform app.fail('E_STATE', 'Only a resolved or closed ticket can be reopened.'); end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  update public.maintenance_tickets set status = 'assigned', resolved_by = null, resolved_at = null, closed_by = null, closed_at = null where id = t.id;
  perform app.audit(t.tenant_id, t.property_id, 'mnt.ticket.reopen', 'maintenance_tickets', t.id, null, null, p_reason, null);
end $$;

create or replace function public.cancel_ticket(p_ticket uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.maintenance_tickets;
begin
  t := app.load_ticket(p_ticket);
  perform app.require(t.property_id, 'mnt.ticket.cancel');
  perform app.assert_writable(t.tenant_id);
  if t.status in ('closed','cancelled') then perform app.fail('E_STATE', 'This ticket is finished.'); end if;
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  update public.maintenance_tickets set status = 'cancelled', cancelled_reason = p_reason where id = t.id;
  if t.block_id is not null then
    update public.room_blocks set status = 'released', released_by = auth.uid(), released_at = now()
     where id = t.block_id and status in ('approved','active');
  end if;
  perform app.audit(t.tenant_id, t.property_id, 'mnt.ticket.cancel', 'maintenance_tickets', t.id, null, null, p_reason, null);
end $$;

-- ---------------------------------------------------------------- service requests
create or replace function app.load_sr(p_id uuid) returns public.service_requests
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.service_requests;
begin
  select * into s from public.service_requests where id = p_id for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Request not found.'); end if;
  return s;
end $$;

create or replace function public.create_service_request(
  p_reservation uuid, p_category text, p_description text, p_chargeable boolean default false,
  p_charge_amount numeric default null, p_currency text default null, p_charge_code uuid default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations; v_stay uuid; v_room uuid; v_id uuid;
begin
  r := app.load_res(p_reservation, false);
  perform app.require(r.property_id, 'svc.request.create');
  perform app.assert_writable(r.tenant_id);
  if r.status <> 'checked_in' then perform app.fail('E_STATE', 'Service requests are for guests in house.'); end if;
  if p_chargeable and (p_charge_amount is null or p_charge_code is null) then
    perform app.fail('E_ARG', 'A chargeable request needs an amount and a charge code.');
  end if;
  select s.id, a.room_id into v_stay, v_room from public.stays s
    join public.room_assignments a on a.stay_id = s.id and a.status = 'active' where s.reservation_id = r.id and s.status = 'in_house';
  insert into public.service_requests (tenant_id, property_id, request_no, reservation_id, stay_id, room_id, category, description,
                                       chargeable, charge_amount, currency, charge_code_id, created_by)
  values (r.tenant_id, r.property_id, app.next_doc_no(r.property_id, 'service_request', 'SR'), r.id, v_stay, v_room, p_category,
          p_description, p_chargeable, p_charge_amount, coalesce(p_currency, r.currency), p_charge_code, auth.uid())
  returning id into v_id;
  perform app.notify_permission(r.property_id, 'svc.request.manage', 'service_request', 'New guest request', p_description, 'service_requests', v_id);
  return v_id;
end $$;

create or replace function public.assign_service_request(p_id uuid, p_user uuid default null, p_department text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.service_requests;
begin
  s := app.load_sr(p_id);
  perform app.require(s.property_id, 'svc.request.manage');
  perform app.assert_writable(s.tenant_id);
  if s.status not in ('new','assigned') then perform app.fail('E_STATE', 'This request cannot be assigned now.'); end if;
  if p_user is not null and not app.user_in_property(p_user, s.property_id) then perform app.fail('E_ARG', 'That user does not work at this property.'); end if;
  update public.service_requests set status = 'assigned', assigned_to = p_user, assigned_department = p_department where id = s.id;
end $$;

create or replace function public.start_service_request(p_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.service_requests;
begin
  s := app.load_sr(p_id);
  perform app.require(s.property_id, 'svc.request.manage');
  perform app.assert_writable(s.tenant_id);
  if s.status not in ('new','assigned') then perform app.fail('E_STATE', 'This request cannot be started.'); end if;
  update public.service_requests set status = 'in_progress' where id = s.id;
end $$;

create or replace function public.complete_service_request(p_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.service_requests; v_folio uuid;
begin
  s := app.load_sr(p_id);
  perform app.require(s.property_id, 'svc.request.manage');
  perform app.assert_writable(s.tenant_id);
  if s.status not in ('new','assigned','in_progress') then perform app.fail('E_STATE', 'This request is finished.'); end if;
  if s.chargeable then
    perform app.require(s.property_id, 'fin.charge.post');
    v_folio := app.main_folio(s.reservation_id);
    perform app.insert_with_tax(v_folio, 'charge', 1::smallint, s.charge_code_id, s.charge_amount, s.currency,
              'Service: ' || s.category, false, 'posted', null, null, s.request_no, 'service_request', 'svc:' || s.id);
  end if;
  update public.service_requests set status = 'completed', completed_by = auth.uid(), completed_at = now() where id = s.id;
end $$;

create or replace function public.cancel_service_request(p_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.service_requests;
begin
  s := app.load_sr(p_id);
  perform app.require(s.property_id, 'svc.request.manage');
  perform app.assert_writable(s.tenant_id);
  if s.status in ('completed','cancelled') then perform app.fail('E_STATE', 'This request is finished.'); end if;
  update public.service_requests set status = 'cancelled', cancelled_reason = p_reason where id = s.id;
end $$;

-- ---------------------------------------------------------------- business date roll (A2)
-- Runs by itself at each property's cut-off. Posts the night, marks no-shows, plans stayover cleaning,
-- records the day's numbers and opens the next business date. Any failure rolls the whole day back.
create or replace function app.roll_business_date(p_property uuid, p_method text default 'auto_roll') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p public.properties; d date; r public.reservations; a public.room_assignments; v_cc uuid;
  v_posted int := 0; v_noshow int := 0; v_expired int := 0; v_tasks int := 0; v_overstay int := 0; v_since timestamptz;
  v_cancels int; v_stats public.daily_stats; v_summary jsonb; v_night public.reservation_nights; v_type uuid;
begin
  select * into p from public.properties where id = p_property for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Property not found.'); end if;
  d := p.business_date;
  select coalesce(max(occurred_at), p.created_at) into v_since from public.business_date_log where property_id = p.id;
  select id into v_cc from public.charge_codes where property_id = p.id and code = 'ROOM';
  if v_cc is null then perform app.fail('E_CHARGE_CODE', 'Charge code ROOM is missing for this property.'); end if;

  -- 1. guests who should have left but are still in house: charge one more night if the room allows
  for r in select * from public.reservations where property_id = p.id and status = 'checked_in' and departure_date <= d loop
    select * into a from public.room_assignments where reservation_id = r.id and status = 'active';
    select room_type_id into v_type from public.rooms where id = a.room_id;
    begin
      update public.room_assignments set stay_range = daterange(lower(a.stay_range), d + 1) where id = a.id;
      update public.reservations set departure_date = d + 1 where id = r.id;
      perform app.write_nights(r.id, d, null, v_type);
      v_overstay := v_overstay + 1;
    exception when others then
      -- keep the assignment and reservation as they were; tell the manager
      perform app.notify_permission(p.id, 'fo.board.view', 'overstay_conflict', 'Overstay could not be extended',
                                    'Reservation ' || r.reservation_no || ' is still in house past departure and could not be extended.',
                                    'reservations', r.id);
    end;
  end loop;

  -- 2. room and tax for the night
  for r in select res.* from public.reservations res
            where res.property_id = p.id and res.status = 'checked_in' loop
    select * into v_night from public.reservation_nights where reservation_id = r.id and stay_date = d;
    if found then
      perform app.insert_with_tax(app.main_folio(r.id), 'charge', 1::smallint, v_cc, v_night.rate_amount, v_night.currency,
                'Room ' || to_char(d, 'DD Mon YYYY'), v_night.price_includes_tax, 'posted', null, null, null,
                'room_charge_roll', 'room:' || r.id || ':' || d);
      v_posted := v_posted + 1;
    end if;
  end loop;

  -- 3. no-shows
  for r in select * from public.reservations where property_id = p.id and status = 'confirmed' and arrival_date <= d loop
    perform app.no_show_internal(r, 'Did not arrive by the business date roll', false);
    v_noshow := v_noshow + 1;
  end loop;

  -- 4. expired tentative holds
  update public.reservations set status = 'cancelled', cancelled_at = now(), cancellation_reason = 'Hold expired', updated_at = now()
   where property_id = p.id and status = 'tentative' and hold_expires_at is not null and hold_expires_at < now();
  get diagnostics v_expired = row_count;

  -- 5. stayover cleaning for the new day
  if p.stayover_service then
    insert into public.hk_tasks (tenant_id, property_id, room_id, task_type, status, stay_id, business_date)
    select p.tenant_id, p.id, a2.room_id, 'stayover', 'pending', a2.stay_id, d + 1
      from public.room_assignments a2 join public.reservations r2 on r2.id = a2.reservation_id
     where a2.property_id = p.id and a2.status = 'active' and r2.status = 'checked_in' and r2.departure_date > d + 1
       and not exists (select 1 from public.hk_tasks h where h.room_id = a2.room_id and h.task_type = 'stayover'
                       and h.status in ('pending','assigned','in_progress') );
    get diagnostics v_tasks = row_count;
  end if;

  -- 6. room blocks: start those due, finish those ended
  update public.room_blocks set status = 'active' where property_id = p.id and status = 'approved' and lower(block_range) <= d + 1;
  update public.room_blocks set status = 'released', released_at = now() where property_id = p.id and status = 'active' and upper(block_range) <= d + 1;

  -- 7. the day's numbers (base currency, net of tax)
  select count(*) into v_cancels from public.reservations where property_id = p.id and cancelled_at > v_since;
  insert into public.daily_stats as ds (property_id, tenant_id, business_date, rooms_total, rooms_ooo, rooms_oos, rooms_available,
      rooms_sold, room_revenue, total_revenue, tax_collected, arrivals, departures, no_shows, cancellations, walk_ins)
  select p.id, p.tenant_id, d,
    (select count(*) from public.rooms where property_id = p.id and status = 'active'),
    (select count(distinct room_id) from public.room_blocks where property_id = p.id and block_type = 'ooo' and status in ('approved','active') and block_range @> d),
    (select count(distinct room_id) from public.room_blocks where property_id = p.id and block_type = 'oos' and status in ('approved','active') and block_range @> d),
    (select count(*) from public.rooms where property_id = p.id and status = 'active')
      - (select count(distinct room_id) from public.room_blocks where property_id = p.id and block_type = 'ooo' and status in ('approved','active') and block_range @> d),
    (select count(*) from public.reservation_nights rn join public.reservations res on res.id = rn.reservation_id
       where rn.property_id = p.id and rn.stay_date = d and res.status in ('checked_in','checked_out')),
    (select coalesce(sum(sign * base_amount), 0) from public.folio_transactions
       where property_id = p.id and business_date = d and status = 'posted' and revenue_group = 'room'),
    (select coalesce(sum(sign * base_amount), 0) from public.folio_transactions
       where property_id = p.id and business_date = d and status = 'posted' and revenue_group is not null),
    (select coalesce(sum(t.sign * t.base_amount), 0) from public.folio_transactions t
       left join public.folio_transactions o on o.id = t.reverses_id
       where t.property_id = p.id and t.business_date = d and t.status = 'posted' and coalesce(o.kind, t.kind) = 'tax'),
    (select count(*) from public.stays where property_id = p.id and business_date_in = d and status <> 'voided'),
    (select count(*) from public.stays where property_id = p.id and business_date_out = d and status = 'checked_out'),
    v_noshow, v_cancels,
    (select count(*) from public.stays s join public.reservations res on res.id = s.reservation_id
       where s.property_id = p.id and s.business_date_in = d and res.booking_source = 'walk_in' and s.status <> 'voided')
  on conflict (property_id, business_date) do update set
    rooms_total = excluded.rooms_total, rooms_ooo = excluded.rooms_ooo, rooms_oos = excluded.rooms_oos,
    rooms_available = excluded.rooms_available, rooms_sold = excluded.rooms_sold, room_revenue = excluded.room_revenue,
    total_revenue = excluded.total_revenue, tax_collected = excluded.tax_collected, arrivals = excluded.arrivals,
    departures = excluded.departures, no_shows = excluded.no_shows, cancellations = excluded.cancellations, walk_ins = excluded.walk_ins
  returning ds.* into v_stats;

  -- 8. open the next day
  update public.properties set business_date = d + 1 where id = p.id;
  v_summary := jsonb_build_object('closed', d, 'opened', d + 1, 'room_nights_posted', v_posted, 'no_shows', v_noshow,
                                  'holds_expired', v_expired, 'stayover_tasks', v_tasks, 'overstays_extended', v_overstay);
  insert into public.business_date_log (tenant_id, property_id, closed_date, opened_date, method, closed_by, summary)
  values (p.tenant_id, p.id, d, d + 1, p_method, auth.uid(), v_summary);
  return v_summary;
end $$;

-- Called by pg_cron every few minutes. A failure at one property never blocks the others.
create or replace function app.run_due_rollovers() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.properties; v_count int := 0; v_guard int;
begin
  for p in select * from public.properties where active loop
    v_guard := 0;
    while v_guard < 3 and (now() at time zone p.timezone) >= ((p.business_date + 1)::timestamp + p.rollover_time) loop
      begin
        perform app.roll_business_date(p.id);
        v_count := v_count + 1;
      exception when others then
        perform app.notify_permission(p.id, 'audit.businessdate.view', 'rollover_failed', 'Business date roll failed', sqlerrm, 'properties', p.id);
        exit;
      end;
      select * into p from public.properties where id = p.id;
      v_guard := v_guard + 1;
    end loop;
  end loop;
  return v_count;
end $$;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('hms-business-date-roll', '*/5 * * * *', 'select app.run_due_rollovers()');
  else
    raise notice 'pg_cron is not available here. Enable it in Supabase and schedule: select app.run_due_rollovers() every 5 minutes.';
  end if;
end $$;

-- ---------------------------------------------------------------- KPIs and boards (security invoker: the caller's row-level security applies)
create view public.v_kpi_daily with (security_invoker = true) as
select property_id, business_date, rooms_total, rooms_ooo, rooms_oos, rooms_available, rooms_sold,
       round(100.0 * rooms_sold / nullif(rooms_available, 0), 2) as occupancy_pct,
       round(room_revenue / nullif(rooms_sold, 0), 2)             as adr,
       round(room_revenue / nullif(rooms_available, 0), 2)        as revpar,
       room_revenue, total_revenue, tax_collected, arrivals, departures, no_shows, cancellations, walk_ins
from public.daily_stats;

create view public.v_arrivals with (security_invoker = true) as
select r.id as reservation_id, r.property_id, r.reservation_no, r.status, r.arrival_date, r.departure_date, r.adults, r.children,
       g.first_name, g.last_name, g.phone, rt.name as room_type, r.arrival_ready, r.guarantee_type, r.deposit_required,
       (select ro.room_number from public.room_assignments a join public.rooms ro on ro.id = a.room_id
         where a.reservation_id = r.id and a.status = 'held') as assigned_room
from public.reservations r
join public.guests g on g.id = r.primary_guest_id
join public.room_types rt on rt.id = r.room_type_id
join public.properties p on p.id = r.property_id
where r.status in ('confirmed','tentative') and r.arrival_date <= p.business_date;

create view public.v_in_house with (security_invoker = true) as
select r.id as reservation_id, r.property_id, r.reservation_no, r.arrival_date, r.departure_date,
       g.first_name, g.last_name, ro.room_number, ro.id as room_id, s.id as stay_id,
       (select coalesce(sum(b.balance), 0) from public.v_folio_balances b where b.reservation_id = r.id) as balance,
       r.departure_date <= p.business_date as departing_or_overdue
from public.reservations r
join public.guests g on g.id = r.primary_guest_id
join public.stays s on s.reservation_id = r.id and s.status = 'in_house'
join public.room_assignments a on a.stay_id = s.id and a.status = 'active'
join public.rooms ro on ro.id = a.room_id
join public.properties p on p.id = r.property_id
where r.status = 'checked_in';

create view public.v_room_board with (security_invoker = true) as
select ro.id as room_id, ro.property_id, ro.room_number, ro.floor, ro.room_type_id, ro.condition, ro.is_occupied,
       (select b.block_type from public.room_blocks b join public.properties p on p.id = ro.property_id
         where b.room_id = ro.id and b.status = 'active' and b.block_range @> p.business_date limit 1) as active_block,
       case when ro.status = 'retired' then 'retired'
            when exists (select 1 from public.room_blocks b join public.properties p on p.id = ro.property_id
                          where b.room_id = ro.id and b.status = 'active' and b.block_type = 'ooo' and b.block_range @> p.business_date) then 'out_of_order'
            when exists (select 1 from public.room_blocks b join public.properties p on p.id = ro.property_id
                          where b.room_id = ro.id and b.status = 'active' and b.block_type = 'oos' and b.block_range @> p.business_date) then 'out_of_service'
            when ro.is_occupied then 'occupied'
            when ro.condition = 'ready' then 'vacant_ready'
            else 'vacant_' || ro.condition end as board_status
from public.rooms ro;

create view public.v_hk_board with (security_invoker = true) as
select t.id as task_id, t.property_id, t.room_id, ro.room_number, ro.floor, t.task_type, t.status, t.priority,
       t.assigned_to, t.business_date, ro.condition, ro.is_occupied
from public.hk_tasks t join public.rooms ro on ro.id = t.room_id
where t.status not in ('inspected','cancelled');
