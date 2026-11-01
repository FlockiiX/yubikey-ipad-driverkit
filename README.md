# YubiKey challenge-response over USB-C on iPad

A proof of concept for YubiKey HMAC-SHA1 challenge-response on M-series iPads,
using a USBDriverKit extension and a SwiftUI test app.

Tested on 2026-10-27 with a YubiKey 5C NFC (firmware 5.7.4): the Slot 2 response
matched `ykman otp calculate` on macOS byte for byte. See the
[test results](docs/test-results.md) for the hardware setup and logs.

## Why a driver?

KeePass-compatible apps such as KeePassium, Strongbox, and KeePassXC use
YubiKey HMAC-SHA1 challenge-response to protect databases. This function uses
the key's OTP HID interface. iPadOS does not expose HID Feature reports
directly to apps, and HIDDriverKit is macOS-only.

This driver claims the USB device and sends the HID requests over endpoint
zero. The OTP protocol runs in the app through the `YubiKeyOTP` Swift library.

## Requirements

- A Mac with Xcode 27 or later, including the DriverKit 27 SDK.
- An M-series iPad with iPadOS 27 or later and Developer Mode enabled.
  The driver's deployment target is DriverKit 27.0.
- A paid Apple Developer Program membership to sign and run the driver.
  A free Personal Team cannot create DriverKit profiles.
- A USB-C YubiKey 5 series key with OTP+FIDO+CCID enabled (`1050:0407`).
  Other product IDs need a matching entry in [Driver/Info.plist](Driver/Info.plist).

## Limitations

- **The driver claims the whole key.** FIDO and smart card (CCID) functions are
  unavailable to other apps and the system while it is attached. Disable the
  driver and reconnect the key to restore them.
- **Distribution requires Apple approval.** Local development uses the
  *DriverKit USB Transport (development)* capability. TestFlight and the App
  Store require the *DriverKit USB Transport – VendorID* entitlement for
  Yubico's vendor ID `0x1050`.
- Hardware testing covers one key, one iPad, and Slot 2. Slot 1, other models,
  repeated reconnects, and App Review are untested. iPhones are unsupported.

The app does not program slots or read the HMAC secret. The driver exposes
raw Feature reports; a modified client could send slot configuration commands.

## Getting started

### 1. Build and test without hardware

```sh
scripts/verify.sh
```

This runs the protocol and app connection tests, builds the macOS probe, and
builds the driver and apps for macOS and iPadOS without code signing.

### 2. Configure signing

Create `Config/Signing.local.xcconfig` (Git ignores it):

```text
DEVELOPMENT_TEAM = ABCDE12345
APP_BUNDLE_IDENTIFIER = com.yourname.yubikey-usb-poc
```

The driver's bundle identifier is the app's identifier followed by `.driver`;
its filename is that identifier followed by `.dext`.

Use the **Debug** configuration. Xcode's automatic signing creates:

- an iOS App Development profile with **Communicates with Drivers** and
  **System Extension**;
- a DriverKit App Development profile with **DriverKit (development)** and
  **DriverKit USB Transport (development)**.

If a capability is missing, enable it for the corresponding App ID under
*Certificates, Identifiers & Profiles* on developer.apple.com and build again.
For local development, select the development capability rather than
*DriverKit USB Transport – VendorID*. Release signing requires the VendorID
entitlement. See [signing details](docs/architecture.md#signing).

### 3. Set up the YubiKey

For compatibility with KeePassium, Strongbox, and KeePassXC, use:

| Setting | Value |
|---|---|
| Slot | **2**; Slot 1 usually holds the factory Yubico OTP credential |
| Type | Challenge-response, HMAC-SHA1, variable input length |
| Secret | 20 random bytes; keep an offline backup |
| Require touch | On |

Install [YubiKey Manager](https://www.yubico.com/support/download/yubikey-manager/)
and check the slot before programming it:

```sh
brew install ykman
ykman otp info
```

**If Slot 2 already protects a database, do not overwrite it.** Programming the
slot replaces its secret permanently. For an unused slot, generate a secret
and require touch:

```sh
ykman otp chalresp --touch --generate 2
```

Save the printed 40-character hex secret offline. It cannot be read back from
the key. To configure a backup key with that secret, use
`ykman otp chalresp --touch 2 <secret>`.

### 4. Run on the iPad

1. Connect the iPad to the Mac, select it as the run destination of the
   `YubiKeyUSBPoC` scheme, then build and run.
2. On the iPad, open **Settings > Privacy & Security > Drivers** and enable
   **YubiKeyUSBPoC**.
3. Connect the YubiKey directly to the iPad, or reconnect it if already attached.
4. Tap **Refresh**. The OTP interface should show a number.
5. Tap **Read OTP Status**, then **Run Challenge — Slot 2**, and touch the key
   when asked.

### 5. Compare with the Mac

Generate a 32-byte challenge and calculate its response on the Mac:

```sh
CH=$(openssl rand -hex 32)
echo "$CH"
ykman otp calculate 2 "$CH"
```

In the app, set **Challenge format** to **Hex**, paste the same challenge, and
run Slot 2. Touch the key for each calculation. Both responses must match
byte for byte.

For setup and connection errors, see [Troubleshooting](docs/troubleshooting.md).

## macOS

The command-line probe uses IOHID directly with the same OTP library:

```sh
swift run ykusb-mac-probe                                     # status only
swift run ykusb-mac-probe --challenge 2 'YubiKey USBDriverKit PoC'
swift run ykusb-mac-probe --hex 2 "$CH"                        # challenge from above
```

To use the SwiftUI app, build it with signing configured, copy
`YubiKeyUSBPoC.app` to `/Applications`, and launch that copy. Click
**Enable / Manage Driver**, approve the extension in System Settings,
reconnect the key, then click **Refresh**. To activate it from Xcode's build
directory, see [Apple's system extensions testing guide](https://developer.apple.com/documentation/driverkit/debugging-and-testing-system-extensions).

The macOS driver activation path is untested. Unsigned builds check
compilation and packaging only.

## Reusing the code

- [YubiKeyOTP](Sources/YubiKeyOTP) is a library target with no external
  dependencies in the Swift package at the repository root. Add the package,
  implement `OTPFeatureReportTransport`, and call
  `OTPSession.challengeResponse(slot:challenge:)`.
- [Driver](Driver) and [DriverAPI.h](Shared/DriverAPI.h) provide the extension.
  [DriverConnection](App/DriverConnection.c) and [DriverClient](App/DriverClient.swift)
  connect the app to it.

A password manager using the driver needs the distribution entitlement above
and should explain that the driver blocks the key's other interfaces.

## Documentation

- [Architecture](docs/architecture.md): USB transport, OTP framing, signing, and references.
- [Test results](docs/test-results.md): hardware logs, automated checks, and a template for reporting other devices.
- [Troubleshooting](docs/troubleshooting.md): signing, driver activation, USB errors, and touch timeouts.

## License

[MIT](LICENSE), with the Yubico BSD 2-Clause notice in
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES). The OTP implementation follows
`yubikit` in [Yubico's yubikey-manager](https://github.com/Yubico/yubikey-manager).
Both license files are included in the app bundle; keep them with redistributed
source or binaries, including standalone builds of the macOS probe.

This project is not affiliated with or endorsed by Yubico or Apple.
YubiKey is a trademark of Yubico AB.
