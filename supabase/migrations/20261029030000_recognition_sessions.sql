-- Rule-based recognition: fields the Edge Functions need (Phase 2).
--
--   recognition_config.min_learned_cutoff_minutes   7-use learning: a learned
--                     cutoff is never shorter than this (was MIN_LEARNED_LIMIT_S
--                     in the firmware)
--   recognition_config.min_session_s                runs shorter than this do
--                     not count as a use (was MIN_SESSION_S)
--   outlet_sessions.confirmed_by   who confirmed a MATCHED_CONFIRMED load:
--                     'stage2' (Stage 2 agreed with Stage 1), 'user' (confirm-match)
--                     or 'registration' (register-sample)
--   outlet_sessions.sample_recorded   the run already updated a signature
--                     (registration sample or EMA after a user confirmation)

alter table public.recognition_config
  add column min_learned_cutoff_minutes integer not null default 5 check (min_learned_cutoff_minutes between 1 and 240),
  add column min_session_s              integer not null default 10 check (min_session_s between 0 and 600);

alter table public.outlet_sessions
  add column confirmed_by    text check (confirmed_by in ('stage2', 'user', 'registration')),
  add column sample_recorded boolean not null default false,
  add constraint outlet_sessions_confirmed_status_check
    check ((status = 'MATCHED_CONFIRMED') = (confirmed_by is not null));

-- One sample per run per profile: a retried request cannot count a run twice.
create unique index signature_samples_profile_event_idx
  on public.signature_samples (profile_id, event_id) where profile_id is not null and event_id is not null;
