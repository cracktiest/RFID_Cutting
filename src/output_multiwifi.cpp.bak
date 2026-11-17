#include <Arduino.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <Preferences.h>

#include "esp_mac.h"
#include "esp_system.h"
#include "esp_wifi.h"

// ============================================================
// FORWARD DECLARATION
// ============================================================
// Diperlukan karena Arduino IDE membuat function prototype
// otomatis sebelum sebagian deklarasi pada file .ino.
struct ToneStep;


// ============================================================
// RFID OUTPUT SEWING - ESP32 + BOOT COUNTER + RESET REASON
// Compatible with Node-RED RFID Output Sewing MANUAL v8
//
// DEVICE ID : WiFi STA MAC tanpa ":" -> AABBCCDDEEFF
//
// PUBLISH:
//   rfid_mac/<MAC>/tag
//
// SUBSCRIBE:
//   rfid_mac/<MAC>/operator_id
//   rfid_mac/<MAC>/nama
//   rfid_mac/<MAC>/line
//   rfid_mac/<MAC>/output
//   rfid_mac/<MAC>/login
//   rfid_mac/<MAC>/response
//
// Passive buzzer : GPIO25
// RDM6300 RX      : GPIO16
// RDM6300 TX      : GPIO17 (tidak wajib dipakai reader)
// LCD I2C         : SDA 21, SCL 22
//
// IMPORTANT:
// - ESP32 TIDAK mereset login ketika reboot.
// - Login/nama/line/output dipulihkan dari retained MQTT.
// - Debounce utama RFID ada di ESP32.
// - Node-RED mempunyai debounce server tambahan.
// - Boot counter persistent menggunakan Preferences/NVS.
// - WiFi multi-SSID failover Tracked s/d Tracked (8).
// - SSID terakhir yang sukses disimpan persistent di NVS.
// - Reset reason tampil di Serial + LCD + MQTT debug.
// ============================================================


// ============================================================
// WIFI - MULTI SSID FAILOVER
// ============================================================
//
// Cara kerja:
// 1. SSID terakhir yang berhasil disimpan di NVS (persistent flash).
// 2. Saat boot, SSID terakhir dicoba terlebih dahulu.
// 3. Jika belum pernah tersimpan, ESP32 mencoba:
//      Tracked -> Tracked (2) -> ... -> Tracked (8).
// 4. Jika SSID tersimpan gagal, ESP32 langsung scan ulang.
// 5. Jika daftar awal seluruhnya gagal, ESP32 juga scan ulang.
// 6. Dari hasil scan, SSID Tracked* dengan RSSI terkuat dicoba dulu.
// 7. Selama koneksi sehat, ESP32 TIDAK pindah WiFi agar MQTT stabil.
//
// Semua SSID di bawah diasumsikan memakai password yang sama.
// ============================================================

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

// const char* WIFI_SSIDS[] = {
//     "GM2_RFID (2)",
//     "GM2_RFID (3)",
//     "GM2_RFID (4)"
//     // "Tracked (2)",
//     // "Tracked (3)",
//     // "Tracked (4)",
//     // "Tracked (5)",
//     // "Tracked (6)",
//     // "Tracked (7)",
//     // "Tracked (8)",
//     // "Tracked (9)"
// };

const size_t WIFI_COUNT =
    sizeof(WIFI_SSIDS) /
    sizeof(WIFI_SSIDS[0]);

const char* WIFI_PASS = "Factory@RFID";

// Timeout untuk mencoba satu access point.
const unsigned long WIFI_CONNECT_TIMEOUT_MS = 8000;

// Jika semua AP gagal / scan tidak menemukan AP,
// tunggu sebentar sebelum scan ulang.
const unsigned long WIFI_RESCAN_MS = 5000;

// Penyimpanan SSID terakhir yang sukses.
Preferences wifiPrefs;

String savedWifiSsid;

// Index SSID yang sedang dicoba.
int currentWifiIndex = -1;

// Urutan SSID yang akan dicoba.
int wifiTryOrder[WIFI_COUNT];
int wifiTryCount = 0;
int wifiTryPosition = 0;

// State koneksi.
bool wifiAttemptInProgress = false;
bool wifiConnectionHandled = false;

unsigned long wifiAttemptStarted = 0;
unsigned long lastWifiAttempt = 0;


// ============================================================
// MQTT
// ============================================================

const char* MQTT_HOST = "10.5.2.222";
// const char* MQTT_HOST = "10.5.0.99";
const uint16_t MQTT_PORT = 1883;


// ============================================================
// PIN
// ============================================================

#define RFID_RX_PIN   16
#define RFID_TX_PIN   17

#define BUZZER_PIN    25

#define I2C_SDA_PIN   21
#define I2C_SCL_PIN   22

#define LED_PIN        2


// ============================================================
// LCD
// ============================================================

#define LCD_ADDRESS 0x27
#define LCD_COLS    16
#define LCD_ROWS     2

LiquidCrystal_I2C lcd(LCD_ADDRESS, LCD_COLS, LCD_ROWS);


// ============================================================
// RFID SERIAL
// ============================================================

HardwareSerial RFIDSerial(2);


// ============================================================
// WIFI / MQTT
// ============================================================

WiFiClient wifiClient;
PubSubClient mqtt(wifiClient);


// ============================================================
// DEVICE ID
// ============================================================

String deviceId;
String mqttBase;


// ============================================================
// BOOT DIAGNOSTIC
// ============================================================

Preferences diagPrefs;

uint32_t bootCount = 0;

String topicStatus;
String topicIp;
String topicDebugReset;
String topicDebugInfo;


// ============================================================
// OPERATOR STATE
// ============================================================

bool operatorLoggedIn = false;

String operatorId;
String operatorName;
String operatorLine;

uint32_t outputCount = 0;


// ============================================================
// CONNECTION STATE
// ============================================================

unsigned long lastMqttAttempt = 0;

const unsigned long MQTT_RETRY_MS = 3000;

bool mqttWasConnected = false;


// ============================================================
// RFID DEBOUNCE
// ============================================================
//
// Reader RDM6300 dapat mengirim kartu yang sama berulang-ulang
// selama kartu masih berada dekat reader.
//
// Debounce ESP32 = 1500 ms.
// Node-RED masih mempunyai debounce tambahan 600 ms.
// ============================================================

String lastRFID;
unsigned long lastRFIDTime = 0;

const unsigned long RFID_DEBOUNCE_MS = 1500;


// ============================================================
// LCD TEMPORARY SCREEN
// ============================================================

bool temporaryScreen = false;
unsigned long temporaryUntil = 0;

const unsigned long RESPONSE_SCREEN_MS = 1800;


// ============================================================
// MQTT RESTORE WINDOW
// ============================================================
//
// Sesudah subscribe, beri waktu retained MQTT untuk masuk sebelum
// menampilkan home screen.
// ============================================================

bool restoringRetained = false;
unsigned long restoreUntil = 0;

const unsigned long RESTORE_WAIT_MS = 900;


// ============================================================
// RDM6300 BUFFER
// ============================================================

bool rdmFrameStarted = false;
char rdmData[13] = {0};
uint8_t rdmIndex = 0;


// ============================================================
// PASSIVE BUZZER - NON BLOCKING
// ============================================================
//
// Passive buzzer membutuhkan frekuensi/tone.
// Tidak menggunakan digitalWrite HIGH/LOW untuk menghasilkan suara.
//
// Bunyi:
// SCAN    : beep tinggi singkat
// SUCCESS : 2 nada naik
// ERROR   : 2 nada turun
// ============================================================

struct ToneStep {
    uint16_t frequency;
    uint16_t durationMs;
    uint16_t gapMs;
};

const ToneStep BEEP_SCAN[] = {
    {2200, 55, 0}
};

const ToneStep BEEP_SUCCESS[] = {
    {2400, 70, 55},
    {3100, 100, 0}
};

const ToneStep BEEP_ERROR[] = {
    {950, 150, 65},
    {650, 230, 0}
};

const ToneStep* activePattern = nullptr;
size_t activePatternLength = 0;
size_t activePatternIndex = 0;

enum BuzzerPhase {
    BUZZER_IDLE,
    BUZZER_TONE,
    BUZZER_GAP
};

BuzzerPhase buzzerPhase = BUZZER_IDLE;
unsigned long buzzerDeadline = 0;


// ============================================================
// TIME HELPER
// ============================================================

bool timeReached(unsigned long deadline) {
    return (long)(millis() - deadline) >= 0;
}


// ============================================================
// PASSIVE BUZZER FUNCTIONS
// ============================================================

void stopBuzzer() {
    noTone(BUZZER_PIN);

    activePattern = nullptr;
    activePatternLength = 0;
    activePatternIndex = 0;

    buzzerPhase = BUZZER_IDLE;
    buzzerDeadline = 0;
}


void startCurrentToneStep() {

    if (
        activePattern == nullptr ||
        activePatternIndex >= activePatternLength
    ) {
        stopBuzzer();
        return;
    }

    const ToneStep& step = activePattern[activePatternIndex];

    tone(BUZZER_PIN, step.frequency);

    buzzerPhase = BUZZER_TONE;
    buzzerDeadline = millis() + step.durationMs;
}


void startBuzzerPattern(
    const ToneStep* pattern,
    size_t length
) {

    stopBuzzer();

    activePattern = pattern;
    activePatternLength = length;
    activePatternIndex = 0;

    startCurrentToneStep();
}


void buzzerTask() {

    if (buzzerPhase == BUZZER_IDLE)
        return;


    if (!timeReached(buzzerDeadline))
        return;


    if (buzzerPhase == BUZZER_TONE) {

        noTone(BUZZER_PIN);

        const ToneStep& step =
            activePattern[activePatternIndex];

        if (step.gapMs > 0) {

            buzzerPhase = BUZZER_GAP;
            buzzerDeadline = millis() + step.gapMs;

            return;
        }

        activePatternIndex++;
        startCurrentToneStep();

        return;
    }


    if (buzzerPhase == BUZZER_GAP) {

        activePatternIndex++;
        startCurrentToneStep();
    }
}


void beepScan() {
    startBuzzerPattern(
        BEEP_SCAN,
        sizeof(BEEP_SCAN) / sizeof(BEEP_SCAN[0])
    );
}


void beepSuccess() {
    startBuzzerPattern(
        BEEP_SUCCESS,
        sizeof(BEEP_SUCCESS) / sizeof(BEEP_SUCCESS[0])
    );
}


void beepError() {
    startBuzzerPattern(
        BEEP_ERROR,
        sizeof(BEEP_ERROR) / sizeof(BEEP_ERROR[0])
    );
}


// ============================================================
// RESET FUNCTION
// ============================================================

void esp_rst() {

    Serial.println();
    Serial.println("================================");
    Serial.println("ESP32 RESTART");
    Serial.println("================================");

    delay(150);
    ESP.restart();
}


// ============================================================
// MAC FUNCTIONS
// ============================================================

String normalizeMac(String mac) {

    mac.trim();
    mac.toUpperCase();

    mac.replace(":", "");
    mac.replace("-", "");
    mac.replace(" ", "");

    return mac;
}


bool isInvalidMac(String mac) {

    mac = normalizeMac(mac);

    if (mac.length() != 12)
        return true;


    for (int i = 0; i < 12; i++) {

        const char c = mac[i];

        const bool valid =
            (c >= '0' && c <= '9') ||
            (c >= 'A' && c <= 'F');

        if (!valid)
            return true;
    }


    if (mac == "000000000000")
        return true;

    if (mac == "FFFFFFFFFFFF")
        return true;

    if (mac == "020000000000")
        return true;


    // Multicast MAC tidak valid sebagai station identity.
    const uint8_t firstByte =
        (uint8_t)strtoul(
            mac.substring(0, 2).c_str(),
            nullptr,
            16
        );

    if ((firstByte & 0x01) != 0)
        return true;


    return false;
}


String macFromBytes(const uint8_t* mac) {

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

    uint8_t mac[6] = {0};

    const esp_err_t result =
        esp_read_mac(
            mac,
            ESP_MAC_WIFI_STA
        );

    if (result != ESP_OK) {

        Serial.print("[MAC] esp_read_mac gagal, code=");
        Serial.println((int)result);

        return "";
    }

    return normalizeMac(macFromBytes(mac));
}


void haltInvalidMac(String mac) {

    Serial.println();
    Serial.println("================================");
    Serial.println("FATAL: MAC INVALID");
    Serial.print("MAC: ");
    Serial.println(mac);
    Serial.println("================================");

    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("MAC INVALID");
    lcd.setCursor(0, 1);
    lcd.print("DEVICE STOP");

    while (true) {

        tone(BUZZER_PIN, 700);
        digitalWrite(LED_PIN, HIGH);
        delay(120);

        noTone(BUZZER_PIN);
        digitalWrite(LED_PIN, LOW);
        delay(880);
    }
}


void ensureValidDeviceId() {

    deviceId = getSafeMacAddress();

    if (isInvalidMac(deviceId)) {
        haltInvalidMac(deviceId);
    }


    mqttBase =
        "rfid_mac/" +
        deviceId +
        "/";


    Serial.println();
    Serial.println("================================");
    Serial.println("DEVICE");
    Serial.println("================================");
    Serial.print("MAC ID   : ");
    Serial.println(deviceId);
    Serial.print("MQTT BASE: ");
    Serial.println(mqttBase);
    Serial.println("================================");
}


// ============================================================
// RESET REASON
// ============================================================

String resetReasonText() {

    const esp_reset_reason_t reason =
        esp_reset_reason();

    switch (reason) {

        case ESP_RST_POWERON:
            return "POWER ON";

        case ESP_RST_EXT:
            return "EXT RESET";

        case ESP_RST_SW:
            return "SOFTWARE";

        case ESP_RST_PANIC:
            return "PANIC/CRASH";

        case ESP_RST_INT_WDT:
            return "INT WDT";

        case ESP_RST_TASK_WDT:
            return "TASK WDT";

        case ESP_RST_WDT:
            return "WATCHDOG";

        case ESP_RST_DEEPSLEEP:
            return "DEEPSLEEP";

        case ESP_RST_BROWNOUT:
            return "BROWNOUT";

        case ESP_RST_SDIO:
            return "SDIO";

        default:
            return "UNKNOWN";
    }
}


// ============================================================
// BOOT COUNTER
// ============================================================
//
// Preferences disimpan di NVS.
// Jadi nilainya tetap tersimpan setelah restart / power off.
// ============================================================

void loadBootCounter() {

    diagPrefs.begin(
        "diag",
        false
    );

    bootCount =
        diagPrefs.getUInt(
            "boot",
            0
        );

    bootCount++;

    diagPrefs.putUInt(
        "boot",
        bootCount
    );

    diagPrefs.end();
}


// ============================================================
// DIAGNOSTIC MQTT TOPICS
// ============================================================

void buildDiagnosticTopics() {

    topicStatus =
        mqttBase +
        "status";

    topicIp =
        mqttBase +
        "ip";

    topicDebugReset =
        mqttBase +
        "debug/reset_reason";

    topicDebugInfo =
        mqttBase +
        "debug/info";
}


// ============================================================
// SERIAL RESET DEBUG
// ============================================================

void printResetDebug() {

    Serial.println();
    Serial.println("================================");
    Serial.println("BOOT / RESET DEBUG");
    Serial.println("================================");

    Serial.print("Boot count : ");
    Serial.println(bootCount);

    Serial.print("Reason     : ");
    Serial.println(resetReasonText());

    Serial.print("Free heap  : ");
    Serial.println(ESP.getFreeHeap());

    Serial.println("================================");
}


// ============================================================
// LCD BOOT DIAGNOSTIC
// ============================================================

void showResetReasonOnLCD() {

    String reason =
        resetReasonText();

    if (reason.length() > LCD_COLS) {
        reason =
            reason.substring(
                0,
                LCD_COLS
            );
    }


    String bootText =
        "BOOT #" +
        String(bootCount);

    if (bootText.length() > LCD_COLS) {
        bootText =
            bootText.substring(
                0,
                LCD_COLS
            );
    }


    lcd.clear();

    lcd.setCursor(0, 0);
    lcd.print(bootText);

    lcd.setCursor(0, 1);
    lcd.print(reason);


    Serial.print("[BOOT] count=");
    Serial.print(bootCount);

    Serial.print(" reset=");
    Serial.println(
        resetReasonText()
    );


    delay(1500);
}


// ============================================================
// MQTT STARTUP DEBUG
// ============================================================
//
// Retained MQTT:
//
// rfid_mac/<MAC>/status
// rfid_mac/<MAC>/ip
// rfid_mac/<MAC>/debug/reset_reason
// rfid_mac/<MAC>/debug/info
//
// ============================================================

void publishStartupDebug() {

    if (!mqtt.connected()) {
        return;
    }


    const String ipAddress =
        WiFi.localIP().toString();

    const String resetReason =
        resetReasonText();

    const String connectedSsid =
        WiFi.SSID();


    char debugPayload[384];

    snprintf(
        debugPayload,
        sizeof(debugPayload),
        "{"
          "\"device\":\"%s\","
          "\"boot_count\":%lu,"
          "\"reset_reason\":\"%s\","
          "\"ssid\":\"%s\","
          "\"ip\":\"%s\","
          "\"rssi\":%ld,"
          "\"free_heap\":%lu"
        "}",
        deviceId.c_str(),
        (unsigned long)bootCount,
        resetReason.c_str(),
        connectedSsid.c_str(),
        ipAddress.c_str(),
        (long)WiFi.RSSI(),
        (unsigned long)ESP.getFreeHeap()
    );


    mqtt.publish(
        topicStatus.c_str(),
        "1",
        true
    );

    mqtt.publish(
        topicIp.c_str(),
        ipAddress.c_str(),
        true
    );

    mqtt.publish(
        topicDebugReset.c_str(),
        resetReason.c_str(),
        true
    );

    mqtt.publish(
        topicDebugInfo.c_str(),
        debugPayload,
        true
    );


    Serial.print(
        "[MQTT DEBUG] "
    );

    Serial.println(
        debugPayload
    );
}


// ============================================================
// LCD
// ============================================================

String lcdFit(String text) {

    if (text.length() > LCD_COLS) {
        text = text.substring(0, LCD_COLS);
    }

    while (text.length() < LCD_COLS) {
        text += ' ';
    }

    return text;
}


void lcdPrintLine(
    uint8_t row,
    const String& text
) {

    lcd.setCursor(0, row);
    lcd.print(lcdFit(text));
}


void showHome() {

    if (temporaryScreen || restoringRetained)
        return;


    if (!operatorLoggedIn) {

        lcdPrintLine(0, "SILAKAN LOGIN");
        lcdPrintLine(1, "TAP KARTU USER");

        return;
    }


    String line1 = operatorName;

    if (line1.length() == 0)
        line1 = "OPERATOR";


    if (operatorLine.length() > 0) {

        line1 += " L";
        line1 += operatorLine;
    }


    const String line2 =
        "OUTPUT: " +
        String(outputCount);


    lcdPrintLine(0, line1);
    lcdPrintLine(1, line2);
}


void showTemporary(
    const String& line1,
    const String& line2,
    unsigned long duration = RESPONSE_SCREEN_MS
) {

    temporaryScreen = true;
    temporaryUntil = millis() + duration;

    lcdPrintLine(0, line1);
    lcdPrintLine(1, line2);
}


void lcdTask() {

    if (
        temporaryScreen &&
        timeReached(temporaryUntil)
    ) {

        temporaryScreen = false;

        if (!restoringRetained)
            showHome();
    }


    if (
        restoringRetained &&
        timeReached(restoreUntil)
    ) {

        restoringRetained = false;

        if (!temporaryScreen)
            showHome();
    }
}


// ============================================================
// MQTT TOPIC SUBSCRIBE
// ============================================================

void subscribeDeviceTopics() {

    mqtt.subscribe(
        (mqttBase + "operator_id").c_str()
    );

    mqtt.subscribe(
        (mqttBase + "nama").c_str()
    );

    mqtt.subscribe(
        (mqttBase + "line").c_str()
    );

    mqtt.subscribe(
        (mqttBase + "output").c_str()
    );

    mqtt.subscribe(
        (mqttBase + "login").c_str()
    );

    mqtt.subscribe(
        (mqttBase + "response").c_str()
    );


    Serial.println("[MQTT] SUBSCRIBED:");

    Serial.println(
        "  " +
        mqttBase +
        "operator_id"
    );

    Serial.println(
        "  " +
        mqttBase +
        "nama"
    );

    Serial.println(
        "  " +
        mqttBase +
        "line"
    );

    Serial.println(
        "  " +
        mqttBase +
        "output"
    );

    Serial.println(
        "  " +
        mqttBase +
        "login"
    );

    Serial.println(
        "  " +
        mqttBase +
        "response"
    );
}


// ============================================================
// SERVER RESPONSE
// ============================================================

void handleServerResponse(String response) {

    response.trim();
    response.toUpperCase();

    Serial.print("[SERVER] ");
    Serial.println(response);


    // ---------------- SUCCESS ----------------

    if (response == "SUKSES") {

        beepSuccess();

        showTemporary(
            "OUTPUT BERHASIL",
            "TOTAL: " + String(outputCount)
        );

        return;
    }


    // ---------------- LOGIN ----------------

    if (response == "LOGIN BERHASIL") {

        beepSuccess();

        showTemporary(
            "LOGIN BERHASIL",
            operatorName.length()
                ? operatorName
                : "OPERATOR"
        );

        return;
    }


    // ---------------- CHANGE OPERATOR ----------------

    if (response == "GANTI OPERATOR") {

        beepSuccess();

        showTemporary(
            "GANTI OPERATOR",
            operatorName.length()
                ? operatorName
                : "OPERATOR"
        );

        return;
    }


    // ---------------- LOGOUT ----------------

    if (response == "LOGOUT BERHASIL") {

        beepSuccess();

        showTemporary(
            "LOGOUT BERHASIL",
            ""
        );

        return;
    }


    // ---------------- DUPLICATE ----------------

    if (response == "GARMENT SUDAH TERINPUT") {

        beepError();

        showTemporary(
            "SUDAH TERINPUT",
            "SCAN DITOLAK"
        );

        return;
    }


    // ---------------- GARMENT INVALID ----------------

    if (response == "GARMENT TIDAK DITEMUKAN") {

        beepError();

        showTemporary(
            "GARMENT TIDAK",
            "DITEMUKAN"
        );

        return;
    }


    // ---------------- LOGIN REQUIRED ----------------

    if (response == "SILAKAN LOGIN") {

        beepError();

        showTemporary(
            "SILAKAN LOGIN",
            "KARTU OPERATOR"
        );

        return;
    }


    // ---------------- SESSION CHANGED ----------------

    if (response == "LOGIN BERUBAH SCAN ULANG") {

        beepError();

        showTemporary(
            "LOGIN BERUBAH",
            "SCAN ULANG"
        );

        return;
    }


    // ---------------- UNKNOWN BUSINESS ERROR ----------------

    beepError();

    showTemporary(
        "PROSES GAGAL",
        response
    );
}


// ============================================================
// MQTT CALLBACK
// ============================================================

void mqttCallback(
    char* topicRaw,
    byte* payloadRaw,
    unsigned int length
) {

    const String topic(topicRaw);

    String payload;
    payload.reserve(length);

    for (unsigned int i = 0; i < length; i++) {
        payload += (char)payloadRaw[i];
    }

    payload.trim();


    Serial.print("[MQTT RX] ");
    Serial.print(topic);
    Serial.print(" = ");
    Serial.println(payload);


    // ---------------- OPERATOR ID ----------------

    if (topic == mqttBase + "operator_id") {

        operatorId = payload;
        return;
    }


    // ---------------- NAME ----------------

    if (topic == mqttBase + "nama") {

        operatorName = payload;

        if (!temporaryScreen && !restoringRetained)
            showHome();

        return;
    }


    // ---------------- LINE ----------------

    if (topic == mqttBase + "line") {

        operatorLine = payload;

        if (!temporaryScreen && !restoringRetained)
            showHome();

        return;
    }


    // ---------------- OUTPUT ----------------

    if (topic == mqttBase + "output") {

        outputCount =
            strtoul(
                payload.c_str(),
                nullptr,
                10
            );

        if (!temporaryScreen && !restoringRetained)
            showHome();

        return;
    }


    // ---------------- LOGIN ----------------

    if (topic == mqttBase + "login") {

        operatorLoggedIn =
            (payload == "1");


        if (!operatorLoggedIn) {

            operatorId = "";
            operatorName = "";
            operatorLine = "";
            outputCount = 0;
        }


        if (!temporaryScreen && !restoringRetained)
            showHome();

        return;
    }


    // ---------------- RESPONSE ----------------

    if (topic == mqttBase + "response") {

        handleServerResponse(payload);
        return;
    }
}


// ============================================================
// WIFI
// ============================================================

int findWifiIndex(const String& ssid) {

    for (size_t i = 0; i < WIFI_COUNT; i++) {

        if (ssid == WIFI_SSIDS[i]) {
            return (int)i;
        }
    }

    return -1;
}


void loadSavedWiFi() {

    wifiPrefs.begin(
        "wifi",
        true
    );

    savedWifiSsid =
        wifiPrefs.getString(
            "last_ssid",
            ""
        );

    wifiPrefs.end();


    if (findWifiIndex(savedWifiSsid) < 0) {
        savedWifiSsid = "";
    }


    Serial.print("[WIFI] saved SSID: ");

    if (savedWifiSsid.length()) {
        Serial.println(savedWifiSsid);
    }
    else {
        Serial.println("(belum ada)");
    }
}


void saveSuccessfulWiFi(const String& ssid) {

    if (ssid.length() == 0)
        return;

    if (findWifiIndex(ssid) < 0)
        return;

    if (ssid == savedWifiSsid)
        return;


    wifiPrefs.begin(
        "wifi",
        false
    );

    wifiPrefs.putString(
        "last_ssid",
        ssid
    );

    wifiPrefs.end();


    savedWifiSsid = ssid;


    Serial.print("[WIFI] SSID disimpan: ");
    Serial.println(savedWifiSsid);
}


// Membuat urutan awal:
// - Jika ada SSID tersimpan: coba SSID itu SAJA terlebih dahulu.
//   Jika gagal, wifiTask() akan langsung melakukan scan.
// - Jika belum ada SSID tersimpan: coba urut
//   Tracked -> Tracked (2) -> ... -> Tracked (8).
void buildPriorityWifiOrder() {

    wifiTryCount = 0;
    wifiTryPosition = 0;


    const int savedIndex =
        findWifiIndex(savedWifiSsid);


    if (savedIndex >= 0) {

        wifiTryOrder[wifiTryCount++] =
            savedIndex;

        return;
    }


    for (size_t i = 0; i < WIFI_COUNT; i++) {

        wifiTryOrder[wifiTryCount++] =
            (int)i;
    }
}


// Scan ulang AP yang tersedia.
// Setelah SSID sebelumnya gagal, kandidat hasil scan
// diurutkan berdasarkan RSSI terkuat.
bool buildWifiOrderFromScan() {

    Serial.println();
    Serial.println("[WIFI] SCANNING...");

    lcdPrintLine(
        0,
        "SCAN WIFI..."
    );

    lcdPrintLine(
        1,
        "PLEASE WAIT"
    );


    WiFi.disconnect(
        false,
        false
    );


    const int found =
        WiFi.scanNetworks(
            false,
            true
        );


    wifiTryCount = 0;
    wifiTryPosition = 0;


    if (found <= 0) {

        Serial.println("[WIFI] tidak ada AP terdeteksi");

        WiFi.scanDelete();

        return false;
    }


    bool visible[WIFI_COUNT];

    int bestRssi[WIFI_COUNT];


    for (size_t i = 0; i < WIFI_COUNT; i++) {

        visible[i] = false;
        bestRssi[i] = -1000;
    }


    Serial.println("[WIFI] hasil scan whitelist:");


    for (int n = 0; n < found; n++) {

        const String ssid =
            WiFi.SSID(n);

        const int index =
            findWifiIndex(ssid);


        if (index < 0)
            continue;


        const int rssi =
            WiFi.RSSI(n);


        visible[index] = true;


        if (rssi > bestRssi[index]) {
            bestRssi[index] = rssi;
        }


        Serial.print("  ");
        Serial.print(ssid);
        Serial.print(" RSSI=");
        Serial.println(rssi);
    }


    WiFi.scanDelete();


    // Setelah koneksi sebelumnya gagal, hasil scan tidak lagi
    // memaksa SSID lama. Semua kandidat diurutkan berdasarkan
    // RSSI paling kuat agar failover memilih AP yang paling baik.
    while (true) {

        int strongestIndex = -1;
        int strongestRssi = -1001;


        for (size_t i = 0; i < WIFI_COUNT; i++) {

            if (
                visible[i] &&
                bestRssi[i] > strongestRssi
            ) {

                strongestRssi =
                    bestRssi[i];

                strongestIndex =
                    (int)i;
            }
        }


        if (strongestIndex < 0)
            break;


        wifiTryOrder[wifiTryCount++] =
            strongestIndex;

        visible[strongestIndex] = false;
    }


    if (wifiTryCount == 0) {

        Serial.println(
            "[WIFI] tidak ada SSID Tracked* yang terlihat"
        );

        return false;
    }


    Serial.println("[WIFI] urutan hasil scan:");

    for (int i = 0; i < wifiTryCount; i++) {

        const int index =
            wifiTryOrder[i];

        Serial.print("  ");
        Serial.print(i + 1);
        Serial.print(". ");
        Serial.println(WIFI_SSIDS[index]);
    }


    return true;
}


void connectWifiIndex(int index) {

    if (
        index < 0 ||
        index >= (int)WIFI_COUNT
    ) {
        return;
    }


    currentWifiIndex = index;

    const char* ssid =
        WIFI_SSIDS[currentWifiIndex];


    Serial.println();
    Serial.println("================================");
    Serial.println("WIFI CONNECT");
    Serial.println("================================");
    Serial.print("SSID: ");
    Serial.println(ssid);
    Serial.println("================================");


    lcdPrintLine(
        0,
        "CONNECT WIFI"
    );

    lcdPrintLine(
        1,
        ssid
    );


    WiFi.disconnect(
        false,
        false
    );


    WiFi.begin(
        ssid,
        WIFI_PASS
    );


    wifiAttemptStarted =
        millis();

    lastWifiAttempt =
        wifiAttemptStarted;

    wifiAttemptInProgress =
        true;

    wifiConnectionHandled =
        false;
}


bool connectNextWifiInOrder() {

    if (
        wifiTryPosition < 0 ||
        wifiTryPosition >= wifiTryCount
    ) {
        return false;
    }


    const int index =
        wifiTryOrder[wifiTryPosition];


    connectWifiIndex(index);

    return true;
}


void startWiFi() {

    WiFi.mode(WIFI_STA);

    // Custom failover dikendalikan program,
    // jadi auto reconnect internal dimatikan agar tidak bentrok.
    WiFi.setAutoReconnect(false);

    // Hindari WiFi sleep karena terminal RFID harus responsif.
    WiFi.setSleep(false);


    String hostname =
        "rfid-" +
        deviceId.substring(6);

    WiFi.setHostname(
        hostname.c_str()
    );


    loadSavedWiFi();

    buildPriorityWifiOrder();


    if (!connectNextWifiInOrder()) {

        lastWifiAttempt =
            millis();
    }
}


void wifiTask() {

    static wl_status_t previousStatus =
        WL_NO_SHIELD;


    const wl_status_t currentStatus =
        WiFi.status();


    if (currentStatus != previousStatus) {

        previousStatus =
            currentStatus;


        if (currentStatus == WL_CONNECTED) {

            Serial.println();
            Serial.println("[WIFI] CONNECTED");
            Serial.print("[WIFI] SSID : ");
            Serial.println(WiFi.SSID());
            Serial.print("[WIFI] IP   : ");
            Serial.println(WiFi.localIP());
            Serial.print("[WIFI] RSSI : ");
            Serial.println(WiFi.RSSI());
        }
        else {

            Serial.print("[WIFI] status=");
            Serial.println((int)currentStatus);
        }
    }


    // ========================================================
    // SUDAH CONNECT
    // ========================================================

    if (currentStatus == WL_CONNECTED) {

        wifiAttemptInProgress =
            false;


        if (!wifiConnectionHandled) {

            wifiConnectionHandled =
                true;


            const String activeSsid =
                WiFi.SSID();


            saveSuccessfulWiFi(
                activeSsid
            );


            const int activeIndex =
                findWifiIndex(activeSsid);


            if (activeIndex >= 0) {
                currentWifiIndex = activeIndex;
            }


            lcdPrintLine(
                0,
                "WIFI CONNECTED"
            );

            lcdPrintLine(
                1,
                activeSsid
            );
        }


        return;
    }


    const unsigned long now =
        millis();


    // ========================================================
    // BARU SAJA PUTUS SETELAH SEBELUMNYA CONNECT
    // ========================================================

    if (wifiConnectionHandled) {

        wifiConnectionHandled =
            false;

        mqttWasConnected =
            false;


        Serial.println(
            "[WIFI] koneksi terputus, mulai failover"
        );


        // Coba SSID terakhir yang sebelumnya sukses satu kali.
        // Jika timeout, tahap berikutnya langsung scan RSSI.
        buildPriorityWifiOrder();


        if (connectNextWifiInOrder()) {
            return;
        }
    }


    // ========================================================
    // MASIH MENUNGGU SATU SSID CONNECT
    // ========================================================

    if (wifiAttemptInProgress) {

        if (
            now - wifiAttemptStarted <
            WIFI_CONNECT_TIMEOUT_MS
        ) {
            return;
        }


        const String failedSsid =
            (
                currentWifiIndex >= 0 &&
                currentWifiIndex < (int)WIFI_COUNT
            )
                ? String(WIFI_SSIDS[currentWifiIndex])
                : String("UNKNOWN");


        Serial.print("[WIFI] TIMEOUT: ");
        Serial.println(failedSsid);


        wifiAttemptInProgress =
            false;


        // Coba SSID berikutnya.
        wifiTryPosition++;


        if (connectNextWifiInOrder()) {
            return;
        }


        // Semua daftar gagal -> scan ulang.
        Serial.println(
            "[WIFI] seluruh daftar gagal, scan ulang"
        );


        if (buildWifiOrderFromScan()) {

            wifiTryPosition = 0;

            connectNextWifiInOrder();

            return;
        }


        lastWifiAttempt =
            now;

        return;
    }


    // ========================================================
    // TIDAK ADA ATTEMPT AKTIF -> PERIODIC RESCAN
    // ========================================================

    if (
        now - lastWifiAttempt <
        WIFI_RESCAN_MS
    ) {
        return;
    }


    lastWifiAttempt =
        now;


    if (buildWifiOrderFromScan()) {

        wifiTryPosition = 0;

        connectNextWifiInOrder();

        return;
    }


    // Jika scan tidak menemukan whitelist,
    // tunggu lalu scan lagi pada siklus berikutnya.
    lcdPrintLine(
        0,
        "WIFI OFFLINE"
    );

    lcdPrintLine(
        1,
        "SCAN ULANG..."
    );
}



// ============================================================
// MQTT
// ============================================================

void mqttTask() {

    if (WiFi.status() != WL_CONNECTED) {

        mqttWasConnected = false;
        return;
    }


    if (mqtt.connected()) {

        mqtt.loop();

        if (!mqttWasConnected) {
            mqttWasConnected = true;
        }

        return;
    }


    mqttWasConnected = false;


    const unsigned long now = millis();


    if (
        now - lastMqttAttempt <
        MQTT_RETRY_MS
    ) {
        return;
    }


    lastMqttAttempt = now;


    const String clientId =
        "RFID-OUTPUT-" +
        deviceId;


    Serial.print("[MQTT] CONNECT ");
    Serial.println(clientId);


    if (mqtt.connect(clientId.c_str())) {

        Serial.println("[MQTT] CONNECTED");


        // Retained state akan dikirim oleh broker.
        subscribeDeviceTopics();

        // Publish boot counter + reset reason + IP.
        publishStartupDebug();


        restoringRetained = true;
        restoreUntil =
            millis() +
            RESTORE_WAIT_MS;


        if (!temporaryScreen) {

            lcdPrintLine(0, "MQTT CONNECTED");
            lcdPrintLine(1, "RESTORE DATA...");
        }

        return;
    }


    Serial.print("[MQTT] FAILED rc=");
    Serial.println(mqtt.state());
}


// ============================================================
// RDM6300 HELPERS
// ============================================================

bool isHexCharacter(char c) {

    return
        (c >= '0' && c <= '9') ||
        (c >= 'A' && c <= 'F') ||
        (c >= 'a' && c <= 'f');
}


uint8_t parseHexByte(
    char high,
    char low
) {

    char temp[3];

    temp[0] = high;
    temp[1] = low;
    temp[2] = '\0';

    return
        (uint8_t)strtoul(
            temp,
            nullptr,
            16
        );
}


// ============================================================
// DECODE RDM6300 -> 10 DIGIT DECIMAL
// ============================================================
//
// RDM6300 frame:
// STX + 10 ASCII HEX DATA + 2 ASCII HEX CHECKSUM + ETX
//
// 5 data bytes.
// Byte 0 biasanya version/customer byte.
// Nomor kartu dikonversi dari 4 byte terakhir ke uint32,
// lalu diformat tepat 10 digit agar sesuai Node-RED:
//
// /^\d{10}$/
// ============================================================

String decodeRDM6300(const char* frame) {

    for (int i = 0; i < 12; i++) {

        if (!isHexCharacter(frame[i])) {

            Serial.println("[RFID] invalid HEX");
            return "";
        }
    }


    uint8_t data[5];


    for (int i = 0; i < 5; i++) {

        data[i] =
            parseHexByte(
                frame[i * 2],
                frame[(i * 2) + 1]
            );
    }


    const uint8_t receivedChecksum =
        parseHexByte(
            frame[10],
            frame[11]
        );


    const uint8_t calculatedChecksum =
        data[0] ^
        data[1] ^
        data[2] ^
        data[3] ^
        data[4];


    if (receivedChecksum != calculatedChecksum) {

        Serial.print("[RFID] checksum error RX=");
        Serial.print(receivedChecksum, HEX);
        Serial.print(" CALC=");
        Serial.println(calculatedChecksum, HEX);

        return "";
    }


    const uint32_t cardNumber =
        ((uint32_t)data[1] << 24) |
        ((uint32_t)data[2] << 16) |
        ((uint32_t)data[3] << 8)  |
        ((uint32_t)data[4]);


    char decimalRFID[11];

    snprintf(
        decimalRFID,
        sizeof(decimalRFID),
        "%010lu",
        (unsigned long)cardNumber
    );


    return String(decimalRFID);
}


// ============================================================
// PUBLISH RFID
// ============================================================

void publishRFID(String tag) {

    tag.trim();


    // Node-RED mewajibkan decimal tepat 10 digit.
    if (tag.length() != 10) {

        Serial.print("[RFID] invalid length: ");
        Serial.println(tag);

        beepError();

        showTemporary(
            "RFID INVALID",
            "FORMAT SALAH"
        );

        return;
    }


    for (uint8_t i = 0; i < tag.length(); i++) {

        if (!isDigit(tag[i])) {

            Serial.print("[RFID] not decimal: ");
            Serial.println(tag);

            beepError();

            showTemporary(
                "RFID INVALID",
                "FORMAT SALAH"
            );

            return;
        }
    }


    const unsigned long now = millis();


    // ========================================================
    // LOCAL RFID DEBOUNCE
    // ========================================================

    if (
        tag == lastRFID &&
        now - lastRFIDTime <
        RFID_DEBOUNCE_MS
    ) {

        Serial.print("[RFID] DEBOUNCE DROP: ");
        Serial.println(tag);

        return;
    }


    lastRFID = tag;
    lastRFIDTime = now;


    // ========================================================
    // SERVER/MQTT REQUIRED
    // ========================================================

    if (!mqtt.connected()) {

        Serial.println("[RFID] MQTT OFFLINE");

        beepError();

        showTemporary(
            "SERVER OFFLINE",
            "SCAN ULANG"
        );

        return;
    }


    const String topic =
        mqttBase +
        "tag";


    const bool published =
        mqtt.publish(
            topic.c_str(),
            tag.c_str(),
            false
        );


    Serial.println();
    Serial.println("================================");
    Serial.println("RFID SCAN");
    Serial.println("================================");
    Serial.print("DEVICE : ");
    Serial.println(deviceId);
    Serial.print("RFID   : ");
    Serial.println(tag);
    Serial.print("TOPIC  : ");
    Serial.println(topic);
    Serial.print("SEND   : ");
    Serial.println(published ? "OK" : "FAILED");
    Serial.println("================================");


    if (!published) {

        beepError();

        showTemporary(
            "KIRIM GAGAL",
            "SCAN ULANG"
        );

        return;
    }


    beepScan();

    showTemporary(
        "MEMPROSES...",
        tag,
        1000
    );
}


// ============================================================
// READ RDM6300
// ============================================================

void rfidTask() {

    while (RFIDSerial.available()) {

        const uint8_t c =
            RFIDSerial.read();


        // STX
        if (c == 0x02) {

            rdmFrameStarted = true;
            rdmIndex = 0;

            memset(
                rdmData,
                0,
                sizeof(rdmData)
            );

            continue;
        }


        if (!rdmFrameStarted)
            continue;


        // ETX
        if (c == 0x03) {

            rdmFrameStarted = false;


            if (rdmIndex != 12) {

                Serial.print(
                    "[RFID] invalid frame length="
                );

                Serial.println(rdmIndex);

                rdmIndex = 0;

                continue;
            }


            rdmData[12] = '\0';


            const String tag =
                decodeRDM6300(rdmData);


            if (tag.length() == 10) {
                publishRFID(tag);
            }


            rdmIndex = 0;

            continue;
        }


        // ASCII HEX payload + checksum
        if (rdmIndex < 12) {

            rdmData[rdmIndex++] =
                (char)c;
        }
        else {

            // Frame terlalu panjang -> reset parser
            rdmFrameStarted = false;
            rdmIndex = 0;
        }
    }
}


// ============================================================
// SETUP
// ============================================================

void setup() {

    Serial.begin(115200);
    delay(100);


    // ---------------- GPIO ----------------

    pinMode(BUZZER_PIN, OUTPUT);
    pinMode(LED_PIN, OUTPUT);

    noTone(BUZZER_PIN);
    digitalWrite(LED_PIN, LOW);


    // ---------------- LCD ----------------

    Wire.begin(
        I2C_SDA_PIN,
        I2C_SCL_PIN
    );

    lcd.init();
    lcd.backlight();
    lcd.clear();


    // ---------------- BOOT COUNTER + RESET DEBUG ----------------

    loadBootCounter();

    printResetDebug();
    showResetReasonOnLCD();


    // ---------------- DEVICE MAC ----------------

    ensureValidDeviceId();

    // mqttBase sudah tersedia setelah MAC valid.
    buildDiagnosticTopics();


    lcdPrintLine(
        0,
        "DEVICE ID"
    );

    lcdPrintLine(
        1,
        deviceId.substring(6)
    );

    delay(350);


    // ---------------- RFID ----------------

    RFIDSerial.begin(
        9600,
        SERIAL_8N1,
        RFID_RX_PIN,
        RFID_TX_PIN
    );

    Serial.println("[RFID] RDM6300 READY");


    // ---------------- MQTT ----------------

    mqtt.setServer(
        MQTT_HOST,
        MQTT_PORT
    );

    mqtt.setCallback(
        mqttCallback
    );

    mqtt.setBufferSize(512);
    mqtt.setKeepAlive(30);
    mqtt.setSocketTimeout(3);


    // ---------------- WIFI ----------------

    startWiFi();
}


// ============================================================
// LOOP
// ============================================================

void loop() {

    // RFID dibaca sesering mungkin.
    rfidTask();

    // Passive buzzer non-blocking.
    buzzerTask();

    // Network.
    wifiTask();
    mqttTask();

    // LCD timer / retained restore.
    lcdTask();


    // LED ON = MQTT connected.
    digitalWrite(
        LED_PIN,
        mqtt.connected()
            ? HIGH
            : LOW
    );


    delay(1);
}