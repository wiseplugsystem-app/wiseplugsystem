-- Store and forward: the plug keeps its run summaries and safety reports in
-- flash until they are stored here, and uploads them in batches
-- (ingest-batch) when the internet is back. Retries are already harmless:
-- sessions are unique per (device, outlet, started_at), alert_logs per event_id.
--
-- A report made before the plug ever learned the time (no internet since it
-- started) and still waiting when it restarted cannot be dated exactly: it is
-- stored with the time it arrived and marked time_estimated.
alter table public.sessions   add column time_estimated boolean not null default false;
alter table public.alert_logs add column time_estimated boolean not null default false;

-- Upload delay (thesis: time from the end of a run to its arrival here).
create view public.upload_delay with (security_invoker = true) as
select device_id,
       outlet,
       ended_at,
       created_at                                          as received_at,
       extract(epoch from created_at - ended_at)::integer  as delay_s,
       time_estimated
from public.sessions;

revoke all on public.upload_delay from anon;
