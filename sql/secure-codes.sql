-- ============================================================================
-- Teph Seal delivery board: keep store codes + area manager PIN on the server,
-- and lock delivery reviews and settings to the area manager.
--
-- Run once in Supabase: SQL Editor > New query > paste all of this > Run.
-- Safe to run again. To go back, run secure-codes-undo.sql.
--
-- What changes:
--   * Store codes and the area manager PIN move out of the public settings
--     into a private table that phones and TVs can't read.
--   * Codes are checked on the server (with a limit of 20 wrong tries per
--     15 minutes from one connection).
--   * Delivery reviews can only be read with an area manager pass.
--     Salespeople can still submit them.
--   * Settings, store codes and on/off switches can only be changed with an
--     area manager pass.
--   * Cars (jobs) and used cars work exactly as before.
-- ============================================================================
begin;

-- ---------- private tables (no access from phones; only the functions below) ----------
create table if not exists public.board_secrets (
  id text primary key default 'settings',
  master_pin text not null default '',
  codes jsonb not null default '{}'::jsonb,    -- store id -> store code
  mcodes jsonb not null default '{}'::jsonb    -- old manager codes, kept just in case
);
create table if not exists public.board_sessions (
  token text primary key,
  role text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create table if not exists public.board_login_fails (
  who text not null,
  at timestamptz not null default now()
);
create index if not exists board_login_fails_who_at on public.board_login_fails (who, at);

alter table public.board_secrets enable row level security;
alter table public.board_sessions enable row level security;
alter table public.board_login_fails enable row level security;
revoke all on public.board_secrets, public.board_sessions, public.board_login_fails from anon, authenticated;

-- ---------- copy today's PIN and codes out of the public settings (first run only) ----------
insert into public.board_secrets (id, master_pin, codes, mcodes)
select 'settings',
  coalesce(c.data->>'masterPin', ''),
  coalesce((select jsonb_object_agg(s->>'id', s->>'code')
            from jsonb_array_elements(coalesce(c.data->'stores', '[]'::jsonb)) s
            where coalesce(s->>'code', '') <> ''), '{}'::jsonb),
  coalesce((select jsonb_object_agg(s->>'id', s->>'mcode')
            from jsonb_array_elements(coalesce(c.data->'stores', '[]'::jsonb)) s
            where coalesce(s->>'mcode', '') <> ''), '{}'::jsonb)
from public.config c
where c.id = 'settings' and coalesce((c.data->>'secure')::boolean, false) = false
on conflict (id) do update
  set master_pin = excluded.master_pin, codes = excluded.codes, mcodes = excluded.mcodes;
insert into public.board_secrets (id) values ('settings') on conflict (id) do nothing;

-- ---------- helpers ----------
-- The public version of the settings: no codes, no PIN, just "this store has a code" / "a PIN is set".
create or replace function public.ts_public_cfg(d jsonb, codes jsonb, pin text)
returns jsonb language sql immutable set search_path = public as $$
  select (coalesce(d, '{}'::jsonb) - 'masterPin' - 'hasPin' - 'secure') || jsonb_build_object(
    'secure', true,
    'hasPin', coalesce(pin, '') <> '',
    'stores', coalesce((
      select jsonb_agg((s - 'code' - 'mcode' - 'hasCode')
                       || jsonb_build_object('hasCode', coalesce(codes->>(s->>'id'), '') <> '') order by ord)
      from jsonb_array_elements(coalesce(d->'stores', '[]'::jsonb)) with ordinality as t(s, ord)
    ), '[]'::jsonb));
$$;

-- Who is calling (their connection), for the wrong-code limit.
create or replace function public.ts_caller()
returns text language sql stable set search_path = public as $$
  select coalesce(nullif(trim(split_part(
    coalesce(nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for', ''), ',', 1)), ''), 'unknown');
$$;

create or replace function public.ts_throttled()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  delete from board_login_fails where at < now() - interval '1 day';
  return (select count(*) from board_login_fails
          where who = ts_caller() and at > now() - interval '15 minutes') >= 20;
end $$;

create or replace function public.ts_need_area(tok text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if tok is null or not exists (select 1 from board_sessions
                                where token = tok and role = 'area' and expires_at > now()) then
    raise exception 'need_pin';
  end if;
end $$;

-- ---------- sign in ----------
-- Area manager PIN -> a pass (token) good for 180 days on that device. Wrong PIN -> null.
create or replace function public.ts_area_login(pin text)
returns text language plpgsql security definer set search_path = public as $$
declare sec board_secrets; tok text;
begin
  if ts_throttled() then raise exception 'too_many_tries'; end if;
  select * into sec from board_secrets where id = 'settings';
  if coalesce(sec.master_pin, '') <> '' and coalesce(pin, '') <> sec.master_pin then
    insert into board_login_fails (who) values (ts_caller());
    return null;
  end if;
  tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into board_sessions (token, role, expires_at) values (tok, 'area', now() + interval '180 days');
  delete from board_sessions where expires_at < now();
  return tok;
end $$;

-- Checks the PIN without handing out a pass (used to move a locked device to another store).
create or replace function public.ts_check_pin(pin text)
returns boolean language plpgsql security definer set search_path = public as $$
declare p text;
begin
  if ts_throttled() then raise exception 'too_many_tries'; end if;
  select master_pin into p from board_secrets where id = 'settings';
  if coalesce(p, '') <> '' and coalesce(pin, '') = p then return true; end if;
  insert into board_login_fails (who) values (ts_caller());
  return false;
end $$;

-- Store code -> store id. Wrong code -> null.
create or replace function public.ts_store_login(code text)
returns text language plpgsql security definer set search_path = public as $$
declare sid text;
begin
  if ts_throttled() then raise exception 'too_many_tries'; end if;
  select e.key into sid
  from board_secrets s, jsonb_each_text(s.codes) e
  where s.id = 'settings' and coalesce(code, '') <> '' and e.value = code
  limit 1;
  if sid is null then insert into board_login_fails (who) values (ts_caller()); end if;
  return sid;
end $$;

-- ---------- area manager only ----------
create or replace function public.ts_secrets(tok text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sec board_secrets;
begin
  perform ts_need_area(tok);
  select * into sec from board_secrets where id = 'settings';
  return jsonb_build_object('pin', coalesce(sec.master_pin, ''), 'codes', coalesce(sec.codes, '{}'::jsonb));
end $$;

-- Save settings. pin / codes = null means "leave them as they are".
create or replace function public.ts_save_config(tok text, d jsonb, pin text, codes jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare sec board_secrets; newpin text; newcodes jsonb; v text; seen text[] := '{}';
begin
  perform ts_need_area(tok);
  select * into sec from board_secrets where id = 'settings';
  newpin := coalesce(pin, sec.master_pin, '');
  newcodes := coalesce(codes, sec.codes, '{}'::jsonb);
  -- drop codes for stores that were removed, and blanks
  select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) into newcodes
  from jsonb_each_text(newcodes) e
  where e.value <> '' and exists (select 1 from jsonb_array_elements(coalesce(d->'stores', '[]'::jsonb)) s where s->>'id' = e.key);
  if newpin <> '' and newpin !~ '^\d{4,6}$' then raise exception 'bad_code'; end if;
  if newpin <> '' then seen := array[newpin]; end if;
  for v in select value from jsonb_each_text(newcodes) loop
    if v !~ '^\d{4,6}$' then raise exception 'bad_code'; end if;
    if v = any(seen) then raise exception 'dup_code'; end if;
    seen := seen || v;
  end loop;
  update board_secrets set master_pin = newpin, codes = newcodes where id = 'settings';
  insert into config (id, data) values ('settings', ts_public_cfg(d, newcodes, newpin))
  on conflict (id) do update set data = excluded.data;
  if newpin is distinct from sec.master_pin then   -- PIN changed: sign out every other device
    delete from board_sessions where role = 'area' and token <> tok;
  end if;
end $$;

-- On/off switches (reviews, used cars, View store layout).
create or replace function public.ts_set_flags(tok text, rows jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform ts_need_area(tok);
  insert into feature_flags (key, enabled, updated_at)
  select r->>'key', (r->>'enabled')::boolean, now()
  from jsonb_array_elements(coalesce(rows, '[]'::jsonb)) r
  where coalesce(r->>'key', '') <> ''
  on conflict (key) do update set enabled = excluded.enabled, updated_at = excluded.updated_at;
end $$;

-- Full reviews (ratings, issues, comments) for the area manager.
create or replace function public.ts_reviews(tok text, since timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform ts_need_area(tok);
  return coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc)
                   from (select * from delivery_reviews where created_at >= since
                         order by created_at desc limit 5000) r), '[]'::jsonb);
end $$;

-- For a salesperson's phone: only WHICH deliveries at their store were already rated. No scores.
create or replace function public.ts_reviewed(st text, since timestamptz)
returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('job_id', job_id, 'store', store, 'created_at', created_at)), '[]'::jsonb)
  from (select job_id, store, created_at from delivery_reviews
        where store = st and created_at >= since order by created_at desc limit 3000) r;
$$;

revoke all on function public.ts_public_cfg(jsonb, jsonb, text), public.ts_caller(), public.ts_throttled(), public.ts_need_area(text) from public, anon, authenticated;
grant execute on function
  public.ts_area_login(text), public.ts_check_pin(text), public.ts_store_login(text),
  public.ts_secrets(text), public.ts_save_config(text, jsonb, text, jsonb), public.ts_set_flags(text, jsonb),
  public.ts_reviews(text, timestamptz), public.ts_reviewed(text, timestamptz)
to anon, authenticated;

-- ---------- lock the tables down ----------
do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('config', 'feature_flags', 'delivery_reviews') loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;
alter table public.config enable row level security;
alter table public.feature_flags enable row level security;
alter table public.delivery_reviews enable row level security;
create policy "board read settings" on public.config for select to anon, authenticated using (true);
create policy "board read switches" on public.feature_flags for select to anon, authenticated using (true);
create policy "board submit review" on public.delivery_reviews for insert to anon, authenticated with check (score between 1 and 5);

-- ---------- strip the codes and PIN out of the public settings ----------
update public.config c
set data = public.ts_public_cfg(c.data, s.codes, s.master_pin)
from public.board_secrets s
where c.id = 'settings' and s.id = 'settings';

commit;

-- Quick check: this should show your stores with "hasCode": true and NO codes or PIN.
select data from public.config where id = 'settings';
