-- No preset profiles: every appliance is registered by its user (the
-- recognition pop-up and its 3 plug-ins). Removes the 7 reference appliances
-- that seed.sql created (Electric Fan, Rice Cooker, Flat Iron, Electric
-- Kettle, LED TV, Laptop/Phone Charger, Refrigerator), the copies the
-- 20261029000000 migration made of them, and types nothing uses any more.

-- The copies: appliances with the same name as a seed row whose samples
-- are all the copied ("migrated") reference values, never a real plug-in.
delete from public.appliance_instances i
using public.appliances a
where a.source = 'seed'
  and a.device_id = i.device_id
  and lower(a.name) = lower(i.name)
  and not exists (
    select 1 from public.appliance_profiles p
    join public.signature_samples s on s.profile_id = p.id
    where p.appliance_id = i.id and s.source <> 'migrated'
  );

-- The seed rows of the old profile table (sessions / alert_logs keep their
-- rows; their appliance_id becomes null).
delete from public.appliances where source = 'seed';

-- Types left without any appliance ("Rice cooker", "TV", ...).
delete from public.appliance_types t
where not exists (select 1 from public.appliance_instances i where i.type_id = t.id);
