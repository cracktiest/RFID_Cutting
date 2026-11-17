#include <Arduino.h>
#include <LiquidCrystal_I2C.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <Preferences.h>
#include "esp_bt.h"
#include "esp_wifi.h"
#include "esp_mac.h"

#if __has_include(<esp_arduino_version.h>)
#include <esp_arduino_version.h>
#endif

// =====================================================
// PILIH MODE ALAT DI SINI SAJA
// assy_in  = INPUT_SEWING
// assy_out = OUTPUT_SEWING
// =====================================================
// String scanType = "assy_in";
String scanType = "assy_out";
// 
// =====================================================
// WIFI - MULTI WIFI FAILOVER
// =====================================================
//
// Cara kerja:
// 1. SSID terakhir yang berhasil disimpan di NVS.
// 2. Saat boot, SSID terakhir dicoba lebih dulu.
// 3. Jika belum pernah tersimpan:
//      Tracked -> Tracked (2) -> ... -> Tracked (8)
// 4. Jika SSID tersimpan gagal, scan ulang whitelist.
// 5. Hasil scan diprioritaskan berdasarkan RSSI terkuat.
// 6. Jika berhasil pindah AP, SSID baru disimpan.
// 7. Selama koneksi sehat, ESP32 tidak pindah AP.
//
// Semua SSID menggunakan password yang sama.
// =====================================================

const char *WIFI_SSIDS[] = {
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
    sizeof(WIFI_SSIDS) /
    sizeof(WIFI_SSIDS[0]);

const char *WIFI_PASS = "Factory@RFID";

constexpr unsigned long WIFI_CONNECT_TIMEOUT_MS = 8000;
constexpr unsigned long WIFI_RESCAN_INTERVAL = 5000;

Preferences wifiPrefs;

String savedWifiSsid = "";

int wifiTryOrder[WIFI_COUNT];
int wifiTryCount = 0;
int wifiTryPosition = 0;
int currentWifiIndex = -1;

bool wifiAttemptInProgress = false;
bool wifiConnectionHandled = false;
bool wifiSystemInitialized = false;

unsigned long wifiAttemptStarted = 0;
// =====================================================
// MQTT
// =====================================================
const char *mqttServer = "10.5.2.223";
const uint16_t mqttPort = 1883;

// =====================================================
// RFID UART
// =====================================================
constexpr uint8_t RFID_RX_PIN = 16;
constexpr uint8_t RFID_TX_PIN = 17;
constexpr uint32_t RFID_BAUD = 9600;

// =====================================================
// LCD & BUZZER
// =====================================================
LiquidCrystal_I2C lcd(0x27, 16, 2);

constexpr uint8_t BUZZER_PIN = 25;
constexpr uint8_t BUZZER_CHANNEL = 0;
constexpr uint16_t BUZZER_FREQ = 2000;
constexpr uint8_t BUZZER_RESOLUTION = 8;

// =====================================================
// BUTTON OPTIONAL
// =====================================================
constexpr uint8_t BUTTON_PIN = 15;

// =====================================================
// INTERVAL
// =====================================================
constexpr unsigned long MQTT_RETRY_INTERVAL = 5000;
constexpr unsigned long HEARTBEAT_INTERVAL = 5000;
constexpr unsigned long RFID_DEBOUNCE_TIME = 2000;
constexpr unsigned long RFID_PROCESSING_TIMEOUT = 8000;

// =====================================================
// OBJECT
// =====================================================
WiFiClient espClient;
PubSubClient client(espClient);
HardwareSerial RFID(2);

// =====================================================
// MQTT TOPIC
// =====================================================
String deviceId;
String topicTag;
String topicStatus;
String topicReply;

// =====================================================
// READY DATA
// =====================================================
String operatorName = "NO LOGIN";
int actualOutput = 0;
int countBundle = 0;
int lineNo = 0;

// =====================================================
// RFID STATE
// =====================================================
String lastTag = "";
unsigned long lastReadTime = 0;
bool rfidProcessing = false;
unsigned long rfidProcessingStart = 0;

// =====================================================
// CONNECTION STATE
// =====================================================
unsigned long lastWifiAttempt = 0;
unsigned long lastMqttAttempt = 0;
unsigned long lastHeartbeat = 0;
bool wifiWasConnected = false;
bool mqttWasConnected = false;
bool restoreRequested = false;

// =====================================================
// READY SCREEN TIMER
// =====================================================
bool returnToReady = false;
unsigned long returnReadyStart = 0;
unsigned long returnReadyDelay = 0;

bool debugMode = true;

// =====================================================
// DEBUG
// =====================================================
void debugPrint(const String &msg)
{
  if (debugMode)
  {
    Serial.println(msg);
  }
}

// =====================================================
// MODE HELPER
// =====================================================
String scanPath()
{
  String mode = scanType;
  mode.toLowerCase();
  mode.trim();

  if (mode == "assy_out")
  {
    return "out";
  }

  return "in";
}

String scanModeShort()
{
  String mode = scanType;
  mode.toLowerCase();
  mode.trim();

  if (mode == "assy_out")
  {
    return "OUT";
  }

  return "IN";
}

String scanModeTitle()
{
  String mode = scanType;
  mode.toLowerCase();
  mode.trim();

  if (mode == "assy_out")
  {
    return "ASSY OUT";
  }

  return "ASSY IN";
}

String mqttClientPrefix()
{
  String mode = scanType;
  mode.toLowerCase();
  mode.trim();

  if (mode == "assy_out")
  {
    return "ESP32-ASSY-OUT-";
  }

  return "ESP32-ASSY-IN-";
}

// =====================================================
// BUZZER
// =====================================================
void buzzerBegin()
{
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(BUZZER_PIN, BUZZER_FREQ, BUZZER_RESOLUTION);
  ledcWriteTone(BUZZER_PIN, 0);
#else
  ledcSetup(BUZZER_CHANNEL, BUZZER_FREQ, BUZZER_RESOLUTION);
  ledcAttachPin(BUZZER_PIN, BUZZER_CHANNEL);
  ledcWriteTone(BUZZER_CHANNEL, 0);
#endif
}

void buzzerTone(int frequency)
{
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWriteTone(BUZZER_PIN, frequency);
#else
  ledcWriteTone(BUZZER_CHANNEL, frequency);
#endif
}

void buzzerOff()
{
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWriteTone(BUZZER_PIN, 0);
#else
  ledcWriteTone(BUZZER_CHANNEL, 0);
#endif
}

void beep(int duration = 120, int frequency = 2200)
{
  if (duration <= 0)
  {
    return;
  }

  buzzerTone(frequency);
  delay(duration);
  buzzerOff();
}

void beepCode(int code)
{
  if (code <= 0)
  {
    return;
  }

  if (code == 1)
  {
    beep(120, 2200);
  }
  else if (code == 2)
  {
    beep(120, 2200);
    delay(80);
    beep(120, 2200);
  }
  else
  {
    beep(450, 900);
  }
}

// =====================================================
// LCD
// =====================================================
void lcdPrint16(int row, String text)
{
  if (text.length() > 16)
  {
    text = text.substring(0, 16);
  }

  lcd.setCursor(0, row);
  lcd.print(text);

  for (int i = text.length(); i < 16; i++)
  {
    lcd.print(' ');
  }
}

void showMessage(const String &row1, const String &row2, int beepValue = 0)
{
  lcdPrint16(0, row1);
  lcdPrint16(1, row2);
  beepCode(beepValue);
}

String shortName(String name, int maxLength = 13)
{
  name.trim();
  name.toUpperCase();

  if (name.length() == 0)
  {
    return "NO LOGIN";
  }

  if (name.length() > maxLength)
  {
    return name.substring(0, maxLength);
  }

  return name;
}

// =====================================================
// IDLE / READY SCREEN
// Jika belum login:
// NO LOGIN
// TAP USER IN / OUT
//
// Jika sudah login:
// L1|NAMA
// INPUT=2
// =====================================================
void showReady()
{
  if (operatorName.length() == 0 || operatorName == "NO LOGIN")
  {
    lcdPrint16(0, "NO LOGIN");
    lcdPrint16(1, "TAP USER " + scanModeShort());
    return;
  }

  String row1 = "L" + String(lineNo) + "|" + shortName(operatorName, 13);

  String label = "INPUT";
  if (scanType == "assy_out")
  {
    label = "OUTPUT";
  }

  String row2 = label + "=" + String(actualOutput);

  lcdPrint16(0, row1);
  lcdPrint16(1, row2);
}

void scheduleReady(unsigned long delayMs)
{
  returnToReady = true;
  returnReadyStart = millis();
  returnReadyDelay = delayMs;
}

// =====================================================
// JSON SIMPLE PARSER
// =====================================================
String jsonGetString(const String &json, const String &key)
{
  String pattern = "\"" + key + "\"";
  int pos = json.indexOf(pattern);

  if (pos < 0)
  {
    return "";
  }

  pos = json.indexOf(':', pos + pattern.length());

  if (pos < 0)
  {
    return "";
  }

  pos++;

  while (pos < (int)json.length() && (json[pos] == ' ' || json[pos] == '\t'))
  {
    pos++;
  }

  if (pos >= (int)json.length())
  {
    return "";
  }

  if (json[pos] == '"')
  {
    pos++;

    String value = "";
    bool escape = false;

    while (pos < (int)json.length())
    {
      char c = json[pos++];

      if (escape)
      {
        value += c;
        escape = false;
      }
      else if (c == '\\')
      {
        escape = true;
      }
      else if (c == '"')
      {
        break;
      }
      else
      {
        value += c;
      }
    }

    return value;
  }

  int end = pos;

  while (end < (int)json.length() && json[end] != ',' && json[end] != '}')
  {
    end++;
  }

  String value = json.substring(pos, end);
  value.trim();
  value.replace("\"", "");

  return value;
}

int jsonGetInt(const String &json, const String &key, int defaultValue = 0)
{
  String value = jsonGetString(json, key);
  value.trim();

  if (value.length() == 0)
  {
    return defaultValue;
  }

  return value.toInt();
}

// =====================================================
// UPDATE DATA READY SCREEN
// Tidak reset operator/output saat response error.
// Reset hanya saat logout / restore_empty.
// Counter update hanya saat status = ok.
// =====================================================
void updateReadyData(const String &json)
{
  String status = jsonGetString(json, "status");
  String action = jsonGetString(json, "action");
  String mode = jsonGetString(json, "mode");

  status.toLowerCase();
  action.toLowerCase();
  mode.toUpperCase();

  status.trim();
  action.trim();
  mode.trim();

  if (action == "logout" || action == "restore_empty" || mode == "RESTORE_EMPTY")
  {
    operatorName = "NO LOGIN";
    actualOutput = 0;
    countBundle = 0;
    lineNo = 0;
    return;
  }

  String op = jsonGetString(json, "operator_name");
  String nama = jsonGetString(json, "nama");

  op.trim();
  nama.trim();

  if (op.length() > 0 && op != "NO LOGIN")
  {
    operatorName = op;
  }
  else if (nama.length() > 0 && nama != "NO LOGIN")
  {
    operatorName = nama;
  }

  int lineA = jsonGetInt(json, "line_no", -1);
  int lineB = jsonGetInt(json, "line", -1);

  if (lineA > 0)
  {
    lineNo = lineA;
  }
  else if (lineB > 0)
  {
    lineNo = lineB;
  }

  if (status != "ok")
  {
    return;
  }

  int outputA = jsonGetInt(json, "actual_output", -1);
  int outputB = jsonGetInt(json, "total_output_qty", -1);
  int outputC = jsonGetInt(json, "operator_output", -1);

  if (outputA >= 0)
  {
    actualOutput = outputA;
  }
  else if (outputB >= 0)
  {
    actualOutput = outputB;
  }
  else if (outputC >= 0)
  {
    actualOutput = outputC;
  }

  int countA = jsonGetInt(json, "count_bundle", -1);
  int countB = jsonGetInt(json, "bundle_count", -1);

  if (countA >= 0)
  {
    countBundle = countA;
  }
  else if (countB >= 0)
  {
    countBundle = countB;
  }
}

// =====================================================
// TOPIC
// Otomatis mengikuti scanType.
// assy_in  -> rfid/assy/in/...
// assy_out -> rfid/assy/out/...
// =====================================================
void buildTopics()
{
  String path = scanPath();

  topicTag = "rfid/assy/" + path + "/" + deviceId + "/tag";
  topicStatus = "rfid/assy/" + path + "/" + deviceId + "/status";
  topicReply = "rfid/assy/" + path + "/reply/" + deviceId;
}

// =====================================================
// WIRELESS - MULTI WIFI FAILOVER
// =====================================================

int findWifiIndex(const String &targetSsid)
{
  for (size_t i = 0; i < WIFI_COUNT; i++)
  {
    if (targetSsid == WIFI_SSIDS[i])
    {
      return (int)i;
    }
  }

  return -1;
}

void loadSavedWiFi()
{
  wifiPrefs.begin("wifi", true);

  savedWifiSsid =
      wifiPrefs.getString(
          "last_ssid",
          "");

  wifiPrefs.end();

  if (findWifiIndex(savedWifiSsid) < 0)
  {
    savedWifiSsid = "";
  }

  if (savedWifiSsid.length() > 0)
  {
    debugPrint("[WIFI] Saved SSID: " + savedWifiSsid);
  }
  else
  {
    debugPrint("[WIFI] Saved SSID: NONE");
  }
}

void saveSuccessfulWiFi(const String &activeSsid)
{
  if (activeSsid.length() == 0)
  {
    return;
  }

  if (findWifiIndex(activeSsid) < 0)
  {
    return;
  }

  // Hindari menulis flash berulang kali
  // jika SSID tidak berubah.
  if (activeSsid == savedWifiSsid)
  {
    return;
  }

  wifiPrefs.begin("wifi", false);

  wifiPrefs.putString(
      "last_ssid",
      activeSsid);

  wifiPrefs.end();

  savedWifiSsid = activeSsid;

  debugPrint("[WIFI] Saved new SSID: " + savedWifiSsid);
}

void optimizeWireless()
{
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);

  // Failover ditangani program.
  WiFi.setAutoReconnect(false);

  WiFi.persistent(false);

  esp_wifi_set_ps(WIFI_PS_NONE);

  btStop();
}

// -----------------------------------------------------
// Urutan awal:
// - Jika ada saved SSID: coba saved SSID SAJA dahulu.
// - Jika belum ada: Tracked -> Tracked (2) -> ... -> (8)
// -----------------------------------------------------
void buildInitialWifiOrder()
{
  wifiTryCount = 0;
  wifiTryPosition = 0;

  const int savedIndex =
      findWifiIndex(savedWifiSsid);

  if (savedIndex >= 0)
  {
    wifiTryOrder[wifiTryCount++] =
        savedIndex;

    return;
  }

  for (size_t i = 0; i < WIFI_COUNT; i++)
  {
    wifiTryOrder[wifiTryCount++] =
        (int)i;
  }
}

// -----------------------------------------------------
// Scan whitelist dan urutkan berdasarkan RSSI terkuat.
// -----------------------------------------------------
bool buildWifiOrderFromScan()
{
  debugPrint("[WIFI] SCANNING...");

  showMessage(
      "SCAN WIFI...",
      "PLEASE WAIT",
      0);

  WiFi.disconnect(false, false);

  const int found =
      WiFi.scanNetworks(
          false,
          true);

  wifiTryCount = 0;
  wifiTryPosition = 0;

  if (found <= 0)
  {
    debugPrint("[WIFI] No network detected");

    WiFi.scanDelete();

    return false;
  }

  bool visible[WIFI_COUNT];
  int bestRssi[WIFI_COUNT];

  for (size_t i = 0; i < WIFI_COUNT; i++)
  {
    visible[i] = false;
    bestRssi[i] = -1000;
  }

  for (int n = 0; n < found; n++)
  {
    const String scannedSsid =
        WiFi.SSID(n);

    const int index =
        findWifiIndex(scannedSsid);

    if (index < 0)
    {
      continue;
    }

    const int rssi =
        WiFi.RSSI(n);

    visible[index] = true;

    if (rssi > bestRssi[index])
    {
      bestRssi[index] = rssi;
    }

    debugPrint(
        "[WIFI] FOUND " +
        scannedSsid +
        " RSSI=" +
        String(rssi));
  }

  WiFi.scanDelete();

  // Setelah koneksi gagal, pilih AP berdasarkan
  // RSSI terkuat, tidak memaksa AP lama.
  while (true)
  {
    int strongestIndex = -1;
    int strongestRssi = -1001;

    for (size_t i = 0; i < WIFI_COUNT; i++)
    {
      if (
          visible[i] &&
          bestRssi[i] > strongestRssi)
      {
        strongestIndex = (int)i;
        strongestRssi = bestRssi[i];
      }
    }

    if (strongestIndex < 0)
    {
      break;
    }

    wifiTryOrder[wifiTryCount++] =
        strongestIndex;

    visible[strongestIndex] = false;
  }

  if (wifiTryCount <= 0)
  {
    debugPrint(
        "[WIFI] No Tracked* whitelist visible");

    return false;
  }

  debugPrint("[WIFI] Priority after scan:");

  for (int i = 0; i < wifiTryCount; i++)
  {
    const int index =
        wifiTryOrder[i];

    debugPrint(
        "  " +
        String(i + 1) +
        ". " +
        String(WIFI_SSIDS[index]) +
        " RSSI=" +
        String(bestRssi[index]));
  }

  return true;
}

void startWifiIndex(int index)
{
  if (
      index < 0 ||
      index >= (int)WIFI_COUNT)
  {
    return;
  }

  currentWifiIndex = index;

  const char *targetSsid =
      WIFI_SSIDS[currentWifiIndex];

  debugPrint("");
  debugPrint("================================");
  debugPrint("[WIFI] TRY: " + String(targetSsid));
  debugPrint("================================");

  showMessage(
      "CONNECT WIFI",
      String(targetSsid),
      0);

  WiFi.disconnect(false, false);

  WiFi.begin(
      targetSsid,
      WIFI_PASS);

  wifiAttemptStarted =
      millis();

  lastWifiAttempt =
      wifiAttemptStarted;

  wifiAttemptInProgress =
      true;

  wifiConnectionHandled =
      false;
}

bool startNextWifiInOrder()
{
  if (
      wifiTryPosition < 0 ||
      wifiTryPosition >= wifiTryCount)
  {
    return false;
  }

  const int index =
      wifiTryOrder[wifiTryPosition];

  startWifiIndex(index);

  return true;
}

void initMultiWiFi()
{
  if (wifiSystemInitialized)
  {
    return;
  }

  wifiSystemInitialized = true;

  loadSavedWiFi();

  buildInitialWifiOrder();

  if (!startNextWifiInOrder())
  {
    lastWifiAttempt = millis();
  }
}

void maintainWiFi()
{
  if (!wifiSystemInitialized)
  {
    initMultiWiFi();
  }

  const wl_status_t wifiStatus =
      WiFi.status();

  // ===================================================
  // CONNECTED
  // ===================================================
  if (wifiStatus == WL_CONNECTED)
  {
    wifiAttemptInProgress = false;

    if (!wifiConnectionHandled)
    {
      wifiConnectionHandled = true;

      wifiWasConnected = true;
      mqttWasConnected = false;
      restoreRequested = false;
      lastMqttAttempt = 0;

      const String activeSsid =
          WiFi.SSID();

      saveSuccessfulWiFi(activeSsid);

      const int activeIndex =
          findWifiIndex(activeSsid);

      if (activeIndex >= 0)
      {
        currentWifiIndex = activeIndex;
      }

      debugPrint(
          "[WIFI] CONNECTED SSID=" +
          activeSsid);

      debugPrint(
          "[WIFI] IP=" +
          WiFi.localIP().toString());

      debugPrint(
          "[WIFI] RSSI=" +
          String(WiFi.RSSI()));

      showMessage(
          "WIFI CONNECTED",
          activeSsid,
          1);

      scheduleReady(1200);
    }

    return;
  }

  const unsigned long now =
      millis();

  // ===================================================
  // BARU PUTUS SETELAH SEBELUMNYA CONNECT
  // ===================================================
  if (wifiWasConnected)
  {
    wifiWasConnected = false;
    wifiConnectionHandled = false;

    mqttWasConnected = false;
    client.disconnect();

    rfidProcessing = false;
    restoreRequested = false;

    debugPrint(
        "[WIFI] LOST -> try saved SSID");

    showMessage(
        "WIFI LOST",
        "FAILOVER...",
        3);

    // Coba SSID terakhir satu kali.
    buildInitialWifiOrder();

    if (startNextWifiInOrder())
    {
      return;
    }
  }

  // ===================================================
  // MENUNGGU SATU AP CONNECT
  // ===================================================
  if (wifiAttemptInProgress)
  {
    if (
        now - wifiAttemptStarted <
        WIFI_CONNECT_TIMEOUT_MS)
    {
      return;
    }

    String failedSsid =
        "UNKNOWN";

    if (
        currentWifiIndex >= 0 &&
        currentWifiIndex < (int)WIFI_COUNT)
    {
      failedSsid =
          WIFI_SSIDS[currentWifiIndex];
    }

    debugPrint(
        "[WIFI] TIMEOUT: " +
        failedSsid);

    WiFi.disconnect(false, false);

    wifiAttemptInProgress = false;

    wifiTryPosition++;

    // Jika masih ada urutan awal / scan berikutnya,
    // coba AP selanjutnya.
    if (startNextWifiInOrder())
    {
      return;
    }

    // Seluruh kandidat yang sedang dicoba gagal.
    // Scan ulang dan prioritaskan RSSI terkuat.
    debugPrint(
        "[WIFI] All current candidates failed -> scan");

    if (buildWifiOrderFromScan())
    {
      wifiTryPosition = 0;

      startNextWifiInOrder();

      return;
    }

    lastWifiAttempt = now;

    showMessage(
        "WIFI OFFLINE",
        "SCAN ULANG...",
        0);

    return;
  }

  // ===================================================
  // TIDAK ADA ATTEMPT AKTIF -> PERIODIC RESCAN
  // ===================================================
  if (
      now - lastWifiAttempt <
      WIFI_RESCAN_INTERVAL)
  {
    return;
  }

  lastWifiAttempt = now;

  if (buildWifiOrderFromScan())
  {
    wifiTryPosition = 0;

    startNextWifiInOrder();

    return;
  }

  showMessage(
      "WIFI OFFLINE",
      "SCAN ULANG...",
      0);
}

bool publishPayload(const String &payload)
{
  if (WiFi.status() != WL_CONNECTED)
  {
    showMessage("WIFI LOST", "TUNGGU KONEKSI", 3);
    scheduleReady(2000);
    return false;
  }

  if (!client.connected())
  {
    showMessage("SERVER LOST", "TUNGGU KONEKSI", 3);
    scheduleReady(2000);
    return false;
  }

  bool ok = client.publish(topicTag.c_str(), payload.c_str(), false);

  if (!ok)
  {
    showMessage("KIRIM GAGAL", "SCAN ULANG", 3);
    scheduleReady(2000);
    return false;
  }

  rfidProcessing = true;
  rfidProcessingStart = millis();

  return true;
}

void requestRestore()
{
  if (restoreRequested || !client.connected())
  {
    return;
  }

  String payload = "__RESTORE__/" + deviceId + "/" + scanType;

  if (publishPayload(payload))
  {
    restoreRequested = true;
    showMessage("SYNC SESSION", "PLEASE WAIT", 0);
    debugPrint("Restore: " + payload);
  }
}

void maintainMQTT()
{
  if (WiFi.status() != WL_CONNECTED)
  {
    return;
  }

  if (client.connected())
  {
    if (!mqttWasConnected)
    {
      mqttWasConnected = true;
      debugPrint("MQTT active");
    }

    return;
  }

  if (mqttWasConnected)
  {
    mqttWasConnected = false;
    rfidProcessing = false;
    restoreRequested = false;
    showMessage("SERVER LOST", "RECONNECT...", 3);
  }

  if (millis() - lastMqttAttempt < MQTT_RETRY_INTERVAL)
  {
    return;
  }

  lastMqttAttempt = millis();

  String clientId = mqttClientPrefix() + deviceId;

  bool ok = client.connect(
      clientId.c_str(),
      topicStatus.c_str(),
      0,
      true,
      "offline");

  if (!ok)
  {
    debugPrint("MQTT failed state=" + String(client.state()));
    showMessage("MQTT FAILED", "RETRY...", 0);
    return;
  }

  mqttWasConnected = true;

  client.subscribe(topicReply.c_str(), 0);
  client.publish(topicStatus.c_str(), "online", true);

  debugPrint("MQTT connected");
  debugPrint("Subscribe: " + topicReply);

  showMessage("MQTT SUCCESS", scanModeTitle(), 1);

  restoreRequested = false;
  requestRestore();
}

// =====================================================
// MQTT CALLBACK
// =====================================================
void callback(char *topic, byte *payload, unsigned int length)
{
  String message = "";
  message.reserve(length + 1);

  for (unsigned int i = 0; i < length; i++)
  {
    message += (char)payload[i];
  }

  message.trim();

  String topicString = String(topic);
  debugPrint("RX: " + topicString + " = " + message);

  if (topicString != topicReply)
  {
    return;
  }

  rfidProcessing = false;
  restoreRequested = false;

  updateReadyData(message);

  String lcd1 = jsonGetString(message, "lcd1");
  String lcd2 = jsonGetString(message, "lcd2");
  int beepValue = jsonGetInt(message, "beep", 1);

  if (lcd1.length() == 0)
  {
    lcd1 = "RESP ERROR";
    lcd2 = "CHECK API";
    beepValue = 3;
  }

  showMessage(lcd1, lcd2, beepValue);
  scheduleReady(2500);
}

// =====================================================
// RFID READER STX/ETX
// =====================================================
String readTag(Stream &serial)
{
  if (!serial.available())
  {
    return "";
  }

  if (serial.read() != 0x02)
  {
    return "";
  }

  String hexData = "";
  unsigned long start = millis();

  while (millis() - start < 100)
  {
    if (!serial.available())
    {
      delay(1);
      continue;
    }

    char c = (char)serial.read();

    if (c == 0x03)
    {
      break;
    }

    hexData += c;
  }

  if (hexData.length() < 12)
  {
    return "";
  }

  String tagHex = hexData.substring(0, 10);
  String serialHex = tagHex.substring(2, 10);

  uint64_t tagDecimal = strtoull(serialHex.c_str(), nullptr, 16);

  char buffer[20];
  snprintf(
      buffer,
      sizeof(buffer),
      "%010llu",
      (unsigned long long)tagDecimal);

  return String(buffer);
}

// =====================================================
// DEBOUNCE RFID
// =====================================================
bool allowRFID(const String &tag)
{
  unsigned long now = millis();

  if (tag == lastTag && now - lastReadTime < RFID_DEBOUNCE_TIME)
  {
    lastReadTime = now;
    debugPrint("RFID duplicate ignored: " + tag);
    return false;
  }

  if (rfidProcessing)
  {
    lastTag = tag;
    lastReadTime = now;
    debugPrint("RFID ignored, waiting backend: " + tag);
    return false;
  }

  lastTag = tag;
  lastReadTime = now;

  return true;
}

void processTag(const String &tag)
{
  if (!allowRFID(tag))
  {
    return;
  }

  String payload = tag + "/" + deviceId + "/" + scanType;

  debugPrint("Publish: " + payload);

  if (publishPayload(payload))
  {
    showMessage("PROCESSING", tag, 1);
  }
}

// =====================================================
// BUTTON OPTIONAL
// =====================================================
void handleButton()
{
  static bool lastState = HIGH;
  static unsigned long lastDebounce = 0;
  static unsigned long lastMessage = 0;

  bool reading = digitalRead(BUTTON_PIN);

  if (reading != lastState)
  {
    lastDebounce = millis();
    lastState = reading;
  }

  if (millis() - lastDebounce > 50 && reading == LOW && millis() - lastMessage > 1000)
  {
    lastMessage = millis();

    if (scanType == "assy_out")
    {
      showMessage("RFID ASSY", "OUT MODE", 2);
    }
    else
    {
      showMessage("RFID ASSY", "IN MODE", 2);
    }

    scheduleReady(2000);
  }
}

// =====================================================
// MAC ADDRESS WIFI STA (ESP-IDF)
// Ambil MAC dari eFuse tanpa bergantung pada status koneksi WiFi.
// =====================================================
bool initDeviceMac()
{
  uint8_t mac[6] = {0};
  esp_err_t result = esp_read_mac(mac, ESP_MAC_WIFI_STA);

  if (result != ESP_OK)
  {
    debugPrint("[MAC] esp_read_mac FAILED, error=" + String((int)result));
    return false;
  }

  char macText[13];
  snprintf(macText, sizeof(macText), "%02X%02X%02X%02X%02X%02X",
           mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  deviceId = String(macText);

  if (deviceId == "000000000000" || deviceId.length() != 12)
  {
    debugPrint("[MAC] INVALID: " + deviceId);
    return false;
  }

  debugPrint("[MAC] WIFI_STA: " + deviceId);
  return true;
}

// =====================================================
// SETUP
// =====================================================
void setup()
{
  Serial.begin(115200);

  scanType.toLowerCase();
  scanType.trim();

  if (scanType != "assy_in" && scanType != "assy_out")
  {
    scanType = "assy_in";
  }

  pinMode(BUTTON_PIN, INPUT_PULLUP);

  buzzerBegin();

  RFID.begin(
      RFID_BAUD,
      SERIAL_8N1,
      RFID_RX_PIN,
      RFID_TX_PIN);

  lcd.init();
  lcd.backlight();

  showMessage("SYSTEM BOOT", scanModeTitle(), 1);

  optimizeWireless();

  // MAC dipakai untuk MQTT client ID, topic dan payload restore/tag.
  // Jangan lanjut jika MAC invalid agar backend tidak menerima 000000000000.
  if (!initDeviceMac())
  {
    showMessage("MAC ERROR", "CHECK ESP32", 3);
    while (true)
    {
      delay(1000);
    }
  }

  buildTopics();

  debugPrint("Device ID   : " + deviceId);
  debugPrint("Scan Type   : " + scanType);
  debugPrint("Topic Tag   : " + topicTag);
  debugPrint("Topic Reply : " + topicReply);

  client.setServer(mqttServer, mqttPort);
  client.setCallback(callback);
  client.setBufferSize(1536);
  client.setKeepAlive(30);
  client.setSocketTimeout(5);

  lastWifiAttempt = 0;
  lastMqttAttempt = millis() - MQTT_RETRY_INTERVAL;

  // Mulai multi-WiFi.
  initMultiWiFi();
}

// =====================================================
// LOOP
// =====================================================
void loop()
{
  maintainWiFi();
  maintainMQTT();

  if (client.connected())
  {
    client.loop();
  }

  handleButton();

  if (rfidProcessing && millis() - rfidProcessingStart >= RFID_PROCESSING_TIMEOUT)
  {
    rfidProcessing = false;
    restoreRequested = false;

    debugPrint("RFID processing timeout");
    showMessage("TIMEOUT", "SCAN ULANG", 3);
    scheduleReady(2000);
  }

  if (returnToReady && millis() - returnReadyStart >= returnReadyDelay)
  {
    returnToReady = false;
    showReady();
  }

  if (client.connected() && millis() - lastHeartbeat >= HEARTBEAT_INTERVAL)
  {
    lastHeartbeat = millis();
    client.publish(topicStatus.c_str(), "online", true);
  }

  // Tetap baca UART walaupun sedang processing supaya frame RFID tidak menumpuk.
  String tag = readTag(RFID);

  if (tag.length() > 0)
  {
    processTag(tag);
  }

  delay(2);
}