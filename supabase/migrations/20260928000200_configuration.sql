-- HMS 0002: configuration owned by a tenant/property: currencies, exchange rates, taxes, charge codes,
-- payment methods, room types, rooms, rate plans, prices, document numbering, country templates.

-- ---------------------------------------------------------------- reference data
create table public.currencies (
  code     text primary key,
  name     text not null,
  decimals smallint not null default 2 check (decimals between 0 and 4)
);

create table public.country_templates (
  country_code    char(2) primary key,
  name            text not null,
  currency        text not null references public.currencies(code),
  timezone        text not null,
  tax_lines       jsonb not null default '[]',
  payment_methods jsonb not null default '[]',
  charge_codes    jsonb not null default '[]',
  verified        boolean not null default false,   -- true only after a local accountant confirms the values
  notes           text
);

create table public.document_sequences (
  tenant_id   uuid not null,
  property_id uuid not null references public.properties(id) on delete cascade,
  kind        text not null,
  next_value  bigint not null default 1,
  primary key (property_id, kind)
);

-- ---------------------------------------------------------------- exchange rates (multi-currency, assumption A10)
create table public.exchange_rates (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  property_id uuid not null,
  currency    text not null references public.currencies(code),
  rate_date   date not null,
  rate        numeric(20,8) not null check (rate > 0),   -- units of property base currency per 1 unit of currency
  source      text not null default 'manual',
  created_by  uuid,
  created_at  timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  unique (property_id, currency, rate_date)
);

-- ---------------------------------------------------------------- taxes, charge codes, payment methods
create table public.tax_rates (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  property_id uuid not null,
  code        text not null,
  name        text not null,
  rate        numeric(9,6) not null check (rate >= 0),        -- percent, e.g. 7.5
  calc_base   text not null default 'net' check (calc_base in ('net','net_plus_prior')),
  seq         int  not null default 1,                          -- order of application
  applies_to  text[] not null default '{room,fnb,other}',       -- charge code revenue groups
  effective_from date not null default date '2000-01-01',
  effective_to   date,
  active      boolean not null default true,
  verified    boolean not null default false,                   -- unverified until an accountant confirms (A11)
  created_at  timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  unique (property_id, code)
);

create table public.charge_codes (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null,
  property_id   uuid not null,
  code          text not null,
  name          text not null,
  revenue_group text not null check (revenue_group in ('room','fnb','other','fee')),
  taxable       boolean not null default true,
  is_system     boolean not null default false,   -- codes the engine posts itself (ROOM, NOSHOW, CANCEL)
  active        boolean not null default true,
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  unique (property_id, code),
  unique (property_id, id)
);

create table public.payment_methods (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  property_id uuid not null,
  code        text not null,
  name        text not null,
  kind        text not null check (kind in ('cash','card_terminal','bank_transfer','mobile_money','online_gateway','other')),
  active      boolean not null default true,
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  unique (property_id, code),
  unique (property_id, id)
);

-- ---------------------------------------------------------------- room types and rooms
create table public.room_types (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null,
  property_id      uuid not null,
  code             text not null,
  name             text not null,
  description      text,
  base_occupancy   int not null default 2 check (base_occupancy > 0),
  max_adults       int not null default 2 check (max_adults > 0),
  max_children     int not null default 0 check (max_children >= 0),
  amenities        text[] not null default '{}',
  sellable         boolean not null default true,
  overbooking_limit int not null default 0 check (overbooking_limit >= 0),
  sort_order       int not null default 0,
  created_at       timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  unique (property_id, code),
  unique (property_id, id)
);

create table public.rooms (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null,
  property_id          uuid not null,
  room_number          text not null,
  room_type_id         uuid not null,
  building             text,
  floor                text,
  status               text not null default 'active' check (status in ('active','retired')),
  -- Condition and occupancy are written only by the engine functions, never by the UI (see grants migration).
  condition            text not null default 'ready' check (condition in ('dirty','cleaning','awaiting_inspection','ready')),
  is_occupied          boolean not null default false,
  condition_updated_at timestamptz not null default now(),
  notes                text,
  created_at           timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (property_id, room_type_id) references public.room_types (property_id, id),
  unique (property_id, room_number),
  unique (property_id, id)
);
create index on public.rooms (property_id, room_type_id);

-- ---------------------------------------------------------------- rate plans
create table public.rate_plans (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null,
  property_id        uuid not null,
  code               text not null,
  name               text not null,
  description        text,
  is_corporate       boolean not null default false,   -- A3: corporate is a tag on a rate plan in R1, no Company entity
  meal_plan          text not null default 'room_only',
  min_stay           int not null default 1 check (min_stay >= 1),
  max_stay           int check (max_stay is null or max_stay >= min_stay),
  price_includes_tax boolean not null default false,
  -- policy shapes: {"type":"none|first_night|percent|fixed","value":0,"free_until_days":1}
  cancellation       jsonb not null default '{"type":"none","value":0,"free_until_days":0}',
  no_show            jsonb not null default '{"type":"none","value":0}',
  deposit            jsonb not null default '{"type":"none","value":0}',
  valid_from         date,
  valid_to           date,
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  unique (property_id, code),
  unique (property_id, id)
);

create table public.rate_plan_prices (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null,
  property_id  uuid not null,
  rate_plan_id uuid not null,
  room_type_id uuid not null,
  valid_from   date not null,
  valid_to     date not null,
  dow          smallint[] not null default '{0,1,2,3,4,5,6}',   -- 0 = Sunday
  amount       numeric(20,4) not null check (amount >= 0),
  currency     text not null references public.currencies(code),
  priority     int not null default 0,                            -- higher wins when ranges overlap
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (property_id, rate_plan_id) references public.rate_plans (property_id, id) on delete cascade,
  foreign key (property_id, room_type_id) references public.room_types (property_id, id) on delete cascade,
  check (valid_from <= valid_to)
);
create index on public.rate_plan_prices (rate_plan_id, room_type_id, valid_from, valid_to);

-- ---------------------------------------------------------------- helpers
create or replace function app.currency_decimals(p_currency text) returns int
language sql stable as $$ select decimals::int from public.currencies where code = p_currency $$;

create or replace function app.round_money(p_amount numeric, p_currency text) returns numeric
language sql stable as $$ select round(p_amount, coalesce(app.currency_decimals(p_currency), 2)) $$;

-- Rate to convert 1 unit of p_currency into the property's base currency, latest on or before p_date.
create or replace function app.fx_rate(p_property uuid, p_currency text, p_date date) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_base text; v_rate numeric;
begin
  select base_currency into v_base from public.properties where id = p_property;
  if p_currency = v_base then return 1; end if;
  select rate into v_rate from public.exchange_rates
   where property_id = p_property and currency = p_currency and rate_date <= p_date
   order by rate_date desc limit 1;
  if v_rate is null then
    perform app.fail('E_NO_RATE', format('No exchange rate for %s to %s on or before %s. Enter today''s rate first.', p_currency, v_base, p_date));
  end if;
  return v_rate;
end $$;

-- Gapless per-property document numbers. Runs inside the caller's transaction, so a rollback returns the number.
create or replace function app.next_doc_no(p_property uuid, p_kind text, p_prefix text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n bigint; v_code text;
begin
  insert into public.document_sequences (tenant_id, property_id, kind, next_value)
  values (app.property_tenant(p_property), p_property, p_kind, 2)
  on conflict (property_id, kind) do update set next_value = public.document_sequences.next_value + 1
  returning next_value - 1 into v_n;
  select code into v_code from public.properties where id = p_property;
  return v_code || '-' || p_prefix || '-' || lpad(v_n::text, 6, '0');
end $$;

-- Price of one night for a rate plan and room type. Highest priority wins, then latest start date.
create or replace function app.night_price(p_property uuid, p_rate_plan uuid, p_room_type uuid, p_date date)
returns table (amount numeric, currency text)
language sql stable security definer set search_path = public, pg_temp as $$
  select rpp.amount, rpp.currency
  from public.rate_plan_prices rpp
  where rpp.property_id = p_property and rpp.rate_plan_id = p_rate_plan and rpp.room_type_id = p_room_type
    and p_date between rpp.valid_from and rpp.valid_to
    and extract(dow from p_date)::smallint = any (rpp.dow)
  order by rpp.priority desc, rpp.valid_from desc
  limit 1
$$;

-- ---------------------------------------------------------------- RLS
do $$
declare t text;
begin
  foreach t in array array['currencies','country_templates','document_sequences','exchange_rates','tax_rates','charge_codes',
                           'payment_methods','room_types','rooms','rate_plans','rate_plan_prices']
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

create policy currencies_read on public.currencies for select to authenticated using (true);
-- country_templates and document_sequences: no policy, service role and engine functions only.

-- Read: anyone with access to the property. Write: named permission, and the tenant must be writable.
create policy fx_read   on public.exchange_rates for select to authenticated using (app.has_property_access(property_id));
create policy fx_ins    on public.exchange_rates for insert to authenticated
  with check (app.can(property_id, 'setup.fx.manage') and app.tenant_writable(tenant_id));
create policy fx_upd    on public.exchange_rates for update to authenticated
  using (app.can(property_id, 'setup.fx.manage') and app.tenant_writable(tenant_id));

create policy tax_read  on public.tax_rates for select to authenticated using (app.has_property_access(property_id));
create policy tax_ins   on public.tax_rates for insert to authenticated
  with check (app.can(property_id, 'setup.tax.manage') and app.tenant_writable(tenant_id));
create policy tax_upd   on public.tax_rates for update to authenticated
  using (app.can(property_id, 'setup.tax.manage') and app.tenant_writable(tenant_id));
create policy tax_del   on public.tax_rates for delete to authenticated
  using (app.can(property_id, 'setup.tax.manage') and app.tenant_writable(tenant_id));

create policy cc_read   on public.charge_codes for select to authenticated using (app.has_property_access(property_id));
create policy cc_ins    on public.charge_codes for insert to authenticated
  with check (app.can(property_id, 'setup.policy.manage') and app.tenant_writable(tenant_id) and not is_system);
create policy cc_upd    on public.charge_codes for update to authenticated
  using (app.can(property_id, 'setup.policy.manage') and app.tenant_writable(tenant_id) and not is_system);

create policy pm_read   on public.payment_methods for select to authenticated using (app.has_property_access(property_id));
create policy pm_ins    on public.payment_methods for insert to authenticated
  with check (app.can(property_id, 'setup.policy.manage') and app.tenant_writable(tenant_id));
create policy pm_upd    on public.payment_methods for update to authenticated
  using (app.can(property_id, 'setup.policy.manage') and app.tenant_writable(tenant_id));

create policy rt_read   on public.room_types for select to authenticated using (app.has_property_access(property_id));
create policy rt_ins    on public.room_types for insert to authenticated
  with check (app.can(property_id, 'setup.roomtype.manage') and app.tenant_writable(tenant_id));
create policy rt_upd    on public.room_types for update to authenticated
  using (app.can(property_id, 'setup.roomtype.manage') and app.tenant_writable(tenant_id));
create policy rt_del    on public.room_types for delete to authenticated
  using (app.can(property_id, 'setup.roomtype.manage') and app.tenant_writable(tenant_id));

-- Rooms: staff with room.view at level Y see all. Level O (room attendants) see only rooms with a task assigned to them.
-- The HK task table is created later; the predicate is added in the operations migration.
create policy rooms_read_full on public.rooms for select to authenticated
  using (app.grant_level(property_id, 'room.view') = 'Y');
create policy rooms_ins on public.rooms for insert to authenticated
  with check (app.can(property_id, 'setup.room.manage') and app.tenant_writable(tenant_id));
create policy rooms_upd on public.rooms for update to authenticated
  using (app.can(property_id, 'setup.room.manage') and app.tenant_writable(tenant_id));
create policy rooms_del on public.rooms for delete to authenticated
  using (app.can(property_id, 'setup.room.manage') and app.tenant_writable(tenant_id));

create policy rp_read   on public.rate_plans for select to authenticated using (app.has_property_access(property_id));
create policy rp_ins    on public.rate_plans for insert to authenticated
  with check (app.can(property_id, 'setup.rateplan.manage') and app.tenant_writable(tenant_id));
create policy rp_upd    on public.rate_plans for update to authenticated
  using (app.can(property_id, 'setup.rateplan.manage') and app.tenant_writable(tenant_id));

create policy rpp_read  on public.rate_plan_prices for select to authenticated using (app.has_property_access(property_id));
create policy rpp_ins   on public.rate_plan_prices for insert to authenticated
  with check (app.can(property_id, 'setup.rateplan.manage') and app.tenant_writable(tenant_id));
create policy rpp_upd   on public.rate_plan_prices for update to authenticated
  using (app.can(property_id, 'setup.rateplan.manage') and app.tenant_writable(tenant_id));
create policy rpp_del   on public.rate_plan_prices for delete to authenticated
  using (app.can(property_id, 'setup.rateplan.manage') and app.tenant_writable(tenant_id));

-- Audit every change to configuration
do $$
declare t text;
begin
  foreach t in array array['exchange_rates','tax_rates','charge_codes','payment_methods','room_types','rate_plans','rate_plan_prices']
  loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function app.audit_change()', t || '_audit', t);
  end loop;
end $$;

-- Rooms: audit configuration changes only. Condition and occupancy churn is recorded by the engine functions instead.
create trigger rooms_audit after insert or delete or update of room_number, room_type_id, building, floor, status, notes
  on public.rooms for each row execute function app.audit_change();
