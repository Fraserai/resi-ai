import Foundation
import SwiftData

@Model
final class ScanEventRecord {
    @Attribute(.unique) var id: UUID
    var date: Date
    var latitude: Double
    var longitude: Double
    var accuracyMeters: Double
    var headingDegrees: Double?
    var photoFilename: String
    var matchedPropertyId: UUID?
    var confidence: Double
    var matchMethodRaw: String
    var matchedAddressLine: String?
    var matchedSuburb: String?

    init(id: UUID,
         date: Date,
         latitude: Double,
         longitude: Double,
         accuracyMeters: Double,
         headingDegrees: Double?,
         photoFilename: String,
         matchedPropertyId: UUID? = nil,
         confidence: Double = 0,
         matchMethodRaw: String = MatchMethod.auto.rawValue,
         matchedAddressLine: String? = nil,
         matchedSuburb: String? = nil) {
        self.id = id
        self.date = date
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.headingDegrees = headingDegrees
        self.photoFilename = photoFilename
        self.matchedPropertyId = matchedPropertyId
        self.confidence = confidence
        self.matchMethodRaw = matchMethodRaw
        self.matchedAddressLine = matchedAddressLine
        self.matchedSuburb = matchedSuburb
    }
}

@Model
final class CachedPropertyRecord {
    @Attribute(.unique) var id: UUID
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
    var flagsJSON: String
    var dataQuality: String
    var dataSourcesJSON: String
    var lastRefreshed: Date
    var isSaved: Bool

    init(from property: Property, isSaved: Bool = false) {
        self.id = property.id
        self.addressLine = property.addressLine
        self.suburb = property.suburb
        self.state = property.state
        self.postcode = property.postcode
        self.country = property.country
        self.latitude = property.latitude
        self.longitude = property.longitude
        self.propertyType = property.propertyType
        self.bedrooms = property.bedrooms
        self.bathrooms = property.bathrooms
        self.landSizeSqm = property.landSizeSqm
        self.yearBuilt = property.yearBuilt
        self.estValueLow = property.estValueLow
        self.estValueHigh = property.estValueHigh
        self.lastSalePrice = property.lastSalePrice
        self.lastSaleDate = property.lastSaleDate
        self.rentEstimateWeekly = property.rentEstimateWeekly
        self.grossYieldPct = property.grossYieldPct
        self.flagsJSON = Self.encodeFlags(property.flags)
        self.dataQuality = property.dataQuality
        self.dataSourcesJSON = Self.encodeFlags(property.dataSources)
        self.lastRefreshed = property.lastRefreshed
        self.isSaved = isSaved
    }

    func toProperty() -> Property {
        Property(
            id: id,
            addressLine: addressLine,
            suburb: suburb,
            state: state,
            postcode: postcode,
            country: country,
            latitude: latitude,
            longitude: longitude,
            propertyType: propertyType,
            bedrooms: bedrooms,
            bathrooms: bathrooms,
            landSizeSqm: landSizeSqm,
            yearBuilt: yearBuilt,
            estValueLow: estValueLow,
            estValueHigh: estValueHigh,
            lastSalePrice: lastSalePrice,
            lastSaleDate: lastSaleDate,
            rentEstimateWeekly: rentEstimateWeekly,
            grossYieldPct: grossYieldPct,
            flags: Self.decodeFlags(flagsJSON),
            dataQuality: dataQuality,
            dataSources: Self.decodeFlags(dataSourcesJSON),
            lastRefreshed: lastRefreshed
        )
    }

    func update(from property: Property) {
        addressLine = property.addressLine
        suburb = property.suburb
        state = property.state
        postcode = property.postcode
        country = property.country
        latitude = property.latitude
        longitude = property.longitude
        propertyType = property.propertyType
        bedrooms = property.bedrooms
        bathrooms = property.bathrooms
        landSizeSqm = property.landSizeSqm
        yearBuilt = property.yearBuilt
        estValueLow = property.estValueLow
        estValueHigh = property.estValueHigh
        lastSalePrice = property.lastSalePrice
        lastSaleDate = property.lastSaleDate
        rentEstimateWeekly = property.rentEstimateWeekly
        grossYieldPct = property.grossYieldPct
        flagsJSON = Self.encodeFlags(property.flags)
        dataQuality = property.dataQuality
        dataSourcesJSON = Self.encodeFlags(property.dataSources)
        lastRefreshed = property.lastRefreshed
    }

    private static func encodeFlags(_ flags: [String]) -> String {
        guard let data = try? JSONEncoder().encode(flags),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private static func decodeFlags(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }
}

struct ScanEventDraft {
    let id: UUID
    let date: Date
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double
    let headingDegrees: Double?
    let photoFilename: String
}

@MainActor
protocol PersistenceServiceProtocol {
    func createScanEvent(_ draft: ScanEventDraft) throws
    func updateScanMatch(scanId: UUID, property: Property, confidence: Double, method: MatchMethod) throws
    func upsertProperty(_ property: Property, markSaved: Bool?) throws
    func property(by id: UUID) throws -> Property?
    func isSaved(propertyId: UUID) throws -> Bool
    func toggleSaved(property: Property) throws -> Bool
    func recentScans(limit: Int) throws -> [ScanHistoryItem]
    func scanHistory() throws -> [ScanHistoryItem]
    func savedProperties() throws -> [Property]
    func searchCachedProperties(query: String) throws -> [Property]
    func deleteAllHistory() throws
}

@MainActor
final class SwiftDataPersistenceService: PersistenceServiceProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func createScanEvent(_ draft: ScanEventDraft) throws {
        let item = ScanEventRecord(
            id: draft.id,
            date: draft.date,
            latitude: draft.latitude,
            longitude: draft.longitude,
            accuracyMeters: draft.accuracyMeters,
            headingDegrees: draft.headingDegrees,
            photoFilename: draft.photoFilename
        )
        context.insert(item)
        try context.save()
    }

    func updateScanMatch(scanId: UUID, property: Property, confidence: Double, method: MatchMethod) throws {
        try upsertProperty(property, markSaved: nil)

        let descriptor = FetchDescriptor<ScanEventRecord>(predicate: #Predicate { $0.id == scanId })
        if let record = try context.fetch(descriptor).first {
            record.matchedPropertyId = property.id
            record.confidence = confidence
            record.matchMethodRaw = method.rawValue
            record.matchedAddressLine = property.addressLine
            record.matchedSuburb = property.suburb
            try context.save()
        }
    }

    func upsertProperty(_ property: Property, markSaved: Bool?) throws {
        let descriptor = FetchDescriptor<CachedPropertyRecord>(predicate: #Predicate { $0.id == property.id })
        if let existing = try context.fetch(descriptor).first {
            existing.update(from: property)
            if let markSaved {
                existing.isSaved = markSaved
            }
        } else {
            let record = CachedPropertyRecord(from: property, isSaved: markSaved ?? false)
            context.insert(record)
        }
        try context.save()
    }

    func property(by id: UUID) throws -> Property? {
        let descriptor = FetchDescriptor<CachedPropertyRecord>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first?.toProperty()
    }

    func isSaved(propertyId: UUID) throws -> Bool {
        let descriptor = FetchDescriptor<CachedPropertyRecord>(predicate: #Predicate { $0.id == propertyId })
        return try context.fetch(descriptor).first?.isSaved ?? false
    }

    func toggleSaved(property: Property) throws -> Bool {
        let descriptor = FetchDescriptor<CachedPropertyRecord>(predicate: #Predicate { $0.id == property.id })
        if let existing = try context.fetch(descriptor).first {
            existing.isSaved.toggle()
            existing.update(from: property)
            try context.save()
            return existing.isSaved
        }

        let record = CachedPropertyRecord(from: property, isSaved: true)
        context.insert(record)
        try context.save()
        return true
    }

    func recentScans(limit: Int) throws -> [ScanHistoryItem] {
        var descriptor = FetchDescriptor<ScanEventRecord>(
            sortBy: [SortDescriptor(\ScanEventRecord.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map(mapScan)
    }

    func scanHistory() throws -> [ScanHistoryItem] {
        let descriptor = FetchDescriptor<ScanEventRecord>(
            sortBy: [SortDescriptor(\ScanEventRecord.date, order: .reverse)]
        )
        return try context.fetch(descriptor).map(mapScan)
    }

    func savedProperties() throws -> [Property] {
        let descriptor = FetchDescriptor<CachedPropertyRecord>(
            predicate: #Predicate { $0.isSaved == true },
            sortBy: [SortDescriptor(\CachedPropertyRecord.addressLine, order: .forward)]
        )
        return try context.fetch(descriptor).map { $0.toProperty() }
    }

    func searchCachedProperties(query: String) throws -> [Property] {
        let descriptor = FetchDescriptor<CachedPropertyRecord>(
            sortBy: [SortDescriptor(\CachedPropertyRecord.addressLine, order: .forward)]
        )
        let records = try context.fetch(descriptor)

        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return records.prefix(20).map { $0.toProperty() }
        }

        return records.filter { item in
            item.addressLine.lowercased().contains(normalized)
            || item.suburb.lowercased().contains(normalized)
            || item.postcode.contains(normalized)
        }.map { $0.toProperty() }
    }

    func deleteAllHistory() throws {
        let scanDescriptor = FetchDescriptor<ScanEventRecord>()
        let scans = try context.fetch(scanDescriptor)
        scans.forEach(context.delete)

        let propertyDescriptor = FetchDescriptor<CachedPropertyRecord>()
        let properties = try context.fetch(propertyDescriptor)
        properties.forEach(context.delete)

        try context.save()
    }

    private func mapScan(_ item: ScanEventRecord) -> ScanHistoryItem {
        ScanHistoryItem(
            id: item.id,
            date: item.date,
            matchedAddressLine: item.matchedAddressLine,
            matchedSuburb: item.matchedSuburb,
            matchedPropertyId: item.matchedPropertyId,
            confidence: item.confidence,
            matchMethod: MatchMethod(rawValue: item.matchMethodRaw) ?? .auto,
            photoFilename: item.photoFilename
        )
    }
}
