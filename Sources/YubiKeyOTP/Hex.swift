import Foundation

public enum Hex {
    public static func encode<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes hex digits. Whitespace and the separators `:` and `-` are ignored.
    public static func decode(_ string: String) throws -> Data {
        let nibbles = try string
            .filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
            .map { character -> UInt8 in
                guard let value = character.hexDigitValue else {
                    throw HexDecodingError.invalidCharacter(character)
                }
                return UInt8(value)
            }
        guard nibbles.count.isMultiple(of: 2) else { throw HexDecodingError.oddNumberOfDigits }
        return Data(stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] })
    }
}

public enum HexDecodingError: Error, Equatable, LocalizedError, Sendable {
    case invalidCharacter(Character)
    case oddNumberOfDigits

    public var errorDescription: String? {
        switch self {
        case .invalidCharacter(let character):
            return "“\(character)” is not a hexadecimal digit."
        case .oddNumberOfDigits:
            return "Hex input must contain an even number of digits."
        }
    }
}
