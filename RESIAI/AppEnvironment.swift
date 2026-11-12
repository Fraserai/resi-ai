import Foundation
import SwiftData
import CoreLocation

@MainActor
final class AppEnvironment: ObservableObject {
    let locationService: any LocationServiceProtocol
    let propertyProvider: any PropertyDataProviderProtocol
    let propertyMatcher: any PropertyMatcherProtocol
    let geocodingService: any GeocodingServiceProtocol
    let persistence: any PersistenceServiceProtocol
    let photoStorage: any PhotoStorageServiceProtocol
    let aiSummaryService: any AISummaryServiceProtocol
    let cameraServiceFactory: () -> any CameraServiceProtocol

    init(locationService: any LocationServiceProtocol,
         propertyProvider: any PropertyDataProviderProtocol,
         propertyMatcher: any PropertyMatcherProtocol,
         geocodingService: any GeocodingServiceProtocol,
         persistence: any PersistenceServiceProtocol,
         photoStorage: any PhotoStorageServiceProtocol,
         aiSummaryService: any AISummaryServiceProtocol,
         cameraServiceFactory: @escaping () -> any CameraServiceProtocol) {
        self.locationService = locationService
        self.propertyProvider = propertyProvider
        self.propertyMatcher = propertyMatcher
        self.geocodingService = geocodingService
        self.persistence = persistence
        self.photoStorage = photoStorage
        self.aiSummaryService = aiSummaryService
        self.cameraServiceFactory = cameraServiceFactory
    }

    func deleteAllHistory() throws {
        try persistence.deleteAllHistory()
        try photoStorage.deleteAllPhotos()
    }

    func property(with id: UUID, near coordinate: CLLocationCoordinate2D?) async -> Property? {
        if let cached = try? persistence.property(by: id) {
            return cached
        }
        return await propertyProvider.property(with: id, near: coordinate)
    }
}
