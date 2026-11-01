import XCTest
@testable import YubiKeyOTP

final class OTPStatusTests: XCTestCase {
    /// Status bytes reported by a YubiKey 5C NFC (firmware 5.7.4) with a
    /// factory Yubico OTP credential in Slot 1 and challenge-response in Slot 2.
    func testParsesStatusFromRealDevice() throws {
        let status = try OTPStatus(report: [0x00, 0x05, 0x07, 0x04, 0x03, 0x07, 0x06, 0x00])

        XCTAssertEqual(status.firmwareVersion, "5.7.4")
        XCTAssertEqual(status.programmingSequence, 3)
        XCTAssertTrue(status.isConfigured(.one))
        XCTAssertTrue(status.isConfigured(.two))
        XCTAssertTrue(status.isTouchTriggered(.one))
        XCTAssertFalse(status.isTouchTriggered(.two))
        XCTAssertEqual(status.raw, Data([0x05, 0x07, 0x04, 0x03, 0x07, 0x06]))
    }

    func testEmptySlots() throws {
        let status = try OTPStatus(report: [0, 5, 7, 4, 0, 0, 0, 0])

        XCTAssertFalse(status.isConfigured(.one))
        XCTAssertFalse(status.isConfigured(.two))
        XCTAssertFalse(status.hasConfiguredSlot)
    }

    func testRejectsShortReport() {
        XCTAssertThrowsError(try OTPStatus(report: [0, 5, 7])) {
            XCTAssertEqual($0 as? OTPError, .invalidReportLength(actual: 3, expected: 8))
        }
    }
}
