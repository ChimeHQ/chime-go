import Foundation
import os.log

import ChimeKit
import LanguageServerProtocol
import ProcessServiceClient

public final class GoExtension {
    private let host: any HostProtocol
    private let lspService: LSPService
    private let log: OSLog

    init(host: any HostProtocol, processHostServiceName: String) {
        self.host = host
        let log = OSLog(subsystem: "com.chimehq.Edit.Go", category: "GoExtension")

        self.log = log

        let transformers = LSPTransformers(hoverTransformer: Gopls.hoverTransformer)
		let paramProvider = { try await GoExtension.provideParams(log: log, processHostServiceName: processHostServiceName) }

        self.lspService = LSPService(host: host,
                                     serverOptions: Gopls.serverOptions,
                                     transformers: transformers,
									 executionParamsProvider: paramProvider,
									 processHostServiceName: processHostServiceName)
    }
}

extension GoExtension: ExtensionProtocol {
	public var configuration: ExtensionConfiguration {
		get async throws {
			return ExtensionConfiguration(contentFilter: [.uti(.goSource), .uti(.goModFile), .uti(.goWorkFile)])
		}
	}

    public func didOpenProject(with context: ProjectContext) async throws {
        try await lspService.didOpenProject(with: context)
    }

    public func willCloseProject(with context: ProjectContext) async throws {
        try await lspService.willCloseProject(with: context)
    }

    public func symbolService(for context: ProjectContext) async throws -> SymbolQueryService? {
        return try await lspService.symbolService(for: context)
    }

    public func didOpenDocument(with context: DocumentContext) async throws -> URL? {
        return try await lspService.didOpenDocument(with: context)
    }

    public func didChangeDocumentContext(from oldContext: DocumentContext, to newContext: DocumentContext) async throws {
        return try await lspService.didChangeDocumentContext(from: oldContext, to: newContext)
    }

    public func willCloseDocument(with context: DocumentContext) async throws {
        return try await lspService.willCloseDocument(with: context)
    }

    public func documentService(for context: DocumentContext) async throws -> DocumentService? {
        return try await lspService.documentService(for: context)
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

	private static func provideParams(log: OSLog, processHostServiceName: String) async throws -> Process.ExecutionParameters {
		let url = GoExtension.bundle?.url(forAuxiliaryExecutable: "gopls")

        guard let path = url?.path else {
			throw LSPServiceError.serverNotFound
        }

        let env = try await GoExtension.computeGoEnvironment(processHostServiceName: processHostServiceName)

		let printableEnv = env.filter({ envKeys.contains($0.key) })

        os_log("Go environment: %{public}@", log: log, type: .info, printableEnv)

        return Process.ExecutionParameters(path: path,
                                           arguments: [],
                                           environment: env)
    }
}

extension GoExtension {
    static func computeGoEnvironment(processHostServiceName: String) async throws -> [String: String] {
		let userEnv = try await HostedProcess.userEnvironment(with: processHostServiceName)
		let env = try await captureGoEnvironment(environment: userEnv, processHostServiceName: processHostServiceName)
        let effectiveEnv = effectiveGoUserEnvironment(userEnv: userEnv, goEnv: env)

        return effectiveEnv
    }

    private static func effectiveGoUserEnvironment(userEnv: [String: String], goEnv: [String: String]) -> [String : String] {
        guard let goRoot = goEnv["GOROOT"] else {
            return userEnv
        }

        return userEnv.merging(["GOROOT": goRoot], uniquingKeysWith: { (a, _) in return a })
    }

    private static func captureGoEnvironment(environment: [String : String], processHostServiceName: String) async throws -> [String : String] {
        let path = "/usr/bin/env"
        let args = ["go", "env", "-json"]
        let params = Process.ExecutionParameters(path: path, arguments: args, environment: environment)

		let data = try await HostedProcess(named: processHostServiceName, parameters: params).runAndReadStdout()

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
                os_log("found mod file at %{public}@", log: log, type: .info, parentURL.absoluteString)
                return parentURL
            }
        }

        // fail, just return the parent directory
        let fallbackPath = url.deletingLastPathComponent()

        os_log("falling back to parent directory %{public}@", log: log, type: .info, fallbackPath.absoluteString)

        return fallbackPath
    }

	private static func projectRoot(at url: URL) -> Bool {
		let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.absoluteURL.path)) ?? []

		if contents.contains(where: { $0 == "go.mod" || $0.hasSuffix(".go") }) {
			return true
		}

		// this also needs to check to see if we are within the GOPATH
		
		return false
	}
}
