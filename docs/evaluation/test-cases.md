# WisePlug — ISO 25010 test cases

Checklist for evaluating WisePlug against the study's specific objectives
(a–d) and the ISO/IEC 25010 quality characteristics: **functional
suitability, reliability, usability and safety**. Fill in *Result* (Pass /
Fail) and *Remarks* for every test. Run each test on **Outlet A and
Outlet B**.

**Setup before testing**
- WisePlug plugged into the wall, online (the app shows **Online**), and the
  app installed and signed in on the test phone.
- Test appliances: an electric fan (3 speeds), a laptop or phone charger, and
  a heating appliance such as a flat iron. Use nothing above 1,760 W.
- For quick safety tests, register an appliance and use it 7 times for about
  1 minute. Its safe time then becomes about 5 minutes.

---

## 1. Functional suitability

### Objective a — Detect and register household appliances when plugged in
| ID | Test | Steps | Expected result | Result | Remarks |
|---|---|---|---|---|---|
| FS-A1 | Detect a load | Plug in a new appliance and switch it on | Within ~5 s the card shows "Finding out what it is…" with its watts | | |
| FS-A2 | New appliance question | Keep a never-registered appliance on for ~60 s | Pop-up "New appliance on Outlet A" (Register / Not now) | | |
| FS-A3 | Register a fan by level | Register → Electric fan → 3 speeds → one sample per speed | "All done!"; the appliance has Level 1–3 in Appliances | | |
| FS-A4 | Live watts while sampling | During a sample | "Measuring: __ W", "Please wait…" and the 60 s timer | | |
| FS-A5 | Same level warned | Sample Level 1 again when Level 2 is asked | "This looks the same as Level 1 … use a DIFFERENT level"; not saved | | |
| FS-A6 | Heating appliance levels | Register a flat iron with 4 heat settings | Level 1–4 are saved (same watts is accepted) | | |
| FS-A7 | Extra samples | At "All done!" tap "Take another sample" | One more sample is saved; "Extra samples saved: 1" | | |
| FS-A8 | Recognize a registered appliance | Unplug, then plug the registered fan in again | "Is this <name>?" pop-up, then the name on the card within ~60 s | | |
| FS-A9 | Recognize on the other outlet | Move the registered appliance to the other outlet | Recognized by name there too | | |
| FS-A10 | Two similar appliances | Plug in an appliance close to a registered one | "Which appliance is on Outlet A?" (never a silent guess) | | |
| FS-A11 | Too-powerful appliance | Try to register a load above 1,760 W (if available) | Refused ("WisePlug cannot power this") | | |
| FS-A12 | Add a setting later | Appliances → appliance → Add a setting → "Level 4" | New setting sampled and listed | | |

### Objective b — Monitor household appliance time usage
| ID | Test | Steps | Expected result | Result | Remarks |
|---|---|---|---|---|---|
| FS-B1 | Running time | Leave an appliance on for 5 min | The card counts up the time used | | |
| FS-B2 | Use recorded | Switch it off | The use appears in the appliance's history with its duration | | |
| FS-B3 | Both outlets at once | Run appliances on A and B together | Each card shows its own time and watts | | |
| FS-B4 | Learning from the last 7 uses | Use one appliance 7 times | "7 of 7" reached; its safe time = average of the last 7 × 1.2 (at least 5 min) | | |
| FS-B5 | Learning keeps updating | Use it an 8th time for a different length | The safe time changes (it uses the newest 7) | | |
| FS-B6 | Run continues after a restart | Tap Restart WisePlug during an idle period, then start an appliance; or let it restart during a run | The run continues with its timer; it is not reset to 0 | | |

### Objective c — Send a notification to the user at the safety limit
| ID | Test | Steps | Expected result | Result | Remarks |
|---|---|---|---|---|---|
| FS-C1 | Warning pop-up | Let an appliance reach its safe time, app open | Pop-up "Still using the …?" with a 60 s countdown and the alarm sound | | |
| FS-C2 | Phone notification | The same, with the app closed | A phone notification with the WisePlug sound | | |
| FS-C3 | Turned-off notice | Do not answer | After 0 s: "… reached its safe time, so WisePlug turned it off." | | |
| FS-C4 | Two outlets at once | Both appliances reach their limit together | "Two appliances reached their safe time", one row each | | |
| FS-C5 | Keep it on | Tap "Keep it on" | Extra time is given; the pop-up closes | | |

### Objective d — Automatically turn off when the appliance exceeds the safety limit
| ID | Test | Steps | Expected result | Result | Remarks |
|---|---|---|---|---|---|
| FS-D1 | Automatic cut-off | Ignore the 60 s warning | The relay switches off at 0 s; the appliance stops | | |
| FS-D2 | Stays off | After FS-D1 | The outlet stays off until "Reset Safety" | | |
| FS-D3 | Turn off now | Tap "Turn off now" in the warning | Off at once, not locked | | |
| FS-D4 | Override limit | Tap "Keep it on" 3 times in one use | On the 4th warning only "Turn off now" is offered | | |
| FS-D5 | Default limit for unknown loads | Run an unregistered appliance | Turned off after 30 min (+60 s warning) | | |
| FS-D6 | Cut-off without internet | Turn the router off during a run | It still turns off at its safe time | | |

---

## 2. Reliability
| ID | Test | Steps | Expected result | Result | Remarks |
|---|---|---|---|---|---|
| RE-1 | Availability | Leave WisePlug on for 24 h | The app shows Online throughout (except planned tests) | | |
| RE-2 | Weak or unstable Wi-Fi | Switch the router off for 2 min, then on | It reconnects by itself within ~1 min | | |
| RE-3 | Setup network | Keep the router off for over 3 min | "wisewp" appears and stays visible on phones | | |
| RE-4 | Wi-Fi setup with mobile data on | Join "wisewp" with mobile data on and open Wi-Fi setup | The app finds the plug and lists networks | | |
| RE-5 | Recovery after a power cut | Unplug WisePlug during a run, then plug it in | The outlet comes back off and locked ("Power cut"); Reset Safety works | | |
| RE-6 | Recovery after a restart | Restart WisePlug from Settings | Back online within ~20 s; settings kept | | |
| RE-7 | Meter dropout | (Observe) a meter stops answering | "Not measuring" shows; a running appliance is warned, then turned off; it recovers by itself | | |
| RE-8 | Data reliability | Run the queries in `reliability.sql` | See `reliability-results.md` | | |

## 3. Usability
| ID | Test | Steps | Expected result | Result | Remarks |
|---|---|---|---|---|---|
| US-1 | First-time setup | A new user sets up Wi-Fi with the help screen only | Done without help in ≤ 10 min | | |
| US-2 | Register without help | A new user registers a fan | Done without help | | |
| US-3 | Understand a warning | Show the warning pop-up to a user | They can say what will happen at 0 s | | |
| US-4 | Help | Settings → How to use WisePlug | Every topic is readable and clear | | |
| US-5 | Small screens and large text | Phone with the largest font size | No text is cut off; all buttons can be reached | | |
| US-6 | Usability survey | Respondents use the app, then answer `usability-survey.md` | SUS score ≥ 68 (above average) | | |

## 4. Safety
| ID | Test | Steps | Expected result | Result | Remarks |
|---|---|---|---|---|---|
| SA-1 | Overcurrent | A load above 10 A (simulated or a test load) | Off at once ("Too much current"), locked | | |
| SA-2 | Overload | Above 8 A for more than 10 s | Off and locked | | |
| SA-3 | Abnormal power | A recognized non-charger draws ≥ 2× its normal power | Off and locked (POWER_ANOMALY) | | |
| SA-4 | Chargers are not tripped by battery changes | A charger's power rises during charging | It stays on (overcurrent still protects it) | | |
| SA-5 | No restart after a power cut | Power cut during a run | It does not switch on by itself afterwards | | |
| SA-6 | Old commands ignored | Tap a button while offline, come back online after 30 s | The old command is not carried out | | |
| SA-7 | Only the owner | Sign in with a second account | Cannot see or control the plug; must pair near it | | |
| SA-8 | Linking only when near | Second account, away from home (mobile data), taps Pair | "No WisePlug answered" | | |
