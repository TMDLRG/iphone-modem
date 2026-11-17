import CoreLocation

/// Second keep-alive, for phone calls.
///
/// The silent audio in `BackgroundKeeper` is what lets Modem run with the screen
/// locked, but a phone call takes over the audio session: the silence stops, iOS
/// sees an app with nothing playing, and it suspends Modem a few seconds after
/// the Phone screen covers it. The PC then loses its connection until Modem is
/// opened again.
///
/// Background location is not interrupted by calls, and iOS keeps an app with
/// active location updates running, so this asks for the cheapest kind of
/// location (kilometre accuracy, no GPS) purely as a reason to stay alive.
/// Every location that arrives is thrown away: nothing is read, stored or sent.
final class LocationKeeper: NSObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case off
        case asking        // waiting for the user to answer the permission prompt
        case active
        case denied        // the user refused (or a profile forbids) location for Modem
        case unavailable   // this build lacks the location background mode
    }

    /// Called whenever `state` changes.
    var onState: ((State) -> Void)?

    private(set) var state: State = .off {
        didSet {
            if state != oldValue {
                onState?(state)
            }
        }
    }

    private let manager = CLLocationManager()
    private var wanted = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers   // cell and Wi-Fi only, never GPS
        manager.distanceFilter = 1000
        manager.activityType = .other
        // If iOS were allowed to pause updates when the phone sits still, it
        // would also stop keeping the app alive.
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        wanted = true
        evaluate()
    }

    func stop() {
        wanted = false
        halt()
        state = .off
    }

    private func evaluate() {
        guard wanted else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            state = .asking
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        case .denied, .restricted:
            halt()
            state = .denied
        @unknown default:
            break
        }
    }

    private func begin() {
        // Turning on background updates without the matching Info.plist entry
        // crashes the app, so check first.
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        guard modes.contains("location") else {
            state = .unavailable
            return
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        state = .active
    }

    private func halt() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        evaluate()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Intentionally empty. The updates only exist to keep the app running.
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Most errors (no fix yet, for example) are transient and need no action.
        if (error as? CLError)?.code == .denied {
            halt()
            state = .denied
        }
    }
}
