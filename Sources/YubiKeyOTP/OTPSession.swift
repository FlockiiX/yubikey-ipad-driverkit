import Foundation

/// Progress reported while a session waits for the YubiKey.
public enum OTPKeepaliveState: Equatable, Sendable {
    case processing
    case waitingForTouch
}

/// Runs legacy YubiKey OTP HID transactions over a Feature report transport.
///
/// Follows the transfer logic of `yubikit.core.otp`. The session reads the
/// OTP status and runs HMAC-SHA1 challenge-response; it has no configuration
/// commands. Its only writes are challenge frames and Yubico's dummy report
/// that finishes or aborts a transfer.
/// Upstream copyright and license: see THIRD_PARTY_NOTICES at the repository root.
///
/// Every method blocks until the YubiKey answers, the user touches the key,
/// or the timeout expires. Call them off the main thread.
public final class OTPSession {
    public static let defaultTimeout: TimeInterval = 30

    public var onLog: ((String) -> Void)?
    public var onKeepalive: ((OTPKeepaliveState) -> Void)?

    private let transport: OTPFeatureReportTransport
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void

    public convenience init(transport: OTPFeatureReportTransport) {
        self.init(
            transport: transport,
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    init(
        transport: OTPFeatureReportTransport,
        now: @escaping () -> TimeInterval,
        sleep: @escaping (TimeInterval) -> Void
    ) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    public func readStatus() throws -> OTPStatus {
        let status = try OTPStatus(report: readReport())
        onLog?("status report: \(Hex.encode(status.raw)); firmware=\(status.firmwareVersion), programmingSequence=\(status.programmingSequence)")
        return status
    }

    /// Sends `challenge` to the slot and returns the 20-byte HMAC-SHA1 response.
    public func challengeResponse(
        slot: OTPSlot,
        challenge: Data,
        timeout: TimeInterval = defaultTimeout
    ) throws -> Data {
        guard challenge.count <= OTPFrame.payloadSize else {
            throw OTPError.invalidChallengeLength(actual: challenge.count, maximum: OTPFrame.payloadSize)
        }
        let deadline = now() + max(0.001, timeout)
        let payload = OTPFrame.padChallenge([UInt8](challenge))
        onLog?("HMAC-SHA1 command=0x\(String(format: "%02x", slot.hmacCommand)), slot=\(slot.rawValue), challenge=\(Hex.encode(challenge)), padded=\(Hex.encode(payload))")

        let status = try OTPStatus(report: readReport())
        guard status.isConfigured(slot) else { throw OTPError.slotNotConfigured(slot) }

        do {
            try writeFrame(OTPFrame.frame(command: slot.hmacCommand, payload: payload), deadline: deadline)
            let response = try readResponse(deadline: deadline)
            let hmac = try verifiedHMACResponse(response)
            try sendDummyReport()
            return hmac
        } catch {
            // Abort a partial transfer without replacing its original error.
            try? sendDummyReport()
            throw error
        }
    }

    // MARK: - Transfer

    private enum Polling {
        static let writeReadyAttempts = 20
        static let writeReadyInterval: TimeInterval = 0.05
        static let repeatedChunkInterval: TimeInterval = 0.002
        static let touchInterval: TimeInterval = 0.1
        static let processingInterval: TimeInterval = 0.02
    }

    private func writeFrame(_ frame: [UInt8], deadline: TimeInterval) throws {
        for report in OTPFrame.outboundReports(for: frame) {
            try waitUntilReadyToWrite(deadline: deadline)
            let sequence = report[OTPFrame.flagsIndex] & OTPFrame.Flag.sequenceMask
            onLog?("OTP frame chunk sent: seq=\(sequence), report=\(Hex.encode(report))")
            try writeReport(report)
        }
    }

    private func waitUntilReadyToWrite(deadline: TimeInterval) throws {
        for _ in 0..<Polling.writeReadyAttempts {
            try checkDeadline(deadline, isWaitingForTouch: false)
            if try readReport()[OTPFrame.flagsIndex] & OTPFrame.Flag.slotWrite == 0 { return }
            sleep(Polling.writeReadyInterval)
        }
        throw OTPError.responseTimeout
    }

    private func readResponse(deadline: TimeInterval) throws -> [UInt8] {
        var response: [UInt8] = []
        var expectedSequence: UInt8 = 0
        var isWaitingForTouch = false

        while true {
            try checkDeadline(deadline, isWaitingForTouch: isWaitingForTouch)
            let report = try readReport()
            let flags = report[OTPFrame.flagsIndex]
            onLog?("response/status report: \(Hex.encode(report))")

            if flags & OTPFrame.Flag.responsePending != 0 {
                let sequence = flags & OTPFrame.Flag.sequenceMask
                if sequence == expectedSequence {
                    response += report.prefix(OTPFrame.chunkSize)
                    onLog?("response chunk received: seq=\(sequence), accumulated=\(response.count)")
                    expectedSequence &+= 1
                } else if expectedSequence > 0 && sequence == (expectedSequence &- 1) & OTPFrame.Flag.sequenceMask {
                    // Check repeats before the end marker: the first chunk is also sequence 0.
                    sleep(Polling.repeatedChunkInterval)
                } else if sequence == 0 && expectedSequence > 0 {
                    return response
                } else {
                    throw OTPError.unexpectedSequence(expected: expectedSequence, actual: sequence)
                }
            } else if flags == 0 {
                // A plain status report: the device has no response data.
                guard response.isEmpty else { throw OTPError.incompleteTransfer }
                throw isWaitingForTouch ? OTPError.touchTimeout : OTPError.commandRejected
            } else if flags & OTPFrame.Flag.touchPending != 0 {
                if !isWaitingForTouch { onLog?("waiting for touch") }
                isWaitingForTouch = true
                onKeepalive?(.waitingForTouch)
                sleep(Polling.touchInterval)
            } else {
                onKeepalive?(.processing)
                sleep(Polling.processingInterval)
            }
        }
    }

    private func verifiedHMACResponse(_ response: [UInt8]) throws -> Data {
        let checkedLength = OTPFrame.hmacResponseSize + 2 // response followed by its CRC
        guard response.count >= checkedLength else {
            throw OTPError.invalidResponseLength(actual: response.count, expected: checkedLength)
        }
        let residual = OTPFrame.crc16(response.prefix(checkedLength))
        guard residual == OTPFrame.validCRCResidual else {
            onLog?("CRC failure: checked=\(Hex.encode(response.prefix(checkedLength))), residual=0x\(String(format: "%04x", residual))")
            throw OTPError.crcFailure
        }
        let hmac = Data(response.prefix(OTPFrame.hmacResponseSize))
        onLog?("CRC result: valid (0xf0b8); final response=\(Hex.encode(hmac))")
        return hmac
    }

    private func checkDeadline(_ deadline: TimeInterval, isWaitingForTouch: Bool) throws {
        guard now() >= deadline else { return }
        throw isWaitingForTouch ? OTPError.touchTimeout : OTPError.responseTimeout
    }

    /// Finishes or aborts the current transfer.
    private func sendDummyReport() throws {
        var report = [UInt8](repeating: 0, count: OTPFrame.featureReportSize)
        report[OTPFrame.flagsIndex] = OTPFrame.Flag.dummyReport
        onLog?("reset/finish report: \(Hex.encode(report))")
        try writeReport(report)
    }

    // MARK: - Transport

    private func readReport() throws -> [UInt8] {
        let report = try transport.readFeatureReport()
        guard report.count == OTPFrame.featureReportSize else {
            throw OTPError.invalidReportLength(actual: report.count, expected: OTPFrame.featureReportSize)
        }
        return [UInt8](report)
    }

    private func writeReport(_ report: [UInt8]) throws {
        precondition(report.count == OTPFrame.featureReportSize)
        try transport.writeFeatureReport(Data(report))
    }
}
