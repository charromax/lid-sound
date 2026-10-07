import AppKit
import Darwin
import Foundation
import LidSoundCore

let preferences = LidSoundPreferences()
let configurationChangedNotification = Notification.Name("com.charromax.lid-sound.configuration-changed")

enum ANSI {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let cyan = "\u{001B}[36m"
    static let gray = "\u{001B}[90m"
}

func accent(_ text: String) -> String { ANSI.cyan + ANSI.bold + text + ANSI.reset }
func warn(_ text: String) -> String { ANSI.yellow + text + ANSI.reset }
func muted(_ text: String) -> String { ANSI.gray + text + ANSI.reset }

let charr0labsBanner = """
\(ANSI.blue)\(ANSI.bold) ██████╗██╗  ██╗ █████╗ ██████╗ ██████╗  ██████╗ ██╗      █████╗ ██████╗ ███████╗\(ANSI.reset)
\(ANSI.blue)\(ANSI.bold)██╔════╝██║  ██║██╔══██╗██╔══██╗██╔══██╗██╔═══██╗██║     ██╔══██╗██╔══██╗██╔════╝\(ANSI.reset)
\(ANSI.cyan)\(ANSI.bold)██║     ███████║███████║██████╔╝██████╔╝██║   ██║██║     ███████║██████╔╝███████╗\(ANSI.reset)
\(ANSI.cyan)\(ANSI.bold)██║     ██╔══██║██╔══██║██╔══██╗██╔══██╗██║   ██║██║     ██╔══██║██╔══██╗╚════██║\(ANSI.reset)
\(ANSI.bold)╚██████╗██║  ██║██║  ██║██║  ██║██║  ██║╚██████╔╝███████╗██║  ██║██████╔╝███████╗\(ANSI.reset)
\(ANSI.bold) ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝\(ANSI.reset)

                     charr0labs
"""

struct TerminalRawMode {
    private var original = termios()
    private var enabled = false

    mutating func enable() {
        guard !enabled else { return }
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        raw.c_cc.16 = 1
        raw.c_cc.17 = 0
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        enabled = true
    }

    mutating func disable() {
        guard enabled else { return }
        var original = original
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        enabled = false
    }
}

enum Key { case up, down, enter, esc, space, other }

func readKey() -> Key {
    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) == 1 else { return .other }
    if byte == 13 || byte == 10 { return .enter }
    if byte == 32 { return .space }
    if byte == 27 {
        var sequence: [UInt8] = [0, 0]
        if read(STDIN_FILENO, &sequence, 2) == 2, sequence[0] == 91 {
            if sequence[1] == 65 { return .up }
            if sequence[1] == 66 { return .down }
        }
        return .esc
    }
    return .other
}

func clearScreen() {
    print("\u{001B}[2J\u{001B}[H", terminator: "")
}

@MainActor
func playPreview(_ source: URL) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    task.arguments = [source.path]
    do { try task.run() } catch { fputs("Failed to preview sound: \(error)\n", stderr) }
}

@MainActor
func renderSoundMenu(sounds: [URL], selectedIndex: Int) {
    clearScreen()
    print(charr0labsBanner)
    print(accent("[ sound picker ]") + "  " + muted("↑/↓ move") + "  " + muted("Space preview") + "  " + muted("Enter select") + "  " + muted("Esc back") + "\n")
    print(muted("Sounds folder:") + " \(preferences.soundsDirectory.path)\n")
    let labels = ["SOUND OFF"] + sounds.map(\.lastPathComponent)
    for (index, label) in labels.enumerated() {
        if index == selectedIndex {
            print(ANSI.green + ANSI.bold + "> \(label)" + ANSI.reset)
        } else {
            print("  \(label)")
        }
    }
    print("\n" + muted("Tip: add mp3 with `lid-sound add-sounds <dir>`"))
}

@MainActor
func runSetSoundTUI() {
    let sounds = AngleAudioSourceResolver.availableSelectedSounds(preferences: preferences)
    var selectedIndex = sounds.firstIndex { $0.lastPathComponent == preferences.selectedSoundToken }.map { $0 + 1 } ?? 0
    var rawMode = TerminalRawMode()
    rawMode.enable()
    defer {
        rawMode.disable()
        print("")
    }
    while true {
        renderSoundMenu(sounds: sounds, selectedIndex: selectedIndex)
        switch readKey() {
        case .up: selectedIndex = max(0, selectedIndex - 1)
        case .down: selectedIndex = min(sounds.count, selectedIndex + 1)
        case .space:
            if selectedIndex > 0 { playPreview(sounds[selectedIndex - 1]) }
        case .enter:
            preferences.setSelectedSoundToken(selectedIndex == 0 ? LidSoundPreferences.offToken : sounds[selectedIndex - 1].lastPathComponent)
            clearScreen()
            print(charr0labsBanner)
            print("Selected: \(selectedIndex == 0 ? "SOUND OFF" : sounds[selectedIndex - 1].lastPathComponent)")
            return
        case .esc:
            clearScreen()
            print(charr0labsBanner)
            print("Canceled.")
            return
        case .other: continue
        }
    }
}

@MainActor
func seedDefaultSoundsIfNeeded() {
    do {
        let sourceDirectories = [
            Bundle.module.url(forResource: "sounds", withExtension: nil),
            URL(fileURLWithPath: "/opt/homebrew/share/lid-sound/sounds", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/share/lid-sound/sounds", isDirectory: true),
            Bundle.main.executableURL?
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("share/lid-sound/sounds", isDirectory: true)
        ].compactMap { $0 }
        try DefaultSoundSeeder.seedIfNeeded(
            destination: preferences.soundsDirectory,
            sourceDirectories: sourceDirectories
        )
    } catch {
        fputs("Unable to seed default sounds: \(error)\n", stderr)
    }
}

func printUsage() {
    print(charr0labsBanner)
    print("""
    Usage:
      lid-sound run
      lid-sound status
      lid-sound set-sound
      lid-sound set-angle-mode [bundled-loop|selected-sound]
      lid-sound add-sounds [directory]

    `set-angle-mode` shows the current mode when no value is supplied and prompts
    to choose a new mode. The selected-sound mode loops the selected file, so
    arbitrary files can have audible loop boundaries.
    """)
}

@MainActor
func selectedSoundURL() -> URL? {
    AngleAudioSourceResolver.selectedSoundURL(preferences: preferences)
}

func notifyConfigurationChanged() {
    DistributedNotificationCenter.default().postNotificationName(
        configurationChangedNotification,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
}

@MainActor
func reloadAngleAudio(_ audio: ContinuousAudioController) {
    guard let source = AngleAudioSourceResolver.resolve(mode: preferences.angleMode, preferences: preferences) else {
        audio.stop()
        print(warn("Angle audio stopped: no source is available for the selected mode."))
        return
    }
    do {
        try audio.prepare(source: source)
        print("Angle-audio source reloaded: \(source.lastPathComponent)")
    } catch {
        audio.stop()
        fputs("Unable to reload angle-audio source: \(error)\n", stderr)
    }
}

@MainActor
func runAngleListener(probe: MacLidAngleProbe, source: URL?) {
    let audio = ContinuousAudioController()
    let sensor = LidAngleSensorService(probe: probe)
    do {
        if let source {
            try audio.prepare(source: source)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: configurationChangedNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                reloadAngleAudio(audio)
            }
        }
        try sensor.start { audio.apply($0) }
        RunLoop.main.run()
    } catch {
        sensor.stop()
        audio.stop()
        fputs("Angle audio failed to start: \(error). Wake fallback remains active.\n", stderr)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            Task { @MainActor in playWakeFallback() }
        }
        RunLoop.main.run()
    }
}

@MainActor
func playWakeFallback() {
    guard let source = selectedSoundURL() else {
        print("[didWake] SOUND OFF")
        return
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    task.arguments = [source.path]
    do { try task.run() } catch { fputs("Failed to run afplay: \(error)\n", stderr) }
}

@MainActor
func printStatus(diagnostic: LidSensorDiagnostic) {
    print("Current sound: \(preferences.selectedSoundToken)")
    print("Sounds dir: \(preferences.soundsDirectory.path)")
    for line in LidSoundStatus.lines(
        diagnostic: diagnostic,
        mode: preferences.angleMode,
        selectedSoundAvailable: selectedSoundURL() != nil
    ) {
        print(line)
    }
}

let args = CommandLine.arguments
let command = args.dropFirst().first?.lowercased() ?? "run"
seedDefaultSoundsIfNeeded()

switch command {
case "help", "-h", "--help":
    printUsage()
case "set-angle-mode":
    if let value = args.dropFirst(2).first, let mode = AngleAudioMode(rawValue: value) {
        preferences.setAngleMode(mode)
        notifyConfigurationChanged()
        print("Angle-audio mode: \(mode.rawValue)")
    } else if args.count == 2 {
        print("Current angle-audio mode: \(preferences.angleMode.rawValue)")
        print("Choose bundled-loop or selected-sound:")
        if let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
           let mode = AngleAudioMode(rawValue: response) {
            preferences.setAngleMode(mode)
            notifyConfigurationChanged()
            print("Angle-audio mode: \(mode.rawValue)")
        } else {
            print("Mode unchanged.")
        }
    } else {
        fputs("Invalid angle-audio mode. Use bundled-loop or selected-sound.\n", stderr)
        exit(2)
    }
case "status":
    let probe = MacLidAngleProbe()
    print(charr0labsBanner)
    printStatus(diagnostic: LidSensorDiagnostics.probe(probe))
    probe.close()
case "set-sound":
    runSetSoundTUI()
    notifyConfigurationChanged()
case "add-sounds":
    let sourceDirectory = args.dropFirst(2).first.map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
    }
    do {
        if let sourceDirectory {
            try SoundLibrary.importSounds(
                from: sourceDirectory,
                into: preferences.soundsDirectory
            )
        } else {
            try FileManager.default.createDirectory(at: preferences.soundsDirectory, withIntermediateDirectories: true)
        }
        print("Sounds directory: \(preferences.soundsDirectory.path)")
    } catch {
        fputs("Unable to add sounds: \(error)\n", stderr)
        exit(1)
    }
case "run":
    let probe = MacLidAngleProbe()
    let diagnostic = LidSensorDiagnostics.probe(probe)
    print(charr0labsBanner)
    print(accent("lid-sound") + " " + muted("running…"))
    printStatus(diagnostic: diagnostic)
    let source = AngleAudioSourceResolver.resolve(mode: preferences.angleMode, preferences: preferences)
    switch ListenerSelection.resolve(diagnostic: diagnostic, source: source) {
    case .continuous(let source):
        runAngleListener(probe: probe, source: source)
    case .continuousSilence(let reason):
        print(reason)
        runAngleListener(probe: probe, source: nil)
    case .wakeFallback:
        probe.close()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            Task { @MainActor in playWakeFallback() }
        }
        RunLoop.main.run()
    }
default:
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exit(2)
}
