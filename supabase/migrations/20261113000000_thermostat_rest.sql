-- Thermostat rests (a flat iron, a microwave, a rice cooker's plate): the
-- heating element clicks off to 0 W while the appliance is still on. The plug
-- used to end a run after 3 s below 1.5 W, so every heating burst started a
-- new run with a fresh safe time, and an iron left on was never cut off.
--
--   recognition_config.rest_gap_s       a heating load (peak at or above
--                                       rest_gap_min_w) may rest at 0 W this
--                                       long without ending its run: its safe
--                                       time keeps counting (180 s)
--   recognition_config.rest_gap_min_w   what counts as a heating load (500 W).
--                                       Fans and chargers stay far below it,
--                                       so their runs still end 3 s after
--                                       they are switched off or unplugged.
--
-- The plug gets both in every recognize-appliance reply; until then (or
-- without Supabase) it uses the same values built into its firmware.
alter table public.recognition_config
  add column rest_gap_s smallint not null default 180
    check (rest_gap_s between 0 and 900),
  add column rest_gap_min_w numeric(6, 1) not null default 500
    check (rest_gap_min_w between 50 and 2200);
