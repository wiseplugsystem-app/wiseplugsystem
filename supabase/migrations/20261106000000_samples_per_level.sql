-- Registration by level: an appliance is registered with one sample for
-- each of its settings ("Speed 1", "Speed 2", "Speed 3"; "Cook", "Keep warm";
-- a charger has one), each setting its own profile. Profiles made before
-- this keep registration_samples (3) in one "Normal" profile.
--
--   recognition_config.samples_per_level   samples for each setting (1)
--   appliance_profiles.required_samples    this profile's samples to be
--                                          matched (null: registration_samples)
--   appliance_profiles.level_position      the setting's place in the list
--                                          (Low, Medium, High), null for others
alter table public.recognition_config
  add column samples_per_level smallint not null default 1
    check (samples_per_level between 1 and 10);
alter table public.appliance_profiles
  add column required_samples smallint check (required_samples between 1 and 10),
  add column level_position smallint check (level_position between 0 and 9);
