/// Framing of the legacy YubiKey OTP HID protocol.
///
/// A command is a 64-byte payload followed by the command byte, the payload's
/// CRC-16, and three zero bytes: 70 bytes in total. The host sends it in ten
/// seven-byte chunks, each in an eight-byte HID Feature report whose last byte
/// holds flags and the chunk's sequence number.
///
/// This mirrors `yubikit.core.otp` in Yubico's yubikey-manager.
/// Upstream copyright and license: see THIRD_PARTY_NOTICES at the repository root.
public enum OTPFrame {
    /// Size of one HID Feature report on the OTP interface (report ID 0).
    public static let featureReportSize = 8
    /// Size of an HMAC-SHA1 response.
    public static let hmacResponseSize = 20

    static let chunkSize = 7
    static let payloadSize = 64
    static let frameSize = 70
    static let chunkCount = frameSize / chunkSize
    /// Index of the flags byte in a Feature report.
    static let flagsIndex = featureReportSize - 1

    /// CRC-16 of data followed by its valid (one's complement) CRC.
    static let validCRCResidual: UInt16 = 0xf0b8

    /// Bits in the flags byte of a Feature report.
    enum Flag {
        /// Host to device: the report carries a frame chunk.
        /// Device to host: the device is still consuming written chunks.
        static let slotWrite: UInt8 = 0x80
        /// Device to host: the report carries a response chunk.
        static let responsePending: UInt8 = 0x40
        /// Device to host: the device is waiting for the user to touch the key.
        static let touchPending: UInt8 = 0x20
        /// Host to device: the dummy report that finishes or aborts a transfer.
        static let dummyReport: UInt8 = 0xff
        /// Mask for the chunk sequence number.
        static let sequenceMask: UInt8 = 0x1f
    }

    /// CRC-16/MCRF4XX, the checksum the YubiKey uses for frames and responses.
    static func crc16<Bytes: Sequence>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                let carry = crc & 1
                crc >>= 1
                if carry == 1 { crc ^= 0x8408 }
            }
        }
        return crc
    }

    /// Pads a challenge to 64 bytes like Yubico's tools do: with a byte that
    /// differs from the challenge's last byte, so a challenge that ends in
    /// `0x00` keeps its effective length.
    static func padChallenge(_ challenge: [UInt8]) -> [UInt8] {
        guard challenge.count < payloadSize else { return challenge }
        let padding: UInt8 = challenge.last == 0 ? 0x01 : 0x00
        return challenge + [UInt8](repeating: padding, count: payloadSize - challenge.count)
    }

    static func frame(command: UInt8, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count == payloadSize)
        let crc = crc16(payload)
        return payload + [command, UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8), 0, 0, 0]
    }

    /// Splits a frame into Feature reports. Like yubikit, it skips all-zero
    /// chunks except the first and the last.
    static func outboundReports(for frame: [UInt8]) -> [[UInt8]] {
        precondition(frame.count == frameSize)
        return (0..<chunkCount).compactMap { sequence in
            let chunk = frame[(sequence * chunkSize)..<((sequence + 1) * chunkSize)]
            let isFirstOrLast = sequence == 0 || sequence == chunkCount - 1
            guard isFirstOrLast || chunk.contains(where: { $0 != 0 }) else { return nil }
            return Array(chunk) + [Flag.slotWrite | UInt8(sequence)]
        }
    }
}
