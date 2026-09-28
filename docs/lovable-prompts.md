# Lovable prompts

Paste them in order. One prompt per session step. Test each screen before you send the next prompt.

Before you start, connect Lovable to the Supabase project and to this GitHub repo. Then send prompt 0 once.

Prompts 1 to 14 assume the database is pushed. Send them only after `supabase db push` has run.

---

## 0. Set the ground rules

```text
This project uses an existing Supabase database that I own. Do not change the schema, policies, triggers or functions. Do not create tables or migrations.

Read docs/lovable-guide.md and docs/data-model.md in the repo before you write any code.

Rules:
- Read data with select on tables and views. Row-level security filters the rows.
- Write data only by calling supabase.rpc with the functions listed in docs/data-model.md. Do not insert into folio_transactions, reservations, stays, room_assignments, hk_tasks, maintenance_tickets, room_blocks or service_requests.
- Direct writes are allowed only on the tables named in docs/lovable-guide.md.
- Every money or booking call takes an idempotency key. Create it with crypto.randomUUID() when the form opens. Reuse it on retry.
- Errors look like "[E_CODE] message". Show the text after the bracket. Match the code for special handling.
- Never add up money in the browser. Show what the database returns.
- Use React, TypeScript, Tailwind and shadcn/ui. Keep the design plain, fast and usable on a laptop and a tablet at a front desk.
- One screen at a time. Tell me what you built and what you skipped.

Confirm you understand. Do not build anything yet.
```

## 1. Sign-in, signup and app shell

```text
Build sign-in, signup and the app shell.

Signup: email and password with Supabase Auth. Require email confirmation. Show a "check your email" page.

After the first sign-in, if the user has no row in user_property_roles, show a "Create your hotel" form. Fields: business name, country (Nigeria, Ghana, Kenya, South Africa, Other), property name, your full name, city. Submit with supabase.rpc('create_hotel', { p_business_name, p_country, p_property_name, p_full_name, p_city }). On success go to the dashboard.

App shell:
- Left menu: Dashboard, Reservations, Front Desk, Rooms, Housekeeping, Maintenance, Guests, Folios, Reports, Setup, Admin.
- Top bar: property switcher, business date of the selected property (properties.business_date), notification bell, user menu with sign out.
- After sign-in, load the user's permission keys: read user_property_roles (own rows), then role_permissions for those roles. Keep a set of keys per property in a React context. Hide menu items and buttons the user cannot use.
- Subscription banner: read tenant_subscriptions. Show days left on trial. Show a warning for past_due. Show a read-only notice for expired and suspended, and disable every write button.

Handle E_READ_ONLY on any write by showing the banner message.
```

## 2. Setup: property, rooms and rates

```text
Build the Setup section. Only show it to users with the setup permissions.

Pages:
1. Property (setup.property.manage): edit name, address, city, phone, check-in time, check-out time. Show business date and base currency as read only.
2. Room types (setup.roomtype.manage): list, add, edit, delete. Fields: code, name, max adults, max children, description.
3. Rooms (setup.room.manage): list, add, edit, delete. Fields: room number, room type, floor. Show condition and occupied as read only. Include a bulk add: a range like 101 to 120 for one room type.
4. Rate plans (setup.rateplan.manage): list, add, edit. Fields: code, name, corporate flag, cancellation policy, no-show policy, deposit policy. Policies are JSON with type (none, nights, percent, amount) and value. Give each a small form, not raw JSON.
5. Prices: for a rate plan, a grid of room type by date range with amount and currency. Use rate_plan_prices.
6. Tax and charge codes (setup.tax.manage): tax_rates, charge_codes and payment_methods. Show the tax order and whether each tax compounds on the previous one. Add a notice: "Tax rates are unverified. Confirm with your accountant."
7. Exchange rates (setup.fx.manage): list, and add with supabase.rpc('set_exchange_rate', { p_property, p_currency, p_date, p_rate }).

Use direct table writes for pages 2 to 6, as allowed in docs/lovable-guide.md. Always send tenant_id and property_id on insert. Take tenant_id from the user's profile.
```

## 3. Reservations: availability and create

```text
Build Reservations.

List page: search by guest name, reservation number, date and status. Read from reservations joined to guests. Columns: number, guest, arrival, departure, room type, status, balance.

Availability page: pick arrival and departure. Call supabase.rpc('get_availability', { p_property, p_arrival, p_departure }). Show a grid of room type by night with the available count. Colour zero red.

New reservation form (permission res.create):
1. Choose dates and see availability.
2. Find or create the guest. Search with supabase.rpc('search_guests', { p_query, p_limit: 10 }). Offer "New guest" with first name, last name, phone, email. Insert into guests with a client-generated uuid.
3. Choose room type, rate plan, adults, children, source (direct, walk-in, phone, corporate, other), company name (free text, only for corporate), special requests, notes.
4. Show the price the database quotes. If none is returned, show the error.
5. Optional rate override needs a reason. Only show it to users with res.rate.override.
6. Save with supabase.rpc('create_reservation', { p_property, p_guest, p_arrival, p_departure, p_room_type, p_rate_plan, p_adults, p_children, p_source, p_status, p_company, p_special, p_notes, p_guarantee, p_hold_hours, p_rate_override, p_rate_override_reason, p_group: null, p_idempotency_key }). Status is confirmed or tentative. A tentative booking has hold hours.

Show E_UNAVAILABLE, E_NO_RATE and E_DEPOSIT clearly. On E_UNAVAILABLE refresh availability.
```

## 4. Reservation detail and changes

```text
Build the reservation detail page.

Show: guest, dates, room type, assigned room, rate plan, status, guests on the booking, notes, folio balance, and a history from audit_events for this reservation.

Actions, each as a button that opens a small dialog, shown only when the user has the permission and the status allows it:
- Modify: supabase.rpc('modify_reservation', { p_id, p_arrival, p_departure, p_room_type, p_rate_plan, p_adults, p_children, p_special, p_notes, p_company, p_guarantee, p_rate_override, p_rate_override_reason }). Send only changed fields as values and the rest as null.
- Confirm a tentative booking: confirm_reservation({ p_id }).
- Cancel: cancel_reservation({ p_id, p_reason, p_waive_fee }). Show the fee the function returns. Waiving needs res.rate.override.
- Mark no-show: mark_no_show({ p_id, p_reason, p_waive_fee }).
- Reinstate: reinstate_reservation({ p_id, p_reason }).
- Assign room: first call get_assignable_rooms, then assign_room({ p_id, p_room }). Unassign with unassign_room({ p_id }).
- Guests on booking: set_reservation_guests({ p_id, p_guests }).
- Arrival ready flag: set_arrival_ready({ p_id, p_ready }).

Every reason field is required. Show the error text after the bracket.
```

## 5. Front desk: arrivals, in-house and check-in

```text
Build the Front Desk page with three tabs.

Arrivals: read v_arrivals for the selected property. Show guest, room type, assigned room, arrival ready, balance, deposit status. Row actions: Assign room, Check in.
In house: read v_in_house. Show room, guest, departure, balance. Row actions: Open folio, Move room, Extend stay, Check out.
Departures today: in-house rows with departure equal to the business date.

Check-in dialog (fo.checkin): pick a room from get_assignable_rooms, fill registration fields (ID type, ID number, nationality, address, vehicle plate), then call supabase.rpc('check_in', { p_id, p_room, p_registration }). Show E_ROOM_NOT_READY, E_ROOM_OCCUPIED and E_DEPOSIT.

Walk-in button (fo.checkin.walkin): find or create guest, choose departure, room, rate plan, adults, children, registration. Call walk_in_check_in with a new idempotency key.

Move room: move_room({ p_reservation, p_new_room, p_reason, p_complimentary }). Complimentary needs fo.roommove.complimentary.
Extend stay: extend_stay({ p_reservation, p_new_departure, p_reason }).
Void check-in: void_check_in({ p_stay, p_reason }), for users with fo.checkout.reverse.
```

## 6. Check-out

```text
Build check-out from the In house list and from the folio page.

Check-out screen for a reservation:
- Show every open folio with balance from v_folio_balances.
- If all balances are zero, the Check out button calls supabase.rpc('check_out', { p_reservation, p_approval: null }).
- If a balance is above zero, show a red notice. A user with fo.checkout.unsettled.approve can approve directly. Others click "Request approval" which calls request_unsettled_checkout({ p_reservation, p_reason }) and shows the pending state. When the approval is decided, the button calls check_out with p_approval set to the approval id.
- Show E_UNSETTLED and E_PENDING_APPROVAL.
- After check-out, offer "Print invoice" (see the folio prompt) and show that a housekeeping task was created.
- Undo check-out: undo_checkout({ p_stay, p_reason }) for users with fo.checkout.reverse, same business day only.
```

## 7. Folio and payments

```text
Build the Folio page for a reservation. Permission fin.folio.view.

Header: guest, room, dates, folio number, status, balance in base currency (from v_folio_balances).
Body: transaction list from v_transactions. Columns: date, code, description, debit, credit, tax, status, who. Show reversed rows greyed with a link to the reversal.

Buttons (only with the permission and an open folio):
- Post charge (fin.charge.post): pick charge code, amount, currency, description, tax inclusive toggle. Call post_charge({ p_folio, p_charge_code, p_amount, p_currency, p_description, p_tax_inclusive, p_idempotency_key, p_reference }).
- Record payment (fin.payment.post): pick method, amount, currency, reference, deposit toggle. Call post_payment({ p_folio, p_method, p_amount, p_currency, p_reference, p_is_deposit, p_idempotency_key }). Add a note: "Payments are taken outside the system. Record them here."
- Apply discount (fin.discount.apply): apply_discount({ p_folio, p_charge_code, p_amount, p_currency, p_reason, p_tax_inclusive, p_idempotency_key }). If the result says pending, show "Waiting for approval".
- Request adjustment: request_adjustment({ p_folio, p_direction, p_amount, p_currency, p_description, p_reason }).
- Request reversal on a row: request_reversal({ p_txn, p_reason }).
- Request refund: request_refund({ p_folio, p_method, p_amount, p_currency, p_reason, p_reference }).
- Transfer a row: transfer_transaction({ p_txn, p_to_folio, p_reason }).
- Split folio: split_folio({ p_reservation, p_label }).
- Close folio: close_folio({ p_folio }). Reopen: reopen_folio({ p_folio, p_reason }).
- Issue invoice: issue_invoice({ p_folio, p_kind }). Then show a printable invoice page from invoices with tax lines and a Print button.

Never edit or delete a transaction. Never total anything in the browser. Show E_FOLIO_CLOSED, E_CURRENCY, E_AMOUNT and E_PENDING_APPROVAL.
```

## 8. Approvals inbox

```text
Build an Approvals page and a badge on the menu.

List rows from approvals for the tenant. Tabs: Waiting for me, My requests, Decided. Columns: type (discount, adjustment, reversal, refund, room block, unsettled check-out), amount, requester, reason, created.

For rows the user may decide, show Approve and Reject buttons. Both ask for a reason. Call decide_approval({ p_approval, p_approve, p_reason }). A requester can withdraw with withdraw_approval({ p_approval }).

Show E_SOD when the user tries to approve their own request. Show E_LIMIT and E_REFUND_LIMIT with the limit in the message.

Tie the bell icon to the notifications table. Mark as read by updating the read flag on the user's own row.
```

## 9. Rooms board and room blocks

```text
Build the Rooms page. Permission room.view.

Board: read v_room_board. One tile per room, grouped by floor. Show room number, type, condition (clean, dirty, inspected, out of order), occupied or vacant, and sellable or not. Filter by condition and type. Click a tile for detail.

Room detail: current guest, next arrival, open tasks, open tickets, blocks.

Actions:
- Set condition (room.status.override): set_room_condition({ p_room, p_condition, p_reason }).
- Block a room (room.block.request): request_room_block({ p_room, p_type, p_from, p_to, p_reason, p_ticket }). Types: out of order, out of service, hold. If approval is needed, show pending.
- Release a block: release_room_block({ p_block, p_reason }).

Show E_OVERSOLD with the dates that would oversell.
```

## 10. Housekeeping

```text
Build Housekeeping. Permission hk.board.view.

Supervisor board: read v_hk_board. Columns for Dirty, Assigned, In progress, Waiting inspection, Done. Show room, task type, priority, assignee, age.
Actions for supervisors: create_hk_task({ p_room, p_type, p_notes, p_priority }), assign_hk_task({ p_task, p_user }), cancel_hk_task({ p_task, p_reason }).

Attendant view (hk.task.execute): a mobile-first list of my tasks. Buttons: Start (start_hk_task({ p_task })), Complete with a checklist and notes (complete_hk_task({ p_task, p_checklist, p_notes })).

Inspection (hk.inspect): a list of tasks waiting inspection. Pass or fail with defects: inspect_hk_task({ p_task, p_pass, p_reason, p_defects }). The inspector cannot be the cleaner. Show E_SOD.

Lost and found: a simple list and form on lost_found_items. Direct writes are allowed.
```

## 11. Maintenance and guest service

```text
Build Maintenance and Guest Service.

Maintenance tickets: list from maintenance_tickets with filters for status, priority and room. Create with create_ticket({ p_property, p_title, p_description, p_room, p_location, p_priority }). Manager actions: assign_ticket, start_ticket, wait_ticket({ p_ticket, p_reason }), resolve_ticket({ p_ticket, p_note }), close_ticket({ p_ticket }), reopen_ticket, cancel_ticket. The closer must differ from the resolver. Show E_SOD. Add "Block room" that opens the room block dialog with the ticket id.

Service requests: list from service_requests. Create from the in-house list with create_service_request({ p_reservation, p_category, p_description, p_chargeable, p_charge_amount, p_currency, p_charge_code }). Actions: assign_service_request, start_service_request, complete_service_request, cancel_service_request. Completing a chargeable request posts the charge to the folio. Show that in the confirmation.
```

## 12. Guests

```text
Build Guests. Permission guest.view.

List with search using search_guests. Guest profile: contact details, ID documents (guest_documents, needs guest.idocs.view), stay history from reservations, total nights, notes, feedback and complaints (guest_feedback).

Actions:
- Create and edit guests with direct writes.
- Add ID documents. Hide document numbers unless the user has guest.idocs.view.
- Log feedback or a complaint with a category, text and status.
- Merge duplicates (guest.merge): choose the guest to keep and the one to remove, then merge_guests({ p_keep, p_remove, p_reason }). Show a preview of what moves.
- Anonymise (guest.merge): anonymise_guest({ p_guest, p_reason }). Show a strong confirmation. Explain that it cannot be undone.
```

## 13. Dashboard and reports

```text
Build the Dashboard and Reports.

Dashboard (dash.view_ops or dash.view_exec):
- Today: arrivals, departures, in house, vacant clean, vacant dirty, out of order. Use v_arrivals, v_in_house, v_room_board, v_hk_board.
- KPIs for the business date and the last 30 days from v_kpi_daily: occupancy, ADR, RevPAR, room revenue, total revenue. Show a line chart of occupancy and revenue.
- Pending approvals count and open maintenance tickets.

Reports (rep.ops.view, rep.fin.view):
- Daily KPI table with date range and CSV download in the browser.
- Revenue by charge code from v_transactions.
- Outstanding balances from v_folio_balances.
- Payments by method and date.

Every figure comes from a view or table. Do not calculate KPIs in the browser. Add a Definitions box: occupancy = occupied rooms over sellable rooms, ADR = room revenue over rooms sold, RevPAR = room revenue over sellable rooms.
Skip cancellation rate and length of stay for now. The views do not exist.
```

## 14. Admin

```text
Build Admin. Permission-gated.

1. Users (adm.user.manage): list profiles for the tenant with roles per property and status. Actions: set_user_status({ p_user, p_status, p_reason }), assign_role({ p_user, p_property, p_role }), remove_role. The invite button is disabled with the label "Coming soon". A person cannot remove the last System Administrator. Show E_LAST_ADMIN.
2. Roles (adm.role.manage): list system roles read only. Let the user copy a system role into a custom role and edit its permissions. Each permission has a grant level: Y, L, O. Show E_ESCALATION if the user tries to give a permission they do not hold.
3. Approval limits (adm.config.manage): a grid of role, permission, maximum amount. Use direct writes on approval_limits. Explain that a role with level L and no limit has a limit of zero.
4. Audit (adm.audit.view): read audit_events with filters for user, table, action and date. Show before and after values as a readable diff.
5. Subscription (org.subscription.manage): show plan, status, trial end and limits. Buttons for cancel_subscription({ p_reason }). Billing and plan change are handled by us for now. Show a "Contact us to change plan" note.
```

## 15. Polish and test

```text
Review the whole app.

1. List every place where the app writes directly to a table that is not on the allowed list in docs/lovable-guide.md. Fix each one to use an RPC.
2. Check that every write RPC call sends an idempotency key where the function takes one.
3. Check that every error shows the text after "[E_CODE]".
4. Check every page at 1280 px and 768 px wide.
5. Add loading and empty states.
6. Add a confirmation before every action that cancels, reverses, refunds, merges or anonymises.
7. Confirm no page totals money in the browser.
8. List the pages and buttons that are hidden or disabled because the backend does not exist yet.

Report what you changed.
```

---

## After each prompt

1. Sign in as a test user with the right role and try the screen.
2. Try one failure on purpose. For example, book a full room type.
3. Check the audit page for the entry.
4. Commit in GitHub before the next prompt.

## Test users to create

Create one user per role in a test hotel: General Manager, Front Office Manager, Front Desk Officer, Reservation Officer, Housekeeping Supervisor, Room Attendant, Maintenance Officer, Cashier and Accountant. Set approval limits for the Front Desk Officer and Front Office Manager before you test discounts and refunds.
