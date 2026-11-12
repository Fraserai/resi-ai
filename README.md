# RESI.AI (iOS MVP)

SwiftUI iOS 17+ MVP for scanning a property photo, resolving the most likely nearby address, and viewing a property profile with a mocked AI-style summary.

## What is implemented

- Full tab app: `Scan`, `Search`, `Saved`, `Settings`
- Camera scan flow with AVFoundation capture UI (flash/shutter/close)
- Location + heading capture (CoreLocation)
- Address matching flow with confidence routing:
  - auto-select when confidence >= 0.75
  - confirm top candidates when confidence is lower
  - map picker fallback
- Property profile screen with:
  - structured cards
  - mocked AI summary bullets
  - Ask-a-question field + fake response chat
  - Save/Unsave
  - Share property-card image
- Local persistence (SwiftData models):
  - scan history
  - cached property records
  - saved state
- Local photo storage in app support directory
- Settings action to delete all local history + photos

## Matching logic (MVP)

Implemented in `RESIAI/Services.swift` (`PropertyMatcher`):

1. Query nearby candidates within radius `max(75m, accuracyMeters * 1.2)`
2. Score each candidate
   - `base = 1 / (1 + distanceMeters)`
   - heading bonus `+0.15` if bearing is within +/-45° of user heading
3. Rank by score
4. Overall confidence = `topScore / (topScore + secondScore)`
5. Route:
   - `>= 0.75` => auto profile
   - `< 0.75` => confirm candidates
   - none => error state with retry/map/search fallback

## Project architecture

- MVVM per feature screen
- Protocol-first services and dependency injection via `AppEnvironment`
- Pluggable provider interfaces:
  - `PropertyDataProviderProtocol`
  - `PropertyMatcherProtocol`
  - `AISummaryServiceProtocol`
  - `LocationServiceProtocol`
  - `CameraServiceProtocol`
  - `PersistenceServiceProtocol`

## Where to plug real APIs

- Real property data provider:
  - replace `MockPropertyDataProvider` in `RESIAI/Services.swift`
  - wire in `RESIAI/RESIAIApp.swift`
- Real AI summary/Q&A:
  - replace `FakeAISummaryService` in `RESIAI/Services.swift`
  - wire in `RESIAI/RESIAIApp.swift`

## Storage/privacy behavior

- Photos are saved locally in app support (`ScanPhotos` folder)
- Scan/property records are stored locally via SwiftData
- `Delete all history` clears scans, cached properties, and stored photos

## Build notes

Open `RESIAI.xcodeproj` in Xcode and run target `RESIAI` on iOS 17+.
