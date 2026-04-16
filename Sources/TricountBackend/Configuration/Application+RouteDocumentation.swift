import Foundation
import Vapor

private struct RouteDocumentationOutputDirectoryKey: StorageKey {
    typealias Value = URL
}

extension Application {
    var routeDocumentationOutputDirectory: URL {
        get {
            if let configured = storage[RouteDocumentationOutputDirectoryKey.self] {
                return configured
            }

            if let customPath = runtimeConfigurationIfLoaded?.routeDocumentation.customOutputDirectory,
               !customPath.isEmpty {
                return URL(fileURLWithPath: customPath, isDirectory: true)
            }

            // In testing, write to a temp build directory to avoid polluting the project.
            // Otherwise, write directly to Public/ (served at the web root).
            let relativePath = environment == .testing
                ? ".build/generated-route-docs"
                : "Public"
            return URL(fileURLWithPath: directory.workingDirectory, isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: true)
        }
        set {
            storage[RouteDocumentationOutputDirectoryKey.self] = newValue
        }
    }

    func generateRouteDocumentation() throws {
        let outputDirectory = routeDocumentationOutputDirectory
        let generator = RouteDocumentationGenerator(application: self)
        try generator.write(to: outputDirectory)

        logger.info(
            "Route documentation generated",
            metadata: [
                "output": .string(outputDirectory.path),
                "routes": .string("\(routes.all.count)"),
            ]
        )
    }
}
