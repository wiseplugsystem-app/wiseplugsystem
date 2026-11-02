// Makes WisePlug's warning sounds (WAV, 22.05 kHz, 16-bit mono) from plain
// sine waves, so they are entirely our own work, released as CC0
// (assets/sounds/LICENSE.md). Run again after changing a number:
//
//   node tool/make_warning_tone.ts
//
// The tone: two short beeps, the first at 1 kHz and the second at 2.5 kHz.
// ISO 7731 (auditory danger signals) asks for a pulsed signal clearly
// different from the surroundings, with its main energy low enough (about
// 0.5-1.5 kHz) to be heard by people with some hearing loss and through a
// door; the 2.5 kHz beep keeps it sharp. It is NOT the "3 beeps, pause"
// evacuation rhythm (ISO 8201 Temporal-3), which people associate with fire.
//
//   assets/sounds/warning_tone.wav  one pair of beeps (the app repeats it:
//                                   every 4 s, every 1 s in the last 10 s)
//   assets/sounds/cutoff_tone.wav   one long beep (1.5 s) when power is cut
//   android/app/src/main/res/raw/wiseplug_warning.wav
//                                   the push notification sound: the pair
//                                   twice (a notification plays it once)
import fs from "node:fs";
import path from "node:path";

const RATE = 22050;
const LEVEL = 0.8;     // peak, 0..1 (the app sets the playback volume)
const FADE_S = 0.008;  // soft start and end: no clicks

/** A beep of [seconds] mixing [frequencies] (Hz), or silence for []. */
function tone(seconds: number, frequencies: number[]): number[] {
  const n = Math.round(seconds * RATE), fade = Math.round(FADE_S * RATE), out: number[] = [];
  for (let i = 0; i < n; i++) {
    if (!frequencies.length) { out.push(0); continue; }
    const envelope = Math.min(1, i / fade, (n - 1 - i) / fade);
    const s = frequencies.reduce((sum, f) => sum + Math.sin((2 * Math.PI * f * i) / RATE), 0) / frequencies.length;
    out.push(s * envelope * LEVEL);
  }
  return out;
}
const beepPair = () => [...tone(0.15, [1000]), ...tone(0.12, []), ...tone(0.15, [2500])];

function wav(samples: number[]): Buffer {
  const data = Buffer.alloc(samples.length * 2);
  samples.forEach((s, i) => data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, s)) * 32767), i * 2));
  const header = Buffer.alloc(44);
  header.write("RIFF", 0); header.writeUInt32LE(36 + data.length, 4); header.write("WAVE", 8);
  header.write("fmt ", 12); header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(RATE, 24); header.writeUInt32LE(RATE * 2, 28); header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34);
  header.write("data", 36); header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}

const files: Record<string, number[]> = {
  "assets/sounds/warning_tone.wav": [...beepPair(), ...tone(0.05, [])],
  // One long beep: both frequencies together, so it is the same "voice".
  "assets/sounds/cutoff_tone.wav": tone(1.5, [1000, 2500]),
  "android/app/src/main/res/raw/wiseplug_warning.wav": [...beepPair(), ...tone(0.6, []), ...beepPair()],
};
for (const [file, samples] of Object.entries(files)) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, wav(samples));
  console.log(`${file}: ${(samples.length / RATE).toFixed(2)} s`);
}
