//
//  AppleIntelligence.swift
//  Rescriva (fork of Open Scanner)
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

	/// Most uncertain words the model is asked about in one document, in reading order. A long,
	/// technical document can have well over a thousand, at up to a second each; the rest keep
	/// Vision's options, still open on the review screen.
	static let maxQuestions = 60

	/// Longest the model may spend on one document's questions, however many are left.
	static let rerankBudget: Duration = .seconds(45)

	/// Moves the model's choice to the front of each open word flag's options
	/// and marks it "most likely". Leaves the document unchanged when the model
	/// is unavailable, slow or unsure, and stops after `maxQuestions`, once `rerankBudget` is
	/// spent or when the task is cancelled. `progress` is called with how many questions are done.
	static func rerankFlags(in document: RescrivaDocument,
							progress: @MainActor (_ done: Int, _ total: Int) -> Void = { _, _ in }) async -> RescrivaDocument {
		#if canImport(FoundationModels)
		guard #available(iOS 26.0, *), isAvailable else { return document }
		var questions = Self.questions(for: document)
		var result = document
		await progress(0, questions.total)
		for pageIndex in result.pages.indices where !questions.isSpent {
			for blockIndex in result.pages[pageIndex].blocks.indices where !questions.isSpent {
				var content = result.pages[pageIndex].blocks[blockIndex].content
				let sentence = content.plainText
				let askedBefore = questions.asked
				content = await rerank(content, sentence: sentence, questions: &questions)
				result.pages[pageIndex].blocks[blockIndex].content = content
				if questions.asked > askedBefore {
					await progress(questions.asked, questions.total)
				}
			}
		}
		return result
		#else
		return document
		#endif
	}

	/// The questions `rerankFlags` will ask about `document`, starting now.
	static func questions(for document: RescrivaDocument) -> Questions {
		Questions(total: min(openWordFlags(in: document), maxQuestions), deadline: .now + rerankBudget)
	}

	/// Open word flags in `document`.
	static func openWordFlags(in document: RescrivaDocument) -> Int {
		var count = 0
		for page in document.pages {
			for block in page.blocks {
				var content = block.content
				content.mapRuns { runs in
					count += runs.filter { $0.flag?.kind == .word && $0.flag?.resolution == nil }.count
					return runs
				}
			}
		}
		return count
	}

	/// How many questions have been asked of how many, and until when there's time to ask.
	struct Questions {
		let total: Int
		let deadline: ContinuousClock.Instant
		var asked = 0

		var isSpent: Bool { Task.isCancelled || ContinuousClock.now >= deadline || asked >= total }
	}

	#if canImport(FoundationModels)
	@available(iOS 26.0, *)
	private static func rerank(_ content: BlockContent, sentence: String, questions: inout Questions) async -> BlockContent {
		switch content {
		case .heading(let level, let runs):
			return .heading(level: level, runs: await rerank(runs, sentence: sentence, questions: &questions))
		case .paragraph(let runs, let alignment):
			return .paragraph(runs: await rerank(runs, sentence: sentence, questions: &questions), alignment: alignment)
		case .list(let style, let items):
			var updated = items
			for index in updated.indices where !questions.isSpent {
				updated[index].runs = await rerank(updated[index].runs, sentence: updated[index].runs.plainText, questions: &questions)
			}
			return .list(style: style, items: updated)
		default:
			return content
		}
	}

	@available(iOS 26.0, *)
	private static func rerank(_ runs: [RescrivaRun], sentence: String, questions: inout Questions) async -> [RescrivaRun] {
		var updated = runs
		for index in updated.indices where !questions.isSpent {
			guard var flag = updated[index].flag, flag.kind == .word, flag.resolution == nil else { continue }
			questions.asked += 1
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
