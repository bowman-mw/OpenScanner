//
//  SafariWebExtensionHandler.swift
//  Rescriva Safari extension
//
//  The extension's native half. Its scripts call browser.runtime.sendNativeMessage; each
//  message lands here and becomes a write into the Inbox in the App Group container
//  (InboxMessage.swift), which the app imports. Nothing heavy happens here: app extensions get
//  little memory, so OCR, rebuilding and comparing stay in the app.
//

import Foundation
import SafariServices
import os

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
	private let log = Logger(subsystem: "MBO.Scanner.SafariExtension", category: "Inbox")

	func beginRequest(with context: NSExtensionContext) {
		let request = context.inputItems.first as? NSExtensionItem
		let message = request?.userInfo?[SFExtensionMessageKey]
		let drop = InboxDrop.shared
		if drop == nil {
			log.error("The app group container isn't available; is the extension signed with group.MBO.Scanner?")
		}
		let reply = InboxMessage.respond(to: message, drop: drop)
		if reply["ok"] as? Bool != true {
			log.error("Hand-off failed: \(String(describing: reply["error"]), privacy: .public)")
		}
		let response = NSExtensionItem()
		response.userInfo = [SFExtensionMessageKey: reply]
		context.completeRequest(returningItems: [response], completionHandler: nil)
	}
}
