# wiseplug_alarm

WisePlug's own Android code for the safety countdown alarm (no third-party
library). Used by `lib/services/countdown_alarm.dart`.

- `CountdownAlarmService`: a foreground service that loops the warning sound on
  the ALARM stream and shows the countdown notification (appliance, outlet,
  time left, "Stop alarm", full-screen alert on the lock screen).
- `CountdownBackupReceiver`: the backup exact alarm at an outlet's safety
  deadline; it checks the outlet in Firebase before it rings.
- `WiseplugAlarmPlugin`: the method channel `wiseplug/alarm`, the phone-setup
  status and the brand settings pages.
