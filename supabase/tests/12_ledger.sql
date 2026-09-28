-- Ledger: postings, tax, immutability, approvals, corrections, transfers, currency.
create function t.bal(p_folio uuid) returns numeric language sql stable as $$
  select balance from public.v_folio_balances where folio_id = p_folio $$;
create function t.folio(p_res uuid) returns uuid language sql stable as $$
  select id from public.folios where reservation_id = p_res order by opened_at limit 1 $$;
grant execute on all functions in schema t to authenticated;

do $$
declare
  v_res uuid; f uuid; f2 uuid; r jsonb; a uuid; tx uuid; v_n int; v_dup jsonb;
begin
  perform t.login('fdo');
  v_res := public.create_reservation(t.id('propA'), t.id('g2'), t.bdate() + 20, t.bdate() + 22, t.id('std'), t.id('bar'));
  f := t.folio(v_res);
  perform t.admin(); insert into t.ids values ('resLedger', v_res), ('folioL', f); perform t.login('fdo');

  -- tax: 10% service charge, then 7.5% VAT on price plus service charge
  r := public.post_charge(f, t.cc('MISC'), 10000, 'NGN', 'Laundry');
  perform t.eq(jsonb_array_length(r -> 'ids'), 3, 'charge creates the charge and two tax lines');
  perform t.eq(t.bal(f), 11825.00, 'exclusive charge: 10,000 + 1,000 service + 825 VAT');

  r := public.post_charge(f, t.cc('MISC'), 11825, 'NGN', 'Inclusive item', true);
  perform t.eq((r ->> 'net')::numeric, 10000.00, 'inclusive price solves back to a net of 10,000');
  perform t.eq(t.bal(f), 23650.00, 'balance after inclusive charge');

  -- idempotency
  r := public.post_charge(f, t.cc('MISC'), 500, 'NGN', 'Snack', false, 'key-1');
  v_dup := public.post_charge(f, t.cc('MISC'), 500, 'NGN', 'Snack', false, 'key-1');
  perform t.eq((v_dup ->> 'duplicate')::boolean, true, 'same idempotency key does not post twice');
  perform t.eq(t.bal(f), 23650.00 + 591.25, 'duplicate did not change the balance');

  perform t.raises(format('select public.post_charge(%L, %L, 100.555, ''NGN'', ''x'')', f, t.cc('MISC')), 'E_PRECISION', 'NGN allows two decimals');
  perform t.raises(format('select public.post_charge(%L, %L, -5, ''NGN'', ''x'')', f, t.cc('MISC')), 'E_AMOUNT', 'negative amount refused');
  perform t.raises(format('select public.post_charge(%L, %L, 100, ''EUR'', ''x'')', f, t.cc('MISC')), 'E_NO_RATE', 'foreign currency without a rate is refused');

  -- permissions
  perform t.login('hks');
  perform t.raises(format('select public.post_charge(%L, %L, 100, ''NGN'', ''x'')', f, t.cc('MISC')), 'E_PERM', 'housekeeping cannot post charges');
  perform t.raises(format('insert into public.folio_transactions (tenant_id, property_id, folio_id, business_date, kind, sign, description, amount, currency, fx_rate, base_amount, status) values (%L,%L,%L,current_date,''charge'',1,''x'',1,''NGN'',1,1,''posted'')', t.id('tenantA'), t.id('propA'), f), 'permission denied', 'nobody can insert ledger rows directly');
  perform t.login('fdo');
  perform t.raises(format('insert into public.folio_transactions (tenant_id, property_id, folio_id, business_date, kind, sign, description, amount, currency, fx_rate, base_amount, status) values (%L,%L,%L,current_date,''charge'',1,''x'',1,''NGN'',1,1,''posted'')', t.id('tenantA'), t.id('propA'), f), 'permission denied', 'front desk cannot insert ledger rows directly');

  -- payments and deposits
  tx := public.post_payment(f, t.pm('CASH'), 5000, 'NGN', 'receipt 1');
  perform t.eq(t.bal(f), 24241.25 - 5000, 'payment lowers the balance');
  perform t.login('rsv');
  perform public.post_payment(f, t.pm('TRANSFER'), 1000, 'NGN', 'dep', true);
  perform t.raises(format('select public.post_payment(%L, %L, 10, ''NGN'')', f, t.pm('CASH')), 'E_PERM', 'reservation officer cannot take a normal payment');
  perform t.eq((select count(*) from public.v_folio_balances where folio_id = f)::int, 0, 'reservation officer sees only folios of own bookings');
  perform t.login('fdo');
  perform t.eq((select total_paid from public.v_folio_balances where folio_id = f), 6000.00, 'deposit counts as paid');

  -- currency: USD at 1,500
  perform t.login('fdo');
  tx := public.post_payment(f, t.pm('CASH'), 10, 'USD', 'usd cash');
  perform t.admin();
  perform t.eq((select base_amount from public.folio_transactions where id = tx), 15000.00, 'USD 10 at 1,500 is 15,000 in naira');
  perform t.eq((select fx_rate from public.folio_transactions where id = tx), 1500.00000000, 'exchange rate is recorded on the row');
  perform t.login('fdo');

  -- immutability: even the table owner cannot change or delete posted rows
  perform t.admin();
  perform t.raises(format('update public.folio_transactions set amount = 1 where id = %L', tx), 'E_IMMUTABLE', 'posted amount cannot be updated');
  perform t.raises(format('update public.folio_transactions set status = ''rejected'' where id = %L', tx), 'E_IMMUTABLE', 'posted row cannot change status');
  perform t.raises(format('delete from public.folio_transactions where id = %L', tx), 'E_IMMUTABLE', 'ledger rows cannot be deleted');
  perform t.raises('truncate public.folio_transactions', 'E_IMMUTABLE', 'ledger cannot be truncated');
  perform t.raises(format('insert into public.folio_transactions (tenant_id, property_id, folio_id, business_date, kind, sign, description, amount, currency, fx_rate, base_amount, status, posted_at) values (%L,%L,%L,%L,''charge'',1,''x'',1,''NGN'',1,1,''posted'',now())', t.id('tenantA'), t.id('propA'), f, t.bdate() - 1), 'E_DATE', 'posting to a past business date is refused');
  perform t.raises(format('insert into public.folio_transactions (tenant_id, property_id, folio_id, business_date, kind, sign, revenue_group, description, amount, currency, fx_rate, base_amount, status, posted_at) values (%L,%L,%L,%L,''charge'',-1,''other'',''x'',1,''NGN'',1,1,''posted'',now())', t.id('tenantA'), t.id('propA'), f, t.bdate()), 'sign_matches_kind', 'a charge cannot carry a negative sign');
  perform t.login('fdo');

  -- discounts: within the limit posts, above the limit waits
  r := public.apply_discount(f, t.cc('MISC'), 3000, 'NGN', 'Loyal guest');
  perform t.eq((r ->> 'pending')::boolean, false, 'discount within limit posts at once');
  r := public.apply_discount(f, t.cc('MISC'), 8000, 'NGN', 'Service failure');
  perform t.eq((r ->> 'pending')::boolean, true, 'discount above limit waits for approval');
  a := (r ->> 'approval_id')::uuid;
  perform t.eq((select count(*) from public.folio_transactions where approval_id = a and status = 'pending_approval')::int, 3, 'pending discount has three rows');
  perform t.raises(format('select public.decide_approval(%L, true)', a), 'E_PERM', 'front desk cannot approve discounts');
  perform t.raises(format('select public.apply_discount(%L, %L, 100, ''NGN'', '''')', f, t.cc('MISC')), 'E_REASON', 'discount needs a reason');
  perform t.login('fom');
  v_n := (select count(*) from public.approvals where status = 'pending' and kind = 'discount');
  perform t.eq(v_n, 1, 'manager sees the pending discount');
  perform t.eq(t.bal(f), (select balance from public.v_folio_balances where folio_id = f), 'pending rows do not change the balance');
  perform public.decide_approval(a, true, 'ok');
  perform t.eq((select count(*) from public.folio_transactions where approval_id = a and status = 'posted')::int, 3, 'approved discount posts all its rows');
  perform t.raises(format('select public.decide_approval(%L, true)', a), 'E_STATE', 'a decided approval cannot be decided again');

  -- rejection
  perform t.login('fdo');
  r := public.apply_discount(f, t.cc('MISC'), 9000, 'NGN', 'Try');
  perform t.login('fom');
  perform t.raises(format('select public.decide_approval(%L, false)', (r ->> 'approval_id')::uuid), 'E_REASON', 'rejection needs a reason');
  perform public.decide_approval((r ->> 'approval_id')::uuid, false, 'Not justified');
  perform t.eq((select count(*) from public.folio_transactions where approval_id = (r ->> 'approval_id')::uuid and status = 'rejected')::int, 3, 'rejected discount rows are marked rejected');

  -- adjustments: separation of duties and limits
  perform t.login('acc');
  a := public.request_adjustment(f, 'decrease', 2000, 'NGN', 'Rate error', 'Correct a rate error');
  perform t.raises(format('select public.decide_approval(%L, true)', a), 'E_SOD', 'the requester cannot approve their own request');
  perform t.admin();
  perform t.raises(format('update public.approvals set status = ''approved'', decided_by = requested_by, decided_at = now() where id = %L', a), 'approver_is_not_requester', 'the database itself refuses self-approval');
  perform t.login('csh');
  a := public.request_adjustment(f, 'decrease', 50000, 'NGN', 'Big correction', 'Large correction');
  perform t.login('fom');
  perform t.raises(format('select public.decide_approval(%L, true)', a), 'E_LIMIT', 'manager cannot approve above their limit');
  perform t.login('acc');
  perform public.decide_approval(a, true);
  perform t.eq((select count(*) from public.folio_transactions where approval_id = a and status = 'posted' and kind = 'adjustment')::int, 1, 'senior approver posts the adjustment');

  -- reversal of a charge takes its tax lines with it
  perform t.login('fdo');
  r := public.post_charge(f, t.cc('MINIBAR'), 4000, 'NGN', 'Minibar');
  tx := (r -> 'ids' ->> 0)::uuid;
  v_dup := jsonb_build_object('before', t.bal(f));
  a := public.request_reversal(tx, 'Posted to wrong room');
  perform t.raises(format('select public.request_reversal(%L, ''again'')', tx), 'E_ALREADY_REVERSED', 'a charge is reversed only once');
  perform t.login('fom');
  perform public.decide_approval(a, true);
  perform t.eq(t.bal(f), (v_dup ->> 'before')::numeric - 4000 * 1.1825, 'reversal removes the charge and its tax');
  perform t.eq((select is_reversed from public.v_transactions where id = tx), true, 'the original shows as reversed');
  perform t.raises(format('select public.request_reversal(%L, ''x'')', (select id from public.folio_transactions where reverses_id = tx and kind = 'reversal')), 'E_STATE', 'a reversal cannot be reversed');

  -- refund only from a credit balance
  perform t.login('csh');
  perform t.raises(format('select public.request_refund(%L, %L, 100000000, ''NGN'', ''x'')', f, t.pm('CASH')), 'E_REFUND_LIMIT', 'a refund cannot exceed the credit on the folio');
  v_dup := jsonb_build_object('before', t.bal(f));
  a := public.request_refund(f, t.pm('CASH'), 100, 'NGN', 'Overpaid');
  perform t.eq(t.bal(f), (v_dup ->> 'before')::numeric, 'a pending refund does not change the balance');
  perform t.raises(format('select public.decide_approval(%L, true)', a), 'E_PERM', 'cashier cannot approve a refund');
  perform t.login('fom');
  perform public.decide_approval(a, true);
  perform t.eq(t.bal(f), (v_dup ->> 'before')::numeric + 100, 'approved refund pays out of the credit');

  -- transfer between folios
  perform t.login('fdo');
  f2 := public.split_folio(v_res, 'Company');
  r := public.post_charge(f, t.cc('RESTAURANT'), 1000, 'NGN', 'Dinner');
  tx := (r -> 'ids' ->> 0)::uuid;
  v_dup := jsonb_build_object('a', t.bal(f), 'b', t.bal(f2));
  perform t.raises(format('select public.transfer_transaction(%L, %L, ''move'')', tx, f2), 'E_PERM', 'front desk cannot transfer between folios');
  perform t.login('fom');
  perform public.transfer_transaction(tx, f2, 'Company pays dinner');
  perform t.eq(t.bal(f2), 1000 * 1.1825, 'target folio receives the charge and its tax');
  perform t.eq(t.bal(f), (v_dup ->> 'a')::numeric - 1000 * 1.1825, 'source folio is relieved');
  perform t.raises(format('select public.transfer_transaction(%L, %L, ''again'')', tx, f2), 'E_STATE', 'a charge is transferred once');
  perform t.admin();
  perform t.eq((select coalesce(sum(sign * base_amount), 0) from public.folio_transactions where property_id = t.id('propA') and kind in ('transfer_in','transfer_out')), 0.00, 'transfers net to zero across folios');

  -- closing and reopening
  perform t.login('hks');
  perform t.raises(format('select public.close_folio(%L)', f2), 'E_PERM', 'housekeeping cannot close a folio');
  perform t.login('fdo');
  perform t.raises(format('select public.close_folio(%L)', f2), 'E_BALANCE', 'a folio with a balance cannot be closed');
  perform public.post_payment(f2, t.pm('CASH'), 1182.50, 'NGN');
  perform t.eq(t.bal(f2), 0.00, 'settled folio has a zero balance');
  tx := public.issue_invoice(f2);
  perform t.eq((select total from public.invoices where id = tx), 1182.50, 'invoice total equals what was charged');
  perform t.eq((select tax_total from public.invoices where id = tx), 182.50, 'invoice shows the tax separately');
  perform t.eq((select balance_due from public.invoices where id = tx), 0.00, 'invoice balance is zero');
  perform public.close_folio(f2);
  perform t.raises(format('select public.post_charge(%L, %L, 10, ''NGN'', ''x'')', f2, t.cc('MISC')), 'E_FOLIO_CLOSED', 'a closed folio takes no postings');
  perform t.raises(format('select public.reopen_folio(%L, ''oops'')', f2), 'E_PERM', 'front desk cannot reopen a folio');
  perform t.login('acc');
  perform t.raises(format('select public.reopen_folio(%L, '''')', f2), 'E_REASON', 'reopening needs a reason');
  perform public.reopen_folio(f2, 'Add missed charge');
  perform t.eq((select status from public.folios where id = f2), 'open', 'accountant reopened the folio');
  perform t.admin();
  perform t.raises(format('update public.invoices set total = 1 where id = %L', tx), 'E_IMMUTABLE', 'an issued invoice cannot be changed');
  perform t.eq((select count(*) from public.audit_events where action = 'folio.reopen')::int, 1, 'reopen is in the audit trail');
end $$;
