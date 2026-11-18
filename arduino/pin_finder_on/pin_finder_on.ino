// WisePlug pin finder: asks for a PZEM-004T on every RX/TX pair of the four
// meter pins and prints which pairs answer. Both outlets stay ON: use only a fan.
const int RELAY_A = 13, RELAY_B = 12;
const int PINS[4] = {25, 26, 32, 33};

uint16_t crc16(const uint8_t* d, size_t n) {
  uint16_t c = 0xFFFF;
  for (size_t i = 0; i < n; ++i) {
    c ^= d[i];
    for (int b = 0; b < 8; ++b) c = (c & 1) ? (c >> 1) ^ 0xA001 : c >> 1;
  }
  return c;
}

// Returns the mains voltage, or -1 if nothing valid answered.
float ask(int espRx, int espTx) {
  Serial2.begin(9600, SERIAL_8N1, espRx, espTx);
  delay(50);
  while (Serial2.available()) Serial2.read();
  uint8_t req[8] = {0xF8, 0x04, 0x00, 0x00, 0x00, 0x0A};
  uint16_t c = crc16(req, 6);
  req[6] = c & 0xFF; req[7] = c >> 8;
  Serial2.write(req, 8);
  Serial2.flush();
  uint8_t r[25]; size_t n = 0;
  uint32_t start = millis();
  while (n < sizeof r && millis() - start < 300) {
    if (Serial2.available()) r[n++] = Serial2.read();
  }
  Serial2.end();
  pinMode(espRx, INPUT); pinMode(espTx, INPUT);
  if (n != sizeof r) return -1;
  uint16_t got = r[23] | (r[24] << 8);
  if (got != crc16(r, 23)) return -1;
  return ((r[3] << 8) | r[4]) / 10.0f;
}

void setup() {
  pinMode(RELAY_A, OUTPUT); digitalWrite(RELAY_A, HIGH);
  pinMode(RELAY_B, OUTPUT); digitalWrite(RELAY_B, HIGH);
  Serial.begin(115200);
  delay(1000);
}

void loop() {
  Serial.println("Searching for PZEMs (outlets are ON)...");
  int found = 0;
  for (int rx : PINS) for (int tx : PINS) {
    if (rx == tx) continue;
    float v = ask(rx, tx);
    if (v >= 0) {
      Serial.printf("FOUND: PZEM TX on GPIO %d, PZEM RX on GPIO %d, %.1f V\n", rx, tx, v);
      ++found;
    }
  }
  Serial.printf("Done: %d found\n---\n", found);
  delay(3000);
}
