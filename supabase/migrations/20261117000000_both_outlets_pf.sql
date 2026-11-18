-- Recognised on both outlets.
--
-- 1. Outlet A and Outlet B each have their own PZEM-004T meter, and two
--    meters read the same appliance's power factor a few hundredths apart.
--    Appliances are registered with one sample per setting, so the fixed
--    floor decides: at 0.02 an appliance registered on one outlet was "new"
--    on the other. 0.05 covers the difference between the meters; power
--    (+-10 %) still tells appliances apart, and two appliances that both pass
--    are asked about (AMBIGUOUS), never guessed.
update public.recognition_config set floor_pf = 0.05;

-- 2. A charger's power factor follows its power as the battery fills (a
--    laptop charger, one charge: PF 0.91 at 120 W, 0.86 at 78 W, 0.77 at
--    48 W), so a charger gets its own, wider floor. A fan (PF 0.96-1.00)
--    still does not pass as a charger registered at PF 0.86.
--    (If 20261118010000_charger_pf_range already added it, at 0.15 for
--    chargers with any phone, it is kept as it is.)
alter table public.recognition_config
  add column if not exists floor_pf_charger numeric(4, 3) not null default 0.10
    check (floor_pf_charger between 0.01 and 0.5);
