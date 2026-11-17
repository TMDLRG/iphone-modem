import Foundation
import Network
import UIKit

/// App state: runs the proxy server, watches cellular availability, and keeps
/// the app alive while tethering.
@MainActor
final class TetherController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var serverHealthy = false
    @Published private(set) var serverStatus = "Stopped"
    @Published private(set) var cellularAvailable = false
    @Published private(set) var cellularDetail = "Checking cellular data..."
    @Published private(set) var stats = ProxyStats.Snapshot()
    @Published private(set) var events: [String] = []
    @Published var keepRunningInBackground: Bool {
        didSet {
            UserDefaults.standard.set(keepRunningInBackground, forKey: Self.backgroundKey)
            applyBackgroundBehaviour()
        }
    }
    /// Stay alive through phone calls (uses iOS location services as the reason to keep running).
    @Published var keepRunningDuringCalls: Bool {
        didSet {
            UserDefaults.standard.set(keepRunningDuringCalls, forKey: Self.callsKey)
            applyBackgroundBehaviour()
        }
    }
    @Published private(set) var callKeepAlive = LocationKeeper.State.off

    private static let backgroundKey = "keepRunningInBackground"
    private static let callsKey = "keepRunningDuringCalls"
    private var server: ProxyServer?
    private let cellularMonitor = NWPathMonitor(requiredInterfaceType: .cellular)
    private let keeper = BackgroundKeeper()
    private let locationKeeper = LocationKeeper()
    private var statsTimer: Timer?
    private var ticks = 0
    private var didAutoStart = false
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init() {
        keepRunningInBackground = UserDefaults.standard.object(forKey: Self.backgroundKey) as? Bool ?? true
        keepRunningDuringCalls = UserDefaults.standard.object(forKey: Self.callsKey) as? Bool ?? true
        locationKeeper.onState = { [weak self] state in
            Task { @MainActor [weak self] in self?.applyCallKeepAlive(state) }
        }
        cellularMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                self?.updateCellular(available: available, constrained: constrained)
            }
        }
        cellularMonitor.start(queue: DispatchQueue(label: "modem.cellular"))
    }

    /// Starts tethering the first time the UI appears, so a freshly opened app is ready to go.
    func autoStart() {
        guard !didAutoStart else { return }
        didAutoStart = true
        start()
    }

    /// Called whenever the app comes to the foreground: resumes background
    /// audio if a call or alarm stopped it without telling us.
    func appBecameActive() {
        applyBackgroundBehaviour()
    }

    func start() {
        guard server == nil else { return }
        let newServer = ProxyServer()
        newServer.onLog = { [weak self] message in
            Task { @MainActor [weak self] in self?.record(message) }
        }
        newServer.onState = { [weak self] state in
            Task { @MainActor [weak self] in self?.apply(state) }
        }
        server = newServer
        isRunning = true
        serverHealthy = false
        serverStatus = "Starting..."
        newServer.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStats() }
        }
        applyBackgroundBehaviour()
        record("Tethering started")
    }

    func stop() {
        guard let current = server else { return }
        current.stop()
        server = nil
        isRunning = false
        serverHealthy = false
        serverStatus = "Stopped"
        statsTimer?.invalidate()
        statsTimer = nil
        applyBackgroundBehaviour()
        record("Tethering stopped")
    }

    private func apply(_ state: ProxyServer.State) {
        guard isRunning else { return }
        switch state {
        case .starting:
            serverHealthy = false
            serverStatus = "Starting..."
        case .ready(let port, let loopbackOnly):
            serverHealthy = true
            serverStatus = "Ready for the PC over USB (port \(port)" + (loopbackOnly ? ")" : ", filtered)")
        case .failed(let message):
            serverHealthy = false
            serverStatus = "Problem: \(message). Retrying..."
        }
    }

    private func refreshStats() {
        guard let server = server else { return }
        let latest = server.stats.snapshot()
        if latest != stats {
            stats = latest
        }
        // A call can end without iOS telling us, leaving the silence stopped.
        ticks += 1
        if ticks % 5 == 0 && keepRunningInBackground {
            keeper.resumeIfStopped()
        }
    }

    private func applyCallKeepAlive(_ state: LocationKeeper.State) {
        guard state != callKeepAlive else { return }
        callKeepAlive = state
        switch state {
        case .off:
            break
        case .asking:
            record("Asking for location permission, used only to keep Modem running during calls")
        case .active:
            record("Call keep-alive on")
        case .denied:
            record("Location is off for Modem, so a phone call can pause it. Allow it in Settings > Modem > Location.")
        case .unavailable:
            record("Call keep-alive unavailable: this build lacks the location background mode")
        }
    }

    private func updateCellular(available: Bool, constrained: Bool) {
        cellularAvailable = available
        if !available {
            cellularDetail = "No cellular data. Turn on Cellular Data and allow Modem to use it in Settings > Cellular."
        } else if constrained {
            cellularDetail = "Cellular data available (Low Data Mode is on)"
        } else {
            cellularDetail = "Cellular data available"
        }
    }

    private func applyBackgroundBehaviour() {
        if isRunning && keepRunningInBackground {
            if let problem = keeper.start() {
                record(problem)
            }
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            keeper.stop()
            // Without background audio, iOS would suspend the app when the
            // screen locks, so keep the screen on while tethering.
            UIApplication.shared.isIdleTimerDisabled = isRunning
        }
        // The audio above stops during a phone call; location keeps the app
        // running through it.
        if isRunning && keepRunningDuringCalls {
            locationKeeper.start()
        } else {
            locationKeeper.stop()
        }
    }

    private func record(_ message: String) {
        events.insert("\(timeFormatter.string(from: Date()))  \(message)", at: 0)
        if events.count > 40 {
            events.removeLast(events.count - 40)
        }
    }
}
