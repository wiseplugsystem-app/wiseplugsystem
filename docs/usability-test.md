# WisePlug usability test

A short test with real users, for example older family members or neighbours
who don't use apps much. One session takes about 30 minutes per person.
Five people are enough to find most problems.

## Before the session

1. Set up a WisePlug with a working Wi-Fi network and one registered
   appliance on Outlet A (for example an electric fan).
2. Have a second appliance ready that is **not** registered yet (for example
   a rice cooker or a kettle).
3. Set the fan's safety limit to a short time (for example 3 minutes) so the
   warning comes during the session. Put it back afterwards.
4. Sign in on the test phone. Set the phone's text size to the size the
   person normally uses.
5. Prepare a sheet for each person: a participant number (no names), age
   range, how often they use smartphone apps, and a table for the tasks
   below.

## What to say at the start

> "We are testing the app, not you. There are no wrong answers. Please say
> out loud what you are thinking while you use it. I can't help you during
> the tasks, but you can stop at any time."

## Tasks

Read each task out loud and give the person the phone. Don't point at the
screen or name buttons. Stop a task after 3 minutes, or after the person
gives up twice.

| # | Task (what you say) | Done when |
|---|---|---|
| 1 | "Find out what is plugged into the WisePlug right now and how much power it is using." | They say the fan's name and the watts shown on Home. |
| 2 | "Turn off the socket the fan is plugged into, then turn it back on." | Outlet A shows Turned off, then In use again. |
| 3 | "Plug in this new appliance and add it to the app." | They answer "What are you adding?" and the appliance shows in Appliance Profiles. |
| 4 | "The fan has been on a long time. When the phone warns you, decide what to do." | They read the warning and choose to keep it on or let it turn off, on purpose. |
| 5 | "The WisePlug turned the fan off for safety. Turn it back on." | They reset the outlet and the fan runs again. |
| 6 | "Find out how long the fan may stay on before WisePlug turns it off." | They open the fan in Appliance Profiles and read its Safety limit. |

## What to write down for each task

- **Done**: yes, with help, or no.
- **Time** in seconds, from giving the phone to "done".
- **Wrong taps**: how many times they tapped something that didn't help.
- **Where they got stuck**, and their words (for example "I don't know what
  this means").
- **Words they didn't understand**: write the exact word.
- **Text too small or hard to see**: did they lean in, squint or zoom?

## After the tasks

1. Give the questionnaire below on paper. Read it out loud if needed.
2. Ask:
   - "What was the hardest part?"
   - "Was any word confusing?"
   - "Would you use this at home? Why or why not?"
3. Thank them. Put the fan's safety limit back.

## Questionnaire (System Usability Scale, SUS)

For each sentence, circle one number: **1 = strongly disagree** and
**5 = strongly agree**.

| # | Sentence | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| 1 | I think that I would like to use this app often. | | | | | |
| 2 | I found the app unnecessarily complex. | | | | | |
| 3 | I thought the app was easy to use. | | | | | |
| 4 | I think that I would need the help of a technical person to be able to use this app. | | | | | |
| 5 | I found the various functions in this app were well integrated. | | | | | |
| 6 | I thought there was too much inconsistency in this app. | | | | | |
| 7 | I would imagine that most people would learn to use this app very quickly. | | | | | |
| 8 | I found the app very cumbersome to use. | | | | | |
| 9 | I felt very confident using the app. | | | | | |
| 10 | I needed to learn a lot of things before I could get going with this app. | | | | | |

Keep the wording and the order: the scoring depends on them. If you
translate it (for example to Tagalog), use a tested translation and say so
in your report.

### Scoring

1. **Odd sentences** (1, 3, 5, 7, 9): the answer minus 1.
2. **Even sentences** (2, 4, 6, 8, 10): 5 minus the answer.
3. Add the ten numbers (0 to 40) and **multiply by 2.5**. That gives a
   score from 0 to 100. It is not a percentage.

Example: answers 4, 2, 5, 1, 4, 2, 4, 2, 4, 1 give
3 + 3 + 4 + 4 + 3 + 3 + 3 + 3 + 3 + 4 = 33, and 33 × 2.5 = **82.5**.

### What the score means

| Score | Meaning |
|---|---|
| Above 80 | Very good |
| About 68 | Average (the usual benchmark) |
| Below 50 | Serious problems; fix before release |

Report the average score and the lowest score. With five people, the
problems you watched in the tasks matter more than the exact number.

## References

- Brooke, J. (1996). SUS: A "quick and dirty" usability scale. In
  *Usability Evaluation in Industry*, 189–194. Taylor & Francis.
- Bangor, A., Kortum, P., & Miller, J. (2009). Determining what individual
  SUS scores mean: Adding an adjective rating scale. *Journal of Usability
  Studies*, 4(3), 114–123.
- Nielsen, J., & Landauer, T. K. (1993). A mathematical model of the finding
  of usability problems. *Proceedings of INTERCHI '93*, 206–213.
- W3C (2023). *Web Content Accessibility Guidelines (WCAG) 2.2*,
  1.4.3 Contrast (Minimum) and 2.5.8 Target Size.
