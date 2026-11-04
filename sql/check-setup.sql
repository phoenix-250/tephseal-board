-- Teph Seal board: setup check. Safe to run; changes nothing.
create or replace function pg_temp.ts_check() returns table(step text, status text, details text)
language plpgsql as $f$
declare v text; n int;
begin
  -- 1. Secure codes
  if to_regclass('public.board_secrets') is null then
    return query select '1. Secure codes SQL', 'NOT RUN', 'Run sql/secure-codes.sql'; 
  else
    execute $q$select coalesce((data->>'secure'),'false') from config where id='settings'$q$ into v;
    return query select '1. Secure codes SQL', case when v='true' then 'OK' else 'PARTIAL' end,
      case when v='true' then 'Codes and PIN are server-side' else 'Table exists but settings not secured; re-run secure-codes.sql' end;
  end if;

  -- 2. Late alerts SQL
  if to_regclass('public.board_alert_keys') is null then
    return query select '2. Late alerts SQL', 'NOT RUN', 'Run sql/late-alerts.sql';
    return;
  end if;
  return query select '2. Late alerts SQL', 'OK', 'Tables and functions installed';

  -- 3. Email key
  execute $q$select coalesce(api_key,'') from board_alert_keys where id='email'$q$ into v;
  return query select '3. Resend email key', case when v<>'' then 'OK' else 'MISSING' end,
    case when v<>'' then 'Key starts ' || left(v,6) || '…' else 'Run the update line at the bottom of late-alerts.sql with your key' end;

  -- 4. 5-minute check scheduled
  begin
    execute $q$select count(*) from cron.job where jobname='ts-late-alerts'$q$ into n;
    return query select '4. 5-minute timer', case when n>0 then 'OK' else 'MISSING' end,
      case when n>0 then 'Scheduled' else 'Re-run late-alerts.sql' end;
  exception when others then
    return query select '4. 5-minute timer', 'MISSING', 'pg_cron not on: Database > Extensions > enable pg_cron, then re-run late-alerts.sql';
  end;

  -- 5. Stores turned on
  execute $q$select count(*), string_agg(ts_store_name(store) || ' -> ' || emails, ' | ') from board_alert_cfg where enabled$q$ into n, v;
  return query select '5. Stores with alerts ON', case when n>0 then 'OK' else 'NONE YET' end,
    coalesce(v, 'Board > Setup > Late alerts > add email > Turn on');

  -- 6. Emails sent
  execute $q$select count(*) from board_alert_log$q$ into n;
  if n = 0 then
    return query select '6. Emails sent', 'NONE YET', 'Tap Send test in Setup > Late alerts';
  else
    return query
      select '6. Last email ' || row_number() over (order by l.sent_at desc),
        case when r.status_code between 200 and 299 then 'SENT' when r.status_code is null and r.error_msg is null then 'PENDING' else 'FAILED' end,
        to_char(l.sent_at at time zone 'America/Denver','Mon DD HH12:MI AM') || ' · ' || ts_store_name(l.store) || ' · ' ||
        case when l.is_test then 'test' else l.cars || ' car(s)' end ||
        coalesce(' · ' || left(coalesce(r.error_msg, case when r.status_code >= 300 then r.content end), 120), '')
      from board_alert_log l left join net._http_response r on r.id = l.req_id
      order by l.sent_at desc limit 3;
  end if;
end $f$;
select * from pg_temp.ts_check();
