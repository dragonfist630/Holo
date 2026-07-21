import XCTest
@testable import HoloCore

final class PipelineIntegrationTests: XCTestCase {
    func testStreamingDetectorThroughClassifierForAllFourZones() throws {
        var training: [LabeledTap] = []
        for zone in DeskZone.allCases {
            for sampleIndex in 0..<5 {
                training.append(LabeledTap(
                    zone: zone,
                    feature: try detectedFeature(
                        zone: zone,
                        frequencyScale: 1 + Double(sampleIndex - 2) * 0.004
                    )
                ))
            }
        }

        let classifier = try TrainedTapClassifier.train(positiveExamples: training)

        for zone in DeskZone.allCases {
            let heldOut = try detectedFeature(zone: zone, frequencyScale: 1.002)
            let decision = classifier.predict(heldOut)
            XCTAssertEqual(decision.zone, zone, "Incorrect end-to-end result for \(zone.displayName)")
            XCTAssertNil(decision.rejectionReason)
        }
    }

    func testComfortableNoisyRoomTapsPassTheCompleteRecognitionPath() throws {
        var training: [LabeledTap] = []
        for zone in DeskZone.allCases {
            for sampleIndex in 0..<5 {
                let feature = try detectedFeature(
                    zone: zone,
                    frequencyScale: 1 + Double(sampleIndex - 2) * 0.004,
                    impactAmplitude: 0.012,
                    resonanceAmplitude: 0.006,
                    backgroundRMS: 0.003,
                    backgroundPhase: Double(sampleIndex) * 0.31
                )
                XCTAssertNil(
                    GuidedCaptureQuality.issue(for: feature.quality),
                    "Comfortable \(zone.displayName) tap was re-rejected after detection: \(feature.quality)"
                )
                training.append(LabeledTap(zone: zone, feature: feature))
            }
        }

        let classifier = try TrainedTapClassifier.train(positiveExamples: training)
        for zone in DeskZone.allCases {
            let heldOut = try detectedFeature(
                zone: zone,
                frequencyScale: 1.002,
                impactAmplitude: 0.012,
                resonanceAmplitude: 0.006,
                backgroundRMS: 0.003,
                backgroundPhase: 0.47
            )
            let decision = classifier.predict(heldOut)
            XCTAssertEqual(decision.zone, zone, "Incorrect comfortable tap for \(zone.displayName)")
            XCTAssertNil(decision.rejectionReason)
        }
    }

    private func detectedFeature(
        zone: DeskZone,
        frequencyScale: Double,
        impactAmplitude: Double = 0.48,
        resonanceAmplitude: Double = 0.13,
        backgroundRMS: Double = 0.0002,
        backgroundPhase: Double = 0
    ) throws -> TapFeatureVector {
        let sampleRate = 48_000.0
        let detector = StreamingTapDetector(
            sampleRate: sampleRate,
            channelCount: 1,
            warmUpDuration: 0,
            initialNoiseFloorRMS: backgroundRMS
        )
        let extractor = TapFeatureExtractor(sampleRate: sampleRate, strategy: .passive)
        let frequency = [280.0, 470, 760, 1_120, 1_650, 2_300][zone.rawValue] * frequencyScale
        let totalSamples = Int(sampleRate * 0.14)
        let onset = 1_100
        let signal: [Float] = (0..<totalSamples).map { index in
            let absoluteTime = Double(index) / sampleRate
            let background = backgroundRMS * (
                1.12 * sin(2 * Double.pi * 173 * absoluteTime + backgroundPhase)
                    + 0.86 * sin(2 * Double.pi * 419 * absoluteTime + 0.7 + backgroundPhase)
            )
            guard index >= onset else { return Float(background) }
            let time = Double(index - onset) / sampleRate
            // A surface tap begins with a brief impact burst before its longer,
            // zone-specific resonance. The old fixture contained only an
            // abruptly started sustained tone, which is intentionally rejected.
            let impact = impactAmplitude * exp(-time * 2_500)
                * cos(2 * Double.pi * 1_800 * time)
            let envelope = exp(-time * (46 + Double(zone.verticalIndex) * 5))
            let fundamental = sin(2 * Double.pi * frequency * time)
            let sideSignature = 0.24 * sin(
                2 * Double.pi * frequency * (zone.isLeft ? 2.1 : 2.7) * time
            )
            return Float(
                background
                    + impact
                    + resonanceAmplitude * envelope * (fundamental + sideSignature)
            )
        }

        var events: [DetectedTap] = []
        var offset = 0
        while offset < signal.count {
            let end = min(offset + 512, signal.count)
            events += detector.process(channels: [Array(signal[offset..<end])])
            offset = end
        }

        let event = try XCTUnwrap(events.first, "Detector missed \(zone.displayName)")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.channels.first?.count, detector.analysisWindowSamples)
        return extractor.extract(from: event)
    }
}
