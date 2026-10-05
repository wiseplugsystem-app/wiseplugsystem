# Class diagram alignment

Models use User, WiseplugDevice, ApplianceProfile, TelemetryLog, AnomalyAlert and SmartOverride. Diagram types are unspecified; deviceStatus/currentState are strings and detectAppliance is a boolean state flag.

Include these necessary extensions in the diagram:

| Class | Extra fields | Purpose |
| --- | --- | --- |
| ApplianceProfile | isOn, outlet, startTime | Dual outlet control and runtime |
| TelemetryLog | timestamp | Order readings |
| AnomalyAlert | profileID | Select appliance for shutdown |
| DetectedAppliance (extra class) | outlet, estimatedWattage, signature, suggestedType | Pattern registration |

UI state is separate from domain attributes. Operations are distributed between widgets and FirebaseBackendService, rather than implemented on every model.

## User configuration

Overrides read devices/{deviceID} and users/{userID}. Configure WISEPLUG_USER_ID with --dart-define=WISEPLUG_USER_ID=your-user-id. The user record must exist and match device.userID. Missing configuration produces an error instead of a fictional identity.

This is configuration, not authentication. This repository has no sign-in flow. Production authorization requires Firebase authentication and server rules. These changes do not create database records or deploy rules.

Power changes set server startTime on activation and clear it on shutdown. Home uses startTime and safetyCeilingDuration for remaining time. Registration uses estimatedWattage for baselineWattage; other limits retain model defaults. Firmware/backend enforcement remains outside this Flutter repository.
