// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "YubiKeyUSBPoC",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "YubiKeyOTP", targets: ["YubiKeyOTP"]),
        .executable(name: "ykusb-mac-probe", targets: ["MacHIDProbe"]),
    ],
    targets: [
        .target(name: "YubiKeyOTP"),
        .executableTarget(name: "MacHIDProbe", dependencies: ["YubiKeyOTP"]),
        .testTarget(name: "YubiKeyOTPTests", dependencies: ["YubiKeyOTP"]),
    ]
)
