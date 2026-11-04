-- Heating appliances: a shorter safe operating time for each type.
--
-- Before this, every new appliance type got the same 240-minute safe time
-- (appliance_types.default_max_runtime_mins), a flat iron as much as a fan.
-- Heating appliances are the ones that start fires when left on (unattended
-- cooking is the leading factor of home cooking fires, NFPA 2023; irons
-- switch themselves off after 8 minutes upright or 30 s flat, Philips and
-- Rowenta), so each heating type gets its own, shorter limit. See
-- docs/scope.md, "Heating appliances".
--
--   heating_safe_times            one row per heating type: the limit (minutes)
--   appliance_types               a heating type's default is its limit
--   appliance_instances           never above its type's limit (a cap: a lower
--                                 time stays lower)
--
-- The numbers are tunable here, like recognition_config: change a row and
-- every type and appliance follows (trigger below). The 7-use learning still
-- works under the cap: the learned time is never above the appliance's own.
-- A water dispenser is not here on purpose: its hot tank is made to stay on
-- all day and switches itself with a thermostat.

create table public.heating_safe_times (
  icon_key          text primary key check (icon_key ~ '^[a-z_]{1,32}$'),
  -- Words in a type's name for types without this icon (typed in under
  -- "Other", e.g. "Heater"), as in lib/models/appliance_icons.dart.
  words             text[] not null default '{}',
  max_runtime_mins  integer not null check (max_runtime_mins between 1 and 10080),
  reason            text not null
);
alter table public.heating_safe_times enable row level security;
-- Read by the functions (service role) and the triggers only.

insert into public.heating_safe_times (icon_key, words, max_runtime_mins, reason) values
  ('kettle',           '{kettle}',           15, 'Boils water in minutes, then should switch itself off'),
  ('hair_dryer',       '{hair,dryer}',       15, 'Hand-held; used for minutes at a time'),
  ('microwave',        '{microwave}',        30, 'Short heating runs; never empty'),
  ('flat_iron',        '{iron,straightener}', 60, 'Soleplate heat; irons switch themselves off after 8 min upright'),
  ('air_fryer',        '{fryer}',            60, 'Cooking with a heating element and fan'),
  ('induction_cooker', '{induction,stove}',  60, 'Cooking; unattended cooking is the leading cause of cooking fires'),
  ('heater',           '{heater}',           60, 'Room or water heater: a heating element left on'),
  ('rice_cooker',      '{rice}',             90, 'Cooking, then keep-warm');

-- The limit of a type (null: not a heating type). Its icon key first; for a
-- type without a known icon ("Other"), the words in its name.
create function public.heating_limit_mins(p_icon_key text, p_name text)
returns integer
language sql stable security definer set search_path = ''
as $$
  select h.max_runtime_mins
  from public.heating_safe_times h
  where h.icon_key = p_icon_key
     or (coalesce(p_icon_key, 'other') = 'other'
         and exists (select 1 from unnest(h.words) w where lower(p_name) like '%' || w || '%'))
  order by (h.icon_key = p_icon_key) desc, h.max_runtime_mins
  limit 1
$$;

-- A heating type's default safe time is its limit.
create function public.apply_heating_type_limit()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare lim integer := public.heating_limit_mins(new.icon_key, new.name);
begin
  if lim is not null then
    new.default_max_runtime_mins := lim;
  end if;
  return new;
end
$$;
create trigger appliance_types_heating_limit
  before insert or update of icon_key, name, default_max_runtime_mins on public.appliance_types
  for each row execute function public.apply_heating_type_limit();

-- An appliance of a heating type is never allowed longer than the limit.
create function public.cap_heating_instance()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare lim integer;
begin
  select public.heating_limit_mins(t.icon_key, t.name) into lim
  from public.appliance_types t where t.id = new.type_id;
  if lim is not null and new.max_runtime_mins > lim then
    new.max_runtime_mins := lim;
  end if;
  return new;
end
$$;
create trigger appliance_instances_heating_cap
  before insert or update of max_runtime_mins, type_id on public.appliance_instances
  for each row execute function public.cap_heating_instance();

-- Applies the table to what exists: now, and whenever a limit is changed.
create function public.apply_heating_safe_times()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.appliance_types t
  set default_max_runtime_mins = public.heating_limit_mins(t.icon_key, t.name)
  where public.heating_limit_mins(t.icon_key, t.name) is not null
    and t.default_max_runtime_mins <> public.heating_limit_mins(t.icon_key, t.name);
  update public.appliance_instances i
  set max_runtime_mins = public.heating_limit_mins(t.icon_key, t.name)
  from public.appliance_types t
  where t.id = i.type_id
    and i.max_runtime_mins > public.heating_limit_mins(t.icon_key, t.name);
  return null;
end
$$;
create trigger heating_safe_times_apply
  after insert or update or delete on public.heating_safe_times
  for each statement execute function public.apply_heating_safe_times();

-- The appliances registered so far.
update public.heating_safe_times set max_runtime_mins = max_runtime_mins;
