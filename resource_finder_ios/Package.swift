// swift-tools-version:6.0
import PackageDescription

var providerDependencies: [Package.Dependency] = [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3")]
var coreDependencies: [Target.Dependency] = [.product(name: "SwiftSoup", package: "SwiftSoup")]
#if os(Linux)
providerDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"))
coreDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

let package = Package(
    name: "ResourceFinderProviders",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "ProviderCore", targets: ["ProviderCore"]), .executable(name: "ProviderProbe", targets: ["ProviderProbe"])],
    dependencies: providerDependencies,
    targets: [
        .target(name: "ProviderCore", dependencies: coreDependencies,
            path: "Sources/Core", exclude: ["JianpianCrypto.swift", "JianpianClient.swift", "CatalogService.swift"],
            sources: ["Models.swift", "CatalogProtocol.swift", "ProviderRegistry.swift", "PublicCatalog.swift", "ProviderNetwork.swift", "KkysBootstrap.swift", "ProviderAccessStore.swift", "MultiCatalogService.swift", "EpisodeNavigator.swift", "LibraryStore.swift", "WatchStore.swift"]),
        .testTarget(name: "ProviderCoreTests", dependencies: ["ProviderCore"], path: "PortableTests"),
        .executableTarget(name: "ProviderProbe", dependencies: ["ProviderCore"], path: "PortableProbe")
    ],
    swiftLanguageModes: [.v5]
)
