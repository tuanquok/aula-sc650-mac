# AULA SC650 protocol notes

Reverse-engineered from the vendor's Windows app (`Mouse.exe`, `hiddriver.dll`) with static analysis (Ghidra),
then checked against a real mouse. Only what is listed under **Verified** was observed on hardware.

**Verified on a real SC650** (macOS, 2.4G receiver and Bluetooth LE): the mouse acknowledges packets 0x04, 0x05, 0x06 (receiver only),
0x08 and 0x09. An acknowledge means "packet accepted"; the mouse has no read-back command.
Lighting, DPI and button changes were also observed to take effect. Items marked **(?)** are inferred and not confirmed.
Wired USB mode is untested.

## Connection modes

| Mode | VID | PID | Transport |
|---|---|---|---|
| 2.4G receiver | 0x1D57 | 0xFA60 | HID feature reports on the control interface |
| Wired USB | 0x1D57 | 0x205E | HID feature reports (from `Mouse.exe`, untested) |
| Bluetooth LE | 0x045E | 0x008E | Vendor GATT service (see below) |

The mouse is in exactly one mode at a time, so a receiver left plugged in is silent while the mouse is on Bluetooth.

## Receiver / wired: HID feature reports

The receiver exposes four HID interfaces. The control one is usage page 0x01, usage 0x80, with a 64-byte feature report,
5-byte input reports and a 1-byte output report.

- Every packet is a **64-byte feature report**: byte 0 = report ID, byte 1 = logical length.
- Events come back as 5-byte input reports `[03, 8E, kind, b3, b4]`:

| kind | Meaning |
|---|---|
| 0x10 | DPI level changed (b3 = level 1...8) |
| 0x20 | Polling rate changed (b3: 8 = 125, 4 = 250, 2 = 500, 1 = 1000 Hz) |
| 0x40 | Status (b3: 1 = wireless, 2 = charged; b4 = battery %) |
| 0x50 | Acknowledge (b3 = 0 means success; b4 = report ID being acknowledged) |

- The original app retries every 500 ms, up to 10 times, until it sees the acknowledge.

## Bluetooth LE: vendor GATT service

Over BLE macOS exposes one HID composite (keyboard, mouse, consumer, a vendor page 0xFF12) that has **no 64-byte feature report**.
`IOHIDDeviceSetReport` fails with `kIOReturnUnsupported` (0xE00002F0), which is why a plain HID implementation "does not work
over Bluetooth". The Windows app uses GATT instead (`Mouse.exe` functions `0x414390`, `0x405880`, `0x406070`, `0x415D70`):

| Item | Value |
|---|---|
| Service | `FEE0` (the mouse also exposes `180A` device info, `180F` battery and a TI OAD service) |
| Command characteristic | `FEE3`, write with response. Value = the same packet as on the receiver, byte 0 = report ID |
| Event characteristic | `FEE4`, notify. Value = `[8E, kind, b3, b4]`, i.e. the receiver event without the leading `03` |
| Polling rate (0x06) | Never sent over Bluetooth by the original app |
| Macro (0x09) | The whole 131-byte logical packet is written at once (no 3 x 64-byte split) |

Implementation notes (`Sources/AulaKit/BLETransport.swift`):

- CoreBluetooth must run on its own queue. Settings are applied synchronously on the main thread, so with `queue: .main`
  the write-response callback could never run and every write timed out.
- The app needs `NSBluetoothAlwaysUsageDescription`. macOS asks once per code signature; a rebuilt ad-hoc signature asks again.

## Packets (offsets count from byte 0 = report ID)

### 0x04: DPI profile (length 0x38)

| Offset | Meaning |
|---|---|
| 0..2 | `04 38 01` |
| 3 | Angle Snap (?) |
| 4 | Ripple Control (?) |
| 5 | Bitmask of enabled DPI levels (?) |
| 6, 7 | Bitmask of "DPI code >= 0xDD" flags for the 8 levels |
| 8..15 | DPI code, low byte, of the 8 levels |
| 16..23 | DPI code, high byte, of the 8 levels |
| 24 | Current level + 1 |
| 25..48 | 8 RGB colors, 3 bytes per level |
| 49 | `01` |
| 50, 51 | 16-bit big-endian sum of bytes 3..49 |

DPI code to value: `code <= 0xC8 -> code * 50`, otherwise `(code - 100) * 100`, halved when `code > 0xDC` (?).

### 0x05: lighting, power and debounce (length 0x0F)

`[05, 0F, 01, mode << 4, (lightOff & 0xF0) | (9 - speed), (lightOff & 0x0F) << 4 | brightness, R, G, B, sleep, debounce, sum_hi, sum_lo]`.
Checksum = 16-bit sum of bytes 3..10. Modes 0...11: Off, Static, Breathing, Neon, Color Breathing, Fixed Color, Mixed Breathing,
Rainbow Wave, Lightning, Mixed Static, Marquee, Marquee 2. Only Static and Mixed Static use the chosen brightness (others use 8).

### 0x06: polling rate (length 9)

`[06, 09, 01, v, ~v]` with v = 8 (125 Hz), 4 (250), 2 (500), 1 (1000). Receiver and wired only.

### 0x08: button assignment (length 0x3B)

`[08, 3B, 01, 18 entries x 3 bytes]`, then a 16-bit big-endian sum of bytes 3..56 at offsets 57..58.
Entry = `[type, b1, b2]`. The vendor action table (64 entries, internal id to `type, b1, b2`) is at `Mouse.exe` VA `0x41E478`,
for example Ctrl+C = `11 01 06`, Ctrl+V = `11 01 19`. `b1` is a modifier mask (1 = Ctrl, 2 = Shift, 4 = Alt, 8 = Win/Cmd).
A macro button is `[12, 00, first slot]`.

### 0x09: macro (partly decoded)

Logical packet of 131 bytes: `[09, 83, seq, ...]`. Byte 28 = number of event slots; events start at byte 29, at most 98 bytes per packet;
16-bit sum of bytes 3..128 at bytes 129 (high) and 130 (low). A full packet continues with `[seq+1, FE]`.
Event: delay < 128 -> `[delay | (release ? 0x80 : 0), key]`; delay >= 128 -> `[delay % 100 | flag, key, delay / 100, 03]`.
On the receiver the logical packet is sent as 3 feature reports `[09, 40, seq, idx, 60 bytes]`, the last one starting `[09, 0C, ...]`.
Unknown: meaning of header bytes 3..7 (probably repeat mode) and how the vendor app allocates slots (this app numbers them from 0).

### 0x0C

`[0C, 0A, 01, FE, 01, FE]`. Sent by the original app before a full write; not needed by this app.

## Open questions

- Exact meaning of the 0x04 bytes 3, 4 and 5 (Angle Snap, Ripple Control and level mask were inferred from the option order).
- Macro header bytes and slot allocation; macro repeat modes.
- A read-back command (`GetFeature`) so the app could load the mouse's current settings.
- Wired USB mode on macOS.
