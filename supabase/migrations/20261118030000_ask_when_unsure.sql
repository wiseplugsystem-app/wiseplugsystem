-- The user decides when WisePlug cannot.
--
-- 1. ask_when_several_match: when more than one registered appliance passes
--    every check (two appliances with the same wattage, e.g. a fan and a
--    charger), WisePlug no longer picks the best score by itself: it asks
--    "Is this Fan or Purple charger?" with every appliance that fits, plus
--    "Register new appliance" (the app's AMBIGUOUS prompt).
-- 2. ask_chargers: a wall meter sees what the phone on a charger draws, not
--    the charger, so one charger cannot be told from another. A charger match
--    is never confirmed by itself at Stage 2: it stays "Is this Purple
--    charger?" (Yes / No, register a new appliance) until the user answers.
--    Until then the run keeps the 30-minute default, and it does not count
--    toward the charger's 7-use learning.
--
-- Both default to on; set either to false for the previous automatic choice.
alter table public.recognition_config
  add column ask_when_several_match boolean not null default true,
  add column ask_chargers           boolean not null default true;
