/// A YubiKey OTP configuration slot.
public enum OTPSlot: Int, CaseIterable, Sendable {
    /// Slot 1 ("short touch"). Holds the factory Yubico OTP credential on most keys.
    case one = 1
    /// Slot 2 ("long touch"). Setup guides for KeePass-compatible apps use this
    /// slot for HMAC-SHA1 challenge-response.
    case two = 2

    /// The HMAC-SHA1 challenge-response command for this slot.
    var hmacCommand: UInt8 {
        switch self {
        case .one: return 0x30
        case .two: return 0x38
        }
    }
}
