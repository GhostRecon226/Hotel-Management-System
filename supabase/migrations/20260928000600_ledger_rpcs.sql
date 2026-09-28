-- HMS 0006: posting functions, approvals, corrections, transfers, invoices.
-- The UI calls these. It never inserts into ledger tables directly (there is no insert policy).

-- ---------------------------------------------------------------- internal helpers
create or replace function app.load_folio(p_folio uuid) returns public.folios
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare f public.folios;
begin
  select * into f from public.folios where id = p_folio;
  if not found then perform app.fail('E_NOT_FOUND', 'Folio not found.'); end if;
  return f;
end $$;

-- Copies a posted row into another folio or as a correction, keeping the original FX rate and base amount.
create or replace function app.insert_copy(
  p_src public.folio_transactions, p_folio uuid, p_kind text, p_sign smallint, p_status text,
  p_reverses uuid, p_parent uuid, p_approval uuid, p_reason text, p_source text, p_reference text default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.folios; p public.properties; v_id uuid;
begin
  select * into f from public.folios where id = p_folio for update;
  select * into p from public.properties where id = f.property_id;
  insert into public.folio_transactions (
    tenant_id, property_id, folio_id, business_date, kind, sign, charge_code_id, payment_method_id, revenue_group,
    description, amount, currency, fx_rate, base_amount, status, reverses_id, parent_id, approval_id, reason, reference,
    source, created_by, posted_at)
  values (
    f.tenant_id, f.property_id, f.id, p.business_date, p_kind, p_sign, p_src.charge_code_id, p_src.payment_method_id,
    p_src.revenue_group, p_src.description, p_src.amount, p_src.currency, p_src.fx_rate, p_src.base_amount, p_status,
    p_reverses, p_parent, p_approval, p_reason, coalesce(p_reference, p_src.reference), p_source, auth.uid(),
    case when p_status = 'posted' then now() end)
  returning id into v_id;
  return v_id;
end $$;

create or replace function app.new_approval(
  p_property uuid, p_kind text, p_table text, p_id uuid, p_amount_base numeric, p_perm text, p_reason text, p_meta jsonb default '{}')
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_tenant uuid := app.property_tenant(p_property);
begin
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  insert into public.approvals (tenant_id, property_id, kind, subject_table, subject_id, amount_base, required_permission,
                                reason, requested_by, meta)
  values (v_tenant, p_property, p_kind, p_table, p_id, p_amount_base, p_perm, p_reason, auth.uid(), coalesce(p_meta, '{}'))
  returning id into v_id;
  perform app.notify_permission(p_property, p_perm, 'approval_requested', 'Approval needed: ' || p_kind,
                                p_reason, 'approvals', v_id);
  return v_id;
end $$;

-- Closes a folio. Used by check-out and by the public close function.
create or replace function app.close_folio(p_folio uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.folios; p public.properties; v_pending int;
begin
  select * into f from public.folios where id = p_folio for update;
  select * into p from public.properties where id = f.property_id;
  select count(*) into v_pending from public.folio_transactions where folio_id = f.id and status = 'pending_approval';
  if v_pending > 0 then
    perform app.fail('E_PENDING_APPROVAL', format('%s posting(s) on this folio are waiting for approval.', v_pending));
  end if;
  update public.folios set status = 'closed', closed_at = now(), closed_by = auth.uid(),
         closed_business_date = p.business_date where id = f.id and status = 'open';
end $$;

-- Invoice or receipt from posted rows. Amounts are in the property base currency.
create or replace function app.issue_invoice(p_folio uuid, p_kind text default 'invoice') returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  f public.folios; p public.properties; g public.guests; v_no text; v_id uuid;
  v_net numeric; v_tax numeric; v_paid numeric; v_lines jsonb;
begin
  select * into f from public.folios where id = p_folio;
  select * into p from public.properties where id = f.property_id;
  if f.guest_id is not null then select * into g from public.guests where id = f.guest_id; end if;
  with x as (
    select t.*, coalesce(o.kind, t.kind) as eff_kind
    from public.folio_transactions t
    left join public.folio_transactions o on o.id = t.reverses_id
      or (t.kind in ('transfer_in','transfer_out') and o.id::text = t.reference)
    where t.folio_id = f.id and t.status = 'posted')
  select coalesce(sum(sign * base_amount) filter (where eff_kind in ('charge','discount','adjustment')), 0),
         coalesce(sum(sign * base_amount) filter (where eff_kind = 'tax'), 0),
         coalesce(-sum(sign * base_amount) filter (where eff_kind in ('payment','deposit','refund')), 0),
         coalesce(jsonb_agg(jsonb_build_object('date', business_date, 'kind', kind, 'description', description,
                  'sign', sign, 'amount', base_amount) order by created_at), '[]')
  into v_net, v_tax, v_paid, v_lines from x;
  v_no := app.next_doc_no(f.property_id, p_kind, case p_kind when 'receipt' then 'RCT' else 'INV' end);
  insert into public.invoices (tenant_id, property_id, folio_id, invoice_no, kind, business_date, currency,
                               net_total, tax_total, total, paid_total, balance_due, lines, guest_snapshot, issued_by)
  values (f.tenant_id, f.property_id, f.id, v_no, p_kind, p.business_date, p.base_currency,
          v_net, v_tax, v_net + v_tax, v_paid, v_net + v_tax - v_paid, v_lines,
          case when g.id is null then '{}'::jsonb else jsonb_build_object(
            'name', g.first_name || ' ' || g.last_name, 'phone', g.phone, 'email', g.email) end,
          auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- Applies the outcome of a decided approval to the thing it was about.
create or replace function app.apply_approval_outcome(a public.approvals, p_approve boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bdate date; v_open int; b public.room_blocks;
begin
  if a.subject_table = 'folio_transactions' then
    select count(*) into v_open from public.folios f
      join public.folio_transactions t on t.folio_id = f.id
     where t.approval_id = a.id and t.status = 'pending_approval' and f.status <> 'open';
    if p_approve and v_open > 0 then
      perform app.fail('E_FOLIO_CLOSED', 'The folio is closed. Reopen it before approving.');
    end if;
    select business_date into v_bdate from public.properties where id = a.property_id;
    if p_approve then
      update public.folio_transactions set status = 'posted', posted_at = now(), business_date = v_bdate
       where approval_id = a.id and status = 'pending_approval';
    else
      update public.folio_transactions set status = 'rejected'
       where approval_id = a.id and status = 'pending_approval';
    end if;
  elsif a.subject_table = 'room_blocks' then
    select * into b from public.room_blocks where id = a.subject_id for update;
    if found and b.status = 'requested' then
      select business_date into v_bdate from public.properties where id = a.property_id;
      if p_approve then
        update public.room_blocks set status = case when lower(block_range) <= v_bdate then 'active' else 'approved' end,
               decided_by = auth.uid(), decided_at = now() where id = b.id;
      else
        update public.room_blocks set status = 'rejected', decided_by = auth.uid(), decided_at = now() where id = b.id;
      end if;
    end if;
  end if;
  -- checkout_unsettled: check_out looks for an approved, unused approval. Nothing to apply here.
end $$;

-- ---------------------------------------------------------------- folios
create or replace function public.split_folio(p_reservation uuid, p_label text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.reservations; f public.folios; p public.properties; v_id uuid; v_stay uuid;
begin
  select * into r from public.reservations where id = p_reservation;
  if not found then perform app.fail('E_NOT_FOUND', 'Reservation not found.'); end if;
  perform app.require(r.property_id, 'fin.folio.split');
  perform app.assert_writable(r.tenant_id);
  if r.status not in ('confirmed','tentative','checked_in') then
    perform app.fail('E_STATE', 'Folios can be added to active reservations only.');
  end if;
  select business_date into p.business_date from public.properties where id = r.property_id;
  select id into v_stay from public.stays where reservation_id = r.id and status = 'in_house';
  insert into public.folios (tenant_id, property_id, folio_no, label, reservation_id, stay_id, guest_id, opened_business_date, created_by)
  values (r.tenant_id, r.property_id, app.next_doc_no(r.property_id, 'folio', 'F'), coalesce(nullif(btrim(p_label), ''), 'Split'),
          r.id, v_stay, r.primary_guest_id, p.business_date, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.reopen_folio(p_folio uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.folios;
begin
  f := app.load_folio(p_folio);
  perform app.require(f.property_id, 'fin.folio.reopen');
  perform app.assert_writable(f.tenant_id, true);
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  if f.status <> 'closed' then perform app.fail('E_STATE', 'Only a closed folio can be reopened.'); end if;
  update public.folios set status = 'open', closed_at = null, closed_by = null, closed_business_date = null where id = f.id;
  perform app.audit(f.tenant_id, f.property_id, 'folio.reopen', 'folios', f.id, null, null, p_reason, null);
end $$;

create or replace function public.close_folio(p_folio uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.folios; v_bal numeric;
begin
  f := app.load_folio(p_folio);
  perform app.require(f.property_id, 'fin.folio.view');
  perform app.require(f.property_id, 'fin.invoice.issue');
  perform app.assert_writable(f.tenant_id, true);
  select balance into v_bal from public.v_folio_balances where folio_id = f.id;
  if v_bal <> 0 then perform app.fail('E_BALANCE', 'Only a folio with a zero balance can be closed.'); end if;
  perform app.close_folio(f.id);
end $$;

-- ---------------------------------------------------------------- charges and payments
create or replace function public.post_charge(
  p_folio uuid, p_charge_code uuid, p_amount numeric, p_currency text, p_description text,
  p_tax_inclusive boolean default false, p_idempotency_key text default null, p_reference text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.folios;
begin
  f := app.load_folio(p_folio);
  perform app.require(f.property_id, 'fin.charge.post');
  perform app.assert_writable(f.tenant_id);
  return app.insert_with_tax(f.id, 'charge', 1::smallint, p_charge_code, p_amount, p_currency,
           coalesce(nullif(btrim(p_description), ''), 'Charge'), p_tax_inclusive, 'posted', null, null,
           p_reference, 'manual', p_idempotency_key);
end $$;

create or replace function public.post_payment(
  p_folio uuid, p_method uuid, p_amount numeric, p_currency text,
  p_reference text default null, p_is_deposit boolean default false, p_idempotency_key text default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.folios; pm public.payment_methods;
begin
  f := app.load_folio(p_folio);
  perform app.require(f.property_id, case when p_is_deposit then 'fin.deposit.take' else 'fin.payment.post' end);
  -- settlement is always allowed, even when the account is read-only
  perform app.assert_writable(f.tenant_id, true);
  select * into pm from public.payment_methods where id = p_method and property_id = f.property_id and active;
  if not found then perform app.fail('E_PAYMENT_METHOD', 'Payment method not found or inactive.'); end if;
  return app.insert_txn(f.id, case when p_is_deposit then 'deposit' else 'payment' end, -1::smallint, p_amount, p_currency,
           pm.name || case when p_is_deposit then ' deposit' else ' payment' end, 'posted', null, p_method, null,
           null, null, null, null, p_reference, 'manual', p_idempotency_key);
end $$;

-- A discount within the caller's limit posts at once. Above the limit it waits for an approver.
create or replace function public.apply_discount(
  p_folio uuid, p_charge_code uuid, p_amount numeric, p_currency text, p_reason text,
  p_tax_inclusive boolean default false, p_idempotency_key text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  f public.folios; p public.properties; v_limit numeric; v_base numeric; v_pending boolean; v_appr uuid; v_res jsonb;
begin
  f := app.load_folio(p_folio);
  perform app.require(f.property_id, 'fin.discount.apply');
  perform app.assert_writable(f.tenant_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required for a discount.'); end if;
  select * into p from public.properties where id = f.property_id;
  v_base := round(p_amount * app.fx_rate(p.id, p_currency, p.business_date), app.currency_decimals(p.base_currency));
  v_limit := app.approval_limit(f.property_id, 'fin.discount.apply');   -- null means unlimited
  v_pending := v_limit is not null and v_base > v_limit;
  if v_pending then
    v_appr := app.new_approval(f.property_id, 'discount', 'folio_transactions', null, v_base, 'fin.discount.approve', p_reason);
  end if;
  v_res := app.insert_with_tax(f.id, 'discount', -1::smallint, p_charge_code, p_amount, p_currency, 'Discount: ' || p_reason,
             p_tax_inclusive, case when v_pending then 'pending_approval' else 'posted' end, v_appr, p_reason,
             null, 'manual', p_idempotency_key);
  if v_pending then
    update public.approvals set subject_id = (v_res -> 'ids' ->> 0)::uuid where id = v_appr;
  end if;
  return v_res || jsonb_build_object('pending', v_pending, 'approval_id', v_appr);
end $$;

-- Adjustments, reversals and refunds always need a second person.
create or replace function public.request_adjustment(
  p_folio uuid, p_direction text, p_amount numeric, p_currency text, p_description text, p_reason text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.folios; p public.properties; v_base numeric; v_appr uuid; v_txn uuid;
begin
  f := app.load_folio(p_folio);
  perform app.require(f.property_id, 'fin.adjust.post');
  perform app.assert_writable(f.tenant_id);
  if p_direction not in ('increase','decrease') then perform app.fail('E_ARG', 'Direction must be increase or decrease.'); end if;
  select * into p from public.properties where id = f.property_id;
  v_base := round(p_amount * app.fx_rate(p.id, p_currency, p.business_date), app.currency_decimals(p.base_currency));
  v_appr := app.new_approval(f.property_id, 'adjustment', 'folio_transactions', null, v_base, 'fin.adjust.approve', p_reason);
  v_txn := app.insert_txn(f.id, 'adjustment', case when p_direction = 'increase' then 1 else -1 end::smallint, p_amount, p_currency,
             coalesce(nullif(btrim(p_description), ''), 'Adjustment'), 'pending_approval', null, null, null, null, null,
             v_appr, p_reason, null, 'manual', null);
  update public.approvals set subject_id = v_txn where id = v_appr;
  perform app.audit(f.tenant_id, f.property_id, 'fin.adjust.request', 'folio_transactions', v_txn, null, null, p_reason, null);
  return v_appr;
end $$;

create or replace function public.request_reversal(p_txn uuid, p_reason text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  t public.folio_transactions; c public.folio_transactions; v_appr uuid; v_base numeric; v_root uuid; v_child uuid;
begin
  select * into t from public.folio_transactions where id = p_txn;
  if not found then perform app.fail('E_NOT_FOUND', 'Transaction not found.'); end if;
  perform app.require(t.property_id, 'fin.reverse.post');
  perform app.assert_writable(t.tenant_id);
  if t.status <> 'posted' then perform app.fail('E_STATE', 'Only posted transactions can be reversed.'); end if;
  if t.kind = 'reversal' then perform app.fail('E_STATE', 'A reversal cannot be reversed. Post the charge again instead.'); end if;
  if t.kind in ('transfer_in','transfer_out') then perform app.fail('E_STATE', 'Move the charge back with a transfer instead.'); end if;
  if t.kind = 'tax' then perform app.fail('E_STATE', 'Reverse the charge. Its tax lines follow.'); end if;
  if exists (select 1 from public.folio_transactions where reverses_id = t.id and status <> 'rejected') then
    perform app.fail('E_ALREADY_REVERSED', 'This transaction is already reversed or a reversal is waiting for approval.');
  end if;
  if exists (select 1 from public.folio_transactions x where x.kind = 'transfer_out' and x.reference = t.id::text and x.status = 'posted') then
    perform app.fail('E_STATE', 'This charge was transferred to another folio. Move it back first.');
  end if;
  if (select status from public.folios where id = t.folio_id) <> 'open' then
    perform app.fail('E_FOLIO_CLOSED', 'This folio is closed. Reopen it before posting.');
  end if;
  select coalesce(t.base_amount, 0) + coalesce(sum(base_amount), 0) into v_base
    from public.folio_transactions where parent_id = t.id and kind = 'tax';
  v_appr := app.new_approval(t.property_id, 'reversal', 'folio_transactions', null, v_base, 'fin.adjust.approve', p_reason);
  v_root := app.insert_copy(t, t.folio_id, 'reversal', (-t.sign)::smallint, 'pending_approval', t.id, null, v_appr,
                            p_reason, 'manual');
  for c in select * from public.folio_transactions where parent_id = t.id and kind = 'tax' and status = 'posted' loop
    v_child := app.insert_copy(c, c.folio_id, 'reversal', (-c.sign)::smallint, 'pending_approval', c.id, v_root, v_appr,
                               p_reason, 'manual');
  end loop;
  update public.approvals set subject_id = v_root where id = v_appr;
  perform app.audit(t.tenant_id, t.property_id, 'fin.reverse.request', 'folio_transactions', t.id, null, null, p_reason, null);
  return v_appr;
end $$;

create or replace function public.request_refund(
  p_folio uuid, p_method uuid, p_amount numeric, p_currency text, p_reason text, p_reference text default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  f public.folios; p public.properties; v_base numeric; v_credit numeric; v_pending numeric; v_appr uuid; v_txn uuid;
begin
  f := app.load_folio(p_folio);
  perform app.require(f.property_id, 'fin.refund.post');
  perform app.assert_writable(f.tenant_id, true);
  select * into p from public.properties where id = f.property_id;
  v_base := round(p_amount * app.fx_rate(p.id, p_currency, p.business_date), app.currency_decimals(p.base_currency));
  select -balance into v_credit from public.v_folio_balances where folio_id = f.id;
  select coalesce(sum(base_amount), 0) into v_pending from public.folio_transactions
   where folio_id = f.id and kind = 'refund' and status = 'pending_approval';
  if v_base > coalesce(v_credit, 0) - v_pending then
    perform app.fail('E_REFUND_LIMIT', 'A refund cannot exceed the credit balance on the folio.');
  end if;
  if not exists (select 1 from public.payment_methods where id = p_method and property_id = f.property_id and active) then
    perform app.fail('E_PAYMENT_METHOD', 'Payment method not found or inactive.');
  end if;
  v_appr := app.new_approval(f.property_id, 'refund', 'folio_transactions', null, v_base, 'fin.refund.approve', p_reason);
  v_txn := app.insert_txn(f.id, 'refund', 1::smallint, p_amount, p_currency, 'Refund', 'pending_approval', null, p_method, null,
             null, null, v_appr, p_reason, p_reference, 'manual', null);
  update public.approvals set subject_id = v_txn where id = v_appr;
  perform app.audit(f.tenant_id, f.property_id, 'fin.refund.request', 'folio_transactions', v_txn, null, null, p_reason, null);
  return v_appr;
end $$;

-- ---------------------------------------------------------------- approvals
create or replace function public.decide_approval(p_approval uuid, p_approve boolean, p_reason text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.approvals; v_limit numeric;
begin
  select * into a from public.approvals where id = p_approval for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Approval not found.'); end if;
  perform app.require(a.property_id, a.required_permission);
  perform app.assert_writable(a.tenant_id, a.kind in ('refund','checkout_unsettled'));
  if a.status <> 'pending' then perform app.fail('E_STATE', format('This request is already %s.', a.status)); end if;
  if a.requested_by = auth.uid() then
    perform app.fail('E_SOD', 'You cannot approve your own request. Ask another approver.');
  end if;
  if not p_approve and coalesce(btrim(p_reason), '') = '' then
    perform app.fail('E_REASON', 'A reason is required to reject.');
  end if;
  if p_approve and a.amount_base is not null and a.kind in ('discount','adjustment','refund','reversal') then
    v_limit := app.approval_limit(a.property_id, a.required_permission);
    if v_limit is not null and a.amount_base > v_limit then
      perform app.fail('E_LIMIT', 'This amount is above your approval limit. Ask a senior approver.');
    end if;
  end if;
  update public.approvals set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now(), decision_reason = p_reason where id = a.id;
  perform app.apply_approval_outcome(a, p_approve);
  perform app.audit(a.tenant_id, a.property_id, case when p_approve then 'approval.approve' else 'approval.reject' end,
                    'approvals', a.id, null, jsonb_build_object('kind', a.kind, 'amount_base', a.amount_base), p_reason, null);
  perform app.notify_user(a.requested_by, a.property_id, 'approval_decided',
                          case when p_approve then 'Approved: ' else 'Rejected: ' end || a.kind,
                          coalesce(p_reason, a.reason), 'approvals', a.id);
end $$;

create or replace function public.withdraw_approval(p_approval uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.approvals;
begin
  select * into a from public.approvals where id = p_approval for update;
  if not found then perform app.fail('E_NOT_FOUND', 'Approval not found.'); end if;
  if a.requested_by <> auth.uid() then perform app.fail('E_PERM', 'Only the requester can withdraw a request.'); end if;
  if a.status <> 'pending' then perform app.fail('E_STATE', format('This request is already %s.', a.status)); end if;
  update public.approvals set status = 'withdrawn', decided_at = now() where id = a.id;
  update public.folio_transactions set status = 'rejected' where approval_id = a.id and status = 'pending_approval';
  update public.room_blocks set status = 'cancelled' where id = a.subject_id and a.subject_table = 'room_blocks' and status = 'requested';
end $$;

-- ---------------------------------------------------------------- transfers
-- Moves a posted charge and its tax lines to another folio of the same property.
-- Revenue does not change. The source folio gets transfer_out rows, the target gets transfer_in rows.
create or replace function public.transfer_transaction(p_txn uuid, p_to_folio uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t public.folio_transactions; c public.folio_transactions; dst public.folios; src public.folios;
begin
  select * into t from public.folio_transactions where id = p_txn;
  if not found then perform app.fail('E_NOT_FOUND', 'Transaction not found.'); end if;
  perform app.require(t.property_id, 'fin.folio.transfer');
  perform app.assert_writable(t.tenant_id);
  if coalesce(btrim(p_reason), '') = '' then perform app.fail('E_REASON', 'A reason is required.'); end if;
  if t.kind <> 'charge' or t.status <> 'posted' then perform app.fail('E_STATE', 'Only posted charges can be transferred.'); end if;
  if exists (select 1 from public.folio_transactions where reverses_id = t.id and status <> 'rejected') then
    perform app.fail('E_STATE', 'This charge is reversed.');
  end if;
  if exists (select 1 from public.folio_transactions x where x.kind = 'transfer_out' and x.reference = t.id::text and x.status = 'posted') then
    perform app.fail('E_STATE', 'This charge was already transferred.');
  end if;
  select * into src from public.folios where id = t.folio_id for update;
  select * into dst from public.folios where id = p_to_folio for update;
  if dst.id is null or dst.property_id <> t.property_id then perform app.fail('E_NOT_FOUND', 'Target folio not found.'); end if;
  if dst.id = src.id then perform app.fail('E_ARG', 'Choose a different folio.'); end if;
  if src.status <> 'open' or dst.status <> 'open' then perform app.fail('E_FOLIO_CLOSED', 'Both folios must be open.'); end if;
  for c in select * from public.folio_transactions
            where id = t.id or (parent_id = t.id and kind = 'tax' and status = 'posted') loop
    -- reference points at the row that was moved, so invoices can still tell a tax line from a charge
    perform app.insert_copy(c, src.id, 'transfer_out', -1::smallint, 'posted', null, null, null, p_reason, 'transfer', c.id::text);
    perform app.insert_copy(c, dst.id, 'transfer_in', 1::smallint, 'posted', null, null, null, p_reason, 'transfer', c.id::text);
  end loop;
  perform app.audit(t.tenant_id, t.property_id, 'fin.transfer', 'folio_transactions', t.id, null,
                    jsonb_build_object('to_folio', dst.id), p_reason, null);
end $$;

-- ---------------------------------------------------------------- invoices
create or replace function public.issue_invoice(p_folio uuid, p_kind text default 'invoice')
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.folios;
begin
  f := app.load_folio(p_folio);
  perform app.require(f.property_id, 'fin.invoice.issue');
  perform app.assert_writable(f.tenant_id, true);
  if p_kind not in ('invoice','receipt') then perform app.fail('E_ARG', 'Kind must be invoice or receipt.'); end if;
  return app.issue_invoice(f.id, p_kind);
end $$;
