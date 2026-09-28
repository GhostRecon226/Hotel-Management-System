# Guide for Lovable

Read this before building any screen. The database holds the rules. The UI shows data and calls functions.

## Ground rules

1. Never change the schema. No new tables, columns, policies or functions. If you need one, stop and ask.
2. Read data with `supabase.from('table').select()` or a view. Row-level security filters it for you.
3. Write data by calling `supabase.rpc('function_name', {...})`. Do not insert into ledger, reservation, stay, task or ticket tables. The database blocks it.
4. Exceptions where direct writes are allowed: `room_types`, `rooms` (not condition or occupancy), `rate_plans`, `rate_plan_prices`, `tax_rates`, `charge_codes`, `payment_methods`, `guests`, `guest_documents`, `guest_feedback`, `group_bookings`, `exchange_rates` (prefer `set_exchange_rate`), `lost_found_items`, `roles`, `role_permissions`, `approval_limits`, `properties` (limited columns), `profiles` (own row), `notifications` (mark read).
5. Send an idempotency key on every money or booking call. Make it once when the user opens the form, and reuse it on retry. Use `crypto.randomUUID()`.
6. Pass ids the database can use. For a new guest or reservation, the client may generate the uuid.
7. Show money with the currency's decimals. Amounts are `numeric(20,4)` strings. Do not use floating point for sums. Let the database compute totals.

## Errors

Every failure has the form `[E_CODE] message`. Read `error.message`. Match the code in brackets. Show the text after the bracket to the user. Special cases:

- `E_READ_ONLY`: show a banner "Your account is read-only. Contact your administrator." Disable write buttons.
- `E_PERM`: hide the button in future. Show the message now.
- `E_PENDING_APPROVAL`: show "Waiting for approval" and link to the approval.
- `E_UNAVAILABLE`, `E_OVERSOLD`, `E_ROOM_TAKEN`: refresh availability and let the user pick again.
- `E_PLAN_LIMIT`: show an upgrade message.

Full code list is in `docs/data-model.md`.

## Sign-in and permissions

1. Sign up with Supabase Auth. Require email confirmation.
2. A new user with no hotel calls `create_hotel(...)`. The result gives `tenant_id` and `property_id`.
3. After sign-in, read `profiles` (own row), `user_property_roles` (own rows) and `role_permissions` for those roles. Build a set of permission keys per property.
4. Hide buttons the user cannot use. The database checks again, so hiding is comfort, not security.
5. Grant level Y means allowed. L means allowed up to a limit. O means own records only.
6. Read `tenant_subscriptions.status`. Show a banner when it is `trial` (days left), `past_due`, `expired` or `suspended`.

## Screens

The property in use is chosen at the top of the app. Pass its id to every call.

| Screen | RPCs to call | Views to read | Permission keys |
|---|---|---|---|
| ADM-01 | `register_invited_user`, `set_user_status` | - | `adm.user.manage` |
| ADM-02 | `assign_role`, `remove_role`, `set_user_status` | - | `adm.config.manage`, `adm.role.assign`, `adm.role.manage` |
| ADM-03 | - | - | `adm.audit.view` |
| DASH-01 | - | `v_kpi_daily` | `dash.view`, `rep.ops.view` |
| DASH-02 | - | `v_arrivals`, `v_hk_board`, `v_in_house`, `v_room_board` | `dash.view` |
| FIN-01 | `apply_discount`, `close_folio`, `complete_service_request`, `decide_approval`, `issue_invoice`, `post_charge`, `post_payment`, `reopen_folio`, `request_adjustment`, `request_refund`, `request_reversal`, `split_folio`, `transfer_transaction` | `v_folio_balances` | `fin.adjust.approve`, `fin.adjust.post`, `fin.charge.post`, `fin.deposit.take`, `fin.discount.apply`, `fin.discount.approve`, `fin.folio.reopen`, `fin.folio.split`, `fin.folio.transfer`, `fin.folio.view`, `fin.invoice.issue`, `fin.payment.post`, `fin.refund.approve`, `fin.refund.post`, `fin.reverse.post`, `fo.checkout`, `svc.request.manage` |
| FIN-02 | - | - | `fin.shift.manage`, `fin.shift.reconcile` |
| FIN-03 | - | - | `audit.night.run` |
| FO-01 | `assign_room`, `assign_service_request`, `complete_service_request`, `create_service_request`, `extend_stay`, `mark_no_show`, `start_service_request` | `v_arrivals`, `v_in_house` | `fin.charge.post`, `fo.board.view`, `fo.room.assign`, `fo.stay.extend`, `res.noshow.mark`, `svc.request.create`, `svc.request.manage` |
| FO-02 | `check_in`, `void_check_in`, `walk_in_check_in` | - | `fo.checkin`, `fo.checkin.walkin`, `fo.checkout.reverse` |
| FO-03 | `check_out`, `issue_invoice`, `request_unsettled_checkout`, `undo_checkout` | - | `fin.invoice.issue`, `fin.payment.post`, `fo.checkout`, `fo.checkout.reverse`, `fo.checkout.unsettled.approve` |
| FO-04 | `move_room` | - | `fo.roommove`, `fo.roommove.complimentary` |
| GST-01 | `search_guests` | - | `guest.create`, `guest.edit`, `guest.view` |
| GST-02 | `anonymise_guest`, `merge_guests`, `search_guests` | - | `guest.complaint.manage`, `guest.create`, `guest.edit`, `guest.idocs.view`, `guest.merge`, `guest.view` |
| HK-01 | `assign_hk_task`, `complete_hk_task`, `start_hk_task` | `v_hk_board` | `hk.board.view`, `hk.task.assign`, `hk.task.execute` |
| HK-02 | `assign_hk_task`, `complete_hk_task`, `start_hk_task` | - | `hk.task.assign`, `hk.task.execute` |
| HK-03 | `inspect_hk_task` | - | `hk.inspect` |
| MNT-01 | `assign_ticket`, `create_ticket`, `resolve_ticket`, `start_ticket`, `wait_ticket` | - | `mnt.ticket.create`, `mnt.ticket.manage`, `mnt.ticket.work` |
| MNT-02 | `assign_ticket`, `cancel_ticket`, `close_ticket`, `create_ticket`, `reopen_ticket`, `resolve_ticket`, `start_ticket`, `wait_ticket` | - | `mnt.ticket.cancel`, `mnt.ticket.close`, `mnt.ticket.create`, `mnt.ticket.manage`, `mnt.ticket.work` |
| REP-01 | - | `v_kpi_daily` | `dash.view`, `rep.fin.view`, `rep.ops.view` |
| REP-02 | - | - | `rep.fin.view`, `rep.ops.view` |
| RES-01 | `get_availability` | - | `res.availability.view` |
| RES-02 | `confirm_reservation`, `create_reservation`, `modify_reservation` | - | `res.create`, `res.deposit.request`, `res.edit`, `res.group.manage`, `res.rate.override` |
| RES-03 | `assign_room`, `cancel_reservation`, `confirm_reservation`, `create_reservation`, `extend_stay`, `mark_no_show`, `modify_reservation`, `reinstate_reservation`, `set_arrival_ready`, `set_reservation_guests` | - | `fo.room.assign`, `fo.stay.extend`, `res.cancel`, `res.create`, `res.edit`, `res.noshow.mark`, `res.rate.override`, `res.reinstate` |
| RES-04 | `get_availability` | - | `res.availability.view` |
| ROOM-01 | - | `v_room_board` | `room.view` |
| ROOM-02 | `set_room_condition` | - | `room.status.override`, `room.view` |
| ROOM-03 | `decide_approval`, `release_room_block`, `request_room_block` | - | `room.block.approve`, `room.block.release`, `room.block.request` |
| SET-01 | `complete_hk_task` | - | `setup.property.manage` |
| SET-02 | - | - | `setup.roomtype.manage` |
| SET-03 | - | - | `setup.room.manage` |
| SET-04 | - | - | `setup.rateplan.manage` |
| SET-05 | `set_exchange_rate` | - | `setup.fx.manage`, `setup.tax.manage` |

Screen ids come from the Screen Catalogue. The table is built from the requirements workbook, so it lists what is backed today. Blank means the screen reads tables directly.

## Common calls

- Availability: `get_availability(p_property, p_arrival, p_departure)`.
- Rooms that can be assigned: `get_assignable_rooms(p_property, p_arrival, p_departure, p_room_type)`.
- Guest search: `search_guests(p_query, p_limit)`.
- Approvals: read `approvals`, then call `decide_approval` or `withdraw_approval`.
- Folio balance: read `v_folio_balances`. Transactions: read `v_transactions`.
- Notifications: read `notifications` for the bell icon.

## Not ready yet

Do not build screens for these. The backend is missing.

- Break-glass support access.
- Data exports.
- Staff invite (needs an Edge Function). Show the form and leave the button disabled.
- Reports for cancellation rate, ALOS and outstanding balances.
- Cashier shifts and night audit.
- Online payment and subscription billing.

## Prompt to start a Lovable session

Paste this first:

> This project uses an existing Supabase database. Read `docs/lovable-guide.md` and `docs/data-model.md` in the repo. Do not change the schema, policies or functions. Read data with select on tables and views. Write data only by calling the RPC functions listed in `docs/data-model.md`. Show errors from the text after `[E_CODE]`. Build one screen at a time. Start with sign-in, hotel creation and the app shell with the property switcher and subscription banner.

## Build order

1. Sign-in, signup, `create_hotel`, app shell, permission set, subscription banner.
2. Setup: room types, rooms, rate plans and prices, tax, charge codes, payment methods.
3. Reservations: availability, create, modify, cancel.
4. Front office: arrivals, in-house, check-in, check-out, room move.
5. Folio: post charge, post payment, discounts, approvals, invoice.
6. Housekeeping and maintenance boards.
7. Dashboard and reports.
8. Admin: users, roles, limits, audit.
