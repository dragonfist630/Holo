import XCTest
@testable import HoloCore

final class FeatureExtractorTests: XCTestCase {
    func testFeatureVectorIsFiniteAndMatchesSchema() {
        let event = makeEvent(frequency: 880)
        let extractor = TapFeatureExtractor(sampleRate: 48_000, strategy: .passive)
        let feature = extractor.extract(from: event)

        XCTAssertEqual(feature.names, TapFeatureExtractor.passiveFeatureNames)
        XCTAssertEqual(feature.names.count, feature.values.count)
        XCTAssertTrue(feature.values.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(feature.quality.signalToNoiseDB, 20)
    }

    func testDifferentResonancesProduceDifferentSpectralFeatures() {
        let extractor = TapFeatureExtractor(sampleRate: 48_000, strategy: .passive)
        let low = extractor.extract(from: makeEvent(frequency: 320))
        let high = extractor.extract(from: makeEvent(frequency: 3_200))
        let centroidIndex = try! XCTUnwrap(low.names.firstIndex(of: "spectral_centroid"))
        XCTAssertGreaterThan(high.values[centroidIndex], low.values[centroidIndex])
    }

    func testComfortableShortTapQualityIsNotDilutedAcrossNinetyMilliseconds() {
        let sampleRate = 48_000.0
        let onset = 576
        let count = Int(sampleRate * 0.09)
        let samples: [Float] = (0..<count).map { index in
            let absoluteTime = Double(index) / sampleRate
            let background = 0.0028 * sin(2 * .pi * 173 * absoluteTime)
                + 0.0021 * sin(2 * .pi * 419 * absoluteTime + 0.4)
            guard index >= onset else { return Float(background) }
            let time = Double(index - onset) / sampleRate
            let impact = 0.008 * exp(-time * 2_200) * cos(2 * .pi * 1_900 * time)
            let resonance = 0.0022 * exp(-time * 32) * sin(2 * .pi * 680 * time)
            return Float(background + impact + resonance)
        }
        let event = DetectedTap(
            channels: [samples],
            onsetOffset: onset,
            streamSampleIndex: 0,
            noiseFloorRMS: 0.003
        )

        let feature = TapFeatureExtractor(sampleRate: sampleRate, strategy: .passive)
            .extract(from: event)

        XCTAssertGreaterThanOrEqual(
            feature.quality.signalToNoiseDB,
            GuidedCaptureQuality.minimumSignalToNoiseDB
        )
        XCTAssertNil(GuidedCaptureQuality.issue(for: feature.quality))
        XCTAssertLessThan(feature.quality.rmsAmplitude, feature.quality.peakAmplitude)
    }

    func testAllStrategiesHaveStableSchemas() {
        let event = makeEvent(frequency: 1_200)
        let passive = TapFeatureExtractor(sampleRate: 48_000, strategy: .passive).extract(from: event)
        let active = TapFeatureExtractor(sampleRate: 48_000, strategy: .active).extract(from: event)
        let hybrid = TapFeatureExtractor(sampleRate: 48_000, strategy: .hybrid).extract(from: event)

        XCTAssertEqual(hybrid.values.count, passive.values.count + active.values.count)
        XCTAssertEqual(hybrid.names, passive.names + active.names)
        XCTAssertTrue(active.values.allSatisfy(\.isFinite))
    }

    func testCombinedAnalysisMatchesStandaloneFeatureAndSpectrumResults() {
        let event = makeEvent(frequency: 1_750)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

        for strategy in SensingStrategy.allCases {
            let extractor = TapFeatureExtractor(sampleRate: 48_000, strategy: strategy)
            let analysis = extractor.analyze(from: event, capturedAt: capturedAt)

            XCTAssertEqual(
                analysis.feature,
                extractor.extract(from: event, capturedAt: capturedAt)
            )
            XCTAssertEqual(analysis.spectrum, extractor.spectrumBands(from: event))
        }
    }

    func testEmptyCaptureProducesFiniteFallbackFeatures() {
        let event = DetectedTap(
            channels: [],
            onsetOffset: 0,
            streamSampleIndex: 0,
            noiseFloorRMS: 0.0005
        )

        for strategy in SensingStrategy.allCases {
            let extractor = TapFeatureExtractor(sampleRate: 48_000, strategy: strategy)
            let feature = extractor.extract(from: event)
            let spectrum = extractor.spectrumBands(from: event)

            XCTAssertEqual(feature.names.count, feature.values.count)
            XCTAssertTrue(feature.values.allSatisfy(\.isFinite))
            XCTAssertTrue(feature.quality.signalToNoiseDB.isFinite)
            XCTAssertTrue(spectrum.allSatisfy { $0.levelDB.isFinite })
        }
    }

    private func makeEvent(frequency: Double) -> DetectedTap {
        let sampleRate = 48_000.0
        let count = Int(sampleRate * 0.09)
        let onset = 576
        let samples: [Float] = (0..<count).map { index in
            guard index >= onset else { return 0.0001 }
            let time = Double(index - onset) / sampleRate
            return Float(0.15 * exp(-time * 55) * sin(2 * .pi * frequency * time))
        }
        return DetectedTap(channels: [samples], onsetOffset: onset, streamSampleIndex: 0, noiseFloorRMS: 0.0002)
    }
}
