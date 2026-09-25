'use strict';
const {onValueWritten} = require('firebase-functions/v2/database');
const {initializeApp} = require('firebase-admin/app');
const {getDatabase} = require('firebase-admin/database');
const {getMessaging} = require('firebase-admin/messaging');
initializeApp();

// Firmware remains the sole safety authority. This function only delivers alerts.
exports.safetyAlert = onValueWritten({
  ref: '/alerts/{alertID}', region: 'asia-southeast1', retry: true,
}, async (event) => {
  const after = event.data.after.val();
  const before = event.data.before.val();
  if (!after || !['PENDING', 'SHUTDOWN'].includes(after.resolution) || before?.resolution === after.resolution) return;
  const db = getDatabase();
  // Re-read to avoid delivering an obsolete countdown after a delayed trigger.
  const latest = (await event.data.after.ref.get()).val();
  if (!latest || latest.resolution !== after.resolution) return;
  const uid = (await db.ref(`device_owners/${after.deviceID}`).get()).val();
  if (typeof uid !== 'string' || !uid) return;
  const preferences = (await db.ref(`users/${uid}/preferences`).get()).val() || {};
  if (preferences.deviceAlerts === false || preferences.safetyWarnings === false) return;
  const tokens = Object.keys((await db.ref(`users/${uid}/fcmTokens`).get()).val() || {});
  const expired = after.resolution === 'SHUTDOWN' || Date.parse(after.countdownExpiry) <= Date.now();
  const notification = {
    title: expired ? 'WisePlug: physical inspection required' : 'WisePlug: safety limit exceeded',
    body: expired ? 'Inspect and unplug the appliance. Check the outlet state in WisePlug; reset requires its physical button.' :
      'Open WisePlug to request more time before the device locks. Software lockout does not disconnect power.',
  };
  for (let offset = 0; offset < tokens.length; offset += 500) {
    const batch = tokens.slice(offset, offset + 500);
    const result = await getMessaging().sendEachForMulticast({
      tokens: batch, notification,
      data: {alertID: event.params.alertID, deviceID: after.deviceID, resolution: after.resolution},
      android: {priority: 'high', ttl: 60000, notification: {tag: event.params.alertID, sound: 'default'}},
      apns: {headers: {'apns-priority': '10', 'apns-collapse-id': event.params.alertID.slice(0, 64)}, payload: {aps: {sound: 'default'}}},
    });
    let retry = false;
    await Promise.all(result.responses.map(async (response, index) => {
      const code = response.error?.code;
      if (['messaging/registration-token-not-registered', 'messaging/invalid-registration-token'].includes(code)) {
        await db.ref(`users/${uid}/fcmTokens/${batch[index]}`).remove();
      } else if (response.error) { retry = true; }
    }));
    if (retry) throw new Error('Transient FCM delivery failure; retrying');
  }
});
