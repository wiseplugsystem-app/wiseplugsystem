// WisePlug meter test: reads both PZEM-004T meters and prints what they say.
// Both outlets stay OFF. Nothing here uses Wi-Fi or the cloud.
#include <PZEM004Tv30.h>

const int RELAY_A = 13, RELAY_B = 12;  // same pins as the main firmware

PZEM004Tv30 meterA(Serial2, 32, 33);   // meter TX -> GPIO 32, meter RX -> GPIO 33
PZEM004Tv30 meterB(Serial1, 25, 26);   // meter TX -> GPIO 25, meter RX -> GPIO 26

void show(const char* name, PZEM004Tv30& m) {
  float v = m.voltage();
  if (isnan(v)) Serial.printf("Outlet %s: NO ANSWER\n", name);
  else Serial.printf("Outlet %s: %.1f V, %.3f A, %.1f W\n", name, v, m.current(), m.power());
}

void setup() {
  pinMode(RELAY_A, OUTPUT); digitalWrite(RELAY_A, LOW);
  pinMode(RELAY_B, OUTPUT); digitalWrite(RELAY_B, LOW);
  Serial.begin(115200);
  delay(1000);
  Serial.println("WisePlug meter test (outlets are OFF)");
}

void loop() {
  show("A", meterA);
  show("B", meterB);
  Serial.println("---");
  delay(2000);
}
