import Foundation

public struct TapDetectorStatistics: Equatable, Sendable {
    public var candidateCount: Int
    public var pendingRejectedCount: Int
    public var impactRejectedCount: Int
    public var emittedCount: Int
    public var lastEnergyRise: Double
    public var lastPeakContrast: Double
    public var lastOnsetContrast: Double
    public var lastEffectiveDurationSeconds: Double
    public var lastEarlyEnergyFraction: Double
    public var lastLateToImpactRMS: Double

    public init(
        candidateCount: Int = 0,
        pendingRejectedCount: Int = 0,
        impactRejectedCount: Int = 0,
        emittedCount: Int = 0,
        lastEnergyRise: Double = 0,
        lastPeakContrast: Double = 0,
        lastOnsetContrast: Double = 0,
        lastEffectiveDurationSeconds: Double = 0,
        lastEarlyEnergyFraction: Double = 0,
        lastLateToImpactRMS: Double = 0
    ) {
        self.candidateCount = candidateCount
        self.pendingRejectedCount = pendingRejectedCount
        self.impactRejectedCount = impactRejectedCount
        self.emittedCount = emittedCount
        self.lastEnergyRise = lastEnergyRise
        self.lastPeakContrast = lastPeakContrast
        self.lastOnsetContrast = lastOnsetContrast
        self.lastEffectiveDurationSeconds = lastEffectiveDurationSeconds
        self.lastEarlyEnergyFraction = lastEarlyEnergyFraction
        self.lastLateToImpactRMS = lastLateToImpactRMS
    }
}

/// A low-allocation streaming onset detector. It adapts to the local noise floor,
/// retains a short pre-roll, and emits a fixed-length analysis window.
public final class StreamingTapDetector {
    private struct PendingTrigger {
        var filteredEvidence: [Float]
        let peakThreshold: Double
        let noiseFloorRMS: Double
    }

    public let sampleRate: Double
    public let channelCount: Int
    public let analysisWindowSamples: Int
    public let preRollSamples: Int
    public let warmUpSamples: Int

    public private(set) var noiseFloorRMS: Double
    public private(set) var totalSamples: Int64 = 0
    public private(set) var statistics = TapDetectorStatistics()

    private let initialNoiseFloorRMS: Double
    private let triggerPreRollSamples: Int
    private let triggerMetricSamples: Int
    private let triggerEvidenceSamples: Int
    private var preRoll: [[Float]]
    private var onsetPreRoll: [Float] = []
    private var capture: [[Float]]?
    private var pendingTrigger: PendingTrigger?
    private var captureOnsetOffset = 0
    private var captureStreamIndex: Int64 = 0
    private var captureNoiseFloor: Double = 0
    private var refractorySamplesRemaining = 0
    private var adaptNoiseDuringRefractory = false
    private var warmUpSamplesRemaining: Int
    private var onsetFilterState = Array(repeating: Float.zero, count: 4)

    public init(
        sampleRate: Double,
        channelCount: Int,
        analysisDuration: Double = 0.090,
        preRollDuration: Double = 0.012,
        warmUpDuration: Double = 0.75,
        initialNoiseFloorRMS: Double = 0.0005
    ) {
        self.sampleRate = sampleRate
        self.channelCount = max(channelCount, 1)
        let analysisWindowSamples = max(Int(sampleRate * analysisDuration), 1_024)
        self.analysisWindowSamples = analysisWindowSamples
        self.preRollSamples = min(
            max(Int(sampleRate * preRollDuration), 128),
            analysisWindowSamples - 1
        )
        let triggerPreRollSamples = max(Int((sampleRate * 0.008).rounded()), 128)
        let triggerMetricSamples = max(Int((sampleRate * 0.001).rounded()), 32)
        self.triggerPreRollSamples = triggerPreRollSamples
        self.triggerMetricSamples = triggerMetricSamples
        self.triggerEvidenceSamples = triggerPreRollSamples + triggerMetricSamples
        self.warmUpSamples = max(Int(sampleRate * warmUpDuration), 0)
        self.initialNoiseFloorRMS = max(initialNoiseFloorRMS, 0.000_01)
        self.noiseFloorRMS = max(initialNoiseFloorRMS, 0.000_01)
        self.warmUpSamplesRemaining = max(Int(sampleRate * warmUpDuration), 0)
        self.preRoll = Array(repeating: [], count: max(channelCount, 1))
    }

    public func reset() {
        totalSamples = 0
        noiseFloorRMS = initialNoiseFloorRMS
        statistics = TapDetectorStatistics()
        preRoll = Array(repeating: [], count: channelCount)
        onsetPreRoll = []
        capture = nil
        pendingTrigger = nil
        refractorySamplesRemaining = 0
        adaptNoiseDuringRefractory = false
        warmUpSamplesRemaining = warmUpSamples
        onsetFilterState = Array(repeating: 0, count: onsetFilterState.count)
    }

    public func resetStatistics() {
        statistics = TapDetectorStatistics()
    }

    public func process(channels incoming: [[Float]]) -> [DetectedTap] {
        guard !incoming.isEmpty else { return [] }
        let frameCount = incoming.map(\.count).min() ?? 0
        guard frameCount > 0 else { return [] }

        let channels = normalizedChannels(incoming, frameCount: frameCount)
        let mono = mixDown(channels)
        let onsetSignal = lowPassForOnset(mono)
        defer { totalSamples += Int64(frameCount) }

        let rms = rootMeanSquare(onsetSignal)

        // The initial fixed floor is only a safe bootstrap value. A MacBook mic
        // in a real room can sit well above it; trying to detect before learning
        // that floor creates a loop where every buffer looks like an impulse and
        // the floor never gets a chance to rise.
        if warmUpSamplesRemaining > 0 {
            adaptNoiseFloor(to: rms, isWarmUp: true)
            warmUpSamplesRemaining = max(0, warmUpSamplesRemaining - frameCount)
            appendToPreRoll(channels)
            appendToOnsetPreRoll(onsetSignal)
            return []
        }

        if refractorySamplesRemaining > 0 {
            if adaptNoiseDuringRefractory {
                adaptNoiseFloor(to: rms, isWarmUp: false)
            }
            refractorySamplesRemaining = max(0, refractorySamplesRemaining - frameCount)
            if refractorySamplesRemaining == 0 {
                adaptNoiseDuringRefractory = false
            }
            appendToPreRoll(channels)
            appendToOnsetPreRoll(onsetSignal)
            return []
        }

        if capture != nil {
            appendToCapture(channels)
            appendToPendingTrigger(onsetSignal)
            switch validatePendingTriggerIfReady() {
            case .collecting, .rejected:
                return []
            case .validated:
                if let event = completeCaptureIfReady() {
                    return [event]
                }
                return []
            }
        }

        // Detect on a low-pass signal so the optional 15.5–21 kHz probe
        // cannot arm its own capture. The emitted event still contains the
        // untouched full-band channels used by the feature extractor.
        // Comfortable far-side taps can sit below four times the learned room
        // floor after the four-stage onset low-pass. Arm them here, then rely on
        // the full-event gate before emitting anything.
        let peakThreshold = max(noiseFloorRMS * 2.0, 0.0015)
        // The streaming front end intentionally optimizes recall: a soft,
        // noise-relative peak starts an aligned capture without a second short-
        // window shape veto. Rounded desk resonances and delayed mechanical
        // arrivals can look non-impulsive over their first 3 ms. The complete
        // 90 ms gate and trained classifier remain the acceptance boundaries.
        if let crossing = onsetSignal.firstIndex(where: { abs(Double($0)) >= peakThreshold }) {
            statistics.candidateCount += 1
            beginCapture(channels: channels, crossing: crossing)
            beginPendingTrigger(
                onsetSignal: onsetSignal,
                crossing: crossing,
                peakThreshold: peakThreshold,
                noiseFloorRMS: noiseFloorRMS
            )
            captureStreamIndex = totalSamples + Int64(crossing)
            captureNoiseFloor = noiseFloorRMS
            switch validatePendingTriggerIfReady() {
            case .collecting, .rejected:
                break
            case .validated:
                if let event = completeCaptureIfReady() {
                    return [event]
                }
            }
        } else {
            adaptNoiseFloor(to: rms, isWarmUp: false)
            appendToPreRoll(channels)
            appendToOnsetPreRoll(onsetSignal)
        }

        return []
    }

    private func normalizedChannels(_ incoming: [[Float]], frameCount: Int) -> [[Float]] {
        var result = Array(repeating: Array(repeating: Float.zero, count: frameCount), count: channelCount)
        for channel in 0..<channelCount {
            let source = incoming[min(channel, incoming.count - 1)]
            result[channel] = Array(source.prefix(frameCount))
        }
        return result
    }

    private func mixDown(_ channels: [[Float]]) -> [Float] {
        guard channels.count > 1 else { return channels[0] }
        var mono = Array(repeating: Float.zero, count: channels[0].count)
        let scale = 1 / Float(channels.count)
        for channel in channels {
            for index in mono.indices { mono[index] += channel[index] * scale }
        }
        return mono
    }

    private func rootMeanSquare(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sum = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        return sqrt(sum / Double(values.count))
    }

    private func adaptNoiseFloor(to measuredRMS: Double, isWarmUp: Bool) {
        guard measuredRMS.isFinite else { return }
        let measured = max(measuredRMS, 0.000_01)
        if isWarmUp {
            let alpha = 0.14
            noiseFloorRMS = (1 - alpha) * noiseFloorRMS + alpha * measured
            return
        }

        // Track sustained room changes quickly enough to avoid a false-trigger
        // cascade, but cap one-step growth so a real tap does not become the new
        // baseline. Downward movement is deliberately slower and steadier.
        // A rejected candidate must not become the next baseline. Bound
        // post-warm-up growth relative to the floor itself; the former 0.020
        // fallback let one rounded tap raise a quiet-room floor by ~25%.
        let capped = min(measured, noiseFloorRMS * 1.5)
        let alpha = capped > noiseFloorRMS ? 0.06 : 0.025
        noiseFloorRMS = (1 - alpha) * noiseFloorRMS + alpha * capped
    }

    private func lowPassForOnset(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        let cutoff = min(6_000.0, sampleRate * 0.20)
        let alpha = Float(1 - exp(-2 * Double.pi * cutoff / sampleRate))
        var result = Array(repeating: Float.zero, count: values.count)
        for index in values.indices {
            var filtered = values[index]
            for stage in onsetFilterState.indices {
                onsetFilterState[stage] += alpha * (filtered - onsetFilterState[stage])
                filtered = onsetFilterState[stage]
            }
            result[index] = filtered
        }
        return result
    }

    private func appendToPreRoll(_ channels: [[Float]]) {
        for index in 0..<channelCount {
            preRoll[index].append(contentsOf: channels[index])
            if preRoll[index].count > preRollSamples {
                preRoll[index].removeFirst(preRoll[index].count - preRollSamples)
            }
        }
    }

    private func appendToOnsetPreRoll(_ samples: [Float]) {
        onsetPreRoll.append(contentsOf: samples)
        if onsetPreRoll.count > triggerPreRollSamples {
            onsetPreRoll.removeFirst(onsetPreRoll.count - triggerPreRollSamples)
        }
    }

    private func appendToCapture(_ channels: [[Float]]) {
        guard var current = capture else { return }
        for index in 0..<channelCount {
            current[index].append(contentsOf: channels[index])
        }
        capture = current
    }

    private func beginPendingTrigger(
        onsetSignal: [Float],
        crossing: Int,
        peakThreshold: Double,
        noiseFloorRMS: Double
    ) {
        let crossing = min(max(crossing, 0), onsetSignal.count)
        var context = onsetPreRoll
        context.append(contentsOf: onsetSignal.prefix(crossing))
        var evidence = Array(context.suffix(triggerPreRollSamples))
        let paddingCount = max(triggerPreRollSamples - evidence.count, 0)
        if paddingCount > 0 {
            evidence.insert(contentsOf: repeatElement(0, count: paddingCount), at: 0)
        }
        evidence.append(contentsOf: onsetSignal.dropFirst(crossing))
        pendingTrigger = PendingTrigger(
            filteredEvidence: evidence,
            peakThreshold: peakThreshold,
            noiseFloorRMS: noiseFloorRMS
        )
    }

    private func appendToPendingTrigger(_ samples: [Float]) {
        guard var pendingTrigger else { return }
        pendingTrigger.filteredEvidence.append(contentsOf: samples)
        self.pendingTrigger = pendingTrigger
    }

    private enum PendingTriggerValidation {
        case collecting
        case validated
        case rejected
    }

    private func validatePendingTriggerIfReady() -> PendingTriggerValidation {
        guard let pendingTrigger else { return .validated }
        guard pendingTrigger.filteredEvidence.count >= triggerEvidenceSamples else {
            return .collecting
        }

        let evidence = Array(pendingTrigger.filteredEvidence.prefix(triggerEvidenceSamples))
        let preImpact = Array(evidence.prefix(triggerPreRollSamples))
        let impact = Array(evidence.suffix(triggerMetricSamples))
        let preImpactRMS = rootMeanSquare(preImpact)
        let impactRMS = rootMeanSquare(impact)
        let impactPeak = impact.map { abs(Double($0)) }.max() ?? 0
        let localReference = max(
            preImpactRMS,
            pendingTrigger.noiseFloorRMS * 0.80,
            0.000_001
        )
        let energyRise = impactRMS / localReference
        let peakContrast = impactPeak / localReference
        statistics.lastEnergyRise = energyRise
        statistics.lastPeakContrast = peakContrast

        // Stationary room noise crosses a 2x peak arm occasionally. Validate
        // that it either raises 1 ms energy 1.3x over the preceding 8 ms or contains
        // a much clearer sparse peak. The OR is important: rounded desk rings
        // use the energy path, while a direct click followed by a delayed desk
        // arrival uses the peak path and is never rejected for low short RMS.
        let isTransient = impactPeak >= pendingTrigger.peakThreshold
            && (energyRise >= 1.30 || peakContrast >= 2.75)

        if isTransient {
            self.pendingTrigger = nil
            onsetPreRoll = []
            return .validated
        }

        rejectPendingTrigger(filteredEvidence: pendingTrigger.filteredEvidence)
        return .rejected
    }

    private func rejectPendingTrigger(filteredEvidence: [Float]) {
        statistics.pendingRejectedCount += 1
        if let capture {
            preRoll = capture.map { Array($0.suffix(preRollSamples)) }
        }
        onsetPreRoll = Array(filteredEvidence.suffix(triggerPreRollSamples))
        capture = nil
        pendingTrigger = nil
    }

    /// Starts every candidate with exactly the configured pre-roll before the
    /// threshold crossing. Previously the complete trigger-buffer prefix was
    /// retained, so callback phase moved the onset by up to one audio buffer and
    /// shortened the post-impact tail by the same amount.
    private func beginCapture(channels: [[Float]], crossing: Int) {
        let crossing = min(max(crossing, 0), channels.first?.count ?? 0)
        var aligned = Array(repeating: [Float](), count: channelCount)

        for channel in 0..<channelCount {
            var context = preRoll[channel]
            context.append(contentsOf: channels[channel].prefix(crossing))
            let availableContext = Array(context.suffix(preRollSamples))
            let paddingCount = max(preRollSamples - availableContext.count, 0)

            aligned[channel].reserveCapacity(
                preRollSamples + channels[channel].count - crossing
            )
            if paddingCount > 0 {
                aligned[channel].append(contentsOf: repeatElement(0, count: paddingCount))
            }
            aligned[channel].append(contentsOf: availableContext)
            aligned[channel].append(contentsOf: channels[channel].dropFirst(crossing))
        }

        capture = aligned
        captureOnsetOffset = preRollSamples
    }

    private func completeCaptureIfReady() -> DetectedTap? {
        guard let current = capture, (current.first?.count ?? 0) >= analysisWindowSamples else {
            return nil
        }
        let trimmed = current.map { Array($0.prefix(analysisWindowSamples)) }
        let event = DetectedTap(
            channels: trimmed,
            onsetOffset: min(captureOnsetOffset, analysisWindowSamples - 1),
            streamSampleIndex: captureStreamIndex,
            noiseFloorRMS: captureNoiseFloor
        )
        if let metrics = ImpactEventGate.metrics(for: event, sampleRate: sampleRate) {
            statistics.lastOnsetContrast = metrics.onsetContrast
            statistics.lastEffectiveDurationSeconds = metrics.effectiveDurationSeconds
            statistics.lastEarlyEnergyFraction = metrics.earlyEnergyFraction
            statistics.lastLateToImpactRMS = metrics.lateToImpactRMS
        }
        let accepted = ImpactEventGate.accepts(event, sampleRate: sampleRate)
        if accepted {
            statistics.emittedCount += 1
        } else {
            statistics.impactRejectedCount += 1
        }
        capture = nil
        pendingTrigger = nil
        preRoll = Array(repeating: [], count: channelCount)
        onsetPreRoll = []
        refractorySamplesRemaining = Int(sampleRate * 0.14)
        // A rejected sustained event is likely speech or a changed background.
        // Let the floor follow it during the refractory period so conversation
        // cannot repeatedly re-arm the detector every 140 ms.
        adaptNoiseDuringRefractory = !accepted
        return accepted ? event : nil
    }
}
