#pragma once
// Copy to secrets.h (git-ignored) and fill in. Never put these in the app.
#define FIREBASE_HOST "wise-46f92-default-rtdb.asia-southeast1.firebasedatabase.app"

// The plug's own Firebase login (recommended). The database rules let this
// account write only what the plug writes (docs/live-gui.md, "The plug's own
// login"). FIREBASE_API_KEY is the Web API key (Firebase console > Project
// settings > General). With these set, FIREBASE_AUTH is not used.
// #define FIREBASE_API_KEY "YOUR_WEB_API_KEY"
// #define FIREBASE_DEVICE_EMAIL "plug-gadget-1@example.com"
// #define FIREBASE_DEVICE_PASSWORD "choose-a-long-password"

// Old way: the database secret, which can read and change the whole
// database. Only used when FIREBASE_DEVICE_EMAIL is not set.
#define FIREBASE_AUTH "YOUR_DATABASE_SECRET"

// Optional: Supabase session history and safety alerts (docs/hybrid-architecture.md).
// Leave both commented out to build without Supabase.
// #define SUPABASE_FUNCTIONS_URL "https://YOUR-PROJECT-REF.supabase.co/functions/v1"
// #define SUPABASE_DEVICE_KEY "same value as: npx supabase secrets set DEVICE_KEY=..."

// Optional: firmware updates over Wi-Fi from the Arduino IDE (Tools > Port >
// "wiseplug-gadget-1"). Only while both outlets are idle or off.
// #define OTA_PASSWORD "choose-a-long-password"
