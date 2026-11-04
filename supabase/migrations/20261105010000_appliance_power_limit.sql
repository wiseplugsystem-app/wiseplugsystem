-- The most an appliance may draw for WisePlug to register it: 80 % of the
-- plug's 10 A socket at 220 V (the SSR-40DA on its heatsink), the rule for
-- loads that stay on. register-sample refuses a run whose average power is
-- above it (the plug itself cuts off above 8 A after 10 s, CONTINUOUS_CURRENT_A).
-- Tunable here like the other recognition numbers.
alter table public.recognition_config
  add column max_appliance_w numeric(6, 1) not null default 1760
    check (max_appliance_w > 0 and max_appliance_w <= 2200);
