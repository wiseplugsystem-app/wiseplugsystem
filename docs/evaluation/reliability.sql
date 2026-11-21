-- WisePlug reliability numbers (ISO 25010: functional correctness,
-- reliability, safety), computed from the real data in Supabase.
-- Read-only: run with
--   npx supabase db query --linked -f docs/evaluation/reliability.sql
-- or paste one query at a time into the Supabase SQL editor.
-- Times are shown in the Philippines (Asia/Manila).

-- 1. Recognition accuracy (objective a). Every run whose real appliance is
--    known (the user confirmed or registered it) gets an outcome:
--    CORRECT, WRONG_APPLIANCE, NEW_DETECTED, ASKED_USER, MISSED_KNOWN.
--    Accuracy = (CORRECT + NEW_DETECTED) / all.
select outcome, count(*) as runs
from recognition_evaluation
group by outcome
order by runs desc;

-- 2. Usage monitoring (objective b): runs recorded, how many have their end,
--    and the hours monitored.
select count(*) as runs,
       count(*) filter (where ended_at is not null) as with_end,
       round(sum(extract(epoch from (ended_at - started_at))) / 3600.0, 1) as hours_monitored,
       min(started_at at time zone 'Asia/Manila')::date as since
from outlet_sessions;

-- 2b. How runs ended. APPLIANCE_OFF / TURNED_OFF / LOCKED_OUT were reported
--     by the plug; SUPERSEDED / REBOOT / NOT_RUNNING were closed by Supabase
--     because the plug's run-end report never arrived.
select coalesce(end_reason, '(still running)') as end_reason, count(*) as runs
from outlet_sessions
group by 1
order by runs desc;

-- 3. Notifications delivered (objective c), per day: alerts and how many
--    reached at least one phone. (Push was set up on 2026-11-09.)
select (occurred_at at time zone 'Asia/Manila')::date as day,
       count(*) as alerts,
       count(*) filter (where notified_count > 0) as delivered
from alert_logs
group by 1
order by 1;

-- 4. Automatic cut-off on time (objective d): safe-time lockouts (a
--    LOCKED_OUT within 2 min after a RUNTIME_WARNING on the same outlet) and
--    how many seconds after the safe time they happened. Expected: up to 60 s
--    (the warning countdown).
select count(*) as cutoffs,
       round(avg(runtime_s - limit_s)) as avg_seconds_after_limit,
       min(runtime_s - limit_s) as min_seconds,
       max(runtime_s - limit_s) as max_seconds,
       count(*) filter (where runtime_s - limit_s <= 61) as within_60_s
from alert_logs l
where alert_type = 'LOCKED_OUT'
  and runtime_s >= limit_s
  and exists (
    select 1 from alert_logs w
    where w.alert_type = 'RUNTIME_WARNING'
      and w.outlet = l.outlet
      and w.occurred_at between l.occurred_at - interval '2 minutes' and l.occurred_at
  );

-- 5. Safety events by type (overcurrent, power anomaly, meter not
--    answering, power cut …).
select alert_type, count(*) as events
from alert_logs
group by alert_type
order by events desc;
