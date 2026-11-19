-- Override limit: how many times "Keep it on" may extend one use of an
-- appliance. The plug gets it with every recognition answer and enforces it
-- (3 until then, or without Supabase). At the limit the safe-time warning
-- still shows, with only "Turn off now"; unanswered, the outlet turns off and
-- locks as before.
alter table public.recognition_config
  add column max_overrides integer not null default 3
    check (max_overrides between 0 and 20);
