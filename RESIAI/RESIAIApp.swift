import SwiftUI
import SwiftData

@main
struct RESIAIApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var environment: AppEnvironment

    init() {
        let schema = Schema([
            ScanEventRecord.self,
            CachedPropertyRecord.self
        ])

        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            self.modelContainer = container

            let locationService = LocationService()
            let provider = MockPropertyDataProvider()
            let matcher = PropertyMatcher(dataProvider: provider)
            let geocodingService = ReverseGeocodeService()
            let persistence = SwiftDataPersistenceService(context: container.mainContext)
            let photoStorage = PhotoStorageService()
            let aiSummary = FakeAISummaryService()

            _environment = StateObject(wrappedValue: AppEnvironment(
                locationService: locationService,
                propertyProvider: provider,
                propertyMatcher: matcher,
                geocodingService: geocodingService,
                persistence: persistence,
                photoStorage: photoStorage,
                aiSummaryService: aiSummary,
                cameraServiceFactory: { AVFoundationCameraService() }
            ))
        } catch {
            fatalError("Unable to initialize app dependencies: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(environment)
                .modelContainer(modelContainer)
        }
    }
}
