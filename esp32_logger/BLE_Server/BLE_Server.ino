#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>  // ← THÊM: Descriptor cho notification

#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_UUID           "57049b24-3c16-4079-b038-76cebc5aa16d"

// ====== GPIO ======
#define PIN_RPM 27
#define PIN_AFR 34
#define PIN_MAP 35

// ====== RPM ======
volatile unsigned long rpm_pulse = 0;
unsigned long last_rpm_time = 0;
float rpm_value = 0;

// ====== BLE ======
BLECharacteristic *pChar;
bool deviceConnected = false;  // ← THÊM: tracking connection

volatile unsigned long last_us = 0;

// ← THÊM: Callback để biết khi nào device connect/disconnect
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("Client connected!");
  }

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("Client disconnected!");
    // Restart advertising để device khác có thể kết nối
    BLEDevice::getAdvertising()->start();
  }
};

void IRAM_ATTR rpm_isr() {
  unsigned long now = micros();
  if (now - last_us > 200) { // bỏ xung <200us
    rpm_pulse++;
    last_us = now;
  }
}

void setup() {
  Serial.begin(115200);

  // --- RPM ---
  pinMode(PIN_RPM, INPUT);
  attachInterrupt(digitalPinToInterrupt(PIN_RPM), rpm_isr, FALLING);

  // --- ADC ---
  analogReadResolution(12);   // 0–4095
  analogSetAttenuation(ADC_11db); // ~0–3.3V

  // --- BLE ---
  BLEDevice::init("ESP32_Logger");
  BLEServer *pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());  // ← THÊM: Callback

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pChar = pService->createCharacteristic(
    CHAR_UUID,
    BLECharacteristic::PROPERTY_NOTIFY |
    BLECharacteristic::PROPERTY_READ
  );

  // ← THÊM: Descriptor cho notification (quan trọng!)
  pChar->addDescriptor(new BLE2902());
  
  pChar->setValue("READY");
  pService->start();

  BLEAdvertising *pAdv = BLEDevice::getAdvertising();
  pAdv->addServiceUUID(SERVICE_UUID);  // ← THÊM: Advertise service UUID
  pAdv->setScanResponse(true);
  pAdv->setMinPreferred(0x06);  // connection interval
  pAdv->start();

  Serial.println("BLE started, waiting for connection...");
}

void loop() {
  // ====== TÍNH RPM (mỗi 500ms) ======
  if (millis() - last_rpm_time >= 500) {
    noInterrupts();
    unsigned long pulse = rpm_pulse;
    rpm_pulse = 0;
    interrupts();

    // CKP 1 răng → pulse/0.5s * 120 = RPM
    rpm_value = pulse * 120.0;
    last_rpm_time = millis();
  }

  // ====== ĐỌC AFR ======
  int adc_afr = analogRead(PIN_AFR);
  float v_afr = adc_afr * 3.3 / 4095.0;
  // AFR controller 0–5V = AFR 10–20
  float afr = (v_afr / 3.3) * 10.0 + 10.0;

  // ====== ĐỌC MAP ======
  // ====== ĐỌC MAP (GM 25195786 + chia áp + bù lệch) ======
int adc_map = analogRead(PIN_MAP);

// điện áp tại ADC (0–3.3V)
float v_adc = adc_map * 3.3 / 4095.0;

// khôi phục điện áp thực MAP (20k/10k)
float v_map = v_adc * 3.0;

// bù lệch sensor
v_map -= 0.85;

// chặn ngưỡng an toàn
if (v_map < 0.5) v_map = 0.5;
if (v_map > 4.5) v_map = 4.5;

// GM 1 bar: 0.5–4.5V → 10–105 kPa
float map_kpa = (v_map - 0.5) * (105.0 / 4.0) + 10.0;

  // ====== GỬI BLE ======
  char buf[64];
  snprintf(buf, sizeof(buf),
         "RPM=%d;AFR=%.1f;MAP=%.0f",
         (int)rpm_value, afr, map_kpa);

  // ← THÊM: Chỉ notify khi có device kết nối
  if (deviceConnected) {
    pChar->setValue(buf);
    pChar->notify();
    Serial.print("Sent: ");
    Serial.println(buf);
  } else {
    // Debug khi chưa có connection
    Serial.print("No connection - Data: ");
    Serial.println(buf);
  }
  
  delay(300);
}