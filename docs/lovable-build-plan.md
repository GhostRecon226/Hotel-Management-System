# Build plan: Lovable first, Claude Code second

You feed these prompts to Lovable by hand. Lovable builds the app, front and back. Later you clone the code and hand it to Claude Code to harden and finish.

The older backend in this repo stays as a reference. It is not used in this plan. Claude Code can compare the two when it takes over.

## The plan in six phases

| Phase | What | Prompts | Result you can see |
|---|---|---|---|
| 0 | Set up accounts | none | Empty Lovable project, Supabase project, GitHub sync |
| 1 | Foundation | 0 to 2 | Sign up, create a hotel, sign in, roles |
| 2 | Setup and guests | 3 to 4 | Rooms, rates, tax, guest records |
| 3 | Bookings and front desk | 5 to 7 | Book, assign, check in |
| 4 | Money | 8 to 10 | Folio, approvals, check-out, invoice |
| 5 | Operations | 11 to 15 | Room board, housekeeping, maintenance, dashboard, admin |
| 6 | Harden and hand over | 16 to 17 | Security review and a hand-over pack |

Plan for two to four weeks. Do one prompt at a time.

## Why this order

Each phase needs the one before it. Money comes after bookings because charges attach to a stay. The hand-over pack comes last so Claude Code starts with a clear map.

## Phase 0: set up (you, about 30 minutes)

1. **Supabase.** Create your own project. Choose the Frankfurt region. Keep your own Supabase so the data and schema are yours. Save the database password.
2. **Lovable.** Create a new project. Connect it to your Supabase project with Lovable's Supabase integration. Do not use Lovable Cloud's built-in database.
3. **GitHub.** In Lovable, connect GitHub so it syncs code to a new repo. Name it `hms-app`. Turn on sync from the start.
4. **Supabase Auth.** Turn on email confirmation. Turn on the `pg_cron` extension.
5. **Credits.** Check your Lovable plan's monthly credits. The full build needs many messages.
6. **Test users.** Keep three real email addresses handy for test users.

## Rules that keep the code easy to hand over

These go into Lovable's project knowledge in prompt 0.

1. Business rules live in database functions, not in React screens.
2. Every schema change is a SQL migration file in `supabase/migrations`, committed to the repo.
3. Every table has `tenant_id` and row-level security.
4. Standard packages only. No Lovable-only features in the code.
5. Tell me what you built after each step.

## After each prompt

1. Open the preview and try the feature.
2. Try one failure on purpose.
3. Confirm the code synced to GitHub.
4. Write down anything odd in a notes file. Claude Code will read it.

---

## Prompt 0: project knowledge

Paste this into Project knowledge in Lovable settings. Do not send it as a chat message.

```text
PRODUCT
A multi-tenant hotel management system for hotels in Nigeria first, then Africa. Hotels sign up themselves. Each hotel is a tenant. A tenant can have one or more properties. Base currency is NGN. Other currencies are allowed with a recorded exchange rate. Payments are taken outside the system and recorded here.

STANDING RULES
1. Use React, TypeScript, Tailwind and shadcn/ui. Use my own Supabase project. Do not use Lovable Cloud.
2. Put business rules in Postgres functions, called from the app with supabase.rpc. Keep React screens thin. Do not calculate money, tax, balances or availability in the browser.
3. Every database change is a SQL file in supabase/migrations named YYYYMMDDHHMMSS_topic.sql. Never edit an old migration. Add a new one.
4. Every table has tenant_id. Property-level tables also have property_id. Turn on row-level security on every table. A user sees only rows of their own tenant and their own properties.
5. Functions that change data are SECURITY DEFINER with search_path set to public, pg_temp. They check the caller's permission first.
6. Errors raised by functions look like: [E_CODE] plain message. The app shows the message text.
7. Money is numeric(20,4). Never use floating point.
8. The financial ledger is immutable. Never update or delete a posted transaction. Corrections are new rows linked to the original: reversal, adjustment or refund.
9. Every function that posts money or books a room takes an idempotency key. The same key twice returns the first result and does nothing new.
10. Roles and permissions are data, not code. A permission is a key like fin.payment.post. A role is a set of permissions. A user has a role per property.
11. Room condition (clean, dirty, inspected, out of order), room occupancy and room sellability are three separate things.
12. Deleting business records is rare. Prefer a status such as cancelled or inactive.
13. After every step, tell me what you built, the tables and functions you added, and what you skipped. Do not start work I did not ask for.
14. Keep the design plain and fast for a front desk on a laptop and a tablet. Use clear labels. Use Nigerian Naira formatting for NGN.
```

## Prompt 1: multi-tenant foundation

```text
Build the multi-tenant foundation as SQL migrations. No screens yet.

Tables:
- tenants: id, name, country, status (trial, active, past_due, expired, suspended, cancelled), created_at.
- tenant_subscriptions: tenant_id, plan_code, status, trial_ends_at, current_period_end.
- plans: code, name, max_rooms, max_properties, max_users. Seed four plans: starter (20 rooms, 1 property, 10 users), standard (60, 1, 25), pro (150, 3, 60), enterprise (no limits).
- profiles: id (same as auth.users id), tenant_id, full_name, phone, status (active, disabled).
- properties: id, tenant_id, name, code, address, city, country, base_currency (default NGN), timezone (default Africa/Lagos), check_in_time, check_out_time, business_date.
- permissions: key, description, module.
- roles: id, tenant_id (null for system roles), code, name, is_system.
- role_permissions: role_id, permission_key, grant_level (Y for allowed, L for allowed up to a limit, O for own records only).
- user_property_roles: user_id, property_id, role_id.
- approval_limits: role_id, permission_key, max_amount.
- audit_events: id, tenant_id, actor_id, action, table_name, record_id, before, after, reason, created_at.

Seed system roles: System Administrator, General Manager, Front Office Manager, Front Desk Officer, Reservation Officer, Housekeeping Supervisor, Room Attendant, Maintenance Officer, Cashier, Accountant. Seed a sensible permission list for each module: setup, reservations, front office, guests, rooms, housekeeping, maintenance, service, finance, reports, admin. Use keys such as res.create, res.edit, res.cancel, fo.checkin, fo.checkout, fin.charge.post, fin.payment.post, fin.discount.apply, fin.discount.approve, fin.adjust.post, fin.adjust.approve, fin.refund.post, fin.refund.approve, fin.reverse.post, fin.invoice.issue, adm.user.manage, adm.role.manage, adm.audit.view.

Helper functions in a schema called app (not exposed to the browser): my_tenant(), can(permission_key, property_id) which returns true if the user holds the permission, has_property_access(property_id), and fail(code, message) which raises [code] message.

Row-level security on every table using those helpers. A user sees only their tenant. A role with grant level L and no row in approval_limits has a limit of zero.

Function create_hotel(business_name, country, property_name, full_name, city): for a signed-in user with a confirmed email who has no hotel yet. It creates the tenant, a 30-day trial subscription on the starter plan, the first property, the profile, and gives the user the System Administrator and General Manager roles. It returns the tenant id and property id.

Add a trigger that stops the last System Administrator being removed.
Add audit triggers on roles, role_permissions, user_property_roles and approval_limits.
Write a short SQL test script in supabase/tests that proves a user from hotel A cannot read hotel B's rows.
```

## Prompt 2: sign-in, sign-up and app shell

```text
Build sign-in, sign-up and the app shell.

Sign-up: email and password with Supabase Auth. Email confirmation required. Show a check-your-email page.

First sign-in: if the user has no hotel, show Create your hotel. Fields: business name, country (Nigeria, Ghana, Kenya, South Africa, Other), property name, your full name, city. Call create_hotel. Then go to the dashboard.

App shell:
- Left menu: Dashboard, Reservations, Front Desk, Rooms, Housekeeping, Maintenance, Guests, Folios, Reports, Setup, Admin.
- Top bar: property switcher, business date, notification bell, user menu with sign out.
- After sign-in, load the user's permission keys per property into a React context. Hide menu items and buttons the user cannot use.
- Subscription banner: days left on trial, warning when past due, read-only notice when expired or suspended.

Add a database function that returns the current user's permissions per property so the app needs only one call. Add a function that reports whether the tenant is writable. Data-changing functions must refuse with [E_READ_ONLY] when the tenant is expired or suspended. Settlement and check-out stay allowed.

Do not build any other screens.
```

## Prompt 3: property setup

```text
Build the Setup section. Only users with setup permissions can see it.

Database:
- room_types: property_id, code, name, max_adults, max_children, description.
- rooms: property_id, room_number, room_type_id, floor, condition (clean, dirty, inspected, out_of_order; default clean), is_occupied (default false).
- rate_plans: property_id, code, name, is_corporate, cancellation policy, no-show policy, deposit policy. Each policy has a type (none, nights, percent, amount) and a value.
- rate_plan_prices: rate_plan_id, room_type_id, valid_from, valid_to, amount, currency.
- tax_rates: property_id, code, name, percent, sort_order, compounds_on_previous (boolean).
- charge_codes: property_id, code, name, category (room, food, service, tax, other), is_taxable.
- payment_methods: property_id, code, name, kind (cash, card, transfer, pos, other).
- exchange_rates: property_id, currency, rate_date, rate.
- document_sequences for reservation, folio and invoice numbers.

Seed defaults when a property is created, for Nigeria: service charge 10%, VAT 7.5% calculated on the net price plus the service charge, and a state levy at 0%. Add charge codes for room, restaurant, laundry, minibar, service charge, VAT, cancellation fee and no-show fee. Add payment methods for cash, POS, bank transfer and card. Mark the tax rates as unverified in the description.

Tax function: given a net amount or a gross amount and a tax-inclusive flag, return the tax lines. Round each line to 2 decimals. Put any rounding remainder on the last tax line.

Function set_exchange_rate(property, currency, date, rate).

Screens: Property details, Room types, Rooms (with a bulk add for a range like 101 to 120), Rate plans and prices, Tax and charge codes and payment methods (with a visible note to confirm rates with an accountant), Exchange rates.

Enforce plan limits: a trigger that blocks adding rooms, properties or users above the plan limit with [E_PLAN_LIMIT].
```

## Prompt 4: guests

```text
Build Guests.

Database:
- guests: tenant_id, first_name, last_name, phone, email, nationality, address, notes, created_at, anonymised_at.
- guest_documents: guest_id, doc_type, doc_number, expiry.
- guest_feedback: guest_id, category, text, status, created_at.

Functions: search_guests(query, limit) matching name, phone and email. merge_guests(keep, remove, reason) moves all references to the kept guest and marks the other as merged. anonymise_guest(guest, reason) removes personal details and keeps the stay history.

Screens: guest list with search, guest profile (details, documents, stay history, feedback), create and edit, merge duplicates with a preview, anonymise with a strong confirmation.

Only users with guest permissions can see ID document numbers. Audit changes to guest personal data.
```

## Prompt 5: reservations and availability

```text
Build reservations and availability.

Database:
- reservations: tenant_id, property_id, number, guest_id, arrival_date, departure_date, room_type_id, rate_plan_id, adults, children, status (tentative, confirmed, cancelled, no_show, checked_in, checked_out), source (direct, walk_in, phone, corporate, other), company_name (free text), special_requests, notes, guarantee, hold_until, group_id, idempotency_key.
- reservation_nights: one row per night per reservation with the nightly rate and, when assigned, the room. This is the source of availability.
- group_bookings: a record that several one-room reservations can share.
- room_assignments: reservation_id, room_id, from_date, to_date.

Rules:
1. Sellable rooms per room type per night = rooms of that type that are not blocked or out of order. Available = sellable minus reserved nights.
2. Booking must be safe under two people booking the last room at the same time. Use a lock per property and room type.
3. A physical room cannot be assigned to two stays on the same night. Enforce this with an exclusion constraint.
4. Departure must be after arrival. Stays have a maximum length setting per property.
5. The nightly price comes from the rate plan and room type. If no price exists, refuse with [E_NO_RATE].
6. A tentative booking has a hold time.
7. A rate override needs a reason and a permission.
8. Deposit policy on the rate plan creates a required deposit amount.

Functions: get_availability(property, arrival, departure), create_reservation(...with an idempotency key), modify_reservation, confirm_reservation, cancel_reservation (returns the cancellation fee per the rate plan policy, with an option to waive), mark_no_show, reinstate_reservation, assign_room, unassign_room, get_assignable_rooms, set_reservation_guests.

Screens: reservation list with search and filters, availability grid (room type by night, zero shown in red), new reservation form, reservation detail with all actions and an audit history. Every reason field is required.
```

## Prompt 6: front desk

```text
Build the Front Desk.

Database: stays (reservation_id, room_id, checked_in_at, checked_out_at, registration jsonb, status).

Rules:
1. Only ready rooms (clean or inspected, not occupied, not blocked) can be assigned to arrive. A manager with permission can override with a reason.
2. Check-in needs an assigned room and the required deposit unless a manager waives it.
3. Check-in marks the room occupied. Check-out marks it vacant and dirty.
4. A walk-in creates the reservation and checks in as one step.

Functions: check_in, walk_in_check_in, void_check_in, move_room, extend_stay, and views v_arrivals and v_in_house.

Screens: Front Desk page with tabs Arrivals, In house and Departures today. Check-in dialog with registration fields (ID type, ID number, nationality, address, vehicle plate). Walk-in dialog. Move room, extend stay and void check-in dialogs.

Do not build check-out yet. It needs the folio.
```

## Prompt 7: room board and blocks

```text
Build the Rooms board and room blocks.

Database: room_blocks (room_id, type: out_of_order, out_of_service or hold, from_date, to_date, reason, ticket_id, status).

Rules: a block that would leave the property oversold on any night is refused with [E_OVERSOLD]. A block needs approval from a user with the approve permission. Approvers who request a block get it approved at once.

Functions: request_room_block, release_room_block, set_room_condition(room, condition, reason), and a view v_room_board.

Screens: room board with one tile per room grouped by floor, showing condition, occupied or vacant, and sellable or not. Filter by condition and type. Room detail with current guest, next arrival, open tasks and blocks. Actions to set condition, block and release.
```

## Prompt 8: folio and ledger

```text
Build the folio and the ledger. This is the most important part. Follow the standing rules exactly.

Database:
- folios: reservation_id, number, label, status (open, closed), guest_id.
- folio_transactions: folio_id, kind (charge, payment, discount, adjustment, reversal, refund, transfer), charge_code_id, payment_method_id, amount, currency, fx_rate, base_amount, tax_inclusive flag, description, reference, links to original transaction, idempotency_key (unique per tenant), posted_by, posted_at, business_date.
- Tax lines stored as their own rows linked to the charge.

Rules:
1. Posted transactions are never updated or deleted. A trigger blocks it and raises [E_IMMUTABLE].
2. Balances come from a view, v_folio_balances, never from a stored total.
3. A reversal is a new opposite row linked to the original. A row can be reversed only once.
4. Charges use the tax function from setup.
5. Payments record the method and can be flagged as a deposit.
6. Foreign currency amounts store the exchange rate used and the base currency amount.
7. A closed folio accepts no new transactions. Reopening needs a reason and a permission.
8. Each stay gets a main folio. A guest can have extra folios. A transaction can be transferred to another folio of the same stay, as a linked pair of rows.

Functions: post_charge, post_payment, split_folio, transfer_transaction, close_folio, reopen_folio.

Screens: Folio page with header, transaction list (reversed rows greyed out), balance, and buttons Post charge, Record payment, Split folio, Transfer, Close and Reopen. Add the note: payments are taken outside the system and recorded here.

Do not build discounts, adjustments, refunds or approvals yet.
```

## Prompt 9: approvals, discounts, adjustments and refunds

```text
Build approvals and the controlled money actions.

Database: approvals (tenant_id, kind, entity, requested_by, amount, reason, status: pending, approved, rejected, withdrawn; decided_by, decided_at, decision_reason). Add a database check so the approver can never be the requester.

Rules:
1. Adjustments, reversals and refunds always need approval.
2. A discount is applied at once if the user's discount limit covers it. Above the limit it waits for approval.
3. A role with grant level L uses the limit in approval_limits. No limit row means zero.
4. On approval the system posts the linked transaction. On rejection nothing is posted.
5. A requester can withdraw a pending request.
6. Approvers get a notification.

Functions: apply_discount, request_adjustment, request_reversal, request_refund, decide_approval, withdraw_approval.

Add notifications: a table, a bell in the top bar, and mark as read.

Screens: Approvals page with tabs Waiting for me, My requests and Decided. Approve and Reject with a required reason. Buttons for these actions on the folio page. Show [E_SOD] clearly when someone tries to approve their own request.
```

## Prompt 10: check-out and invoices

```text
Build check-out and invoices.

Rules:
1. Check-out needs every folio at zero balance.
2. A user with the unsettled-checkout approval permission can approve a check-out with a balance. Others request approval and the approval id is passed to check_out.
3. Check-out closes the folios, marks the room dirty and creates a turnover housekeeping task.
4. Same-day arrival and departure keeps the dates and creates no night rows.
5. Undo check-out is allowed on the same business day for users with the permission.

Database: invoices (folio_id, number, kind, issued_at, totals, tax split). Numbers come from a sequence.

Functions: request_unsettled_checkout, check_out, undo_checkout, issue_invoice. The invoice keeps the tax split per tax line, including on transferred rows.

Screens: check-out screen showing every folio and balance, a printable invoice page with tax lines and a Print button.

Also add the nightly room charge: a function that posts one room charge per in-house stay per business date using the idempotency key room:<reservation>:<date>, so running it twice never charges twice.
```

## Prompt 11: housekeeping

```text
Build Housekeeping.

Database: hk_tasks (room_id, type: turnover, stayover, deep_clean, inspection; status: open, assigned, in_progress, done, inspected, failed, cancelled; priority, assignee, checklist jsonb, notes, timestamps). lost_found_items (property_id, description, found_at, location, status).

Rules:
1. Check-out creates a turnover task. A new turnover cancels any stale open one for the room.
2. Completing a task marks the room dirty until inspected. A pass marks it clean or inspected.
3. The inspector cannot be the person who cleaned the room. Raise [E_SOD].
4. A failed inspection reopens the task with the defects listed.

Functions: create_hk_task, assign_hk_task, start_hk_task, complete_hk_task, inspect_hk_task, cancel_hk_task, and a view v_hk_board.

Screens: supervisor board with columns for Open, Assigned, In progress, Waiting inspection and Done. Attendant view, mobile first, with Start and Complete and a checklist. Inspection list with pass and fail. Lost and found list and form.
```

## Prompt 12: maintenance and guest service

```text
Build Maintenance and Guest Service.

Database: maintenance_tickets (property_id, title, description, room_id, location, priority, status: open, assigned, in_progress, waiting, resolved, closed, cancelled; assignee, resolver, closer). service_requests (reservation_id, category, description, chargeable, charge_amount, currency, charge_code_id, status, assignee).

Rules:
1. The person who closes a ticket must differ from the person who resolved it. Raise [E_SOD].
2. A ticket can block a room. Use the room block function from the rooms step.
3. Completing a chargeable service request posts the charge to the guest's folio, once.

Functions: create_ticket, assign_ticket, start_ticket, wait_ticket, resolve_ticket, close_ticket, reopen_ticket, cancel_ticket, create_service_request, assign_service_request, start_service_request, complete_service_request, cancel_service_request.

Screens: tickets list and detail with all actions and a Block room button. Service requests list, created from the in-house list.
```

## Prompt 13: business date and reports

```text
Build the business date and reporting.

Rules:
1. Each property has a business date. It rolls automatically after a configurable time, default 03:00 property time. A scheduled job checks every 5 minutes and rolls the date when due.
2. The roll posts room charges for in-house stays, marks unconfirmed tentative holds that have expired, marks no-shows for confirmed arrivals that did not show, and creates stayover housekeeping tasks.
3. Each step is idempotent. A failed roll changes nothing and notifies the managers.
4. Log every roll in business_date_log.

Database: business_date_log, daily_stats (one row per property per date: rooms sold, rooms available, room revenue, total revenue, arrivals, departures, no-shows, cancellations). Views v_kpi_daily with occupancy, ADR and RevPAR.

Definitions: occupancy = rooms sold over rooms available. ADR = room revenue over rooms sold. RevPAR = room revenue over rooms available.

Screens: Dashboard with today's arrivals, departures, in house, vacant clean, vacant dirty, out of order, KPIs for the last 30 days with a chart, pending approvals and open tickets. Reports page with a KPI table and CSV download, revenue by charge code, outstanding balances, and payments by method and date. Add a Definitions box.

Every figure comes from a view or function, not from browser code.
```

## Prompt 14: staff and roles admin

```text
Build the Admin section.

Functions: register_invited_user, assign_role, remove_role, set_user_status, plus an Edge Function that invites a staff member by email: it creates the auth user, calls register_invited_user, then assign_role.

Rules:
1. Nobody can grant a permission they do not hold. Raise [E_ESCALATION].
2. The last System Administrator cannot be removed or disabled. Raise [E_LAST_ADMIN].
3. System roles are read only. Users copy one to make a custom role.
4. Plan limits apply to the user count.

Screens: Users (list, invite, roles per property, enable and disable), Roles (list, copy, edit permissions and grant levels Y, L and O), Approval limits (role, permission, maximum amount, with a note that L with no limit means zero), Audit log (filters for user, table, action and date, with before and after shown as a readable diff), Subscription (plan, status, trial end, limits).
```

## Prompt 15: notifications outbox and exports

```text
Add the outbox and exports.

1. notification_outbox: a queue for messages (channel: email, sms, whatsapp; recipient; subject; body; status: pending, sent, failed; attempts; last_error). Database functions add messages here. An Edge Function reads pending rows, sends email through Resend, marks them sent or failed, and retries with back-off. Run it every minute. Send reservation confirmations and approval alerts by email. Leave SMS and WhatsApp as stubs.
2. Exports: an Edge Function that exports reservations, folio transactions and guests to CSV for a date range. It checks the export permission and writes an audit entry.
3. Add report views for cancellation rate, average length of stay, and outstanding balances by guest, and show them on the Reports page.
```

## Prompt 16: security and quality review

```text
Review the whole app. Do not add features.

1. List every table without row-level security. Fix them.
2. List every function that changes data without a permission check. Fix them.
3. List every place the browser writes directly to ledger, reservation, stay, task, ticket, block or approval tables. Change each to use a function.
4. Confirm no page adds up money in the browser.
5. Confirm every money or booking function takes an idempotency key.
6. Confirm the two-hotels isolation test passes. Add tests for: double booking, immutable ledger, approver cannot be requester, last admin protection, and plan limits.
7. Confirm every error shows the text after [E_CODE].
8. Check every page at 1280 px and 768 px wide. Add loading and empty states.
9. Add a confirmation before every action that cancels, reverses, refunds, merges or anonymises.
10. List what is hidden, disabled or unfinished.

Report what you found and fixed.
```

## Prompt 17: hand-over pack

```text
Prepare the hand-over to another engineer.

Write these files in the repo:
1. README.md: what the app is, how to run it locally, environment variables, how to deploy, how to run the tests.
2. docs/architecture.md: layers, the tenant model, the permission model, the ledger rules, how availability works, how the business date rolls, scheduled jobs.
3. docs/data-model.md: every table with columns and purpose, every view, and a Mermaid diagram of the main relationships.
4. docs/functions.md: every database function with arguments, returns, permission needed and error codes it can raise.
5. docs/screens.md: every screen, its route, and the functions and views it uses.
6. docs/known-issues.md: everything unfinished, hacky or doubtful. Be blunt.
7. docs/lovable-notes.md: anything specific to Lovable that would need to change if the app moves to another build tool.

Make sure all schema changes are in supabase/migrations and the migrations run cleanly from an empty database. Remove unused code and files. Do not add features.
```

---

## Hand-over to Claude Code

When prompt 17 is done:
1. Confirm the code is synced to the `hms-app` repo.
2. Start a Claude Code session in that repo. Tell it to read `docs/known-issues.md`, then the architecture and data model.
3. Claude Code compares this schema with the tested backend in the `Hotel-Management-System` repo. It keeps whichever parts are stronger. It runs the tests, fixes gaps and hardens the ledger, approvals and security.
4. Then decide if you keep Lovable for screens or move everything to Claude Code. The rules in prompt 0 make either path possible.
