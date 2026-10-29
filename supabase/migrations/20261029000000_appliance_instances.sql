-- Appliance TYPE vs INSTANCE, k-NN signature samples, and outlet exclusivity.
--
--   appliance_types       "Fan", "Laptop charger" (per device)
--   appliance_instances   "Fan 1", "Fan 2": own signature samples and cutoff
--   signature_samples     one summary per confirmed use, <= 20 per instance mode
--   outlets               outlet_1 / outlet_2 of each device
--   active_sessions       the load on each outlet right now and how sure we are
--
-- Matching (_shared/knn.ts, identify-appliance) reads samples; only Edge
-- Functions write (service role). The old `appliances` table is left in place
-- for match-signature / log-session; its rows are copied in below.

create table public.appliance_types (
  id                        uuid primary key default gen_random_uuid(),
  device_id                 text not null references public.devices (id) on delete cascade,
  name                      text not null check (char_length(name) between 1 and 40),
  default_max_runtime_mins  integer not null default 240 check (default_max_runtime_mins between 1 and 10080),
  created_at                timestamptz not null default now()
);
-- "Fan" and "fan" are the same type.
create unique index appliance_types_name_idx on public.appliance_types (device_id, lower(name));

create table public.appliance_instances (
  id                uuid primary key default gen_random_uuid(),
  device_id         text not null references public.devices (id) on delete cascade,
  type_id           uuid not null references public.appliance_types (id) on delete restrict,
  name              text not null check (char_length(name) between 1 and 63),
  max_runtime_mins  integer not null check (max_runtime_mins between 1 and 10080),
  profile_id        text check (profile_id ~ '^[A-Za-z0-9_-]{1,63}$'),  -- firmware profile, if linked
  last_outlet       text check (last_outlet in ('outlet_1', 'outlet_2')),
  last_seen_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (id, device_id)  -- target of the composite key in active_sessions
);
create unique index appliance_instances_name_idx on public.appliance_instances (device_id, lower(name));
create index appliance_instances_type_idx on public.appliance_instances (type_id);
create trigger appliance_instances_touch before update on public.appliance_instances
  for each row execute function public.touch_updated_at();

-- One row per confirmed use: the steady-state summary the plug computed.
create table public.signature_samples (
  id            bigint generated always as identity primary key,
  instance_id   uuid not null references public.appliance_instances (id) on delete cascade,
  mode          smallint not null default 0 check (mode between 0 and 7),  -- e.g. fan speed
  power_w       numeric(8, 2) not null check (power_w >= 0),
  current_a     numeric(7, 3) not null check (current_a >= 0),
  power_factor  numeric(4, 3) check (power_factor between 0 and 1),
  reactive_var  numeric(10, 2) check (reactive_var >= 0),
  power_cv      numeric(6, 4) check (power_cv >= 0),        -- std(P) / mean(P) over the window
  peak_ratio    numeric(6, 3) check (peak_ratio >= 0),      -- start-up peak P / steady P
  standby_w     numeric(6, 2) check (standby_w >= 0),       -- informational, not matched
  window_s      smallint check (window_s > 0),
  readings      smallint check (readings > 0),
  source        text not null check (source in ('registration', 'confirmed', 'migrated')),
  event_id      text,
  created_at    timestamptz not null default now()
);
create index signature_samples_instance_idx on public.signature_samples (instance_id, mode, created_at desc);

-- Bounded history: keep the newest 20 samples of each instance mode, so the
-- signature follows slow drift (motor wear, a new charger) without growing.
create function public.trim_signature_samples() returns trigger
language plpgsql set search_path = '' as $$
begin
  delete from public.signature_samples s
  where s.instance_id = new.instance_id and s.mode = new.mode
    and s.id not in (
      select id from public.signature_samples
      where instance_id = new.instance_id and mode = new.mode
      order by created_at desc, id desc
      limit 20
    );
  return null;
end $$;
create trigger signature_samples_trim after insert on public.signature_samples
  for each row execute function public.trim_signature_samples();

-- Per-mode statistics, for the app and for reporting in the study.
create view public.signature_stats with (security_invoker = true) as
select instance_id, mode, count(*) as samples,
       round(avg(power_w), 2) as power_mean,         round(stddev_samp(power_w), 2) as power_sd,
       round(avg(current_a), 3) as current_mean,     round(stddev_samp(current_a), 3) as current_sd,
       round(avg(power_factor), 3) as pf_mean,       round(stddev_samp(power_factor), 3) as pf_sd,
       round(avg(reactive_var), 2) as reactive_mean, round(stddev_samp(reactive_var), 2) as reactive_sd
from public.signature_samples
group by instance_id, mode;

create table public.outlets (
  device_id  text not null references public.devices (id) on delete cascade,
  outlet     text not null check (outlet in ('outlet_1', 'outlet_2')),
  label      text check (char_length(label) <= 40),
  primary key (device_id, outlet)
);
insert into public.outlets (device_id, outlet)
select d.id, o.outlet from public.devices d cross join (values ('outlet_1'), ('outlet_2')) o (outlet);

-- New devices get both outlets.
create function public.add_device_outlets() returns trigger
language plpgsql set search_path = '' as $$
begin
  insert into public.outlets (device_id, outlet) values (new.id, 'outlet_1'), (new.id, 'outlet_2')
  on conflict do nothing;
  return null;
end $$;
create trigger devices_add_outlets after insert on public.devices
  for each row execute function public.add_device_outlets();

-- The load running on each outlet right now. Removed by log-session when the run ends.
create table public.active_sessions (
  id           bigint generated always as identity primary key,
  device_id    text not null,
  outlet       text not null,
  event_id     text not null unique check (char_length(event_id) between 1 and 88),
  instance_id  uuid,
  state        text not null check (state in ('CONFIDENT', 'AMBIGUOUS', 'UNKNOWN', 'CONFIRMED')),
  cutoff_s     integer not null check (cutoff_s > 0),
  features     jsonb not null,
  candidates   jsonb not null default '[]',
  suggestion   jsonb,
  reason       text,
  started_at   timestamptz not null,
  updated_at   timestamptz not null default now(),
  foreign key (device_id, outlet) references public.outlets (device_id, outlet) on delete cascade,
  -- The instance must belong to the same device (composite key).
  foreign key (instance_id, device_id) references public.appliance_instances (id, device_id)
    on delete set null (instance_id),
  -- One load per outlet.
  unique (device_id, outlet),
  -- Outlet exclusivity: an instance is active on at most one outlet. (NULLs
  -- are distinct, so any number of unidentified loads may run.)
  unique (instance_id),
  -- An identity is attached only when the match is confident or confirmed.
  check ((instance_id is not null) = (state in ('CONFIDENT', 'CONFIRMED'))),
  -- Safety: an unconfirmed load never runs longer than the conservative 30 min.
  check (state in ('CONFIDENT', 'CONFIRMED') or cutoff_s <= 1800)
);
create trigger active_sessions_touch before update on public.active_sessions
  for each row execute function public.touch_updated_at();

-- Copy the existing profiles: one type per appliance_type, one instance per
-- appliance, and its signature target as the first (migrated) sample.
insert into public.appliance_types (device_id, name)
select distinct device_id, appliance_type from public.appliances
on conflict do nothing;

with copied as (
  insert into public.appliance_instances (device_id, type_id, name, max_runtime_mins, profile_id)
  select a.device_id, t.id, a.name, a.max_runtime_mins, a.profile_id
  from public.appliances a
  join public.appliance_types t on t.device_id = a.device_id and lower(t.name) = lower(a.appliance_type)
  on conflict do nothing
  returning id, device_id, name
)
insert into public.signature_samples (instance_id, power_w, current_a, power_factor, reactive_var, source)
select c.id, a.target_power, a.target_current, a.target_pf,
       case when a.target_pf > 0 then round(a.target_power * sqrt(1 - a.target_pf ^ 2) / a.target_pf, 2) end,
       'migrated'
from copied c
join public.appliances a on a.device_id = c.device_id and lower(a.name) = lower(c.name);

-- ---------------------------------------------------------------------------
-- Row Level Security: owners read; only Edge Functions write.
-- ---------------------------------------------------------------------------
alter table public.appliance_types     enable row level security;
alter table public.appliance_instances enable row level security;
alter table public.signature_samples   enable row level security;
alter table public.outlets             enable row level security;
alter table public.active_sessions     enable row level security;

revoke all on public.appliance_types, public.appliance_instances, public.signature_samples,
              public.outlets, public.active_sessions, public.signature_stats from anon;
revoke insert, update, delete on public.appliance_types, public.appliance_instances,
                                 public.signature_samples, public.outlets, public.active_sessions
  from authenticated;

create policy "owner reads types" on public.appliance_types
  for select to authenticated using ((select public.owns_device(device_id)));
create policy "owner reads instances" on public.appliance_instances
  for select to authenticated using ((select public.owns_device(device_id)));
create policy "owner reads samples" on public.signature_samples
  for select to authenticated using (exists (
    select 1 from public.appliance_instances i
    where i.id = instance_id and (select public.owns_device(i.device_id))
  ));
create policy "owner reads outlets" on public.outlets
  for select to authenticated using ((select public.owns_device(device_id)));
create policy "owner reads active sessions" on public.active_sessions
  for select to authenticated using ((select public.owns_device(device_id)));

-- The app subscribes to its outlets' identification prompts.
alter publication supabase_realtime add table public.active_sessions;
