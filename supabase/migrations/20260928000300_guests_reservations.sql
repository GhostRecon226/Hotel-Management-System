-- HMS 0003: guests, groups, reservations, stays, room assignments, room blocks, availability.
-- Guest -> Reservation -> Stay -> Room Assignment -> Folio (folio comes in 0005).
-- One reservation = one room. Several rooms = a group booking (reservations sharing group_id).

create or replace function app.can_any(p_key text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.user_property_roles upr
    join public.profiles pr on pr.id = upr.user_id and pr.status = 'active'
    join public.role_permissions rp on rp.role_id = upr.role_id
    where upr.user_id = auth.uid() and rp.permission_key = p_key)
$$;

-- ---------------------------------------------------------------- guests (tenant-level identity, BR-003)
create table public.guests (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete cascade,
  first_name        text not null,
  last_name         text not null,
  phone             text,
  email             text,
  nationality       text,
  date_of_birth     date,
  preferences       jsonb not null default '{}',
  notes             text,
  marketing_consent boolean not null default false,
  anonymised_at     timestamptz,        -- personal data removed on request; ledger keeps the id
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (tenant_id, id)
);
create index on public.guests (tenant_id, lower(last_name));
create index on public.guests (tenant_id, phone);
create index on public.guests (tenant_id, lower(email));

-- Identity documents are separate so they can be hidden behind guest.idocs.view
create table public.guest_documents (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null,
  guest_id        uuid not null,
  doc_type        text not null,   -- passport, national_id, drivers_licence, other
  doc_number      text not null,
  issuing_country text,
  expiry_date     date,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id) on delete cascade
);
create index on public.guest_documents (tenant_id, guest_id);
create index on public.guest_documents (tenant_id, doc_number);

create table public.guest_feedback (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  property_id uuid not null,
  guest_id    uuid not null,
  kind        text not null check (kind in ('complaint','feedback','compliment')),
  body        text not null,
  status      text not null default 'open' check (status in ('open','resolved')),
  resolution  text,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id)
);

-- ---------------------------------------------------------------- group bookings (rooming list)
create table public.group_bookings (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null,
  property_id    uuid not null,
  name           text not null,
  contact_name   text,
  contact_phone  text,
  contact_email  text,
  arrival_date   date,
  departure_date date,
  notes          text,
  status         text not null default 'open' check (status in ('open','closed','cancelled')),
  created_by     uuid,
  created_at     timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  unique (property_id, id)
);

-- ---------------------------------------------------------------- reservations
create table public.reservations (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null,
  property_id         uuid not null,
  reservation_no      text not null,
  status              text not null default 'inquiry' check (status in
                        ('inquiry','tentative','confirmed','checked_in','checked_out','cancelled','no_show')),
  booking_source      text not null check (booking_source in ('direct','walk_in','phone','email','corporate','group','ota','other')),
  company_name        text,                       -- A3: free text in R1
  group_id            uuid,
  primary_guest_id    uuid not null,
  arrival_date        date not null,
  departure_date      date not null,
  adults              int not null default 1 check (adults >= 1),
  children            int not null default 0 check (children >= 0),
  room_type_id        uuid not null,
  rate_plan_id        uuid not null,
  currency            text not null references public.currencies(code),
  total_amount        numeric(20,4) not null default 0,   -- sum of nights as priced
  deposit_required    numeric(20,4) not null default 0 check (deposit_required >= 0),
  guarantee_type      text not null default 'none' check (guarantee_type in ('none','deposit','card','company','other')),
  hold_expires_at     timestamptz,
  arrival_ready       boolean not null default false,     -- pre-arrival checklist flag, not a status
  special_requests    text,
  notes               text,
  cancelled_at        timestamptz,
  cancellation_reason text,
  no_show_at          timestamptz,
  created_by          uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  idempotency_key     text,
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (tenant_id, primary_guest_id) references public.guests (tenant_id, id),
  foreign key (property_id, room_type_id) references public.room_types (property_id, id),
  foreign key (property_id, rate_plan_id) references public.rate_plans (property_id, id),
  foreign key (property_id, group_id) references public.group_bookings (property_id, id),
  check (departure_date > arrival_date),
  unique (property_id, id),
  unique (property_id, reservation_no),
  unique (tenant_id, idempotency_key)
);
create index on public.reservations (property_id, arrival_date) where status in ('tentative','confirmed');
create index on public.reservations (property_id, departure_date) where status = 'checked_in';
create index on public.reservations (property_id, status);
create index on public.reservations (primary_guest_id);

create table public.reservation_guests (
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  tenant_id      uuid not null,
  guest_id       uuid not null,
  is_primary     boolean not null default false,
  primary key (reservation_id, guest_id),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id)
);

create table public.reservation_nights (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null,
  property_id    uuid not null,
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  stay_date      date not null,
  room_type_id   uuid not null,         -- room type occupied that night (an upgrade changes it)
  rate_amount    numeric(20,4) not null check (rate_amount >= 0),
  currency       text not null references public.currencies(code),
  price_includes_tax boolean not null default false,
  unique (reservation_id, stay_date),
  foreign key (property_id, room_type_id) references public.room_types (property_id, id)
);
create index on public.reservation_nights (property_id, room_type_id, stay_date);

-- ---------------------------------------------------------------- stays and room assignments
create table public.stays (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null,
  property_id       uuid not null,
  reservation_id    uuid not null,
  status            text not null default 'in_house' check (status in ('in_house','checked_out','voided')),
  checked_in_at     timestamptz not null default now(),
  checked_out_at    timestamptz,
  business_date_in  date not null,
  business_date_out date,
  registration      jsonb not null default '{}',
  created_by        uuid,
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (property_id, reservation_id) references public.reservations (property_id, id),
  unique (property_id, id)
);
-- one live stay per reservation; a voided check-in can be followed by a new one
create unique index one_live_stay_per_reservation on public.stays (reservation_id) where status <> 'voided';

create table public.room_assignments (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null,
  property_id    uuid not null,
  reservation_id uuid not null,
  stay_id        uuid,
  room_id        uuid not null,
  status         text not null check (status in ('held','active','ended','released')),
  stay_range     daterange not null,       -- [arrival, departure). Nights the room is used under this assignment.
  created_by     uuid,
  created_at     timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (property_id, reservation_id) references public.reservations (property_id, id),
  foreign key (property_id, stay_id) references public.stays (property_id, id),
  foreign key (property_id, room_id) references public.rooms (property_id, id),
  check (not isempty(stay_range)),
  -- BR-005 / business rule: a physical room cannot be allocated to overlapping stays. Enforced by the database.
  constraint no_overlapping_room_use
    exclude using gist (room_id with =, stay_range with &&) where (status in ('held','active'))
);
create unique index one_held_per_reservation on public.room_assignments (reservation_id) where status = 'held';
create unique index one_active_per_stay on public.room_assignments (stay_id) where status = 'active';
create index on public.room_assignments (property_id, room_id);

-- ---------------------------------------------------------------- room blocks (OOO / OOS)
create table public.room_blocks (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null,
  property_id   uuid not null,
  room_id       uuid not null,
  block_type    text not null check (block_type in ('ooo','oos')),
  block_range   daterange not null,        -- [start, end). Nights the room is out of the sellable pool.
  status        text not null default 'requested' check (status in
                  ('requested','approved','active','released','rejected','cancelled')),
  reason        text not null,
  ticket_id     uuid,                       -- set by maintenance when the block comes from a ticket
  requested_by  uuid,
  decided_by    uuid,
  decided_at    timestamptz,
  released_by   uuid,
  released_at   timestamptz,
  created_at    timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (property_id, room_id) references public.rooms (property_id, id),
  check (not isempty(block_range))
);
create index on public.room_blocks (property_id, room_id);

-- ---------------------------------------------------------------- availability
-- A reservation holds inventory while tentative (hold not expired), confirmed, or checked in.
create or replace function app.holds_inventory(p_status text, p_hold_expires timestamptz) returns boolean
language sql stable as $$
  select case p_status
    when 'confirmed' then true
    when 'checked_in' then true
    when 'tentative' then (p_hold_expires is null or p_hold_expires > now())
    else false end
$$;

-- Per room type and night: rooms that can be sold, rooms reserved, rooms left.
-- Sellability is derived: a room is out of the pool on nights covered by an approved or active block.
-- Condition (dirty, clean) does not affect future sellability.
create or replace function public.get_availability(p_property uuid, p_arrival date, p_departure date)
returns table (room_type_id uuid, stay_date date, sellable_rooms int, reserved int, available int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require(p_property, 'res.availability.view');
  if p_departure <= p_arrival then perform app.fail('E_DATES', 'Departure must be after arrival.'); end if;
  return query
  with nights as (select d::date as stay_date from generate_series(p_arrival, p_departure - 1, interval '1 day') d),
  types as (select rt.id, rt.overbooking_limit from public.room_types rt where rt.property_id = p_property and rt.sellable),
  sellable as (
    select t.id as room_type_id, n.stay_date, count(r.id)::int as cnt
    from types t cross join nights n
    left join public.rooms r on r.property_id = p_property and r.room_type_id = t.id and r.status = 'active'
      and not exists (select 1 from public.room_blocks b
                      where b.room_id = r.id and b.status in ('approved','active') and b.block_range @> n.stay_date)
    group by t.id, n.stay_date),
  reserved as (
    select rn.room_type_id, rn.stay_date, count(*)::int as cnt
    from public.reservation_nights rn
    join public.reservations res on res.id = rn.reservation_id
    where rn.property_id = p_property and rn.stay_date >= p_arrival and rn.stay_date < p_departure
      and app.holds_inventory(res.status, res.hold_expires_at)
    group by rn.room_type_id, rn.stay_date)
  select s.room_type_id, s.stay_date, s.cnt,
         coalesce(rv.cnt, 0),
         s.cnt - coalesce(rv.cnt, 0) + t.overbooking_limit
  from sellable s
  join types t on t.id = s.room_type_id
  left join reserved rv on rv.room_type_id = s.room_type_id and rv.stay_date = s.stay_date
  order by s.room_type_id, s.stay_date;
end $$;

-- Internal: raises unless every night has at least one room left. Caller must hold the property lock.
create or replace function app.assert_available(p_property uuid, p_room_type uuid, p_arrival date, p_departure date, p_exclude_reservation uuid default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_short date; v_rt_sellable boolean;
begin
  select sellable into v_rt_sellable from public.room_types where id = p_room_type and property_id = p_property;
  if v_rt_sellable is null then perform app.fail('E_ROOM_TYPE', 'Room type not found for this property.'); end if;
  if not v_rt_sellable then perform app.fail('E_UNAVAILABLE', 'This room type is not sellable.'); end if;
  select n.stay_date into v_short
  from generate_series(p_arrival, p_departure - 1, interval '1 day') g(d)
  cross join lateral (
    select g.d::date as stay_date,
      (select count(*) from public.rooms r
        where r.property_id = p_property and r.room_type_id = p_room_type and r.status = 'active'
          and not exists (select 1 from public.room_blocks b
                          where b.room_id = r.id and b.status in ('approved','active') and b.block_range @> g.d::date))
      + (select overbooking_limit from public.room_types where id = p_room_type)
      - (select count(*) from public.reservation_nights rn
          join public.reservations res on res.id = rn.reservation_id
          where rn.property_id = p_property and rn.room_type_id = p_room_type and rn.stay_date = g.d::date
            and (p_exclude_reservation is null or res.id <> p_exclude_reservation)
            and app.holds_inventory(res.status, res.hold_expires_at)) as left_over
  ) n
  where n.left_over <= 0
  order by n.stay_date limit 1;
  if v_short is not null then
    perform app.fail('E_UNAVAILABLE', format('No availability for this room type on %s.', v_short));
  end if;
end $$;

-- Serialises bookings per property and room type so two people cannot take the last room together.
create or replace function app.lock_inventory(p_property uuid, p_room_type uuid) returns void
language sql as $$ select pg_advisory_xact_lock(hashtextextended(p_property::text || ':' || p_room_type::text, 0)) $$;

-- Rooms that could be assigned for a stay: active, right type (or any type if null), no block, no overlapping assignment.
create or replace function public.get_assignable_rooms(p_property uuid, p_arrival date, p_departure date, p_room_type uuid default null)
returns table (room_id uuid, room_number text, room_type_id uuid, condition text, is_occupied boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require(p_property, 'room.view');
  return query
  select r.id, r.room_number, r.room_type_id, r.condition, r.is_occupied
  from public.rooms r
  where r.property_id = p_property and r.status = 'active'
    and (p_room_type is null or r.room_type_id = p_room_type)
    and not exists (select 1 from public.room_blocks b
                    where b.room_id = r.id and b.status in ('approved','active')
                      and b.block_range && daterange(p_arrival, p_departure))
    and not exists (select 1 from public.room_assignments a
                    where a.room_id = r.id and a.status in ('held','active')
                      and a.stay_range && daterange(p_arrival, p_departure))
  order by r.room_number;
end $$;

-- Guest search (GST-01). Runs with the caller's rights, so row-level security limits what comes back.
create or replace function public.search_guests(p_query text, p_limit int default 25)
returns setof public.guests
language sql stable security invoker as $$
  select g.* from public.guests g
  where g.anonymised_at is null
    and (g.last_name ilike '%' || p_query || '%' or g.first_name ilike '%' || p_query || '%'
      or g.phone ilike '%' || p_query || '%' or g.email ilike '%' || p_query || '%'
      or exists (select 1 from public.guest_documents d where d.guest_id = g.id and d.doc_number ilike p_query)
      or exists (select 1 from public.reservations r where r.primary_guest_id = g.id and r.reservation_no ilike p_query))
  order by g.last_name, g.first_name
  limit least(p_limit, 100)
$$;

-- ---------------------------------------------------------------- RLS
alter table public.guests             enable row level security;
alter table public.guest_documents    enable row level security;
alter table public.guest_feedback     enable row level security;
alter table public.group_bookings     enable row level security;
alter table public.reservations       enable row level security;
alter table public.reservation_guests enable row level security;
alter table public.reservation_nights enable row level security;
alter table public.stays              enable row level security;
alter table public.room_assignments   enable row level security;
alter table public.room_blocks        enable row level security;

create policy guests_read on public.guests for select to authenticated
  using (tenant_id = app.my_tenant() and app.can_any('guest.view'));
create policy guests_ins on public.guests for insert to authenticated
  with check (tenant_id = app.my_tenant() and app.can_any('guest.create') and app.tenant_writable(tenant_id));
create policy guests_upd on public.guests for update to authenticated
  using (tenant_id = app.my_tenant() and app.can_any('guest.edit') and app.tenant_writable(tenant_id))
  with check (tenant_id = app.my_tenant());

create policy gdocs_read on public.guest_documents for select to authenticated
  using (tenant_id = app.my_tenant() and app.can_any('guest.idocs.view'));
create policy gdocs_ins on public.guest_documents for insert to authenticated
  with check (tenant_id = app.my_tenant() and app.can_any('guest.edit') and app.tenant_writable(tenant_id));
create policy gdocs_upd on public.guest_documents for update to authenticated
  using (tenant_id = app.my_tenant() and app.can_any('guest.edit') and app.tenant_writable(tenant_id));

create policy gfb_read on public.guest_feedback for select to authenticated
  using (app.can(property_id, 'guest.complaint.manage'));
create policy gfb_ins on public.guest_feedback for insert to authenticated
  with check (app.can(property_id, 'guest.complaint.manage') and app.tenant_writable(tenant_id));
create policy gfb_upd on public.guest_feedback for update to authenticated
  using (app.can(property_id, 'guest.complaint.manage') and app.tenant_writable(tenant_id));

create policy groups_read on public.group_bookings for select to authenticated
  using (app.can(property_id, 'res.view') or app.can(property_id, 'res.group.manage'));
create policy groups_ins on public.group_bookings for insert to authenticated
  with check (app.can(property_id, 'res.group.manage') and app.tenant_writable(tenant_id));
create policy groups_upd on public.group_bookings for update to authenticated
  using (app.can(property_id, 'res.group.manage') and app.tenant_writable(tenant_id));

-- Reservations, nights, guests-on-reservation, stays, assignments: read only. Every change goes through an RPC.
create policy res_read on public.reservations for select to authenticated
  using (app.can(property_id, 'res.view') or app.can(property_id, 'fo.board.view'));
create policy resg_read on public.reservation_guests for select to authenticated
  using (exists (select 1 from public.reservations r where r.id = reservation_id
                 and (app.can(r.property_id, 'res.view') or app.can(r.property_id, 'fo.board.view'))));
create policy resn_read on public.reservation_nights for select to authenticated
  using (app.can(property_id, 'res.view') or app.can(property_id, 'fo.board.view'));
create policy stays_read on public.stays for select to authenticated
  using (app.can(property_id, 'res.view') or app.can(property_id, 'fo.board.view'));
create policy assign_read on public.room_assignments for select to authenticated
  using (app.can(property_id, 'res.view') or app.can(property_id, 'fo.board.view'));

create policy blocks_read on public.room_blocks for select to authenticated
  using (app.grant_level(property_id, 'room.view') = 'Y' or app.can(property_id, 'room.block.request'));

-- Guest audit records which fields changed, never their values. Audit rows are immutable, so personal data
-- must not be copied into them or erasure requests could not be honoured.
create or replace function app.audit_change_pii() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_changed jsonb;
begin
  if tg_op = 'UPDATE' then
    select coalesce(jsonb_agg(n.key), '[]') into v_changed
    from jsonb_each(to_jsonb(new)) n join jsonb_each(to_jsonb(old)) o using (key)
    where n.value is distinct from o.value and n.key <> 'updated_at';
  end if;
  insert into public.audit_events (tenant_id, actor_id, action, entity_table, entity_id, after_data, reason)
  values (coalesce(new.tenant_id, old.tenant_id), auth.uid(), lower(tg_op), tg_table_name, coalesce(new.id, old.id),
          jsonb_build_object('changed_fields', v_changed), nullif(current_setting('app.reason', true), ''));
  return coalesce(new, old);
end $$;
create trigger guests_audit after insert or update or delete on public.guests
  for each row execute function app.audit_change_pii();
create trigger guest_documents_audit after insert or update or delete on public.guest_documents
  for each row execute function app.audit_change_pii();
create trigger group_bookings_audit after insert or update or delete on public.group_bookings
  for each row execute function app.audit_change();
