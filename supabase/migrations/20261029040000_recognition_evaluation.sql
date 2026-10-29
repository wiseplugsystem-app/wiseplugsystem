-- Evaluation of rule-based recognition (thesis): predicted vs actual per run,
-- confusion table, per-appliance precision / recall / F1, and a summary.
--
--   outlet_sessions.predicted_status / predicted_appliance_id
--       what recognize-appliance decided on its own (kept when the user answers;
--       status / appliance_id then change to the user's answer)
--   outlet_sessions.actual_appliance_id
--       the truth: set by confirm-match ("Yes, this is Fan 1") and
--       register-sample (the run was this appliance), or typed in by the tester
--       for runs nobody was asked about (see docs/appliance-identification.md)
--
-- A run's appliance counts as NEW when it was registered during or after
-- that run (its first registration plug-in): then UNKNOWN / SAME_TYPE_IN_USE
-- is the correct answer. Registration plug-ins 2 and 3 are not recognition
-- tests (the appliance cannot be matched before its 3 samples) and are left out.

alter table public.outlet_sessions
  add column predicted_status text check (predicted_status in (
    'UNKNOWN', 'AMBIGUOUS', 'SAME_TYPE_IN_USE', 'MATCHED_PROVISIONAL', 'MATCHED_CONFIRMED')),
  add column predicted_appliance_id uuid references public.appliance_instances (id) on delete set null,
  add column actual_appliance_id    uuid references public.appliance_instances (id) on delete set null;
create index outlet_sessions_predicted_idx on public.outlet_sessions (predicted_appliance_id);
create index outlet_sessions_actual_idx on public.outlet_sessions (actual_appliance_id);

-- Runs so far: their prediction is their status unless a person decided it.
update public.outlet_sessions
set predicted_status = status, predicted_appliance_id = appliance_id
where status <> 'RECOGNIZING' and (confirmed_by is null or confirmed_by = 'stage2');

-- One row per evaluated run.
create view public.recognition_evaluation with (security_invoker = true) as
with runs as (
  select s.event_id, s.device_id, s.outlet, s.started_at, s.stage, s.predicted_status,
         s.predicted_appliance_id, s.actual_appliance_id, s.confirmed_by,
         p.name as predicted_name, a.name as actual_name,
         a.created_at >= s.started_at as actual_is_new
  from public.outlet_sessions s
  join public.appliance_instances a on a.id = s.actual_appliance_id
  left join public.appliance_instances p on p.id = s.predicted_appliance_id
  where s.predicted_status is not null
)
select event_id, device_id, outlet, started_at, stage, predicted_status,
       predicted_name, actual_name, actual_is_new,
       -- Labels for the confusion table.
       case
         when predicted_status in ('MATCHED_PROVISIONAL', 'MATCHED_CONFIRMED') then predicted_name
         when predicted_status = 'AMBIGUOUS' then 'Asked the user'
         else 'New appliance'
       end as predicted_label,
       case when actual_is_new then 'New appliance' else actual_name end as actual_label,
       case
         when predicted_status in ('MATCHED_PROVISIONAL', 'MATCHED_CONFIRMED')
              and not actual_is_new and predicted_appliance_id = actual_appliance_id then 'CORRECT'
         when predicted_status in ('MATCHED_PROVISIONAL', 'MATCHED_CONFIRMED') then 'WRONG_APPLIANCE'
         when actual_is_new and predicted_status in ('UNKNOWN', 'SAME_TYPE_IN_USE') then 'NEW_DETECTED'
         when predicted_status = 'AMBIGUOUS' then 'ASKED_USER'
         else 'MISSED_KNOWN'
       end as outcome
from runs
where not (confirmed_by = 'registration' and not actual_is_new);

-- Confusion table: actual (rows) x predicted (columns), as counts.
create view public.recognition_confusion with (security_invoker = true) as
select actual_label, predicted_label, count(*) as runs
from public.recognition_evaluation
group by actual_label, predicted_label
order by actual_label, predicted_label;

-- Per appliance (and "New appliance"): TP, FP, FN, precision, recall, F1.
-- A run WisePlug asked about counts as not recognised (FN): the question is
-- safe, but it is not an automatic recognition.
create view public.recognition_metrics with (security_invoker = true) as
with labels as (
  select actual_label as label from public.recognition_evaluation
  union
  select predicted_label from public.recognition_evaluation where predicted_label <> 'Asked the user'
), counts as (
  select l.label,
         count(*) filter (where e.actual_label = l.label and e.predicted_label = l.label) as tp,
         count(*) filter (where e.actual_label <> l.label and e.predicted_label = l.label) as fp,
         count(*) filter (where e.actual_label = l.label and e.predicted_label <> l.label) as fn
  from labels l cross join public.recognition_evaluation e
  group by l.label
)
select label, tp, fp, fn,
       round(tp::numeric / nullif(tp + fp, 0), 3) as precision,
       round(tp::numeric / nullif(tp + fn, 0), 3) as recall,
       round(2 * tp::numeric / nullif(2 * tp + fp + fn, 0), 3) as f1
from counts
order by label;

-- One row of thesis numbers.
create view public.recognition_summary with (security_invoker = true) as
select count(*) as runs,
       count(*) filter (where not actual_is_new) as known_runs,
       count(*) filter (where actual_is_new) as new_runs,
       -- Accuracy on registered appliances: recognised as the right one.
       round(count(*) filter (where outcome = 'CORRECT')::numeric
             / nullif(count(*) filter (where not actual_is_new), 0), 3) as accuracy_known,
       -- Of all runs: right label or correctly flagged as new.
       round(count(*) filter (where outcome in ('CORRECT', 'NEW_DETECTED'))::numeric
             / nullif(count(*), 0), 3) as accuracy_overall,
       -- Unknown-appliance detection rate.
       round(count(*) filter (where outcome = 'NEW_DETECTED')::numeric
             / nullif(count(*) filter (where actual_is_new), 0), 3) as new_detection_rate,
       count(*) filter (where outcome = 'ASKED_USER') as asked_user,
       count(*) filter (where outcome = 'WRONG_APPLIANCE') as wrong_appliance,
       count(*) filter (where outcome = 'MISSED_KNOWN') as missed_known,
       -- SAFETY: unconfirmed runs given more than the default cutoff. Always 0:
       -- the outlet_sessions trigger refuses it.
       (select count(*) from public.outlet_sessions s, public.recognition_config c
        where s.status <> 'MATCHED_CONFIRMED' and s.cutoff_s > c.default_cutoff_minutes * 60) as safety_violations
from public.recognition_evaluation;

revoke all on public.recognition_evaluation, public.recognition_confusion,
              public.recognition_metrics, public.recognition_summary from anon;
