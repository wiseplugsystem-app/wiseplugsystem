// WisePlug relay test: blinks each SSR in turn so its red LED can be watched.
// Unplug every appliance from the outlets before running this.
const int RELAY_A = 13, RELAY_B = 12;  // same pins as the main firmware

void setup() {
  pinMode(RELAY_A, OUTPUT); digitalWrite(RELAY_A, LOW);
  pinMode(RELAY_B, OUTPUT); digitalWrite(RELAY_B, LOW);
  Serial.begin(115200);
}

void blink(const char* name, int pin) {
  Serial.printf("SSR %s: ON (its red LED should be lit)\n", name);
  digitalWrite(pin, HIGH); delay(3000);
  Serial.printf("SSR %s: OFF\n", name);
  digitalWrite(pin, LOW); delay(2000);
}

void loop() {
  blink("A", RELAY_A);
  blink("B", RELAY_B);
}
