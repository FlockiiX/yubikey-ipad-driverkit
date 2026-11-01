import Foundation

enum DriverClientError: Error, LocalizedError {
    case serviceNotFound
    case ioKit(operation: String, result: kern_return_t)
    case incompatibleDriver(abiVersion: UInt32)

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            return "No active YubiKey driver service. Connect the YubiKey. If it is already connected, enable the driver and reconnect it."
        case .ioKit(let operation, let result):
            return "\(operation) failed: \(Self.describe(result))"
        case .incompatibleDriver(let abiVersion):
            return "The loaded driver uses ABI \(abiVersion), the app expects \(kYKUSBDriverABIVersion). Reconnect the YubiKey to load the current driver."
        }
    }

    static func describe(_ result: kern_return_t) -> String {
        String(format: "%@ (0x%08x)", String(cString: YKUSBReturnName(result)), UInt32(bitPattern: result))
    }
}

/// What the driver learned about the YubiKey while starting.
struct DriverDeviceInfo: Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let product: String
    let otpInterfaceNumber: UInt8?
    let deviceOpenResult: kern_return_t
    let driverLog: String
}

/// The app's user-client connection to `YubiKeyUSBDriver`.
///
/// Provides the Feature report transport that `OTPSession` needs. Not
/// thread-safe: use one instance from one serial queue.
final class DriverClient: OTPFeatureReportTransport, @unchecked Sendable {
    private let connection: io_connect_t

    init() throws {
        var connection: io_connect_t = IO_OBJECT_NULL
        var failedStep: UnsafePointer<CChar>?
        let result = YKUSBOpen(&connection, &failedStep)
        guard result == kIOReturnSuccess else {
            let operation = failedStep.map { String(cString: $0) } ?? "YKUSBOpen"
            // Only an empty service lookup is expected while waiting for hardware.
            // NotFound from IOServiceOpen is still a connection error.
            if YKUSBIsNotFound(result) && operation == "IOServiceGetMatchingService(YubiKeyUSBDriver)" {
                throw DriverClientError.serviceNotFound
            }
            throw DriverClientError.ioKit(operation: operation, result: result)
        }
        self.connection = connection
    }

    deinit {
        YKUSBClose(connection)
    }

    func deviceInfo() throws -> DriverDeviceInfo {
        var info = YKUSBDeviceInfo()
        let result = YKUSBGetDeviceInfo(connection, &info)
        guard result == kIOReturnSuccess else { throw DriverClientError.ioKit(operation: "GetDeviceInfo", result: result) }
        guard info.abiVersion == kYKUSBDriverABIVersion else {
            throw DriverClientError.incompatibleDriver(abiVersion: info.abiVersion)
        }
        return DriverDeviceInfo(
            vendorID: info.vendorID,
            productID: info.productID,
            product: Self.string(fromCString: info.product),
            otpInterfaceNumber: info.otpInterfaceNumber == kYKUSBNoInterface ? nil : info.otpInterfaceNumber,
            deviceOpenResult: info.deviceOpenResult,
            driverLog: Self.string(fromCString: info.driverLog)
        )
    }

    func readFeatureReport() throws -> Data {
        var report = [UInt8](repeating: 0, count: Int(kYKUSBFeatureReportSize))
        let result = YKUSBGetFeatureReport(connection, &report)
        guard result == kIOReturnSuccess else { throw DriverClientError.ioKit(operation: "GET_REPORT", result: result) }
        return Data(report)
    }

    func writeFeatureReport(_ report: Data) throws {
        guard report.count == Int(kYKUSBFeatureReportSize) else {
            throw OTPError.invalidReportLength(actual: report.count, expected: Int(kYKUSBFeatureReportSize))
        }
        let result = YKUSBSetFeatureReport(connection, [UInt8](report))
        guard result == kIOReturnSuccess else { throw DriverClientError.ioKit(operation: "SET_REPORT", result: result) }
    }

    /// Reads a fixed-size C `char` array, which Swift imports as a tuple.
    private static func string<CString>(fromCString cString: CString) -> String {
        withUnsafeBytes(of: cString) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
