import XCTest
@testable import YubiKeyOTP

final class OTPSessionTests: XCTestCase {
    private enum TransportFailure: Error {
        case disconnected
        case writeFailed
    }

    private var clock = 0.0

    private func makeSession(_ transport: MockTransport) -> OTPSession {
        OTPSession(transport: transport, now: { self.clock }, sleep: { self.clock += $0 })
    }

    func testSlotOneResponseAssemblyAndCRC() throws {
        let expected = [UInt8](0..<20)
        let transport = MockTransport(reads: Reports.successfulExchange(response: expected, touchLevel: 0x01))

        let response = try makeSession(transport).challengeResponse(slot: .one, challenge: Data("abc".utf8))

        XCTAssertEqual([UInt8](response), expected)
        XCTAssertEqual(transport.writes.map { $0[7] }, [0x80, 0x89, 0xff])
        XCTAssertEqual(transport.writes[1][1], 0x30)
    }

    func testSlotTwoUsesCommand0x38() throws {
        let expected = [UInt8](repeating: 0xa5, count: 20)
        let transport = MockTransport(reads: Reports.successfulExchange(response: expected, touchLevel: 0x02))

        let response = try makeSession(transport).challengeResponse(slot: .two, challenge: Data())

        XCTAssertEqual([UInt8](response), expected)
        XCTAssertEqual(transport.writes[1][1], 0x38)
    }

    func test32ByteChallengeMatchesIndependentReportVector() throws {
        let expected = [UInt8](repeating: 0xa5, count: 20)
        let transport = MockTransport(reads: Reports.successfulExchange(
            response: expected, touchLevel: 0x02, writeReportCount: 6
        ))

        let response = try makeSession(transport).challengeResponse(slot: .two, challenge: Data(0..<32))

        XCTAssertEqual([UInt8](response), expected)
        // Fixed vector for bytes 00..1f, padded with zeroes. CRC 0x929e was
        // calculated independently using Python binascii.crc_hqx with reflected bits.
        let reports = try [
            "0001020304050680", "0708090a0b0c0d81", "0e0f101112131482",
            "15161718191a1b83", "1c1d1e1f00000084", "00389e9200000089",
            "00000000000000ff",
        ].map { [UInt8](try Hex.decode($0)) }
        XCTAssertEqual(transport.writes, reports)
    }

    func testUnconfiguredSlotIsRejectedBeforeWriting() {
        let transport = MockTransport(reads: [Reports.status(touchLevel: 0)])

        XCTAssertThrowsError(try makeSession(transport).challengeResponse(slot: .one, challenge: Data())) {
            XCTAssertEqual($0 as? OTPError, .slotNotConfigured(.one))
        }
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testOversizedChallengeIsRejectedBeforeAnyIO() {
        let transport = MockTransport(reads: [])

        XCTAssertThrowsError(try makeSession(transport).challengeResponse(slot: .two, challenge: Data(count: 65))) {
            XCTAssertEqual($0 as? OTPError, .invalidChallengeLength(actual: 65, maximum: 64))
        }
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testTouchKeepaliveThenSuccess() throws {
        let expected = [UInt8](repeating: 0x5a, count: 20)
        var reads = Reports.successfulExchange(response: expected, touchLevel: 0x01)
        reads.insert(Reports.touchPending, at: 3)
        let session = makeSession(MockTransport(reads: reads))
        var states: [OTPKeepaliveState] = []
        session.onKeepalive = { states.append($0) }

        XCTAssertEqual([UInt8](try session.challengeResponse(slot: .one, challenge: Data())), expected)
        XCTAssertTrue(states.contains(.waitingForTouch))
    }

    func testTouchTimeoutSendsDummyReport() {
        let idle = Reports.status(touchLevel: 0x01)
        let transport = MockTransport(reads: [idle, idle, idle], fallback: Reports.touchPending)

        XCTAssertThrowsError(try makeSession(transport).challengeResponse(slot: .one, challenge: Data(), timeout: 0.15)) {
            XCTAssertEqual($0 as? OTPError, .touchTimeout)
        }
        XCTAssertEqual(transport.writes.last, Reports.dummy)
    }

    func testRepeatedPreviousChunkIsTolerated() throws {
        let expected = [UInt8](repeating: 0x33, count: 20)
        var reads = Reports.successfulExchange(response: expected, touchLevel: 0x01)
        reads.insert(reads[4], at: 5) // chunk 1 again before chunk 2

        let response = try makeSession(MockTransport(reads: reads)).challengeResponse(slot: .one, challenge: Data())

        XCTAssertEqual([UInt8](response), expected)
    }

    func testRepeatedFirstChunkIsTolerated() throws {
        let expected = [UInt8](repeating: 0x33, count: 20)
        var reads = Reports.successfulExchange(response: expected, touchLevel: 0x01)
        reads.insert(reads[3], at: 4)
        let transport = MockTransport(reads: reads)

        let response = try makeSession(transport).challengeResponse(slot: .one, challenge: Data())

        XCTAssertEqual([UInt8](response), expected)
        XCTAssertEqual(transport.writes.last, Reports.dummy)
    }

    func testUnexpectedSequenceIsRejected() {
        var reads = Reports.successfulExchange(response: [UInt8](repeating: 0, count: 20), touchLevel: 0x01)
        reads.remove(at: 4) // chunk 1 is missing, chunk 2 follows chunk 0

        let transport = MockTransport(reads: reads)
        XCTAssertThrowsError(try makeSession(transport).challengeResponse(slot: .one, challenge: Data())) {
            XCTAssertEqual($0 as? OTPError, .unexpectedSequence(expected: 1, actual: 2))
        }
        XCTAssertEqual(transport.writes.last, Reports.dummy)
    }

    func testIncompleteTransferSendsDummyReport() {
        let idle = Reports.status(touchLevel: 0x01)
        let transport = MockTransport(reads: [idle, idle, idle, [0, 0, 0, 0, 0, 0, 0, 0x40], idle])

        XCTAssertThrowsError(try makeSession(transport).challengeResponse(slot: .one, challenge: Data())) {
            XCTAssertEqual($0 as? OTPError, .incompleteTransfer)
        }
        XCTAssertEqual(transport.writes.last, Reports.dummy)
    }

    func testResponseReadErrorIsPreservedAndAbortsTransfer() {
        let idle = Reports.status(touchLevel: 0x01)
        let transport = MockTransport(reads: [idle, idle, idle])
        transport.readError = TransportFailure.disconnected

        XCTAssertThrowsError(try makeSession(transport).challengeResponse(slot: .one, challenge: Data())) {
            XCTAssertEqual($0 as? TransportFailure, .disconnected)
        }
        XCTAssertEqual(transport.writes.last, Reports.dummy)
    }

    func testWriteErrorIsPreservedEvenWhenAbortFails() {
        let idle = Reports.status(touchLevel: 0x01)
        let transport = MockTransport(reads: [idle, idle])
        transport.writeError = TransportFailure.writeFailed

        XCTAssertThrowsError(try makeSession(transport).challengeResponse(slot: .one, challenge: Data())) {
            XCTAssertEqual($0 as? TransportFailure, .writeFailed)
        }
        XCTAssertEqual(transport.writes.last, Reports.dummy)
    }

    func testInvalidResponseCRCIsRejected() {
        var reads = Reports.successfulExchange(response: [UInt8](repeating: 0x11, count: 20), touchLevel: 0x01)
        reads[reads.count - 2][0] ^= 0xff // corrupt the CRC in the last chunk

        XCTAssertThrowsError(try makeSession(MockTransport(reads: reads)).challengeResponse(slot: .one, challenge: Data())) {
            XCTAssertEqual($0 as? OTPError, .crcFailure)
        }
    }

    func testInvalidReportLengthIsRejected() {
        let transport = MockTransport(reads: [[UInt8](repeating: 0, count: 7)])

        XCTAssertThrowsError(try makeSession(transport).readStatus()) {
            XCTAssertEqual($0 as? OTPError, .invalidReportLength(actual: 7, expected: 8))
        }
    }
}
