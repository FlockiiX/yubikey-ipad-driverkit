import XCTest
import YubiKeyOTP

final class HexTests: XCTestCase {
    func testRoundTrip() throws {
        let bytes = Data([0x00, 0x7f, 0x80, 0xff])
        XCTAssertEqual(Hex.encode(bytes), "007f80ff")
        XCTAssertEqual(try Hex.decode("007F80ff"), bytes)
    }

    func testIgnoresWhitespaceAndSeparators() throws {
        XCTAssertEqual(try Hex.decode("de:ad be-ef\n"), Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testRejectsOddNumberOfDigits() {
        XCTAssertThrowsError(try Hex.decode("abc")) {
            XCTAssertEqual($0 as? HexDecodingError, .oddNumberOfDigits)
        }
    }

    func testRejectsNonHexCharacters() {
        XCTAssertThrowsError(try Hex.decode("+f")) {
            XCTAssertEqual($0 as? HexDecodingError, .invalidCharacter("+"))
        }
    }
}
