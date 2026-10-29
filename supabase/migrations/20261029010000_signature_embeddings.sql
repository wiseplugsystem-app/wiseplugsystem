-- CNN signature embeddings (Matindife et al. 2020, adapted) on top of the
-- appliance type / instance model of 20261029000000_appliance_instances.sql.
--
--   signature_samples.window_signal  the first 32 readings of the run (the
--                                     databank keeps raw windows, so a
--                                     retrained model can re-embed them)
--   signature_embeddings             one 16-number embedding per sample and
--                                     model version (a cache of the model output)
--   identification_events            every identification decision, kept after
--                                     the run ends: evaluation log + training data
--   training_readings (view)         the labelled windows as one CSV row per
--                                     reading, for the Colab notebook

-- {"power": [W ...], "current": [A ...], "pf": [...]}, one value per second from switch-on.
alter table public.signature_samples add column window_signal jsonb
  check (window_signal is null or (
    jsonb_typeof(window_signal -> 'power') = 'array'
    and jsonb_array_length(window_signal -> 'power') between 24 and 64
    and jsonb_array_length(window_signal -> 'current') = jsonb_array_length(window_signal -> 'power')
    and jsonb_array_length(window_signal -> 'pf') = jsonb_array_length(window_signal -> 'power')
  ));

create table public.signature_embeddings (
  sample_id      bigint not null references public.signature_samples (id) on delete cascade,
  device_id      text not null references public.devices (id) on delete cascade,
  model_version  text not null check (char_length(model_version) between 1 and 40),
  embedding      real[] not null check (array_length(embedding, 1) between 4 and 128),
  created_at     timestamptz not null default now(),
  primary key (sample_id, model_version)
);
create index signature_embeddings_device_idx on public.signature_embeddings (device_id, model_version);

create table public.identification_events (
  event_id              text primary key check (char_length(event_id) between 1 and 88),
  device_id             text not null references public.devices (id) on delete cascade,
  outlet                text not null check (outlet in ('outlet_1', 'outlet_2')),
  started_at            timestamptz not null,
  signal                jsonb,
  features              jsonb not null,
  method                text not null check (method in ('embedding', 'features')),
  model_version         text,
  outcome               text not null check (outcome in ('CONFIDENT', 'AMBIGUOUS', 'UNKNOWN')),
  instance_id           uuid references public.appliance_instances (id) on delete set null,
  nearest_instance_id   uuid references public.appliance_instances (id) on delete set null,
  nearest_distance      real,
  candidates            jsonb,
  -- Ground truth: the user's answer in the app (confirm-appliance) ...
  confirmed_instance_id uuid references public.appliance_instances (id) on delete set null,
  confirmed_mode        smallint check (confirmed_mode between 0 and 7),
  confirmed_at          timestamptz,
  -- ... or typed in by the researcher during data collection (Table Editor).
  -- label_appliance names the appliance MODEL ("Stand fan, Brand A"); two
  -- units of the same model get the same label (they cannot be told apart).
  label_appliance       text check (char_length(label_appliance) between 1 and 63),
  label_mode            smallint check (label_mode between 0 and 7),
  label_note            text,
  created_at            timestamptz not null default now()
);
create index identification_events_device_idx on public.identification_events (device_id, started_at desc);

-- One row per reading of every labelled window: export from the SQL editor
-- (select * from training_readings) and download as CSV for the notebook.
create view public.training_readings with (security_invoker = true) as
select e.event_id                                   as session_id,
       e.device_id,
       e.outlet,
       coalesce(e.label_appliance, ty.name)         as appliance,
       i.name                                       as instance,
       coalesce(e.label_mode, e.confirmed_mode, 0)  as mode,
       r.t                                          as t_s,
       (e.signal -> 'power'   ->> r.t)::real        as power_w,
       (e.signal -> 'current' ->> r.t)::real        as current_a,
       (e.signal -> 'pf'      ->> r.t)::real        as pf,
       e.started_at
from public.identification_events e
left join public.appliance_instances i on i.id = e.confirmed_instance_id
left join public.appliance_types ty on ty.id = i.type_id
cross join lateral generate_series(0, jsonb_array_length(e.signal -> 'power') - 1) as r (t)
where e.signal is not null and coalesce(e.label_appliance, ty.name) is not null;

-- Owners read; only Edge Functions write.
alter table public.signature_embeddings  enable row level security;
alter table public.identification_events enable row level security;
revoke all on public.signature_embeddings, public.identification_events, public.training_readings from anon;
revoke insert, update, delete on public.signature_embeddings, public.identification_events from authenticated;
create policy "owner reads embeddings" on public.signature_embeddings
  for select to authenticated using ((select public.owns_device(device_id)));
create policy "owner reads identification events" on public.identification_events
  for select to authenticated using ((select public.owns_device(device_id)));
