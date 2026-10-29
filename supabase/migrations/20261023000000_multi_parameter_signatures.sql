-- Multi-parameter appliance signatures.
--
-- Each profile stores min / max / target for active power P, current I and
-- power factor PF. Apparent power S and reactive power Q are generated from
-- the P and PF bounds, so they can never disagree with them:
--   S = P / PF            min_S = min_P / max_PF     max_S = max_P / min_PF
--   Q = P * tan(acos PF)  min_Q = min_P * q(max_PF)  max_Q = max_P * q(min_PF)
--   where q(pf) = sqrt(1 - pf^2) / pf
--
-- Profiles stay at the device level (appliances.device_id), so a profile
-- calibrated on outlet_1 is matched on outlet_2 and vice versa.

alter table public.appliances
  add column target_power   numeric(8, 2),
  add column target_current numeric(7, 3),
  add column min_pf         numeric(3, 2),
  add column max_pf         numeric(3, 2),
  add column target_pf      numeric(3, 2);

-- Convert existing rows (single PF + tolerance) to explicit ranges.
update public.appliances set
  target_power   = round((min_power + max_power) / 2, 2),
  target_current = round((min_current + max_current) / 2, 3),
  -- greatest()/least() ignore NULLs, so a profile without PF must stay NULL.
  target_pf      = power_factor,
  min_pf         = case when power_factor is not null then greatest(power_factor - pf_tolerance, 0) end,
  max_pf         = case when power_factor is not null then least(power_factor + pf_tolerance, 1) end;

-- Dropping the columns also drops the old checks that referenced them.
alter table public.appliances
  drop column power_factor,
  drop column pf_tolerance;

alter table public.appliances
  alter column target_power   set not null,
  alter column target_current set not null,
  add constraint appliances_power_range   check (min_power <= target_power and target_power <= max_power),
  add constraint appliances_current_range check (min_current <= target_current and target_current <= max_current),
  -- All three PF columns set, or none. Written so no part can evaluate to
  -- NULL, which a CHECK would silently accept.
  add constraint appliances_pf_range check (
    coalesce(min_pf is null and max_pf is null and target_pf is null, false)
    or coalesce(min_pf >= 0 and min_pf <= target_pf and target_pf <= max_pf and max_pf <= 1, false)
  ),
  add column min_apparent_power numeric(10, 2) generated always as
    (case when max_pf > 0 then round(min_power / max_pf, 2) end) stored,
  add column max_apparent_power numeric(10, 2) generated always as
    (case when min_pf > 0 then round(max_power / min_pf, 2) end) stored,
  add column min_reactive_power numeric(10, 2) generated always as
    (case when max_pf > 0 then round(min_power * sqrt(1 - max_pf * max_pf) / max_pf, 2) end) stored,
  add column max_reactive_power numeric(10, 2) generated always as
    (case when min_pf > 0 then round(max_power * sqrt(1 - min_pf * min_pf) / min_pf, 2) end) stored;

-- Writers may give just the bounds (or just a target PF): fill the rest.
create function public.fill_signature_targets() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.target_power   := coalesce(new.target_power, round((new.min_power + new.max_power) / 2, 2));
  new.target_current := coalesce(new.target_current, round((new.min_current + new.max_current) / 2, 3));
  if new.target_pf is not null then
    new.min_pf := coalesce(new.min_pf, greatest(new.target_pf - 0.10, 0));
    new.max_pf := coalesce(new.max_pf, least(new.target_pf + 0.10, 1));
  elsif new.min_pf is not null and new.max_pf is not null then
    new.target_pf := round((new.min_pf + new.max_pf) / 2, 2);
  end if;
  return new;
end $$;

create trigger appliances_fill_targets before insert or update on public.appliances
  for each row execute function public.fill_signature_targets();

comment on column public.appliances.target_power is 'Typical active power P (W)';
comment on column public.appliances.target_current is 'Typical current I (A)';
comment on column public.appliances.target_pf is 'Typical power factor; null when not measured';
comment on column public.appliances.min_apparent_power is 'Generated: min P / max PF (VA)';
comment on column public.appliances.max_reactive_power is 'Generated: max P x tan(acos(min PF)) (VAR)';

-- Row Level Security is unchanged and still applies to every new column:
-- "owner reads appliances" lets only the device owner read profiles, and only
-- Edge Functions (service role) can insert or change them.
