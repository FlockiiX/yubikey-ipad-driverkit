import Foundation
import Combine

/// View state and actions of the test app.
///
/// Driver I/O blocks for up to 30 seconds while the YubiKey waits for a touch,
/// so each operation runs on a private serial queue. Only one operation runs
/// at a time.
@MainActor
final class AppModel: ObservableObject {
    enum ChallengeFormat: String, CaseIterable, Identifiable {
        case text = "Text"
        case hex = "Hex"

        var id: Self { self }

        func data(from input: String) throws -> Data {
            switch self {
            case .text: return Data(input.utf8)
            case .hex: return try Hex.decode(input)
            }
        }
    }

    @Published private(set) var driverStatus = "Checking device connection…"
    @Published private(set) var yubiKeyStatus = "Checking…"
    @Published private(set) var usbIDs = "—"
    @Published private(set) var product = "—"
    @Published private(set) var firmware = "—"
    @Published private(set) var otpInterface = "—"
    @Published var challenge = "YubiKey USBDriverKit PoC"
    @Published var challengeFormat: ChallengeFormat = .text
    @Published private(set) var challengeUTF8 = "—"
    @Published private(set) var challengeHex = "—"
    @Published private(set) var responseHex = "—"
    @Published private(set) var duration = "—"
    @Published private(set) var isBusy = false
    @Published private(set) var log = ""

    private var client: DriverClient?
    private var lastRefreshFailure: String?
    private let ioQueue = DispatchQueue(label: "YubiKeyUSBPoC.driver-io", qos: .userInitiated)
    private let timestampFormatter = ISO8601DateFormatter()

    /// Checks only while idle, so a touch/challenge transaction is never interrupted.
    func monitorConnection() async {
        while !Task.isCancelled {
            refresh(automatically: true)
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
        }
    }

    func refresh(automatically: Bool = false) {
        let existingClient = client
        run("Refresh", logsProgress: !automatically, onFailure: { [self] error in
            let previousStatus = driverStatus
            let repeatedError = lastRefreshFailure == error.localizedDescription
            lastRefreshFailure = error.localizedDescription
            let waiting = isMissingDevice(error)
            clearConnection()
            driverStatus = waiting ? "Waiting for device connection" : "Connection failed"
            yubiKeyStatus = waiting ? "Not detected" : "Status unavailable"
            if waiting {
                if !automatically || previousStatus != driverStatus {
                    appendLog("No active YubiKey driver service. Connect the YubiKey. If it is already connected, enable the driver and reconnect it.")
                }
                return true
            }
            // Do not repeat an unchanged connection error every two seconds.
            return automatically && repeatedError
        }) { [self] in
            let (client, info) = try await performIO { () -> (DriverClient, DriverDeviceInfo) in
                let client = try existingClient ?? DriverClient()
                return (client, try client.deviceInfo())
            }
            self.client = client
            lastRefreshFailure = nil
            if !automatically || existingClient == nil { show(info) }
        }
    }

    func readStatus() {
        runWithClient("Read OTP Status") { [self] client in
            let status = try await performIO { try self.makeSession(for: client).readStatus() }
            firmware = status.firmwareVersion
            yubiKeyStatus = OTPSlot.allCases
                .map { "Slot \($0.rawValue) \(status.isConfigured($0) ? "configured" : "empty")" }
                .joined(separator: ", ")
            appendLog("OTP status: raw=\(Hex.encode(status.raw)), firmware=\(status.firmwareVersion), \(yubiKeyStatus)")
        }
    }

    func runChallenge(slot: OTPSlot) {
        let input = challenge
        let format = challengeFormat
        runWithClient("HMAC-SHA1 Slot \(slot.rawValue)") { [self] client in
            let challenge = try format.data(from: input)
            let (response, elapsed) = try await performIO { () -> (Data, TimeInterval) in
                let started = Date()
                let response = try self.makeSession(for: client).challengeResponse(slot: slot, challenge: challenge)
                return (response, Date().timeIntervalSince(started))
            }
            challengeUTF8 = String(data: challenge, encoding: .utf8) ?? "<not UTF-8>"
            challengeHex = Hex.encode(challenge)
            responseHex = Hex.encode(response)
            duration = String(format: "%.3f s", elapsed)
            yubiKeyStatus = "Slot \(slot.rawValue) HMAC-SHA1 succeeded"
            appendLog("final response: slot=\(slot.rawValue), challengeHex=\(challengeHex), response=\(responseHex), duration=\(duration)")
        }
    }

    // MARK: - Operations

    private func run(
        _ name: String,
        logsProgress: Bool = true,
        onFailure: @escaping @MainActor (Error) -> Bool = { _ in false },
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        if logsProgress { appendLog("\(name) started") }
        Task {
            defer { isBusy = false }
            do {
                try await operation()
                if logsProgress { appendLog("\(name) finished") }
            } catch {
                yubiKeyStatus = "\(name) failed"
                let handled = onFailure(error)
                if !handled { appendLog("\(name) failed: \(error.localizedDescription)") }
            }
        }
    }

    private func runWithClient(_ name: String, operation: @escaping @MainActor (DriverClient) async throws -> Void) {
        guard let client else {
            appendLog("\(name): driver not connected. Enable the driver, reconnect the YubiKey, then tap Refresh.")
            return
        }
        run(name, onFailure: { [self] error in
            if isMissingDevice(error) {
                clearConnection()
                driverStatus = "Waiting for device connection"
                yubiKeyStatus = "Disconnected"
            }
            return false
        }) { try await operation(client) }
    }

    private func isMissingDevice(_ error: Error) -> Bool {
        guard let error = error as? DriverClientError else { return false }
        switch error {
        case .serviceNotFound: return true
        case .ioKit(_, let result):
            return YKUSBIsDeviceDisconnected(result)
        case .incompatibleDriver: return false
        }
    }

    private func clearConnection() {
        client = nil
        usbIDs = "—"
        product = "—"
        firmware = "—"
        otpInterface = "—"
    }

    private func performIO<Value>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    /// Creates a session whose callbacks, which arrive on the I/O queue, update
    /// the UI on the main queue.
    private nonisolated func makeSession(for client: DriverClient) -> OTPSession {
        let session = OTPSession(transport: client)
        session.onLog = { [weak self] message in
            DispatchQueue.main.async { self?.appendLog(message) }
        }
        session.onKeepalive = { [weak self] state in
            guard state == .waitingForTouch else { return }
            DispatchQueue.main.async { self?.yubiKeyStatus = "Touch your YubiKey..." }
        }
        return session
    }

    // MARK: - Presentation

    private func show(_ info: DriverDeviceInfo) {
        driverStatus = "Loaded; user client connected"
        usbIDs = String(format: "0x%04x / 0x%04x", info.vendorID, info.productID)
        product = info.product.isEmpty ? "Unavailable" : info.product
        otpInterface = info.otpInterfaceNumber.map(String.init) ?? "Not found"
        if info.deviceOpenResult != kIOReturnSuccess {
            yubiKeyStatus = "USB open failed: \(DriverClientError.describe(info.deviceOpenResult))"
        } else if info.otpInterfaceNumber == nil {
            yubiKeyStatus = "Connected; OTP interface not found"
        } else {
            yubiKeyStatus = "Connected"
        }
        appendLog("device info: VID/PID=\(usbIDs), product=\(product), OTP interface=\(otpInterface)")
        if !info.driverLog.isEmpty { appendLog("driver log:\n\(info.driverLog)") }
    }

    private func appendLog(_ message: String) {
        let entry = "[\(timestampFormatter.string(from: Date()))] \(message)"
        log = log.isEmpty ? entry : log + "\n" + entry
    }
}
