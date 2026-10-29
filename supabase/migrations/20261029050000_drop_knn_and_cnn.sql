-- Rule-based recognition, part 2 of 2 ("contract"): removes the k-NN and CNN
-- identification (approved in Phase 0) now that the firmware calls
-- recognize-appliance and log-session no longer touches active_sessions.
-- Deploy the new log-session BEFORE pushing this migration.
--
-- Dropped: training_readings (view), identification_events,
-- signature_embeddings, active_sessions (test data only), signature_stats
-- (view over the old columns), and the old per-instance columns of
-- signature_samples. The old `appliances` table stays: sessions and
-- alert_logs still reference it.

drop view if exists public.training_readings;
drop view if exists public.signature_stats;
drop table if exists public.identification_events;
drop table if exists public.signature_embeddings;
drop table if exists public.active_sessions;

-- Samples belong to a mode profile only. Old-style rows that were never
-- linked to a profile (none after the Phase 1 backfill) are removed.
delete from public.signature_samples where profile_id is null;
-- The old per-instance read policy uses instance_id (owners keep "owner reads profile samples").
drop policy if exists "owner reads samples" on public.signature_samples;
alter table public.signature_samples drop constraint signature_samples_parent_check;
alter table public.signature_samples drop constraint signature_samples_power_check;
alter table public.signature_samples
  drop column instance_id,
  drop column mode,
  drop column power_w,
  drop column current_a,
  drop column power_factor,
  drop column reactive_var,
  drop column power_cv,
  drop column peak_ratio,
  drop column standby_w,
  drop column window_s,
  drop column readings,
  drop column window_signal,
  alter column profile_id set not null,
  alter column avg_power_w set not null;
alter table public.signature_samples drop constraint signature_samples_source_check;
alter table public.signature_samples add constraint signature_samples_source_check
  check (source in ('registration', 'confirmed_match', 'migrated'));

-- Bounded history per profile only.
create or replace function public.trim_signature_samples() returns trigger
language plpgsql set search_path = '' as $$
declare
  keep integer;
begin
  select max_samples_per_profile into keep from public.recognition_config;
  delete from public.signature_samples s
  where s.profile_id = new.profile_id
    and s.id not in (
      select id from public.signature_samples
      where profile_id = new.profile_id
      order by created_at desc, id desc
      limit coalesce(keep, 20)
    );
  return null;
end $$;
