-- A phone charger is never offered as a new appliance.
--
-- A wall meter sees the phone on a charger, not the charger, so the same
-- charger reads differently with every phone. When a reading is a registered
-- charger's, the pop-up no longer offers "Register new appliance" /
-- "No, register a new appliance": it only confirms the charger ("Is this
-- Purple charger?") or lets the user pick which charger / phone it is
-- ("Which charger is this?"), from every registered charger that is free.
-- (recognizeWithChargers in supabase/functions/_shared/matching.ts.)
--
--   charger_no_register  on: chargers are only confirmed or picked
--   charger_near_pf      0.25: a reading whose PF is this close to a
--                        registered charger's (at up to charger_max_power_w)
--                        is that charger, not "New appliance detected"
--
-- Unconfirmed runs keep the default cutoff, as before. Set
-- charger_no_register to false for the previous prompts.
alter table public.recognition_config
  add column charger_no_register boolean not null default true,
  add column charger_near_pf numeric(4, 2) not null default 0.25
    check (charger_near_pf between 0 and 1);
