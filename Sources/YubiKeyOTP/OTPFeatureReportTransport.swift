import Foundation

/// The only primitive the legacy YubiKey OTP protocol needs from a transport.
///
/// Conforming types exist for USBDriverKit (the app's `DriverClient`) and for
/// macOS IOHID (`ykusb-mac-probe`).
public protocol OTPFeatureReportTransport: AnyObject {
    /// Returns exactly one eight-byte HID Feature report (report ID 0).
    func readFeatureReport() throws -> Data

    /// Writes exactly one eight-byte HID Feature report (report ID 0).
    func writeFeatureReport(_ report: Data) throws
}
