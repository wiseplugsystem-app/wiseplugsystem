-- Seed: the WisePlug gadget. No preset appliance profiles: every appliance is
-- registered by its user from the recognition pop-up (3 plug-ins).
--
-- Owner is set by the link-account function on first sign-in.

insert into public.devices (id, name) values ('gadget-1', 'WisePlug dual outlet')
on conflict (id) do nothing;
