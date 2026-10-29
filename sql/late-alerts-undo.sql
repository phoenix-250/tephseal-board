-- Turns late-alert emails off for good and removes everything late-alerts.sql added.
-- The board itself is not touched. Run in Supabase: SQL Editor > New query > paste > Run.
select cron.unschedule('ts-late-alerts') where exists (select 1 from cron.job where jobname = 'ts-late-alerts');

begin;
drop function if exists public.ts_alert_cfg(text);
drop function if exists public.ts_alert_save(text, text, boolean, text);
drop function if exists public.ts_alert_test(text, text);
drop function if exists public.ts_run_late_alerts();
drop function if exists public.ts_send_email(text, text, text, int, boolean);
drop function if exists public.ts_email_list(text);
drop function if exists public.ts_store_name(text);
drop function if exists public.ts_dur(numeric);
drop function if exists public.ts_ms_time(bigint);
drop function if exists public.ts_h(text);
drop table if exists public.board_alert_log;
drop table if exists public.board_alerts_sent;
drop table if exists public.board_alert_keys;
drop table if exists public.board_alert_cfg;
commit;
