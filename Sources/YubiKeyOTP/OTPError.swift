import Foundation

public enum OTPError: Error, Equatable, LocalizedError, Sendable {
    case invalidChallengeLength(actual: Int, maximum: Int)
    case invalidReportLength(actual: Int, expected: Int)
    case slotNotConfigured(OTPSlot)
    case commandRejected
    case touchTimeout
    case responseTimeout
    case incompleteTransfer
    case unexpectedSequence(expected: UInt8, actual: UInt8)
    case invalidResponseLength(actual: Int, expected: Int)
    case crcFailure
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidChallengeLength(let actual, let maximum):
            return "The challenge is \(actual) bytes; the maximum is \(maximum)."
        case .invalidReportLength(let actual, let expected):
            return "Invalid HID Feature report length \(actual); expected \(expected)."
        case .slotNotConfigured(let slot):
            return "Slot \(slot.rawValue) is not configured. Program it for HMAC-SHA1 challenge-response with YubiKey Manager first."
        case .commandRejected:
            return "The YubiKey rejected the OTP command."
        case .touchTimeout:
            return "Timed out waiting for a touch on the YubiKey."
        case .responseTimeout:
            return "Timed out waiting for the YubiKey's OTP response."
        case .incompleteTransfer:
            return "The YubiKey ended the OTP response transfer early."
        case .unexpectedSequence(let expected, let actual):
            return "Unexpected OTP response sequence \(actual); expected \(expected)."
        case .invalidResponseLength(let actual, let expected):
            return "Invalid HMAC response length \(actual); expected \(expected)."
        case .crcFailure:
            return "The CRC of the YubiKey's OTP response is invalid."
        case .transport(let message):
            return message
        }
    }
}
