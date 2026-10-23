import AppKit

@MainActor
final class AudioPlayer: NSObject, NSSoundDelegate {
    private var sound: NSSound?

    func play(fileName: String, fileExtension: String) {
        stop()
        guard let url = Bundle.main.url(forResource: fileName, withExtension: fileExtension),
              let next = NSSound(contentsOf: url, byReference: false) else {
            AppLogger.log("Welcome sound is unavailable", category: .warning)
            return
        }
        sound = next
        next.delegate = self
        if !next.play() { sound = nil }
    }

    func stop() {
        sound?.delegate = nil
        _ = sound?.stop()
        sound = nil
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        let identifier = ObjectIdentifier(sound)
        Task { @MainActor [weak self] in
            if self?.sound.map(ObjectIdentifier.init) == identifier { self?.sound = nil }
        }
    }
}
