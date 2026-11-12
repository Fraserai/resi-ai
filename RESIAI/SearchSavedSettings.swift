import SwiftUI
import CoreLocation
import UIKit

enum SavedSegment: String, CaseIterable, Identifiable {
    case saved = "Saved"
    case scanned = "Scanned"

    var id: String { rawValue }
}

@MainActor
final class AddressSearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [Property] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func runSearch() async {
        isLoading = true
        defer { isLoading = false }

        let location = environment.locationService.currentSnapshot().map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }

        let remote = await environment.propertyProvider.searchProperties(query: query, around: location)
        let cached = (try? environment.persistence.searchCachedProperties(query: query)) ?? []

        var deduped: [UUID: Property] = [:]
        (remote + cached).forEach { deduped[$0.id] = $0 }
        results = deduped.values.sorted(by: { $0.addressLine < $1.addressLine })
    }

    func cacheForLater(_ property: Property) {
        do {
            try environment.persistence.upsertProperty(property, markSaved: nil)
        } catch {
            errorMessage = "Could not cache property."
        }
    }
}

@MainActor
final class SavedViewModel: ObservableObject {
    @Published var selectedSegment: SavedSegment = .saved
    @Published var savedProperties: [Property] = []
    @Published var scannedItems: [ScanHistoryItem] = []
    @Published var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func refresh() {
        do {
            savedProperties = try environment.persistence.savedProperties()
            scannedItems = try environment.persistence.scanHistory()
        } catch {
            errorMessage = "Could not load saved lists."
        }
    }

    func resolve(item: ScanHistoryItem) async -> (Property, ProfileContext)? {
        guard let propertyId = item.matchedPropertyId else {
            return nil
        }

        if let cached = try? environment.persistence.property(by: propertyId) {
            return (
                cached,
                ProfileContext(
                    photoFilename: item.photoFilename,
                    confidence: item.confidence,
                    matchMethod: item.matchMethod,
                    captureLatitude: nil,
                    captureLongitude: nil,
                    accuracyMeters: nil
                )
            )
        }

        guard let remote = await environment.propertyProvider.property(with: propertyId, near: nil) else {
            return nil
        }

        return (
            remote,
            ProfileContext(
                photoFilename: item.photoFilename,
                confidence: item.confidence,
                matchMethod: item.matchMethod,
                captureLatitude: nil,
                captureLongitude: nil,
                accuracyMeters: nil
            )
        )
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var locationStatusText: String = "Unknown"
    @Published var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func refreshStatus() {
        let status = environment.locationService.authorizationStatus
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            locationStatusText = "Allowed"
        case .denied:
            locationStatusText = "Denied"
        case .restricted:
            locationStatusText = "Restricted"
        case .notDetermined:
            locationStatusText = "Not determined"
        @unknown default:
            locationStatusText = "Unknown"
        }
    }

    func deleteAllHistory() {
        do {
            try environment.deleteAllHistory()
        } catch {
            errorMessage = "Could not delete local history."
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selectedTab: MainTab = .scan

    var body: some View {
        TabView(selection: $selectedTab) {
            ScanRootView(environment: environment, selectedTab: $selectedTab)
                .tabItem {
                    Label("Scan", systemImage: "camera.viewfinder")
                }
                .tag(MainTab.scan)

            AddressSearchView(environment: environment)
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(MainTab.search)

            SavedView(environment: environment)
                .tabItem {
                    Label("Saved", systemImage: "bookmark")
                }
                .tag(MainTab.saved)

            SettingsView(environment: environment)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(MainTab.settings)
        }
    }
}

struct AddressSearchView: View {
    @StateObject private var viewModel: AddressSearchViewModel
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        self._viewModel = StateObject(wrappedValue: AddressSearchViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                ForEach(viewModel.results) { property in
                    NavigationLink(value: property) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(property.addressLine)
                                .font(.headline)
                            Text("\(property.suburb) \(property.state) \(property.postcode)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Address Search")
            .searchable(text: $viewModel.query, prompt: "Search address or suburb")
            .onSubmit(of: .search) {
                Task {
                    await viewModel.runSearch()
                }
            }
            .onChange(of: viewModel.query) { _, newValue in
                guard newValue.isEmpty else {
                    return
                }
                Task {
                    await viewModel.runSearch()
                }
            }
            .task {
                await viewModel.runSearch()
            }
            .navigationDestination(for: Property.self) { property in
                PropertyProfileView(
                    environment: environment,
                    property: property,
                    context: ProfileContext(
                        photoFilename: nil,
                        confidence: 0.6,
                        matchMethod: .manual,
                        captureLatitude: nil,
                        captureLongitude: nil,
                        accuracyMeters: nil
                    )
                )
                .onAppear {
                    viewModel.cacheForLater(property)
                }
            }
            .alert("Search", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { _ in viewModel.errorMessage = nil }
            )) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }
}

enum SavedRoute: Hashable {
    case profile(Property, ProfileContext)
}

struct SavedView: View {
    @StateObject private var viewModel: SavedViewModel
    @State private var path: [SavedRoute] = []
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        self._viewModel = StateObject(wrappedValue: SavedViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack {
                Picker("Mode", selection: $viewModel.selectedSegment) {
                    ForEach(SavedSegment.allCases) { segment in
                        Text(segment.rawValue).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                List {
                    if viewModel.selectedSegment == .saved {
                        ForEach(viewModel.savedProperties) { property in
                            Button {
                                let context = ProfileContext(
                                    photoFilename: nil,
                                    confidence: 0.7,
                                    matchMethod: .manual,
                                    captureLatitude: nil,
                                    captureLongitude: nil,
                                    accuracyMeters: nil
                                )
                                path.append(.profile(property, context))
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(property.addressLine)
                                        .font(.headline)
                                    Text("Last refreshed \(Formatters.shortDate.string(from: property.lastRefreshed))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        ForEach(viewModel.scannedItems) { item in
                            Button {
                                guard item.matchedPropertyId != nil else { return }
                                Task {
                                    if let tuple = await viewModel.resolve(item: item) {
                                        await MainActor.run {
                                            path.append(.profile(tuple.0, tuple.1))
                                        }
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.matchedAddressLine ?? "Unmatched scan")
                                        .font(.headline)
                                    Text("\(Formatters.dateTime.string(from: item.date))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(item.matchedPropertyId == nil)
                        }
                    }
                }
            }
            .navigationTitle("Saved")
            .navigationDestination(for: SavedRoute.self) { route in
                switch route {
                case .profile(let property, let context):
                    PropertyProfileView(environment: environment, property: property, context: context)
                }
            }
            .onAppear {
                viewModel.refresh()
            }
            .alert("Saved", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { _ in viewModel.errorMessage = nil }
            )) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }
}

struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel
    @State private var showDeleteConfirm = false

    init(environment: AppEnvironment) {
        self._viewModel = StateObject(wrappedValue: SettingsViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Permissions") {
                    HStack {
                        Text("Location")
                        Spacer()
                        Text(viewModel.locationStatusText)
                            .foregroundStyle(.secondary)
                    }

                    Button("Open iOS Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }

                Section("Privacy") {
                    Text("Photos stored on device")
                }

                Section("Data") {
                    Button("Delete all history", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }

                Section("Support") {
                    Link("Report issue", destination: URL(string: "mailto:support@example.com?subject=RESI.AI%20Issue")!)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete all local history?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete all history", role: .destructive) {
                    viewModel.deleteAllHistory()
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                viewModel.refreshStatus()
            }
            .alert("Settings", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { _ in viewModel.errorMessage = nil }
            )) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }
}
