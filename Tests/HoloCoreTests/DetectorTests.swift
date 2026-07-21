import XCTest
@testable import HoloCore

final class DetectorTests: XCTestCase {
    func testDetectorIgnoresSteadyBackgroundAndFindsImpulse() {
        let sampleRate = 48_000.0
        let detector = StreamingTapDetector(sampleRate: sampleRate, channelCount: 1)
        var events: [DetectedTap] = []

        for _ in 0..<80 {
            events += detector.process(channels: [Array(repeating: 0.0004, count: 512)])
        }
        XCTAssertTrue(events.isEmpty)

        var impulse = Array(repeating: Float(0.0004), count: 512)
        impulse[120] = 0.2
        impulse[121] = -0.13
        events += detector.process(channels: [impulse])
        for _ in 0..<10 {
            events += detector.process(channels: [Array(repeating: 0.0002, count: 512)])
        }

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(detector.statistics.candidateCount, 1)
        XCTAssertEqual(detector.statistics.impactRejectedCount, 0)
        XCTAssertEqual(detector.statistics.emittedCount, 1)
        XCTAssertEqual(events[0].channels[0].count, detector.analysisWindowSamples)
        XCTAssertEqual(events[0].onsetOffset, detector.preRollSamples)
    }

    func testDetectorUsesFixedOnsetRelativeWindowAcrossEveryCallbackPhase() throws {
        try assertTapIsCallbackPartitionInvariant(amplitudeScale: 1.0)
    }

    func testDetectorAcceptsGentleTapAboveTypicalRoomFloorAcrossEveryCallbackPhase() throws {
        // The raw impact starts at 0.018 with a 0.0042 resonant tail. Its filtered
        // peak clears the high-recall arm. Earlier 4x/1.8 and 3.2x/1.6
        // combinations rejected it before the classifier could inspect it.
        try assertTapIsCallbackPartitionInvariant(
            amplitudeScale: 0.06,
            initialNoiseFloorRMS: 0.003
        )
    }

    func testDetectorAcceptsGentleTapAboveElevatedRoomFloorAcrossEveryCallbackPhase() throws {
        try assertTapIsCallbackPartitionInvariant(
            amplitudeScale: 0.08,
            initialNoiseFloorRMS: 0.004
        )
    }

    func testDetectorAcceptsComfortableTapEmbeddedInActualRoomNoiseAcrossEveryCallbackPhase() throws {
        let sampleRate = 48_000.0
        let onsetSample = 2_048
        let sampleCount = onsetSample + Int(sampleRate * 0.090) + 1_024
        let signal = noisyTapSignal(
            sampleRate: sampleRate,
            onsetSample: onsetSample,
            sampleCount: sampleCount,
            amplitudeScale: 0.03,
            backgroundRMS: 0.003
        )

        for firstCallbackLength in 1...512 {
            let result = detect(
                signal,
                sampleRate: sampleRate,
                firstCallbackLength: firstCallbackLength,
                initialNoiseFloorRMS: 0.003
            )
            XCTAssertEqual(
                result.events.count,
                1,
                "Comfortable noisy-room tap missed at callback partition \(firstCallbackLength); \(result.statistics)"
            )
        }
    }

    func testDetectorAcceptsRoundedLowFrequencyDeskRingAcrossEveryCallbackPhase() {
        let sampleRate = 48_000.0
        let onsetSample = 2_048
        let sampleCount = onsetSample + Int(sampleRate * 0.090) + 1_024
        let signal: [Float] = (0..<sampleCount).map { index in
            guard index >= onsetSample else { return 0 }
            let time = Double(index - onsetSample) / sampleRate
            return Float(0.012 * exp(-40 * time) * sin(2 * Double.pi * 650 * time))
        }

        for firstCallbackLength in 1...512 {
            let result = detect(
                signal,
                sampleRate: sampleRate,
                firstCallbackLength: firstCallbackLength,
                initialNoiseFloorRMS: 0.0015
            )
            XCTAssertEqual(
                result.events.count,
                1,
                "Rounded desk ring missed at callback partition \(firstCallbackLength)"
            )
        }
    }

    func testDetectorAcceptsDirectImpactWithDelayedDeskPathAcrossEveryCallbackPhase() {
        let sampleRate = 48_000.0
        let onsetSample = 2_048
        let delayedPathSample = onsetSample + 192
        let sampleCount = onsetSample + Int(sampleRate * 0.090) + 1_024
        let signal: [Float] = (0..<sampleCount).map { index in
            if index == onsetSample { return 0.05 }
            guard index >= delayedPathSample else { return 0 }
            let time = Double(index - delayedPathSample) / sampleRate
            return Float(0.015 * exp(-35 * time) * sin(2 * Double.pi * 650 * time))
        }

        for firstCallbackLength in 1...512 {
            let result = detect(
                signal,
                sampleRate: sampleRate,
                firstCallbackLength: firstCallbackLength,
                initialNoiseFloorRMS: 0.0015
            )
            XCTAssertEqual(
                result.events.count,
                1,
                "Delayed desk path missed at callback partition \(firstCallbackLength)"
            )
        }
    }

    func testDetectorRejectsSustainedSignalAcrossEveryCallbackPhase() {
        let sampleRate = 48_000.0
        let onsetSample = 2_048
        let signal = sustainedSignal(
            sampleRate: sampleRate,
            onsetSample: onsetSample,
            sampleCount: onsetSample + 6_144
        )

        for firstCallbackLength in 1...512 {
            let result = detect(
                signal,
                sampleRate: sampleRate,
                firstCallbackLength: firstCallbackLength
            )
            XCTAssertTrue(
                result.events.isEmpty,
                "Sustained signal emitted at callback partition \(firstCallbackLength)"
            )
        }
    }

    func testRejectedTriggerRestoresHistoryBeforeFollowingTap() {
        let sampleRate = 48_000.0
        // Leave ample room after the rejected sustained candidate so restored
        // history and any refractory behavior settle before the real tap.
        let tapOnset = 16_000
        let signal = rejectedCandidateThenTapSignal(
            sampleRate: sampleRate,
            tapOnset: tapOnset,
            sampleCount: tapOnset + 6_144
        )

        for firstCallbackLength in [1, 127, 256, 385, 512] {
            let result = detect(
                signal,
                sampleRate: sampleRate,
                firstCallbackLength: firstCallbackLength
            )
            XCTAssertEqual(
                result.events.count,
                1,
                "Partition \(firstCallbackLength); \(result.statistics)"
            )
            guard let event = result.events.first else { continue }
            XCTAssertGreaterThanOrEqual(event.streamSampleIndex, Int64(tapOnset))
            XCTAssertLessThan(event.streamSampleIndex, Int64(tapOnset + 64))
            XCTAssertEqual(event.onsetOffset, result.preRollSamples)
        }
    }

    func testDetectorHonorsRefractoryPeriod() {
        let detector = StreamingTapDetector(
            sampleRate: 48_000,
            channelCount: 1,
            analysisDuration: 0.025,
            warmUpDuration: 0
        )
        var chunk = Array(repeating: Float.zero, count: 512)
        chunk[100] = 0.3
        var events: [DetectedTap] = []
        for _ in 0..<4 { events += detector.process(channels: [chunk]) }
        XCTAssertLessThanOrEqual(events.count, 1)
    }

    func testDetectorDoesNotTriggerOnActiveProbe() {
        for sampleRate in [44_100.0, 48_000.0] {
            let detector = StreamingTapDetector(
                sampleRate: sampleRate,
                channelCount: 1,
                warmUpDuration: 0
            )
            let chirp = ActiveProbe.chirp(sampleRate: sampleRate).map { $0 * 0.55 }
            let periodSamples = Int(sampleRate * 0.120)
            var signal: [Float] = []
            for _ in 0..<12 {
                signal.append(contentsOf: chirp)
                signal.append(contentsOf: Array(repeating: 0, count: periodSamples - chirp.count))
            }

            var events: [DetectedTap] = []
            var offset = 0
            while offset < signal.count {
                let end = min(offset + 512, signal.count)
                events += detector.process(channels: [Array(signal[offset..<end])])
                offset = end
            }

            XCTAssertTrue(events.isEmpty, "Probe self-triggered at \(sampleRate) Hz")
        }
    }

    func testDetectorLearnsElevatedBackgroundBeforeEmittingTap() {
        let sampleRate = 48_000.0
        let detector = StreamingTapDetector(sampleRate: sampleRate, channelCount: 1)
        var generator = DeterministicNoise(state: 0x484F4C4F)
        var backgroundEvents: [DetectedTap] = []

        for _ in 0..<120 {
            backgroundEvents += detector.process(channels: [backgroundChunk(generator: &generator)])
        }

        XCTAssertTrue(
            backgroundEvents.isEmpty,
            "Steady room noise must not look like repeated taps; \(detector.statistics)"
        )
        XCTAssertGreaterThan(detector.noiseFloorRMS, 0.002)

        var tap = backgroundChunk(generator: &generator)
        tap[120] = 0.48
        tap[124] = -0.31
        var tapEvents = detector.process(channels: [tap])
        for _ in 0..<10 {
            tapEvents += detector.process(channels: [backgroundChunk(generator: &generator)])
        }

        XCTAssertEqual(tapEvents.count, 1, "A real impulse must remain detectable above the learned room floor")
    }

    func testImpactGateRejectsPlosiveSpeechButKeepsAResonantTap() {
        let sampleRate = 48_000.0
        let onset = 576
        let speech = DetectedTap(
            channels: [candidateSignal(sampleRate: sampleRate, onset: onset, kind: .speech)],
            onsetOffset: onset,
            streamSampleIndex: 0,
            noiseFloorRMS: 0.001
        )
        let tap = DetectedTap(
            channels: [candidateSignal(sampleRate: sampleRate, onset: onset, kind: .tap)],
            onsetOffset: onset,
            streamSampleIndex: 0,
            noiseFloorRMS: 0.001
        )

        let speechMetrics = ImpactEventGate.metrics(for: speech, sampleRate: sampleRate)
        XCTAssertNotNil(speechMetrics)
        XCTAssertGreaterThan(speechMetrics?.effectiveDurationSeconds ?? 0, 0.04)
        XCTAssertFalse(ImpactEventGate.accepts(speech, sampleRate: sampleRate))
        XCTAssertTrue(ImpactEventGate.accepts(tap, sampleRate: sampleRate))
    }

    func testDetectorDoesNotEmitPlosiveSpeechCandidate() {
        let sampleRate = 48_000.0
        let signal = candidateSignal(
            sampleRate: sampleRate,
            onset: 900,
            kind: .speech,
            duration: 0.18
        )

        for firstCallbackLength in 1...512 {
            let result = detect(
                signal,
                sampleRate: sampleRate,
                firstCallbackLength: firstCallbackLength,
                initialNoiseFloorRMS: 0.003
            )
            XCTAssertTrue(
                result.events.isEmpty,
                "Plosive speech emitted at callback partition \(firstCallbackLength)"
            )
        }
    }

    private func backgroundChunk(generator: inout DeterministicNoise) -> [Float] {
        var chunk = Array(repeating: Float.zero, count: 512)
        for start in stride(from: 0, to: chunk.count, by: 8) {
            let value = Float((generator.unit() * 2 - 1) * 0.014)
            for index in start..<min(start + 8, chunk.count) {
                chunk[index] = value
            }
        }
        return chunk
    }

    private func assertTapIsCallbackPartitionInvariant(
        amplitudeScale: Double,
        initialNoiseFloorRMS: Double = 0.000_01,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sampleRate = 48_000.0
        let onsetSample = 2_048
        let sampleCount = onsetSample + Int(sampleRate * 0.090) + 1_024
        let signal = tapSignal(
            sampleRate: sampleRate,
            onsetSample: onsetSample,
            sampleCount: sampleCount,
            amplitudeScale: amplitudeScale
        )
        let referenceResult = detect(
            signal,
            sampleRate: sampleRate,
            firstCallbackLength: 512,
            initialNoiseFloorRMS: initialNoiseFloorRMS
        )
        let reference = try XCTUnwrap(
            referenceResult.events.first,
            "Detector missed the reference tap at scale \(amplitudeScale)",
            file: file,
            line: line
        )
        XCTAssertEqual(referenceResult.events.count, 1, file: file, line: line)

        for firstCallbackLength in 1...512 {
            let result = detect(
                signal,
                sampleRate: sampleRate,
                firstCallbackLength: firstCallbackLength,
                initialNoiseFloorRMS: initialNoiseFloorRMS
            )
            XCTAssertEqual(
                result.events.count,
                1,
                "Tap scale \(amplitudeScale) changed eligibility at callback partition \(firstCallbackLength)",
                file: file,
                line: line
            )
            guard let event = result.events.first else { continue }
            XCTAssertEqual(event.streamSampleIndex, reference.streamSampleIndex, file: file, line: line)
            XCTAssertEqual(event.onsetOffset, result.preRollSamples, file: file, line: line)
            XCTAssertEqual(event.channels.count, reference.channels.count, file: file, line: line)
            XCTAssertEqual(
                event.channels.first,
                reference.channels.first,
                "Aligned capture changed at callback partition \(firstCallbackLength)",
                file: file,
                line: line
            )
        }
    }

    private func detect(
        _ signal: [Float],
        sampleRate: Double,
        firstCallbackLength: Int,
        initialNoiseFloorRMS: Double = 0.000_01
    ) -> (events: [DetectedTap], preRollSamples: Int, statistics: TapDetectorStatistics) {
        let detector = StreamingTapDetector(
            sampleRate: sampleRate,
            channelCount: 1,
            warmUpDuration: 0,
            initialNoiseFloorRMS: initialNoiseFloorRMS
        )
        var events: [DetectedTap] = []
        var offset = 0
        var callbackLength = firstCallbackLength
        while offset < signal.count {
            let end = min(offset + callbackLength, signal.count)
            events += detector.process(channels: [Array(signal[offset..<end])])
            offset = end
            callbackLength = 512
        }
        return (events, detector.preRollSamples, detector.statistics)
    }

    private func tapSignal(
        sampleRate: Double,
        onsetSample: Int,
        sampleCount: Int,
        amplitudeScale: Double
    ) -> [Float] {
        (0..<sampleCount).map { index in
            guard index >= onsetSample else { return 0 }
            let time = Double(index - onsetSample) / sampleRate
            let impact = amplitudeScale * 0.30 * exp(-time * 2_200)
                * cos(2 * Double.pi * 1_900 * time)
            let resonance = amplitudeScale * 0.07 * exp(-time * 28)
                * sin(2 * Double.pi * 650 * time)
            return Float(impact + resonance)
        }
    }

    private func noisyTapSignal(
        sampleRate: Double,
        onsetSample: Int,
        sampleCount: Int,
        amplitudeScale: Double,
        backgroundRMS: Double
    ) -> [Float] {
        let coefficientEnergy = (0.75 * 0.75 + 0.55 * 0.55 + 0.35 * 0.35) / 2
        let backgroundScale = backgroundRMS / sqrt(coefficientEnergy)
        return (0..<sampleCount).map { index in
            let absoluteTime = Double(index) / sampleRate
            let background = backgroundScale * (
                0.75 * sin(2 * Double.pi * 137 * absoluteTime)
                    + 0.55 * sin(2 * Double.pi * 331 * absoluteTime + 0.7)
                    + 0.35 * sin(2 * Double.pi * 727 * absoluteTime + 1.4)
            )
            guard index >= onsetSample else { return Float(background) }
            let time = Double(index - onsetSample) / sampleRate
            let impact = amplitudeScale * 0.30 * exp(-time * 2_200)
                * cos(2 * Double.pi * 1_900 * time)
            let resonance = amplitudeScale * 0.07 * exp(-time * 28)
                * sin(2 * Double.pi * 650 * time)
            return Float(background + impact + resonance)
        }
    }

    private func sustainedSignal(
        sampleRate: Double,
        onsetSample: Int,
        sampleCount: Int
    ) -> [Float] {
        (0..<sampleCount).map { index in
            guard index >= onsetSample else { return 0 }
            let time = Double(index - onsetSample) / sampleRate
            return Float(0.08 * sin(2 * Double.pi * 900 * time))
        }
    }

    private func rejectedCandidateThenTapSignal(
        sampleRate: Double,
        tapOnset: Int,
        sampleCount: Int
    ) -> [Float] {
        let sustainedStart = 1_024
        let sustainedEnd = 2_048
        return (0..<sampleCount).map { index in
            if index >= sustainedStart && index < sustainedEnd {
                let time = Double(index - sustainedStart) / sampleRate
                return Float(0.08 * sin(2 * Double.pi * 900 * time))
            }
            guard index >= tapOnset else { return 0 }
            let time = Double(index - tapOnset) / sampleRate
            let impact = 0.30 * exp(-time * 2_200) * cos(2 * Double.pi * 1_900 * time)
            let resonance = 0.07 * exp(-time * 28) * sin(2 * Double.pi * 650 * time)
            return Float(impact + resonance)
        }
    }

    private enum CandidateKind {
        case tap
        case speech
    }

    private func candidateSignal(
        sampleRate: Double,
        onset: Int,
        kind: CandidateKind,
        duration: Double = 0.090
    ) -> [Float] {
        let count = max(Int(sampleRate * duration), onset + 1)
        return (0..<count).map { index in
            let background = 0.0007 * sin(2 * Double.pi * 83 * Double(index) / sampleRate)
            guard index >= onset else { return Float(background) }
            let time = Double(index - onset) / sampleRate
            switch kind {
            case .tap:
                let impact = 0.24 * exp(-time * 2_100) * cos(2 * Double.pi * 1_900 * time)
                let resonance = 0.075 * exp(-time * 24) * sin(2 * Double.pi * 620 * time)
                return Float(background + impact + resonance)
            case .speech:
                let plosive = 0.24 * exp(-time * 850) * sin(2 * Double.pi * 2_700 * time)
                let voiceEnvelope = min(time / 0.010, 1)
                let voiced = 0.075 * voiceEnvelope * (
                    sin(2 * Double.pi * 145 * time)
                        + 0.55 * sin(2 * Double.pi * 290 * time)
                        + 0.30 * sin(2 * Double.pi * 435 * time)
                )
                return Float(background + plosive + voiced)
            }
        }
    }
}

private struct DeterministicNoise {
    var state: UInt64

    mutating func unit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return Double(state >> 11) / Double(UInt64.max >> 11)
    }
}
