#pragma once
// Copy to secrets.h (git-ignored) and fill in. Never put these in the app.
#define FIREBASE_HOST "wise-46f92-default-rtdb.asia-southeast1.firebasedatabase.app"
#define FIREBASE_AUTH "YOUR_DATABASE_SECRET"

// Optional: Supabase session history and safety alerts (docs/hybrid-architecture.md).
// Leave both commented out to build without Supabase.
// #define SUPABASE_FUNCTIONS_URL "https://YOUR-PROJECT-REF.supabase.co/functions/v1"
// #define SUPABASE_DEVICE_KEY "same value as: npx supabase secrets set DEVICE_KEY=..."

// Optional: firmware updates over Wi-Fi from the Arduino IDE (Tools > Port >
// "wiseplug-gadget-1"). Only while both outlets are idle or off.
// #define OTA_PASSWORD "choose-a-long-password"
