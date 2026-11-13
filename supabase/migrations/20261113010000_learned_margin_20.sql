-- The learned safe time: an appliance's typical running time (after 7 uses)
-- plus a 20 % buffer, as the thesis states (Chapter II, after UARP [30]):
-- 60 minutes of typical use -> a 72-minute safe time. It was x 1.5 (+50 %).
-- Still never above the appliance type's own safe time, never below
-- min_learned_cutoff_minutes.
update public.recognition_config set learned_margin = 1.20;
