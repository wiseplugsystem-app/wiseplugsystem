-- Recognition of appliances whose power varies from run to run (a laptop
-- charger draws 80, 103 or 91 W depending on the battery; a fan's motor
-- varies a little): with one registration sample WisePlug has no spread to
-- learn from, so only these minimum tolerances apply. At 2 % of the power
-- and 2 s of settling time, such appliances came back as "Something new"
-- almost every time.
--
--   floor_power_pct           2 %  -> 10 %   of the profile's mean power
--   floor_settling_time_s     2 s  -> 10 s
--   floor_startup_peak_ratio  0.10 -> 0.25
--
-- Appliances within 10 % of each other now become "Which appliance is it?"
-- (AMBIGUOUS), which the app asks.
--
-- A charger is registered with samples_per_charger samples (its one setting,
-- "Charging"), so its real spread is learned and 3 x std_dev applies on top
-- of the floors. Other appliances keep samples_per_level per setting.
update public.recognition_config set
  floor_power_pct = 0.10,
  floor_settling_time_s = 10,
  floor_startup_peak_ratio = 0.25;

alter table public.recognition_config
  add column samples_per_charger smallint not null default 3
    check (samples_per_charger between 1 and 10);
