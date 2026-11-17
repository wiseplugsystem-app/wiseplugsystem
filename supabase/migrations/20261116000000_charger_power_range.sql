-- A laptop or phone charger draws much more on a low battery than when it is
-- nearly full (measured: 120 W down to 48 W in one charge). Registered with
-- one sample, its power was compared with the usual +-10 % floor, so most of a
-- charge looked like "something new" and the same charger was registered
-- again and again. A charger's power is now compared with this wider floor;
-- power factor and the other features still apply.
--
--   recognition_config.floor_power_pct_charger   0.50 (+-50 % of its mean)
alter table public.recognition_config
  add column floor_power_pct_charger numeric(4, 2) not null default 0.50
    check (floor_power_pct_charger between 0.05 and 1);
