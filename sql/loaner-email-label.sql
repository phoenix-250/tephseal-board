-- Retired loaners: late emails label them LOANER instead of USED.
-- Changes only that one label inside the alert function that's running now; everything else stays exactly the same.
-- Safe to run more than once. Undo: sql/loaner-email-label-undo.sql

do $patch$
declare
  src text;
  old_lbl text := $q$' <span style="color:#888">USED</span></td>'$q$;
  new_lbl text := $q$' <span style="color:#888">' || case when u.data->>'loaner' = 'true' then 'LOANER' else 'USED' end || '</span></td>'$q$;
begin
  src := pg_get_functiondef('public.ts_run_late_alerts()'::regprocedure);
  if position(new_lbl in src) > 0 then
    raise notice 'Already done. Nothing changed.';
    return;
  end if;
  if (length(src) - length(replace(src, old_lbl, ''))) / length(old_lbl) <> 1 then
    raise exception 'Couldn''t find the USED label exactly once. Nothing was changed.';
  end if;
  execute replace(src, old_lbl, new_lbl);
  raise notice 'Done: late emails now say LOANER for retired loaners.';
end
$patch$;
