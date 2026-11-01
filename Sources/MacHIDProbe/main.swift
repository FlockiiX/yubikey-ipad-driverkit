// ykusb-mac-probe: a macOS reference for the DriverKit path.
//
// It talks to the YubiKey's OTP interface through IOHID Feature reports, like
// Yubico's own macOS tools, using the same OTPSession as the app. Results from
// the iPad can be compared with it byte for byte.

import Foundation
import IOKit.hid
import YubiKeyOTP

private enum ProbeError: LocalizedError {
    case deviceNotFound
    case ioKit(operation: String, result: IOReturn)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "No Yubico OTP HID device found (VID 0x1050, usage page 0x01, usage 0x06)."
        case .ioKit(let operation, let result):
            return String(format: "%@ failed: 0x%08x", operation, result)
        }
    }
}

/// Selects the OTP interface the same way Yubico's tools do: Generic Desktop /
/// Keyboard. The FIDO interface uses usage page 0xF1D0.
private enum OTPInterface {
    static let vendorID = 0x1050
    static let usagePage = 0x01
    static let usage = 0x06
}

private final class IOHIDTransport: OTPFeatureReportTransport {
    private let device: IOHIDDevice

    init(device: IOHIDDevice) throws {
        self.device = device
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw ProbeError.ioKit(operation: "IOHIDDeviceOpen", result: result) }
    }

    deinit {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func readFeatureReport() throws -> Data {
        var report = [UInt8](repeating: 0, count: OTPFrame.featureReportSize)
        var length = report.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &report, &length)
        guard result == kIOReturnSuccess else { throw ProbeError.ioKit(operation: "IOHIDDeviceGetReport", result: result) }
        return Data(report.prefix(length))
    }

    func writeFeatureReport(_ report: Data) throws {
        let bytes = [UInt8](report)
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, bytes, bytes.count)
        guard result == kIOReturnSuccess else { throw ProbeError.ioKit(operation: "IOHIDDeviceSetReport", result: result) }
    }
}

private func findOTPDevice() throws -> IOHIDDevice {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Any] = [
        kIOHIDVendorIDKey: OTPInterface.vendorID,
        kIOHIDPrimaryUsagePageKey: OTPInterface.usagePage,
        kIOHIDPrimaryUsageKey: OTPInterface.usage,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard result == kIOReturnSuccess else { throw ProbeError.ioKit(operation: "IOHIDManagerOpen", result: result) }
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
        throw ProbeError.deviceNotFound
    }
    return device
}

private func property<T>(_ device: IOHIDDevice, _ key: String) -> T? {
    IOHIDDeviceGetProperty(device, key as CFString) as? T
}

/// Parses `[--challenge|--hex <1|2> <challenge>]`. Returns nil for a status-only run.
private func parseChallenge(_ arguments: [String]) throws -> (slot: OTPSlot, challenge: Data)? {
    guard !arguments.isEmpty else { return nil }
    guard arguments.count == 3, let slot = Int(arguments[1]).flatMap(OTPSlot.init(rawValue:)) else { exitWithUsage() }
    switch arguments[0] {
    case "--challenge": return (slot, Data(arguments[2].utf8))
    case "--hex": return (slot, try Hex.decode(arguments[2]))
    default: exitWithUsage()
    }
}

private func exitWithUsage() -> Never {
    fputs("""
        Usage: ykusb-mac-probe [--challenge <1|2> <text> | --hex <1|2> <hex>]
        Without arguments, the probe only reads the eight-byte OTP status report.

        """, stderr)
    exit(64)
}

do {
    let request = try parseChallenge(Array(CommandLine.arguments.dropFirst()))

    let device = try findOTPDevice()
    let product: String = property(device, kIOHIDProductKey) ?? "unknown"
    let productID: Int = property(device, kIOHIDProductIDKey) ?? 0
    print(String(format: "OTP HID: %@ VID=0x%04x PID=0x%04x", product, OTPInterface.vendorID, productID))

    let session = OTPSession(transport: try IOHIDTransport(device: device))
    session.onLog = { print("[OTP] \($0)") }
    session.onKeepalive = { if $0 == .waitingForTouch { print("Touch your YubiKey...") } }

    let status = try session.readStatus()
    print("Status raw: \(Hex.encode(status.raw))")
    print("Firmware: \(status.firmwareVersion)")
    for slot in OTPSlot.allCases {
        print("Slot \(slot.rawValue) configured: \(status.isConfigured(slot)); touch-triggered: \(status.isTouchTriggered(slot))")
    }

    if let (slot, challenge) = request {
        let started = Date()
        let response = try session.challengeResponse(slot: slot, challenge: challenge)
        print("Challenge UTF-8: \(String(data: challenge, encoding: .utf8) ?? "<not UTF-8>")")
        print("Challenge hex: \(Hex.encode(challenge))")
        print("Slot: \(slot.rawValue)")
        print("Response hex: \(Hex.encode(response))")
        print(String(format: "Duration: %.3f s", Date().timeIntervalSince(started)))
    }
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}
