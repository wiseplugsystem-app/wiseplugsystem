-- Outlet A and Outlet B as one system: appliances, profiles, samples,
-- settings and the 7-use learning already belong to the user (owner_uid),
-- not to an outlet. This adds what makes the data of both outlets comparable
-- and combined:
--
--   outlets.power_cal / voltage_cal / pf_cal   per-outlet sensor calibration
--       (1.0 = as measured). recognize-appliance and log-session apply them
--       before anything is stored, so every sample is in the same units
--       whichever outlet measured it. Set them with tool/calibrate.ts.
--   outlet_sessions.raw_features   the plug's summary before calibration.
--   signature_samples.device_id / outlet   where a sample was measured: a
--       record for history and evaluation only, never used for matching.
--   appliance_runs    every run of an appliance on either outlet.
--   appliance_usage   its runs, runtime and energy, both outlets combined.

-- ---------------------------------------------------------------------------
-- 1. Calibration. Outside 0.8..1.2 the meter or its wiring is faulty: fix the
--    hardware rather than calibrate it away.
-- ---------------------------------------------------------------------------
alter table public.outlets
  add column power_cal   numeric(6, 4) not null default 1 check (power_cal between 0.8 and 1.2),
  add column voltage_cal numeric(6, 4) not null default 1 check (voltage_cal between 0.8 and 1.2),
  add column pf_cal      numeric(6, 4) not null default 1 check (pf_cal between 0.8 and 1.2);

alter table public.outlet_sessions add column raw_features jsonb;

-- ---------------------------------------------------------------------------
-- 2. Where each sample was measured (from its run).
-- ---------------------------------------------------------------------------
alter table public.signature_samples
  add column device_id text references public.devices (id) on delete set null,
  add column outlet    text check (outlet in ('outlet_1', 'outlet_2'));

update public.signature_samples s
set device_id = o.device_id, outlet = o.outlet
from public.outlet_sessions o
where o.event_id = s.event_id and s.outlet is null;

create function public.sample_outlet() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.outlet is null and new.event_id is not null then
    select o.device_id, o.outlet into new.device_id, new.outlet
    from public.outlet_sessions o where o.event_id = new.event_id;
  end if;
  return new;
end $$;
create trigger signature_samples_outlet before insert on public.signature_samples
  for each row execute function public.sample_outlet();

-- ---------------------------------------------------------------------------
-- 3. Usage history per appliance, both outlets combined. A run belongs to the
--    appliance the user said it was (actual_appliance_id), else the one it
--    was confirmed as. Its energy and end come from the plug's usage report
--    (sessions) for the same outlet and start (within 5 s).
-- ---------------------------------------------------------------------------
create view public.appliance_runs with (security_invoker = true) as
select o.id                                           as run_id,
       coalesce(o.actual_appliance_id, o.appliance_id) as appliance_id,
       o.device_id,
       o.outlet,
       o.event_id,
       o.started_at,
       coalesce(s.ended_at, o.ended_at)               as ended_at,
       coalesce(s.duration_s, extract(epoch from o.ended_at - o.started_at)::integer) as duration_s,
       s.energy_wh,
       coalesce(s.end_reason, o.end_reason)           as end_reason
from public.outlet_sessions o
left join lateral (
  select x.ended_at, x.duration_s, x.energy_wh, x.end_reason
  from public.sessions x
  where x.device_id = o.device_id and x.outlet = o.outlet
    and x.started_at between o.started_at - interval '5 seconds' and o.started_at + interval '5 seconds'
  order by abs(extract(epoch from x.started_at - o.started_at))
  limit 1
) s on true
where o.actual_appliance_id is not null
   or (o.status = 'MATCHED_CONFIRMED' and o.appliance_id is not null);

create view public.appliance_usage with (security_invoker = true) as
select appliance_id,
       count(*)                                         as runs,
       count(*) filter (where outlet = 'outlet_1')      as runs_on_a,
       count(*) filter (where outlet = 'outlet_2')      as runs_on_b,
       coalesce(sum(duration_s), 0)                     as total_runtime_s,
       coalesce(sum(energy_wh), 0)                      as total_energy_wh,
       max(started_at)                                  as last_used_at
from public.appliance_runs
where ended_at is not null
group by appliance_id;

revoke all on public.appliance_runs, public.appliance_usage from anon;
