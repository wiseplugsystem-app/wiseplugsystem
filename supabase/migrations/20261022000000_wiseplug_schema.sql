-- WisePlug permanent data store (Supabase Free Tier).
-- Live readings stay in Firebase RTDB; Postgres keeps profiles, finished
-- sessions per outlet and safety alerts. Edge Functions write with the
-- service role (bypasses RLS); the app only reads its own rows.
--
-- Identity: users sign in with Firebase Auth only. Supabase third-party auth
-- accepts the Firebase ID token, so auth.jwt() ->> 'sub' is the Firebase uid.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.devices (
  id            text primary key check (id ~ '^[a-z0-9-]{1,32}$'),   -- 'gadget-1'
  name          text not null default 'WisePlug',
  owner_uid     text,                                                -- Firebase uid; set by link-account
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz
);

create table public.appliances (
  id                  uuid primary key default gen_random_uuid(),
  device_id           text not null references public.devices (id) on delete cascade,
  profile_id          text check (profile_id ~ '^[A-Za-z0-9_-]{1,63}$'),  -- firmware ID; null for seeds
  name                text not null check (char_length(name) between 1 and 63),
  appliance_type      text not null default 'Other' check (char_length(appliance_type) <= 40),
  -- Multi-parameter signature: a steady load inside every bound matches.
  min_power           numeric(8, 2) not null,
  max_power           numeric(8, 2) not null,
  min_current         numeric(7, 3) not null,
  max_current         numeric(7, 3) not null,
  power_factor        numeric(3, 2),                 -- null: not compared
  pf_tolerance        numeric(3, 2) not null default 0.10,
  max_runtime_mins    integer not null check (max_runtime_mins between 1 and 10080),
  -- Adaptive baseline, mirrored from the firmware (first 7 uses).
  is_learned          boolean not null default false,
  session_count       integer not null default 0 check (session_count >= 0),
  baseline_runtime_s  integer check (baseline_runtime_s >= 0),
  source              text not null default 'registered' check (source in ('seed', 'registered', 'firmware')),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (min_power >= 0 and min_power <= max_power),
  check (min_current >= 0 and min_current <= max_current),
  check (power_factor is null or (power_factor > 0 and power_factor <= 1)),
  check (pf_tolerance > 0 and pf_tolerance <= 1),
  unique (device_id, profile_id)
);
create index appliances_device_idx on public.appliances (device_id);

create table public.sessions (
  id                      bigint generated always as identity primary key,
  device_id               text not null references public.devices (id) on delete cascade,
  outlet                  text not null check (outlet in ('outlet_1', 'outlet_2')),
  appliance_id            uuid references public.appliances (id) on delete set null,
  profile_id              text,
  appliance_name          text,
  started_at              timestamptz not null,
  ended_at                timestamptz not null,
  duration_s              integer not null check (duration_s >= 0),
  energy_wh               numeric(12, 3) not null check (energy_wh >= 0),
  peak_current_a          numeric(7, 3) not null default 0 check (peak_current_a >= 0),
  peak_power_w            numeric(8, 2) not null default 0 check (peak_power_w >= 0),
  avg_power_w             numeric(8, 2) generated always as
                            (case when duration_s > 0 then round(energy_wh * 3600 / duration_s, 2) end) stored,
  end_reason              text not null check (end_reason in ('APPLIANCE_OFF', 'TURNED_OFF', 'LOCKED_OUT', 'RESET', 'ENDED')),
  counts_toward_learning  boolean not null default false,
  learning_use            smallint check (learning_use between 1 and 7),
  created_at              timestamptz not null default now(),
  check (ended_at >= started_at),
  -- One row per run per outlet: retried uploads are ignored, not duplicated.
  unique (device_id, outlet, started_at)
);
create index sessions_history_idx on public.sessions (device_id, outlet, started_at desc);
create index sessions_appliance_idx on public.sessions (appliance_id);

create table public.alert_logs (
  id              bigint generated always as identity primary key,
  event_id        text not null unique,          -- from the plug; makes retries idempotent
  device_id       text not null references public.devices (id) on delete cascade,
  outlet          text not null check (outlet in ('outlet_1', 'outlet_2')),
  appliance_id    uuid references public.appliances (id) on delete set null,
  profile_id      text,
  appliance_name  text,
  alert_type      text not null check (alert_type in
                    ('RUNTIME_WARNING', 'SENSOR_UNAVAILABLE', 'LOCKED_OUT', 'OVERCURRENT', 'POWER_ANOMALY')),
  severity        text not null check (severity in ('info', 'warning', 'critical')),
  runtime_s       integer,
  limit_s         integer,
  baseline_s      integer,
  baseline_ratio  numeric(6, 2),                 -- runtime / learned typical use
  power_w         numeric(8, 2),
  current_a       numeric(7, 3),
  message         text not null,
  notified_count  integer not null default 0,
  occurred_at     timestamptz not null,
  created_at      timestamptz not null default now()
);
create index alert_logs_device_time_idx on public.alert_logs (device_id, occurred_at desc);

-- FCM registration tokens of the app installs, used for push notifications.
create table public.push_tokens (
  token       text primary key check (char_length(token) between 20 and 4096),
  owner_uid   text not null,
  platform    text check (platform in ('android', 'ios', 'web')),
  updated_at  timestamptz not null default now()
);
create index push_tokens_owner_idx on public.push_tokens (owner_uid);

create function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;
create trigger appliances_touch before update on public.appliances
  for each row execute function public.touch_updated_at();

-- Daily energy per outlet (Philippine time) for the app's charts.
create view public.daily_energy with (security_invoker = true) as
select device_id,
       outlet,
       (started_at at time zone 'Asia/Manila')::date as day,
       count(*)                                      as sessions,
       sum(duration_s)                               as runtime_s,
       round(sum(energy_wh), 3)                      as energy_wh
from public.sessions
group by device_id, outlet, day;

-- Free-tier projects pause after 7 days without activity. The GitHub Actions
-- workflow (.github/workflows/supabase-keepalive.yml) calls this every 3 days.
-- It reads no data, so it is safe to expose to anon.
create function public.keepalive() returns timestamptz
language sql stable set search_path = '' as $$ select now() $$;
grant execute on function public.keepalive() to anon;

-- ---------------------------------------------------------------------------
-- Row Level Security: owners read their own data; only Edge Functions write.
-- ---------------------------------------------------------------------------
create function public.firebase_uid() returns text
language sql stable set search_path = '' as $$
  select auth.jwt() ->> 'sub'
$$;

create function public.owns_device(p_device_id text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.devices d
    where d.id = p_device_id and d.owner_uid = public.firebase_uid()
  )
$$;

alter table public.devices     enable row level security;
alter table public.appliances  enable row level security;
alter table public.sessions    enable row level security;
alter table public.alert_logs  enable row level security;
alter table public.push_tokens enable row level security;

-- Nothing is readable without signing in.
revoke all on public.devices, public.appliances, public.sessions, public.alert_logs,
              public.push_tokens, public.daily_energy from anon;
-- Signed-in users may read, but never write, history and profiles.
revoke insert, update, delete on public.devices, public.appliances, public.sessions,
                                 public.alert_logs from authenticated;

create policy "owner reads device" on public.devices
  for select to authenticated using (owner_uid = (select public.firebase_uid()));
create policy "owner reads appliances" on public.appliances
  for select to authenticated using ((select public.owns_device(device_id)));
create policy "owner reads sessions" on public.sessions
  for select to authenticated using ((select public.owns_device(device_id)));
create policy "owner reads alerts" on public.alert_logs
  for select to authenticated using ((select public.owns_device(device_id)));

create policy "owner reads tokens" on public.push_tokens
  for select to authenticated using (owner_uid = (select public.firebase_uid()));
create policy "owner adds tokens" on public.push_tokens
  for insert to authenticated with check (owner_uid = (select public.firebase_uid()));
create policy "owner updates tokens" on public.push_tokens
  for update to authenticated
  using (owner_uid = (select public.firebase_uid()))
  with check (owner_uid = (select public.firebase_uid()));
create policy "owner removes tokens" on public.push_tokens
  for delete to authenticated using (owner_uid = (select public.firebase_uid()));
