import Foundation
import OSLog

import ChimeKit
import LanguageServerProtocol

@MainActor
public final class GoExtension {
    private let host: any HostProtocol
    private let lspService: LSPService
    private let logger = Logger(subsystem: "com.chimehq.Edit.Go", category: "GoExtension")

    init(host: any HostProtocol) {
        self.host = host

        let transformers = LSPTransformers(hoverTransformer: Gopls.hoverTransformer)
		let paramProvider = { [logger] in try await GoExtension.provideParams(logger: logger, host: host) }

        self.lspService = LSPService(host: host,
                                     serverOptions: Gopls.serverOptions,
                                     transformers: transformers,
									 executionParamsProvider: paramProvider)
    }
}

extension GoExtension: ExtensionProtocol {
	public var configuration: ExtensionConfiguration {
		return ExtensionConfiguration(
			contentFilter: [.uti(.goSource), .uti(.goModFile), .uti(.goWorkFile)],
			serviceConfiguration: ServiceConfiguration(completionTriggers: ["."])
		)
	}

	public var applicationService: ApplicationService {
		return lspService
	}
}

extension GoExtension {
    static let envKeys = Set(["GOPATH", "GOROOT", "GOBIN", "GOEXE", "GOTOOLDIR",
							 "PATH", "SHLVL", "TERM_PROGRAM", "PWD", "TERM_PROGRAM_VERSION", "SHELL", "TERM"])

	static let bundle: Bundle? = {
		// Determine if we are executing within the main application or an extension
		let mainBundle = Bundle.main

		if mainBundle.bundleURL.pathExtension == "appex" {
			return mainBundle
		}

		let bundleURL = mainBundle.bundleURL.appendingPathComponent("Contents/Extensions/GoExtension.appex", isDirectory: true)

		return Bundle(url: bundleURL)
	}()

	private static func provideParams(logger: Logger, host: HostProtocol) async throws -> Process.ExecutionParameters {
		let url = GoExtension.bundle?.url(forAuxiliaryExecutable: "gopls")

        guard let path = url?.path else {
			throw LSPServiceError.serverNotFound
        }

        let env = try await GoExtension.computeGoEnvironment(host: host)

		let printableEnv = env.filter({ envKeys.contains($0.key) })

		logger.info("Go environment: \(printableEnv, privacy: .public)")

        return Process.ExecutionParameters(path: path,
                                           arguments: ["-logfile=/tmp/gopls.txt"],
                                           environment: env)
    }
}

extension GoExtension {
    static func computeGoEnvironment(host: HostProtocol) async throws -> [String: String] {
		let userEnv = try await host.captureUserEnvironment()
		let env = try await captureGoEnvironment(environment: userEnv, host: host)
        let effectiveEnv = effectiveGoUserEnvironment(userEnv: userEnv, goEnv: env)

        return effectiveEnv
    }

    private static func effectiveGoUserEnvironment(userEnv: [String: String], goEnv: [String: String]) -> [String : String] {
        guard let goRoot = goEnv["GOROOT"] else {
            return userEnv
        }

        return userEnv.merging(["GOROOT": goRoot], uniquingKeysWith: { (a, _) in return a })
    }

    private static func captureGoEnvironment(environment: [String : String], host: HostProtocol) async throws -> [String : String] {
        let path = "/usr/bin/env"
        let args = ["go", "env", "-json"]
        let params = Process.ExecutionParameters(path: path, arguments: args, environment: environment)

		let data = try await host.launchProcess(with: params).readStdout()

        guard let dict = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return [:]
        }

        return dict as? [String : String] ?? [:]
    }

    private func findContainingURL(for url: URL, with environment: [String: String]) -> URL {
        // first, create a list of all the containing directories
        var parentURLs = [URL]()

        let components = url.pathComponents

        for i in 1..<components.count {
            let path = "/" + components[1..<i].joined(separator: "/")
            let parentURL = URL(fileURLWithPath: path, isDirectory: true)

            parentURLs.append(parentURL)
        }

        parentURLs.append(url)

        // then, check them in reverse order
        for parentURL in parentURLs.reversed() {
            let contents = try? FileManager.default.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil)
            let containsModFile = contents?.contains(where: { $0.lastPathComponent == "go.mod" }) ?? false

            if containsModFile {
				logger.info("found mod file: \(parentURL.absoluteString, privacy: .public)")
                return parentURL
            }
        }

        // fail, just return the parent directory
        let fallbackPath = url.deletingLastPathComponent()

		logger.info("falling back to parent directory: \(fallbackPath.absoluteString, privacy: .public)")

        return fallbackPath
    }
}
