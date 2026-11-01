import Foundation
@testable import YubiKeyOTP

/// Replays scripted Feature reports and records every write.
final class MockTransport: OTPFeatureReportTransport {
    private var reads: [[UInt8]]
    private let fallback: [UInt8]?
    private(set) var writes: [[UInt8]] = []
    var readError: Error = OTPError.transport("Mock read queue exhausted")
    var writeError: Error?

    init(reads: [[UInt8]], fallback: [UInt8]? = nil) {
        self.reads = reads
        self.fallback = fallback
    }

    func readFeatureReport() throws -> Data {
        if !reads.isEmpty { return Data(reads.removeFirst()) }
        if let fallback { return Data(fallback) }
        throw readError
    }

    func writeFeatureReport(_ report: Data) throws {
        writes.append([UInt8](report))
        if let writeError { throw writeError }
    }
}

enum Reports {
    static let touchPending: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x20]
    static let dummy: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0xff]

    /// An idle status report: firmware 5.7.1, programming sequence 9.
    static func status(touchLevel: UInt8) -> [UInt8] {
        [0, 5, 7, 1, 9, touchLevel, 0, 0]
    }

    /// The four response chunks for `response` (20 bytes + CRC + padding).
    static func responseChunks(for response: [UInt8]) -> [[UInt8]] {
        // The device appends the one's complement of the CRC, so the CRC over
        // response and CRC yields the 0xf0b8 residual.
        let crc = ~OTPFrame.crc16(response)
        var framed = response + [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)]
        framed += [UInt8](repeating: 0, count: 28 - framed.count)
        return (0..<4).map { sequence in
            Array(framed[(sequence * 7)..<(sequence * 7 + 7)]) + [0x40 | UInt8(sequence)]
        }
    }

    /// Status, one readiness poll per write, response chunks, and end marker.
    static func successfulExchange(response: [UInt8], touchLevel: UInt8, writeReportCount: Int = 2) -> [[UInt8]] {
        let idle = status(touchLevel: touchLevel)
        return Array(repeating: idle, count: writeReportCount + 1)
            + responseChunks(for: response) + [[0, 0, 0, 0, 0, 0, 0, 0x40]]
    }
}
