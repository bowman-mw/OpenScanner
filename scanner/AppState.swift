//
//  AppState.swift
//  Open Scanner
//
//  Created by Slaven Radic on 2024-09-01.
//

import Foundation
import AppIntents
import CoreData
import AVFoundation
import CoreLocation
#if canImport(CoreLocationUI)
import CoreLocationUI
#endif
import SwiftUI

enum ViewState: String {
	case Home, Page, About
}

extension ViewState: AppEnum {
	static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scanner mode"

	static let caseDisplayRepresentations: [ViewState: DisplayRepresentation] = [
		.Home: "Scan List",
		.Page: "Scan Now",
		.About: "Folio settings",
	]
}

class AppState: ObservableObject {
	
	public static let shared = AppState()
	var locationManager = LocationManager()
	
	@Published var viewState = ViewState.Home {
		didSet {
			stopSpeaking()
		}
	}
	
	@Published var openScan: Scan?
	@Published var openRecognizedItem: ScanRecognizedItem?
	
	private let speechSynthesizer = AVSpeechSynthesizer()
	
	var lastScanIndex: Int {
		
		let request = Scan.fetchRequest()
		do {
			let scans = try PersistenceController.shared.container.viewContext.fetch(request)
			return scans.count - 1
		} catch {
			print("Fetch failed")
		}
		
		return 0
	}
	
	func speak(text: String?) {
		guard let text = text else { return }
		
		if speechSynthesizer.isSpeaking {
			speechSynthesizer.stopSpeaking(at: .immediate)
		}
		let utterance = AVSpeechUtterance(string: text)
		utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

		speechSynthesizer.speak(utterance)
	}
	
	var isSpeaking: Bool {
		return speechSynthesizer.isSpeaking
	}
	
	func stopSpeaking() {
		if speechSynthesizer.isSpeaking {
			speechSynthesizer.stopSpeaking(at: .word)
		}
	}
}


class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
	let manager = CLLocationManager()

	@Published var location: CLLocationCoordinate2D?
	private var locations: [CLLocation] = [CLLocation]()

	override init() {
		super.init()
		manager.delegate = self
	}

	func requestLocation() {
		manager.requestWhenInUseAuthorization()
		locationManager(manager, didUpdateLocations: locations)
	}
	
	func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
		location = locations.first?.coordinate
	}
	
	var myLocation: CLLocation? {
		return manager.location
	}
}
