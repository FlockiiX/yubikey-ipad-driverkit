import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var activation = DriverActivation()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    driverSection
                    challengeSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("YubiKey USBDriverKit PoC")
        }
        .onAppear { model.refresh() }
    }

    private var driverSection: some View {
        GroupBox("Driver and USB") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                InfoRow("Driver status", model.driverStatus)
                InfoRow("YubiKey status", model.yubiKeyStatus)
                InfoRow("USB VID / PID", model.usbIDs)
                InfoRow("Product", model.product)
                InfoRow("Firmware", model.firmware)
                InfoRow("OTP interface", model.otpInterface)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(activation.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            HStack {
                Button("Enable / Manage Driver") { activation.enableDriver() }
                Button("Refresh") { model.refresh() }
                Button("Read OTP Status") { model.readStatus() }
            }
            .disabled(model.isBusy)
            .padding(.top, 4)
        }
    }

    private var challengeSection: some View {
        GroupBox("HMAC-SHA1 Challenge-Response") {
            Picker("Challenge format", selection: $model.challengeFormat) {
                ForEach(AppModel.ChallengeFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            TextField("Challenge", text: $model.challenge, axis: .vertical)
                .textFieldStyle(.roundedBorder)

            HStack {
                ForEach(OTPSlot.allCases, id: \.self) { slot in
                    Button("Run Challenge — Slot \(slot.rawValue)") { model.runChallenge(slot: slot) }
                }
            }
            .disabled(model.isBusy)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                InfoRow("Challenge UTF-8", model.challengeUTF8)
                InfoRow("Challenge hex", model.challengeHex)
                InfoRow("Response (20-byte hex)", model.responseHex)
                InfoRow("Duration", model.duration)
            }
            .padding(.top, 6)
        }
    }

    private var logSection: some View {
        GroupBox {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Copy Log") { copyToPasteboard(model.log) }
            }
            Text(model.log)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                .textSelection(.enabled)
        }
    }

    private func copyToPasteboard(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
