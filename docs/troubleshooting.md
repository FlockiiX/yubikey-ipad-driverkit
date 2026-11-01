# Troubleshooting

[Setup instructions](../README.md#getting-started)

**"Provisioning profile doesn't match the entitlements file".** Build the Debug
configuration. Its entitlements use `idVendor = "*"` as a string, matching the
development profile. Release uses `0x1050` and needs Apple's VendorID
entitlement.

**The driver does not appear under Drivers.** Check that the iPadOS app contains
`SystemExtensions/<app-bundle-id>.driver.dext`, that both targets use the same
team, and that the driver's bundle identifier is the app's plus `.driver`.
The DEXT filename must match that identifier. Inspect what was signed, using
your configured app bundle identifier:

```sh
codesign -d --entitlements - <path>/YubiKeyUSBPoC.app/SystemExtensions/com.yourname.yubikey-usb-poc.driver.dext
```

On macOS, the corresponding directory is
`YubiKeyUSBPoC.app/Contents/Library/SystemExtensions`.

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

