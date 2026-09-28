from fnmatch import fnmatch

# code, name, maps to (actor / BRD owner), release, scope, note
ROLES = [
 ("PSA","Platform Super Admin","A20","R1","Platform (all tenants)","Runs the SaaS platform: creates tenants (hotel organisations), plans, suspends tenants, platform audit. No access to any tenant's guest, room or financial data. Break-glass support access is time-boxed, audited and notifies the tenant."),
 ("SYS","System Administrator","A19","R1","Tenant or property (assigned)","Tenant administrator. Configuration, users, roles, audit view, creates properties when assigned at tenant scope. No operational or financial posting rights."),
 ("OWN","Hotel Owner / Investor","A01","R1","Tenant or property (assigned)","Read-only management view. Added: the earlier matrix had no row for A01."),
 ("GM","General Manager","A02","R1","Property (assigned)","Oversight and top-level approvals and overrides. Not a data-entry role."),
 ("FOM","Front Office Manager","BRD owners: Front Office Manager, Reservation Manager, Guest Relations","R1","Property (assigned)","Front office supervisor with first-level approvals. Added: BRD names these owners but no role existed."),
 ("FDO","Front Desk Officer","A03","R1","Property (assigned)","Arrivals, departures, check-in/out, folio entry within limits."),
 ("RSV","Reservation Officer","A04","R1","Property (assigned)","Availability, bookings, amendments, deposit requests."),
 ("REV","Revenue Manager","BRD owner: Revenue Manager; screen SET-04","R1","Property (assigned)","Rate plans and rate overrides. Added: SET-04 named a Revenue user with no role."),
 ("HKS","Housekeeping Supervisor","A05; BRD owner: Housekeeping Manager","R1","Property (assigned)","Assign, inspect, release rooms."),
 ("ATT","Room Attendant","A06","R1","Own assigned tasks","Mobile task execution only."),
 ("MNT","Maintenance Officer","A07; BRD owner: Engineering Manager","R1","Property (assigned)","Tickets, work, block requests."),
 ("CSH","Cashier","A10","R1","Property; own shift (R2)","Payments and folio postings."),
 ("NAU","Night Auditor","Screen FIN-03","R2","Property (assigned)","Runs night audit from R2. Added: FIN-03 named Finance/GM only, which is not workable overnight."),
 ("ACC","Accountant / Finance","A11; BRD owner: Finance Manager","R1","Property (assigned)","Financial control, approvals, reopen, reconciliation."),
 ("SLS","Sales Manager","A14","R2","Property (assigned)","Company accounts, credit and pipeline in R2. In R1 can create and edit reservations."),
 ("EVT","Event Manager","A15","R2","Property (assigned)","Events and group billing."),
 ("HRA","HR / Administrator","A16","R2","Property (assigned)","Employee records. Creates user records but does not assign roles."),
 ("FNB","F&B Staff","A08","R2","Outlet","Orders and room charges."),
 ("KIT","Kitchen Staff","A09","R2","Outlet","Kitchen display."),
 ("PRC","Procurement Officer","A12","R2","Property (assigned)","Creates POs. Cannot approve them."),
 ("STK","Storekeeper","A13","R2","Store","Stock movements and receipts."),
 ("DEP","Department Head","Screen PROC-01","R2","Own department","Raises and approves department purchase requests. Added: PROC-01 named 'Department' with no role."),
 ("GST","Guest","A17","R3","Own records","Self-service portal."),
]

# key, module, release, description, sensitive (S = reason + audit event)
PERMS = [
 ("platform.tenant.manage","PLT","R1","Create, configure, suspend tenants; provision first tenant admin","S"),
 ("platform.plan.manage","PLT","R1","Manage subscription plans and limits","S"),
 ("platform.support.access","PLT","R1","Break-glass access into a tenant (time-boxed, reason, tenant notified)","S"),
 ("platform.audit.view","PLT","R1","View platform-level audit log",""),
 ("platform.billing.manage","PLT","R1","Activate, extend or invoice a tenant manually; issue credits","S"),
 ("org.subscription.manage","M15","R1","View plan and usage; change plan; cancel subscription","S"),
 ("org.billing.paymentmethod","M15","R1b","Manage subscription payment method and view invoices",""),
 ("org.property.create","M02","R1","Create additional properties inside a tenant","S"),
 ("dash.view_exec","M01","R1","View executive dashboard (KPIs, revenue)",""),
 ("dash.view_ops","M01","R1","View operations dashboard (arrivals, departures, readiness, queues)",""),
 ("setup.view","M02","R1","View property configuration (room types, rates, taxes)",""),
 ("setup.property.manage","M02","R1","Create/edit property profile, timezone, currency","S"),
 ("setup.roomtype.manage","M02","R1","Create/edit room types",""),
 ("setup.room.manage","M02","R1","Create/edit physical rooms, buildings, floors",""),
 ("setup.rateplan.manage","M02","R1","Create/edit rate plans, restrictions, cancellation rules","S"),
 ("setup.tax.manage","M02","R1","Create/edit taxes and service charges","S"),
 ("setup.fx.manage","M02","R1","Enter daily exchange rates",""),
 ("setup.policy.manage","M02","R1","Manage departments, outlets, policies, readiness rules",""),
 ("res.availability.view","M03","R1","Search availability and view reservation calendar",""),
 ("res.view","M03","R1","View reservations",""),
 ("res.create","M03","R1","Create reservations",""),
 ("res.edit","M03","R1","Modify reservations (reprices where applicable)",""),
 ("res.cancel","M03","R1","Cancel reservation","S"),
 ("res.noshow.mark","M03","R1","Mark reservation as no-show manually","S"),
 ("res.reinstate","M03","R1","Reinstate a cancelled or no-show reservation","S"),
 ("res.rate.override","M03","R1","Override the rate plan price","S"),
 ("res.group.manage","M03","R1","Create and manage group bookings and rooming lists",""),
 ("res.deposit.request","M03","R1","Set deposit or guarantee requirement on a reservation",""),
 ("fo.board.view","M04","R1","View front desk board",""),
 ("fo.checkin","M04","R1","Check in a reservation",""),
 ("fo.checkin.walkin","M04","R1","Create and check in a walk-in",""),
 ("fo.checkout","M04","R1","Check out a guest (folio must be settled)",""),
 ("fo.checkout.unsettled.approve","M04","R1","Approve checkout with an open balance","S"),
 ("fo.checkout.reverse","M04","R1","Undo a checkout on the same business date","S"),
 ("fo.room.assign","M04","R1","Assign or reassign a room before arrival",""),
 ("fo.roommove","M04","R1","Move a guest to another room",""),
 ("fo.roommove.complimentary","M04","R1","Move or upgrade with no price change","S"),
 ("fo.stay.extend","M04","R1","Extend or shorten a stay",""),
 ("svc.request.create","M04","R1","Log a guest service request",""),
 ("svc.request.manage","M04","R1","Assign, progress and complete service requests",""),
 ("guest.view","M05","R1","View guest profile and history",""),
 ("guest.create","M05","R1","Create guest profile",""),
 ("guest.edit","M05","R1","Edit guest profile",""),
 ("guest.idocs.view","M05","R1","View identity document details","S"),
 ("guest.merge","M05","R1","Merge duplicate guest profiles","S"),
 ("guest.complaint.manage","M05","R1","Record and resolve complaints and feedback",""),
 ("room.view","M06","R1","View room board and room detail",""),
 ("room.status.update","M06","R1","Change room condition through allowed transitions",""),
 ("room.status.override","M06","R1","Force a room condition outside allowed transitions","S"),
 ("room.block.request","M06","R1","Request an Out of Order / Out of Service block",""),
 ("room.block.approve","M06","R1","Approve or reject a room block","S"),
 ("room.block.release","M06","R1","Release an active block",""),
 ("hk.board.view","M07","R1","View housekeeping board",""),
 ("hk.task.assign","M07","R1","Create and assign cleaning tasks",""),
 ("hk.task.execute","M07","R1","Start and complete cleaning tasks",""),
 ("hk.inspect","M07","R1","Inspect rooms; pass or fail",""),
 ("hk.lostfound.manage","M07","R1","Log and release lost and found items",""),
 ("mnt.view","M08","R1","View maintenance board and tickets",""),
 ("mnt.ticket.create","M08","R1","Report an issue / create ticket",""),
 ("mnt.ticket.manage","M08","R1","Prioritise, assign and reopen tickets",""),
 ("mnt.ticket.work","M08","R1","Work and resolve tickets",""),
 ("mnt.ticket.close","M08","R1","Verify and close resolved tickets",""),
 ("mnt.ticket.cancel","M08","R1","Cancel invalid or duplicate ticket","S"),
 ("fin.folio.view","M12","R1","View folios",""),
 ("fin.charge.post","M12","R1","Post a charge",""),
 ("fin.payment.post","M12","R1","Post a payment",""),
 ("fin.deposit.take","M12","R1","Take a deposit",""),
 ("fin.discount.apply","M12","R1","Apply a discount (limit-based)","S"),
 ("fin.discount.approve","M12","R1","Approve discounts above limit","S"),
 ("fin.adjust.post","M12","R1","Initiate an adjustment","S"),
 ("fin.adjust.approve","M12","R1","Approve an adjustment","S"),
 ("fin.reverse.post","M12","R1","Initiate a reversal of a posted transaction","S"),
 ("fin.refund.post","M12","R1","Initiate a refund","S"),
 ("fin.refund.approve","M12","R1","Approve a refund","S"),
 ("fin.folio.transfer","M12","R1","Transfer transactions between folios","S"),
 ("fin.folio.split","M12","R1","Create additional folio for a stay",""),
 ("fin.folio.reopen","M12","R1","Reopen a closed folio","S"),
 ("fin.invoice.issue","M12","R1","Issue invoice or receipt",""),
 ("audit.businessdate.view","M12","R1","View current business date and audit status",""),
 ("audit.night.run","M12","R2","Run night audit","S"),
 ("audit.night.override","M12","R2","Close night audit with unresolved exceptions","S"),
 ("fin.shift.manage","M12","R2","Open and close own cashier shift",""),
 ("fin.shift.reconcile","M12","R2","Reconcile shifts and approve variance","S"),
 ("sales.company.manage","M13","R2","Create/edit company accounts and negotiated rate links",""),
 ("sales.credit.approve","M13","R2","Approve credit terms / direct bill","S"),
 ("sales.pipeline.manage","M13","R2","Manage leads and pipeline",""),
 ("sales.event.manage","M13","R2","Manage events and venues",""),
 ("pos.order.manage","M09","R2","Create and settle POS orders",""),
 ("pos.roomcharge","M09","R2","Post POS order to a room folio",""),
 ("pos.discount","M09","R2","Apply POS discount","S"),
 ("pos.kitchen.update","M09","R2","Update order status on kitchen display",""),
 ("inv.view","M10","R2","View stock",""),
 ("inv.move","M10","R2","Receive, issue, transfer, adjust, count stock","S"),
 ("inv.count.approve","M10","R2","Approve stock count variance","S"),
 ("proc.request.create","M11","R2","Raise a purchase request",""),
 ("proc.request.approve","M11","R2","Approve a purchase request","S"),
 ("proc.po.create","M11","R2","Create a purchase order",""),
 ("proc.po.approve","M11","R2","Approve a purchase order","S"),
 ("proc.receive","M11","R2","Record goods receipt",""),
 ("hr.employee.manage","M14","R2","Manage employee records",""),
 ("hr.roster.manage","M14","R2","Manage rosters and shifts",""),
 ("adm.user.manage","M15","R1","Create, edit, disable users and set property scope","S"),
 ("adm.role.manage","M15","R1","Create and edit roles and permission sets","S"),
 ("adm.role.assign","M15","R1","Assign roles to users","S"),
 ("adm.audit.view","M15","R1","View audit log",""),
 ("adm.config.manage","M15","R1","Manage notifications and system configuration",""),
 ("data.export","M15","R1","Bulk data export","S"),
 ("rep.ops.view","M16","R1","View operations reports",""),
 ("rep.fin.view","M16","R1","View financial reports",""),
 ("rep.mgmt.view","M16","R2","View management analytics",""),
 ("rep.export","M16","R1","Export reports","S"),
 ("portal.self","M17","R3","Guest self-service on own records",""),
]

# grants: role -> list of (pattern, code). code Y full, L within configured limit, O own/assigned/linked records only
G = {}
def g(role, *items):
    G.setdefault(role, [])
    for it in items:
        if isinstance(it, tuple): G[role].append(it)
        else: G[role].append((it, "Y"))

g("PSA","platform.*")
g("SYS","setup.*","org.property.create","org.subscription.manage","org.billing.paymentmethod","adm.user.manage","adm.role.manage","adm.role.assign","adm.audit.view","adm.config.manage","data.export")
g("OWN","dash.view_exec","rep.ops.view","rep.fin.view","rep.mgmt.view","rep.export")
g("GM","dash.*","setup.view","res.availability.view","res.view","res.cancel","res.reinstate","res.rate.override",
  "fo.board.view","fo.checkout.unsettled.approve","guest.view","room.view","room.block.approve","hk.board.view","mnt.view",
  "fin.folio.view","fin.discount.approve","fin.adjust.approve","fin.refund.approve","audit.businessdate.view","audit.night.override",
  "adm.audit.view","rep.ops.view","rep.fin.view","rep.mgmt.view","rep.export","sales.credit.approve","proc.request.approve","proc.po.approve","data.export")
g("FOM","dash.*","setup.view","setup.fx.manage","res.availability.view","res.view","res.create","res.edit","res.cancel","res.noshow.mark","res.reinstate",
  "res.rate.override","res.group.manage","res.deposit.request","fo.board.view","fo.checkin","fo.checkin.walkin","fo.checkout",
  ("fo.checkout.unsettled.approve","L"),"fo.checkout.reverse","fo.room.assign","fo.roommove","fo.roommove.complimentary","fo.stay.extend","svc.*",
  "guest.view","guest.create","guest.edit","guest.idocs.view","guest.merge","guest.complaint.manage",
  "room.view","room.status.update","room.status.override","room.block.request","room.block.approve","room.block.release",
  "hk.board.view","mnt.view","mnt.ticket.create","fin.folio.view","fin.charge.post","fin.payment.post","fin.deposit.take",
  "fin.discount.apply",("fin.discount.approve","L"),"fin.adjust.post",("fin.adjust.approve","L"),"fin.reverse.post","fin.refund.post",("fin.refund.approve","L"),
  "fin.folio.transfer","fin.folio.split","fin.invoice.issue","audit.businessdate.view","rep.ops.view","rep.export")
g("FDO","dash.view_ops","setup.view","res.availability.view","res.view","res.create","res.edit","res.cancel","res.noshow.mark","res.deposit.request",
  "fo.board.view","fo.checkin","fo.checkin.walkin","fo.checkout","fo.room.assign","fo.roommove","fo.stay.extend","svc.*",
  "guest.view","guest.create","guest.edit","guest.idocs.view","guest.complaint.manage","room.view","room.block.request","mnt.ticket.create",
  "fin.folio.view","fin.charge.post","fin.payment.post","fin.deposit.take",("fin.discount.apply","L"),"fin.adjust.post","fin.reverse.post",
  "fin.folio.split","fin.invoice.issue","audit.businessdate.view","rep.ops.view")
g("RSV","setup.view","res.availability.view","res.view","res.create","res.edit","res.cancel","res.group.manage","res.deposit.request",
  "guest.view","guest.create","guest.edit","room.view",("fin.folio.view","O"),"fin.deposit.take")
g("REV","dash.view_exec","setup.view","setup.rateplan.manage","res.availability.view","res.view","res.rate.override","rep.ops.view","rep.fin.view","rep.mgmt.view","rep.export")
g("HKS","dash.view_ops","room.view","room.status.update","room.block.request","hk.*","mnt.view","mnt.ticket.create","mnt.ticket.close",
  "svc.request.manage","rep.ops.view")
g("ATT",("hk.task.execute","O"),"mnt.ticket.create",("room.view","O"),("svc.request.manage","O"))
g("MNT","room.view","room.block.request","room.block.release","mnt.*",("svc.request.manage","O"))
g("CSH","fin.folio.view","fin.charge.post","fin.payment.post","fin.deposit.take","fin.adjust.post","fin.reverse.post","fin.refund.post",
  "fin.invoice.issue","audit.businessdate.view","fin.shift.manage")
g("NAU","dash.view_ops","fo.board.view","room.view","res.noshow.mark","fin.folio.view","fin.charge.post","fin.adjust.post",
  "audit.businessdate.view","audit.night.run","rep.ops.view","rep.fin.view")
g("ACC","dash.view_exec","setup.view","setup.fx.manage","setup.tax.manage","fo.checkout.unsettled.approve","fin.folio.view","fin.adjust.post","fin.adjust.approve",
  "fin.reverse.post","fin.refund.post","fin.refund.approve","fin.discount.approve","fin.folio.reopen","fin.folio.transfer","fin.invoice.issue",
  "audit.businessdate.view","audit.night.run","audit.night.override","fin.shift.reconcile","sales.credit.approve","adm.audit.view",
  "rep.ops.view","rep.fin.view","rep.mgmt.view","rep.export","inv.count.approve","proc.po.approve")
g("SLS","setup.view","sales.company.manage","sales.pipeline.manage","res.availability.view","res.view","res.create","res.edit","res.cancel","res.group.manage",
  "guest.view","guest.create","guest.edit","rep.ops.view","rep.mgmt.view")
g("EVT","setup.view","sales.event.manage","res.group.manage","res.availability.view","res.view","res.create","res.edit","room.view",("fin.folio.view","O"))
g("HRA","hr.*","adm.user.manage")
g("FNB","pos.order.manage","pos.roomcharge",("pos.discount","L"))
g("KIT","pos.kitchen.update")
g("PRC","proc.request.create","proc.po.create","inv.view")
g("STK","inv.view","inv.move","proc.receive")
g("DEP","proc.request.create",("proc.request.approve","L"),"inv.view")
g("GST",("portal.self","O"))

def grid():
    out = {}
    for role,_,_,_,_,_ in ROLES:
        for key,_,_,_,_ in PERMS:
            code = ""
            for pat, c in G.get(role, []):
                if fnmatch(key, pat): code = c
            out[(role,key)] = code
    return out

# screen -> (name, release, stated users, required permission, roles that must hold it)
SCREENS = [
 ("DASH-01","Executive Dashboard","R1","All authorised management users","dash.view_exec",["GM","OWN","REV","ACC","FOM"]),
 ("DASH-02","Operations Dashboard","R1","GM, Front Office, Housekeeping","dash.view_ops",["GM","FDO","HKS","FOM"]),
 ("SET-01","Property Profile","R1","System Admin","setup.property.manage",["SYS"]),
 ("SET-02","Room Types","R1","System Admin","setup.roomtype.manage",["SYS"]),
 ("SET-03","Room Inventory","R1","System Admin","setup.room.manage",["SYS"]),
 ("SET-04","Rate Plans","R1","Revenue/Admin","setup.rateplan.manage",["REV","SYS"]),
 ("SET-05","Taxes & Charges","R1","Finance/Admin","setup.tax.manage",["ACC","SYS"]),
 ("RES-01","Availability Search","R1","Reservation/Front Desk","res.availability.view",["RSV","FDO"]),
 ("RES-02","New Reservation","R1","Reservation/Front Desk","res.create",["RSV","FDO"]),
 ("RES-03","Reservation Detail","R1","Reservation/Front Desk","res.view",["RSV","FDO"]),
 ("RES-04","Reservation Calendar","R1","Reservation/Front Desk","res.availability.view",["RSV","FDO"]),
 ("FO-01","Front Desk Board","R1","Front Desk","fo.board.view",["FDO"]),
 ("FO-02","Check-in","R1","Front Desk","fo.checkin",["FDO"]),
 ("FO-03","Check-out","R1","Front Desk","fo.checkout",["FDO"]),
 ("FO-04","Room Move / Upgrade","R1","Front Desk","fo.roommove",["FDO"]),
 ("GST-01","Guest Search","R1","Front Desk/Reservation","guest.view",["FDO","RSV"]),
 ("GST-02","Guest Profile","R1","Authorised Staff","guest.view",["FDO","RSV"]),
 ("ROOM-01","Room Board","R1","Front Desk/Housekeeping/Maintenance","room.view",["FDO","HKS","MNT"]),
 ("ROOM-02","Room Detail","R1","Authorised Staff","room.view",["FDO","HKS","MNT"]),
 ("ROOM-03","Room Blocks","R1","Authorised Staff","room.block.request",["HKS","MNT","FOM"]),
 ("HK-01","Housekeeping Board","R1","HK Supervisor","hk.board.view",["HKS"]),
 ("HK-02","Cleaning Task","R1","Room Attendant","hk.task.execute",["ATT"]),
 ("HK-03","Inspection","R1","HK Supervisor","hk.inspect",["HKS"]),
 ("MNT-01","Maintenance Board","R1/R2","Maintenance","mnt.view",["MNT"]),
 ("MNT-02","Maintenance Ticket","R1/R2","Maintenance","mnt.ticket.work",["MNT"]),
 ("FIN-01","Guest Folio","R1","Front Desk/Cashier/Finance","fin.folio.view",["FDO","CSH","ACC"]),
 ("ADM-01","Users","R1","System Admin","adm.user.manage",["SYS"]),
 ("ADM-02","Roles & Permissions","R1","System Admin","adm.role.manage",["SYS"]),
 ("ADM-03","Audit Log","R1","System Admin/GM","adm.audit.view",["SYS","GM"]),
 ("REP-01","Operations Reports","R1","Management","rep.ops.view",["GM","FOM","OWN"]),
 ("REP-02","Financial Reports","R1/R2","Finance/Management","rep.fin.view",["ACC","GM","OWN"]),
]
