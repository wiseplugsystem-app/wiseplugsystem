-- No 4-hour ceiling on the learned safe time.
--
-- Every non-heating type had default_max_runtime_mins = 240, copied to each
-- appliance's max_runtime_mins, and the 7-use learned safe time (usual time
-- x learned_margin) was capped by it: an appliance usually on for 5 hours
-- still got 4 hours. 240 was a generic default, not a safety limit, so it is
-- now 10080 minutes (7 days, the firmware's MAX_CONFIRMED_LIMIT_S): in
-- practice no ceiling, and the learned time applies as learned.
--
-- Heating appliances keep their real caps (heating_safe_times: kettle 15,
-- iron 60, rice cooker 90 min...): the triggers there still set and cap them.
-- Until 7 uses are learned, the 30-minute default applies as before
-- (confirmedCutoffS in supabase/functions/_shared/matching.ts).

alter table public.appliance_types
  alter column default_max_runtime_mins set default 10080;

-- Types and appliances still on the old generic 240 (heating ones excluded).
update public.appliance_types t
set default_max_runtime_mins = 10080
where t.default_max_runtime_mins = 240
  and public.heating_limit_mins(t.icon_key, t.name) is null;

update public.appliance_instances i
set max_runtime_mins = 10080
from public.appliance_types t
where t.id = i.type_id
  and i.max_runtime_mins = 240
  and public.heating_limit_mins(t.icon_key, t.name) is null;
