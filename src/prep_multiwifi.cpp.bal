#include <Arduino.h>
#include <LiquidCrystal_I2C.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <HTTPClient.h>
#include <HTTPUpdate.h>
#include <Preferences.h>
#include "esp_wifi.h"
#include "esp_system.h"

#if __has_include("esp_mac.h")
#include "esp_mac.h"
#endif

// =====================================================
// SETTING JENIS ALAT
// HANYA ADA 2 JENIS:
// "in"  = alat input
// "out" = alat output
// =====================================================
#define DEVICE_MODE "out"

// Reject hanya fitur tambahan alat OUT.
// Walaupun true, fitur ini TIDAK aktif jika DEVICE_MODE = "in".
#define ENABLE_REJECT true

// =====================================================
// WIFI CONFIG - MULTI WIFI FAILOVER
// =====================================================
//
// Urutan:
// 1. SSID terakhir yang sukses disimpan di NVS.
// 2. Boot berikutnya mencoba SSID terakhir terlebih dahulu.
// 3. Jika belum ada SSID tersimpan:
//      Tracked -> Tracked (2) -> ... -> Tracked (8)
// 4. Jika gagal, scan seluruh SSID whitelist.
// 5. Hasil scan dicoba berdasarkan RSSI paling kuat.
// 6. Jika berhasil, SSID baru disimpan untuk boot berikutnya.
// =====================================================

const char* WIFI_SSIDS[] = {
  "Tracked",
  "Tracked (2)",
  "Tracked (3)",
  "Tracked (4)",
  "Tracked (5)",
  "Tracked (6)",
  "Tracked (7)",
  "Tracked (8)",
  "Tracked (9)"
};

const size_t WIFI_COUNT =
  sizeof(WIFI_SSIDS) / sizeof(WIFI_SSIDS[0]);

const char* WIFI_PASS = "Factory@RFID";

const unsigned long WIFI_CONNECT_TIMEOUT_MS = 8000;
const unsigned long WIFI_RESCAN_MS = 5000;

Preferences wifiPrefs;
String savedWifiSsid = "";

// =====================================================
// MQTT CONFIG
// Topic v2 agar tidak bentrok dengan flow lama
// =====================================================
const char* mqtt_server = "10.5.2.223";
const int mqtt_port = 1883;
const char* MQTT_BASE = "rfid/batch/v2";

// =====================================================
// OTA UPDATE DARI SERVER LOKAL
// =====================================================
const char *OTA_BASE_URL = "http://10.5.0.106/firmware/";
const unsigned long OTA_HOLD_TIME = 5000;

// =====================================================
// PIN CONFIG
// =====================================================
#define RFID_RX_PIN 16
#define RFID_TX_PIN 17
#define BUTTON_PIN 15
#define BUZZER_PIN 25

// =====================================================
// OBJECT
// =====================================================
LiquidCrystal_I2C lcd(0x27, 16, 2);
WiFiClient espClient;
PubSubClient client(espClient);
HardwareSerial RFID(2);

// =====================================================
// MQTT TOPIC
// =====================================================
String deviceId;
String topicPublish;
String topicReply;
String topicStatus;

// =====================================================
// STATE
// =====================================================
enum DeviceState {
  STATE_IDLE,
  STATE_WAIT_REPLY,
  STATE_REJECT_WINDOW,
  STATE_WAIT_FINAL_REPLY
};

DeviceState state = STATE_IDLE;

// =====================================================
// LCD STATE
// =====================================================
bool hasLoginDisplay = false;
String lastLoginLine1 = "";
String lastLoginLine2 = "";

// =====================================================
// IDLE DISPLAY DATA
// Format idle:
// 50 | JAJA
// C5 | L4 | OUT
// =====================================================
String idleOperatorName = "NO LOGIN";
int idleOutputQty = 0;
int idleBundleCount = 0;
int idleLineNo = 0;

bool temporaryScreen = false;
unsigned long screenExpireAt = 0;

// =====================================================
// RFID DEBOUNCE
// =====================================================
String lastTag = "";
unsigned long lastReadTime = 0;
const unsigned long debounceTime = 1500;

// =====================================================
// REPLY TIMEOUT
// =====================================================
unsigned long waitReplyStart = 0;
const unsigned long replyTimeout = 7000;

// =====================================================
// REJECT WINDOW
// Tombol reject 5 detik
// =====================================================
bool rejectWindowActive = false;
unsigned long rejectLastActivity = 0;
const unsigned long rejectWaitMs = 5000;

int pendingQty = 0;
int rejectQty = 0;
String pendingRfidBatch = "";

// =====================================================
// BUTTON
// Tekan pendek  : debug + restart
// Tahan 5 detik : OTA
// Saat reject window: tombol = reject +1
// =====================================================
bool lastButtonReading = HIGH;
bool buttonState = HIGH;
unsigned long lastButtonDebounceTime = 0;
const unsigned long buttonDebounceDelay = 50;

unsigned long buttonPressedStart = 0;
bool buttonHeldForOta = false;
bool buttonMessageActive = false;
unsigned long buttonMessageStart = 0;
const unsigned long BUTTON_MESSAGE_DURATION = 3000;

// =====================================================
// HEARTBEAT
// =====================================================
unsigned long lastHeartbeat = 0;
const unsigned long heartbeatInterval = 5000;

// =====================================================
// OTA STATE
// =====================================================
bool otaRunning = false;

// =====================================================
// DEBUG
// =====================================================
bool debugMode = true;

void debugPrint(String msg) {
  if (debugMode) {
    Serial.println(msg);
  }
}

// =====================================================
// BUZZER PASIF TANPA tone()
// =====================================================
void buzzerTone(int frequency, int durationMs) {
  if (frequency <= 0 || durationMs <= 0) return;

  unsigned long periodUs = 1000000UL / frequency;
  unsigned long halfPeriodUs = periodUs / 2;
  unsigned long cycles = ((unsigned long)frequency * durationMs) / 1000UL;

  for (unsigned long i = 0; i < cycles; i++) {
    digitalWrite(BUZZER_PIN, HIGH);
    delayMicroseconds(halfPeriodUs);
    digitalWrite(BUZZER_PIN, LOW);
    delayMicroseconds(halfPeriodUs);
  }

  digitalWrite(BUZZER_PIN, LOW);
}

void beepOnce(int duration = 60) {
  buzzerTone(2500, duration);
}

void beepCount(int count) {
  if (count <= 0) return;
  if (count > 5) count = 5;

  for (int i = 0; i < count; i++) {
    beepOnce(60);
    delay(70);
  }
}

// =====================================================
// LCD HELPER
// =====================================================
String fit16(String text) {
  text.trim();

  if (text.length() > 16) {
    text = text.substring(0, 16);
  }

  return text;
}

void lcdPrint16(int col, int row, String text) {
  lcd.setCursor(col, row);

  text = fit16(text);
  lcd.print(text);

  for (int i = text.length(); i < 16; i++) {
    lcd.print(" ");
  }
}

void showLCD(String row1, String row2) {
  lcd.clear();
  lcdPrint16(0, 0, row1);
  lcdPrint16(0, 1, row2);
}

void showTemporary(String row1, String row2, unsigned long durationMs) {
  showLCD(row1, row2);
  temporaryScreen = true;
  screenExpireAt = millis() + durationMs;
}

// =====================================================
// MODE HELPER
// =====================================================
String modeUpper() {
  String mode = String(DEVICE_MODE);
  mode.toUpperCase();
  return mode;
}

// =====================================================
// REJECT MODE HELPER
// ENABLE_REJECT hanya efektif pada DEVICE_MODE = "out".
// Jadi jika:
//   DEVICE_MODE   = "in"
//   ENABLE_REJECT = true
// hasilnya tetap REJECT OFF.
// =====================================================
bool rejectEnabledForDevice() {
  String mode = String(DEVICE_MODE);
  mode.toLowerCase();

  return (
    mode == "out" &&
    ENABLE_REJECT
  );
}

// =====================================================
// MAC SAFETY
// Blokir MAC aneh:
// - kosong
// - 000000000000
// - FFFFFFFFFFFF
// - bukan 12 digit HEX
// =====================================================
String normalizeMac(String mac) {
  mac.trim();
  mac.replace(":", "");
  mac.replace("-", "");
  mac.replace(" ", "");
  mac.toUpperCase();
  return mac;
}

bool isHexChar(char c) {
  return (
    (c >= '0' && c <= '9') ||
    (c >= 'A' && c <= 'F')
  );
}

bool isInvalidMac(String mac) {
  mac = normalizeMac(mac);

  if (mac.length() != 12) return true;
  if (mac == "000000000000") return true;
  if (mac == "FFFFFFFFFFFF") return true;

  for (int i = 0; i < mac.length(); i++) {
    if (!isHexChar(mac.charAt(i))) return true;
  }

  return false;
}

String macFromBytes(const uint8_t mac[6]) {
  char buffer[13];

  snprintf(
    buffer,
    sizeof(buffer),
    "%02X%02X%02X%02X%02X%02X",
    mac[0],
    mac[1],
    mac[2],
    mac[3],
    mac[4],
    mac[5]
  );

  return String(buffer);
}

String getSafeMacAddress() {
  String mac = "";

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  delay(200);

  for (int i = 0; i < 20; i++) {
    uint8_t macBytes[6] = {0, 0, 0, 0, 0, 0};

    esp_err_t err = esp_wifi_get_mac(WIFI_IF_STA, macBytes);

    if (err == ESP_OK) {
      mac = normalizeMac(macFromBytes(macBytes));

      if (!isInvalidMac(mac)) {
        return mac;
      }
    }

#if defined(ESP_MAC_WIFI_STA)
    esp_read_mac(macBytes, ESP_MAC_WIFI_STA);
    mac = normalizeMac(macFromBytes(macBytes));

    if (!isInvalidMac(mac)) {
      return mac;
    }
#endif

    mac = normalizeMac(WiFi.macAddress());

    if (!isInvalidMac(mac)) {
      return mac;
    }

    debugPrint("MAC invalid retry " + String(i + 1) + ": " + mac);
    delay(250);
  }

  return "INVALID_MAC";
}

void haltInvalidMac() {
  debugPrint("FATAL INVALID MAC: " + deviceId);

  state = STATE_IDLE;
  rejectWindowActive = false;
  temporaryScreen = false;
  hasLoginDisplay = false;
  buttonMessageActive = false;
  otaRunning = false;

  if (client.connected()) {
    client.disconnect();
  }

  showLCD("MAC INVALID", "RESTART ESP");
  beepCount(3);

  while (true) {
    delay(1000);
  }
}

bool ensureValidDeviceId() {
  deviceId = normalizeMac(deviceId);

  if (!isInvalidMac(deviceId)) {
    return true;
  }

  haltInvalidMac();
  return false;
}

// =====================================================
// IDLE DISPLAY HELPER
// =====================================================
String shortDisplayName(String name, int maxLength = 9) {
  name.trim();
  name.toUpperCase();

  if (name.length() == 0) {
    return "NO LOGIN";
  }

  int firstSpace = name.indexOf(' ');
  if (firstSpace > 0) {
    name = name.substring(0, firstSpace);
  }

  if (name.length() > maxLength) {
    name = name.substring(0, maxLength);
  }

  return name;
}

String buildIdleRow1() {
  return String(idleOutputQty) + " | " + shortDisplayName(idleOperatorName, 9);
}

String buildIdleRow2() {
  return "C" + String(idleBundleCount) + " | L" + String(idleLineNo) + " | " + modeUpper();
}

int extractFirstNumber(String text) {
  String num = "";

  for (int i = 0; i < text.length(); i++) {
    char c = text.charAt(i);

    if (c >= '0' && c <= '9') {
      num += c;
    } else if (num.length() > 0) {
      break;
    }
  }

  if (num.length() == 0) {
    return -1;
  }

  return num.toInt();
}

int extractNumberAfterChar(String text, char marker) {
  text.toUpperCase();

  int pos = text.indexOf(marker);
  if (pos < 0) {
    return -1;
  }

  String num = "";

  for (int i = pos + 1; i < text.length(); i++) {
    char c = text.charAt(i);

    if (c >= '0' && c <= '9') {
      num += c;
    } else if (num.length() > 0) {
      break;
    }
  }

  if (num.length() == 0) {
    return -1;
  }

  return num.toInt();
}

String extractNameFromLcd1(String lcd1) {
  lcd1.trim();

  int pipePos = lcd1.indexOf('|');

  if (pipePos >= 0 && pipePos + 1 < lcd1.length()) {
    String name = lcd1.substring(pipePos + 1);
    name.trim();

    if (name.length() > 0) {
      return name;
    }
  }

  return "";
}

void resetIdleData() {
  hasLoginDisplay = false;
  lastLoginLine1 = "";
  lastLoginLine2 = "";

  idleOperatorName = "NO LOGIN";
  idleOutputQty = 0;
  idleBundleCount = 0;
  idleLineNo = 0;
}

// Backend tidak diubah.
// ESP parsing dari lcd1/lcd2 lama.
void updateIdleDataFromOldBackend(
  String mode,
  String lcd1,
  String lcd2,
  String qtyText
) {
  String parsedName = extractNameFromLcd1(lcd1);

  if (parsedName.length() > 0 && parsedName != "NO LOGIN") {
    idleOperatorName = parsedName;
  }

  int parsedLine = extractNumberAfterChar(lcd2, 'L');

  if (parsedLine > 0) {
    idleLineNo = parsedLine;
  }

  String lcd1Upper = lcd1;
  String lcd2Upper = lcd2;
  lcd1Upper.toUpperCase();
  lcd2Upper.toUpperCase();

  // OUT biasanya:
  // lcd2 = TOTAL 50PCS
  if (lcd2Upper.indexOf("TOTAL") >= 0) {
    int total = extractFirstNumber(lcd2Upper);
    if (total >= 0) {
      idleOutputQty = total;
    }
  }

  // IN biasanya:
  // lcd1 = MASUK OK 10PCS
  // Jika backend tidak kirim total, ESP tambah lokal.
  if (mode == "SCAN_OK" && lcd1Upper.indexOf("MASUK") >= 0) {
    int qty = extractFirstNumber(lcd1Upper);
    if (qty > 0) {
      idleOutputQty += qty;
    }
  }

  // Bundle count tidak dikirim backend lama.
  // Tanpa ubah backend, ESP increment lokal saat SCAN_OK.
  if (mode == "SCAN_OK") {
    idleBundleCount++;
  }
}

void showStandby() {
  temporaryScreen = false;

  // Tampilan idle final:
  // 50 | JAJA
  // C5 | L4 | OUT
  showLCD(buildIdleRow1(), buildIdleRow2());
}

// =====================================================
// RESET REASON + DEBUG BUTTON
// =====================================================
String resetReasonText() {
  esp_reset_reason_t reason = esp_reset_reason();

  switch (reason) {
    case ESP_RST_POWERON: return "POWER ON";
    case ESP_RST_EXT: return "EXT RESET";
    case ESP_RST_SW: return "SOFTWARE";
    case ESP_RST_PANIC: return "PANIC/CRASH";
    case ESP_RST_INT_WDT: return "INT WDT";
    case ESP_RST_TASK_WDT: return "TASK WDT";
    case ESP_RST_WDT: return "WATCHDOG";
    case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
    case ESP_RST_BROWNOUT: return "BROWNOUT";
    case ESP_RST_SDIO: return "SDIO";
    default: return "UNKNOWN";
  }
}

String esp_rst() {
  return resetReasonText();
}

void showDebugStatus() {
  showLCD(deviceId, "O" + String(idleOutputQty) + " C" + String(idleBundleCount));
  delay(1800);

  showLCD("L" + String(idleLineNo) + " " + modeUpper(), resetReasonText());
  delay(1800);

  if (WiFi.status() == WL_CONNECTED) {
    showLCD("IP ADDRESS", WiFi.localIP().toString());
  } else {
    showLCD("IP ADDRESS", "NO WIFI");
  }
  delay(1800);
}

// =====================================================
// OTA HELPER
// =====================================================
String otaFirmwareFileName() {
  if (String(DEVICE_MODE) == "in") {
    return "rfid_in.bin";
  }

  return "rfid_out.bin";
}

String otaFirmwareUrl() {
  return String(OTA_BASE_URL) + otaFirmwareFileName();
}

void otaStarted() {
  showLCD("OTA START", "DOWNLOADING...");
}

void otaFinished() {
  showLCD("OTA FINISHED", "REBOOTING...");
}

void otaProgress(int current, int total) {
  if (total <= 0) {
    return;
  }

  int percent = (current * 100) / total;
  static int lastPercent = -1;

  if (percent == lastPercent) {
    return;
  }

  lastPercent = percent;

  String row2 = String(percent) + "% " + String(current / 1024) + "/" + String(total / 1024) + "KB";
  showLCD("OTA UPDATE", row2);
}

void otaError(int error) {
  showLCD("OTA ERROR", "CODE " + String(error));
}

void performLocalOTA() {
  if (otaRunning) {
    return;
  }

  otaRunning = true;

  state = STATE_IDLE;
  rejectWindowActive = false;
  temporaryScreen = false;
  buttonMessageActive = false;

  if (WiFi.status() != WL_CONNECTED) {
    showTemporary("OTA FAILED", "WIFI LOST", 2500);
    beepCount(3);
    otaRunning = false;
    return;
  }

  if (client.connected()) {
    client.publish(topicStatus.c_str(), "ota_update", true);
    client.disconnect();
  }

  String otaUrl = otaFirmwareUrl();

  showLCD("OTA " + modeUpper(), otaFirmwareFileName());
  delay(1200);

  WiFiClient otaClient;

  httpUpdate.onStart(otaStarted);
  httpUpdate.onEnd(otaFinished);
  httpUpdate.onProgress(otaProgress);
  httpUpdate.onError(otaError);
  httpUpdate.rebootOnUpdate(true);

  t_httpUpdate_return result = httpUpdate.update(otaClient, otaUrl);

  switch (result) {
    case HTTP_UPDATE_FAILED:
      showTemporary("OTA FAILED", "ERR " + String(httpUpdate.getLastError()), 2500);
      delay(2500);
      showTemporary("OTA ERROR MSG", httpUpdate.getLastErrorString(), 2500);
      break;

    case HTTP_UPDATE_NO_UPDATES:
      showTemporary("OTA INFO", "NO UPDATE", 2500);
      break;

    case HTTP_UPDATE_OK:
      showTemporary("OTA OK", "REBOOT...", 1000);
      break;
  }

  otaRunning = false;
  showStandby();
}

// =====================================================
// STRING PARSER
// Reply:
// MODE^BEEP^LCD1^LCD2
// OUT_WAIT_REJECT^BEEP^LCD1^LCD2^QTY
// =====================================================
String getPart(String data, char separator, int index) {
  int found = 0;
  int startIndex = 0;

  for (int i = 0; i <= data.length(); i++) {
    if (i == data.length() || data.charAt(i) == separator) {
      if (found == index) {
        return data.substring(startIndex, i);
      }

      found++;
      startIndex = i + 1;
    }
  }

  return "";
}

// =====================================================
// RFID READER
// Reader format STX 0x02 ... ETX 0x03
// Output RFID decimal 10 digit
// =====================================================
String readTag(Stream& serial) {
  if (!serial.available()) return "";

  if (serial.read() != 0x02) return "";

  String hexData = "";
  unsigned long start = millis();

  while (millis() - start < 100) {
    if (serial.available()) {
      char c = serial.read();

      if (c == 0x03) break;

      hexData += c;
    }
  }

  if (hexData.length() < 12) return "";

  String tagHex = hexData.substring(0, 10);
  String serialHex = tagHex.substring(2, 10);

  uint64_t tagDec = strtoull(serialHex.c_str(), NULL, 16);

  char buffer[20];

  snprintf(
    buffer,
    sizeof(buffer),
    "%010llu",
    (unsigned long long)tagDec
  );

  return String(buffer);
}

// =====================================================
// RFID CONTROL
// =====================================================
bool allowRFID(String tag) {
  unsigned long now = millis();

  if (state == STATE_WAIT_REPLY || state == STATE_WAIT_FINAL_REPLY) {
    debugPrint("RFID ignored, waiting reply: " + tag);
    return false;
  }

  if (state == STATE_REJECT_WINDOW) {
    showLCD("SEDANG REJECT", "RFID DIABAIKAN");
    beepCount(2);
    return false;
  }

  if (tag == lastTag && now - lastReadTime < debounceTime) {
    lastReadTime = now;
    debugPrint("RFID duplicate ignored: " + tag);
    return false;
  }

  lastTag = tag;
  lastReadTime = now;

  return true;
}

// =====================================================
// RESTORE SESSION
// Setelah ESP restart, cek apakah MAC masih login
// =====================================================
void requestRestoreSession() {
  if (!ensureValidDeviceId()) return;
  if (!client.connected()) return;

  String payload = "";
  payload += deviceId;
  payload += "/";
  payload += "__RESTORE__";
  payload += "/";
  payload += String(DEVICE_MODE);

  debugPrint("Restore payload: " + payload);

  client.publish(topicPublish.c_str(), payload.c_str());

  state = STATE_WAIT_REPLY;
  waitReplyStart = millis();

  showLCD("RESTORE SESSION", "PLEASE WAIT");
}

// =====================================================
// SEND TAP NORMAL
// Payload:
// MAC/RFID/in
// MAC/RFID/out
// =====================================================
void sendInitialTap(String tag) {
  if (!ensureValidDeviceId()) return;

  if (!client.connected()) {
    showTemporary("MQTT OFFLINE", "RECONNECT...", 2500);
    beepCount(3);
    return;
  }

  pendingRfidBatch = tag;

  String payload = "";
  payload += deviceId;
  payload += "/";
  payload += tag;
  payload += "/";
  payload += String(DEVICE_MODE);

  debugPrint("Publish topic: " + topicPublish);
  debugPrint("Publish data : " + payload);

  bool ok = client.publish(topicPublish.c_str(), payload.c_str());

  if (!ok) {
    showTemporary("MQTT SEND FAIL", "CHECK BROKER", 3000);
    beepCount(3);
    return;
  }

  state = STATE_WAIT_REPLY;
  waitReplyStart = millis();

  if (String(DEVICE_MODE) == "in") {
    showLCD("PROCESSING IN", tag);
  } else {
    showLCD("PROCESSING OUT", tag);
  }

  beepOnce(60);
}

// =====================================================
// START REJECT WINDOW
// Hanya untuk DEVICE_MODE out dan ENABLE_REJECT true
// Waktu tunggu 5 detik
// =====================================================
void startRejectWindow(int qty) {
  if (!rejectEnabledForDevice()) {
    state = STATE_IDLE;
    rejectWindowActive = false;
    return;
  }

  if (qty <= 0) {
    state = STATE_IDLE;
    rejectWindowActive = false;

    showTemporary("QTY INVALID", "CEK BACKEND", 3000);
    beepCount(3);
    return;
  }

  pendingQty = qty;
  rejectQty = 0;

  rejectWindowActive = true;
  rejectLastActivity = millis();
  state = STATE_REJECT_WINDOW;

  showLCD("REJECT 5 DETIK", "R:0 G:" + String(pendingQty));
  beepCount(1);
}

// =====================================================
// BUTTON REJECT
// Setiap tombol ditekan:
// reject +1
// timer 5 detik reset
// =====================================================
void addReject() {
  if (!rejectEnabledForDevice()) return;
  if (state != STATE_REJECT_WINDOW || !rejectWindowActive) return;

  if (rejectQty < pendingQty) {
    rejectQty++;

    int goodQty = pendingQty - rejectQty;
    rejectLastActivity = millis();

    showLCD("REJECT " + String(rejectQty), "GOOD " + String(goodQty));
    beepOnce(40);
  } else {
    rejectQty = pendingQty;
    rejectLastActivity = millis();

    showLCD("REJECT FULL", "QTY HABIS");
    beepCount(3);
  }
}

// =====================================================
// SEND FINAL OUT
// Payload:
// MAC/RFID/out/final/REJECT
// Contoh:
// B4BFE914A620/0002959598/out/final/2
// =====================================================
void sendFinalOutput() {
  if (!ensureValidDeviceId()) return;

  if (!rejectEnabledForDevice()) {
    state = STATE_IDLE;
    rejectWindowActive = false;
    return;
  }

  if (!client.connected()) {
    state = STATE_IDLE;
    rejectWindowActive = false;

    showTemporary("MQTT OFFLINE", "FINAL GAGAL", 3000);
    beepCount(3);
    return;
  }

  String payload = "";
  payload += deviceId;
  payload += "/";
  payload += pendingRfidBatch;
  payload += "/";
  payload += "out";
  payload += "/";
  payload += "final";
  payload += "/";
  payload += String(rejectQty);

  debugPrint("Publish final topic: " + topicPublish);
  debugPrint("Publish final data : " + payload);

  bool ok = client.publish(topicPublish.c_str(), payload.c_str());

  if (!ok) {
    state = STATE_IDLE;
    rejectWindowActive = false;

    showTemporary("SEND FINAL FAIL", "CEK MQTT", 3000);
    beepCount(3);
    return;
  }

  int goodQty = pendingQty - rejectQty;

  if (goodQty < 0) {
    goodQty = 0;
  }

  state = STATE_WAIT_FINAL_REPLY;
  waitReplyStart = millis();

  showLCD("KIRIM OUTPUT", "G:" + String(goodQty) + " R:" + String(rejectQty));
  beepCount(2);
}

// =====================================================
// HANDLE REJECT WINDOW
// Setelah 5 detik tanpa tombol, kirim final.
// =====================================================
void handleRejectWindow() {
  if (!rejectEnabledForDevice()) return;
  if (state != STATE_REJECT_WINDOW || !rejectWindowActive) return;

  if (millis() - rejectLastActivity >= rejectWaitMs) {
    rejectWindowActive = false;
    sendFinalOutput();
  }
}

// =====================================================
// MQTT CALLBACK
// =====================================================
void callback(char* topic, byte* payload, unsigned int length) {
  String msg = "";

  for (unsigned int i = 0; i < length; i++) {
    msg += (char)payload[i];
  }

  msg.trim();

  debugPrint("RX TOPIC: " + String(topic));
  debugPrint("RX MSG  : " + msg);

  String mode = getPart(msg, '^', 0);
  String beepText = getPart(msg, '^', 1);
  String lcd1 = getPart(msg, '^', 2);
  String lcd2 = getPart(msg, '^', 3);
  String qtyText = getPart(msg, '^', 4);

  int beepQty = beepText.toInt();

  if (beepQty < 0) beepQty = 0;
  if (beepQty > 5) beepQty = 5;

  if (mode.length() == 0) {
    state = STATE_IDLE;
    rejectWindowActive = false;

    showTemporary("BAD RESPONSE", "CHECK MQTT", 3000);
    beepCount(3);
    return;
  }

  if (mode == "LOGIN_OK" || mode == "RESTORE_OK") {
    state = STATE_IDLE;
    rejectWindowActive = false;

    hasLoginDisplay = true;
    lastLoginLine1 = lcd1;
    lastLoginLine2 = lcd2;

    updateIdleDataFromOldBackend(mode, lcd1, lcd2, qtyText);

    beepCount(beepQty);

    // Backend tidak diubah.
    // LCD backend dipakai sebagai sumber data,
    // lalu langsung dipaksa ke format idle baru.
    showStandby();
    return;
  }

  if (mode == "LOGOUT" || mode == "NO_SESSION" || mode == "RESTORE_EMPTY") {
    state = STATE_IDLE;
    rejectWindowActive = false;

    resetIdleData();

    showLCD(lcd1, lcd2);
    beepCount(beepQty);

    temporaryScreen = true;
    screenExpireAt = millis() + 1500;
    return;
  }

  if (mode == "OUT_WAIT_REJECT") {
    int qty = qtyText.toInt();

    showLCD(lcd1, lcd2);
    beepCount(beepQty);

    delay(300);
    startRejectWindow(qty);
    return;
  }

  if (mode == "SCAN_OK") {
    state = STATE_IDLE;
    rejectWindowActive = false;

    pendingQty = 0;
    rejectQty = 0;
    pendingRfidBatch = "";

    updateIdleDataFromOldBackend(mode, lcd1, lcd2, qtyText);

    // Pesan sukses backend tetap tampil sebentar,
    // lalu setelah temporary selesai kembali ke idle baru.
    showLCD(lcd1, lcd2);
    beepCount(beepQty);

    temporaryScreen = true;
    screenExpireAt = millis() + 3000;
    return;
  }

  state = STATE_IDLE;
  rejectWindowActive = false;

  showLCD(lcd1, lcd2);
  beepCount(beepQty);

  temporaryScreen = true;
  screenExpireAt = millis() + 3000;
}

// =====================================================
// WIFI MULTI CONNECT / FAILOVER
// =====================================================

int findWifiIndex(const String& targetSsid) {
  for (size_t i = 0; i < WIFI_COUNT; i++) {
    if (targetSsid == WIFI_SSIDS[i]) {
      return (int)i;
    }
  }

  return -1;
}

void loadSavedWiFi() {
  wifiPrefs.begin("wifi", true);
  savedWifiSsid = wifiPrefs.getString("last_ssid", "");
  wifiPrefs.end();

  if (findWifiIndex(savedWifiSsid) < 0) {
    savedWifiSsid = "";
  }

  if (savedWifiSsid.length() > 0) {
    debugPrint("[WIFI] Saved SSID: " + savedWifiSsid);
  } else {
    debugPrint("[WIFI] Saved SSID: NONE");
  }
}

void saveSuccessfulWiFi(const String& activeSsid) {
  if (activeSsid.length() == 0) return;
  if (findWifiIndex(activeSsid) < 0) return;

  // Hindari write flash kalau SSID tidak berubah.
  if (activeSsid == savedWifiSsid) {
    return;
  }

  wifiPrefs.begin("wifi", false);
  wifiPrefs.putString("last_ssid", activeSsid);
  wifiPrefs.end();

  savedWifiSsid = activeSsid;

  debugPrint("[WIFI] Saved new SSID: " + savedWifiSsid);
}

bool tryConnectWifiIndex(int index) {
  if (index < 0 || index >= (int)WIFI_COUNT) {
    return false;
  }

  const char* targetSsid = WIFI_SSIDS[index];

  debugPrint("");
  debugPrint("================================");
  debugPrint("[WIFI] TRY: " + String(targetSsid));
  debugPrint("================================");

  showLCD("CONNECT WIFI", String(targetSsid));

  WiFi.disconnect(false, false);
  delay(100);

  WiFi.begin(targetSsid, WIFI_PASS);

  unsigned long startedAt = millis();

  while (
    WiFi.status() != WL_CONNECTED &&
    millis() - startedAt < WIFI_CONNECT_TIMEOUT_MS
  ) {
    delay(250);
    Serial.print(".");
  }

  Serial.println();

  if (WiFi.status() != WL_CONNECTED) {
    debugPrint("[WIFI] FAILED: " + String(targetSsid));
    return false;
  }

  String activeSsid = WiFi.SSID();

  debugPrint("[WIFI] CONNECTED");
  debugPrint("[WIFI] SSID : " + activeSsid);
  debugPrint("[WIFI] IP   : " + WiFi.localIP().toString());
  debugPrint("[WIFI] RSSI : " + String(WiFi.RSSI()));

  saveSuccessfulWiFi(activeSsid);

  // Pertahankan setting radio dari program lama.
  esp_wifi_set_protocol(WIFI_IF_STA, WIFI_PROTOCOL_11B);
  esp_wifi_set_bandwidth(WIFI_IF_STA, WIFI_BW_HT20);

  showLCD("WIFI CONNECTED", activeSsid);
  delay(700);

  return true;
}


// Scan whitelist dan susun berdasarkan RSSI paling kuat.
int buildWifiOrderFromScan(int orderOut[], int maxCount) {
  showLCD("SCAN WIFI...", "PLEASE WAIT");

  debugPrint("[WIFI] SCANNING...");

  WiFi.disconnect(false, false);
  delay(100);

  int found = WiFi.scanNetworks(false, true);

  if (found <= 0) {
    debugPrint("[WIFI] No network detected");
    WiFi.scanDelete();
    return 0;
  }

  bool visible[WIFI_COUNT];
  int bestRssi[WIFI_COUNT];

  for (size_t i = 0; i < WIFI_COUNT; i++) {
    visible[i] = false;
    bestRssi[i] = -1000;
  }

  for (int n = 0; n < found; n++) {
    String scannedSsid = WiFi.SSID(n);
    int index = findWifiIndex(scannedSsid);

    if (index < 0) {
      continue;
    }

    int rssi = WiFi.RSSI(n);

    visible[index] = true;

    if (rssi > bestRssi[index]) {
      bestRssi[index] = rssi;
    }

    debugPrint(
      "[WIFI] FOUND " +
      scannedSsid +
      " RSSI=" +
      String(rssi)
    );
  }

  WiFi.scanDelete();

  int count = 0;

  while (count < maxCount) {
    int strongestIndex = -1;
    int strongestRssi = -1001;

    for (size_t i = 0; i < WIFI_COUNT; i++) {
      if (
        visible[i] &&
        bestRssi[i] > strongestRssi
      ) {
        strongestIndex = (int)i;
        strongestRssi = bestRssi[i];
      }
    }

    if (strongestIndex < 0) {
      break;
    }

    orderOut[count++] = strongestIndex;
    visible[strongestIndex] = false;
  }

  if (count > 0) {
    debugPrint("[WIFI] Priority after scan:");

    for (int i = 0; i < count; i++) {
      int index = orderOut[i];

      debugPrint(
        "  " +
        String(i + 1) +
        ". " +
        String(WIFI_SSIDS[index]) +
        " RSSI=" +
        String(bestRssi[index])
      );
    }
  }

  return count;
}


bool trySavedWifiFirst() {
  int savedIndex = findWifiIndex(savedWifiSsid);

  if (savedIndex < 0) {
    return false;
  }

  debugPrint(
    "[WIFI] Try saved SSID first: " +
    savedWifiSsid
  );

  return tryConnectWifiIndex(savedIndex);
}


// Dipakai hanya saat belum pernah ada SSID tersimpan.
// Mencoba:
// Tracked -> Tracked (2) -> ... -> Tracked (8)
bool tryDefaultWifiSequence() {
  debugPrint("[WIFI] No saved SSID, try default sequence");

  for (size_t i = 0; i < WIFI_COUNT; i++) {
    if (tryConnectWifiIndex((int)i)) {
      return true;
    }
  }

  return false;
}


void connectWiFi() {
  if (!ensureValidDeviceId()) return;

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);

  // Failover dikendalikan sendiri.
  WiFi.setAutoReconnect(false);

  // Membaca SSID terakhir dari NVS.
  loadSavedWiFi();

  // ===================================================
  // BOOT / RECONNECT PRIORITY
  // ===================================================

  if (savedWifiSsid.length() > 0) {
    // Ada histori: SSID terakhir dicoba lebih dulu.
    if (trySavedWifiFirst()) {
      return;
    }

    debugPrint(
      "[WIFI] Saved SSID failed -> scan strongest network"
    );
  } else {
    // Belum pernah sukses:
    // coba Tracked, Tracked (2), dst secara urut.
    if (tryDefaultWifiSequence()) {
      return;
    }

    debugPrint(
      "[WIFI] Default sequence failed -> scan"
    );
  }

  // ===================================================
  // SCAN LOOP
  // ===================================================

  while (WiFi.status() != WL_CONNECTED) {
    int scanOrder[WIFI_COUNT];

    int scanCount =
      buildWifiOrderFromScan(
        scanOrder,
        (int)WIFI_COUNT
      );

    if (scanCount > 0) {
      for (int i = 0; i < scanCount; i++) {
        if (tryConnectWifiIndex(scanOrder[i])) {
          return;
        }
      }
    }

    debugPrint(
      "[WIFI] All whitelist AP failed. Rescan in " +
      String(WIFI_RESCAN_MS) +
      " ms"
    );

    showLCD("WIFI OFFLINE", "SCAN ULANG...");
    delay(WIFI_RESCAN_MS);
  }
}


// =====================================================
// MQTT RECONNECT
// =====================================================
void reconnectMQTT() {
  ensureValidDeviceId();

  while (!client.connected()) {
    showLCD("MQTT CONNECT TO", mqtt_server);

    String clientId = "ESP32-";
    clientId += String(DEVICE_MODE);
    clientId += "-";
    clientId += deviceId;

    if (
      client.connect(
        clientId.c_str(),
        topicStatus.c_str(),
        0,
        true,
        "offline"
      )
    ) {
      client.subscribe(topicReply.c_str());
      client.publish(topicStatus.c_str(), "online", true);

      showLCD("MQTT SUCCESS", mqtt_server);
      delay(700);

      requestRestoreSession();
    } else {
      showLCD("MQTT FAILED", "RETRY...");
      delay(2000);
    }
  }
}

// =====================================================
// BUTTON HANDLER
// Saat reject window:
//   tombol = reject +1
//
// Di luar reject window:
//   tekan pendek  = debug status + restart
//   tahan 5 detik = OTA update
// =====================================================
void handleButton() {
  if (otaRunning) {
    return;
  }

  const bool reading = digitalRead(BUTTON_PIN);

  if (reading != lastButtonReading) {
    lastButtonDebounceTime = millis();
  }

  if ((millis() - lastButtonDebounceTime) > buttonDebounceDelay) {
    if (reading != buttonState) {
      buttonState = reading;

      if (buttonState == LOW) {
        buttonPressedStart = millis();
        buttonHeldForOta = false;
        buttonMessageActive = true;
        buttonMessageStart = millis();

        // Kalau sedang reject window, tombol tetap reject.
        if (
          rejectEnabledForDevice() &&
          state == STATE_REJECT_WINDOW &&
          rejectWindowActive
        ) {
          addReject();

          // Setelah reject, jangan masuk mode OTA/debug.
          buttonMessageActive = false;
          buttonPressedStart = 0;
          buttonHeldForOta = false;
        } else {
          showLCD("HOLD 5 SEC", "FOR OTA UPDATE");
        }

      } else {
        // Tombol dilepas sebelum 5 detik = debug + restart.
        if (!buttonHeldForOta && buttonPressedStart > 0) {
          showDebugStatus();

          delay(300);
          ESP.restart();
        }

        buttonPressedStart = 0;
        buttonHeldForOta = false;
      }
    }
  }

  // Hold 5 detik = OTA.
  if (
    buttonState == LOW &&
    !buttonHeldForOta &&
    buttonPressedStart > 0
  ) {
    unsigned long holdDuration = millis() - buttonPressedStart;

    if (holdDuration >= OTA_HOLD_TIME) {
      buttonHeldForOta = true;
      buttonMessageActive = false;
      performLocalOTA();
    } else {
      int remain = (OTA_HOLD_TIME - holdDuration + 999) / 1000;
      showLCD("OTA IN " + String(remain) + " SEC", "KEEP HOLDING");
    }
  }

  lastButtonReading = reading;

  if (buttonMessageActive && millis() - buttonMessageStart >= BUTTON_MESSAGE_DURATION) {
    buttonMessageActive = false;
    showStandby();
  }
}

// =====================================================
// API TIMEOUT
// =====================================================
void handleApiTimeout() {
  if (state == STATE_WAIT_REPLY || state == STATE_WAIT_FINAL_REPLY) {
    if (millis() - waitReplyStart >= replyTimeout) {
      state = STATE_IDLE;
      rejectWindowActive = false;

      showTemporary("NO REPLY", "CEK SERVER", 3000);
      beepCount(3);
    }
  }
}

// =====================================================
// SETUP
// =====================================================
void setup() {
  Serial.begin(115200);

  pinMode(BUTTON_PIN, INPUT_PULLUP);

  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);

  RFID.begin(
    9600,
    SERIAL_8N1,
    RFID_RX_PIN,
    RFID_TX_PIN
  );

  lcd.init();
  lcd.backlight();

  showLCD("RFID " + String(DEVICE_MODE), "STARTING...");
  delay(1000);

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);

  deviceId = getSafeMacAddress();

  if (isInvalidMac(deviceId)) {
    haltInvalidMac();
  }

  connectWiFi();

  ensureValidDeviceId();

  topicPublish = String(MQTT_BASE) + "/" + String(DEVICE_MODE) + "/" + deviceId;
  topicReply = String(MQTT_BASE) + "/reply/" + deviceId;
  topicStatus = String(MQTT_BASE) + "/status/" + deviceId;

  debugPrint("Device ID    : " + deviceId);
  debugPrint("DEVICE_MODE  : " + String(DEVICE_MODE));
  debugPrint("REJECT CFG   : " + String(ENABLE_REJECT ? "TRUE" : "FALSE"));
  debugPrint("REJECT ACTIVE: " + String(rejectEnabledForDevice() ? "ON" : "OFF"));
  debugPrint("topicPublish : " + topicPublish);
  debugPrint("topicReply   : " + topicReply);
  debugPrint("topicStatus  : " + topicStatus);

  client.setServer(mqtt_server, mqtt_port);
  client.setCallback(callback);
  client.setBufferSize(512);

  reconnectMQTT();
}

// =====================================================
// LOOP
// =====================================================
void loop() {
  ensureValidDeviceId();

  handleButton();

  if (WiFi.status() != WL_CONNECTED) {
    state = STATE_IDLE;
    rejectWindowActive = false;

    showLCD("WIFI LOST", "FAILOVER...");

    // Multi-WiFi:
    // coba SSID terakhir, jika gagal scan Tracked* terkuat.
    connectWiFi();

    // MQTT akan reconnect pada blok berikutnya.
  }

  if (!client.connected()) {
    state = STATE_IDLE;
    rejectWindowActive = false;
    reconnectMQTT();
  }

  client.loop();

  handleRejectWindow();
  handleApiTimeout();

  if (temporaryScreen && millis() >= screenExpireAt) {
    temporaryScreen = false;
    showStandby();
  }

  if (millis() - lastHeartbeat >= heartbeatInterval) {
    ensureValidDeviceId();

    lastHeartbeat = millis();

    client.publish(topicStatus.c_str(), "online", true);
  }

  if (!buttonMessageActive && !otaRunning) {
    String tag = readTag(RFID);

    if (tag.length() > 0) {
      if (!allowRFID(tag)) return;

      sendInitialTap(tag);
    }
  }

  delay(2);
}