//
//  LocationFetcher.swift
//  befriend
//

import CoreLocation
import MapKit
import Observation
import PetCore

/// One approximate location fix, turned into the friend's city-level birthplace.
@Observable
final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private(set) var place: OnboardingLocation?
    private(set) var status: String?
    private(set) var isLocating = false

    @ObservationIgnored private let manager = CLLocationManager()

    func request() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        status = nil
        isLocating = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            fail("Location access is off. You can skip this step.")
        default:
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.isLocating else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .denied, .restricted: self.fail("Location access is off. You can skip this step.")
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in await self.resolve(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.fail("Couldn't find your location. You can skip this step.") }
    }

    private func resolve(_ location: CLLocation) async {
        defer { isLocating = false }
        let item = try? await MKReverseGeocodingRequest(location: location)?.mapItems.first
        let address = item?.addressRepresentations
        // One decimal (~11 km) is all the chart needs; the server rounds again.
        place = OnboardingLocation(
            city: address?.cityName,
            countryCode: address?.region?.identifier,
            latitude: (location.coordinate.latitude * 10).rounded() / 10,
            longitude: (location.coordinate.longitude * 10).rounded() / 10
        )
    }

    private func fail(_ message: String) {
        isLocating = false
        status = message
    }
}
