-- HMS 0011: who can touch what. Default deny, then open the minimum.
-- The browser talks to Postgres as `authenticated`. It may read what row-level security lets it read,
-- write only the plain configuration tables that have a write policy, and call the public functions.
-- Ledger, reservations, stays, assignments, tasks, tickets and blocks have no direct write path at all.

-- 1. nothing by default, now or for future tables and functions created by this role
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;

-- 2. the app schema is internal. Only the helpers that row-level security policies call stay executable.
revoke all on all functions in schema app from public, anon, authenticated;
grant usage on schema app to authenticated;
grant execute on function
  app.can(uuid, text), app.can_any(text), app.can_see_folio(uuid, uuid), app.grant_level(uuid, text),
  app.has_property_access(uuid), app.my_tenant(), app.platform_can(text), app.tenant_can(text), app.tenant_writable(uuid)
to authenticated;

-- 3. reads: every table and view, narrowed by row-level security (views run as the caller)
grant select on all tables in schema public to authenticated;

-- 4. direct writes only where a write policy exists. Updates and inserts are column-limited.
do $$
declare
  t record; cols text; protected text[];
  generic text[] := array['id','tenant_id','property_id'];
  extra jsonb := jsonb_build_object(
    'rooms',      array['condition','is_occupied','condition_updated_at'],
    'guests',     array['anonymised_at','created_by','created_at'],
    'properties', array['business_date','base_currency','country_code','code'],
    'profiles',   array['email','status','created_at'],
    'roles',      array['code','is_system'],
    'notifications', array['kind','title','body','entity_table','entity_id','user_id','created_at']);
  -- on insert, only engine-managed state is withheld (a role's code and a property's code can be set when created)
  extra_ins jsonb := jsonb_build_object(
    'rooms',  array['condition','is_occupied','condition_updated_at'],
    'guests', array['anonymised_at'],
    'roles',  array['is_system']);
  prot_ins text[];
begin
  for t in select tablename, array_agg(distinct cmd) as cmds from pg_policies
            where schemaname = 'public' and cmd <> 'SELECT' group by tablename loop
    protected := generic || coalesce(array(select jsonb_array_elements_text(extra -> t.tablename)), '{}');
    if 'DELETE' = any (t.cmds) or 'ALL' = any (t.cmds) then
      execute format('grant delete on public.%I to authenticated', t.tablename);
    end if;
    if 'UPDATE' = any (t.cmds) or 'ALL' = any (t.cmds) then
      select string_agg(quote_ident(column_name), ', ') into cols from information_schema.columns
       where table_schema = 'public' and table_name = t.tablename and column_name <> all (protected);
      if cols is not null then execute format('grant update (%s) on public.%I to authenticated', cols, t.tablename); end if;
    end if;
    if 'INSERT' = any (t.cmds) or 'ALL' = any (t.cmds) then
      -- inserts may set ids, tenant_id and property_id (policies check them) but not engine-managed columns
      prot_ins := coalesce(array(select jsonb_array_elements_text(extra_ins -> t.tablename)), '{}');
      select string_agg(quote_ident(column_name), ', ') into cols from information_schema.columns
       where table_schema = 'public' and table_name = t.tablename and column_name <> all (prot_ins);
      if cols is not null then execute format('grant insert (%s) on public.%I to authenticated', cols, t.tablename); end if;
    end if;
  end loop;
end $$;

-- 5. functions the app calls
grant execute on all functions in schema public to authenticated;

-- 6. the service role (Edge Functions, jobs) keeps full access
grant all on all tables    in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant all on all functions in schema public to service_role;
grant usage on schema app to service_role;
grant execute on all functions in schema app to service_role;
