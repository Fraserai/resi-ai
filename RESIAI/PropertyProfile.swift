import SwiftUI
import UIKit
import MapKit

@MainActor
final class PropertyProfileViewModel: ObservableObject {
    @Published var property: Property
    @Published var summaryPoints: [String] = []
    @Published var question: String = ""
    @Published var conversation: [ChatMessage] = []
    @Published var isSaved = false
    @Published var shareImage: UIImage?
    @Published var errorMessage: String?

    let context: ProfileContext

    private let environment: AppEnvironment

    init(environment: AppEnvironment, property: Property, context: ProfileContext) {
        self.environment = environment
        self.property = property
        self.context = context
    }

    func onAppear() {
        summaryPoints = environment.aiSummaryService.summaryPoints(for: property)

        do {
            try environment.persistence.upsertProperty(property, markSaved: nil)
            isSaved = try environment.persistence.isSaved(propertyId: property.id)
        } catch {
            errorMessage = "Could not load local property state."
        }
    }

    func toggleSaved() {
        do {
            isSaved = try environment.persistence.toggleSaved(property: property)
        } catch {
            errorMessage = "Could not update saved state."
        }
    }

    func sendQuestion() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        conversation.append(ChatMessage(id: UUID(), role: .user, text: trimmed))
        let response = environment.aiSummaryService.respond(to: trimmed, property: property)
        conversation.append(ChatMessage(id: UUID(), role: .assistant, text: response))
        question = ""
    }

    func prepareShareImage(thumbnail: UIImage?) {
        let card = PropertyShareCardView(property: property, thumbnail: thumbnail)
            .frame(width: 620)
            .padding(28)
            .background(Color.white)

        let renderer = ImageRenderer(content: card)
        renderer.scale = UIScreen.main.scale
        shareImage = renderer.uiImage
    }

    var confidenceBadgeTitle: String {
        switch context.matchMethod {
        case .manual:
            return "Manual selection"
        case .confirmed:
            return "Needs confirmation"
        case .auto:
            return context.confidence >= 0.75 ? "High confidence" : "Needs confirmation"
        }
    }

    var confidenceBadgeColor: Color {
        switch context.matchMethod {
        case .manual:
            return .blue
        case .confirmed:
            return .orange
        case .auto:
            return context.confidence >= 0.75 ? .green : .orange
        }
    }

    var addressLineText: String {
        property.addressLine.isEmpty ? "Address unavailable" : property.addressLine
    }

    var localityText: String {
        let value = "\(property.suburb), \(property.state) \(property.postcode)".trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "Location unavailable" : value
    }

    var coordinateText: String {
        let lat = context.captureLatitude ?? property.latitude
        let lon = context.captureLongitude ?? property.longitude
        return String(format: "%.6f, %.6f", lat, lon)
    }

    var accuracyText: String {
        guard let accuracy = context.accuracyMeters else {
            return "Unknown"
        }
        return "\(Int(accuracy))m"
    }

    var typeText: String {
        property.propertyType.isEmpty ? "Coming soon" : property.propertyType
    }

    var bedsText: String {
        property.bedrooms > 0 ? "\(property.bedrooms)" : "Coming soon"
    }

    var bathsText: String {
        property.bathrooms > 0 ? "\(property.bathrooms)" : "Coming soon"
    }

    var landText: String {
        property.landSizeSqm > 0 ? "\(property.landSizeSqm) sqm" : "Coming soon"
    }

    var yearBuiltText: String {
        property.yearBuilt > 0 ? "\(property.yearBuilt)" : "Coming soon"
    }

    var valueRangeText: String {
        if property.estValueLow > 0 && property.estValueHigh > 0 {
            return "\(Formatters.currency(property.estValueLow)) - \(Formatters.currency(property.estValueHigh))"
        }
        return "Coming soon"
    }

    var lastSalePriceText: String {
        property.lastSalePrice > 0 ? Formatters.currency(property.lastSalePrice) : "Coming soon"
    }

    var saleDateText: String {
        property.lastSalePrice > 0 ? Formatters.shortDate.string(from: property.lastSaleDate) : "Coming soon"
    }

    var rentText: String {
        property.rentEstimateWeekly > 0 ? "\(Formatters.currency(property.rentEstimateWeekly))/week" : "Coming soon"
    }

    var yieldText: String {
        property.grossYieldPct > 0 ? "\(String(format: "%.1f", property.grossYieldPct))%" : "Coming soon"
    }

    var flagsText: [String] {
        property.flags.isEmpty ? ["Coming soon"] : property.flags
    }

    var dataSourcesText: String {
        property.dataSources.isEmpty ? "Unknown source" : property.dataSources.joined(separator: ", ")
    }
}

struct PropertyProfileView: View {
    @StateObject private var viewModel: PropertyProfileViewModel

    private let environment: AppEnvironment
    private let photoFilename: String?

    init(environment: AppEnvironment, property: Property, context: ProfileContext) {
        self.environment = environment
        self.photoFilename = context.photoFilename
        self._viewModel = StateObject(
            wrappedValue: PropertyProfileViewModel(environment: environment, property: property, context: context)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                imageSection
                actionButtons
                cards
            }
            .padding()
        }
        .navigationTitle("Property")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.onAppear()
        }
        .sheet(item: Binding(
            get: {
                viewModel.shareImage.map { ShareableImage(image: $0) }
            },
            set: { _ in
                viewModel.shareImage = nil
            }
        )) { shareable in
            ShareSheet(items: [shareable.image])
        }
        .alert("Property", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.addressLineText)
                .font(.title2.bold())
            Text(viewModel.localityText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(viewModel.confidenceBadgeTitle)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(viewModel.confidenceBadgeColor.opacity(0.15))
                .clipShape(Capsule())

            Text("Source: \(viewModel.dataSourcesText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var imageSection: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 210)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "house")
                                .font(.largeTitle)
                            Text("No captured image")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(viewModel.isSaved ? "Unsave" : "Save") {
                viewModel.toggleSaved()
            }
            .buttonStyle(.borderedProminent)

            Button("Share") {
                viewModel.prepareShareImage(thumbnail: loadedImage)
            }
            .buttonStyle(.bordered)
        }
    }

    private var cards: some View {
        VStack(spacing: 12) {
            GroupBox("Address Verified") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.property.fullAddress)
                        .font(.headline)
                    Text("GPS: \(viewModel.coordinateText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Accuracy: \(viewModel.accuracyText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Map(
                        coordinateRegion: .constant(MKCoordinateRegion(
                            center: CLLocationCoordinate2D(
                                latitude: viewModel.context.captureLatitude ?? viewModel.property.latitude,
                                longitude: viewModel.context.captureLongitude ?? viewModel.property.longitude
                            ),
                            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
                        )),
                        annotationItems: [VerifiedMapPin(
                            latitude: viewModel.context.captureLatitude ?? viewModel.property.latitude,
                            longitude: viewModel.context.captureLongitude ?? viewModel.property.longitude
                        )]
                    ) { pin in
                        MapAnnotation(coordinate: pin.coordinate) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("At a glance") {
                ProfileKeyValueGrid(rows: [
                    ("Type", viewModel.typeText),
                    ("Beds", viewModel.bedsText),
                    ("Baths", viewModel.bathsText),
                    ("Land size", viewModel.landText),
                    ("Year built", viewModel.yearBuiltText)
                ])
            }

            GroupBox("Value & history") {
                ProfileKeyValueGrid(rows: [
                    ("Est. value", viewModel.valueRangeText),
                    ("Last sale", viewModel.lastSalePriceText),
                    ("Sale date", viewModel.saleDateText)
                ])
            }

            GroupBox("Rent snapshot") {
                ProfileKeyValueGrid(rows: [
                    ("Rent est.", viewModel.rentText),
                    ("Gross yield", viewModel.yieldText)
                ])
            }

            GroupBox("Risks & flags") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.flagsText, id: \.self) { flag in
                        Text("• \(flag)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("AI Summary") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.summaryPoints, id: \.self) { point in
                        Text("• \(point)")
                    }

                    Divider()

                    ForEach(viewModel.conversation) { message in
                        HStack {
                            if message.role == .assistant {
                                bubble(text: message.text, color: Color(.secondarySystemBackground))
                                Spacer()
                            } else {
                                Spacer()
                                bubble(text: message.text, color: Color.accentColor.opacity(0.2))
                            }
                        }
                    }

                    HStack {
                        TextField("Ask a question", text: $viewModel.question)
                            .textFieldStyle(.roundedBorder)
                        Button("Send") {
                            viewModel.sendQuestion()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func bubble(text: String, color: Color) -> some View {
        Text(text)
            .padding(10)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 280, alignment: .leading)
    }

    private var loadedImage: UIImage? {
        guard let photoFilename else {
            return nil
        }
        return environment.photoStorage.loadImage(named: photoFilename)
    }
}

struct ProfileKeyValueGrid: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PropertyShareCardView: View {
    let property: Property
    let thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RESI.AI Property Card")
                .font(.title3.bold())
            Text(property.fullAddress)
                .font(.headline)

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Divider()

            Text(property.estValueLow > 0 && property.estValueHigh > 0
                 ? "Estimated value: \(Formatters.currency(property.estValueLow)) - \(Formatters.currency(property.estValueHigh))"
                 : "Estimated value: Coming soon")
            Text(property.lastSalePrice > 0
                 ? "Last sale: \(Formatters.currency(property.lastSalePrice)) on \(Formatters.shortDate.string(from: property.lastSaleDate))"
                 : "Last sale: Coming soon")
            Text(property.rentEstimateWeekly > 0
                 ? "Rent estimate: \(Formatters.currency(property.rentEstimateWeekly))/week"
                 : "Rent estimate: Coming soon")
                .foregroundStyle(.secondary)
        }
    }
}

private struct VerifiedMapPin: Identifiable {
    let id = UUID()
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct ShareableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}
