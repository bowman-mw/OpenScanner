//
//  RecognizedLine.swift
//  Rescriva (fork of Open Scanner)
//
//  One line of recognized text — what Vision read, how sure it was, what
//  else it considered and where the line sits. Foundation/CoreGraphics only,
//  so the rebuild detectors can be exercised off-device.
//

import CoreGraphics
import Foundation

/// One line of recognized text.
struct RecognizedLine: Sendable, Hashable {
	var text: String
	var confidence: Float
	/// Other readings Vision considered, most likely first.
	var alternatives: [String]
	/// Normalized page rectangle, top-left origin.
	var box: CGRect
}
