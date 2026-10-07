import Foundation

public enum LidSensorDiagnostic: Equatable {
    case readable
    case absent
    case unreadable(String)

    public var availabilityText: String {
        switch self {
        case .readable: "available: input reports ready"
        case .absent: "unavailable: no compatible lid-angle sensor found"
        case .unreadable(let reason): "unavailable: \(reason)"
        }
    }
}

public protocol LidAngleProbe {
    func checkReadiness() -> Result<Void, Error>?
}

public enum LidSensorDiagnostics {
    public static func probe(_ probe: LidAngleProbe?) -> LidSensorDiagnostic {
        guard let probe else { return .absent }
        guard let readiness = probe.checkReadiness() else { return .unreadable("the sensor could not be opened") }
        switch readiness {
        case .success:
            return .readable
        case .failure(let error):
            return .unreadable("input report setup failed: \(error.localizedDescription)")
        }
    }
}

public enum LidAngleReport {
    public static func decode(_ bytes: [UInt8], reportID: UInt8? = nil) -> Double? {
        let payload: ArraySlice<UInt8>
        if reportID == 1 {
            payload = bytes.first == 1 ? bytes.dropFirst() : bytes[...]
        } else {
            payload = bytes[...]
        }
        guard payload.count >= 2 else { return nil }
        let value = UInt16(payload[payload.startIndex]) | UInt16(payload[payload.index(after: payload.startIndex)]) << 8
        let angle = Double(value)
        return (0...360).contains(angle) ? angle : nil
    }
}

public struct AngleAudioOutput: Equatable {
    public let gain: Float
    public let rate: Float
}

public struct MotionAudioProcessor {
    public static let maximumAngle = 130.0
    public static let stationarySpeed = 1.5
    public static let maximumSpeed = 15.0
    public static let minimumRate: Float = 0.8
    public static let maximumRate: Float = 1.5
    private let smoothing: Double
    private var lastAngle: Double?
    private var lastTime: TimeInterval?
    private var smoothedSpeed = 0.0

    public init(smoothing: Double = 0.25) {
        self.smoothing = smoothing
    }

    public mutating func process(angle: Double, at time: TimeInterval) -> AngleAudioOutput {
        let normalizedAngle = min(max(angle / Self.maximumAngle, 0), 1)
        defer {
            lastAngle = angle
            lastTime = time
        }
        guard let lastAngle, let lastTime else {
            return AngleAudioOutput(gain: 0, rate: rate(for: normalizedAngle))
        }
        let elapsed = max(time - lastTime, 0.001)
        let rawSpeed = abs(angle - lastAngle) / elapsed
        smoothedSpeed += smoothing * (rawSpeed - smoothedSpeed)
        let normalizedSpeed = min(max(
            (smoothedSpeed - Self.stationarySpeed) / (Self.maximumSpeed - Self.stationarySpeed),
            0
        ), 1)
        return AngleAudioOutput(
            gain: Float(normalizedSpeed),
            rate: rate(for: normalizedAngle)
        )
    }

    public func stationaryOutput() -> AngleAudioOutput {
        let normalizedAngle = min(max((lastAngle ?? 0) / Self.maximumAngle, 0), 1)
        return AngleAudioOutput(gain: 0, rate: rate(for: normalizedAngle))
    }

    private func rate(for normalizedAngle: Double) -> Float {
        Self.minimumRate + Float(normalizedAngle) * (Self.maximumRate - Self.minimumRate)
    }
}

public enum ContinuousAudioCommand: Equatable {
    case start(AngleAudioOutput)
    case update(AngleAudioOutput)
    case mute(AngleAudioOutput)
    case resume(AngleAudioOutput)
}

public struct ContinuousAudioState {
    private var hasStarted = false
    private var isMuted = true

    public init() {}

    public mutating func command(for output: AngleAudioOutput) -> ContinuousAudioCommand {
        guard output.gain > 0 else {
            isMuted = true
            return .mute(output)
        }
        defer {
            hasStarted = true
            isMuted = false
        }
        guard hasStarted else { return .start(output) }
        return isMuted ? .resume(output) : .update(output)
    }
}

public struct AudioParameterSmoother {
    public static let defaultAttack: TimeInterval = 0.025
    public static let defaultRelease: TimeInterval = 0.075
    public static let defaultRateTime: TimeInterval = 0.05
    private let attack: TimeInterval
    private let release: TimeInterval
    private let rateTime: TimeInterval
    private var current = AngleAudioOutput(gain: 0, rate: 1)
    private var lastTime: TimeInterval?

    public init(
        attack: TimeInterval = Self.defaultAttack,
        release: TimeInterval = Self.defaultRelease,
        rateTime: TimeInterval = Self.defaultRateTime
    ) {
        self.attack = attack
        self.release = release
        self.rateTime = rateTime
    }

    public mutating func apply(_ target: AngleAudioOutput, at time: TimeInterval) -> AngleAudioOutput {
        let target = AngleAudioOutput(
            gain: min(max(target.gain, 0), 1),
            rate: min(max(target.rate, 0.25), 4)
        )
        defer { lastTime = time }
        guard let lastTime else {
            current = AngleAudioOutput(gain: 0, rate: target.rate)
            return current
        }
        let elapsed = min(max(time - lastTime, 0), 1.0 / 30.0)
        current = AngleAudioOutput(
            gain: ramp(current.gain, toward: target.gain, over: target.gain > current.gain ? attack : release, elapsed: elapsed),
            rate: ramp(current.rate, toward: target.rate, over: rateTime, elapsed: elapsed)
        )
        return current
    }

    public mutating func finishRelease(at time: TimeInterval) {
        current = AngleAudioOutput(gain: 0, rate: current.rate)
        lastTime = time
    }

    private func ramp(_ value: Float, toward target: Float, over duration: TimeInterval, elapsed: TimeInterval) -> Float {
        guard duration > 0 else { return target }
        let factor = 1 - exp(-elapsed / duration)
        return value + (target - value) * Float(factor)
    }
}

public enum AngleAudioMode: String, CaseIterable {
    case bundledLoop = "bundled-loop"
    case selectedSound = "selected-sound"
}

public protocol PreferencesStore {
    func string(forKey key: String) -> String?
    func setString(_ value: String, forKey key: String)
}

extension UserDefaults: PreferencesStore {
    public func setString(_ value: String, forKey key: String) {
        set(value, forKey: key)
    }
}

public struct LidSoundPreferences {
    public static let selectedSoundKey = "lid_sound_selected_sound"
    public static let soundsDirectoryKey = "lid_sound_sounds_dir"
    public static let angleModeKey = "lid_sound_angle_audio_mode"
    public static let offToken = "OFF"
    private let store: PreferencesStore

    public init(store: PreferencesStore = UserDefaults.standard) {
        self.store = store
    }

    public var angleMode: AngleAudioMode {
        AngleAudioMode(rawValue: store.string(forKey: Self.angleModeKey) ?? "") ?? .bundledLoop
    }

    public func setAngleMode(_ mode: AngleAudioMode) {
        store.setString(mode.rawValue, forKey: Self.angleModeKey)
    }

    public var selectedSoundToken: String {
        store.string(forKey: Self.selectedSoundKey).flatMap { $0.isEmpty ? nil : $0 } ?? Self.offToken
    }

    public func setSelectedSoundToken(_ token: String) {
        store.setString(token, forKey: Self.selectedSoundKey)
    }

    public var soundsDirectory: URL {
        if let path = store.string(forKey: Self.soundsDirectoryKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lid-sound/sounds", isDirectory: true)
    }

    public func setSoundsDirectory(_ directory: URL) {
        store.setString(directory.path, forKey: Self.soundsDirectoryKey)
    }
}

public enum AngleAudioSourceResolver {
    public static func bundledLoopURL(fileManager: FileManager = .default) -> URL? {
        let candidates = [
            Bundle.module.url(forResource: "lid-motion-loop", withExtension: "mp3"),
            URL(fileURLWithPath: "/opt/homebrew/share/lid-sound/lid-motion-loop.mp3"),
            URL(fileURLWithPath: "/usr/local/share/lid-sound/lid-motion-loop.mp3"),
            Bundle.main.executableURL?
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("share/lid-sound/lid-motion-loop.mp3")
        ].compactMap { $0 }
        return candidates.first(where: { fileManager.isReadableFile(atPath: $0.path) })
    }

    public static func selectedSoundURL(preferences: LidSoundPreferences, fileManager: FileManager = .default) -> URL? {
        let token = preferences.selectedSoundToken
        guard token != LidSoundPreferences.offToken,
              !token.contains("/"), !token.contains("..") else { return nil }
        let url = preferences.soundsDirectory.appendingPathComponent(token)
        return fileManager.isReadableFile(atPath: url.path) ? url : nil
    }

    public static func availableSelectedSounds(preferences: LidSoundPreferences, fileManager: FileManager = .default) -> [URL] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: preferences.soundsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func resolve(mode: AngleAudioMode, preferences: LidSoundPreferences) -> URL? {
        switch mode {
        case .bundledLoop: bundledLoopURL()
        case .selectedSound: selectedSoundURL(preferences: preferences)
        }
    }
}

public enum DefaultSoundSeeder {
    public static func seedIfNeeded(
        destination: URL,
        sourceDirectories: [URL],
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard SoundLibrary.soundFiles(in: destination, fileManager: fileManager).isEmpty else { return }
        for sourceDirectory in sourceDirectories {
            for source in SoundLibrary.soundFiles(in: sourceDirectory, fileManager: fileManager) {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                if !fileManager.fileExists(atPath: target.path) {
                    try fileManager.copyItem(at: source, to: target)
                }
            }
        }
    }
}

public enum SoundLibrary {
    public static func soundFiles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func importSounds(
        from sourceDirectory: URL,
        into destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        for source in soundFiles(in: sourceDirectory, fileManager: fileManager) {
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: source, to: destination)
            }
        }
    }
}

public enum ListenerMode: Equatable {
    case continuous(URL)
    case wakeFallback
    case continuousSilence(String)
}

public enum ListenerSelection {
    public static func resolve(diagnostic: LidSensorDiagnostic, source: URL?) -> ListenerMode {
        guard diagnostic == .readable else { return .wakeFallback }
        guard let source else { return .continuousSilence("No selected angle-audio source is available.") }
        return .continuous(source)
    }
}

public enum LidSoundStatus {
    public static func lines(diagnostic: LidSensorDiagnostic, mode: AngleAudioMode, selectedSoundAvailable: Bool) -> [String] {
        var lines = [
            "Angle sensor: \(diagnostic.availabilityText)",
            "Angle-audio mode: \(mode.rawValue)"
        ]
        if mode == .selectedSound && !selectedSoundAvailable {
            lines.append("Angle audio: unavailable because no selected sound can be loaded")
        }
        return lines
    }
}
