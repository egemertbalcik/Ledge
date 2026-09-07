import CoreLocation
import Foundation
import MapKit
import os

/// Where you are, coarsely, plus the name of the place.
public struct PlaceFix: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Locality name for the card's title. Empty when reverse geocoding fails,
    /// which is not an error — the forecast is still valid without a label.
    public var name: String

    public init(latitude: Double, longitude: Double, name: String = "") {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }
}

/// Where a location fix comes from.
@MainActor
public protocol LocationProviding: AnyObject {
    /// The current place, or nil when permission is absent or no fix arrives.
    /// Failure is normal and must stay quiet — weather falls back to a typed
    /// city.
    func current() async -> PlaceFix?
}

/// A single coarse location fix from CoreLocation.
///
/// Deliberately one-shot rather than a continuous subscription: weather is
/// refreshed on a slow timer, and holding a live location subscription for it
/// would keep the location indicator lit and cost battery for a value that
/// changes when you travel, not second to second.
///
/// Accuracy is reduced on purpose. A forecast is a city-scale question, and
/// asking for `kCLLocationAccuracyReduced` means macOS can answer from its
/// coarse cache without waking GPS.
@MainActor
public final class CoreLocationSource: NSObject, LocationProviding, CLLocationManagerDelegate {

    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "weather")

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<PlaceFix?, Never>] = []

    /// The last good fix. Reused when a later request times out, so a temporary
    /// failure shows yesterday's city rather than removing the card.
    private var lastFix: PlaceFix?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    public func current() async -> PlaceFix? {
        guard CLLocationManager.locationServicesEnabled() else { return lastFix }

        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            break
        case .notDetermined:
            // Never prompt from here. The prompt belongs to the Permissions tab,
            // where the user asked for it — a card refresh must not raise a
            // system dialog on its own.
            return lastFix
        default:
            return lastFix
        }

        // A cached fix macOS already has is good enough for a forecast and
        // arrives instantly; only ask for a fresh one when there is none.
        if let cached = manager.location {
            let fix = await named(cached)
            lastFix = fix
            return fix
        }

        let fix: PlaceFix? = await withCheckedContinuation { continuation in
            waiting.append(continuation)
            manager.requestLocation()
            // Failsafe: CoreLocation owes us either a fix or an error, but a
            // wedged delegate (or a reverse-geocode hanging before the
            // resume) must not freeze every weather fetch behind an await
            // that never returns. `resumeAll` drains, so a late fulfilment
            // finds nobody waiting and is a no-op.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                self?.resumeAll(with: nil)
            }
        }
        if let fix { lastFix = fix }
        return fix ?? lastFix
    }

    /// Reverse-geocodes to a locality. The forecast does not need it; the card's
    /// title does.
    private func named(_ location: CLLocation) async -> PlaceFix {
        let coordinate = location.coordinate
        return PlaceFix(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            name: await Self.placeName(for: location)
        )
    }

    /// `MKReverseGeocodingRequest` rather than `CLGeocoder`, which macOS 26
    /// deprecates. A failure here costs the card its title, nothing more.
    ///
    /// `nonisolated` and returning a plain `String` on purpose: `MKMapItem` is
    /// not `Sendable`, so the result has to be reduced to something that is
    /// before it can cross back to the main actor.
    private nonisolated static func placeName(for location: CLLocation) async -> String {
        // Bounded: Apple's geocoding service can hang, and this await sits on
        // the weather fetch's critical path — an unbounded stall here kept
        // the card off screen with no retry and no log. Two seconds, then
        // the forecast simply goes untitled.
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                guard let request = MKReverseGeocodingRequest(location: location),
                      let items = try? await request.mapItems,
                      let item = items.first
                else { return "" }
                return Self.locality(from: item.address?.shortAddress ?? item.name ?? "")
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? ""
        }
    }

    /// Reduces an address to the place a forecast is about.
    ///
    /// Reverse geocoding answers with the nearest thing it knows, which is
    /// usually a street: "201 Brookline Ave, Boston". A forecast is a
    /// city-scale question, and a street address is both wrong for the card and
    /// more than anyone wants displayed in their notch.
    ///
    /// The rule: drop leading components that carry a house number, keep the
    /// first that does not. That turns "201 Brookline Ave, Boston" into
    /// "Boston" while leaving an already-clean "Boston, MA" as "Boston".
    nonisolated static func locality(from address: String) -> String {
        let parts = address
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        let named = parts.first { !$0.contains(where: \.isNumber) }
        return named ?? parts[0]
    }

    // MARK: - CLLocationManagerDelegate

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let fix = await self.named(location)
            self.resumeAll(with: fix)
        }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        Self.log.debug("location: no fix — \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in self.resumeAll(with: nil) }
    }

    /// Resumes every waiter exactly once. `requestLocation` can report both a
    /// location and an error, and a continuation resumed twice is a crash.
    private func resumeAll(with fix: PlaceFix?) {
        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume(returning: fix) }
    }
}

