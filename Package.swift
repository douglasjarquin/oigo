// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "OigoSpike",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "OigoCore", targets: ["OigoCore"]),
        .library(name: "OigoSpike", targets: ["OigoSpike"]),
        .executable(name: "Oigo", targets: ["Oigo"]),
        .executable(name: "oigo-spike", targets: ["OigoSpikeCLI"]),
        .executable(name: "oigo-spike-contract-tests", targets: ["OigoSpikeContractTests"]),
        .executable(
            name: "oigo-issue3-contract-tests",
            targets: ["OigoIssue3ContractTests"]
        )
    ],
    targets: [
        .target(
            name: "OigoCore",
            path: "Sources/OigoCore"
        ),
        .target(
            name: "OigoSpike",
            linkerSettings: [
                .linkedFramework("AVFAudio"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("Speech")
            ]
        ),
        .executableTarget(
            name: "OigoSpikeCLI",
            dependencies: ["OigoSpike"],
            path: "Sources/oigo-spike"
        ),
        .executableTarget(
            name: "OigoSpikeContractTests",
            dependencies: ["OigoSpike"],
            path: "Tests/OigoSpikeContractTests"
        ),
        .executableTarget(
            name: "Oigo",
            dependencies: ["OigoCore"],
            path: "Sources/Oigo",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "OigoIssue3ContractTests",
            dependencies: ["OigoCore"],
            path: "Tests/OigoIssue3ContractTests"
        )
    ]
)
