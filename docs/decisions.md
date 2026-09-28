# Decisions log

Newest changes go at the bottom of each row's notes. Date format is day month year.

| Ref | Decision | State | Reason |
|---|---|---|---|
| A1 | Multi-tenant. One product, many hotels. | Confirmed | Hotels sign up themselves by subscription. |
| A2 | Business date rolls automatically in R1. Night audit and cashier shift come in R2. | Confirmed | Keeps R1 small. Audit needs cashier shifts first. |
| A3 | No Company entity. Corporate is a booking source, a free-text company name and a corporate rate plan. BR-007 reworded. | Confirmed | Structured accounts are R2 (BR-024). |
| A10 | Nigeria first. NGN base currency. Multi-currency with recorded FX rate. Payments are taken outside the system. | Confirmed | Avoids a payment licence in R1. |
| A11 | Tax seed: 10% service charge, 7.5% VAT on net plus prior, state levy 0%. | Open | Accountant must confirm. Also confirm cancellation and no-show fees are non-taxable. |
| A12 | Online only in R1. Client ids and idempotency keys keep offline possible. | Confirmed | Offline mode is R2. |
| A13 | Self-service signup with a 30-day trial. Billing integration is R1b. Pilots are invoiced by hand. | Confirmed | Speed to first pilot. |
| A14 | Cloud hosting. Provider and region not chosen. Nearest Supabase region is Frankfurt. | Open | Check data protection advice first. |
| A16 | Plans are configuration. Proposed: starter 20 rooms, standard 60, pro 150, enterprise unlimited. Unpriced. | Open | Peter to pick tiers and prices. |
| D1 | Adjustments, reversals and refunds always need approval. A discount above the user's limit waits for approval. | Built | Audit trail and control (BR-015). |
| D2 | Approver must differ from requester. Inspector differs from cleaner. Ticket closer differs from resolver. | Built | Separation of duties. |
| D3 | Approval limits have no default. Grant level L with no limit row means 0. | Built | Fail closed. |
| D4 | Room charge idempotency key is `room:<reservation>:<date>`. | Built | Rolling twice cannot charge twice. |
| D5 | A failed date roll notifies managers and changes nothing. | Built | Safe to retry. |
| D6 | Read-only tenants can still settle and check out. | Built | Never trap a guest at the desk. |
| D7 | Past-due for more than 14 days suspends the tenant. | Built | Grace period before suspension. |
| D8 | First admin gets the System Administrator and General Manager roles. | Built | One person runs a small hotel. |
| D9 | Same-day arrival and departure keeps the dates and deletes the night rows. | Built | Charge rule still open (DAY-006). |
| DAY-006 | Same-day stay: charge a night, a day-use rate, or nothing. | Open | Peter to decide. |
| Ops | Enable pg_cron. Schedule the date roll every 5 minutes and the subscription clock daily. | Open | Setup step on Supabase. |
