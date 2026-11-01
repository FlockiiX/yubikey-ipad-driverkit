# Architecture

## Layers

```text
SwiftUI app (iPadOS / macOS)
  AppModel            runs one operation at a time on a serial I/O queue
  OTPSession          OTP transfers: frame chunks, polling, touch, CRC
  DriverClient        OTPFeatureReportTransport over the IOKit user client
  DriverConnection.c  IOServiceOpen and IOConnectCallStructMethod
      │
      │  3 selectors with fixed structure sizes (Shared/DriverAPI.h)
      ▼
YubiKeyUSBDriverUserClient
  GetDeviceInfo       output: YKUSBDeviceInfo
  GetFeatureReport    output: 8 bytes
  SetFeatureReport    input:  8 bytes
      ▼
YubiKeyUSBDriver : IOService
  provider: IOUSBHostDevice, matched by vendor and product ID
  IOUSBHostDevice::DeviceRequest on endpoint zero
      ▼
YubiKey OTP HID interface
```

The protocol policy lives in the app. The driver handles USB enumeration,
opening the device, configuration activation, OTP interface selection, and
the two Feature report transfers. It builds every USB setup packet itself, but
passes Feature report payloads through unchanged. Configuration commands use
the same OTP transport and are not blocked by the driver. The supplied app and
OTP library implement only status reads and HMAC-SHA1 challenge-response.

`Sources/YubiKeyOTP` depends only on Foundation and on the
`OTPFeatureReportTransport` protocol. The app's `DriverClient`, the macOS
probe's IOHID transport, and the tests' mock transport all implement it.

## Device-level matching

The personality in `Driver/Info.plist`:

```text
IOProviderClass = IOUSBHostDevice
idVendor        = 4176 (0x1050)
idProduct       = 1031 (0x0407)
```

An interface-level driver (`IOUSBHostInterface`) would load next to the system's
HID driver and lose access to the HID interface that driver already owns.
Matching the whole device avoids that. In exchange, the YubiKey's FIDO and CCID
interfaces are unavailable to others while the driver is attached. The driver
makes no persistent change to the key during startup.

## Startup

`YubiKeyUSBDriver::Start`:

1. opens the `IOUSBHostDevice`;
2. reads the device descriptor and refuses anything but Yubico's vendor ID;
3. parses configuration descriptor 0 and records each HID interface
   (alternate setting 0) with its report descriptor length;
4. reads the active configuration with `GET_CONFIGURATION` and, if it differs,
   selects it with `SetConfiguration(value, matchInterfaces: false)` and
   verifies it;
5. reads each HID interface's report descriptor with `GET_DESCRIPTOR(Report)`;
6. selects the interface whose top-level collection is Generic Desktop (`0x01`)
   / Keyboard (`0x06`), the OTP interface. FIDO (`0xF1D0` / `0x01`) is never
   selected;
7. registers the service.

Failures in steps 1 and 3–6 are recorded rather than fatal, so the app can
connect and read the driver's log. Feature transfers stay disabled until the
configuration is active and an OTP interface was found.

## App connection status

The app checks the connection every two seconds while its view is visible and
no operation is running. Existing connections are checked with `GetDeviceInfo`;
when none exists, the app searches for the driver service again. Background
checks preserve OTP results and do not repeat unchanged status messages.

An empty `IOServiceGetMatchingService` lookup means there is no active device
service, not that the driver is uninstalled or disabled. The app displays
“Waiting for device connection” / “Not detected” and logs an informational
connection hint. If the key is already attached, the hint directs the user to
enable the driver and reconnect. Opening an existing service, ABI checks, and
other I/O failures remain errors. Losing the device clears its metadata.

`sh scripts/test-app-status.sh` tests these transitions using the real app model
and Swift driver client with a fake C transport boundary.

## USB requests

| Operation | bmRequestType | bRequest | wValue | wIndex | wLength |
|---|---:|---:|---:|---:|---:|
| GET_CONFIGURATION | `0x80` | `0x08` | `0` | `0` | 1 |
| GET_DESCRIPTOR (HID report) | `0x81` | `0x06` | `0x2200` | HID interface | descriptor length |
| GET_REPORT (Feature, ID 0) | `0xA1` | `0x01` | `0x0300` | OTP interface | 8 |
| SET_REPORT (Feature, ID 0) | `0x21` | `0x09` | `0x0300` | OTP interface | 8 |

These are the raw USB equivalents of `IOHIDDeviceGetReport` and
`IOHIDDeviceSetReport` with a Feature report and report ID 0, which Yubico's
macOS code uses. Every request has a two-second timeout and is logged with all
setup fields, the `IOReturn`, and the transfer count. Feature report payloads
are excluded from driver logs. The test app and macOS probe still display
protocol traces, including challenges and responses, for comparison.

## OTP protocol

`OTPFrame` and `OTPSession` follow `yubikit.core.otp`:

- A command is a 64-byte payload, the command byte, the payload's CRC-16
  (little-endian), and three zero bytes: a 70-byte frame.
- The frame is sent as ten seven-byte chunks in eight-byte Feature reports. The
  last byte of each report is `0x80 | sequence`. All-zero chunks other than the
  first and last are skipped.
- Before each chunk, the host polls until the device clears the write flag
  (`0x80`).
- The response arrives in chunks flagged `0x40 | sequence`. A report repeating
  the previous chunk is tolerated; any other sequence is an error. A sequence
  of 0 after later chunks ends the response; a repeated first chunk is tolerated.
- Flag `0x20` means the device waits for a touch.
- The dummy report `00 00 00 00 00 00 00 FF` finishes or aborts a transfer.
- Failed frame writes and response reads attempt to abort the transfer while
  preserving the original error, even if the abort itself fails.
- The CRC over the 20-byte response and its two CRC bytes must equal `0xF0B8`.

The HMAC-SHA1 commands are `0x30` (Slot 1) and `0x38` (Slot 2). A challenge
shorter than 64 bytes is padded with `0x00`, or with `0x01` if its last byte is
`0x00`, so its effective length does not change.

## Platform lifecycle

On macOS, the driver is embedded under `Contents/Library/SystemExtensions`, and
the app activates it with `OSSystemExtensionRequest`. On iPadOS it is embedded
under `SystemExtensions`; the system discovers it, and the user enables it in
**Settings > Privacy & Security > Drivers**. iPadOS has no activation API.

## DriverKit pitfalls

These cost the most time and are worth knowing for any USBDriverKit HID work:

- **The configuration may not be active.** After device-level matching, the
  YubiKey was still unconfigured (configuration 0). Descriptors were readable,
  but Feature reports failed: the write flag never cleared and later requests
  returned `kIOReturnNotReady`. Selecting the configuration with
  `SetConfiguration(value, false)` fixed it. Passing `false` keeps the system's
  HID, FIDO, and CCID drivers from attaching to the child interfaces.
- **Avoid `getMetaClass()` in a DEXT.** It can return `nullptr`; dereferencing
  it to log the provider's class name crashed `Start`. Use `OSDynamicCast`.
- **Development needs no Apple approval.** A paid team's *DriverKit USB
  Transport (development)* capability puts `idVendor = "*"` into the
  development profile. The entitlements file must match it with the **string**
  `"*"`; a numeric vendor ID does not match. The VendorID entitlement is only
  needed for distribution.
- **iPadOS keeps a loaded driver** until the device is reconnected. The driver
  logs its build time first, and the app checks an ABI version, so a stale
  driver is easy to recognize.

## Trust boundary

All three user-client methods check exact input and output sizes through
`IOUserClientMethodDispatch`. `YKUSBDeviceInfo` carries an ABI version and a
bounded 2 KiB log. The macOS app's `userclient-access` entitlement names only
its own driver, and the driver requests neither `allow-any-userclient-access`
nor `allow-third-party-userclients`.
