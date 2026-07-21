import XCTest
@testable import HoloCore

final class ClassifierTests: XCTestCase {
    func testClassifierIdentifiesAllFourSyntheticZones() throws {
        let classifier = try TrainedTapClassifier.train(positiveExamples: trainingSamples())
        let linearModel = try XCTUnwrap(classifier.linearZoneModel)
        XCTAssertEqual(linearModel.coefficients.count, DeskZone.allCases.count)
        XCTAssertTrue(linearModel.coefficients.allSatisfy {
            $0.count == classifier.featureNames.count + 1 && $0.allSatisfy(\.isFinite)
        })
        for zone in DeskZone.allCases {
            let decision = classifier.predict(feature(zone: zone, jitter: 0.015))
            XCTAssertEqual(decision.zone, zone)
            XCTAssertNil(decision.rejectionReason)
            XCTAssertGreaterThan(decision.confidence, 0.4)
        }
    }

    func testClassifierRejectsWeakAndOutOfDistributionSignals() throws {
        let classifier = try TrainedTapClassifier.train(positiveExamples: trainingSamples())
        var weak = feature(zone: .leftBottom)
        weak.quality.peakAmplitude = 0.001
        XCTAssertEqual(classifier.predict(weak).rejectionReason, .weakSignal)

        var alien = feature(zone: .leftBottom)
        alien.values = [100, -100, 80, -70]
        XCTAssertEqual(classifier.predict(alien).rejectionReason, .outOfDistribution)
    }

    func testClassifierRejectsClippedAndNoisySignalsBeforeDistanceMatching() throws {
        let classifier = try TrainedTapClassifier.train(positiveExamples: trainingSamples())

        var clipped = feature(zone: .rightTop)
        clipped.quality.clippingFraction = SignalQuality.maximumReliableClippingFraction + 0.01
        clipped.quality.peakAmplitude = 0.001
        XCTAssertEqual(classifier.predict(clipped).rejectionReason, .clippedSignal)

        var noisy = feature(zone: .rightTop)
        noisy.quality.signalToNoiseDB = SignalQuality.minimumClassificationSignalToNoiseDB - 0.1
        XCTAssertEqual(classifier.predict(noisy).rejectionReason, .lowSignalToNoise)
    }

    func testSchemaMismatchIsRejected() throws {
        let classifier = try TrainedTapClassifier.train(positiveExamples: trainingSamples())
        var mismatched = feature(zone: .leftBottom)
        mismatched.names[0] = "other"
        XCTAssertEqual(classifier.predict(mismatched).rejectionReason, .schemaMismatch)

        var legacyFraming = feature(zone: .leftBottom)
        legacyFraming.version = TapFeatureVector.schemaVersion - 1
        XCTAssertEqual(classifier.predict(legacyFraming).rejectionReason, .schemaMismatch)
        XCTAssertTrue(classifier.usesCurrentFeatureSchema)

        var legacyClassifier = classifier
        for index in legacyClassifier.positiveExamples.indices {
            legacyClassifier.positiveExamples[index].feature.version = TapFeatureVector.schemaVersion - 1
        }
        XCTAssertFalse(legacyClassifier.usesCurrentFeatureSchema)
        XCTAssertEqual(
            legacyClassifier.predict(feature(zone: .leftBottom)).rejectionReason,
            .schemaMismatch
        )

        var mixedClassifier = classifier
        mixedClassifier.positiveExamples[mixedClassifier.positiveExamples.indices.last!].feature.version -= 1
        XCTAssertFalse(mixedClassifier.usesCurrentFeatureSchema)
    }

    func testClassifierRejectsCalibratedNegativeExample() throws {
        let typing = feature(zone: .leftTop, jitter: 0.042)
        let classifier = try TrainedTapClassifier.train(
            positiveExamples: trainingSamples(),
            negativeExamples: [LabeledTap(
                zone: nil,
                negativeLabel: "Typing",
                feature: typing
            )]
        )

        let decision = classifier.predict(typing)

        XCTAssertNil(decision.zone)
        XCTAssertEqual(decision.rejectionReason, .resemblesNegativeExample)
    }

    func testClassifierRejectsNovelEventShapeEvenWhenZoneFeaturesMatch() throws {
        let samples = trainingSamples().map { sample -> LabeledTap in
            var updated = sample
            updated.feature.names.append("sustained_speech_shape")
            updated.feature.values.append(Double((sample.id.hashValue & 3) - 1) * 0.002)
            return updated
        }
        var classifier = try TrainedTapClassifier.train(positiveExamples: samples)
        classifier.outlierThreshold = 1_000_000
        classifier.featureWeights[classifier.featureWeights.count - 1] = 1e-9

        var speechLike = samples.first { $0.zone == .rightBottom }!.feature
        speechLike.values[speechLike.values.count - 1] = 2.0

        XCTAssertEqual(classifier.predict(speechLike).rejectionReason, .outOfDistribution)
    }

    func testClassifierDecodesProfilesCreatedBeforeHybridModelFields() throws {
        let classifier = try TrainedTapClassifier.train(positiveExamples: trainingSamples())
        let encoded = try JSONEncoder().encode(classifier)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "positiveNoveltyThreshold")
        object.removeValue(forKey: "linearZoneModel")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TrainedTapClassifier.self, from: legacyData)

        XCTAssertNil(decoded.positiveNoveltyThreshold)
        XCTAssertNil(decoded.linearZoneModel)
        XCTAssertEqual(decoded.predict(feature(zone: .leftTop)).zone, .leftTop)
    }

    func testClassifierRejectsIndistinguishableZonesAsAmbiguous() throws {
        let collided = trainingSamples().map { sample -> LabeledTap in
            guard sample.zone == .leftBottom else { return sample }
            var replacement = sample
            let originalJitter = -sample.feature.values[1]
            replacement.feature = feature(zone: .leftTop, jitter: originalJitter)
            return replacement
        }
        let classifier = try TrainedTapClassifier.train(positiveExamples: collided)

        let decision = classifier.predict(feature(zone: .leftTop, jitter: 0))

        XCTAssertNil(decision.zone)
        XCTAssertEqual(decision.rejectionReason, .ambiguousZone)
    }

    func testClassifierAcceptsCloseButUsableDecisionAtRelaxedSeparation() throws {
        let leftRearValues = [-100.0, -100.0, -0.1, -0.1, -0.1, 100.0, 100.0, 100.0]
        let leftFrontValues = [-100.0, -100.0, -0.1055, -0.1055, -0.1055, 100.0, 100.0, 100.0]
        let samples = leftRearValues.map {
            LabeledTap(zone: .leftTop, feature: oneDimensionFeature($0))
        } + leftFrontValues.map {
            LabeledTap(zone: .leftBottom, feature: oneDimensionFeature($0))
        }
        let classifier = try TrainedTapClassifier.train(positiveExamples: samples)

        let decision = classifier.predict(oneDimensionFeature(0))
        let ranked = decision.zoneDistances.filter(\.isFinite).sorted()
        let relativeSeparation = (ranked[1] - ranked[0]) / ranked[1]

        XCTAssertEqual(decision.zone, .leftTop)
        XCTAssertNil(decision.rejectionReason)
        XCTAssertGreaterThanOrEqual(relativeSeparation, ClassifierDefaults.minimumRelativeSeparation)
        XCTAssertLessThan(relativeSeparation, 0.055)
        XCTAssertGreaterThanOrEqual(decision.confidence, ClassifierDefaults.minimumConfidence)
    }

    func testLeaveOneOutEvaluationUsesEverySample() throws {
        let samples = trainingSamples()
        let result = try ClassifierEvaluator.leaveOneOut(samples, minimumConfidence: 0.2)
        XCTAssertEqual(result.predictions.count, samples.count)
        XCTAssertGreaterThan(result.accuracy, 0.95)
        XCTAssertEqual(result.perZoneAccuracy.filter { $0.total > 0 }.count, DeskZone.allCases.count)
    }

    private func trainingSamples() -> [LabeledTap] {
        DeskZone.allCases.flatMap { zone in
            (0..<8).map { sample in
                LabeledTap(zone: zone, feature: feature(zone: zone, jitter: Double(sample - 3) * 0.012))
            }
        }
    }

    private func feature(zone: DeskZone, jitter: Double = 0) -> TapFeatureVector {
        TapFeatureVector(
            strategy: .passive,
            names: ["row", "column", "diagonal", "texture"],
            values: [
                Double(zone.row) * 2.2 + jitter,
                Double(zone.column) * 2.0 - jitter,
                Double(zone.row + zone.column) * 0.8 + jitter * 0.5,
                Double(zone.rawValue) * 0.35 - jitter * 0.2
            ],
            quality: SignalQuality(
                signalToNoiseDB: 28,
                peakAmplitude: 0.12,
                rmsAmplitude: 0.025,
                clippingFraction: 0,
                noiseFloorRMS: 0.0004,
                durationMilliseconds: 90
            )
        )
    }

    private func oneDimensionFeature(_ value: Double) -> TapFeatureVector {
        TapFeatureVector(
            strategy: .passive,
            names: ["signature"],
            values: [value],
            quality: SignalQuality(
                signalToNoiseDB: 28,
                peakAmplitude: 0.12,
                rmsAmplitude: 0.025,
                clippingFraction: 0,
                noiseFloorRMS: 0.0004,
                durationMilliseconds: 90
            )
        )
    }
}
