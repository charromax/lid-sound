import Foundation
import AppKit
import Darwin

// MARK: - ANSI / Banner

enum ANSI {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"

    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let magenta = "\u{001B}[35m"
    static let cyan = "\u{001B}[36m"
    static let gray = "\u{001B}[90m"
}

func accent(_ s: String) -> String { ANSI.cyan + ANSI.bold + s + ANSI.reset }
func warn(_ s: String) -> String { ANSI.yellow + s + ANSI.reset }
func muted(_ s: String) -> String { ANSI.gray + s + ANSI.reset }

let charr0labsBanner = """
\(ANSI.blue)\(ANSI.bold) ██████╗██╗  ██╗ █████╗ ██████╗ ██████╗  ██████╗ ██╗      █████╗ ██████╗ ███████╗\(ANSI.reset)
\(ANSI.blue)\(ANSI.bold)██╔════╝██║  ██║██╔══██╗██╔══██╗██╔══██╗██╔═══██╗██║     ██╔══██╗██╔══██╗██╔════╝\(ANSI.reset)
\(ANSI.cyan)\(ANSI.bold)██║     ███████║███████║██████╔╝██████╔╝██║   ██║██║     ███████║██████╔╝███████╗\(ANSI.reset)
\(ANSI.cyan)\(ANSI.bold)██║     ██╔══██║██╔══██║██╔══██╗██╔══██╗██║   ██║██║     ██╔══██║██╔══██╗╚════██║\(ANSI.reset)
\(ANSI.bold)╚██████╗██║  ██║██║  ██║██║  ██║██║  ██║╚██████╔╝███████╗██║  ██║██████╔╝███████║\(ANSI.reset)
\(ANSI.bold) ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝\(ANSI.reset)

                     charr0labs
"""

// MARK: - Config

// afplay volume 0.0 ... 1.0
let volume: Double = 1.0

// Persisted selection
private let selectedSoundDefaultsKey = "lid_sound_selected_sound" // "OFF" or filename
private let offToken = "OFF"

// Sounds directory selection (portable for Homebrew)
private let soundsDirDefaultsKey = "lid_sound_sounds_dir" // absolute path

// MARK: - Sounds Dir

func defaultUserSoundsDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("lid-sound/sounds", isDirectory: true)
}

func loadSoundsDirURL() -> URL {
    if let saved = UserDefaults.standard.string(forKey: soundsDirDefaultsKey), !saved.isEmpty {
        return URL(fileURLWithPath: saved, isDirectory: true)
    }
    return defaultUserSoundsDir()
}

func saveSoundsDirURL(_ url: URL) {
    UserDefaults.standard.set(url.path, forKey: soundsDirDefaultsKey)
}

func ensureSoundsDirExists(_ dir: URL) {
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
        fputs("Failed to create sounds dir: \(dir.path) -> \(error)\n", stderr)
    }
}

// Seed default sounds into the selected sounds directory if missing.
// Homebrew-friendly: defaults live in a share directory (e.g. /opt/homebrew/share/lid-sound/sounds).
func findDefaultSoundsSourceDir() -> URL? {
    let candidates: [URL] = [
        // Apple Silicon Homebrew
        URL(fileURLWithPath: "/opt/homebrew/share/lid-sound/sounds", isDirectory: true),
        // Intel Homebrew
        URL(fileURLWithPath: "/usr/local/share/lid-sound/sounds", isDirectory: true)
    ]

    for dir in candidates {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
            return dir
        }
    }

    // Try resolving relative to the executable (…/bin/lid-sound -> …/share/lid-sound/sounds)
    if let exec = Bundle.main.executableURL {
        let share = exec
            .deletingLastPathComponent() // bin/
            .deletingLastPathComponent() // prefix/
            .appendingPathComponent("share/lid-sound/sounds", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: share.path, isDirectory: &isDir), isDir.boolValue {
            return share
        }
    }

    // Dev fallback: local repo layout (if present)
    if let exec = Bundle.main.executableURL {
        let maybeRepo = exec
            .deletingLastPathComponent() // .build/release
            .deletingLastPathComponent() // .build
            .appendingPathComponent("Sources/lid-sound/sounds", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: maybeRepo.path, isDirectory: &isDir), isDir.boolValue {
            return maybeRepo
        }
    }

    return nil
}

func seedDefaultSoundsIfMissing(into dir: URL) {
    ensureSoundsDirExists(dir)

    // If there is already at least one mp3 in the target dir, do nothing.
    if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "mp3" {
                return
            }
        }
    }

    guard let sourceDir = findDefaultSoundsSourceDir() else {
        // No defaults available on this machine.
        return
    }

    copyMp3s(from: sourceDir, to: dir)
}

func setSoundsDir(to newDir: URL) {
    saveSoundsDirURL(newDir)
    seedDefaultSoundsIfMissing(into: newDir)
}

func copyMp3s(from sourceDir: URL, to targetDir: URL) {
    ensureSoundsDirExists(targetDir)

    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: sourceDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
        fputs("Cannot read directory: \(sourceDir.path)\n", stderr)
        return
    }

    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension.lowercased() == "mp3" else { continue }
        let dst = targetDir.appendingPathComponent(fileURL.lastPathComponent)
        if fm.fileExists(atPath: dst.path) { continue }
        do {
            try fm.copyItem(at: fileURL, to: dst)
        } catch {
            fputs("Failed to copy \(fileURL.lastPathComponent): \(error)\n", stderr)
        }
    }
}

// MARK: - Persistence

func loadSelectedSoundToken() -> String {
    if let raw = UserDefaults.standard.string(forKey: selectedSoundDefaultsKey), !raw.isEmpty {
        return raw
    }
    return offToken
}

func saveSelectedSoundToken(_ token: String) {
    UserDefaults.standard.set(token, forKey: selectedSoundDefaultsKey)
}

// MARK: - Sounds

enum SoundItem: Equatable {
    case off
    case file(name: String, fullPath: String)

    var displayName: String {
        switch self {
        case .off:
            return "SOUND OFF"
        case .file(let name, _):
            return name
        }
    }

    var token: String {
        switch self {
        case .off:
            return offToken
        case .file(let name, _):
            return name
        }
    }

    var path: String? {
        switch self {
        case .off:
            return nil
        case .file(_, let fullPath):
            return fullPath
        }
    }
}

func listSoundItems() -> [SoundItem] {
    var items: [SoundItem] = [.off]

    let url = loadSoundsDirURL()
    let fm = FileManager.default

    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
        return items
    }

    var mp3s: [SoundItem] = []

    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension.lowercased() == "mp3" else { continue }
        mp3s.append(.file(name: fileURL.lastPathComponent, fullPath: fileURL.path))
    }

    mp3s.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    items.append(contentsOf: mp3s)
    return items
}

func resolveSelectedSoundPath() -> String? {
    let token = loadSelectedSoundToken()
    if token == offToken { return nil }

    for item in listSoundItems() {
        if item.token == token {
            return item.path
        }
    }

    // File removed -> treat as OFF
    return nil
}

// MARK: - Audio

@discardableResult
func playSoundAsync(at path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else {
        fputs("Sound file not found: \(path)\n", stderr)
        return false
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    task.arguments = ["-v", String(volume), path]

    do {
        try task.run()
        return true
    } catch {
        fputs("Failed to run afplay: \(error)\n", stderr)
        return false
    }
}

// MARK: - TUI (set-sound)

struct TerminalRawMode {
    private var original = termios()
    private var enabled = false

    mutating func enable() {
        guard !enabled else { return }
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        raw.c_cc.16 = 1 // VMIN
        raw.c_cc.17 = 0 // VTIME
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        enabled = true
    }

    mutating func disable() {
        guard enabled else { return }
        var orig = original
        tcsetattr(STDIN_FILENO, TCSANOW, &orig)
        enabled = false
    }
}

enum Key {
    case up
    case down
    case enter
    case esc
    case space
    case other
}

func readKey() -> Key {
    var b: UInt8 = 0
    let n = read(STDIN_FILENO, &b, 1)
    guard n == 1 else { return .other }

    if b == 13 || b == 10 { return .enter } // Enter
    if b == 32 { return .space }            // Space

    if b == 27 { // ESC
        var seq: [UInt8] = [0, 0]
        let n2 = read(STDIN_FILENO, &seq, 2)
        if n2 == 2, seq[0] == 91 { // '['
            if seq[1] == 65 { return .up }
            if seq[1] == 66 { return .down }
        }
        return .esc
    }

    return .other
}

func clearScreen() {
    print("\u{001B}[2J\u{001B}[H", terminator: "")
}

func renderMenu(items: [SoundItem], selectedIndex: Int) {
    clearScreen()
    print(charr0labsBanner)

    print(accent("[ sound picker ]") + "  " + muted("↑/↓ move") + "  " + muted("Space preview") + "  " + muted("Enter select") + "  " + muted("Esc back") + "\n")
    print(muted("Sounds folder:") + " \(loadSoundsDirURL().path)\n")

    for (i, item) in items.enumerated() {
        if i == selectedIndex {
            let cursor = ANSI.green + ANSI.bold + ">" + ANSI.reset
            print("\(cursor) \(ANSI.bold)\(item.displayName)\(ANSI.reset)")
        } else {
            print("  \(item.displayName)")
        }
    }

    print("\n" + muted("Tip: add mp3 with `lid-sound add-sounds <dir>`"))
}

func runSetSoundTUI() {
    let items = listSoundItems()

    if items.count == 1 {
        clearScreen()
        print(charr0labsBanner)
        print(warn("No .mp3 files found in:") + " \(loadSoundsDirURL().path)")
        print(muted("Only available: SOUND OFF"))
        print("\n" + muted("Use: lid-sound add-sounds <dir>"))
    }

    let currentToken = loadSelectedSoundToken()
    var selectedIndex = items.firstIndex(where: { $0.token == currentToken }) ?? 0

    var raw = TerminalRawMode()
    raw.enable()
    defer {
        raw.disable()
        print("")
    }

    while true {
        renderMenu(items: items, selectedIndex: selectedIndex)

        switch readKey() {
        case .up:
            selectedIndex = max(0, selectedIndex - 1)
        case .down:
            selectedIndex = min(items.count - 1, selectedIndex + 1)
        case .space:
            if let path = items[selectedIndex].path {
                _ = playSoundAsync(at: path)
            }
        case .enter:
            let chosen = items[selectedIndex]
            saveSelectedSoundToken(chosen.token)
            clearScreen()
            print(charr0labsBanner)
            print("Selected: \(chosen.displayName)")
            return
        case .esc:
            clearScreen()
            print(charr0labsBanner)
            print("Canceled.")
            return
        case .other:
            continue
        }
    }
}

// MARK: - CLI

func printUsage() {
    print(charr0labsBanner)
    print(
"""
Usage:
  lid-sound run
  lid-sound status
  lid-sound set-sound
  lid-sound add-sounds [directory]

Notes:
- Put .mp3 files in: \(loadSoundsDirURL().path)
- set-sound opens an interactive picker (↑/↓, Space, Enter, Esc)
- add-sounds sets the sounds directory and seeds default sounds (from the install share dir) if missing. If you pass a directory, it also copies any .mp3 from there.
"""
    )
}

let args = CommandLine.arguments
let command = args.count >= 2 ? args[1].lowercased() : "run"

// Ensure we have a usable directory and defaults on first run.
seedDefaultSoundsIfMissing(into: loadSoundsDirURL())

switch command {
case "set-sound":
    runSetSoundTUI()
    exit(0)

case "add-sounds":
    if args.count >= 3 {
        let provided = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true)
        setSoundsDir(to: provided)
        copyMp3s(from: provided, to: loadSoundsDirURL())
        print("Sounds directory set to: \(loadSoundsDirURL().path)")
        exit(0)
    } else {
        print(charr0labsBanner)
        print("Enter a directory path containing .mp3 sounds (or press Enter to use the default):")
        if let line = readLine(), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let provided = URL(fileURLWithPath: (line as NSString).expandingTildeInPath, isDirectory: true)
            setSoundsDir(to: provided)
            copyMp3s(from: provided, to: loadSoundsDirURL())
            print("Sounds directory set to: \(loadSoundsDirURL().path)")
        } else {
            setSoundsDir(to: defaultUserSoundsDir())
            print("Sounds directory set to default: \(loadSoundsDirURL().path)")
        }
        exit(0)
    }

case "status":
    print(charr0labsBanner)

    let token = loadSelectedSoundToken()
    if token == offToken {
        print(accent("Current sound:") + " " + muted("SOUND OFF"))
    } else {
        print(accent("Current sound:") + " \(ANSI.green)\(token)\(ANSI.reset)")
    }

    print(muted("Sounds dir:") + " \(loadSoundsDirURL().path)")

    if let resolved = resolveSelectedSoundPath() {
        print(muted("Resolved path:") + " \(resolved)")
    } else {
        print(muted("Resolved path:") + " (none)")
    }
    exit(0)

case "run":
    break

case "help", "-h", "--help":
    printUsage()
    exit(0)

default:
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exit(2)
}

// MARK: - Listener

let center = NSWorkspace.shared.notificationCenter

func maybePlaySelected(label: String) {
    guard let path = resolveSelectedSoundPath() else {
        print("[\(label)] SOUND OFF")
        return
    }
    print("[\(label)] playing: \(path)")
    _ = playSoundAsync(at: path)
}

// NOTE: didWake is reliable. For lid-close sound, wire IOKit will-sleep notifications.
center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
    maybePlaySelected(label: "didWake")
}

let token = loadSelectedSoundToken()
print(charr0labsBanner)
print(accent("lid-sound") + " " + muted("running…"))
print(muted("Sounds dir:") + " \(loadSoundsDirURL().path)")
print(muted("Selected:") + " \(token == offToken ? ANSI.gray + "SOUND OFF" + ANSI.reset : ANSI.green + token + ANSI.reset)")
RunLoop.main.run()