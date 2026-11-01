# YubiKey challenge-response over USB-C on iPad

A proof of concept that lets an iPad app run **YubiKey HMAC-SHA1
challenge-response over USB-C**. It uses a **USBDriverKit** driver extension
instead of HIDDriverKit, which Apple documents as macOS-only.

> **Status: working proof of concept.** On 2026-10-27, a YubiKey 5C NFC
> (firmware 5.7.4) returned a valid Slot 2 HMAC-SHA1 response on an M-series
> iPad. The response matched `ykman otp calculate` on a Mac byte for byte.
> One key and one iPad were tested. This is not production code.

## Why this exists

KeePass-compatible password managers such as KeePassium, Strongbox, KeePassXC,
KeePassDX, and Keepass2Android can protect a database with YubiKey
**HMAC-SHA1 challenge-response**. The YubiKey provides it through its **OTP HID
interface**, using eight-byte HID Feature reports.

On a Mac, apps reach that interface through IOHID. On an iPad, a third-party
app has no public API for HID Feature reports, HIDDriverKit is documented for
macOS only, and there is no NFC reader. As a result, iPad users could not use
their USB-C YubiKey for challenge-response.

This project fills that gap. A USBDriverKit driver, which M-series iPads
support, claims the YubiKey as a USB device and sends the HID class requests
(`GET_REPORT` / `SET_REPORT`) on endpoint zero itself. The OTP protocol on top
is a small, transport-independent Swift library.

## How it works

```text
iPad app (SwiftUI)
  │  YubiKeyOTP: OTP framing, CRC, touch handling          Sources/YubiKeyOTP
  │  DriverClient: IOKit user-client connection            App/
  ▼
YubiKeyUSBDriverUserClient: 3 fixed-size methods           Driver/
  ▼
YubiKeyUSBDriver (USBDriverKit, matches IOUSBHostDevice 1050:0407)
  │  activates the USB configuration, finds the OTP interface,
  │  sends HID class requests on endpoint zero
  ▼
YubiKey OTP HID interface: 8-byte Feature reports
  ▼
HMAC-SHA1(slot secret, challenge) → 20-byte response
```

The driver knows nothing about OTP. It exposes exactly three operations: read
device information, `GET_REPORT`, and `SET_REPORT`, each with a fixed size.
All protocol logic runs in the app. See [Architecture](docs/architecture.md)
for details and the DriverKit pitfalls found along the way.

## What was verified

| Check | Result |
|---|---|
| Driver attaches on iPad and reads USB descriptors | ✅ |
| Eight-byte Feature `GET_REPORT` / `SET_REPORT` on the OTP interface | ✅ |
| Slot 2 (touch required) returns a 20-byte HMAC-SHA1 response with a valid CRC | ✅ |
| Same challenge gives the same response as `ykman otp calculate` on macOS | ✅ |

Logs and details are in [Test results](docs/test-results.md).

## Limitations

- **The driver claims the whole YubiKey.** It matches the USB device, not a
  single interface. While it is attached, the key's FIDO and smart card (CCID)
  functions are unavailable to other apps and to the system. Reconnecting the
  key after disabling the driver restores them.
- **Distribution needs an Apple entitlement.** Development builds use the
  *DriverKit USB Transport (development)* capability, which allows any vendor
  ID. TestFlight and the App Store need the *DriverKit USB Transport – VendorID*
  entitlement for Yubico's vendor ID `0x1050`, granted by Apple on request.
  Apple's guidance is that this entitlement is not needed for local testing.
- **One product ID.** The driver matches `1050:0407` (YubiKey 5 series,
  OTP+FIDO+CCID). Other product IDs need an extra entry in
  `Driver/Info.plist`.
- **M-series iPads only.** Apple supports USBDriverKit on iPads with an M-series
  chip. iPhones are not supported.
- Only one key and one iPad were tested. Slot 1, other YubiKey models, repeated
  reconnects, and App Review are untested.

## Safety

The supplied app and OTP library implement no slot programming, erasing, mode
switching, or secret generation, and never see the HMAC secret. The driver
exposes a raw eight-byte Feature report transport; it does not restrict OTP
commands. A modified client could use it to send configuration commands.

The supplied app and driver perform these writes:

- the eight-byte chunks of an HMAC challenge (command `0x30` for Slot 1, `0x38`
  for Slot 2);
- Yubico's dummy report `00 00 00 00 00 00 00 FF`, which ends or aborts the
  current transfer;
- the standard USB `SET_CONFIGURATION` request, sent only if the device's
  configuration is not active yet. It affects the current USB session, not the
  key's slots, secrets, or enabled interfaces.

Program the challenge-response slot yourself, as described in
[Set up the YubiKey](#3-set-up-the-yubikey).

## Repository layout

```text
App/                  SwiftUI test app for iPadOS and macOS, IOKit bridge
Driver/               USBDriverKit driver extension and its user client
Shared/DriverAPI.h    C ABI shared by the driver and the app
Sources/YubiKeyOTP/   OTP HID protocol: framing, CRC, transfers (Swift package)
Sources/MacHIDProbe/  ykusb-mac-probe: the same protocol over macOS IOHID
Tests/                Unit tests for the protocol, using a mock transport
Config/               Code-signing settings
docs/                 Architecture and test results
scripts/verify.sh     Builds and tests everything that needs no hardware
```

## Requirements

- A Mac with Xcode 27 or later (DriverKit 27 SDK)
- For the iPad test:
  - a paid Apple Developer Program membership (a free Personal Team cannot
    create DriverKit profiles)
  - an M-series iPad with iPadOS 27 or later and Developer Mode enabled. The
    driver's deployment target is DriverKit 27.0; earlier versions are untested.
  - a YubiKey 5 series key with USB-C and the OTP interface enabled

## Getting started

### 1. Build and test without hardware

```sh
scripts/verify.sh
```

The script runs the protocol tests and the macOS probe build, then builds the
driver and the app for macOS and iPadOS without code signing.

### 2. Configure signing

Create `Config/Signing.local.xcconfig` (Git ignores it):

```text
DEVELOPMENT_TEAM = ABCDE12345
APP_BUNDLE_IDENTIFIER = com.yourname.yubikey-usb-poc
```

The driver's bundle identifier is always the app's identifier followed by
`.driver`.

Xcode's automatic signing then creates two profiles:

- an iOS App Development profile for the app with **Communicates with Drivers**
  and **System Extension**;
- a DriverKit App Development profile for the driver with **DriverKit
  (development)** and **DriverKit USB Transport (development)**.

If Xcode reports a missing DriverKit or `transport.usb` entitlement, enable
these capabilities on the two App IDs under *Certificates, Identifiers &
Profiles* on developer.apple.com and build again. Do not select *DriverKit USB
Transport – VendorID*; that is the distribution entitlement.

| Target | Configuration | Entitlements |
|---|---|---|
| Driver | Debug | `Driver/YubiKeyUSBDriver-Development.entitlements`: `driverkit`, `transport.usb` with `idVendor = "*"` |
| Driver | Release | `Driver/YubiKeyUSBDriver.entitlements`: `driverkit`, `transport.usb` with `idVendor = 4176` (`0x1050`) |
| App | iPadOS | `communicates-with-drivers`, `system-extension.install` |
| App | macOS | `system-extension.install`, `userclient-access` for its own driver |

The development entitlement allows any vendor, but the driver still matches
only Yubico devices: the IOKit personality in `Driver/Info.plist` decides what
it matches. Release builds fail to sign until Apple grants the VendorID
entitlement, which is expected.

### 3. Set up the YubiKey

Use the configuration that KeePassium, Strongbox, and KeePassXC expect, so the
same key works with them later:

| Setting | Value |
|---|---|
| Slot | **2** (Slot 1 usually holds the factory Yubico OTP credential) |
| Type | **Challenge-response, HMAC-SHA1**, variable input length |
| Secret | **20 random bytes**; store a backup offline, it cannot be read back |
| Require touch | **On** (recommended) |
| USB interfaces | **OTP enabled** |

With [YubiKey Manager](https://www.yubico.com/support/download/yubikey-manager/) (`brew install ykman`):

```sh
ykman otp info                        # check first: is Slot 2 already programmed?
ykman otp chalresp --touch --generate 2
```

> **Caution:** if Slot 2 is already programmed, it may protect an existing
> database. Programming it again replaces that secret permanently.

`--generate` prints the secret as 40 hex characters. Save it: it is the only
way to program a backup key with the same secret
(`ykman otp chalresp --touch 2 <secret>`).

### 4. Run on the iPad

1. Connect the iPad to the Mac, select it as the run destination of the
   `YubiKeyUSBPoC` scheme, then build and run.
2. On the iPad, open **Settings > Privacy & Security > Drivers** and enable
   **YubiKeyUSBPoC**.
3. Connect the YubiKey directly to the iPad (no hub), or reconnect it if it was
   already connected.
4. In the app, tap **Refresh**. The OTP interface should show a number.
5. Tap **Read OTP Status**, then **Run Challenge — Slot 2**, and touch the key
   when asked.

### 5. Compare with the Mac

Use a 32-byte challenge, the size of the KDBX master seed that KeePass apps
send:

```sh
CH=$(openssl rand -hex 32); echo "$CH"
ykman otp calculate 2 "$CH"           # touch the key; prints 40 hex characters
```

In the app, set **Challenge format** to **Hex**, paste the same challenge, and
run Slot 2. Both responses must match byte for byte.

## macOS

The probe uses macOS IOHID with the same `YubiKeyOTP` library, which makes it a
reference for the DriverKit path:

```sh
swift run ykusb-mac-probe                                     # status only
swift run ykusb-mac-probe --challenge 2 'YubiKey USBDriverKit PoC'
swift run ykusb-mac-probe --hex 2 "$CH"
```

The app also runs on macOS. Click **Enable / Manage Driver**, approve the
extension in System Settings, reconnect the key, then click **Refresh**.

## Troubleshooting

**"Provisioning profile doesn't match the entitlements file".** Build the Debug
configuration. Its entitlements use `idVendor = "*"` as a string, matching the
development profile. Release uses `0x1050` and needs Apple's VendorID
entitlement.

**The driver does not appear under Drivers.** Check that the app contains
`SystemExtensions/YubiKeyUSBPoC.dext`, that both targets use the same team, and
that the driver's bundle identifier is the app's plus `.driver`. Inspect what
was signed:

```sh
codesign -d --entitlements - <path>/YubiKeyUSBPoC.app/SystemExtensions/YubiKeyUSBPoC.dext
```

**The driver is enabled but does not attach.** Reconnect the key. Check its
product ID with `swift run ykusb-mac-probe` or `ioreg -p IOUSB -l -w0` on a Mac
and add it to the personality in `Driver/Info.plist` if it differs from
`0x0407`.

**`kIOReturnNotFound` on Refresh.** No driver service is registered: the driver
is not enabled, did not match, or the key is not connected.

**`kIOReturnNotPrivileged` or `kIOReturnNotPermitted`.** The app's signed
entitlements or profile do not allow DriverKit communication.

**`kIOReturnExclusiveAccess`.** Another driver owns the device. Remove old
builds of the driver, re-enable the current one, and reconnect the key.

**The app reports an incompatible driver ABI.** An older driver build is still
loaded. Reconnect the key. The driver log's first line shows the running
driver's build time.

**Feature reports fail with `kIOReturnNotReady`, or the write flag never
clears.** The USB configuration is not active. The driver activates it on
start; look for `SET_CONFIGURATION` in the log.

**Touch timeout.** The app waits 30 seconds for a touch, then aborts the
transfer with the dummy report.

## Using this in a password manager

The pieces are meant to be reused:

- `Sources/YubiKeyOTP` is a Swift package with no dependencies. Implement
  `OTPFeatureReportTransport` and call
  `OTPSession.challengeResponse(slot:challenge:)`.
- `Driver/` and `Shared/DriverAPI.h` form the driver extension, and
  `App/DriverConnection.*` plus `App/DriverClient.swift` connect to it.
- Shipping requires Apple's VendorID entitlement for `0x1050`, and users must
  enable the driver in Settings once.
- Because the driver claims the whole key, the app should tell users that FIDO
  and smart card functions are unavailable while the driver is attached.

## References

- [Apple: Communicating between a DriverKit extension and a client app](https://developer.apple.com/documentation/driverkit/communicating-between-a-driverkit-extension-and-a-client-app)
- [Apple: Requesting entitlements for DriverKit development](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)
- [Apple: USB transport entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.transport.usb)
- [Apple: IOUSBHostDevice.SetConfiguration](https://developer.apple.com/documentation/usbdriverkit/iousbhostdevice/setconfiguration)
- [Yubico: OTP framing (`yubikit/core/otp.py`)](https://github.com/Yubico/yubikey-manager/blob/main/yubikit/core/otp.py)
- [Yubico: challenge-response command (`yubikit/yubiotp.py`)](https://github.com/Yubico/yubikey-manager/blob/main/yubikit/yubiotp.py)

## Acknowledgments

The OTP framing in `Sources/YubiKeyOTP` follows the behavior of `yubikit` in
Yubico's [yubikey-manager](https://github.com/Yubico/yubikey-manager)
(BSD 2-Clause License, Copyright (c) Yubico AB).

## License

[MIT](LICENSE). This project is not affiliated with or endorsed by Yubico or
Apple. YubiKey is a trademark of Yubico AB.
