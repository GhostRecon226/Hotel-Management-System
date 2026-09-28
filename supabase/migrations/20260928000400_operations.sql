-- HMS 0004: housekeeping, maintenance, service requests, notifications, daily statistics.
-- State changes on these tables go through RPCs (0008). Direct writes are limited to lost and found.

create table public.hk_tasks (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null,
  property_id   uuid not null,
  room_id       uuid not null,
  task_type     text not null check (task_type in ('turnover','stayover','deep_clean','inspection_only')),
  status        text not null default 'pending' check (status in
                  ('pending','assigned','in_progress','completed','inspected','rework','cancelled')),
  priority      int not null default 0,
  assigned_to   uuid,
  assigned_at   timestamptz,
  started_at    timestamptz,
  completed_at  timestamptz,
  inspected_by  uuid,
  inspected_at  timestamptz,
  inspection_result text check (inspection_result in ('pass','fail')),
  fail_reason   text,
  defects       jsonb not null default '[]',
  checklist     jsonb not null default '[]',
  notes         text,
  stay_id       uuid,
  business_date date,
  cancelled_reason text,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (property_id, room_id) references public.rooms (property_id, id)
);
create index on public.hk_tasks (property_id, status);
create index on public.hk_tasks (assigned_to, status);
create unique index one_open_turnover_per_room on public.hk_tasks (room_id)
  where task_type = 'turnover' and status not in ('inspected','cancelled');

create table public.lost_found_items (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  property_id  uuid not null,
  room_id      uuid,
  description  text not null,
  found_on     date not null default current_date,
  found_by     uuid,
  status       text not null default 'found' check (status in ('found','returned','disposed')),
  returned_to  text,
  returned_on  date,
  notes        text,
  created_at   timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade
);

create table public.maintenance_tickets (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null,
  property_id     uuid not null,
  ticket_no       text not null,
  room_id         uuid,
  location        text,
  title           text not null,
  description     text,
  priority        text not null default 'medium' check (priority in ('low','medium','high','critical')),
  status          text not null default 'open' check (status in
                    ('open','assigned','in_progress','waiting','resolved','closed','cancelled')),
  reported_by     uuid,
  assigned_to     uuid,
  assigned_at     timestamptz,
  started_at      timestamptz,
  waiting_reason  text,
  resolution_note text,
  resolved_by     uuid,
  resolved_at     timestamptz,
  closed_by       uuid,
  closed_at       timestamptz,
  cancelled_reason text,
  block_id        uuid,
  created_at      timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (property_id, room_id) references public.rooms (property_id, id),
  unique (property_id, ticket_no)
);
create index on public.maintenance_tickets (property_id, status);
alter table public.room_blocks add constraint room_blocks_ticket_fk foreign key (ticket_id) references public.maintenance_tickets(id);

create table public.service_requests (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null,
  property_id      uuid not null,
  request_no       text not null,
  reservation_id   uuid,
  stay_id          uuid,
  room_id          uuid,
  category         text not null,
  description      text not null,
  status           text not null default 'new' check (status in ('new','assigned','in_progress','completed','cancelled')),
  assigned_to      uuid,
  assigned_department text,
  chargeable       boolean not null default false,
  charge_amount    numeric(20,4),
  currency         text,
  charge_code_id   uuid,
  completed_by     uuid,
  completed_at     timestamptz,
  cancelled_reason text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  unique (property_id, request_no)
);
create index on public.service_requests (property_id, status);

create table public.notifications (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  property_id  uuid,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  kind         text not null,
  title        text not null,
  body         text,
  entity_table text,
  entity_id    uuid,
  created_at   timestamptz not null default now(),
  read_at      timestamptz
);
create index on public.notifications (user_id, read_at, created_at desc);

-- Outbound email/SMS queue. Written by the engine, drained by an Edge Function using the service role.
create table public.notification_outbox (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null,
  property_id   uuid,
  channel       text not null check (channel in ('email','sms')),
  to_address    text not null,
  template      text not null,
  payload       jsonb not null default '{}',
  status        text not null default 'queued' check (status in ('queued','sent','failed')),
  attempts      int not null default 0,
  created_at    timestamptz not null default now(),
  sent_at       timestamptz
);
create index on public.notification_outbox (status, created_at);

-- One row per property per closed business date. Feeds the KPI views.
create table public.daily_stats (
  property_id      uuid not null references public.properties(id) on delete cascade,
  business_date    date not null,
  tenant_id        uuid not null,
  rooms_total      int not null default 0,   -- active rooms
  rooms_ooo        int not null default 0,   -- out of order: leave the KPI denominator (assumption A5)
  rooms_oos        int not null default 0,   -- out of service: stay in the denominator
  rooms_available  int not null default 0,   -- rooms_total - rooms_ooo
  rooms_sold       int not null default 0,
  room_revenue     numeric(20,4) not null default 0,   -- net of tax and service charge, base currency
  total_revenue    numeric(20,4) not null default 0,
  tax_collected    numeric(20,4) not null default 0,
  arrivals         int not null default 0,
  departures       int not null default 0,
  no_shows         int not null default 0,
  cancellations    int not null default 0,
  walk_ins         int not null default 0,
  created_at       timestamptz not null default now(),
  primary key (property_id, business_date),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade
);

create table public.business_date_log (
  id            bigint generated always as identity primary key,
  tenant_id     uuid not null,
  property_id   uuid not null references public.properties(id) on delete cascade,
  closed_date   date not null,
  opened_date   date not null,
  method        text not null default 'auto_roll' check (method in ('auto_roll','night_audit')),
  closed_by     uuid,
  summary       jsonb not null default '{}',
  occurred_at   timestamptz not null default now(),
  unique (property_id, closed_date)
);

-- ---------------------------------------------------------------- notifications helper
-- Notify every user who holds a permission at a property (tenant-wide assignments included).
create or replace function app.notify_permission(
  p_property uuid, p_key text, p_kind text, p_title text, p_body text default null,
  p_entity_table text default null, p_entity_id uuid default null)
returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tenant uuid; v_n int;
begin
  select tenant_id into v_tenant from public.properties where id = p_property;
  insert into public.notifications (tenant_id, property_id, user_id, kind, title, body, entity_table, entity_id)
  select distinct v_tenant, p_property, upr.user_id, p_kind, p_title, p_body, p_entity_table, p_entity_id
  from public.user_property_roles upr
  join public.profiles pr on pr.id = upr.user_id and pr.status = 'active'
  join public.role_permissions rp on rp.role_id = upr.role_id and rp.permission_key = p_key
  where upr.tenant_id = v_tenant and (upr.property_id is null or upr.property_id = p_property);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function app.notify_user(
  p_user uuid, p_property uuid, p_kind text, p_title text, p_body text default null,
  p_entity_table text default null, p_entity_id uuid default null)
returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.notifications (tenant_id, property_id, user_id, kind, title, body, entity_table, entity_id)
  select tenant_id, p_property, id, p_kind, p_title, p_body, p_entity_table, p_entity_id
  from public.profiles where id = p_user
$$;

-- ---------------------------------------------------------------- RLS
alter table public.hk_tasks            enable row level security;
alter table public.lost_found_items    enable row level security;
alter table public.maintenance_tickets enable row level security;
alter table public.service_requests    enable row level security;
alter table public.notifications       enable row level security;
alter table public.notification_outbox enable row level security;
alter table public.daily_stats         enable row level security;
alter table public.business_date_log   enable row level security;

create policy hk_read on public.hk_tasks for select to authenticated
  using (app.can(property_id, 'hk.board.view')
         or (assigned_to = auth.uid() and app.can(property_id, 'hk.task.execute')));

-- Room attendants (room.view at level O) see only rooms they currently have a task for.
create policy rooms_read_own on public.rooms for select to authenticated
  using (app.grant_level(property_id, 'room.view') = 'O'
         and exists (select 1 from public.hk_tasks t
                     where t.room_id = rooms.id and t.assigned_to = auth.uid()
                       and t.status not in ('inspected','cancelled')));

create policy lf_read on public.lost_found_items for select to authenticated
  using (app.can(property_id, 'hk.lostfound.manage'));
create policy lf_ins on public.lost_found_items for insert to authenticated
  with check (app.can(property_id, 'hk.lostfound.manage') and app.tenant_writable(tenant_id));
create policy lf_upd on public.lost_found_items for update to authenticated
  using (app.can(property_id, 'hk.lostfound.manage') and app.tenant_writable(tenant_id));

create policy mnt_read on public.maintenance_tickets for select to authenticated
  using (app.can(property_id, 'mnt.view') or reported_by = auth.uid()
         or (assigned_to = auth.uid() and app.can(property_id, 'mnt.ticket.work')));

create policy svc_read on public.service_requests for select to authenticated
  using (app.grant_level(property_id, 'svc.request.manage') = 'Y'
         or (app.can(property_id, 'svc.request.manage') and (assigned_to = auth.uid() or created_by = auth.uid()))
         or created_by = auth.uid());

create policy notif_read on public.notifications for select to authenticated using (user_id = auth.uid());
create policy notif_upd on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- notification_outbox: no policy (service role only)

create policy stats_read on public.daily_stats for select to authenticated
  using (app.can(property_id, 'rep.ops.view') or app.can(property_id, 'rep.fin.view') or app.can(property_id, 'dash.view_exec'));
create policy bdlog_read on public.business_date_log for select to authenticated
  using (app.can(property_id, 'audit.businessdate.view'));

create trigger lost_found_audit after insert or update or delete on public.lost_found_items
  for each row execute function app.audit_change();
