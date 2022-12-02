import Foundation

import ChimeKit
import ProcessEnv

struct Gopls {
}

extension Gopls {
	struct ServerOptions: Codable {
		enum HoverKind: String, Codable {
			case FullDocumentation
			case NoDocumentation
			case SingleLine
			case Structured
			case SynopsisDocumentation
		}

		let usePlaceholders: Bool
		let completeUnimported: Bool
		let deepCompletion: Bool
		let hoverKind: HoverKind
		let semanticTokens: Bool
		let staticcheck: Bool
		let gofumpt: Bool
	}

	static var serverOptions: some Codable {
		let stackcheckEnabled = true
		let gofumptEnabled = true

		return ServerOptions(usePlaceholders: true,
							 completeUnimported: true,
							 deepCompletion: true,
							 hoverKind: .Structured,
							 semanticTokens: true,
							 staticcheck: stackcheckEnabled,
							 gofumpt: gofumptEnabled)
	}
}

extension Gopls {
	struct StructuredHover: Decodable {
		let signature: String
		let singleLine: String
		let synopsis: String
		let fullDocumentation: String
		let link: String?
		let SymbolName: String?

		var displayableValue: String {
			if !singleLine.isEmpty {
				return singleLine
			}

			if !signature.isEmpty {
				return signature
			}

			return SymbolName ?? "unknown"
		}

		static let empty = StructuredHover(signature: "", singleLine: "", synopsis: "", fullDocumentation: "", link: nil, SymbolName: nil)
	}

	static let hoverTransformer: HoverTransformer = { position, response in
		guard
			let response = response,
			let hoverValue = response.value,
			let struturedData = hoverValue.data(using: .utf8),
			let structure = try? JSONDecoder().decode(StructuredHover.self, from: struturedData)
		else {
			return LSPTransformers.standardHoverTransformer(position, response)
		}

		let textRange: ChimeKit.TextRange

		if let range = response.range {
			textRange = .lineRelativeRange(LineRelativeTextRange(range))
		} else {
			textRange = .range(NSRange(location: position.location, length: 0))
		}

		return SemanticDetails(textRange: textRange,
							   synopsis: structure.synopsis,
							   declaration: structure.signature,
							   documentation: structure.fullDocumentation)
	}
}
