# RFID Multi-WiFi Firmware Documentation

This repository contains three ESP32 RFID firmware variants in `src/`:

| File | Purpose | Default mode |
|---|---|---|
| `assy_multiwifi.cpp` | RFID terminal for assembling | `assy_out` |
| `prep_multiwifi.cpp.bal` | Batch/preparation RFID terminal, reject handling, and OTA | `out` |
| `output_multiwifi.cpp.bak` | Legacy output-sewing firmware with MQTT state restoration and boot diagnostics | Output sewing |

> **File extension notice:** `prep_multiwifi.cpp.bal` contains Arduino C++ despite the `.bal` extension, while `output_multiwifi.cpp.bak` is a `.bak` backup. Verify and adjust the filename or build configuration before compiling these files.

## Overview

All three firmware variants run on an ESP32, read RFID tags through UART, display status on a 16×2 I2C LCD, and communicate with a backend through MQTT.

They support Wi-Fi failover across:

- `Tracked`
- `Tracked (2)` through `Tracked (9)`

The firmware stores the last successfully connected SSID in ESP32 NVS/Preferences. On the next boot, it tries that SSID first. If it fails, it rescans only the configured whitelist and prioritizes visible networks by signal strength.

Before deployment, review the SSIDs, Wi-Fi password, MQTT host, OTA server, MQTT topics, and payload formats. These values are currently tailored to a private factory network.

## Dependencies

- ESP32 Arduino core
- `PubSubClient`
- `LiquidCrystal_I2C`
- `Preferences`
- ESP32 Wi-Fi/ESP-IDF APIs
- `HTTPClient` and `HTTPUpdate` for OTA on the preparation firmware
- RDM6300-compatible RFID reader
- 16×2 I2C LCD, buzzer, and any optional button hardware

## assy_multiwifi.cpp

This terminal supports two assembling modes.

```cpp
String scanType = "assy_out";
```

Set it to `assy_in` for input mode or `assy_out` for output mode. The value controls:

- MQTT topic path
- MQTT client prefix
- LCD mode label
- RFID payload mode
- Ready-screen input/output label

### Behavior

1. The ESP32 reads its Wi-Fi STA MAC as `deviceId`.
2. It connects to Wi-Fi using saved-SSID and RSSI-based failover logic.
3. It connects to MQTT and subscribes to its reply topic.
4. It requests session restoration with `__RESTORE__`.
5. A tag is converted to a 10-digit decimal value and published.
6. The backend response updates operator, line, bundle count, and output counters.
7. Additional RFID reads are ignored while a backend response is pending.

### MQTT topics

`<mode>` is `in` or `out`, and `<deviceId>` is the MAC address without separators.

- Tag publish: `rfid/assy/<mode>/<deviceId>/tag`
- Status publish: `rfid/assy/<mode>/<deviceId>/status`
- Reply subscribe: `rfid/assy/<mode>/reply/<deviceId>`

The tag payload format is:

```text
tag/deviceId/scanType
```

Backend replies should provide LCD text and optional JSON fields such as `status`, `lcd1`, `lcd2`, `beep`, `operator_name`, `nama`, `line_no`, `line`, `actual_output`, `total_output_qty`, `operator_output`, `count_bundle`, or `bundle_count`.

### Hardware

| Component | ESP32 pin |
|---|---:|
| RFID UART RX | GPIO 16 |
| RFID UART TX | GPIO 17 |
| Buzzer | GPIO 25 |
| Optional button | GPIO 15 |
| LCD I2C address | `0x27` |

## prep_multiwifi.cpp.bal

This firmware is for preparation/batch processes and supports input, output, reject, and OTA workflows.

Configure it in the top section:

```cpp
#define DEVICE_MODE "out"
#define ENABLE_REJECT true
```

Reject handling is only active when `DEVICE_MODE` is `"out"` and `ENABLE_REJECT` is `true`.

### Behavior

- Reads RFID tags in STX/ETX framing and converts them to decimal values.
- Sends normal taps to the MQTT backend.
- Displays operator and production counters on the LCD.
- Prevents duplicate RFID scans during backend processing.
- Provides a 5-second reject window in output mode.
- Sends a final payload containing the rejected quantity.
- Restores the device session after restarting.
- Publishes heartbeat status every five seconds.
- Supports OTA firmware updates from a local HTTP server.

### MQTT topics

Default MQTT base: `rfid/batch/v2`

- Publish: `rfid/batch/v2/<mode>/<deviceId>`
- Reply: `rfid/batch/v2/reply/<deviceId>`
- Status: `rfid/batch/v2/status/<deviceId>`

Normal tap payload:

```text
deviceId/tag/mode
```

Session restore payload:

```text
deviceId/__RESTORE__/mode
```

Output final payload:

```text
deviceId/tag/out/final/rejectQty
```

The reply parser supports:

```text
MODE^BEEP^LCD1^LCD2
OUT_WAIT_REJECT^BEEP^LCD1^LCD2^QTY
```

### Button behavior

- **Short press:** debug/status display and restart behavior.
- **Short press during reject window:** increments reject quantity.
- **Long press:** starts OTA update.

### OTA

OTA is downloaded from:

```text
<OTA_BASE_URL>/<firmware-file>
```

The firmware file name is:

- `rfid_in.bin` for input mode
- `rfid_out.bin` for output mode

Test OTA updates on a non-production device before deployment.

### Hardware

| Component | ESP32 pin |
|---|---:|
| RFID UART RX | GPIO 16 |
| RFID UART TX | GPIO 17 |
| Button | GPIO 15 |
| Buzzer | GPIO 25 |
| LCD I2C address | `0x27` |

## output_multiwifi.cpp.bak

This is the legacy output-sewing firmware. It restores operator, line, and output state from retained MQTT topics after reboot.

### Features

- Wi-Fi STA MAC used as device ID
- Retained MQTT session-state recovery
- Persistent boot counter
- ESP32 reset reason reporting
- Server response handling
- RFID debounce
- Non-blocking passive-buzzer patterns
- LCD temporary and home screens
- MQTT startup diagnostics

### MQTT topics

- Tag publish: `rfid_mac/<MAC>/tag`
- Operator ID: `rfid_mac/<MAC>/operator_id`
- Operator name: `rfid_mac/<MAC>/nama`
- Line: `rfid_mac/<MAC>/line`
- Output: `rfid_mac/<MAC>/output`
- Login: `rfid_mac/<MAC>/login`
- Server response: `rfid_mac/<MAC>/response`
- Status: `rfid_mac/<MAC>/status`
- IP address: `rfid_mac/<MAC>/ip`
- Reset reason: `rfid_mac/<MAC>/debug/reset_reason`
- Startup information: `rfid_mac/<MAC>/debug/info`

The firmware is compatible with an MQTT/Node-RED backend that publishes its state and responses to the topics above.

### Hardware

| Component | ESP32 pin |
|---|---:|
| RFID UART RX | GPIO 16 |
| RFID UART TX | GPIO 17 |
| Buzzer | GPIO 25 |
| LCD SDA | GPIO 21 |
| LCD SCL | GPIO 22 |
| Diagnostic LED | GPIO 2 |
| LCD I2C address | `0x27` |

## Configuration

Update these values to match your environment:

- Wi-Fi SSID list and password
- MQTT broker address and port
- MQTT base/topic paths
- Device mode
- OTA base URL
- LCD I2C address
- RFID and button GPIO pins
- Debug mode

Do not commit real factory passwords or private credentials. Prefer local build configuration or a secrets mechanism not intended for public repositories.

## Security notes

The current firmware examples use:

- Plain MQTT on port `1883`
- Plain HTTP for OTA
- A shared Wi-Fi password embedded in source code

For production use, evaluate MQTT authentication/TLS, OTA server authentication, firmware signing, and secret management.

## Troubleshooting

| Symptom | Check |
|---|---|
| Wi-Fi cannot connect | SSID list, password, access-point availability, and Serial logs |
| MQTT reconnect loop | Broker address/port, network routing, topic conflicts, and client ID |
| RFID is not detected | Reader power, RX/TX wiring, baud rate `9600`, and STX/ETX framing |
| Blank or incorrect LCD output | `0x27` I2C address, SDA/SCL wiring, power, and LCD library |
| Backend response missing | Topic names, payload format, subscriptions, and response timeout |
| OTA fails | OTA URL, firmware filename, HTTP reachability, and board compatibility |
| MAC is rejected | ESP32 Wi-Fi station MAC or invalid MAC value |

## Before production deployment

1. Rename and place each active firmware according to the selected build system.
2. Configure only the intended device mode.
3. Verify all topic names and payload formats with the Node-RED/backend implementation.
4. Test Wi-Fi failover and NVS behavior.
5. Test RFID debounce and backend timeout behavior.
6. Test retained MQTT state restoration.
7. Test OTA from a separate staging device.
8. Replace plaintext credentials and add transport security where required.
