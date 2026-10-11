//
//  AppleIntelligence.swift
//  Folio (fork of Open Scanner)
//
//  Tier 2 of the rebuild: the on-device Foundation Models language model
//  picks the most likely reading for each uncertain word from context.
//  Text only — image input needs iOS 27 — and nothing leaves the phone.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, when this iPhone has it.
enum AppleIntelligence {
	static var isAvailable: Bool {
		#if canImport(FoundationModels)
		if #available(iOS 26.0, *) {
			return SystemLanguageModel.default.isAvailable
		}
		#endif
		return false
	}

	/// Moves the model's choice to the front of each open word flag's options
	/// and marks it "most likely". Leaves the document unchanged when the model
	/// is unavailable, slow or unsure.
	static func rerankFlags(in document: FolioDocument) async -> FolioDocument {
		#if canImport(FoundationModels)
		guard #available(iOS 26.0, *), isAvailable else { return document }
		var result = document
		for pageIndex in result.pages.indices {
			for blockIndex in result.pages[pageIndex].blocks.indices {
				var content = result.pages[pageIndex].blocks[blockIndex].content
				let sentence = content.plainText
				content = await rerank(content, sentence: sentence)
				result.pages[pageIndex].blocks[blockIndex].content = content
			}
		}
		return result
		#else
		return document
		#endif
	}

	#if canImport(FoundationModels)
	@available(iOS 26.0, *)
	private static func rerank(_ content: BlockContent, sentence: String) async -> BlockContent {
		switch content {
		case .heading(let level, let runs):
			return .heading(level: level, runs: await rerank(runs, sentence: sentence))
		case .paragraph(let runs, let alignment):
			return .paragraph(runs: await rerank(runs, sentence: sentence), alignment: alignment)
		case .list(let style, let items):
			var updated = items
			for index in updated.indices {
				updated[index].runs = await rerank(updated[index].runs, sentence: updated[index].runs.plainText)
			}
			return .list(style: style, items: updated)
		default:
			return content
		}
	}

	@available(iOS 26.0, *)
	private static func rerank(_ runs: [FolioRun], sentence: String) async -> [FolioRun] {
		var updated = runs
		for index in updated.indices {
			guard var flag = updated[index].flag, flag.kind == .word, flag.resolution == nil else { continue }
			// The reading itself is a candidate: if the model backs it, the flag goes away.
			var candidates = flag.options.map(\.label)
			if !candidates.contains(flag.read) { candidates.append(flag.read) }
			guard let choice = await mostLikely(read: flag.read, candidates: candidates, sentence: sentence) else { continue }
			if choice == flag.read {
				updated[index].flag = nil
				continue
			}
			guard let position = flag.options.firstIndex(where: { $0.label.caseInsensitiveCompare(choice) == .orderedSame }) else { continue }
			var option = flag.options.remove(at: position)
			option.note = String(localized: "most likely")
			flag.options.insert(option, at: 0)
			updated[index].flag = flag
		}
		return updated
	}

	@available(iOS 26.0, *)
	private static func mostLikely(read: String, candidates: [String], sentence: String) async -> String? {
		let session = LanguageModelSession(instructions: """
			You fix handwriting-recognition mistakes. Given a sentence, a word the recognizer \
			was unsure about and candidate readings, reply with exactly one candidate, nothing else.
			""")
		let prompt = """
			Sentence: \(sentence)
			Unsure word: \(read)
			Candidates: \(candidates.joined(separator: ", "))
			"""
		do {
			let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0))
			let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
			return candidates.first { $0.caseInsensitiveCompare(answer) == .orderedSame }
		} catch {
			return nil
		}
	}
	#endif
}
