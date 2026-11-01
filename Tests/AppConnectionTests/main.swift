import Foundation

@main
struct AppConnectionTests {
    @MainActor
    static func settled(_ model: AppModel) async {
        while model.isBusy { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    @MainActor
    static func main() async {
        let model = AppModel()
        model.refresh(automatically: true)
        await settled(model)
        precondition(model.driverStatus == "Waiting for device connection")
        precondition(model.yubiKeyStatus == "Not detected")
        precondition(!model.log.contains("failed") && !model.log.contains("kIOReturnNotFound"))
        let idleLog = model.log
        model.refresh(automatically: true)
        await settled(model)
        precondition(model.log == idleLog, "Idle checks must not flood the log")

        // NotFound from opening an existing service must remain a real error.
        YKTestSetResults(kIOReturnNotFound, kIOReturnSuccess, 0)
        model.refresh()
        await settled(model)
        precondition(model.driverStatus == "Connection failed")
        precondition(model.log.contains("IOServiceOpen(YubiKeyUSBDriver) failed"))

        YKTestSetResults(kIOReturnNotPermitted, kIOReturnSuccess, 0)
        model.refresh()
        await settled(model)
        precondition(model.driverStatus == "Connection failed")

        YKTestSetResults(kIOReturnSuccess, kIOReturnSuccess, 0)
        model.refresh(automatically: true)
        await settled(model)
        precondition(model.driverStatus == "Loaded; user client connected")
        precondition(model.yubiKeyStatus == "Connected")
        precondition(model.product == "Test YubiKey")
        model.readStatus()
        await settled(model)
        precondition(model.firmware == "5.7.1")
        let otpStatus = model.yubiKeyStatus
        let connectedLog = model.log
        model.refresh(automatically: true)
        await settled(model)
        precondition(model.yubiKeyStatus == otpStatus, "Idle checks must preserve OTP results")
        precondition(model.log == connectedLog)

        YKTestSetResults(kIOReturnNotFound, kIOReturnNoDevice, 1)
        model.refresh(automatically: true)
        await settled(model)
        precondition(model.driverStatus == "Waiting for device connection")
        precondition(model.yubiKeyStatus == "Not detected")
        precondition(model.product == "—" && model.usbIDs == "—")
        precondition(model.firmware == "—" && model.otpInterface == "—")
        model.refresh(automatically: true)
        await settled(model)
        precondition(!model.log.contains("kIOReturnNoDevice"))

        YKTestSetResults(kIOReturnSuccess, kIOReturnSuccess, 0)
        model.refresh(automatically: true)
        await settled(model)
        precondition(model.driverStatus == "Loaded; user client connected")
        precondition(model.yubiKeyStatus == "Connected")
        // Exercise the view's actual monitoring loop, including its cancellation.
        YKTestSetResults(kIOReturnNotFound, kIOReturnNotAttached, 1)
        model.refresh(automatically: true)
        await settled(model)
        precondition(model.driverStatus == "Waiting for device connection")
        let monitor = Task { await model.monitorConnection() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await settled(model)
        YKTestSetResults(kIOReturnSuccess, kIOReturnSuccess, 0)
        try? await Task.sleep(nanoseconds: 2_100_000_000)
        await settled(model)
        precondition(model.yubiKeyStatus == "Connected", "Monitor must detect a newly attached key")
        monitor.cancel()
        await monitor.value
        print("App connection tests passed (absent, open errors, connect, idle, disconnect, reconnect).")
    }
}
