-- Rule-based appliance recognition, part 1 of 2 ("expand").
--
-- Adds what the rule-based recognizer needs, WITHOUT removing anything the
-- deployed functions still use (identify-appliance is called by the current
-- firmware, log-session writes active_sessions). Part 2 ("contract", after the
-- new functions and firmware are deployed) drops the old k-NN / CNN tables
-- and columns.
--
--   recognition_config   every tunable number (one row): tolerance floors,
--                        weights, clear-winner ratio, tie margin, default cutoff
--   appliance_types      + owner_uid: types belong to the user, not one plug
--   appliance_instances  the spec's "appliances" (Fan 1, Fan 2): + owner_uid,
--                        + 7-use learning, + last device/outlet
--   appliance_profiles   one per mode ("Fan - Low", "Fan - High"): per-feature
--                        mean and standard deviation, registration voltage
--   signature_samples    + profile_id and the spec's features (raw samples,
--                        the newest 20 per profile are kept)
--   outlet_sessions      what is on each outlet, its recognition status and
--                        cutoff; kept after the run ends (ended_at)
--
-- Column names follow the existing schema: appliance_instances.name is the
-- display name ("Fan 2"), max_runtime_mins is the appliance's own cutoff, and
-- an outlet is (device_id, 'outlet_1' | 'outlet_2'), labelled A / B in the app.

-- ---------------------------------------------------------------------------
-- 1. Tunable numbers. Exactly one row (id is always true), read by the Edge
--    Functions on every recognition, so a value can be changed in the Table
--    Editor without redeploying anything.
-- ---------------------------------------------------------------------------
create table public.recognition_config (
  id                          boolean primary key default true check (id),
  -- Tolerance of a feature = max(tolerance_sigma x std_dev, floor).
  tolerance_sigma             numeric(4, 2) not null default 3     check (tolerance_sigma > 0),
  -- Floors: the smallest tolerance, so 3 near-identical registration samples
  -- (std_dev ~ 0) do not make an appliance reject its own next reading.
  floor_power_pct             numeric(5, 4) not null default 0.02  check (floor_power_pct > 0),  -- 2 % of mean W
  floor_pf                    numeric(5, 4) not null default 0.02  check (floor_pf > 0),
  floor_startup_peak_ratio    numeric(5, 4) not null default 0.10  check (floor_startup_peak_ratio > 0),
  floor_power_variation       numeric(5, 4) not null default 0.02  check (floor_power_variation > 0),
  floor_settling_time_s       numeric(6, 2) not null default 2     check (floor_settling_time_s > 0),
  -- Not in the base specification: cycling and standby need floors too.
  -- Cycle period: 10 % of the mean; standby: 0.5 W (the meter's noise level).
  floor_cycle_period_pct      numeric(5, 4) not null default 0.10  check (floor_cycle_period_pct > 0),
  floor_standby_power_w       numeric(6, 2) not null default 0.5   check (floor_standby_power_w > 0),
  -- Weights of the score (weighted average of |new - mean| / tolerance).
  -- Cycle period is pass/fail only (weight 0) unless changed here.
  weight_power                numeric(4, 3) not null default 0.30  check (weight_power >= 0),
  weight_pf                   numeric(4, 3) not null default 0.30  check (weight_pf >= 0),
  weight_startup_peak_ratio   numeric(4, 3) not null default 0.15  check (weight_startup_peak_ratio >= 0),
  weight_power_variation      numeric(4, 3) not null default 0.10  check (weight_power_variation >= 0),
  weight_settling_time        numeric(4, 3) not null default 0.10  check (weight_settling_time >= 0),
  weight_standby_power        numeric(4, 3) not null default 0.05  check (weight_standby_power >= 0),
  weight_cycle_period         numeric(4, 3) not null default 0     check (weight_cycle_period >= 0),
  -- Clear winner: the second-best score is at least this many times the best.
  clear_winner_ratio          numeric(4, 2) not null default 1.5   check (clear_winner_ratio > 1),
  -- Two scores closer than this (score units) are tied: prefer the appliance
  -- last used on this outlet (pre-selected, never decided silently).
  tie_margin                  numeric(4, 3) not null default 0.10  check (tie_margin >= 0),
  -- Voltage correction applies to profiles with mean PF at or above this
  -- (resistive loads, whose power follows V squared).
  voltage_correction_min_pf   numeric(4, 3) not null default 0.95  check (voltage_correction_min_pf between 0 and 1),
  -- Safety: cutoff for every load that is not MATCHED_CONFIRMED.
  default_cutoff_minutes      integer       not null default 30    check (default_cutoff_minutes between 1 and 240),
  -- Signature updating after a confirmed match: new_mean = (1 - f) old + f new.
  ema_factor                  numeric(4, 3) not null default 0.10  check (ema_factor > 0 and ema_factor <= 1),
  max_samples_per_profile     integer       not null default 20    check (max_samples_per_profile between 3 and 200),
  registration_samples        integer       not null default 3     check (registration_samples between 1 and 10),
  -- Existing 7-use learning: after learning_uses confirmed uses, the cutoff is
  -- the average runtime x learned_margin (never above the appliance's own).
  learning_uses               integer       not null default 7     check (learning_uses between 1 and 50),
  learned_margin              numeric(4, 2) not null default 1.5   check (learned_margin >= 1),
  updated_at                  timestamptz   not null default now(),
  check (weight_power + weight_pf + weight_startup_peak_ratio + weight_power_variation
         + weight_settling_time + weight_standby_power + weight_cycle_period > 0)
);
insert into public.recognition_config default values;
create trigger recognition_config_touch before update on public.recognition_config
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Appliances belong to the user (devices.owner_uid, the Firebase uid), so
--    one Fan can move between the user's plugs and outlet exclusivity holds
--    across all of them. device_id stays: the plug it was registered on.
-- ---------------------------------------------------------------------------
alter table public.appliance_types add column owner_uid text;
alter table public.appliance_instances
  add column owner_uid          text,
  add column last_device_id     text references public.devices (id) on delete set null,
  -- 7-use learning, moved from the firmware to the server.
  add column use_count          integer   not null default 0 check (use_count >= 0),
  add column recent_runtimes_s  integer[] not null default '{}',
  add column baseline_runtime_s integer check (baseline_runtime_s >= 0),
  add column is_learned         boolean   not null default false;

update public.appliance_types t set owner_uid = d.owner_uid from public.devices d where d.id = t.device_id;
update public.appliance_instances i set owner_uid = d.owner_uid from public.devices d where d.id = i.device_id;
-- Keep the learning progress the firmware already reported (old appliances table).
update public.appliance_instances i
set use_count = a.session_count, baseline_runtime_s = a.baseline_runtime_s, is_learned = a.is_learned
from public.appliances a
where a.device_id = i.device_id and a.profile_id = i.profile_id;
update public.appliance_instances set last_device_id = device_id where last_outlet is not null;

-- "Fan" and "fan" are one type, and names are unique per user.
create unique index appliance_types_owner_name_idx
  on public.appliance_types (owner_uid, lower(name)) where owner_uid is not null;
create unique index appliance_instances_owner_name_idx
  on public.appliance_instances (owner_uid, lower(name)) where owner_uid is not null;
create index appliance_instances_last_device_idx on public.appliance_instances (last_device_id);

-- ---------------------------------------------------------------------------
-- 3. Mode profiles. Matching any profile of an appliance matches the appliance.
--    A null mean means the feature was never measured: it is skipped.
-- ---------------------------------------------------------------------------
create table public.appliance_profiles (
  id                       uuid primary key default gen_random_uuid(),
  appliance_id             uuid not null references public.appliance_instances (id) on delete cascade,
  mode_name                text not null default 'Normal' check (char_length(mode_name) between 1 and 40),
  avg_power_w_mean         real check (avg_power_w_mean >= 0),
  avg_power_w_std          real check (avg_power_w_std >= 0),
  avg_pf_mean              real check (avg_pf_mean between 0 and 1),
  avg_pf_std               real check (avg_pf_std >= 0),
  startup_peak_ratio_mean  real check (startup_peak_ratio_mean >= 0),
  startup_peak_ratio_std   real check (startup_peak_ratio_std >= 0),
  power_variation_mean     real check (power_variation_mean >= 0),
  power_variation_std      real check (power_variation_std >= 0),
  settling_time_s_mean     real check (settling_time_s_mean >= 0),
  settling_time_s_std      real check (settling_time_s_std >= 0),
  cycle_period_s_mean      real check (cycle_period_s_mean > 0),
  cycle_period_s_std       real check (cycle_period_s_std >= 0),
  standby_power_w_mean     real check (standby_power_w_mean >= 0),
  standby_power_w_std      real check (standby_power_w_std >= 0),
  -- Mean voltage at registration, for the resistive-load voltage correction.
  registration_voltage_v   real check (registration_voltage_v between 80 and 300),
  sample_count             integer not null default 0 check (sample_count >= 0),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
-- Also serves as the index on the appliance_id foreign key.
create unique index appliance_profiles_mode_idx on public.appliance_profiles (appliance_id, lower(mode_name));
create trigger appliance_profiles_touch before update on public.appliance_profiles
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- 4. Raw samples per profile. Old k-NN rows (instance_id, power_w, ...) stay
--    readable for identify-appliance until part 2.
-- ---------------------------------------------------------------------------
alter table public.signature_samples
  add column profile_id          uuid references public.appliance_profiles (id) on delete cascade,
  add column avg_power_w         real check (avg_power_w >= 0),
  add column avg_pf              real check (avg_pf between 0 and 1),
  add column avg_voltage_v       real check (avg_voltage_v between 80 and 300),
  add column startup_peak_ratio  real check (startup_peak_ratio >= 0),
  add column settling_time_s     real check (settling_time_s >= 0),
  add column power_variation     real check (power_variation >= 0),
  add column cycle_period_s      real check (cycle_period_s > 0),
  add column standby_power_w     real check (standby_power_w >= 0),
  -- The load never settled within 60 s: averages are less reliable.
  add column unstable            boolean not null default false,
  alter column instance_id drop not null,
  alter column power_w drop not null,
  alter column current_a drop not null;
alter table public.signature_samples drop constraint signature_samples_source_check;
alter table public.signature_samples add constraint signature_samples_source_check
  check (source in ('registration', 'confirmed_match', 'confirmed', 'migrated'));
alter table public.signature_samples add constraint signature_samples_parent_check
  check (profile_id is not null or instance_id is not null);
-- A rule-based sample always has its average power.
alter table public.signature_samples add constraint signature_samples_power_check
  check (profile_id is null or avg_power_w is not null);
create index signature_samples_profile_idx on public.signature_samples (profile_id, created_at desc);

-- Bounded history: the newest max_samples_per_profile samples of a profile
-- (old instance/mode rows keep their 20).
create or replace function public.trim_signature_samples() returns trigger
language plpgsql set search_path = '' as $$
declare
  keep integer;
begin
  if new.profile_id is not null then
    select max_samples_per_profile into keep from public.recognition_config;
    delete from public.signature_samples s
    where s.profile_id = new.profile_id
      and s.id not in (
        select id from public.signature_samples
        where profile_id = new.profile_id
        order by created_at desc, id desc
        limit coalesce(keep, 20)
      );
  else
    delete from public.signature_samples s
    where s.instance_id = new.instance_id and s.mode = new.mode
      and s.id not in (
        select id from public.signature_samples
        where instance_id = new.instance_id and mode = new.mode
        order by created_at desc, id desc
        limit 20
      );
  end if;
  return null;
end $$;

-- Existing appliances: one profile per (instance, mode) that has samples,
-- with the features the old samples share with the new ones (power, PF,
-- start-up peak ratio). The other features stay null (skipped) until new
-- samples arrive. Appliances without samples get no profile: they cannot be
-- matched until registered again (a profile without power would match anything).
insert into public.appliance_profiles (
  appliance_id, mode_name, avg_power_w_mean, avg_power_w_std, avg_pf_mean, avg_pf_std,
  startup_peak_ratio_mean, startup_peak_ratio_std, sample_count)
select s.instance_id,
       case when s.mode = 0 then 'Normal' else 'Mode ' || s.mode end,
       avg(s.power_w), stddev_samp(s.power_w),
       avg(s.power_factor), stddev_samp(s.power_factor),
       avg(s.peak_ratio), stddev_samp(s.peak_ratio),
       count(*)
from public.signature_samples s
where s.instance_id is not null and s.power_w is not null
group by s.instance_id, s.mode;

update public.signature_samples s
set profile_id = p.id, avg_power_w = s.power_w, avg_pf = s.power_factor, startup_peak_ratio = s.peak_ratio
from public.appliance_profiles p
where p.appliance_id = s.instance_id
  and p.mode_name = case when s.mode = 0 then 'Normal' else 'Mode ' || s.mode end;

-- ---------------------------------------------------------------------------
-- 5. Outlet sessions: one row per run, open while ended_at is null.
-- ---------------------------------------------------------------------------
create table public.outlet_sessions (
  id            bigint generated always as identity primary key,
  device_id     text not null,
  outlet        text not null,
  -- The plug's idempotency key for this run (retried uploads update the same row).
  event_id      text not null unique check (char_length(event_id) between 1 and 88),
  appliance_id  uuid references public.appliance_instances (id) on delete set null,
  profile_id    uuid references public.appliance_profiles (id) on delete set null,
  status        text not null default 'RECOGNIZING' check (status in (
                  'RECOGNIZING', 'UNKNOWN', 'AMBIGUOUS', 'SAME_TYPE_IN_USE',
                  'MATCHED_PROVISIONAL', 'MATCHED_CONFIRMED')),
  stage         smallint not null default 0 check (stage between 0 and 2),  -- 0 none, 1, 2
  started_at    timestamptz not null,
  ended_at      timestamptz,
  last_score    real check (last_score >= 0),
  cutoff_s      integer not null check (cutoff_s > 0),
  candidates    jsonb not null default '[]',
  prompt_text   text,
  -- The latest stage summary from the plug (register-sample / confirm-match use it).
  features      jsonb,
  end_reason    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  foreign key (device_id, outlet) references public.outlets (device_id, outlet) on delete cascade,
  check (ended_at is null or ended_at >= started_at),
  -- An appliance is attached only to a match. (A match whose appliance was
  -- deleted keeps its row with appliance_id null.)
  check (appliance_id is null or status in ('MATCHED_PROVISIONAL', 'MATCHED_CONFIRMED'))
);
-- One run per outlet at a time.
create unique index outlet_sessions_open_outlet_idx
  on public.outlet_sessions (device_id, outlet) where ended_at is null;
-- OUTLET EXCLUSIVITY: an appliance is in at most one open session, on any
-- outlet of any of the user's plugs (appliance ids are unique across users).
create unique index outlet_sessions_open_appliance_idx
  on public.outlet_sessions (appliance_id) where ended_at is null and appliance_id is not null;
create index outlet_sessions_appliance_idx on public.outlet_sessions (appliance_id);
create index outlet_sessions_profile_idx on public.outlet_sessions (profile_id);
create index outlet_sessions_history_idx on public.outlet_sessions (device_id, outlet, started_at desc);
create trigger outlet_sessions_touch before update on public.outlet_sessions
  for each row execute function public.touch_updated_at();

-- Two rules the database enforces itself, whatever the code does:
--  * SAFETY: a load that is not MATCHED_CONFIRMED never gets a cutoff above
--    the conservative default (never another appliance's limit).
--  * The appliance belongs to the owner of the plug it is on.
create function public.check_outlet_session() returns trigger
language plpgsql set search_path = '' as $$
declare
  default_s integer;
begin
  select default_cutoff_minutes * 60 into default_s from public.recognition_config;
  if new.status <> 'MATCHED_CONFIRMED' and new.cutoff_s > default_s then
    raise exception 'Safety: a % load may not have a cutoff above the default % s (got % s)',
      new.status, default_s, new.cutoff_s using errcode = 'check_violation';
  end if;
  if new.appliance_id is not null and not exists (
    select 1 from public.appliance_instances i
    join public.devices d on d.id = new.device_id
    where i.id = new.appliance_id and i.owner_uid = d.owner_uid
  ) then
    raise exception 'Appliance % does not belong to the owner of %', new.appliance_id, new.device_id
      using errcode = 'foreign_key_violation';
  end if;
  return new;
end $$;
create trigger outlet_sessions_check before insert or update on public.outlet_sessions
  for each row execute function public.check_outlet_session();

-- The app follows its outlets' status live.
alter publication supabase_realtime add table public.outlet_sessions;

-- ---------------------------------------------------------------------------
-- 6. Row Level Security: owners read; only Edge Functions (service role) write.
-- ---------------------------------------------------------------------------
alter table public.recognition_config enable row level security;
alter table public.appliance_profiles enable row level security;
alter table public.outlet_sessions    enable row level security;

revoke all on public.recognition_config, public.appliance_profiles, public.outlet_sessions from anon;
revoke insert, update, delete on public.recognition_config, public.appliance_profiles, public.outlet_sessions
  from authenticated;

create policy "signed-in users read the config" on public.recognition_config
  for select to authenticated using (true);
create policy "owner reads own types" on public.appliance_types
  for select to authenticated using (owner_uid = (select public.firebase_uid()));
create policy "owner reads own appliances" on public.appliance_instances
  for select to authenticated using (owner_uid = (select public.firebase_uid()));
create policy "owner reads profiles" on public.appliance_profiles
  for select to authenticated using (exists (
    select 1 from public.appliance_instances i
    where i.id = appliance_profiles.appliance_id and i.owner_uid = (select public.firebase_uid())
  ));
create policy "owner reads profile samples" on public.signature_samples
  for select to authenticated using (exists (
    select 1 from public.appliance_profiles p
    join public.appliance_instances i on i.id = p.appliance_id
    where p.id = signature_samples.profile_id and i.owner_uid = (select public.firebase_uid())
  ));
create policy "owner reads outlet sessions" on public.outlet_sessions
  for select to authenticated using ((select public.owns_device(device_id)));
