-- A charger is recognised whatever phone or laptop is on it, from its one
-- registration sample: no registering it again with each phone.
--
-- A charger passes on what the device on it asks for (a slow phone 5-10 W, a
-- fast-charging one 18-30 W, a laptop up to 140 W), so its power says little
-- about which charger it is. For chargers only, any power from 0 up to
-- charger_max_power_w now passes the power check (floor_power_pct_charger
-- still applies on top); the charger's power factor (floor_pf_charger, +-0.15)
-- is what identifies it. Other appliances keep their own +-10 % power check.
--
--   recognition_config.charger_max_power_w   140 W (a fast laptop charger)
alter table public.recognition_config
  add column charger_max_power_w numeric(6, 1) not null default 140
    check (charger_max_power_w between 5 and 1760);
