//
//  ViewExtensions.swift
//  Open Scanner
//
//  Created by Slaven Radic on 2024-09-01.
//

import Foundation
import SwiftUI
import UIKit
import ImageIO

public extension Color {
	
	static let background = Color("background")
	static let foreground = Color("foreground")
	static let accent = Color("accent")
	
	
	init(hex: UInt, alpha: Double = 1) {
		self.init(
			.sRGB,
			red: Double((hex >> 16) & 0xff) / 255,
			green: Double((hex >> 08) & 0xff) / 255,
			blue: Double((hex >> 00) & 0xff) / 255,
			opacity: alpha
		)
	}
}

var DefaultBackgroundGradient: LinearGradient {
	LinearGradient(
		colors: [
			Color("gradientMainTop"),
			Color("gradientMainBottom")],
		startPoint: .topLeading,
		endPoint: .bottomTrailing)
	
}

func getDocumentsDirectory() -> URL {
	let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
	return paths[0]
}

func getTemporaryDirectory() -> URL {
	let previewURL = FileManager.default.temporaryDirectory.appendingPathComponent("Document")
	return previewURL
}

extension Animation {
	func `repeat`(while expression: Bool, autoreverses: Bool = true) -> Animation {
		if expression {
			return self.repeatForever(autoreverses: autoreverses)
		} else {
			return self
		}
	}
}

extension UIImage {
	
	var aspectRatio: CGFloat {
		size.width / size.height
	}
	
	func resizeToWidth(_ width: CGFloat) -> UIImage {
		
		// Determine the scale factor that preserves aspect ratio
		let ratio = size.width / size.height
		let height = width / ratio
		
		// Compute the new image size that preserves aspect ratio
		let scaledImageSize = CGSize(
			width: width,
			height: height
		)
		
		// Draw and return the resized UIImage
		
		let format = UIGraphicsImageRendererFormat()
		format.scale = 1
		
		let renderer = UIGraphicsImageRenderer(size: scaledImageSize, format: format)
		
		let scaledImage = renderer.image { _ in
			self.draw(in: CGRect(
				origin: .zero,
				size: scaledImageSize
			))
		}
		
		return scaledImage
	}
	
	func resize(newSize: CGSize) -> UIImage? {
		let renderer = UIGraphicsImageRenderer(size: newSize)
		return renderer.image { (context) in
			self.draw(in: CGRect(origin: .zero, size: newSize))
		}
	}
	
}

struct FlippedUpsideDown: ViewModifier {
	func body(content: Content) -> some View {
		content
			.rotationEffect(.radians(CGFloat.pi))
			.scaleEffect(x: -1, y: 1, anchor: .center)
	}
}
extension View {
	func flippedUpsideDown() -> some View{
		self.modifier(FlippedUpsideDown())
	}
}

extension String {
	func truncate(to limit: Int) -> String {
		if count > limit {
			let truncated = String(prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
			return truncated + "\u{2026}"
		} else {
			return self
		}
	}
	
	func sanitized() -> String {
		// see for ressoning on charachrer sets https://superuser.com/a/358861
		let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
			.union(.newlines)
			.union(.illegalCharacters)
			.union(.controlCharacters)
		
		return String(
			self
				.components(separatedBy: invalidCharacters)
				.joined(separator: "")
				.prefix(50)
		)
	}
	
	mutating func sanitize() -> Void {
		self = self.sanitized()
	}
	
	func whitespaceCondensed() -> String {
		return self.components(separatedBy: .whitespacesAndNewlines)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}
	
	mutating func condenseWhitespace() -> Void {
		self = self.whitespaceCondensed()
	}
}

extension View {
	/// Applies the given transform if the given condition evaluates to `true`.
	/// - Parameters:
	///   - condition: The condition to evaluate.
	///   - transform: The transform to apply to the source `View`.
	/// - Returns: Either the original `View` or the modified `View` if the condition is `true`.
	@ViewBuilder func `if`<Content: View>(_ condition: @autoclosure () -> Bool, transform: (Self) -> Content) -> some View {
		if condition() {
			transform(self)
		} else {
			self
		}
	}
}
