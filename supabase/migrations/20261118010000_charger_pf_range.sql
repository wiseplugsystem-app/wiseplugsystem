-- One charger, different phones.
--
-- A charger passes on what the phone on it asks for: a slow phone draws 10 W,
-- a fast-charging one 18 W or more, and a charger's power factor changes with
-- that load (lower at light load). The wider power floor for chargers
-- (floor_power_pct_charger, 20261116) is not enough: the power factor was still
-- held to the usual floor_pf (+-0.02), so the same charger with another phone
-- looked like "something new".
--
--   recognition_config.floor_pf_charger   0.15 (+-0.15 power factor, chargers only)
--
-- Chargers also skip the startup peak check (the inrush follows the phone).
-- Every other appliance keeps floor_pf and all its checks, so same-wattage
-- appliances on the two outlets are still told apart as before.
--
-- 20261117000000_both_outlets_pf may already have added the column (0.10):
-- then it is kept and set to 0.15 here, instead of failing on a second add.
alter table public.recognition_config
  add column if not exists floor_pf_charger numeric(4, 2) not null default 0.15
    check (floor_pf_charger between 0.01 and 1);
alter table public.recognition_config
  alter column floor_pf_charger set default 0.15;
update public.recognition_config set floor_pf_charger = 0.15;
