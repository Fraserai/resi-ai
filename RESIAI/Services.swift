import Foundation
import CoreLocation
import AVFoundation
import UIKit

protocol LocationServiceProtocol: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    func requestPermission()
    func startUpdating()
    func stopUpdating()
    func currentSnapshot() -> LocationSnapshot?
}

protocol CameraServiceProtocol: AnyObject {
    var isFlashEnabled: Bool { get set }
    var previewLayer: AVCaptureVideoPreviewLayer { get }
    func requestAccess() async -> Bool
    func configureSession() throws
    func startSession()
    func stopSession()
    func capturePhoto() async throws -> Data
}

protocol PropertyDataProviderProtocol {
    func nearbyProperties(around coordinate: CLLocationCoordinate2D, radiusMeters: Double) async -> [Property]
    func searchProperties(query: String, around coordinate: CLLocationCoordinate2D?) async -> [Property]
    func property(with id: UUID, near coordinate: CLLocationCoordinate2D?) async -> Property?
}

protocol PropertyMatcherProtocol {
    func match(location: LocationSnapshot, capturedImage: Data?) async -> MatchResult
}

protocol GeocodingServiceProtocol {
    func reverseGeocode(location: LocationSnapshot) async throws -> ReverseGeocodeResult
}

protocol PhotoStorageServiceProtocol {
    func savePhotoData(_ data: Data) throws -> String
    func loadImage(named filename: String) -> UIImage?
    func deleteAllPhotos() throws
}

protocol AISummaryServiceProtocol {
    func summaryPoints(for property: Property) -> [String]
    func respond(to question: String, property: Property) -> String
}

final class LocationService: NSObject, LocationServiceProtocol {
    private let manager = CLLocationManager()
    private var latestLocation: CLLocation?
    private var latestHeading: CLHeading?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.headingFilter = 5
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func startUpdating() {
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else {
            return
        }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func currentSnapshot() -> LocationSnapshot? {
        guard let latestLocation else {
            return nil
        }

        let heading = latestHeading?.trueHeading ?? latestHeading?.magneticHeading
        let cleanHeading = heading != nil && heading! >= 0 ? heading : nil
        return LocationSnapshot(
            latitude: latestLocation.coordinate.latitude,
            longitude: latestLocation.coordinate.longitude,
            accuracyMeters: max(1, latestLocation.horizontalAccuracy),
            headingDegrees: cleanHeading
        )
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            startUpdating()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latestLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        latestHeading = newHeading
    }
}

enum CameraServiceError: Error {
    case unavailable
    case notConfigured
    case captureFailed
}

final class AVFoundationCameraService: NSObject, CameraServiceProtocol {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "resi.ai.camera.session")
    private var isConfigured = false
    private var captureContinuation: CheckedContinuation<Data, Error>?

    var isFlashEnabled: Bool = false

    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    func configureSession() throws {
        guard !isConfigured else {
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            throw CameraServiceError.unavailable
        }

        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            throw CameraServiceError.unavailable
        }

        session.addOutput(photoOutput)
        photoOutput.isHighResolutionCaptureEnabled = true

        session.commitConfiguration()
        isConfigured = true
    }

    func startSession() {
        guard isConfigured else {
            return
        }
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stopSession() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func capturePhoto() async throws -> Data {
        guard isConfigured else {
            throw CameraServiceError.notConfigured
        }

        let settings = AVCapturePhotoSettings()
        settings.flashMode = isFlashEnabled ? .on : .off
        settings.isHighResolutionPhotoEnabled = true

        return try await withCheckedThrowingContinuation { continuation in
            captureContinuation = continuation
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension AVFoundationCameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            captureContinuation?.resume(throwing: error)
            captureContinuation = nil
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            captureContinuation?.resume(throwing: CameraServiceError.captureFailed)
            captureContinuation = nil
            return
        }

        captureContinuation?.resume(returning: data)
        captureContinuation = nil
    }
}

final class MockPropertyDataProvider: PropertyDataProviderProtocol {
    // TODO: Swap this mock provider for a real property data source adapter.
    private let baseCoordinate = CLLocationCoordinate2D(latitude: -27.4698, longitude: 153.0556)
    private let baseSuburb = "New Farm"
    private lazy var fixedProperties: [Property] = makeFixedProperties()

    func nearbyProperties(around coordinate: CLLocationCoordinate2D, radiusMeters: Double) async -> [Property] {
        let source = sourceProperties(near: coordinate)
        let userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return source.filter { property in
            let propertyLocation = CLLocation(latitude: property.latitude, longitude: property.longitude)
            return userLocation.distance(from: propertyLocation) <= radiusMeters
        }
    }

    func searchProperties(query: String, around coordinate: CLLocationCoordinate2D?) async -> [Property] {
        let source = sourceProperties(near: coordinate)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(source.prefix(20))
        }

        let normalized = query.lowercased()
        return source.filter { property in
            property.addressLine.lowercased().contains(normalized)
            || property.suburb.lowercased().contains(normalized)
            || property.postcode.contains(normalized)
        }
    }

    func property(with id: UUID, near coordinate: CLLocationCoordinate2D?) async -> Property? {
        sourceProperties(near: coordinate).first { $0.id == id }
    }

    private func sourceProperties(near coordinate: CLLocationCoordinate2D?) -> [Property] {
        guard let coordinate else {
            return fixedProperties
        }

        let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let anchor = CLLocation(latitude: baseCoordinate.latitude, longitude: baseCoordinate.longitude)

        if current.distance(from: anchor) > 35_000 {
            return makeDemoProperties(around: coordinate)
        }

        return fixedProperties
    }

    private func makeFixedProperties() -> [Property] {
        let addresses = [
            "12 Brunswick St", "18 Merthyr Rd", "27 Sydney St", "55 Harcourt St", "3 Heal St",
            "88 Oxlade Dr", "21 Bowen Tce", "7 Annie St", "34 Kent St", "69 Moray St",
            "5 Villiers St", "41 James St", "90 Barker St", "14 Welsby St", "73 Lamington St",
            "26 Berwick St", "48 Moreton St", "102 Terrace St", "11 Griffith St", "63 Maxwell St",
            "2 Sargent St", "77 Farm St", "15 Dixon St", "29 Browne St", "39 Cutter St",
            "58 Arthur St", "66 Elysium Rd", "84 Crescent Rd", "91 Prospect St", "109 River View St"
        ]

        return addresses.enumerated().map { index, address in
            let north = Double((index / 6) * 28 - 60)
            let east = Double((index % 6) * 24 - 60)
            let coord = offsetCoordinate(from: baseCoordinate, northMeters: north, eastMeters: east)
            let beds = 2 + (index % 4)
            let baths = 1 + (index % 3)
            let land = 210 + (index * 14)
            let lowValue = 680_000 + (index * 35_000)
            let highValue = lowValue + 110_000
            let rent = 530 + (index * 9)
            return Property(
                id: UUID(),
                addressLine: address,
                suburb: baseSuburb,
                state: "QLD",
                postcode: "4005",
                country: "Australia",
                latitude: coord.latitude,
                longitude: coord.longitude,
                propertyType: index % 3 == 0 ? "House" : "Unit",
                bedrooms: beds,
                bathrooms: baths,
                landSizeSqm: land,
                yearBuilt: 1970 + (index % 40),
                estValueLow: lowValue,
                estValueHigh: highValue,
                lastSalePrice: lowValue - 95_000,
                lastSaleDate: Calendar.current.date(byAdding: .year, value: -(index % 8 + 1), to: .now) ?? .now,
                rentEstimateWeekly: rent,
                grossYieldPct: Double.random(in: 2.8...5.6),
                flags: flags(for: index),
                dataQuality: "Enriched mock",
                dataSources: ["MockPropertyDataProvider"],
                lastRefreshed: .now
            )
        }
    }

    private func makeDemoProperties(around coordinate: CLLocationCoordinate2D) -> [Property] {
        (0..<30).map { index in
            let north = Double((index / 6) * 22 - 48)
            let east = Double((index % 6) * 20 - 50)
            let coord = offsetCoordinate(from: coordinate, northMeters: north, eastMeters: east)
            let streetNo = 10 + index
            let streetName = ["Example", "Sample", "Harbor", "View", "Oak", "River"][index % 6]
            return Property(
                id: UUID(),
                addressLine: "\(streetNo) \(streetName) St",
                suburb: "Demo",
                state: "QLD",
                postcode: "4000",
                country: "Australia",
                latitude: coord.latitude,
                longitude: coord.longitude,
                propertyType: index % 2 == 0 ? "House" : "Townhouse",
                bedrooms: 2 + (index % 3),
                bathrooms: 1 + (index % 2),
                landSizeSqm: 180 + index * 10,
                yearBuilt: 1985 + (index % 30),
                estValueLow: 610_000 + index * 22_000,
                estValueHigh: 730_000 + index * 22_000,
                lastSalePrice: 560_000 + index * 18_500,
                lastSaleDate: Calendar.current.date(byAdding: .year, value: -(index % 6 + 1), to: .now) ?? .now,
                rentEstimateWeekly: 520 + index * 7,
                grossYieldPct: Double.random(in: 3.1...5.0),
                flags: flags(for: index),
                dataQuality: "Demo synthetic",
                dataSources: ["MockPropertyDataProvider"],
                lastRefreshed: .now
            )
        }
    }

    private func flags(for index: Int) -> [String] {
        [
            index % 2 == 0 ? "Flood overlay: Medium" : "Flood overlay: Low",
            index % 3 == 0 ? "Bushfire: Not mapped" : "Bushfire: Low",
            index % 4 == 0 ? "Strata: No" : "Strata: Yes",
            index % 5 == 0 ? "Zoning: Mixed residential" : "Zoning: Low-medium density"
        ]
    }

    private func offsetCoordinate(from base: CLLocationCoordinate2D,
                                  northMeters: Double,
                                  eastMeters: Double) -> CLLocationCoordinate2D {
        let latDelta = northMeters / 111_111
        let lonDelta = eastMeters / (111_111 * cos(base.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: base.latitude + latDelta, longitude: base.longitude + lonDelta)
    }
}

final class PropertyMatcher: PropertyMatcherProtocol {
    private let dataProvider: PropertyDataProviderProtocol

    init(dataProvider: PropertyDataProviderProtocol) {
        self.dataProvider = dataProvider
    }

    func match(location: LocationSnapshot, capturedImage: Data?) async -> MatchResult {
        let radius = max(75, location.accuracyMeters * 1.2)
        let userCoordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        let candidates = await dataProvider.nearbyProperties(around: userCoordinate, radiusMeters: radius)

        guard !candidates.isEmpty else {
            return MatchResult(rankedCandidates: [], overallConfidence: 0)
        }

        let userLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
        let heading = location.headingDegrees

        let scored = candidates.map { property -> MatchCandidate in
            let target = CLLocation(latitude: property.latitude, longitude: property.longitude)
            let distance = userLocation.distance(from: target)
            var score = 1.0 / (1.0 + distance)

            if let heading {
                let bearing = bearingDegrees(from: userCoordinate, to: property.coordinate)
                let delta = angularDifference(a: heading, b: bearing)
                if delta <= 45 {
                    score += 0.15
                }
            }

            score = min(1, max(0, score))
            return MatchCandidate(
                property: property,
                confidence: 0,
                distanceMeters: distance,
                directionString: compassDirection(from: userCoordinate, to: property.coordinate),
                rawScore: score
            )
        }
        .sorted { $0.rawScore > $1.rawScore }

        guard let top = scored.first else {
            return MatchResult(rankedCandidates: [], overallConfidence: 0)
        }

        let topScore = max(0.000_001, top.rawScore)
        let secondScore = scored.dropFirst().first?.rawScore ?? 0
        let overallConfidence = min(1, max(0, topScore / (topScore + secondScore)))

        let normalized = scored.map { item in
            MatchCandidate(
                property: item.property,
                confidence: min(1, max(0, item.rawScore / topScore)),
                distanceMeters: item.distanceMeters,
                directionString: item.directionString,
                rawScore: item.rawScore
            )
        }

        return MatchResult(rankedCandidates: normalized, overallConfidence: overallConfidence)
    }

    private func angularDifference(a: Double, b: Double) -> Double {
        let delta = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(delta, 360 - delta)
    }

    private func bearingDegrees(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude.radians
        let lon1 = from.longitude.radians
        let lat2 = to.latitude.radians
        let lon2 = to.longitude.radians

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    private func compassDirection(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> String {
        let bearing = bearingDegrees(from: from, to: to)
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((bearing + 22.5) / 45.0) % directions.count
        return directions[index]
    }
}

final class ReverseGeocodeService: GeocodingServiceProtocol {
    private let geocoder = CLGeocoder()

    func reverseGeocode(location: LocationSnapshot) async throws -> ReverseGeocodeResult {
        let clLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
            altitude: 0,
            horizontalAccuracy: location.accuracyMeters,
            verticalAccuracy: -1,
            timestamp: .now
        )

        let placemarks = try await geocoder.reverseGeocodeLocation(clLocation)
        guard let placemark = placemarks.first else {
            throw CLError(.geocodeFoundNoResult)
        }

        let streetNumber = placemark.subThoroughfare?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let street = (placemark.thoroughfare ?? placemark.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lineParts = [streetNumber, street].filter { !$0.isEmpty }
        let addressLine = lineParts.isEmpty ? "Unknown address" : lineParts.joined(separator: " ")
        let suburb = placemark.locality ?? placemark.subLocality ?? "Unknown suburb"
        let state = placemark.administrativeArea ?? "Unknown state"
        let postcode = placemark.postalCode ?? ""
        let country = placemark.country

        var confidence = confidenceFromAccuracy(location.accuracyMeters)
        if addressLine == "Unknown address" {
            confidence *= 0.7
        }

        return ReverseGeocodeResult(
            addressLine: addressLine,
            suburb: suburb,
            state: state,
            postcode: postcode,
            country: country,
            latitude: location.latitude,
            longitude: location.longitude,
            confidence: min(1, max(0, confidence)),
            accuracyMeters: location.accuracyMeters
        )
    }

    private func confidenceFromAccuracy(_ accuracy: Double) -> Double {
        switch accuracy {
        case ...10:
            return 0.96
        case ...20:
            return 0.9
        case ...35:
            return 0.82
        case ...60:
            return 0.74
        case ...100:
            return 0.62
        default:
            return 0.48
        }
    }
}

final class PhotoStorageService: PhotoStorageServiceProtocol {
    private let fileManager = FileManager.default
    private let folderName = "ScanPhotos"

    func savePhotoData(_ data: Data) throws -> String {
        let filename = "\(UUID().uuidString).jpg"
        let url = try folderURL().appendingPathComponent(filename)
        try data.write(to: url, options: [.atomic])
        return filename
    }

    func loadImage(named filename: String) -> UIImage? {
        guard let url = try? folderURL().appendingPathComponent(filename),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return UIImage(data: data)
    }

    func deleteAllPhotos() throws {
        let folder = try folderURL()
        guard fileManager.fileExists(atPath: folder.path) else {
            return
        }

        let files = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for file in files {
            try fileManager.removeItem(at: file)
        }
    }

    private func folderURL() throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }
}

final class FakeAISummaryService: AISummaryServiceProtocol {
    // TODO: Replace with real AI summary and Q&A API integration.
    func summaryPoints(for property: Property) -> [String] {
        [
            property.estValueLow > 0 && property.estValueHigh > 0
                ? "Estimated value sits around \(currency(property.estValueLow)) to \(currency(property.estValueHigh))."
                : "Estimated value model is coming soon.",
            property.rentEstimateWeekly > 0
                ? "Rental estimate is \(currency(property.rentEstimateWeekly))/week with ~\(String(format: "%.1f", property.grossYieldPct))% gross yield."
                : "Rental estimate is coming soon.",
            property.bedrooms > 0 && property.bathrooms > 0 && !property.propertyType.isEmpty
                ? "\(property.bedrooms) bed / \(property.bathrooms) bath \(property.propertyType.lowercased()) on \(property.landSizeSqm) sqm."
                : "Detailed dwelling specs are coming soon.",
            property.lastSalePrice > 0
                ? "Last sale recorded at \(currency(property.lastSalePrice)) on \(DateFormatter.shortDate.string(from: property.lastSaleDate))."
                : "Sale history enrichment is coming soon.",
            property.flags.isEmpty
                ? "Planning risk flags are coming soon."
                : "Key planning flags: \(property.flags.prefix(2).joined(separator: "; "))."
        ]
    }

    func respond(to question: String, property: Property) -> String {
        let lower = question.lowercased()

        if lower.contains("risk") || lower.contains("flag") {
            return "Main risk markers are \(property.flags.joined(separator: ", ")). A formal due-diligence search should verify overlays and zoning notices."
        }

        if lower.contains("rent") || lower.contains("yield") {
            return "Current model puts rent near \(currency(property.rentEstimateWeekly))/week, implying about \(String(format: "%.1f", property.grossYieldPct))% gross yield before costs."
        }

        if lower.contains("value") || lower.contains("price") {
            return "A reasonable working range is \(currency(property.estValueLow))–\(currency(property.estValueHigh)). I would compare at least 3 nearby settled sales before an offer."
        }

        return "Based on the profile, this looks like a \(property.bedrooms)-bed \(property.propertyType.lowercased()) in \(property.suburb) with balanced owner-occupier/investor appeal."
    }

    private func currency(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_AU")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "$\(value)"
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
}
