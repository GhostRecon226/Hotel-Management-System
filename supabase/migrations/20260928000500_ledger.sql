-- HMS 0005: folios and the ledger.
-- Rules enforced in the database, not in the UI:
--   * a posted transaction can never be edited or deleted, by anyone
--   * corrections are new rows linked to the original (reversal, adjustment, refund)
--   * balances are calculated from posted rows, never stored
--   * the person who approves cannot be the person who asked (BR-015, separation of duties)
--   * postings use the property's open business date

create table public.folios (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null,
  property_id        uuid not null,
  folio_no           text not null,
  label              text not null default 'Guest',
  reservation_id     uuid,
  stay_id            uuid,
  guest_id           uuid,
  status             text not null default 'open' check (status in ('open','closed','void')),
  opened_business_date date not null,
  closed_business_date date,
  opened_at          timestamptz not null default now(),
  closed_at          timestamptz,
  closed_by          uuid,
  created_by         uuid,
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (property_id, reservation_id) references public.reservations (property_id, id),
  foreign key (property_id, stay_id) references public.stays (property_id, id),
  foreign key (tenant_id, guest_id) references public.guests (tenant_id, id),
  unique (property_id, id),
  unique (property_id, folio_no)
);
create index on public.folios (property_id, reservation_id);
create index on public.folios (property_id, stay_id);
create index on public.folios (property_id, status);

create table public.approvals (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null,
  property_id         uuid not null,
  kind                text not null check (kind in
                        ('discount','adjustment','refund','reversal','checkout_unsettled','room_block','other')),
  subject_table       text,
  subject_id          uuid,
  status              text not null default 'pending' check (status in ('pending','approved','rejected','expired','withdrawn')),
  amount_base         numeric(20,4),
  required_permission text not null references public.permissions(key),
  reason              text not null,
  requested_by        uuid not null,
  requested_at        timestamptz not null default now(),
  decided_by          uuid,
  decided_at          timestamptz,
  decision_reason     text,
  expires_at          timestamptz,
  meta                jsonb not null default '{}',
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  -- separation of duties, enforced by the database
  constraint approver_is_not_requester check (decided_by is null or decided_by <> requested_by),
  constraint decision_complete check ((status = 'pending') = (decided_by is null and decided_at is null) or status in ('expired','withdrawn'))
);
create index on public.approvals (property_id, status);
create index on public.approvals (subject_table, subject_id);

create table public.folio_transactions (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null,
  property_id      uuid not null,
  folio_id         uuid not null,
  business_date    date not null,
  kind             text not null check (kind in
                     ('charge','tax','discount','payment','deposit','refund','adjustment','transfer_in','transfer_out','reversal')),
  sign             smallint not null check (sign in (1, -1)),   -- +1 raises what the guest owes, -1 lowers it
  charge_code_id   uuid,
  payment_method_id uuid,
  revenue_group    text check (revenue_group in ('room','fnb','other','fee')),   -- null for tax, payments, transfers
  description      text not null,
  amount           numeric(20,4) not null check (amount > 0),   -- always positive, in transaction currency
  currency         text not null references public.currencies(code),
  fx_rate          numeric(20,8) not null check (fx_rate > 0),
  base_amount      numeric(20,4) not null check (base_amount >= 0),   -- in property base currency
  status           text not null check (status in ('pending_approval','posted','rejected')),
  reverses_id      uuid references public.folio_transactions(id),
  parent_id        uuid references public.folio_transactions(id),   -- tax lines point at their charge
  approval_id      uuid references public.approvals(id),
  reason           text,
  reference        text,
  source           text not null default 'manual',   -- manual, room_charge_roll, no_show_fee, cancellation_fee, service_request, transfer
  idempotency_key  text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  posted_at        timestamptz,
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (property_id, folio_id) references public.folios (property_id, id),
  foreign key (property_id, charge_code_id) references public.charge_codes (property_id, id),
  foreign key (property_id, payment_method_id) references public.payment_methods (property_id, id),
  constraint sign_matches_kind check (
       (kind = 'charge' and sign = 1)
    or (kind in ('discount','payment','deposit') and sign = -1)
    or (kind = 'refund' and sign = 1)
    or kind in ('tax','adjustment','reversal','transfer_in','transfer_out')),
  constraint revenue_kinds_have_group check (kind not in ('charge','discount') or revenue_group is not null),
  constraint payment_kinds_have_method check (kind not in ('payment','deposit','refund') or payment_method_id is not null),
  constraint posted_has_timestamp check (status <> 'posted' or posted_at is not null)
);
create index on public.folio_transactions (folio_id, status);
create index on public.folio_transactions (property_id, business_date);
create unique index txn_idempotency on public.folio_transactions (tenant_id, idempotency_key) where idempotency_key is not null;
-- A transaction can be reversed once. A rejected reversal does not block a new attempt.
create unique index txn_reversed_once on public.folio_transactions (reverses_id)
  where reverses_id is not null and status <> 'rejected' and kind = 'reversal';

create table public.invoices (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null,
  property_id   uuid not null,
  folio_id      uuid not null,
  invoice_no    text not null,
  kind          text not null check (kind in ('invoice','receipt')),
  business_date date not null,
  currency      text not null,
  net_total     numeric(20,4) not null,
  tax_total     numeric(20,4) not null,
  total         numeric(20,4) not null,
  paid_total    numeric(20,4) not null,
  balance_due   numeric(20,4) not null,
  lines         jsonb not null,
  guest_snapshot jsonb not null default '{}',
  issued_by     uuid,
  issued_at     timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (property_id, folio_id) references public.folios (property_id, id),
  unique (property_id, invoice_no)
);

-- ---------------------------------------------------------------- immutability
create or replace function app.txn_guard() returns trigger language plpgsql as $$
declare v_folio_status text; v_bdate date;
begin
  if tg_op = 'INSERT' then
    select status into v_folio_status from public.folios where id = new.folio_id;
    if v_folio_status is distinct from 'open' then
      perform app.fail('E_FOLIO_CLOSED', 'This folio is not open. Reopen it before posting.');
    end if;
    if new.status = 'posted' then
      select business_date into v_bdate from public.properties where id = new.property_id;
      if new.business_date <> v_bdate then
        perform app.fail('E_DATE', format('Transactions post to the open business date (%s).', v_bdate));
      end if;
    end if;
    return new;
  elsif tg_op = 'UPDATE' then
    -- The only allowed change: a pending row becomes posted or rejected, and takes the open business date.
    if old.status = 'pending_approval' and new.status in ('posted','rejected')
       and (to_jsonb(new) - 'status' - 'posted_at' - 'business_date')
         = (to_jsonb(old) - 'status' - 'posted_at' - 'business_date') then
      if new.status = 'posted' then
        select business_date into v_bdate from public.properties where id = new.property_id;
        if new.business_date <> v_bdate then
          perform app.fail('E_DATE', format('Transactions post to the open business date (%s).', v_bdate));
        end if;
      end if;
      return new;
    end if;
    perform app.fail('E_IMMUTABLE', 'Posted transactions cannot be changed. Use a reversal, adjustment or refund.');
  end if;
  perform app.fail('E_IMMUTABLE', 'Transactions cannot be deleted. Use a reversal.');
  return null;
end $$;

create trigger txn_guard_ins before insert on public.folio_transactions
  for each row execute function app.txn_guard();
create trigger txn_guard_upd before update on public.folio_transactions
  for each row execute function app.txn_guard();
create trigger txn_guard_del before delete on public.folio_transactions
  for each row execute function app.block_mutation();
create trigger txn_no_truncate before truncate on public.folio_transactions
  for each statement execute function app.block_mutation();

create trigger invoices_immutable before update or delete on public.invoices
  for each row execute function app.block_mutation();
create trigger invoices_no_truncate before truncate on public.invoices
  for each statement execute function app.block_mutation();

-- Folios: only status fields may change. Identity of the folio never changes.
create or replace function app.folio_guard() returns trigger language plpgsql as $$
begin
  -- guest_id may change only when two guest records are merged
  if (to_jsonb(new) - 'status' - 'closed_at' - 'closed_by' - 'closed_business_date' - 'label' - 'stay_id' - 'guest_id')
   <> (to_jsonb(old) - 'status' - 'closed_at' - 'closed_by' - 'closed_business_date' - 'label' - 'stay_id' - 'guest_id') then
    perform app.fail('E_IMMUTABLE', 'Folio identity cannot be changed.');
  end if;
  if old.status = 'void' then perform app.fail('E_STATE', 'A void folio cannot be changed.'); end if;
  return new;
end $$;
create trigger folio_guard_upd before update on public.folios for each row execute function app.folio_guard();
create trigger folio_no_delete before delete on public.folios for each row execute function app.block_mutation();

-- ---------------------------------------------------------------- balances (derived, never stored)
create view public.v_folio_balances with (security_invoker = true) as
select f.id as folio_id, f.property_id, f.status, f.reservation_id, f.stay_id, f.label,
       coalesce(sum(t.sign * t.base_amount) filter (where t.status = 'posted'), 0) as balance,
       coalesce(sum(t.base_amount) filter (where t.status = 'posted' and t.sign = 1), 0) as total_debits,
       coalesce(sum(t.base_amount) filter (where t.status = 'posted' and t.sign = -1), 0) as total_credits,
       coalesce(sum(t.base_amount) filter (where t.status = 'posted' and t.kind in ('payment','deposit')), 0) as total_paid,
       count(*) filter (where t.status = 'pending_approval') as pending_count,
       case
         when coalesce(sum(t.sign * t.base_amount) filter (where t.status = 'posted'), 0) < 0 then 'credit'
         when coalesce(sum(t.sign * t.base_amount) filter (where t.status = 'posted'), 0) = 0 then 'settled'
         when coalesce(sum(t.base_amount) filter (where t.status = 'posted' and t.kind in ('payment','deposit')), 0) > 0 then 'part_paid'
         else 'unsettled' end as settlement_status
from public.folios f
left join public.folio_transactions t on t.folio_id = f.id
group by f.id;

-- Derived "Reversed" state: a posted or pending reversal exists for the row.
create view public.v_transactions with (security_invoker = true) as
select t.*, exists (select 1 from public.folio_transactions r
                    where r.reverses_id = t.id and r.status <> 'rejected') as is_reversed
from public.folio_transactions t;

-- ---------------------------------------------------------------- tax calculation
-- Returns {"net": n, "taxes": [{"tax_rate_id","name","amount"}...]} in the transaction currency.
-- Exclusive: taxes are added on top of p_amount. Inclusive: p_amount already contains the taxes,
-- the net is solved and any rounding remainder goes on the last tax line so the total is exact.
create or replace function app.compute_taxes(
  p_property uuid, p_revenue_group text, p_taxable boolean, p_amount numeric, p_currency text, p_date date, p_inclusive boolean)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_dec int := coalesce(app.currency_decimals(p_currency), 2);
  v_net numeric; v_prior numeric; v_tax numeric; v_k numeric; v_diff numeric;
  v_rates public.tax_rates[]; r public.tax_rates;
  v_out jsonb := '[]'::jsonb; v_sum numeric := 0; v_n int; i int := 0;
begin
  if not p_taxable then return jsonb_build_object('net', p_amount, 'taxes', '[]'::jsonb); end if;
  select coalesce(array_agg(tr order by tr.seq, tr.code), '{}') into v_rates
  from public.tax_rates tr
  where tr.property_id = p_property and tr.active and tr.effective_from <= p_date
    and (tr.effective_to is null or tr.effective_to >= p_date)
    and p_revenue_group = any (tr.applies_to);
  v_n := coalesce(array_length(v_rates, 1), 0);
  if v_n = 0 then return jsonb_build_object('net', p_amount, 'taxes', '[]'::jsonb); end if;

  if p_inclusive then
    -- factor k such that gross = net * k, using an unrounded net of 1
    v_k := 1; v_prior := 0;
    foreach r in array v_rates loop
      v_tax := (case r.calc_base when 'net' then 1 else 1 + v_prior end) * r.rate / 100;
      v_prior := v_prior + v_tax; v_k := v_k + v_tax;
    end loop;
    v_net := round(p_amount / v_k, v_dec);
  else
    v_net := p_amount;
  end if;

  v_prior := 0;
  foreach r in array v_rates loop
    i := i + 1;
    v_tax := round((case r.calc_base when 'net' then v_net else v_net + v_prior end) * r.rate / 100, v_dec);
    v_prior := v_prior + v_tax; v_sum := v_sum + v_tax;
    v_out := v_out || jsonb_build_object('tax_rate_id', r.id, 'name', r.name, 'amount', v_tax);
  end loop;

  if p_inclusive then
    v_diff := p_amount - (v_net + v_sum);
    if v_diff <> 0 then
      -- put the rounding remainder on the last tax line
      v_out := jsonb_set(v_out, array[(v_n - 1)::text, 'amount'],
                         to_jsonb((v_out -> (v_n - 1) ->> 'amount')::numeric + v_diff));
    end if;
  end if;
  return jsonb_build_object('net', v_net, 'taxes', v_out);
end $$;

-- ---------------------------------------------------------------- core insert
-- The one place a transaction row is created. Called by the public posting functions and by system jobs.
create or replace function app.insert_txn(
  p_folio uuid, p_kind text, p_sign smallint, p_amount numeric, p_currency text,
  p_description text, p_status text default 'posted',
  p_charge_code uuid default null, p_payment_method uuid default null, p_revenue_group text default null,
  p_reverses uuid default null, p_parent uuid default null, p_approval uuid default null,
  p_reason text default null, p_reference text default null, p_source text default 'manual',
  p_idempotency_key text default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  f public.folios; p public.properties; v_dec int; v_base_dec int; v_fx numeric; v_id uuid; v_base numeric;
begin
  select * into f from public.folios where id = p_folio for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Folio not found.'); end if;
  select * into p from public.properties where id = f.property_id;

  if p_idempotency_key is not null then
    select id into v_id from public.folio_transactions where tenant_id = f.tenant_id and idempotency_key = p_idempotency_key;
    if found then return v_id; end if;
  end if;

  v_dec := app.currency_decimals(p_currency);
  if v_dec is null then perform app.fail('E_CURRENCY', format('Unknown currency %s.', p_currency)); end if;
  if p_amount <= 0 then perform app.fail('E_AMOUNT', 'Amount must be greater than zero.'); end if;
  if p_amount <> round(p_amount, v_dec) then
    perform app.fail('E_PRECISION', format('%s allows %s decimal places.', p_currency, v_dec));
  end if;
  v_base_dec := app.currency_decimals(p.base_currency);
  v_fx := app.fx_rate(p.id, p_currency, p.business_date);
  v_base := round(p_amount * v_fx, v_base_dec);

  insert into public.folio_transactions (
    tenant_id, property_id, folio_id, business_date, kind, sign, charge_code_id, payment_method_id, revenue_group,
    description, amount, currency, fx_rate, base_amount, status, reverses_id, parent_id, approval_id, reason, reference,
    source, idempotency_key, created_by, posted_at)
  values (
    f.tenant_id, f.property_id, f.id, p.business_date, p_kind, p_sign, p_charge_code, p_payment_method, p_revenue_group,
    p_description, p_amount, p_currency, v_fx, v_base, p_status, p_reverses, p_parent, p_approval, p_reason, p_reference,
    p_source, p_idempotency_key, auth.uid(), case when p_status = 'posted' then now() end)
  returning id into v_id;
  return v_id;
end $$;

-- Posts a charge or discount together with its tax lines. Returns the ids created.
-- p_sign = 1 for a charge, -1 for a discount. Tax lines carry the same sign as the parent.
create or replace function app.insert_with_tax(
  p_folio uuid, p_kind text, p_sign smallint, p_charge_code uuid, p_amount numeric, p_currency text,
  p_description text, p_inclusive boolean, p_status text, p_approval uuid, p_reason text,
  p_reference text, p_source text, p_idempotency_key text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  f public.folios; p public.properties; cc public.charge_codes; v_calc jsonb; v_id uuid; v_ids uuid[] := '{}'; v_t jsonb;
begin
  select * into f from public.folios where id = p_folio;
  select * into p from public.properties where id = f.property_id;
  select * into cc from public.charge_codes where id = p_charge_code and property_id = f.property_id;
  if not found then perform app.fail('E_CHARGE_CODE', 'Charge code not found for this property.'); end if;
  if not cc.active then perform app.fail('E_CHARGE_CODE', 'This charge code is inactive.'); end if;

  if p_idempotency_key is not null then
    select id into v_id from public.folio_transactions where tenant_id = f.tenant_id and idempotency_key = p_idempotency_key;
    if found then
      return jsonb_build_object('ids', (select coalesce(jsonb_agg(id), '[]') from public.folio_transactions
                                          where id = v_id or parent_id = v_id), 'duplicate', true);
    end if;
  end if;

  v_calc := app.compute_taxes(f.property_id, cc.revenue_group, cc.taxable, p_amount, p_currency, p.business_date, p_inclusive);
  v_id := app.insert_txn(p_folio, p_kind, p_sign, (v_calc ->> 'net')::numeric, p_currency, p_description, p_status,
                         p_charge_code, null, cc.revenue_group, null, null, p_approval, p_reason, p_reference, p_source, p_idempotency_key);
  v_ids := v_ids || v_id;
  for v_t in select * from jsonb_array_elements(v_calc -> 'taxes') loop
    if (v_t ->> 'amount')::numeric > 0 then
      v_ids := v_ids || app.insert_txn(p_folio, 'tax', p_sign, (v_t ->> 'amount')::numeric, p_currency, v_t ->> 'name', p_status,
                                       null, null, null, null, v_id, p_approval, p_reason, p_reference, p_source, null);
    end if;
  end loop;
  return jsonb_build_object('ids', to_jsonb(v_ids), 'net', (v_calc ->> 'net')::numeric, 'duplicate', false);
end $$;

-- ---------------------------------------------------------------- visibility helper and RLS
create or replace function app.can_see_folio(p_property uuid, p_reservation uuid) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v text;
begin
  v := app.grant_level(p_property, 'fin.folio.view');
  if v = 'Y' then return true; end if;
  if v = 'O' then
    return exists (select 1 from public.reservations r where r.id = p_reservation and r.created_by = auth.uid());
  end if;
  return false;
end $$;

alter table public.folios             enable row level security;
alter table public.folio_transactions enable row level security;
alter table public.approvals          enable row level security;
alter table public.invoices           enable row level security;

create policy folios_read on public.folios for select to authenticated
  using (app.can_see_folio(property_id, reservation_id));
create policy txn_read on public.folio_transactions for select to authenticated
  using (exists (select 1 from public.folios f where f.id = folio_id and app.can_see_folio(f.property_id, f.reservation_id)));
create policy invoices_read on public.invoices for select to authenticated
  using (exists (select 1 from public.folios f where f.id = folio_id and app.can_see_folio(f.property_id, f.reservation_id)));
create policy approvals_read on public.approvals for select to authenticated
  using (requested_by = auth.uid() or app.can(property_id, required_permission));
-- No insert, update or delete policies on any of these four tables. Every change goes through a function.
