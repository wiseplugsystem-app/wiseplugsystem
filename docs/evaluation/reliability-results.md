# WisePlug — Reliability results so far (2026-11-21)

Computed with [reliability.sql](reliability.sql) from the real data in
Supabase, covering 2026-10-29 to 2026-11-20. These numbers include
development and testing, so run the queries again after the formal
evaluation and report those.

| Objective / quality | Measure | Result |
|---|---|---|
| a) Detect and register (functional correctness) | Labeled runs recognized correctly or correctly called "new" | **9 of 9** (8 correct, 1 new detected, 0 wrong). Runs of appliances later deleted are not counted. |
| b) Monitor time usage | Runs recorded / with an end time | **386 / 386** runs, **193.9 h** monitored |
| b) Monitor time usage | Run ends reported by the plug itself | **321 of 386 (83 %)**. 65 were closed by Supabase because the report never arrived: 26 on 2026-11-12 (an early bug, since fixed), and 0–6 a day since 2026-11-16. |
| c) Notify at the safety limit | Alerts that reached at least one phone, since push was set up (2026-11-09) | **80 of 94 (85 %)**. Every alert on 11-09 to 11-17 and 11-19 to 11-20 was delivered; the 14 misses were all on 2026-11-18, 3:56–6:45 pm, most likely while no phone was signed in. |
| d) Turn off automatically | Safe-time cut-offs on time (≤ 60 s after the safe time, the warning countdown) | **13 of 13**, 15–60 s after the limit (average 53 s) |
| Safety | Safety events handled | 1 overcurrent and 1 power anomaly (both cut off at once), 30 lockouts |
| Reliability (fault tolerance) | "Meter not answering" events | **55**, mostly on Outlet A. Each was handled safely (a warning, then off), but this is the main reliability issue. |

**Watchdog restarts:** the plug restarted itself after a freeze at least
once (its last restart reason is "watchdog"). The cause is being
investigated.
