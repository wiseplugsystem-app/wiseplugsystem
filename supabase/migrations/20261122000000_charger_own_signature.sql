-- "Is this <charger>?" only within the charger's own signature.
-- Since 20261118020000 a charger matched any power from 0 to
-- charger_max_power_w (140 W), and a "new" reading close in PF to a charger
-- was turned into the charger (20261118040000), so almost any small appliance
-- was asked about as the charger and could not be registered. 0 now means
-- "off": a charger is matched within floor_power_pct_charger (+-50 %) of its
-- registered power and floor_pf_charger of its power factor, like its own
-- signature. Any value from 5 W turns the old rules back on.
alter table public.recognition_config
  drop constraint if exists recognition_config_charger_max_power_w_check;
alter table public.recognition_config
  add constraint recognition_config_charger_max_power_w_check
    check (charger_max_power_w = 0 or charger_max_power_w between 5 and 1760);
update public.recognition_config set charger_max_power_w = 0;
