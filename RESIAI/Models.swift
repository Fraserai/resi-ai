import Foundation
import CoreLocation

enum MatchMethod: String, Codable, CaseIterable {
    case auto
    case confirmed
    case manual
}

struct Property: Identifiable, Hashable, Codable {
    var id: UUID
    var addressLine: String
    var suburb: String
    var state: String
    var postcode: String
    var country: String?
    var latitude: Double
    var longitude: Double
    var propertyType: String
    var bedrooms: Int
    var bathrooms: Int
    var landSizeSqm: Int
    var yearBuilt: Int
    var estValueLow: Int
    var estValueHigh: Int
    var lastSalePrice: Int
    var lastSaleDate: Date
    var rentEstimateWeekly: Int
    var grossYieldPct: Double
    var flags: [String]
    var dataQuality: String
    var dataSources: [String]
    var lastRefreshed: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var fullAddress: String {
        [addressLine, "\(suburb) \(state) \(postcode)".trimmingCharacters(in: .whitespaces), country ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func partialFromGeocode(_ geocode: ReverseGeocodeResult) -> Property {
        Property(
            id: UUID(),
            addressLine: geocode.addressLine,
            suburb: geocode.suburb,
            state: geocode.state,
            postcode: geocode.postcode,
            country: geocode.country,
            latitude: geocode.latitude,
            longitude: geocode.longitude,
            propertyType: "",
            bedrooms: 0,
            bathrooms: 0,
            landSizeSqm: 0,
            yearBuilt: 0,
            estValueLow: 0,
            estValueHigh: 0,
            lastSalePrice: 0,
            lastSaleDate: .now,
            rentEstimateWeekly: 0,
            grossYieldPct: 0,
            flags: [],
            dataQuality: "Address-only",
            dataSources: ["Apple Reverse Geocode"],
            lastRefreshed: .now
        )
    }
}

struct ReverseGeocodeResult: Hashable {
    let addressLine: String
    let suburb: String
    let state: String
    let postcode: String
    let country: String?
    let latitude: Double
    let longitude: Double
    let confidence: Double
    let accuracyMeters: Double
}

struct MatchCandidate: Identifiable, Hashable {
    let id: UUID
    let property: Property
    let confidence: Double
    let distanceMeters: Double
    let directionString: String
    let rawScore: Double

    init(property: Property, confidence: Double, distanceMeters: Double, directionString: String, rawScore: Double) {
        self.id = property.id
        self.property = property
        self.confidence = confidence
        self.distanceMeters = distanceMeters
        self.directionString = directionString
        self.rawScore = rawScore
    }
}

struct MatchResult {
    let rankedCandidates: [MatchCandidate]
    let overallConfidence: Double
}

struct LocationSnapshot {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
    let headingDegrees: Double?

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

struct PendingScan: Hashable, Identifiable {
    let id: UUID
    let photoFilename: String
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
    let headingDegrees: Double?

    var locationSnapshot: LocationSnapshot {
        LocationSnapshot(
            latitude: latitude,
            longitude: longitude,
            accuracyMeters: accuracyMeters,
            headingDegrees: headingDegrees
        )
    }
}

struct ScanHistoryItem: Identifiable {
    let id: UUID
    let date: Date
    let matchedAddressLine: String?
    let matchedSuburb: String?
    let matchedPropertyId: UUID?
    let confidence: Double
    let matchMethod: MatchMethod
    let photoFilename: String
}

struct ProfileContext: Hashable {
    let photoFilename: String?
    let confidence: Double
    let matchMethod: MatchMethod
    let captureLatitude: Double?
    let captureLongitude: Double?
    let accuracyMeters: Double?
}

enum MainTab: Hashable {
    case scan
    case search
    case saved
    case settings
}

struct ChatMessage: Identifiable, Hashable {
    enum Role: Hashable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
}
