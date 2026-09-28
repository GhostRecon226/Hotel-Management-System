# HMS

Multi-tenant hotel management system. Supabase Postgres backend. Lovable UI.

## Layout

- `supabase/migrations` schema, ledger, posting engine, seed data, grants
- `supabase/tests` automated tests (353 checks)
- `supabase/tools` seed and workbook generators
- `docs/data-model.md` tables, rules, error codes, RPC catalogue
- `docs/system-design.md` architecture, decisions, risks, next build items
- `CLAUDE.md` rules for Claude sessions
- `docs/lovable-guide.md` what Lovable needs to build the UI
- `docs/decisions.md` decisions log
- `docs/lovable-prompts.md` ordered prompts to build the UI
- `docs/HMS_R1_Requirements.xlsx` requirements with acceptance criteria

## Deploy to Supabase

1. `supabase link --project-ref <ref>`
2. `supabase db push`
3. Enable the `pg_cron` extension.
4. Schedule `select app.run_due_rollovers();` every 5 minutes.
5. Schedule `select app.run_subscription_clock();` daily.
6. In Auth settings, require email confirmation.

## Run the tests locally

Needs PostgreSQL 16.

    PGHOST=/tmp PGPORT=5544 PGUSER=pgtest ./supabase/tests/run.sh

Rules for Lovable: call `public` functions only. Never change the schema.
