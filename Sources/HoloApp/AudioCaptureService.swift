import AVFoundation
import Combine
import Foundation
import HoloCore

struct TapObservation {
    var feature: TapFeatureVector
    var spectrum: [SpectrumBand]
    var rawChannels: [[Float]]
    var onsetOffset: Int
    var eventHostTimeSeconds: Double
    var processingLatencyMilliseconds: Double
}

enum AudioCaptureError: Error, LocalizedError {
    case microphonePermissionDenied
    case noInputChannels
    case invalidAudioFormat
    case audioRouteUnavailable(String)
    case builtInInputRequired(String)
    case builtInOutputRequired(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is required. Enable Holo in System Settings › Privacy & Security › Microphone."
        case .noInputChannels:
            return "The selected audio input exposes no microphone channels."
        case .invalidAudioFormat:
            return "The default microphone format could not be configured."
        case .audioRouteUnavailable(let detail):
            return detail
        case .builtInInputRequired(let selected):
            return "Holo requires the MacBook's built-in microphone. The current input is \(selected). Select MacBook Microphone in System Settings › Sound › Input, then press Resume."
        case .builtInOutputRequired(let selected):
            return "Active and Hybrid sensing require the MacBook's built-in speakers. The current output is \(selected). Select MacBook Speakers in System Settings › Sound › Output, or use Passive sensing."
        }
    }
}

enum MicrophoneAuthorizationState {
    case notDetermined
    case authorized
    case unavailable
}

@MainActor
final class AudioCaptureService: ObservableObject {
    private struct PendingStart {
        var id: UUID
        var strategy: SensingStrategy
        var task: Task<Void, Error>
    }

    @Published private(set) var isListening = false
    @Published private(set) var permissionGranted = false
    @Published private(set) var liveLevel: Double = 0
    @Published private(set) var diagnostics = MicrophoneDiagnostics()
    @Published private(set) var detectorStatistics = TapDetectorStatistics()
    @Published private(set) var strategy: SensingStrategy = .passive
    @Published var lastError: String?

    var onObservation: ((TapObservation) -> Void)?
    var onRouteInvalidated: ((String) -> Void)?

    private var engine: AVAudioEngine?
    private var probePlayer: AVAudioPlayerNode?
    private var configurationObserver: NSObjectProtocol?
    nonisolated private let processingQueue = DispatchQueue(label: "com.holo.audio-analysis", qos: .userInteractive)
    nonisolated(unsafe) private var detector: StreamingTapDetector?
    nonisolated(unsafe) private var extractor: TapFeatureExtractor?
    nonisolated(unsafe) private var timing = CallbackTimingAccumulator()
    nonisolated(unsafe) private var sampleRate = 48_000.0
    nonisolated(unsafe) private var inputLatencySeconds = 0.0
    nonisolated(unsafe) private var callbackCounter = 0
    private var captureGeneration: UInt64 = 0
    private let bufferFrames: AVAudioFrameCount = 512
    // Authorization is process-wide, not tied to one capture-service object.
    // Keeping both the in-flight request and its decision static guarantees
    // that even an unexpected second model/service in the same app process
    // cannot enqueue another macOS permission prompt.
    private static let permissionRequestGate = AsyncBooleanRequestGate()
    private static var permissionDecisionThisLaunch: Bool?
    private var pendingStart: PendingStart?

    var authorizationState: MicrophoneAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied, .restricted: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func start(strategy: SensingStrategy) async throws {
        if isListening && self.strategy == strategy { return }

        if let pendingStart, pendingStart.strategy == strategy {
            try await pendingStart.task.value
            return
        }

        pendingStart?.task.cancel()
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.startNow(strategy: strategy)
        }
        pendingStart = PendingStart(id: id, strategy: strategy, task: task)

        do {
            try await task.value
            if pendingStart?.id == id { pendingStart = nil }
        } catch {
            if pendingStart?.id == id { pendingStart = nil }
            throw error
        }
    }

    private func startNow(strategy: SensingStrategy) async throws {
        try Task.checkCancellation()
        stopCapture()

        let route: AudioRouteInfo
        do {
            route = try SystemAudioRouteInspector.currentRoute()
        } catch {
            let captureError = AudioCaptureError.audioRouteUnavailable(error.localizedDescription)
            lastError = captureError.localizedDescription
            throw captureError
        }
        diagnostics.deviceName = route.input?.name ?? "No input"
        diagnostics.audioRoute = route
        if let issue = AudioHardwarePolicy.issue(for: route, strategy: strategy) {
            let captureError = Self.captureError(for: issue)
            lastError = captureError.localizedDescription
            throw captureError
        }

        guard await requestMicrophonePermission() else {
            lastError = AudioCaptureError.microphonePermissionDenied.localizedDescription
            throw AudioCaptureError.microphonePermissionDenied
        }
        try Task.checkCancellation()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw AudioCaptureError.noInputChannels }
        guard format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw AudioCaptureError.invalidAudioFormat
        }

        self.strategy = strategy
        sampleRate = format.sampleRate
        inputLatencySeconds = input.presentationLatency
        let channelCount = Int(format.channelCount)
        processingQueue.sync {
            detector = StreamingTapDetector(sampleRate: format.sampleRate, channelCount: channelCount)
            extractor = TapFeatureExtractor(sampleRate: format.sampleRate, strategy: strategy)
            timing = CallbackTimingAccumulator()
            callbackCounter = 0
        }

        if strategy != .passive {
            configureProbe(on: engine, sampleRate: format.sampleRate)
        }

        let fallbackInputLatency = inputLatencySeconds
        let generation = captureGeneration
        input.installTap(onBus: 0, bufferSize: bufferFrames, format: nil) { [weak self] buffer, when in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0 else { return }
            let channels = (0..<channelCount).map { channel in
                Array(UnsafeBufferPointer(start: channelData[channel], count: frameCount))
            }
            let callbackUptime = ProcessInfo.processInfo.systemUptime
            let reportedHostTime = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime)
                : .nan
            let fallbackHostTime = callbackUptime - Double(frameCount) / format.sampleRate - fallbackInputLatency
            let bufferStartHostTimeSeconds = reportedHostTime.isFinite && abs(reportedHostTime - callbackUptime) < 10
                ? reportedHostTime
                : fallbackHostTime
            self.processingQueue.async { [weak self] in
                self?.process(
                    channels: channels,
                    callbackUptime: callbackUptime,
                    bufferStartHostTimeSeconds: bufferStartHostTimeSeconds,
                    generation: generation
                )
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lastError = error.localizedDescription
            throw error
        }
        probePlayer?.play()
        self.engine = engine
        diagnostics = MicrophoneDiagnostics(
            deviceName: route.input?.name ?? AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default system input",
            audioRoute: route,
            sampleRate: format.sampleRate,
            channelCount: channelCount,
            channelNames: (1...channelCount).map { "Input \($0)" },
            bufferFrameCount: Int(bufferFrames),
            timing: TimingDiagnostics(
                expectedCallbackMilliseconds: Double(bufferFrames) / format.sampleRate * 1_000,
                estimatedInputLatencyMilliseconds: inputLatencySeconds * 1_000
            ),
            microphonePermissionGranted: true
        )
        lastError = nil
        detectorStatistics = TapDetectorStatistics()
        isListening = true
        observeConfigurationChanges(for: engine)
    }

    func stop() {
        pendingStart?.task.cancel()
        pendingStart = nil
        stopCapture()
    }

    private func stopCapture() {
        captureGeneration &+= 1
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        probePlayer?.stop()
        probePlayer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        engine = nil
        processingQueue.sync {
            detector = nil
            extractor = nil
        }
        isListening = false
        liveLevel = 0
        detectorStatistics = TapDetectorStatistics()
    }

    func resetDetectorStatistics() {
        processingQueue.sync {
            detector?.resetStatistics()
        }
        detectorStatistics = TapDetectorStatistics()
    }

    func reconfigure(strategy: SensingStrategy) async throws {
        try await start(strategy: strategy)
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionGranted = true
            return true
        case .denied, .restricted:
            permissionGranted = false
            return false
        case .notDetermined:
            if let permissionDecisionThisLaunch = Self.permissionDecisionThisLaunch {
                permissionGranted = permissionDecisionThisLaunch
                return permissionDecisionThisLaunch
            }
            let granted = await Self.permissionRequestGate.run {
                await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) {
                        continuation.resume(returning: $0)
                    }
                }
            }
            Self.permissionDecisionThisLaunch = granted
            permissionGranted = granted
            return granted
        @unknown default:
            permissionGranted = false
            return false
        }
    }

    private static func captureError(for issue: AudioHardwarePolicyIssue) -> AudioCaptureError {
        switch issue {
        case .inputUnavailable:
            return .audioRouteUnavailable("No default microphone is available. Select MacBook Microphone in System Settings › Sound › Input.")
        case .builtInInputRequired(let selected):
            return .builtInInputRequired(selected)
        case .outputUnavailable:
            return .audioRouteUnavailable("No default speaker output is available. Select MacBook Speakers in System Settings › Sound › Output.")
        case .builtInOutputRequired(let selected):
            return .builtInOutputRequired(selected)
        }
    }

    private func observeConfigurationChanges(for engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() {
        guard isListening else { return }
        do {
            let route = try SystemAudioRouteInspector.currentRoute()
            diagnostics.audioRoute = route
            diagnostics.deviceName = route.input?.name ?? "No input"
            if let issue = AudioHardwarePolicy.issue(for: route, strategy: strategy) {
                invalidateRoute(with: Self.captureError(for: issue))
            } else if engine?.isRunning != true {
                invalidateRoute(with: .audioRouteUnavailable(
                    "The audio device changed and capture stopped. Confirm the built-in routes, then press Resume."
                ))
            }
        } catch {
            invalidateRoute(with: .audioRouteUnavailable(error.localizedDescription))
        }
    }

    private func invalidateRoute(with error: AudioCaptureError) {
        let message = error.localizedDescription
        stop()
        lastError = message
        onRouteInvalidated?(message)
    }

    private func configureProbe(on engine: AVAudioEngine, sampleRate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let periodFrames = max(Int(sampleRate * 0.120), 1)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(periodFrames)
        ), let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(periodFrames)
        let chirp = ActiveProbe.chirp(sampleRate: sampleRate)
        for index in 0..<periodFrames {
            samples[index] = index < chirp.count ? chirp[index] : 0
        }
        player.volume = 0.55
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        probePlayer = player
    }

    nonisolated private func process(
        channels: [[Float]],
        callbackUptime: Double,
        bufferStartHostTimeSeconds: Double,
        generation: UInt64
    ) {
        guard let detector, let extractor, let frameCount = channels.first?.count else { return }
        callbackCounter += 1
        timing.record(timestamp: callbackUptime)
        let bufferStartSampleIndex = detector.totalSamples

        let mono = channels.count == 1 ? channels[0] : (0..<frameCount).map { index in
            channels.reduce(Float.zero) { $0 + $1[index] / Float(channels.count) }
        }
        let rms = sqrt(mono.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(mono.count, 1)))
        let events = detector.process(channels: channels)

        if callbackCounter.isMultiple(of: 8) {
            let detectorStatistics = detector.statistics
            let expected = Double(frameCount) / sampleRate * 1_000
            let timingSnapshot = timing.diagnostics(
                expectedMilliseconds: expected,
                inputLatencyMilliseconds: inputLatencySeconds * 1_000
            )
            Task { @MainActor [weak self] in
                guard let self,
                      self.captureGeneration == generation,
                      self.isListening else { return }
                self.liveLevel = min(max((20 * log10(max(rms, 1e-8)) + 70) / 70, 0), 1)
                self.diagnostics.timing = timingSnapshot
                self.detectorStatistics = detectorStatistics
            }
        }

        for event in events {
            let processingStart = ProcessInfo.processInfo.systemUptime
            let analysis = extractor.analyze(from: event)
            let processingEnd = ProcessInfo.processInfo.systemUptime
            let eventUptime = AudioTimeline.eventHostTimeSeconds(
                bufferStartHostTimeSeconds: bufferStartHostTimeSeconds,
                bufferStartSampleIndex: bufferStartSampleIndex,
                eventSampleIndex: event.streamSampleIndex,
                sampleRate: sampleRate
            )
            let observation = TapObservation(
                feature: analysis.feature,
                spectrum: analysis.spectrum,
                rawChannels: event.channels,
                onsetOffset: event.onsetOffset,
                eventHostTimeSeconds: eventUptime,
                processingLatencyMilliseconds: (processingEnd - processingStart) * 1_000
            )
            Task { @MainActor [weak self] in
                guard let self,
                      self.captureGeneration == generation,
                      self.isListening else { return }
                self.diagnostics.latestSignalQuality = analysis.feature.quality
                self.diagnostics.latestFrequencyResponse = analysis.spectrum
                self.diagnostics.capturedAt = Date()
                self.onObservation?(observation)
            }
        }
    }
}
