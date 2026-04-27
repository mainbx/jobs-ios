// swift-tools-version: 5.9
//
// This Package.swift exists **only** to let us type-check the Swift
// sources outside Xcode. The real iOS app target lives in the
// checked-in `jobs-ios.xcodeproj` (see README.md § First-time setup).
//
// `JobsApp.swift` is excluded because `@main struct JobsApp: App`
// only works inside an iOS app target, not a library. The rest of
// the Swift files can be type-checked here.

import PackageDescription

let package = Package(
    name: "jobs-ios",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JobsIOSCore", targets: ["JobsIOSCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "JobsIOSCore",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            path: "Sources",
            exclude: ["JobsApp.swift"]
        ),
    ]
)
