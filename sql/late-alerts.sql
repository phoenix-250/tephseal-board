-- ============================================================================
-- Teph Seal delivery board: LATE ALERTS BY EMAIL
--
-- Run once in Supabase: SQL Editor > New query > paste all of this > Run.
-- Safe to run again. To turn it all off for good, run late-alerts-undo.sql.
-- Needs secure-codes.sql to have been run first (it uses the area manager pass).
--
-- What it does:
--   * Every 5 minutes the server checks each store that has alerts turned on.
--   * A delivery that passes its ready-by time and still isn't Ready -> email.
--   * A used car that passes 48 hours and isn't Completed -> email.
--   * One email per store per check, listing every newly late car.
--   * Each car is emailed about once. It never repeats.
--   * Only reads the board's tables. Never changes a car, a setting or a switch.
--
-- After running this, do STEP 2 at the bottom (paste your Resend key).
-- ============================================================================
begin;

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ---------- private tables (phones and TVs can't read these) ----------
create table if not exists public.board_alert_cfg (
  store text primary key,
  enabled boolean not null default false,
  emails text not null default '',
  updated_at timestamptz not null default now()
);
create table if not exists public.board_alert_keys (
  id text primary key default 'email',
  api_key text not null default '',
  from_addr text not null default 'Teph Seal Board <alerts@tephsealsold.com>',
  board_url text not null default 'https://tephsealsold.com'
);
insert into public.board_alert_keys (id) values ('email') on conflict (id) do nothing;
create table if not exists public.board_alerts_sent (
  item_id text not null,
  kind text not null,              -- 'late' = delivery, 'used48' = used car
  store text,
  sent_at timestamptz not null default now(),
  primary key (item_id, kind)
);
create table if not exists public.board_alert_log (
  id bigserial primary key,
  store text,
  cars int not null default 0,
  is_test boolean not null default false,
  req_id bigint,
  sent_at timestamptz not null default now()
);

alter table public.board_alert_cfg enable row level security;
alter table public.board_alert_keys enable row level security;
alter table public.board_alerts_sent enable row level security;
alter table public.board_alert_log enable row level security;
revoke all on public.board_alert_cfg, public.board_alert_keys, public.board_alerts_sent, public.board_alert_log from anon, authenticated;

-- ---------- helpers ----------
create or replace function public.ts_h(t text)
returns text language sql immutable set search_path = public as $$
  select replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
$$;

create or replace function public.ts_ms_time(ms bigint)
returns text language sql stable set search_path = public as $$
  select case when ms is null then '—'
    else to_char(to_timestamp(ms / 1000.0) at time zone 'America/Denver', 'FMHH12:MI AM') end;
$$;

create or replace function public.ts_dur(mins numeric)
returns text language sql immutable set search_path = public as $$
  select case when mins < 60 then round(mins)::int || ' min'
    else floor(mins / 60)::int || 'h ' || lpad((round(mins)::int % 60)::text, 2, '0') || 'm' end;
$$;

create or replace function public.ts_store_name(st text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select s->>'name' from config c, jsonb_array_elements(coalesce(c.data->'stores', '[]'::jsonb)) s
                   where c.id = 'settings' and s->>'id' = st limit 1), st);
$$;

create or replace function public.ts_email_list(t text)
returns text[] language sql immutable set search_path = public as $$
  select coalesce(array_agg(e), '{}') from (
    select lower(trim(x)) e from regexp_split_to_table(coalesce(t, ''), '[,;\s]+') x
    where trim(x) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' limit 20) q;
$$;

-- Sends one email through Resend. Returns the request id (or null if no key yet).
create or replace function public.ts_send_email(st text, subj text, html text, cars int, is_test boolean)
returns bigint language plpgsql security definer set search_path = public as $$
declare k board_alert_keys; c board_alert_cfg; rid bigint; tos text[];
begin
  select * into k from board_alert_keys where id = 'email';
  select * into c from board_alert_cfg where store = st;
  tos := ts_email_list(c.emails);
  if coalesce(k.api_key, '') = '' or array_length(tos, 1) is null then return null; end if;
  select net.http_post(
    url := 'https://api.resend.com/emails',
    body := jsonb_build_object('from', k.from_addr, 'to', to_jsonb(tos), 'subject', subj, 'html', html),
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || k.api_key),
    timeout_milliseconds := 10000
  ) into rid;
  insert into board_alert_log (store, cars, is_test, req_id) values (st, cars, is_test, rid);
  return rid;
end $$;

-- ---------- the check that runs every 5 minutes ----------
create or replace function public.ts_run_late_alerts()
returns int language plpgsql security definer set search_path = public as $$
declare
  c board_alert_cfg; k board_alert_keys;
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
  win_ms bigint := 2 * 3600 * 1000;          -- only cars that went late in the last 2 hours (no old backlog)
  used_max bigint := 48 * 3600 * 1000;
  rows_html text; n_late int; n_used int; total int := 0; nm text; subj text; html text;
begin
  select * into k from board_alert_keys where id = 'email';
  if coalesce(k.api_key, '') = '' then return 0; end if;

  for c in select * from board_alert_cfg where enabled and emails <> '' loop
    nm := ts_store_name(c.store);

    -- deliveries past their ready-by time, still waiting or in progress
    create temp table if not exists _late (id text, kind text, line text) on commit drop;
    truncate _late;

    insert into _late
    select j.id, 'late',
      '<tr><td style="padding:6px 10px;border-bottom:1px solid #eee"><b>#' || ts_h(j.data->>'stock') || '</b></td>' ||
      '<td style="padding:6px 10px;border-bottom:1px solid #eee">' || ts_h(nullif(concat_ws(' ', j.data->>'year', j.data->>'make', j.data->>'model'), '')) ||
        case when coalesce(j.data->>'color', '') <> '' then ' <span style="color:#888">' || ts_h(j.data->>'color') || '</span>' else '' end || '</td>' ||
      '<td style="padding:6px 10px;border-bottom:1px solid #eee">' || ts_h(coalesce(nullif(j.data->>'salesperson', ''), '—')) || '</td>' ||
      '<td style="padding:6px 10px;border-bottom:1px solid #eee">' || case j.data->>'status' when 'queued' then 'Waiting' else 'In progress' end || '</td>' ||
      '<td style="padding:6px 10px;border-bottom:1px solid #eee">Due ' || ts_ms_time((j.data->>'dueAt')::bigint) || '</td>' ||
      '<td style="padding:6px 10px;border-bottom:1px solid #eee;color:#c0392b"><b>' || ts_dur((now_ms - (j.data->>'dueAt')::bigint) / 60000.0) || ' late</b></td></tr>'
    from jobs j
    where j.data->>'store' = c.store
      and j.data->>'status' in ('queued', 'working')
      and coalesce(j.data->>'dueAt', '') ~ '^\d+$'
      and (j.data->>'dueAt')::bigint < now_ms
      and (j.data->>'dueAt')::bigint > now_ms - win_ms
      and not exists (select 1 from board_alerts_sent s where s.item_id = j.id and s.kind = 'late')
    order by (j.data->>'dueAt')::bigint;

    -- used cars past 48 hours, not completed
    insert into _late
    select u.id, 'used48',
      '<tr><td style="padding:6px 10px;border-bottom:1px solid #eee"><b>#' || ts_h(coalesce(nullif(u.data->>'stock', ''), '—')) || '</b></td>' ||
      '<td style="padding:6px 10px;border-bottom:1px solid #eee">' || ts_h(coalesce(nullif(concat_ws(' ', u.data->>'year', u.data->>'make', u.data->>'model'), ''), 'Used vehicle')) || ' <span style="color:#888">USED</span></td>' ||
      '<td style="padding:6px 10px;border-bottom:1px solid #eee">' || ts_h(coalesce(nullif(u.data->>'detailer', ''), 'No detailer')) || '</td>' ||
      '<td style="padding:6px 10px;border-bottom:1px solid #eee">' || case u.data->>'stage' when 'detail' then 'In detail' else 'In progress' end || '</td>' ||
      '<td style="padding:6px 10px;border-bottom:1px solid #eee">In since ' || to_char(to_timestamp((u.data->>'createdAt')::bigint / 1000.0) at time zone 'America/Denver', 'Dy FMHH12:MI AM') || '</td>' ||
      '<td style="padding:6px 10px;border-bottom:1px solid #eee;color:#c0392b"><b>' || ts_dur((now_ms - (u.data->>'createdAt')::bigint) / 60000.0) || ' on the clock</b></td></tr>'
    from used_units u
    where u.store = c.store
      and coalesce(u.data->>'stage', '') <> 'done'
      and coalesce(u.data->>'createdAt', '') ~ '^\d+$'
      and (u.data->>'createdAt')::bigint + used_max < now_ms
      and (u.data->>'createdAt')::bigint + used_max > now_ms - win_ms
      and not exists (select 1 from board_alerts_sent s where s.item_id = u.id and s.kind = 'used48');

    select count(*) filter (where kind = 'late'), count(*) filter (where kind = 'used48'), string_agg(line, '' order by kind, line)
      into n_late, n_used, rows_html from _late;

    if n_late + n_used > 0 then
      subj := 'LATE at ' || nm || ': ' ||
        concat_ws(' + ',
          case when n_late > 0 then n_late || ' deliver' || case when n_late = 1 then 'y' else 'ies' end end,
          case when n_used > 0 then n_used || ' used car' || case when n_used = 1 then '' else 's' end || ' past 48h' end);
      html := '<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;color:#222">' ||
        '<h2 style="margin:0 0 6px;color:#c0392b">Late at ' || ts_h(nm) || '</h2>' ||
        '<p style="margin:0 0 14px;color:#555">' ||
          case when n_late > 0 then 'Deliveries past their ready-by time (1-hour standard). ' else '' end ||
          case when n_used > 0 then 'Used cars past the 48-hour max. ' else '' end || '</p>' ||
        '<table style="border-collapse:collapse;font-size:14px"><tr style="text-align:left;color:#888;font-size:12px"><th style="padding:4px 10px">Stock</th><th style="padding:4px 10px">Vehicle</th><th style="padding:4px 10px">Sales / detailer</th><th style="padding:4px 10px">Status</th><th style="padding:4px 10px">Time</th><th style="padding:4px 10px">Late</th></tr>' || rows_html || '</table>' ||
        '<p style="margin:16px 0 0"><a href="' || ts_h(k.board_url) || '" style="color:#0a66c2">Open the board</a></p>' ||
        '<p style="margin:14px 0 0;font-size:12px;color:#999">Teph Seal delivery board. You get one email per late car. Turn these off in Setup &gt; Late alerts.</p></div>';

      perform ts_send_email(c.store, subj, html, n_late + n_used, false);
      insert into board_alerts_sent (item_id, kind, store) select id, kind, c.store from _late on conflict do nothing;
      total := total + n_late + n_used;
    end if;
  end loop;

  delete from board_alerts_sent where sent_at < now() - interval '30 days';
  delete from board_alert_log where sent_at < now() - interval '60 days';
  return total;
end $$;

-- ---------- area manager only (Setup > Late alerts) ----------
create or replace function public.ts_alert_cfg(tok text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k board_alert_keys;
begin
  perform ts_need_area(tok);
  select * into k from board_alert_keys where id = 'email';
  return jsonb_build_object(
    'connected', coalesce(k.api_key, '') <> '',
    'from', k.from_addr,
    'stores', coalesce((select jsonb_object_agg(store, jsonb_build_object('on', enabled, 'emails', emails)) from board_alert_cfg), '{}'::jsonb),
    'log', coalesce((select jsonb_agg(x order by x.sent_at desc) from (
      select l.store, l.cars, l.is_test, l.sent_at,
             r.status_code, coalesce(r.error_msg, case when r.status_code >= 300 then left(r.content, 200) end) as err
      from board_alert_log l left join net._http_response r on r.id = l.req_id
      order by l.sent_at desc limit 8) x), '[]'::jsonb));
end $$;

create or replace function public.ts_alert_save(tok text, st text, on_ boolean, emails text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare clean text;
begin
  perform ts_need_area(tok);
  if coalesce(st, '') = '' then raise exception 'bad_store'; end if;
  clean := array_to_string(ts_email_list(emails), ', ');
  if on_ and clean = '' then raise exception 'need_email'; end if;
  insert into board_alert_cfg (store, enabled, emails, updated_at) values (st, coalesce(on_, false), clean, now())
  on conflict (store) do update set enabled = excluded.enabled, emails = excluded.emails, updated_at = now();
  return jsonb_build_object('on', coalesce(on_, false), 'emails', clean);
end $$;

create or replace function public.ts_alert_test(tok text, st text)
returns boolean language plpgsql security definer set search_path = public as $$
declare k board_alert_keys; nm text;
begin
  perform ts_need_area(tok);
  select * into k from board_alert_keys where id = 'email';
  if coalesce(k.api_key, '') = '' then raise exception 'not_connected'; end if;
  nm := ts_store_name(st);
  return ts_send_email(st, 'Test: late alerts for ' || nm || ' are working',
    '<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;color:#222"><h2 style="margin:0 0 8px">Late alerts are set up</h2>' ||
    '<p>This address will get an email when a delivery at <b>' || ts_h(nm) || '</b> passes its ready-by time, or a used car passes 48 hours.</p>' ||
    '<p><a href="' || ts_h(k.board_url) || '">Open the board</a></p></div>', 0, true) is not null;
end $$;

revoke all on function public.ts_h(text), public.ts_ms_time(bigint), public.ts_dur(numeric), public.ts_store_name(text),
  public.ts_email_list(text), public.ts_send_email(text, text, text, int, boolean), public.ts_run_late_alerts()
  from public, anon, authenticated;
grant execute on function public.ts_alert_cfg(text), public.ts_alert_save(text, text, boolean, text), public.ts_alert_test(text, text)
  to anon, authenticated;

commit;

-- ---------- run the check every 5 minutes ----------
select cron.schedule('ts-late-alerts', '*/5 * * * *', $$select public.ts_run_late_alerts()$$);

-- ============================================================================
-- STEP 2 (once): connect the email service.
--   1. Sign up free at resend.com, add the domain tephsealsold.com and add the
--      DNS records it shows you (same place you set up the board's address).
--   2. Create an API key in Resend, put it between the quotes below, and run
--      just this line:
--
-- update public.board_alert_keys set api_key = 're_PASTE_YOUR_KEY_HERE' where id = 'email';
--
-- Then in the board: Setup > Late alerts > add emails > Turn on > Send test.
-- ============================================================================
