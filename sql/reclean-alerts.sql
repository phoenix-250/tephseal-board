-- Reclean for lot: stop late emails for reclean cars (they have no timer).
-- Safe to run any time; only replaces the alert function. Undo: re-run the old late-alerts.sql.

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
      and coalesce(u.data->>'reclean', '') <> 'true'   -- reclean for lot: no timer, no alerts
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

