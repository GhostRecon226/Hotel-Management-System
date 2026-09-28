# CLAUDE.md

Multi-tenant hotel management system for Nigeria, then Africa. Peter owns the product.

## Stack

- Supabase Postgres owns all data and rules. Claude writes migrations and tests.
- Lovable builds the UI. It never changes the schema.
- Edge Functions only for work Postgres cannot do (invite, webhooks, messages, PDF, exports).

## Commands

    PGHOST=/tmp PGPORT=5544 PGUSER=pgtest ./supabase/tests/run.sh

This rebuilds a scratch database from the migrations and runs every test. It must end with `ALL OK`. Run it before you finish any change.

## Rules

1. Never edit a migration that has been pushed. Add a new one. Name it `YYYYMMDDHHMMSS_topic.sql`. Until the first push to Supabase, edits are allowed.
2. Every table has `tenant_id`, row-level security and, where it applies, `property_id`.
3. Helpers live in schema `app`. Callable functions live in `public`. Only `public` functions are granted to the browser.
4. Every function is `security definer` with `set search_path = public, pg_temp`. Every function checks a permission with `app.can` first.
5. Errors use `app.fail('E_CODE', 'plain message')`. It raises `[E_CODE] message`. Add new codes to `docs/data-model.md`.
6. The ledger is immutable. Never update or delete `folio_transactions`. Add a linked reversal, adjustment or refund.
7. Every write that moves money or inventory takes an idempotency key.
8. New tables get default-deny grants. Add only the grants the UI needs to `20260928001100_grants.sql` logic or a new grants migration.
9. Every new function needs a test. Every new requirement needs a row in `supabase/tools/reqs_data.py`. Rebuild the workbook with `python3 supabase/tools/build_reqs_xlsx.py`.
10. Seed data comes from `supabase/tools/data_perm.py` through `gen_seed.py`. Change the source, then regenerate. Do not hand edit `20260928001000_seed_reference_data.sql`.

## Test gotchas

- `set role` persists across DO blocks. Call `select t.admin();` between blocks.
- Test helpers are in schema `t`: `login`, `admin`, `ok`, `eq`, `raises`, `bdate`, `pm`, `cc`.

## Language

Plain and short. No em dashes. Active voice. Peter is a project manager, not a database engineer. Explain choices in business terms.

## Open decisions

Plan tiers and prices (A16), cloud region (A14), tax seed sign-off (A11), same-day check-in and check-out charge (DAY-006). See `docs/decisions.md`.
