# WisePlug hardware test

A short check of the whole system on the real plug: plug, Firebase, Supabase
and the app together. Do it after every firmware upload and before a
demonstration. Write the result (pass / fail and what you saw) next to each
step.

**Mains safety:** the plug is on 220 V. Unplug it from the wall before
touching any wire. Nothing at 220 V goes on the breadboard.

## Before you start

- [ ] **Both outlets are empty.** Uploading while an appliance runs restarts
      the plug mid-run, and that outlet comes back "Turned off for safety"
      (the power-cut rule, on purpose).
- [ ] Upload `arduino/wiseplug_esp32/wiseplug_esp32.ino`: Tools → Partition
      Scheme → **Minimal SPIFFS**, the right COM port.
- [ ] Serial Monitor at 115200 baud, timestamps on (clock icon).
- [ ] The app is open and signed in (`flutter run`, press **R** after code
      changes).

## 1. Start-up

| Do | Expect |
|---|---|
| Plug the plug into the wall | Serial: `SYSTEM READY`, `Meter answering: outlet may be on` (A and B), `Wi-Fi: online …`; no `Backtrace` |
| Look at the app | **Online**, WisePlug WP-001; both cards **Ready to use** |
| Firebase → `devices/gadget-1/status/health` | `largestBlock` above about 40000; `lastRestart` empty |

## 2. A meter that stops

| Do | Expect |
|---|---|
| Unplug the plug's cord from the wall (USB stays) | After 15 s both cards **Not ready**; switches greyed out |
| Plug the cord back in | Both back to **Ready to use** by themselves |

## 3. Register a new appliance (Outlet A)

| Do | Expect |
|---|---|
| Plug a fan into A, switch it on | Card: **Finding out what it is… This takes about 20 seconds**; within ~25 s the **Something new on Outlet A** pop-up |
| Register it (type, name, levels) and follow each step | Each step: "Please wait… measuring Level N", "On for … s of about 60 s", then "Sample N done! Now turn it off". The time in the pop-up matches the card's "On for" |
| Finish all levels | "All done! WisePlug knows … now." |
| Serial during registration | `Stage 1 …`, `Stage 2 …`; **no** `not delivered`, **no** `LOCKED OUT` |

## 4. Recognition on both outlets

| Do | Expect |
|---|---|
| Fan into A, switch on | Within ~25 s the card names it |
| Switch off, move it to B, switch on | Within ~25 s B names it (not "Something new", not "Another fan?") |

## 5. Safe time (the only pop-up)

For a quick test, register a type with a short safe time or wait out the
30-minute default with an unconfirmed appliance.

| Do | Expect |
|---|---|
| Let the safe time run out | Pop-up **Safe time is up**, "Still using the …?", countdown, sound |
| Press **Keep it on** | Pop-up closes; "OK, it stays on a little longer" |
| Next time, let the 60 s run out | Outlet off; pop-up **Turned off for safety** |
| **Reset Safety** | Card **Reset done**; outlet stays off |
| **Turn on again** (confirm) | Card **Ready to use** |

## 6. A missed meter reading during a run

| Do | Expect |
|---|---|
| Run the fan for a few minutes | Serial may show `PZEM not responding` once; the outlet stays **on**, no warning |

## 7. Power cut during a run

| Do | Expect |
|---|---|
| Fan running on A, unplug the plug from the wall, plug it back in | A comes back **Turned off for safety**; B as it was |
| Reset Safety → Turn on again | A **Ready to use** |

## 8. After the test

- [ ] Firebase health: `largestBlock` still above about 40000
- [ ] Supabase → Edge Functions → `recognize-appliance` → Logs: the calls
      from the test, status 200
- [ ] Supabase → `outlet_sessions`: no run left with an empty `ended_at`
      once everything is switched off (allow a few seconds)
