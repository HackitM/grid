import AppKit
import CoreLocation
import GridCore
import Observation

/// ⌖ LOCATE: one location fix per click, through CoreLocation "when in use". GRID asks only when
/// you click Locate (after its own explanation), never retries on its own, and keeps the fix in
/// memory only: it is never written to disk, logged or put in a URL.
@Observable
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle
        /// GRID's own explanation is showing, before macOS is asked.
        case explaining
        case asking
        case locating
        case fix(LonLat, accuracy: Double, at: Date)
        case denied
        case restricted
        case servicesOff
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var wantsFix = false

    var fix: (LonLat, Double)? {
        if case .fix(let p, let acc, _) = state { return (p, acc) }
        return nil
    }

    /// The ⌖ button. Shows GRID's explanation first if macOS hasn't been asked yet.
    func locate() {
        guard CLLocationManager.locationServicesEnabled() else { state = .servicesOff; return }
        let m = manager ?? makeManager()
        switch m.authorizationStatus {
        case .notDetermined: state = .explaining
        case .denied: state = .denied
        case .restricted: state = .restricted
        default: request(m)
        }
    }

    /// "Continue" on GRID's explanation: asks macOS (the system prompt appears once).
    func confirmAndAsk() {
        let m = manager ?? makeManager()
        state = .asking
        wantsFix = true
        m.requestWhenInUseAuthorization()
        // macOS may not call back if the prompt is answered elsewhere; re-check shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.authorizationChanged() }
    }

    func cancel() { if state == .explaining || state == .asking { state = .idle }; wantsFix = false }

    /// Forgets the fix (e.g. when the Map page closes).
    func clear() { if case .fix = state { state = .idle } }

    private func makeManager() -> CLLocationManager {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager = m
        return m
    }

    private func request(_ m: CLLocationManager) {
        state = .locating
        wantsFix = false
        m.requestLocation()
    }

    private func authorizationChanged() {
        guard let m = manager else { return }
        switch m.authorizationStatus {
        case .authorizedAlways, .authorized:
            if wantsFix || state == .asking { request(m) }
        case .denied: if state == .asking || wantsFix { state = .denied; wantsFix = false }
        case .restricted: if state == .asking || wantsFix { state = .restricted; wantsFix = false }
        default: break
        }
    }

    // MARK: CLLocationManagerDelegate (called on the main thread: the manager was made there)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { authorizationChanged() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let p = LonLat(lon: l.coordinate.longitude, lat: l.coordinate.latitude)
        let acc = l.horizontalAccuracy, t = l.timestamp
        MainActor.assumeIsolated {
            guard p.isValid, acc >= 0 else { state = .failed("macOS returned an unusable position."); return }
            state = .fix(p, accuracy: acc, at: t)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let ns = error as NSError
        MainActor.assumeIsolated {
            if ns.domain == kCLErrorDomain && ns.code == CLError.denied.rawValue { state = .denied }
            else if ns.domain == kCLErrorDomain && ns.code == CLError.locationUnknown.rawValue { state = .failed("Location unknown right now. Try again in a moment.") }
            else { state = .failed("Couldn't get a location (\(ns.code)).") }
        }
    }
}
