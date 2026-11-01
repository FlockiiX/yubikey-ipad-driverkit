# Test results

## Hardware test: 2026-10-27

**Result: pass.** Slot 2 HMAC-SHA1 challenge-response over USBDriverKit on an
M-series iPad.

| Item | Value |
|---|---|
| YubiKey | YubiKey 5C NFC, firmware 5.7.4, VID/PID `1050:0407`, product `YubiKey OTP+FIDO+CCID` |
| iPad | M-series iPad, DriverKit 27 |
| Slot | Slot 2, HMAC-SHA1, touch required |
| Reference | `ykman otp calculate` on macOS |

| Check | Result |
|---|---|
| Driver attaches, app opens the user client | Pass |
| USB descriptors read, OTP interface 0 selected by usage `01/06` | Pass |
| USB configuration activated: active 0 → selected 1 → verified 1 | Pass |
| Eight-byte Feature `GET_REPORT` / `SET_REPORT` | Pass |
| Touch wait, then 20-byte response with CRC residual `0xf0b8` | Pass |
| Same 32-byte hex challenge gives the same response as `ykman` | Pass, byte-for-byte match |

Log excerpt from the successful run, with the app's default text challenge:

```text
GET_CONFIGURATION result=0x00000000 active=0 expected=1
SET_CONFIGURATION value=1 matchInterfaces=false result=0x00000000
GET_CONFIGURATION after selection result=0x00000000 active=1
...
waiting for touch
response chunk received: seq=0 … seq=3
CRC result: valid (0xf0b8); final response=f9d7067d3c36b4c99197a4a98060bda98680ecd9
```

Challenge `YubiKey USBDriverKit PoC` (UTF-8) on Slot 2 returned
`f9d7067d3c36b4c99197a4a98060bda98680ecd9` in 1.765 seconds, including the
touch. This vector depends on the key's secret and only shows that the exchange
completed.

### The failure before the fix

The first hardware run reached the YubiKey but never got a response:

- The driver opened the device, read all descriptors, and selected OTP
  interface 0.
- The Slot 2 frame chunks were sent. The following Feature reports
  (`0005070403070689`) kept the write flag (`0x80`) set and never showed a
  response (`0x40`) or touch (`0x20`) flag.
- The first attempt ended with `kIOReturnNotReady`; later attempts on the same
  connection failed as well.

The cause was an inactive USB configuration. The driver now reads the active
configuration, selects it if needed, and verifies it before it allows Feature
transfers. The next run, above, showed configuration 0 before selection and
completed the exchange. Selecting a configuration is USB session state, not a
change to the YubiKey's slots.

## Automated checks

`scripts/verify.sh` runs everything that needs no hardware:

| Check | Expected |
|---|---|
| `swift test` | 26 tests pass |
| `swift build` | `YubiKeyOTP` and `ykusb-mac-probe` build |
| `sh scripts/test-app-status.sh` | connection and in-operation disconnect checks pass |
| Driver extension, DriverKit SDK, unsigned | builds |
| App with embedded driver, macOS and iPadOS, unsigned | builds |

The unit tests cover:

- CRC-16 reference vector and the `0xf0b8` response residual;
- frame layout, skipping of all-zero chunks, and sequence flags;
- a fixed, independently calculated vector for all reports of a 32-byte
  challenge, including payload, CRC bytes, and skipped zero chunks;
- Yubico's challenge padding rule;
- response assembly and CRC check for Slot 1 (`0x30`) and Slot 2 (`0x38`);
- rejection of an unconfigured slot and of an oversized challenge before any
  write;
- touch keepalive followed by success, and touch timeout with the dummy report;
- tolerance of repeated first and later chunks, and rejection of an unexpected
  sequence;
- dummy-report cleanup after incomplete transfers and transport errors,
  preserving the original transport error even when cleanup fails;
- invalid report length and corrupted response CRC;
- status parsing with bytes from a real YubiKey 5C NFC;
- hex decoding.

The mocks do not exercise USB enumeration or configuration; the hardware test
above covers those.

The app connection checks also cover unplugging during status reads and
challenge-response, reconnecting, and cancelling the connection monitor.
Waits for operations and monitor cancellation have deadlines.

## Reporting results on other hardware

Results from other YubiKey models and iPads are welcome. Please open an issue
with:

```text
iPad model / chip:
iPadOS version:
YubiKey model, firmware, VID/PID:
Enabled USB interfaces:
Slot (1/2), touch required:
Driver attaches (yes/no, IOReturn):
OTP interface number:
Challenge (hex):
App response (hex):
ykman response (hex):
Byte-for-byte match:
Relevant log lines:
```
