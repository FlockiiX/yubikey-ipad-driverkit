import XCTest
@testable import YubiKeyOTP

final class OTPFrameTests: XCTestCase {
    func testCRCReferenceVectorAndResidual() {
        XCTAssertEqual(OTPFrame.crc16(Array("123456789".utf8)), 0x6f91)

        let payload = Array("response".utf8)
        let crc = ~OTPFrame.crc16(payload)
        let checked = payload + [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)]
        XCTAssertEqual(OTPFrame.crc16(checked), OTPFrame.validCRCResidual)
    }

    func testFrameLayout() {
        let frame = OTPFrame.frame(command: 0x30, payload: [UInt8](repeating: 0, count: 64))
        XCTAssertEqual(frame.count, 70)
        XCTAssertEqual(frame[64], 0x30)
        XCTAssertEqual(Array(frame[67...]), [0, 0, 0])
    }

    func testAllZeroChunksAreSkippedExceptFirstAndLast() {
        let frame = OTPFrame.frame(command: 0x30, payload: [UInt8](repeating: 0, count: 64))
        let reports = OTPFrame.outboundReports(for: frame)
        XCTAssertEqual(reports.map { $0[7] }, [0x80, 0x89])
        XCTAssertTrue(reports.allSatisfy { $0.count == 8 })
    }

    func testChallengePaddingMatchesYubicoRule() {
        let normal = OTPFrame.padChallenge([0x41])
        XCTAssertEqual(normal.count, 64)
        XCTAssertEqual(normal[1], 0x00)

        let nullTerminated = OTPFrame.padChallenge([0x41, 0x00])
        XCTAssertEqual(nullTerminated.count, 64)
        XCTAssertEqual(nullTerminated[2], 0x01)

        let full = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(OTPFrame.padChallenge(full), full)
    }
}
