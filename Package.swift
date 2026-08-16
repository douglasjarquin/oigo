// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "OigoSpike",
    platforms: [
        .macOS("13.0")
    ],
    products: [
        .library(name: "OigoCore", targets: ["OigoCore"]),
        .library(name: "OigoCapture", targets: ["OigoCapture"]),
        .library(name: "OigoTranscription", targets: ["OigoTranscription"]),
        .library(name: "OigoInsertion", targets: ["OigoInsertion"]),
        .library(name: "OigoSpike", targets: ["OigoSpike"]),
        .executable(name: "Oigo", targets: ["Oigo"]),
        .executable(name: "oigo-spike", targets: ["OigoSpikeCLI"]),
        .executable(name: "oigo-spike-contract-tests", targets: ["OigoSpikeContractTests"]),
        .executable(
            name: "oigo-issue3-contract-tests",
            targets: ["OigoIssue3ContractTests"]
        ),
        .executable(
            name: "oigo-issue4-contract-tests",
            targets: ["OigoIssue4ContractTests"]
        ),
        .executable(
            name: "oigo-issue5-contract-tests",
            targets: ["OigoIssue5ContractTests"]
        ),
        .executable(
            name: "oigo-issue6-contract-tests",
            targets: ["OigoIssue6ContractTests"]
        ),
        .executable(
            name: "oigo-issue7-contract-tests",
            targets: ["OigoIssue7ContractTests"]
        ),
        .executable(
            name: "oigo-issue8-contract-tests",
            targets: ["OigoIssue8ContractTests"]
        ),
        .executable(
            name: "oigo-issue9-contract-tests",
            targets: ["OigoIssue9ContractTests"]
        ),
        .executable(
            name: "oigo-issue10-contract-tests",
            targets: ["OigoIssue10ContractTests"]
        ),
        .executable(
            name: "oigo-issue11-performance-check",
            targets: ["OigoIssue11PerformanceCheck"]
        )
    ],
    targets: [
        .target(
            name: "OigoCore",
            path: "Sources/OigoCore"
        ),
        .target(
            name: "OigoCapture",
            dependencies: ["OigoCore"],
            path: "Sources/OigoCapture",
            linkerSettings: [
                .linkedFramework("AVFAudio")
            ]
        ),
        .target(
            name: "OigoTranscription",
            dependencies: ["OigoCore"],
            path: "Sources/OigoTranscription",
            linkerSettings: [
                .linkedFramework("AVFAudio"),
                .linkedFramework("Speech")
            ]
        ),
        .target(
            name: "OigoInsertion",
            dependencies: ["OigoCore"],
            path: "Sources/OigoInsertion",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics")
            ]
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
            dependencies: ["OigoSpike", "OigoCore", "OigoTranscription"],
            path: "Sources/oigo-spike"
        ),
        .executableTarget(
            name: "OigoSpikeContractTests",
            dependencies: ["OigoSpike"],
            path: "Tests/OigoSpikeContractTests"
        ),
        .executableTarget(
            name: "Oigo",
            dependencies: ["OigoCore", "OigoCapture", "OigoTranscription", "OigoInsertion"],
            path: "Sources/Oigo",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "OigoIssue3ContractTests",
            dependencies: ["OigoCore"],
            path: "Tests/OigoIssue3ContractTests"
        ),
        .executableTarget(
            name: "OigoIssue4ContractTests",
            dependencies: ["OigoCore", "OigoCapture"],
            path: "Tests/OigoIssue4ContractTests"
        ),
        .executableTarget(
            name: "OigoIssue5ContractTests",
            dependencies: ["OigoCore", "OigoTranscription"],
            path: "Tests/OigoIssue5ContractTests"
        ),
        .executableTarget(
            name: "OigoIssue6ContractTests",
            dependencies: ["OigoCore", "OigoInsertion"],
            path: "Tests/OigoIssue6ContractTests"
        ),
        .executableTarget(
            name: "OigoIssue7ContractTests",
            dependencies: ["OigoCore", "OigoTranscription", "OigoInsertion"],
            path: "Tests/OigoIssue7ContractTests"
        ),
        .executableTarget(
            name: "OigoIssue8ContractTests",
            dependencies: ["OigoCore", "OigoTranscription", "OigoInsertion"],
            path: "Tests/OigoIssue8ContractTests",
            exclude: ["Fixtures"]
        ),
        .executableTarget(
            name: "OigoIssue9ContractTests",
            dependencies: ["OigoCore", "OigoTranscription"],
            path: "Tests/OigoIssue9ContractTests"
        ),
        .executableTarget(
            name: "OigoIssue10ContractTests",
            dependencies: ["OigoCore", "OigoInsertion", "OigoTranscription"],
            path: "Tests/OigoIssue10ContractTests"
        ),
        .executableTarget(
            name: "OigoIssue11PerformanceCheck",
            dependencies: ["OigoCore", "OigoTranscription"],
            path: "Tests/OigoIssue11PerformanceCheck"
        )
    ]
)
