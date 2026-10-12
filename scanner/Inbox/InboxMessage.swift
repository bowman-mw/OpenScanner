//
//  InboxMessage.swift
//  Folio (fork of Open Scanner)
//
//  The Safari extension's native messages: what its scripts send with
//  browser.runtime.sendNativeMessage, and what SafariWebExtensionHandler answers. Every reply
//  has "ok"; a failure adds "error", a sentence the popup shows as it is.
//
//      {action: "begin", kind: "pdf" | "webPage", title, sourceURL}   → {ok, id}
//      {action: "append", id, data: <base64 piece>}                     → {ok, bytes}
//      {action: "commit", id}                                           → {ok}
//      {action: "cancel", id}                                           → {ok}
//      {action: "link", title, sourceURL}                               → {ok, id}
//
//  Shared by the app (tests) and the Safari extension.
//

import Foundation

enum InboxMessage {
	/// The longest base64 piece one message may carry (a 1 MB piece is about 1.4 MB of base64).
	static let maxPieceCharacters = 4 * 1024 * 1024

	/// Answers one message from the extension's scripts. `drop` is nil when the app group isn't there.
	static func respond(to message: Any?, drop: InboxDrop?) -> [String: Any] {
		guard let fields = message as? [String: Any], let action = fields["action"] as? String else {
			return failure(String(localized: "Folio didn't understand that request."))
		}
		guard let drop else { return failure(InboxDropError.unavailable) }
		do {
			return try perform(action, fields, drop: drop)
		} catch {
			return failure(error)
		}
	}

	private static func perform(_ action: String, _ fields: [String: Any], drop: InboxDrop) throws -> [String: Any] {
		switch action {
		case "begin":
			guard let kind = (fields["kind"] as? String).flatMap(InboxManifest.Kind.init(rawValue:)) else {
				throw InboxDropError.unknownHandOff
			}
			let id = try drop.begin(kind, title: title(fields), sourceURL: sourceURL(fields))
			return ["ok": true, "id": id.uuidString]
		case "append":
			guard let base64 = fields["data"] as? String else { throw InboxDropError.unknownHandOff }
			guard base64.utf8.count <= maxPieceCharacters else { throw InboxDropError.tooLarge }
			guard let data = Data(base64Encoded: base64) else { throw InboxDropError.unknownHandOff }
			return ["ok": true, "bytes": try drop.append(data, to: id(fields))]
		case "commit":
			try drop.commit(id(fields))
			return ["ok": true]
		case "cancel":
			drop.cancel(try id(fields))
			return ["ok": true]
		case "link":
			guard let url = sourceURL(fields) else { throw InboxDropError.notAWebAddress }
			let id = try drop.dropLink(url, title: title(fields))
			return ["ok": true, "id": id.uuidString]
		default:
			return failure(String(localized: "Folio didn't understand that request."))
		}
	}

	private static func id(_ fields: [String: Any]) throws -> UUID {
		guard let text = fields["id"] as? String, let id = UUID(uuidString: text) else { throw InboxDropError.unknownHandOff }
		return id
	}

	private static func title(_ fields: [String: Any]) -> String {
		(fields["title"] as? String) ?? ""
	}

	private static func sourceURL(_ fields: [String: Any]) -> URL? {
		guard let text = fields["sourceURL"] as? String, !text.isEmpty else { return nil }
		return URL(string: text)
	}

	private static func failure(_ error: Error) -> [String: Any] {
		failure((error as? LocalizedError)?.errorDescription ?? String(localized: "Folio couldn't take that."))
	}

	private static func failure(_ message: String) -> [String: Any] {
		["ok": false, "error": message]
	}
}
