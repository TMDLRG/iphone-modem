import AVFoundation

/// Keeps the app running in the background by playing silence. iOS suspends
/// ordinary apps a few seconds after they leave the screen, which would cut the
/// PC off; an app with an active audio session keeps running. A phone call
/// interrupts this audio, which is why `LocationKeeper` exists as well.
final class BackgroundKeeper {
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

    /// Starts the silent audio, or resumes it if something paused it.
    /// Returns an error message if the audio session could not be started.
    @discardableResult
    func start() -> String? {
        do {
            let session = AVAudioSession.sharedInstance()
            if let current = player {
                if !current.isPlaying {
                    try session.setActive(true)
                    current.play()
                }
                return nil
            }
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let newPlayer = try AVAudioPlayer(data: Self.silence())
            newPlayer.numberOfLoops = -1
            newPlayer.volume = 0
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer
            if observers.isEmpty {
                let center = NotificationCenter.default
                observers.append(center.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
                ) { [weak self] notification in
                    self?.handleInterruption(notification)
                })
                observers.append(center.addObserver(
                    forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    self?.handleMediaServicesReset()
                })
            }
            return nil
        } catch {
            return "Background mode unavailable: \(error.localizedDescription)"
        }
    }

    /// Quietly restarts the silence if it has stopped (a call that has ended, for
    /// example, when iOS didn't send the "ended" event). While a call is still in
    /// progress iOS refuses to activate the session; that is ignored and the
    /// caller simply tries again later.
    func resumeIfStopped() {
        guard let current = player, !current.isPlaying else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            current.play()
        } catch {
            // Still interrupted.
        }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        guard let current = player else { return }
        current.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// A phone call or alarm pauses our audio; start it again afterwards.
    /// iOS doesn't always send the "ended" event, so the app also calls
    /// start() whenever it comes back to the foreground.
    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw),
              type == .ended,
              player != nil else { return }
        start()
    }

    /// The system audio service restarted, which invalidates our player.
    private func handleMediaServicesReset() {
        guard player != nil else { return }
        player = nil
        start()
    }

    /// One second of 8 kHz, 16-bit mono silence as an in-memory WAV file.
    private static func silence() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: Array(value.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + dataSize); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        text("data"); u32(dataSize)
        wav.append(Data(count: Int(dataSize)))
        return wav
    }
}
