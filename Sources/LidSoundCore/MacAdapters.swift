import AVFoundation
import Foundation
import IOKit.hid

public final class MacLidAngleProbe: LidAngleProbe {
    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var isOpen = false

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDPrimaryUsagePageKey as String: 0x20,
            kIOHIDPrimaryUsageKey as String: 0x8A
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first
    }

    deinit {
        close()
        reportBuffer.deallocate()
    }

    public func checkReadiness() -> Result<Void, Error>? {
        guard let device else { return nil }
        if !isOpen {
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else { return .failure(HIDError.io(result)) }
            isOpen = true
        }
        let inputSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
        return inputSize >= 3 ? .success(()) : .failure(HIDError.invalidInputReportSize(inputSize))
    }

    fileprivate func start(onReport: @escaping ([UInt8], UInt8) -> Void) throws {
        guard case .success? = checkReadiness(), let device else {
            throw HIDError.unavailable
        }
        let callbackBox = ReportCallbackBox(onReport: onReport)
        self.callbackBox = callbackBox
        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer,
            reportBufferSize,
            { context, result, _, _, reportID, report, length in
                guard result == kIOReturnSuccess, let context, length > 0 else { return }
                let callbackBox = Unmanaged<ReportCallbackBox>.fromOpaque(context).takeUnretainedValue()
                callbackBox.onReport(Array(UnsafeBufferPointer(start: report, count: Int(length))), UInt8(reportID))
            },
            Unmanaged.passUnretained(callbackBox).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    public func close() {
        guard let device else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        if isOpen {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            isOpen = false
        }
        callbackBox = nil
        self.device = nil
    }

    private let reportBufferSize = 8
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
    private var callbackBox: ReportCallbackBox?

    private final class ReportCallbackBox {
        let onReport: ([UInt8], UInt8) -> Void
        init(onReport: @escaping ([UInt8], UInt8) -> Void) {
            self.onReport = onReport
        }
    }

    private enum HIDError: LocalizedError {
        case unavailable
        case io(IOReturn)
        case invalidInputReportSize(Int)

        var errorDescription: String? {
            switch self {
            case .unavailable: "no matching Apple lid-angle input device was found"
            case .io(let result): "IOKit error \(result)"
            case .invalidInputReportSize(let size): "expected at least 3 input-report bytes, found \(size)"
            }
        }
    }
}

public final class LidAngleSensorService {
    private let probe: MacLidAngleProbe
    private var processor = MotionAudioProcessor()
    private var lastDelivery = 0.0
    private var stationaryWorkItem: DispatchWorkItem?

    public init(probe: MacLidAngleProbe = MacLidAngleProbe()) {
        self.probe = probe
    }

    public func start(onOutput: @escaping (AngleAudioOutput) -> Void) throws {
        try probe.start { [weak self] bytes, reportID in
            guard reportID == 1,
                  let angle = LidAngleReport.decode(bytes, reportID: reportID),
                  let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.scheduleStationaryStop(onOutput: onOutput)
            guard now - self.lastDelivery >= 1.0 / 30.0 else { return }
            self.lastDelivery = now
            onOutput(self.processor.process(angle: angle, at: now))
        }
    }

    public func stop() {
        stationaryWorkItem?.cancel()
        stationaryWorkItem = nil
        probe.close()
    }

    deinit { stop() }

    private func scheduleStationaryStop(onOutput: @escaping (AngleAudioOutput) -> Void) {
        stationaryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            onOutput(self.processor.stationaryOutput())
        }
        stationaryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: workItem)
    }
}

@MainActor
public final class ContinuousAudioController {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var varispeed: AVAudioUnitVarispeed?
    private var mixer: AVAudioMixerNode?
    private var state = ContinuousAudioState()
    private var parameterSmoother = AudioParameterSmoother()
    private var releaseTask: Task<Void, Never>?
    private var releaseRate: Float = 1

    public init() {}

    public func prepare(source: URL) throws {
        stop()
        state = ContinuousAudioState()
        parameterSmoother = AudioParameterSmoother()

        let file = try AVAudioFile(forReading: source)
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ) else {
            throw AudioControllerError.emptySource(source)
        }
        try file.read(into: buffer)

        let audioEngine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let varispeed = AVAudioUnitVarispeed()
        let mixer = AVAudioMixerNode()
        audioEngine.attach(playerNode)
        audioEngine.attach(varispeed)
        audioEngine.attach(mixer)
        audioEngine.connect(playerNode, to: varispeed, format: file.processingFormat)
        audioEngine.connect(varispeed, to: mixer, format: file.processingFormat)
        audioEngine.connect(mixer, to: audioEngine.mainMixerNode, format: nil)

        mixer.outputVolume = 0
        varispeed.rate = 1
        playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
        try audioEngine.start()
        playerNode.play()

        self.audioEngine = audioEngine
        self.playerNode = playerNode
        self.varispeed = varispeed
        self.mixer = mixer
    }

    public func apply(_ output: AngleAudioOutput) {
        guard let mixer, let varispeed else { return }
        releaseTask?.cancel()
        releaseTask = nil
        let now = ProcessInfo.processInfo.systemUptime
        switch state.command(for: output) {
        case .start, .update, .resume:
            let parameters = parameterSmoother.apply(output, at: now)
            mixer.outputVolume = parameters.gain
            varispeed.rate = parameters.rate
        case .mute:
            let parameters = parameterSmoother.apply(output, at: now)
            mixer.outputVolume = parameters.gain
            varispeed.rate = parameters.rate
            releaseRate = parameters.rate
            startRelease()
        }
    }

    public func stop() {
        releaseTask?.cancel()
        releaseTask = nil
        playerNode?.stop()
        audioEngine?.stop()
        mixer = nil
        varispeed = nil
        playerNode = nil
        audioEngine = nil
        state = ContinuousAudioState()
    }

    private func startRelease() {
        releaseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: NSEC_PER_SEC / 60)
                guard !Task.isCancelled, let self else { return }
                guard let mixer = self.mixer, let varispeed = self.varispeed else { return }
                let parameters = self.parameterSmoother.apply(
                    AngleAudioOutput(gain: 0, rate: self.releaseRate),
                    at: ProcessInfo.processInfo.systemUptime
                )
                mixer.outputVolume = parameters.gain
                varispeed.rate = parameters.rate
                if parameters.gain <= 0.001 {
                    mixer.outputVolume = 0
                    self.parameterSmoother.finishRelease(at: ProcessInfo.processInfo.systemUptime)
                    self.releaseTask = nil
                    return
                }
            }
        }
    }

    private enum AudioControllerError: LocalizedError {
        case emptySource(URL)

        var errorDescription: String? {
            switch self {
            case .emptySource(let source):
                "audio source is empty: \(source.lastPathComponent)"
            }
        }
    }
}
