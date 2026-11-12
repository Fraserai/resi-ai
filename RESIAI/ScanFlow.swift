import SwiftUI
import MapKit
import CoreLocation
import AVFoundation
import UIKit

enum ScanRoute: Hashable {
    case camera
    case geocoding(PendingScan)
    case manualPin(PendingScan)
    case matching(PendingScan)
    case confirm(PendingScan, [MatchCandidate], Double)
    case mapPicker(PendingScan, [MatchCandidate])
    case profile(Property, ProfileContext)
}

@MainActor
final class ScanRootViewModel: ObservableObject {
    @Published var recentScans: [ScanHistoryItem] = []
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var isLocationBlocked: Bool {
        locationStatus == .denied || locationStatus == .restricted
    }

    func onAppear() {
        locationStatus = environment.locationService.authorizationStatus
        environment.locationService.requestPermission()
        environment.locationService.startUpdating()
        refreshRecentScans()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.locationStatus = self?.environment.locationService.authorizationStatus ?? .notDetermined
        }
    }

    func refreshRecentScans() {
        do {
            recentScans = try environment.persistence.recentScans(limit: 5)
        } catch {
            errorMessage = "Could not load recent scans."
        }
    }

    func createPendingScan(photoData: Data) throws -> PendingScan {
        let snapshot = environment.locationService.currentSnapshot()
        let photoFilename = try environment.photoStorage.savePhotoData(photoData)
        let id = UUID()

        let draft = ScanEventDraft(
            id: id,
            date: .now,
            latitude: snapshot?.latitude ?? 0,
            longitude: snapshot?.longitude ?? 0,
            accuracyMeters: snapshot?.accuracyMeters ?? 150,
            headingDegrees: snapshot?.headingDegrees,
            photoFilename: photoFilename
        )
        try environment.persistence.createScanEvent(draft)
        refreshRecentScans()

        return PendingScan(
            id: id,
            photoFilename: photoFilename,
            latitude: draft.latitude,
            longitude: draft.longitude,
            accuracyMeters: draft.accuracyMeters,
            headingDegrees: draft.headingDegrees
        )
    }

    func finalizeMatch(scan: PendingScan,
                       property: Property,
                       confidence: Double,
                       method: MatchMethod) {
        do {
            try environment.persistence.updateScanMatch(
                scanId: scan.id,
                property: property,
                confidence: confidence,
                method: method
            )
            refreshRecentScans()
        } catch {
            errorMessage = "Could not save scan result."
        }
    }

    func profileContext(for scan: PendingScan,
                        confidence: Double,
                        method: MatchMethod,
                        coordinateOverride: CLLocationCoordinate2D? = nil,
                        accuracyMetersOverride: Double? = nil) -> ProfileContext {
        ProfileContext(
            photoFilename: scan.photoFilename,
            confidence: confidence,
            matchMethod: method,
            captureLatitude: coordinateOverride?.latitude ?? scan.latitude,
            captureLongitude: coordinateOverride?.longitude ?? scan.longitude,
            accuracyMeters: accuracyMetersOverride ?? scan.accuracyMeters
        )
    }

    func loadProperty(for historyItem: ScanHistoryItem) async -> (Property, ProfileContext)? {
        guard let propertyId = historyItem.matchedPropertyId else {
            return nil
        }

        if let cached = try? environment.persistence.property(by: propertyId) {
            return (
                cached,
                ProfileContext(
                    photoFilename: historyItem.photoFilename,
                    confidence: historyItem.confidence,
                    matchMethod: historyItem.matchMethod,
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
                photoFilename: historyItem.photoFilename,
                confidence: historyItem.confidence,
                matchMethod: historyItem.matchMethod,
                captureLatitude: nil,
                captureLongitude: nil,
                accuracyMeters: nil
            )
        )
    }
}

@MainActor
final class CameraViewModel: ObservableObject {
    @Published var hasCameraAccess: Bool = true
    @Published var flashEnabled: Bool = false
    @Published var isCapturing: Bool = false
    @Published var errorMessage: String?

    private let cameraService: any CameraServiceProtocol

    init(cameraServiceFactory: @escaping () -> any CameraServiceProtocol) {
        self.cameraService = cameraServiceFactory()
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        cameraService.previewLayer
    }

    func start() async {
        hasCameraAccess = await cameraService.requestAccess()
        guard hasCameraAccess else {
            return
        }

        do {
            try cameraService.configureSession()
            cameraService.startSession()
        } catch {
            errorMessage = "Camera session could not start."
        }
    }

    func stop() {
        cameraService.stopSession()
    }

    func toggleFlash() {
        flashEnabled.toggle()
        cameraService.isFlashEnabled = flashEnabled
    }

    func capture() async -> Data? {
        isCapturing = true
        defer { isCapturing = false }

        do {
            return try await cameraService.capturePhoto()
        } catch {
            errorMessage = "Capture failed. Please try again."
            return nil
        }
    }
}

@MainActor
final class MatchingViewModel: ObservableObject {
    @Published var stepText = "Using your location…"
    @Published var isNoCandidateState = false

    private let steps = [
        "Using your location…",
        "Matching the building…",
        "Verifying address…"
    ]

    func runMatch(scan: PendingScan,
                  matcher: any PropertyMatcherProtocol,
                  onStep: (() -> Void)? = nil) async -> MatchResult {
        isNoCandidateState = false
        stepText = steps[0]

        let snapshot = LocationSnapshot(
            latitude: scan.latitude,
            longitude: scan.longitude,
            accuracyMeters: max(5, scan.accuracyMeters),
            headingDegrees: scan.headingDegrees
        )

        async let resultTask = matcher.match(location: snapshot, capturedImage: nil)

        for index in 1..<steps.count {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else {
                break
            }
            stepText = steps[index]
            onStep?()
        }

        let result = await resultTask
        if result.rankedCandidates.isEmpty {
            isNoCandidateState = true
        }

        return result
    }
}

@MainActor
final class ConfirmAddressViewModel: ObservableObject {
    let candidates: [MatchCandidate]

    init(candidates: [MatchCandidate]) {
        self.candidates = candidates
    }
}

@MainActor
final class MapPickerViewModel: ObservableObject {
    @Published var region: MKCoordinateRegion
    @Published var selectedCandidateId: UUID?

    let candidates: [MatchCandidate]

    init(scan: PendingScan, candidates: [MatchCandidate]) {
        self.candidates = candidates
        self.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: scan.latitude, longitude: scan.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
        )
    }

    var selectedCandidate: MatchCandidate? {
        candidates.first(where: { $0.id == selectedCandidateId })
    }
}

struct ScanRootView: View {
    @Binding private var selectedTab: MainTab
    @State private var path: [ScanRoute] = []
    @StateObject private var viewModel: ScanRootViewModel

    private let environment: AppEnvironment

    init(environment: AppEnvironment, selectedTab: Binding<MainTab>) {
        self.environment = environment
        self._selectedTab = selectedTab
        self._viewModel = StateObject(wrappedValue: ScanRootViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack(path: $path) {
            HomeScanView(
                viewModel: viewModel,
                selectedTab: $selectedTab,
                openCamera: {
                    path.append(.camera)
                },
                openRecent: { item in
                    Task {
                        if let tuple = await viewModel.loadProperty(for: item) {
                            await MainActor.run {
                                path.append(.profile(tuple.0, tuple.1))
                            }
                        }
                    }
                }
            )
            .navigationDestination(for: ScanRoute.self) { route in
                switch route {
                case .camera:
                    CameraView(cameraFactory: environment.cameraServiceFactory) { data in
                        do {
                            let pending = try viewModel.createPendingScan(photoData: data)
                            replaceTop(with: .geocoding(pending))
                        } catch {
                            viewModel.errorMessage = "Could not save scan photo locally."
                        }
                    }
                case .geocoding(let scan):
                    ScanAddressResolveView(
                        scan: scan,
                        geocodingService: environment.geocodingService,
                        onResolved: { geocode in
                            let property = Property.partialFromGeocode(geocode)
                            viewModel.finalizeMatch(scan: scan, property: property, confidence: geocode.confidence, method: .auto)
                            let context = viewModel.profileContext(
                                for: scan,
                                confidence: geocode.confidence,
                                method: .auto,
                                coordinateOverride: CLLocationCoordinate2D(latitude: geocode.latitude, longitude: geocode.longitude),
                                accuracyMetersOverride: geocode.accuracyMeters
                            )
                            showProfile(property: property, context: context)
                        },
                        onOpenMap: {
                            replaceTop(with: .manualPin(scan))
                        },
                        onTrySearchTab: {
                            selectedTab = .search
                            path = []
                        }
                    )
                case .manualPin(let scan):
                    ManualPinPickerView(
                        scan: scan,
                        geocodingService: environment.geocodingService,
                        onResolved: { geocode in
                            let property = Property.partialFromGeocode(geocode)
                            viewModel.finalizeMatch(scan: scan, property: property, confidence: geocode.confidence, method: .manual)
                            let context = viewModel.profileContext(
                                for: scan,
                                confidence: geocode.confidence,
                                method: .manual,
                                coordinateOverride: CLLocationCoordinate2D(latitude: geocode.latitude, longitude: geocode.longitude),
                                accuracyMetersOverride: geocode.accuracyMeters
                            )
                            showProfile(property: property, context: context)
                        },
                        onTrySearchTab: {
                            selectedTab = .search
                            path = []
                        }
                    )
                case .matching(let scan):
                    MatchingView(
                        scan: scan,
                        matcher: environment.propertyMatcher,
                        provider: environment.propertyProvider,
                        onAutoMatch: { property, confidence in
                            viewModel.finalizeMatch(scan: scan, property: property, confidence: confidence, method: .auto)
                            let context = viewModel.profileContext(for: scan, confidence: confidence, method: .auto)
                            showProfile(property: property, context: context)
                        },
                        onNeedConfirmation: { candidates, confidence in
                            replaceTop(with: .confirm(scan, candidates, confidence))
                        },
                        onOpenMap: { candidates in
                            replaceTop(with: .mapPicker(scan, candidates))
                        },
                        onTrySearchTab: {
                            selectedTab = .search
                            path = []
                        }
                    )
                case .confirm(let scan, let candidates, let confidence):
                    ConfirmAddressView(
                        viewModel: ConfirmAddressViewModel(candidates: candidates),
                        onSelect: { property in
                            viewModel.finalizeMatch(scan: scan, property: property, confidence: confidence, method: .confirmed)
                            let context = viewModel.profileContext(for: scan, confidence: confidence, method: .confirmed)
                            showProfile(property: property, context: context)
                        },
                        onNone: {
                            path.append(.mapPicker(scan, candidates))
                        }
                    )
                case .mapPicker(let scan, let candidates):
                    MapPickerView(viewModel: MapPickerViewModel(scan: scan, candidates: candidates)) { selected in
                        viewModel.finalizeMatch(scan: scan, property: selected.property, confidence: selected.confidence, method: .manual)
                        let context = viewModel.profileContext(for: scan, confidence: selected.confidence, method: .manual)
                        showProfile(property: selected.property, context: context)
                    }
                case .profile(let property, let context):
                    PropertyProfileView(environment: environment, property: property, context: context)
                }
            }
            .alert("Notice", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { _ in viewModel.errorMessage = nil }
            )) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .onAppear {
            viewModel.onAppear()
        }
    }

    private func replaceTop(with route: ScanRoute) {
        if !path.isEmpty {
            path.removeLast()
        }
        path.append(route)
    }

    private func showProfile(property: Property, context: ProfileContext) {
        path = [.profile(property, context)]
    }
}

struct HomeScanView: View {
    @ObservedObject var viewModel: ScanRootViewModel
    @Binding var selectedTab: MainTab
    let openCamera: () -> Void
    let openRecent: (ScanHistoryItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("RESI.AI")
                    .font(.largeTitle.bold())

                if viewModel.isLocationBlocked {
                    blockedLocationView
                } else {
                    Button(action: openCamera) {
                        Label("Open Camera", systemImage: "camera.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }

                Button("Try address search") {
                    selectedTab = .search
                }
                .font(.subheadline)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent scans")
                        .font(.headline)

                    if viewModel.recentScans.isEmpty {
                        Text("No scans yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(viewModel.recentScans) { item in
                                    Button {
                                        if item.matchedPropertyId != nil {
                                            openRecent(item)
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(item.matchedAddressLine ?? "Unmatched scan")
                                                .font(.headline)
                                                .lineLimit(2)
                                            Text(item.matchedSuburb ?? "")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                            Text(Formatters.dateTime.string(from: item.date))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(12)
                                        .frame(width: 220, alignment: .leading)
                                        .background(Color(.secondarySystemBackground))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var blockedLocationView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Location access is required to match the property you scan.")
                .font(.subheadline)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: CameraViewModel
    let onCaptured: (Data) -> Void

    init(cameraFactory: @escaping () -> any CameraServiceProtocol,
         onCaptured: @escaping (Data) -> Void) {
        self._viewModel = StateObject(wrappedValue: CameraViewModel(cameraServiceFactory: cameraFactory))
        self.onCaptured = onCaptured
    }

    var body: some View {
        ZStack {
            if viewModel.hasCameraAccess {
                CameraPreviewView(previewLayer: viewModel.previewLayer)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Text("Camera access needed")
                        .font(.headline)
                    Button("Open Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.bold())
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    Spacer()
                    Button {
                        viewModel.toggleFlash()
                    } label: {
                        Image(systemName: viewModel.flashEnabled ? "bolt.fill" : "bolt.slash")
                            .font(.title3)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding()
                Spacer()

                Button {
                    Task {
                        if let data = await viewModel.capture() {
                            onCaptured(data)
                        }
                    }
                } label: {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 78, height: 78)
                        .overlay {
                            Circle().stroke(Color.black.opacity(0.3), lineWidth: 2)
                        }
                }
                .padding(.bottom, 36)
                .disabled(viewModel.isCapturing)
            }
        }
        .task {
            await viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .alert("Camera", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .navigationBarBackButtonHidden(true)
    }
}

@MainActor
final class ScanAddressResolveViewModel: ObservableObject {
    @Published var stepText = "Using your location…"
    @Published var isResolving = true
    @Published var failed = false

    private let steps = [
        "Using your location…",
        "Resolving your address…",
        "Preparing property profile…"
    ]

    func resolve(scan: PendingScan, geocodingService: any GeocodingServiceProtocol) async -> ReverseGeocodeResult? {
        failed = false
        isResolving = true
        stepText = steps[0]

        for text in steps.dropFirst() {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return nil }
            stepText = text
        }

        do {
            let result = try await geocodingService.reverseGeocode(location: scan.locationSnapshot)
            isResolving = false
            return result
        } catch {
            isResolving = false
            failed = true
            return nil
        }
    }
}

struct ScanAddressResolveView: View {
    @StateObject private var viewModel = ScanAddressResolveViewModel()

    let scan: PendingScan
    let geocodingService: any GeocodingServiceProtocol
    let onResolved: (ReverseGeocodeResult) -> Void
    let onOpenMap: () -> Void
    let onTrySearchTab: () -> Void

    @State private var hasStarted = false

    var body: some View {
        VStack(spacing: 18) {
            if let image = PhotoStorageService().loadImage(named: scan.photoFilename) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            if viewModel.failed {
                Text("Couldn’t determine address")
                    .font(.title3.bold())
                Text("Try choosing the location manually on the map, or switch to address search.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button("Open map picker") {
                    onOpenMap()
                }
                .buttonStyle(.borderedProminent)

                Button("Try address search") {
                    onTrySearchTab()
                }
                .buttonStyle(.bordered)
            } else {
                ProgressView()
                Text(viewModel.stepText)
                    .font(.headline)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Resolving Address")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await start()
        }
    }

    private func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        guard let geocode = await viewModel.resolve(scan: scan, geocodingService: geocodingService) else {
            return
        }
        onResolved(geocode)
    }
}

struct ManualPinPickerView: View {
    let scan: PendingScan
    let geocodingService: any GeocodingServiceProtocol
    let onResolved: (ReverseGeocodeResult) -> Void
    let onTrySearchTab: () -> Void

    @State private var region: MKCoordinateRegion
    @State private var isResolving = false
    @State private var errorMessage: String?

    init(scan: PendingScan,
         geocodingService: any GeocodingServiceProtocol,
         onResolved: @escaping (ReverseGeocodeResult) -> Void,
         onTrySearchTab: @escaping () -> Void) {
        self.scan = scan
        self.geocodingService = geocodingService
        self.onResolved = onResolved
        self.onTrySearchTab = onTrySearchTab
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: scan.latitude, longitude: scan.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
        ))
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Move the map so the pin is on the property.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Map(coordinateRegion: $region)
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                    .shadow(radius: 3)
            }
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Button(isResolving ? "Resolving…" : "Use this location") {
                Task { await resolveSelectedCoordinate() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isResolving)

            Button("Try address search") {
                onTrySearchTab()
            }
            .buttonStyle(.bordered)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Manual Pin")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resolveSelectedCoordinate() async {
        isResolving = true
        defer { isResolving = false }

        let snapshot = LocationSnapshot(
            latitude: region.center.latitude,
            longitude: region.center.longitude,
            accuracyMeters: max(scan.accuracyMeters, 20),
            headingDegrees: nil
        )

        do {
            let geocode = try await geocodingService.reverseGeocode(location: snapshot)
            onResolved(geocode)
        } catch {
            errorMessage = "Couldn’t determine address for that pin. Try another spot."
        }
    }
}

struct MatchingView: View {
    @StateObject private var viewModel = MatchingViewModel()

    let scan: PendingScan
    let matcher: any PropertyMatcherProtocol
    let provider: any PropertyDataProviderProtocol
    let onAutoMatch: (Property, Double) -> Void
    let onNeedConfirmation: ([MatchCandidate], Double) -> Void
    let onOpenMap: ([MatchCandidate]) -> Void
    let onTrySearchTab: () -> Void

    @State private var fallbackCandidates: [MatchCandidate] = []
    @State private var hasStarted = false

    var body: some View {
        VStack(spacing: 18) {
            if let image = PhotoStorageService().loadImage(named: scan.photoFilename) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            if viewModel.isNoCandidateState {
                Text("Couldn’t confidently match")
                    .font(.title3.bold())
                Text("Try again, use map selection, or switch to address search.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button("Retry") {
                    hasStarted = false
                    Task { await startMatch() }
                }
                .buttonStyle(.borderedProminent)

                Button("Open map") {
                    onOpenMap(fallbackCandidates)
                }
                .buttonStyle(.bordered)

                Button("Manual address search") {
                    onTrySearchTab()
                }
                .font(.subheadline)
            } else {
                ProgressView()
                Text(viewModel.stepText)
                    .font(.headline)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Matching")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await startMatch()
        }
    }

    private func startMatch() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        let result = await viewModel.runMatch(scan: scan, matcher: matcher)

        if result.rankedCandidates.isEmpty {
            let coordinate = CLLocationCoordinate2D(latitude: scan.latitude, longitude: scan.longitude)
            let fallback = await provider.nearbyProperties(around: coordinate, radiusMeters: 250)
            fallbackCandidates = fallback.map {
                MatchCandidate(property: $0, confidence: 0.5, distanceMeters: 0, directionString: "", rawScore: 0.5)
            }
            return
        }

        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else {
            return
        }

        if let top = result.rankedCandidates.first, result.overallConfidence >= 0.75 {
            onAutoMatch(top.property, result.overallConfidence)
        } else {
            let topThree = Array(result.rankedCandidates.prefix(3))
            onNeedConfirmation(topThree, result.overallConfidence)
        }
    }
}

struct ConfirmAddressView: View {
    @ObservedObject var viewModel: ConfirmAddressViewModel
    let onSelect: (Property) -> Void
    let onNone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(viewModel.candidates.prefix(3)) { candidate in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(candidate.property.addressLine)
                            .font(.title3.bold())
                        Text("\(Int(candidate.distanceMeters))m • \(candidate.directionString)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Confidence \(Int(candidate.confidence * 100))%")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())

                            Spacer()

                            Button("This one") {
                                onSelect(candidate.property)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button("None of these") {
                    onNone()
                }
                .buttonStyle(.bordered)
                .padding(.top, 6)
            }
            .padding()
        }
        .navigationTitle("Confirm Address")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MapPickerView: View {
    @ObservedObject var viewModel: MapPickerViewModel
    let onSelect: (MatchCandidate) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Map(coordinateRegion: $viewModel.region, annotationItems: viewModel.candidates) { candidate in
                MapAnnotation(coordinate: candidate.property.coordinate) {
                    Button {
                        viewModel.selectedCandidateId = candidate.id
                    } label: {
                        Image(systemName: viewModel.selectedCandidateId == candidate.id ? "mappin.circle.fill" : "mappin.circle")
                            .font(.title)
                            .foregroundStyle(viewModel.selectedCandidateId == candidate.id ? .red : .blue)
                    }
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if viewModel.candidates.isEmpty {
                Text("No nearby candidates found on map.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let selected = viewModel.selectedCandidate {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selected.property.addressLine)
                        .font(.headline)
                    Text("\(selected.property.suburb)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Use selected pin") {
                    onSelect(selected)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Pick on Map")
        .navigationBarTitleDisplayMode(.inline)
    }
}
