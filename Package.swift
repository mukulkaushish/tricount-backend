// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TricountBackend",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        // 🐬 Fluent driver for MySQL.
        .package(url: "https://github.com/vapor/fluent-mysql-driver.git", from: "4.8.0"),
        // 🔐 JWT signing and verification.
        .package(url: "https://github.com/vapor/jwt.git", from: "4.0.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // 🔒 Argon2id password hashing via libsodium
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "TricountBackend",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentMySQLDriver", package: "fluent-mysql-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Sodium", package: "swift-sodium"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "TricountBackendTests",
            dependencies: [
                .target(name: "TricountBackend"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
