import Foundation

/// The OTP application status that bytes 1–6 of an idle Feature report carry.
public struct OTPStatus: Equatable, Sendable {
    public let firmwareMajor: UInt8
    public let firmwareMinor: UInt8
    public let firmwarePatch: UInt8
    /// Incremented by the device after each successful configuration write.
    public let programmingSequence: UInt8
    /// Slot state bits (`CFGSTATE` in Yubico's sources).
    public let touchLevel: UInt16
    /// The six raw status bytes.
    public let raw: Data

    public var firmwareVersion: String {
        "\(firmwareMajor).\(firmwareMinor).\(firmwarePatch)"
    }

    /// Whether the slot holds a configuration of any kind.
    public func isConfigured(_ slot: OTPSlot) -> Bool {
        touchLevel & (slot == .one ? Flag.slot1Valid : Flag.slot2Valid) != 0
    }

    /// Whether touching the key makes this slot emit an OTP (Yubico OTP,
    /// static password). Challenge-response slots report `false`, even when
    /// they require a touch for each challenge.
    public func isTouchTriggered(_ slot: OTPSlot) -> Bool {
        touchLevel & (slot == .one ? Flag.slot1Touch : Flag.slot2Touch) != 0
    }

    init(report: [UInt8]) throws {
        guard report.count == OTPFrame.featureReportSize else {
            throw OTPError.invalidReportLength(actual: report.count, expected: OTPFrame.featureReportSize)
        }
        firmwareMajor = report[1]
        firmwareMinor = report[2]
        firmwarePatch = report[3]
        programmingSequence = report[4]
        touchLevel = UInt16(report[5]) | UInt16(report[6]) << 8
        raw = Data(report[1...6])
    }

    private enum Flag {
        static let slot1Valid: UInt16 = 0x01
        static let slot2Valid: UInt16 = 0x02
        static let slot1Touch: UInt16 = 0x04
        static let slot2Touch: UInt16 = 0x08
    }
}
