# R1 requirement list. Columns:
# id, module, screens, requirement, BR trace, priority, release, permissions, transition/rule refs,
# given, when, then, built by (database object), verified by (test file), status
# status: Built+tested | Built (UI or Edge Function work remains) | Not built | R1b | Decision needed
R = []
def r(*a): R.append(a)

# ---------------- Platform, tenancy, subscription
r("PLT-001","Platform & Tenancy","(signup page)","A person with a confirmed email creates a hotel account in one step.","BR-001, BR-002","Must","R1","(any signed-in user)","Rule: Signup protection; A13",
  "a signed-in user with a confirmed email and no hotel","they submit business name, country and property name","a tenant, a 30-day trial, one property with country defaults, and the System Administrator and General Manager roles exist for them",
  "create_hotel, provision_tenant","10, 17","Built+tested")
r("PLT-002","Platform & Tenancy","(signup page)","Signup is refused for an unconfirmed email and for a user who already belongs to a hotel.","BR-017","Must","R1","-","Rule: Signup protection",
  "a user whose email is not confirmed","they try to create a hotel","the request is refused with E_EMAIL_UNVERIFIED; a user who already has a hotel gets E_ALREADY_HAS_HOTEL",
  "create_hotel","17","Built+tested")
r("PLT-003","Platform & Tenancy","(all)","One hotel can never see or change another hotel's data.","BR-002, BR-017","Must","R1","-","Rule: Tenant isolation; A1",
  "two hotels with data","a user of hotel B queries or calls functions with hotel A's ids","no rows come back, writes are refused, and functions answer E_PERM or E_NOT_FOUND",
  "row-level security on every table; tenant_id on every row","11, 16","Built+tested")
r("PLT-004","Platform & Tenancy","(signup page), SET-01","A new property is seeded from its country template (currency, timezone, tax lines, payment methods, charge codes).","BR-002","Must","R1","-","Rule: Country templates; A10, A11",
  "a hotel signs up in Nigeria","the property is created","it uses naira and Africa/Lagos with service charge, VAT 7.5% and a state levy line at 0%, all marked unverified; other countries get no guessed taxes",
  "seed_property_defaults, country_templates","17","Built+tested")
r("PLT-005","Platform & Tenancy","(banner)","A trial ends automatically and the hotel becomes read-only.","BR-001","Must","R1","-","Rule: Read-only tenants; A13",
  "a hotel whose trial end date has passed","the daily clock runs","the subscription is Expired, the change is in the subscription history, and the hotel can read but not create",
  "run_subscription_clock, assert_writable, tenant_writable","15","Built+tested")
r("PLT-006","Platform & Tenancy","FO-03, FIN-01","A read-only hotel can still settle and check out guests already in house.","BR-013","Must","R1","fin.payment.post, fo.checkout","Rule: Read-only tenants",
  "an expired hotel with a guest in house who owes money","staff post a payment and check the guest out","both succeed; new bookings and charges are refused with E_READ_ONLY",
  "assert_writable(p_allow_settlement)","15","Built+tested")
r("PLT-007","Platform & Tenancy","SET-03, ADM-01","Plan limits on rooms, properties and users stop new creation and never delete anything.","BR-002","Should","R1","(system)","Rule: Plan limits; A16",
  "a hotel on a plan of one room","staff add a second room, property or user","the action is refused with E_PLAN_LIMIT; existing data is untouched",
  "limit_rooms, limit_properties, limit_users triggers","15","Built+tested")
r("PLT-008","Platform & Tenancy","(platform console)","Platform staff activate, suspend, change plan or close a hotel by hand, with a reason, and every change is logged.","BR-001","Must","R1","platform.billing.manage, platform.tenant.manage","Rule: Read-only tenants; A13",
  "a hotel whose invoice was paid outside the system","platform staff activate it with a paid-until date","it becomes Active, works again, and the change appears in the subscription history",
  "platform_change_subscription","15","Built+tested")
r("PLT-009","Platform & Tenancy","(platform console)","Platform staff see tenants and subscriptions but no guest, reservation or financial data.","BR-017","Must","R1","platform.tenant.manage","Rule: Platform Super Admin",
  "a platform user","they query guests, folios or reservations","they get no rows",
  "row-level security; platform staff have no tenant profile","15","Built+tested")
r("PLT-010","Platform & Tenancy","(platform console)","Time-boxed break-glass support access, with reason, tenant notice and audit entry.","BR-017, BR-018","Should","R1","platform.support.access","Rule: Platform Super Admin",
  "a platform user needs to help a hotel","they request support access with a reason","access is limited in time, written to the hotel's audit log and the hotel is told",
  "(not written)","-","Not built")
r("PLT-011","Platform & Tenancy","(billing page)","A hotel can cancel its own subscription and stays read-only afterwards.","BR-001","Should","R1","org.subscription.manage","A13",
  "a hotel administrator","they cancel the subscription with a reason","status becomes Cancelled and, when no paid period remains, the hotel is read-only",
  "cancel_subscription","17","Built+tested")
r("PLT-012","Platform & Tenancy","(billing page)","Subscription billing through a payment provider (Paystack or Flutterwave).","BR-001","Should","R1b","org.billing.paymentmethod","A13",
  "a hotel wants to pay online","they choose a plan and pay","the subscription activates automatically","(pilots are invoiced by hand until then)","-","R1b")

# ---------------- Administration
r("ADM-001","Administration","ADM-01","A hotel administrator adds staff to the hotel.","BR-017","Must","R1","adm.user.manage","Rule: Role assignment",
  "an administrator and a new auth user created by an Edge Function","the administrator registers the user","the user joins the hotel; a person who already belongs to a hotel cannot be taken over",
  "register_invited_user (the Edge Function creates the auth user and sends the invite)","10, 15","Built (UI or Edge Function work remains)")
r("ADM-002","Administration","ADM-02","Only administrators assign roles, per property or hotel-wide; the last administrator cannot be removed.","BR-017","Must","R1","adm.role.assign","Rule: Role assignment",
  "a hotel with one System Administrator","that person is removed or disabled","the change is refused with E_LAST_ADMIN; platform roles can never be assigned by a hotel",
  "assign_role, remove_role, set_user_status","15","Built+tested")
r("ADM-003","Administration","ADM-01","A disabled user loses all access immediately.","BR-017","Must","R1","adm.user.manage","-",
  "a cashier who leaves the company","an administrator disables the user","every action the user tries is refused with E_PERM",
  "set_user_status; grant_level checks profile status","15","Built+tested")
r("ADM-004","Administration","ADM-02","Custom roles cannot hold more than their creator holds.","BR-017","Must","R1","adm.role.manage","Rule: Role assignment",
  "an administrator without payment rights","they add fin.payment.post to a custom role","the change is refused with E_ESCALATION; system roles cannot be edited",
  "role_perm_no_escalation trigger; roles policies","15","Built+tested")
r("ADM-005","Administration","ADM-02","Limit-based permissions (grant level L) use a per-role amount; no limit means zero.","BR-015, BR-017","Must","R1","adm.config.manage","Rule: Limits",
  "a role with level L on discount and a limit of 5,000","the user applies a discount of 8,000","the discount waits for approval",
  "approval_limits, approval_limit()","12","Built+tested")
r("ADM-006","Administration","ADM-03","The audit trail cannot be changed or deleted by anyone, and is visible to permitted roles only.","BR-014, BR-018","Must","R1","adm.audit.view","Rule: Immutability, Audit log access",
  "audit events exist","anyone, including the database owner, updates or deletes one","the change is refused with E_IMMUTABLE",
  "audit_events triggers; audit_read policy","11, 13, 16","Built+tested")
r("ADM-007","Administration","(all)","Sensitive actions require a reason and write an audit event with actor, time, before and after.","BR-018","Must","R1","(all S permissions)","Rule: Reasons",
  "a sensitive action (cancel, rate override, refund, block, reopen, override condition)","it is performed","a reason is required and an audit event is written",
  "app.audit calls in each function","12, 13, 14, 15, 17","Built+tested")
r("ADM-008","Administration","(bell icon)","Staff get in-app notifications for approvals, tasks and exceptions, and can mark them read.","BR-017","Should","R1","(own)","-",
  "an approval is requested","the requester submits it","users holding the approve permission get a notification; each user sees only their own",
  "notifications, notify_permission, notify_user","16, 17","Built+tested")
r("ADM-009","Administration","(exports)","Authorised users export data.","BR-020","Should","R1","data.export, rep.export","-",
  "an authorised user","they export a report","a file is produced and the export is audited","(needs an Edge Function or client-side export)","-","Not built")

# ---------------- Setup
r("SET-001","Setup","SET-01","Property profile can be edited, but the business date and base currency cannot.","BR-002","Must","R1","setup.property.manage","Rule: Business date",
  "a property with postings","an administrator edits the profile","name, contact, rollover time and inspection setting change; business date and base currency are refused",
  "column grants on properties","16","Built+tested")
r("SET-002","Setup","SET-02","Room types with occupancy limits and an overbooking allowance.","BR-004","Must","R1","setup.roomtype.manage","-",
  "an administrator","they add a room type","it appears in availability and booking",
  "room_types (direct write with RLS)","10, 13","Built+tested")
r("SET-003","Setup","SET-03","Room inventory per property; rooms can be retired but never deleted while in use.","BR-004, BR-009","Must","R1","setup.room.manage","-",
  "an administrator","they add rooms","they start Ready and Vacant and count towards inventory; condition and occupancy cannot be written by hand",
  "rooms; column grants","10, 14, 16","Built+tested")
r("SET-004","Setup","SET-04","Rate plans with prices by room type, date range and weekday, and policies for cancellation, no-show and deposit.","BR-004","Must","R1","setup.rateplan.manage","A3",
  "a rate plan with a cancellation rule of one night inside two days","a guest cancels one day before arrival","one night is charged",
  "rate_plans, rate_plan_prices, night_price, policy_fee","13","Built+tested")
r("SET-005","Setup","SET-05","Tax lines with rate, base (net or net plus prior taxes), applicable revenue groups and a verified flag.","BR-013","Must","R1","setup.tax.manage","A11",
  "service charge 10% then VAT 7.5% on price plus service charge","a charge of 10,000 is posted","tax lines of 1,000 and 825 are posted; inclusive prices solve back to the same net",
  "tax_rates, compute_taxes","12","Built+tested")
r("SET-006","Setup","SET-05","Charge codes and payment methods per property.","BR-013","Must","R1","setup.tax.manage","Rule: Payments in R1",
  "a property","staff post a charge or a payment","only active codes and methods of that property are accepted",
  "charge_codes, payment_methods","12","Built+tested")
r("SET-007","Setup","SET-05","Exchange rates per property per day, entered by hand.","BR-013","Should","R1","setup.fx.manage","Rule: Multi-currency; A10",
  "USD at 1,500","a guest pays USD 10","the row stores amount, currency, rate 1,500 and a base amount of 15,000; a currency without a rate is refused",
  "set_exchange_rate, fx_rate","12","Built+tested")
r("SET-008","Setup","SET-01","Inspection can be switched off per property.","BR-011","Should","R1","setup.property.manage","Transition: Room Condition Cleaning to Ready",
  "inspection_required is false","an attendant completes a task","the room is Ready at once and the task closes itself",
  "complete_hk_task","17","Built+tested")

# ---------------- Reservations
r("RES-001","Reservations","RES-01, RES-04","Availability is calculated per room type and night from sellable rooms less held bookings.","BR-004","Must","R1","res.availability.view","Rule: Room condition vs sellability",
  "three standard rooms and three bookings for a night","staff search that night","availability is zero; approved blocks reduce sellable rooms; dirty rooms do not",
  "get_availability, holds_inventory","13, 14","Built+tested")
r("RES-002","Reservations","RES-02","Create a reservation for one room type and rate plan, priced night by night.","BR-004, BR-007","Must","R1","res.create","Transition: Reservation new to Inquiry/Tentative/Confirmed",
  "a room type with a rate","staff create a two-night booking","nights are priced from the rate plan, a folio is opened, and the same idempotency key returns the same booking",
  "create_reservation","13","Built+tested")
r("RES-003","Reservations","RES-02","A sold-out room type cannot be booked, and occupancy and stay-length limits are enforced.","BR-004, BR-005","Must","R1","res.create","-",
  "a sold-out night","staff book it","the booking is refused with E_UNAVAILABLE; too many guests gives E_OCCUPANCY; past arrival gives E_DATES",
  "assert_available (advisory lock per property and room type)","13","Built+tested")
r("RES-004","Reservations","RES-03","Modify dates, room type, rate plan or guest count before check-in; the stay is repriced and inventory follows.","BR-004","Must","R1","res.edit","Transition: Reservation edit",
  "a confirmed booking","staff shorten it by a night","the total is repriced and the night is released; an in-house booking cannot be edited this way",
  "modify_reservation","13","Built+tested")
r("RES-005","Reservations","RES-02, RES-03","A tentative booking holds inventory until its hold expires, then is released at the next roll; confirming ends the hold.","BR-004","Must","R1","res.create, res.edit","Transition: Tentative to Confirmed / Cancelled",
  "a tentative booking with a 1-hour hold","the hold passes and the roll runs","the booking is cancelled with reason 'Hold expired' and inventory is free",
  "create_reservation, confirm_reservation, roll_business_date","17","Built+tested")
r("RES-006","Reservations","RES-03","Cancel with a reason; the fee follows the rate plan; only a permitted user can waive it.","BR-004, BR-015","Must","R1","res.cancel, res.rate.override","Transition: Confirmed to Cancelled",
  "a booking inside the free-cancellation window","staff cancel it","one night's fee is posted to the folio; a cancellation outside the window is free; waiving the fee needs res.rate.override",
  "cancel_reservation","13","Built+tested")
r("RES-007","Reservations","RES-03, FO-01","No-show can be marked by hand or by the automatic roll, with the fee from the rate plan.","BR-004","Must","R1","res.noshow.mark","Transition: Confirmed to No-show; A2",
  "a confirmed booking whose arrival date is today","staff mark it no-show, or the roll runs","the booking is No-show, the fee is posted once and the room hold is released; a guest not yet due cannot be marked",
  "mark_no_show, no_show_internal, roll_business_date","13, 14","Built+tested")
r("RES-008","Reservations","RES-03","Reinstate a cancelled or no-show booking when inventory allows.","BR-004","Should","R1","res.reinstate","Transition: Cancelled/No-show to Confirmed",
  "a cancelled booking with the room type still available","a manager reinstates it with a reason","it is Confirmed again and its folio reopens; if the type is full it is refused",
  "reinstate_reservation","13","Built+tested")
r("RES-009","Reservations","RES-02","Rate override needs its own permission and a reason, and is audited.","BR-015, BR-018","Must","R1","res.rate.override","Rule: Reasons",
  "a front desk officer without the permission","they set a custom rate","the request is refused; a manager with a reason sets the rate and the override is audited",
  "create_reservation, modify_reservation","13, 17","Built+tested")
r("RES-010","Reservations","RES-02","A deposit rule on the rate plan sets the deposit required.","BR-013","Must","R1","res.deposit.request","Rule: Payments in R1",
  "a rate plan asking for 50% deposit","a two-night booking is made","the deposit required is half the stay and the guarantee type is deposit",
  "create_reservation","13","Built+tested")
r("RES-011","Reservations","RES-02","Corporate business is a booking source plus a free-text company name plus a corporate rate plan; no company entity in R1.","BR-007, BR-024","Must","R1","res.create","A3",
  "a booking for a company","staff choose source Corporate and type the company name","the company name is saved with the booking and reports can filter on it",
  "reservations.company_name, rate_plans.is_corporate","17","Built+tested")
r("RES-012","Reservations","RES-02","A group booking is several one-room reservations sharing a group record.","BR-007","Should","R1","res.group.manage","-",
  "a group with a contact and dates","staff create reservations for the group","each reservation links to the group; each room is booked and assigned on its own",
  "group_bookings, reservations.group_id","-","Built (UI or Edge Function work remains)")
r("RES-013","Reservations","RES-03","Additional guests and an arrival-ready flag on a booking.","BR-003","Should","R1","res.edit","Rule: arrival-ready is a flag",
  "a confirmed booking","staff add a second guest and set arrival-ready","both are saved; arrival-ready never changes the status",
  "set_reservation_guests, set_arrival_ready","17","Built+tested")

# ---------------- Front office
r("FO-001","Front Office","FO-01","Arrivals due today or overdue, with guest, room type, guarantee and assigned room.","BR-006","Must","R1","fo.board.view","-",
  "a confirmed booking due today","staff open the board","it appears with the guest's name; after check-in it leaves the list",
  "v_arrivals","17","Built+tested")
r("FO-002","Front Office","FO-01","In-house guests with room, departure and balance; overdue departures flagged.","BR-006","Must","R1","fo.board.view","-",
  "a guest in house","staff open the board","the guest appears with room number and balance",
  "v_in_house","17","Built+tested")
r("FO-003","Front Office","FO-02","Check-in guards: confirmed booking, arrival date reached, ID recorded, registration accepted, room ready and free, deposit paid.","BR-006, BR-011","Must","R1","fo.checkin","Transition: Confirmed to Checked In",
  "a booking due today","staff check the guest in without ID, or into a dirty or occupied room, or without the deposit","each is refused with its own code; with everything in place the reservation is Checked In, the stay In-House and the room Occupied",
  "check_in","13","Built+tested")
r("FO-004","Front Office","FO-02","Walk-in check-in creates the booking and checks in in one step.","BR-006, BR-007","Must","R1","fo.checkin.walkin","Transition: (walk-in) to Checked In",
  "a free ready room","staff check in a walk-in guest","a confirmed walk-in booking is created and the guest is checked in",
  "walk_in_check_in","13","Built+tested")
r("FO-005","Front Office","RES-03, FO-01","Assign a room before arrival; two overlapping stays can never hold the same room.","BR-005","Must","R1","fo.room.assign","Transition: Room Assignment none to Held",
  "a room held for a booking","staff assign it to an overlapping booking","the database refuses with E_ROOM_TAKEN; a room of the wrong type is refused with E_ROOM_TYPE",
  "assign_room; exclusion constraint no_overlapping_room_use","13","Built+tested")
r("FO-006","Front Office","FO-04","Move a guest to another room; the old room turns dirty with a turnover task; the stay and folio carry over.","BR-006, BR-010","Must","R1","fo.roommove","Transition: Room Assignment Active to Ended",
  "a guest in house and a ready room","staff move the guest with a reason","one active room at a time, old room dirty and vacant, new room occupied, task created; a dirty target is refused",
  "move_room","13","Built+tested")
r("FO-007","Front Office","FO-04","A move to a different room type reprices from tonight; a complimentary upgrade keeps the rate and needs its own permission.","BR-006","Should","R1","fo.roommove.complimentary","Transition: complimentary move",
  "a guest booked in a standard room","a manager upgrades them free","the booked rate stays but the night counts against deluxe inventory; a front desk officer is refused",
  "move_room","13","Built+tested")
r("FO-008","Front Office","FO-01, RES-03","Extend or shorten a stay in house; extension checks inventory, the room and blocks.","BR-006","Must","R1","fo.stay.extend","Transition: Stay extension",
  "a guest in house and the room promised to another guest","staff extend the stay","the extension is refused with E_ROOM_TAKEN; a free extension prices the new night; shortening removes unused nights",
  "extend_stay","13","Built+tested")
r("FO-009","Front Office","FO-03","Check-out needs a zero balance and no credit, or an approved exception; open folios stay open for collection.","BR-006, BR-013","Must","R1","fo.checkout, fo.checkout.unsettled.approve","Transition: In-House to Checked Out",
  "a guest who owes money","staff try to check them out","it is refused until a different person approves an exception; then the stay closes, the invoice shows the balance and the folio stays open; a credit balance must be refunded first",
  "check_out, request_unsettled_checkout","13, 14","Built+tested")
r("FO-010","Front Office","FO-03","Check-out sets the room Dirty and Vacant and creates a turnover task; leaving early releases the unused nights.","BR-010","Must","R1","fo.checkout","Transition: Room Condition Ready to Dirty",
  "a guest checks out","the check-out completes","the room is Dirty and Vacant, a turnover task exists, the folio closes and an invoice is issued",
  "check_out, create_turnover_task","13, 14","Built+tested")
r("FO-011","Front Office","FO-03","Undo a check-out on the same business date.","BR-006","Should","R1","fo.checkout.reverse","Transition: Checked Out to Checked In",
  "a guest checked out today and the room not yet being cleaned","a manager undoes it with a reason","the guest is in house, the room occupied, the task cancelled and the folio open; a front desk officer is refused",
  "undo_checkout","13","Built+tested")
r("FO-012","Front Office","FO-02","Void a check-in on the same business date when no charges are posted.","BR-006","Should","R1","fo.checkout.reverse","Transition: Stay In-House to Voided",
  "a check-in made in error today","a manager voids it with a reason","the stay is Voided, the booking Confirmed, the room vacant and held; the guest can be checked in again",
  "void_check_in","17","Built+tested")
r("FO-013","Front Office","ROOM-01","Room board shows each room as occupied, vacant by condition, out of order or out of service.","BR-009","Must","R1","room.view","Rule: Room condition vs sellability",
  "a guest in a room","staff open the room board","the room shows occupied",
  "v_room_board","17","Built+tested")

# ---------------- Guests
r("GST-001","Guests","GST-01, GST-02","One guest profile per person across stays; search by name, phone, email or ID number.","BR-003, BR-008","Must","R1","guest.view, guest.create, guest.edit","-",
  "guests exist","front desk searches by surname","the guest is found; a role without guest.view finds nothing",
  "guests, search_guests","15","Built+tested")
r("GST-002","Guests","GST-02","ID documents are stored apart and shown only to roles that may see them.","BR-017","Must","R1","guest.idocs.view","-",
  "a recorded passport number","a reservation officer opens the guest","they see the profile but no ID documents",
  "guest_documents policies","17","Built+tested")
r("GST-003","Guests","GST-02","Personal data never appears in audit records; only the names of changed fields do.","BR-018","Must","R1","-","Rule: Personal data and the ledger",
  "a phone number is changed","the audit trail is read","it says the phone changed, not what the number was",
  "audit_change_pii","15","Built+tested")
r("GST-004","Guests","GST-02","Merge duplicate guest profiles; history moves to the kept profile.","BR-003","Should","R1","guest.merge","-",
  "two profiles for one person","a manager merges them with a reason","reservations and folios point to the kept profile and the duplicate is emptied",
  "merge_guests","15","Built+tested")
r("GST-005","Guests","GST-02","Anonymise a guest on request; the ledger and stay history stay intact.","BR-003, BR-014","Should","R1","guest.merge","Rule: Personal data and the ledger",
  "a guest with no current or upcoming stay","a manager anonymises them","name, contact and documents are removed and cannot be restored from the app; reservations remain",
  "anonymise_guest","15","Built+tested")
r("GST-006","Guests","GST-02","Feedback and complaints logged against a guest.","BR-008","Should","R1","guest.complaint.manage","-",
  "a guest complaint","staff log it","it is saved with the guest and shown on the profile",
  "guest_feedback (direct write with RLS)","-","Built (UI or Edge Function work remains)")

# ---------------- Rooms
r("ROOM-001","Rooms","ROOM-01, ROOM-02","Room condition and occupancy are separate, are set only by the system or a controlled action, and cannot be written by hand.","BR-009","Must","R1","room.view","Rule: Room condition vs sellability",
  "any user","they try to update condition or occupancy directly","the update is refused with permission denied",
  "column grants; rooms","14, 16","Built+tested")
r("ROOM-002","Rooms","ROOM-03","Out-of-order and out-of-service blocks; a request from maintenance needs approval, an approver's own request does not.","BR-012","Must","R1","room.block.request, room.block.approve, room.block.release","Transition: Room Block",
  "a maintenance officer requests a block","a manager approves it","the room leaves availability for those nights; a requested block does not; releasing returns it",
  "request_room_block, decide_approval, release_room_block","14","Built+tested")
r("ROOM-003","Rooms","ROOM-03","A block cannot cover a night a guest is assigned, and cannot oversell the room type.","BR-005, BR-012","Must","R1","room.block.request","-",
  "a room assigned to a guest or the last room of a type","staff block it","the block is refused with E_ROOM_TAKEN or E_OVERSOLD",
  "request_room_block, assert_not_oversold","14, 17","Built+tested")
r("ROOM-004","Rooms","ROOM-02","A supervisor can override a room's condition with a reason; it is audited.","BR-018","Should","R1","room.status.override","Rule: Reasons",
  "a dirty room a manager has inspected","the manager marks it ready with a reason","the room is Ready and the override is in the audit trail; front desk is refused",
  "set_room_condition","13, 14","Built+tested")

# ---------------- Housekeeping
r("HK-001","Housekeeping","HK-01","Check-out and room moves create a turnover task; the board lists open tasks.","BR-010","Must","R1","hk.board.view","Transition: Ready to Dirty",
  "a guest checks out","the check-out completes","a pending turnover task exists for the room; an older unfinished task is superseded",
  "create_turnover_task, v_hk_board","13, 14","Built+tested")
r("HK-002","Housekeeping","HK-01, HK-02","Assign, start and complete cleaning tasks; an attendant sees only their own tasks.","BR-010","Must","R1","hk.task.assign, hk.task.execute","Transition: Dirty to Cleaning to Awaiting Inspection",
  "a pending task","a supervisor assigns it and the attendant starts and completes it","the room goes Cleaning then Awaiting Inspection; an attendant cannot start another person's task",
  "assign_hk_task, start_hk_task, complete_hk_task","14, 17","Built+tested")
r("HK-003","Housekeeping","HK-03","Inspection passes to Ready or fails with a reason and goes to rework.","BR-011","Must","R1","hk.inspect","Transition: Awaiting Inspection to Ready / Cleaning",
  "a completed task","the inspector fails it with a reason","the room is Dirty, the task is in rework and the attendant is notified; a pass makes it Ready",
  "inspect_hk_task","14","Built+tested")
r("HK-004","Housekeeping","HK-03","Nobody inspects their own cleaning.","BR-015","Must","R1","hk.inspect","Rule: Separation of duties",
  "a supervisor who cleaned a room","they inspect it","it is refused with E_SOD",
  "inspect_hk_task","14","Built+tested")
r("HK-005","Housekeeping","HK-01","Stayover cleaning tasks are planned at the roll for guests staying on.","BR-010","Should","R1","(system)","Transition: stayover; Rule: Business date",
  "a guest in house who stays another night","the roll runs","a stayover task exists for the new day; a departing guest gets none",
  "roll_business_date","14","Built+tested")
r("HK-006","Housekeeping","(lost & found)","Lost and found items are logged and tracked to return or disposal.","BR-013","Should","R1","hk.lostfound.manage","-",
  "a found item","housekeeping logs it","it is saved with room, date and status",
  "lost_found_items (direct write with RLS)","16","Built+tested")

# ---------------- Maintenance
r("MNT-001","Maintenance","MNT-01, MNT-02","Tickets move from open to assigned, in progress, waiting, resolved and closed; waiting needs a reason.","BR-012","Must","R1","mnt.ticket.create, mnt.ticket.manage, mnt.ticket.work","States: Maintenance Ticket",
  "a ticket","it is assigned, started, paused with a reason, resumed and resolved","each step follows the allowed path and a ticket assigned to someone else cannot be started by another person",
  "create_ticket, assign_ticket, start_ticket, wait_ticket, resolve_ticket","14","Built+tested")
r("MNT-002","Maintenance","MNT-02","The person who resolved a ticket cannot close it; closing releases its room block.","BR-015, BR-012","Must","R1","mnt.ticket.close","Rule: Separation of duties",
  "a resolved ticket with a room block","its resolver tries to close it, then a supervisor does","the first is refused with E_SOD; the second closes it and releases the block",
  "close_ticket","14","Built+tested")
r("MNT-003","Maintenance","MNT-02","Tickets can be reopened or cancelled, each with a reason.","BR-012","Should","R1","mnt.ticket.manage, mnt.ticket.cancel","States: Maintenance Ticket",
  "a resolved ticket","a maintenance officer reopens it or cancels it","the status changes and the reason is audited; housekeeping cannot cancel",
  "reopen_ticket, cancel_ticket","17","Built+tested")

# ---------------- Guest service
r("SVC-001","Guest Service","FO-01","Guest requests are captured, assigned, progressed and completed.","BR-006","Should","R1","svc.request.create, svc.request.manage","Workflow WF05",
  "a guest in house","staff log a request and it is assigned, started and completed","it is tied to the guest's room and finishes once",
  "create_service_request, assign_service_request, start_service_request, complete_service_request","17","Built+tested")
r("SVC-002","Guest Service","FO-01, FIN-01","A chargeable request posts its charge, with tax, to the folio when completed.","BR-013","Should","R1","svc.request.manage, fin.charge.post","Workflow WF05",
  "a chargeable laundry request of 3,000","it is completed","3,000 plus tax is posted once to the guest's folio",
  "complete_service_request","17","Built+tested")

# ---------------- Finance
r("FIN-001","Finance","FIN-01","Charges post with their tax lines; prices can include or exclude tax; the remainder of a rounding goes on the last tax line.","BR-013","Must","R1","fin.charge.post","Rule: Business date",
  "service charge 10% and VAT 7.5%","a charge of 10,000 or an inclusive 11,825 is posted","the folio owes 11,825 with a net of 10,000 either way",
  "post_charge, compute_taxes, insert_with_tax","12","Built+tested")
r("FIN-002","Finance","FIN-01","Payments and deposits are recorded against a folio with a method; payments are taken outside the system in R1.","BR-013","Must","R1","fin.payment.post, fin.deposit.take","Rule: Payments in R1",
  "a folio with a balance","staff record a cash payment or a deposit","the balance falls; a role without the matching permission is refused",
  "post_payment","12","Built+tested")
r("FIN-003","Finance","FIN-01","Foreign-currency postings store the amount, currency, exchange rate and base amount.","BR-013","Should","R1","fin.payment.post","Rule: Multi-currency",
  "USD 10 at 1,500","it is posted","the row shows the rate and 15,000 in the base currency; the amount must respect the currency's decimals",
  "insert_txn, fx_rate","12","Built+tested")
r("FIN-004","Finance","FIN-01","A discount within the user's limit posts at once; above the limit it waits for an approver who is not the requester.","BR-015","Must","R1","fin.discount.apply, fin.discount.approve","Rule: Limits; Separation of duties",
  "a front desk limit of 5,000","they apply 3,000 then 8,000","the first posts; the second is pending, does not change the balance and can be approved or rejected (with a reason) by a manager",
  "apply_discount, decide_approval","12","Built+tested")
r("FIN-005","Finance","FIN-01","Adjustments, reversals and refunds always need a second person and stay within the approver's limit.","BR-015","Must","R1","fin.adjust.post, fin.adjust.approve, fin.reverse.post, fin.refund.post, fin.refund.approve","Rule: Separation of duties, Limits",
  "an adjustment of 50,000 requested by a cashier","a manager with a 20,000 limit approves","it is refused with E_LIMIT; a senior approver can; nobody approves their own request",
  "request_adjustment, request_reversal, request_refund, decide_approval; check constraint approver_is_not_requester","12","Built+tested")
r("FIN-006","Finance","FIN-01","A posted transaction is never edited or deleted; corrections are linked reversal, adjustment or refund rows.","BR-014, BR-015","Must","R1","-","Rule: Immutability",
  "a posted charge","anyone, including the database owner, changes or deletes it","the change is refused with E_IMMUTABLE; a reversal posts a linked row (with its tax lines) and a charge reverses only once",
  "txn_guard triggers; request_reversal","12","Built+tested")
r("FIN-007","Finance","FIN-01","A refund cannot exceed the credit on the folio.","BR-015","Must","R1","fin.refund.post","-",
  "a folio with a small credit","staff request a bigger refund","it is refused with E_REFUND_LIMIT; a refund within the credit is approved and pays out",
  "request_refund","12","Built+tested")
r("FIN-008","Finance","FIN-01","Repeating the same request cannot double post (idempotency keys).","BR-013","Must","R1","-","Rule: Offline-ready design; A12",
  "a charge posted with a key","the same request arrives again","the second returns the first and the balance is unchanged",
  "idempotency_key unique per tenant","12, 13","Built+tested")
r("FIN-009","Finance","FIN-01","Move a posted charge, with its tax, to another folio of the same booking; revenue does not change.","BR-013","Should","R1","fin.folio.transfer","-",
  "a charge on the guest folio","a manager transfers it to a company folio","the target owes the charge and tax, the source is relieved, the total is unchanged and the charge moves once",
  "transfer_transaction","12","Built+tested")
r("FIN-010","Finance","FIN-01","Split folios per reservation.","BR-013","Should","R1","fin.folio.split","-",
  "a reservation","staff add a Company folio","charges can be posted to either folio and check-out settles both",
  "split_folio","12, 13","Built+tested")
r("FIN-011","Finance","FIN-01","A folio closes only at a zero balance and reopens only for the accountant with a reason; a closed folio takes no postings.","BR-013, BR-015","Must","R1","fin.invoice.issue, fin.folio.reopen","Rule: Reasons",
  "a settled folio","it is closed and then a posting is attempted","the posting is refused with E_FOLIO_CLOSED; reopening needs the permission and a reason and is audited",
  "close_folio, reopen_folio","12","Built+tested")
r("FIN-012","Finance","FIN-01, FO-03","Invoices and receipts are numbered documents built from posted rows; they cannot be changed once issued.","BR-013","Must","R1","fin.invoice.issue","-",
  "a settled folio","an invoice is issued","the total, tax and balance match the folio and the invoice cannot be edited; interim receipts have their own number series",
  "issue_invoice","12, 17","Built+tested")
r("FIN-013","Finance","FIN-01","Balances are calculated from posted rows and never stored; pending approvals do not change them.","BR-013","Must","R1","fin.folio.view","Rule: Immutability",
  "a pending discount","the balance is read","it is unchanged until the approval posts",
  "v_folio_balances","12","Built+tested")
r("FIN-014","Finance","FIN-01","Every posting takes the open business date, and a past date is refused.","BR-013","Must","R1","-","Rule: Business date",
  "a posting for a past date","it is inserted","it is refused with E_DATE",
  "txn_guard","12","Built+tested")
r("FIN-015","Finance","FIN-01","Folio visibility follows the role: managers see all folios, a reservation officer sees only those of their own bookings.","BR-017","Must","R1","fin.folio.view","Own-record scope",
  "a reservation officer","they read a colleague's folio","they see nothing; they can still take a deposit",
  "can_see_folio","12","Built+tested")
r("FIN-016","Finance","FIN-02","Cashier shifts and reconciliation by cashier, shift and method.","BR-016","Should","R2","fin.shift.manage, fin.shift.reconcile","-",
  "a cashier shift","the shift is closed","payments reconcile by method","(not in R1)","-","R1b")

# ---------------- Business date
r("DAY-001","Business Date","(system)","The business date rolls automatically at each property's cut-off time.","BR-019","Must","R1","audit.businessdate.view","Rule: Business date; A2",
  "a property whose cut-off has passed","the scheduler runs","the date advances one day, up to three days per run; the roll is logged",
  "roll_business_date, run_due_rollovers (pg_cron)","14","Built+tested")
r("DAY-002","Business Date","(system)","At the roll, each guest in house is charged the night's room rate and tax exactly once.","BR-013","Must","R1","(system)","Rule: Business date",
  "two guests in house","the roll runs","each folio gets one room charge for the closing date, with tax; running it again for the same night cannot repeat it",
  "roll_business_date; idempotency keys room:<reservation>:<date>","14","Built+tested")
r("DAY-003","Business Date","(system)","A guest still in house past departure is charged and extended a night if the room allows; otherwise managers are told.","BR-013","Should","R1","(system)","-",
  "a guest due out today who is still in house","the roll runs","the departure moves one day and the night is charged",
  "roll_business_date","14","Built+tested")
r("DAY-004","Business Date","(system)","A failed roll changes nothing and notifies managers; other properties are not blocked.","BR-013","Must","R1","audit.businessdate.view","-",
  "a property whose roll fails","the scheduler runs","its date is unchanged and managers get a notification",
  "run_due_rollovers","17","Built+tested")
r("DAY-005","Business Date","FIN-03","Night audit gates the roll from R2.","BR-016","Should","R2","audit.night.run","A2",
  "R2","-","-","(not in R1)","-","R1b")
r("DAY-006","Business Date","(system)","A same-day arrival and departure: decide whether a night or day-use charge applies.","BR-013","Should","R1","(decision)","-",
  "a guest checks in and out on the same business date","they leave before the roll","today no room charge is made; the desk can post a manual charge",
  "check_out","13","Decision needed")

# ---------------- Reporting
r("RPT-001","Reporting","DASH-01, REP-01","Occupancy, ADR and RevPAR use one definition: rooms sold over rooms available (out-of-order rooms excluded), revenue net of tax.","BR-019","Must","R1","dash.view_exec, rep.ops.view","KPI Dictionary",
  "a closed day","management opens the KPI view","occupancy, ADR and RevPAR equal sold, revenue and available as defined; tax is shown apart",
  "daily_stats, v_kpi_daily","14","Built+tested")
r("RPT-002","Reporting","DASH-02","Live operations views: arrivals, in-house, room board, housekeeping board.","BR-006, BR-019","Must","R1","dash.view_ops","-",
  "activity in the hotel","staff open the operations dashboard","the views return only rows the user may see",
  "v_arrivals, v_in_house, v_room_board, v_hk_board","17","Built+tested")
r("RPT-003","Reporting","REP-01, REP-02","Every reported figure traces to ledger rows or operational records.","BR-020","Must","R1","rep.ops.view, rep.fin.view","-",
  "a daily figure","an auditor recomputes it from folio_transactions","the figures agree",
  "daily_stats computed from folio_transactions","14","Built+tested")
r("RPT-004","Reporting","REP-01, REP-02","Report screens (occupancy trend, revenue by group, outstanding balances, cancellation and no-show rates).","BR-019","Must","R1","rep.ops.view, rep.fin.view","KPI Dictionary",
  "a date range","a manager opens a report","the numbers match the KPI definitions","(views for cancellation rate, ALOS and outstanding balances still to add)","-","Built (UI or Edge Function work remains)")

# ---------------- Non-functional
r("NFR-001","Non-functional","(all)","Every table has row-level security and tenant_id; security definer functions pin their search path.","BR-017","Must","R1","-","Rule: Tenant isolation",
  "a migration adds a table or function","the test suite runs","it fails if RLS, tenant_id or search_path is missing",
  "structure tests","16","Built+tested")
r("NFR-002","Non-functional","(all)","The browser can write directly only to plain configuration tables; ledger, reservations, stays, tasks and blocks change only through functions.","BR-014, BR-017","Must","R1","-","Rule: Immutability",
  "any user","they write to a ledger or state table","permission denied; the list of directly writable tables is asserted by a test",
  "20260928001100_grants.sql","16","Built+tested")
r("NFR-003","Non-functional","(all)","Create actions accept client-generated ids and idempotency keys so an offline queue can be added later.","BR-001","Should","R1","-","Rule: Offline-ready design; A12",
  "a repeated create request","it arrives twice","only one record exists",
  "idempotency keys; client ids allowed on insert","12, 13","Built+tested")
r("NFR-004","Non-functional","(all)","Money uses fixed decimals per currency (naira 2, CFA franc 0), never floating point.","BR-013","Must","R1","-","A10",
  "an amount with too many decimals","it is posted","it is refused with E_PRECISION",
  "numeric(20,4), currencies.decimals","12","Built+tested")
r("NFR-005","Non-functional","(all)","Business date and cut-off follow the property's timezone.","BR-019","Must","R1","-","A2",
  "a property in Lagos","it is created just before or after cut-off","the business date is the local hotel day, not the server's day",
  "local_business_date","14, 17","Built+tested")
