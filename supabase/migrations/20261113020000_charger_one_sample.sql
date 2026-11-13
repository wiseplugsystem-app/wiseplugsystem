-- A laptop or phone charger is registered with ONE sample, like any other
-- appliance with one setting (the user asked: "it only has 1 level").
-- It was 3 (battery low / half / nearly full). Trade-off: the charger's
-- power still changes with the battery, so a run at a very different battery
-- level may be asked about ("Which appliance…?") instead of being recognised
-- at once; the wider floors of 20261112000000 still apply.
update public.recognition_config set samples_per_charger = 1;

-- Chargers already being registered ("Charging" setting) need only what they
-- have: one sample, so they are finished now.
update public.appliance_profiles set required_samples = 1
where mode_name = 'Charging' and required_samples > 1;
