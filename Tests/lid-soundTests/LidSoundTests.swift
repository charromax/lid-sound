import XCTest
@testable import LidSoundCore

final class LidSoundTests: XCTestCase {
    func testTestTargetIsDiscovered() {
        XCTAssertTrue(true)
    }

    func testDiagnosticsDistinguishSensorStates() {
        XCTAssertEqual(LidSensorDiagnostics.probe(nil), .absent)
        XCTAssertEqual(LidSensorDiagnostics.probe(StubProbe(.success(()))), .readable)
        XCTAssertEqual(
            LidSensorDiagnostics.probe(StubProbe(.failure(ProbeError.failed))),
            .unreadable("input report setup failed: test failure")
        )
    }

    func testReportDecodingAndMotionMapping() {
        XCTAssertEqual(LidAngleReport.decode([0x01, 0x5A, 0x00], reportID: 1), 90)
        XCTAssertNil(LidAngleReport.decode([0x00]))
        var processor = MotionAudioProcessor(smoothing: 1)
        XCTAssertEqual(processor.process(angle: 0, at: 0), AngleAudioOutput(gain: 0, rate: 0.8))
        XCTAssertEqual(processor.process(angle: 13, at: 1), AngleAudioOutput(gain: 0.8518519, rate: 0.87))
        XCTAssertEqual(processor.process(angle: 13, at: 2), AngleAudioOutput(gain: 0, rate: 0.87))
        XCTAssertEqual(processor.process(angle: 28, at: 3), AngleAudioOutput(gain: 1, rate: 0.95076925))
        XCTAssertEqual(processor.process(angle: 200, at: 4), AngleAudioOutput(gain: 1, rate: 1.5))
        XCTAssertEqual(processor.stationaryOutput(), AngleAudioOutput(gain: 0, rate: 1.5))
    }

    func testContinuousAudioStateRetainsPlaybackAcrossStationaryPeriods() {
        var state = ContinuousAudioState()
        let output = AngleAudioOutput(gain: 0.5, rate: 1.1)
        XCTAssertEqual(state.command(for: output), .start(output))
        XCTAssertEqual(state.command(for: output), .update(output))
        XCTAssertEqual(state.command(for: AngleAudioOutput(gain: 0, rate: 1.1)), .mute(AngleAudioOutput(gain: 0, rate: 1.1)))
        XCTAssertEqual(state.command(for: output), .resume(output))
    }

    func testAudioParameterSmootherAttacksReleasesAndClampsParameters() {
        var smoother = AudioParameterSmoother(attack: 0.025, release: 0.075, rateTime: 0.05)
        XCTAssertEqual(smoother.apply(AngleAudioOutput(gain: -1, rate: 9), at: 0), AngleAudioOutput(gain: 0, rate: 4))

        let attack = smoother.apply(AngleAudioOutput(gain: 1, rate: 1), at: 0.025)
        XCTAssertGreaterThan(attack.gain, 0)
        XCTAssertLessThan(attack.gain, 1)
        XCTAssertLessThan(attack.rate, 4)

        let release = smoother.apply(AngleAudioOutput(gain: 0, rate: 1), at: 0.05)
        XCTAssertLessThan(release.gain, attack.gain)
        XCTAssertGreaterThan(release.gain, 0)
        XCTAssertLessThan(release.rate, attack.rate)
    }

    func testInvalidModeDefaultsToBundledLoop() {
        let store = MemoryStore(values: [LidSoundPreferences.angleModeKey: "invalid"])
        XCTAssertEqual(LidSoundPreferences(store: store).angleMode, .bundledLoop)
    }

    func testSelectedSoundRequiresReadableExistingFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryStore(values: [
            LidSoundPreferences.soundsDirectoryKey: directory.path,
            LidSoundPreferences.selectedSoundKey: "sound.mp3"
        ])
        let preferences = LidSoundPreferences(store: store)
        XCTAssertNil(AngleAudioSourceResolver.selectedSoundURL(preferences: preferences))
        FileManager.default.createFile(atPath: directory.appendingPathComponent("sound.mp3").path, contents: Data())
        XCTAssertNotNil(AngleAudioSourceResolver.selectedSoundURL(preferences: preferences))
    }

    func testBundledLoopAssetResolvesAndCanBeLoaded() {
        let asset = try? XCTUnwrap(AngleAudioSourceResolver.bundledLoopURL())
        XCTAssertNotNil(asset)
        XCTAssertEqual(asset?.pathExtension, "mp3")
        XCTAssertGreaterThan((try? Data(contentsOf: asset!))?.count ?? 0, 44)
    }

    @MainActor
    func testContinuousAudioControllerPreparesAndReplacesSources() throws {
        let bundledSource = try XCTUnwrap(AngleAudioSourceResolver.bundledLoopURL())
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selectedSource = directory.appendingPathComponent("selected.mp3")
        try FileManager.default.copyItem(at: bundledSource, to: selectedSource)

        let controller = ContinuousAudioController()
        try controller.prepare(source: bundledSource)
        controller.apply(AngleAudioOutput(gain: 0.5, rate: 1.1))
        try controller.prepare(source: selectedSource)
        controller.apply(AngleAudioOutput(gain: 0, rate: 1.1))
        controller.stop()
    }

    func testListenerSelectionPreventsDuplicateWakePlayback() {
        let source = URL(fileURLWithPath: "/tmp/loop.wav")
        XCTAssertEqual(ListenerSelection.resolve(diagnostic: .readable, source: source), .continuous(source))
        XCTAssertEqual(ListenerSelection.resolve(diagnostic: .absent, source: source), .wakeFallback)
        XCTAssertEqual(
            ListenerSelection.resolve(diagnostic: .readable, source: nil),
            .continuousSilence("No selected angle-audio source is available.")
        )
    }

    func testStatusReportsUnavailableSelectedSound() {
        XCTAssertTrue(
            LidSoundStatus.lines(diagnostic: .absent, mode: .selectedSound, selectedSoundAvailable: false)
                .contains("Angle audio: unavailable because no selected sound can be loaded")
        )
    }

    func testStatusCoversAvailableAbsentAndUnreadableSensorStates() {
        XCTAssertTrue(LidSoundStatus.lines(diagnostic: .readable, mode: .bundledLoop, selectedSoundAvailable: true)[0].contains("available"))
        XCTAssertTrue(LidSoundStatus.lines(diagnostic: .absent, mode: .bundledLoop, selectedSoundAvailable: true)[0].contains("no compatible"))
        XCTAssertTrue(
            LidSoundStatus.lines(
                diagnostic: .unreadable("input report setup failed"),
                mode: .bundledLoop,
                selectedSoundAvailable: true
            )[0].contains("input report setup failed")
        )
    }
}

private final class StubProbe: LidAngleProbe {
    let result: Result<Void, Error>?
    init(_ result: Result<Void, Error>?) { self.result = result }
    func checkReadiness() -> Result<Void, Error>? { result }
}

private enum ProbeError: LocalizedError {
    case failed
    var errorDescription: String? { "test failure" }
}

private final class MemoryStore: PreferencesStore {
    var values: [String: String]
    init(values: [String: String] = [:]) { self.values = values }
    func string(forKey key: String) -> String? { values[key] }
    func setString(_ value: String, forKey key: String) { values[key] = value }
}
