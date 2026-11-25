# RFID Cutting

RFID Cutting is an ESP32-based manufacturing station firmware for RFID scanning at assembly input and output points. It reads RFID tags over UART, displays status on a 16×2 I2C LCD, provides buzzer feedback, connects to approved Wi-Fi networks, and publishes scan events to an MQTT broker.

The repository currently uses the ESP32 Arduino framework with PlatformIO. The active firmware is `src/assy_multiwifi.cpp`; several `.bak`, `.bal`, and template files contain earlier or alternate implementations.

## Features

- Reads STX/ETX-framed RFID data from a UART reader
- Converts the RFID serial hexadecimal value to a 10-digit decimal tag
- Supports `assy_in` and `assy_out` scan modes
- Uses the ESP32 Wi-Fi station MAC address as a unique device ID
- Attempts a saved Wi-Fi network first, then scans the configured network whitelist
- Orders available Wi-Fi networks by signal strength
- Stores the last successful Wi-Fi SSID in ESP32 NVS
- Communicates with an MQTT broker and subscribes to scan replies
- Synchronizes the operator, line, and output state after reconnection
- Displays status on an I2C LCD and provides buzzer feedback
- Ignores duplicate scans for a configurable debounce period

## Firmware Configuration

### Platform and board

The PlatformIO environment in `platformio.ini` is configured for:

- Board: `esp32doit-devkit-v1`
- Platform: Espressif32
- Framework: Arduino
- Serial monitor: 115200 baud

### Select the station mode

Open `src/assy_multiwifi.cpp` and change:

```cpp
String scanType = "assy_out";
```

Use:

```cpp
String scanType = "assy_in";
```

for an assembly input station, or `assy_out` for an assembly output station.

### Configure Wi-Fi

Update the network list and password near the top of `src/assy_multiwifi.cpp`:

```cpp
const char *WIFI_SSIDS[] = {
    "Tracked",
    "Tracked (2)"
};

const char *WIFI_PASS = "your-wifi-password";
```

The firmware scans only networks listed in `WIFI_SSIDS` and uses the same password for every listed network. The last successful SSID is remembered in NVS.

> **Security:** The active source currently contains a Wi-Fi password and MQTT broker address. Replace or rotate these credentials before deployment and avoid committing production passwords to public repositories.

### Configure MQTT

Set the broker address and port in `src/assy_multiwifi.cpp`:

```cpp
const char *mqttServer = "10.5.2.223";
const uint16_t mqttPort = 1883;
```

MQTT topics are generated automatically using the station mode and ESP32 MAC address:

```text
rfid/assy/<in-or-out>/<MAC_ADDRESS>/tag
rfid/assy/<in-or-out>/<MAC_ADDRESS>/status
rfid/assy/<in-or-out>/reply/<MAC_ADDRESS>
```

The ESP32 MAC address is used as the device ID, for example `AABBCCDDEEFF`.

## Hardware Connections

The active firmware uses these ESP32 pins:

| Device | ESP32 pin | Firmware constant |
|---|---:|---|
| RFID UART RX | GPIO 16 | `RFID_RX_PIN` |
| RFID UART TX | GPIO 17 | `RFID_TX_PIN` |
| LCD SDA | Board I2C SDA | Usually GPIO 21 |
| LCD SCL | Board I2C SCL | Usually GPIO 22 |
| Buzzer | GPIO 25 | `BUZZER_PIN` |
| Optional button | GPIO 15 | `BUTTON_PIN` |

The RFID reader is configured for `9600` baud, 8 data bits, no parity, and 1 stop bit:

```text
RFID TX -> ESP32 GPIO 16 (RFID_RX_PIN)
ESP32 GPIO 17 (RFID_TX_PIN) -> RFID RX, if reader duplex communication is used
RFID GND -> ESP32 GND
RFID VCC -> regulated power supply matching the reader specification
```

The LCD is configured for I2C address `0x27`:

```cpp
LiquidCrystal_I2C lcd(0x27, 16, 2);
```

If the LCD uses another address or the button/buzzer polarity differs, update the constants before uploading.

## Build and Upload

### Option 1: VS Code with PlatformIO

1. Install [Visual Studio Code](https://code.visualstudio.com/).
2. Install the **PlatformIO IDE** extension.
3. Connect the ESP32 DEVKIT V1 with a USB data cable.
4. Clone the repository:

```bash
git clone https://github.com/cracktiest/RFID_Cutting.git
cd RFID_Cutting
code .
```

5. Open the repository in VS Code and allow PlatformIO to initialize it.
6. Confirm `board = esp32doit-devkit-v1` in `platformio.ini`.
7. Edit the Wi-Fi, MQTT, station mode, and pin settings if required.
8. Use **PlatformIO: Build** or run:

```bash
pio run
```

9. Select the correct serial port for the ESP32.
10. Use **PlatformIO: Upload** or run:

```bash
pio run --target upload
```

11. Open the serial monitor:

```bash
pio device monitor
```

The monitor will show Wi-Fi, MQTT, device MAC, topic, and RFID debug messages.

### Option 2: Command line only

Install PlatformIO Core, then from the repository root:

```bash
python -m pip install --upgrade platformio
pio run
pio run --target upload
pio device monitor --baud 115200
```

### Upload port troubleshooting

If upload cannot detect the board:

- Confirm that the cable supports data, not only charging
- Install or select the ESP32 USB-UART driver
- Put the board into bootloader mode if necessary:
  1. Hold **BOOT**
  2. Press and release **EN/RST**
  3. Release **BOOT**
- Select the correct COM port in VS Code or pass it explicitly:

```bash
pio run --target upload --upload-port COM3
```

Use the matching Linux/macOS device path instead of `COM3`, such as `/dev/ttyUSB0`.

## Libraries

Dependencies are declared in `platformio.ini`:

- PubSubClient
- LiquidCrystal_I2C
- ArduinoJson

PlatformIO downloads them automatically during the first build.

## Project Structure

```text
RFID_Cutting/
├── src/
│   ├── assy_multiwifi.cpp       # Active firmware implementation
│   └── *.bak / *.bal            # Earlier or alternate source versions
├── include/                     # Optional project headers
├── lib/                         # Optional project libraries
├── test/                        # Test directory
├── platformio.ini               # PlatformIO environment and dependencies
└── .gitignore
```

## Operation

1. Power on the ESP32 and connected reader.
2. The LCD displays `SYSTEM BOOT` and the selected `ASSY IN` or `ASSY OUT` mode.
3. The firmware attempts configured Wi-Fi networks and saves the last successful SSID.
4. After Wi-Fi connects, the firmware connects to MQTT and restores the previous session.
5. Present an RFID card/tag to the reader.
6. The firmware publishes the tag and waits for a reply from the backend.
7. The reply controls the LCD text, optional buzzer code, and ready-screen output state.

## Repository

<https://github.com/cracktiest/RFID_Cutting>
