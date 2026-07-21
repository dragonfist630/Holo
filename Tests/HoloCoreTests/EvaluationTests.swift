import XCTest
@testable import HoloCore

final class EvaluationTests: XCTestCase {
    func testBalancedSixtyTapReportAndConfusionMatrix() {
        var records: [EvaluationRecord] = []
        for zone in DeskZone.allCases {
            for index in 0..<EvaluationAcceptance.tapsPerZone {
                let predicted = index < 12 ? zone : DeskZone(
                    rawValue: (zone.rawValue + 1) % DeskZone.allCases.count
                )
                let decision = ClassificationDecision(
                    zone: predicted,
                    confidence: 0.8,
                    signalStrength: 0.8,
                    zoneDistances: [],
                    rejectionReason: nil
                )
                records.append(EvaluationRecord(
                    expectedZone: zone,
                    decision: decision,
                    responseLatencyMilliseconds: 120 + Double(index)
                ))
            }
        }
        let report = EvaluationReport(
            profileName: "Test",
            strategy: .passive,
            startedAt: Date(),
            records: records
        )

        XCTAssertTrue(report.isBalancedAcceptanceSession)
        XCTAssertEqual(report.overallAccuracy, 0.8, accuracy: 0.0001)
        XCTAssertTrue(report.meetsAccuracyAndLatencyTargets)
        XCTAssertEqual(report.confusionMatrix.count, DeskZone.allCases.count)
        XCTAssertEqual(report.confusionMatrix[0][0], 12)
        XCTAssertEqual(report.perZoneAccuracy[DeskZone.rightTop.rawValue].accuracy, 0.8, accuracy: 0.0001)
        XCTAssertEqual(report.csv().split(separator: "\n").count, 61)
    }

    func testRejectedTapsCountAsIncorrect() {
        let decision = ClassificationDecision(
            zone: nil,
            confidence: 0.2,
            signalStrength: 0.4,
            zoneDistances: [],
            rejectionReason: .ambiguousZone
        )
        let record = EvaluationRecord(expectedZone: .leftBottom, decision: decision, responseLatencyMilliseconds: 90)
        let report = EvaluationReport(profileName: "Test", strategy: .passive, startedAt: Date(), records: [record])
        XCTAssertEqual(report.overallAccuracy, 0)
        XCTAssertEqual(report.rejectedPerZone[DeskZone.leftBottom.rawValue], 1)
    }

    func testMissedDetectionCountsAsAnIncorrectAttemptWithInvalidLatency() {
        let decision = ClassificationDecision(
            zone: nil,
            confidence: 0,
            signalStrength: 0,
            zoneDistances: [],
            rejectionReason: .missedDetection
        )
        let record = EvaluationRecord(
            expectedZone: .leftTop,
            decision: decision,
            responseLatencyMilliseconds: AudioTimeline.invalidElapsedMilliseconds
        )
        let report = EvaluationReport(
            profileName: "Miss fixture",
            strategy: .passive,
            startedAt: Date(),
            records: [record]
        )

        XCTAssertEqual(report.overallAccuracy, 0)
        XCTAssertEqual(report.missedDetectionCount, 1)
        XCTAssertEqual(report.classifierRejectionCount, 0)
        XCTAssertFalse(report.hasCompleteResponseLatency)
        XCTAssertTrue(report.csv().contains("missedDetection"))
        XCTAssertTrue(report.csv().contains("INVALID"))
    }

    func testEvaluationJSONPersistsFeatureOnlyReplayEvidence() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_050)
        let feature = TapFeatureVector(
            strategy: .passive,
            names: ["signature"],
            values: [0.42],
            quality: SignalQuality(
                signalToNoiseDB: 18,
                peakAmplitude: 0.08,
                rmsAmplitude: 0.02,
                clippingFraction: 0,
                noiseFloorRMS: 0.0005,
                durationMilliseconds: 90
            ),
            capturedAt: capturedAt
        )
        let decision = ClassificationDecision(
            zone: .rightBottom,
            confidence: 0.8,
            signalStrength: 0.7,
            zoneDistances: [],
            rejectionReason: nil
        )
        let report = EvaluationReport(
            calibrationCapturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            profileName: "Replay fixture",
            strategy: .passive,
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            records: [EvaluationRecord(
                expectedZone: .rightBottom,
                decision: decision,
                responseLatencyMilliseconds: 75,
                feature: feature
            )]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(EvaluationReport.self, from: report.jsonData())

        XCTAssertEqual(decoded.records.first?.feature, feature)
        XCTAssertEqual(decoded.calibrationCapturedAt, report.calibrationCapturedAt)
    }

    func testEvaluationJSONDecodesReportsWithoutRevisionOrReplayFields() throws {
        let decision = ClassificationDecision(
            zone: .leftBottom,
            confidence: 0.75,
            signalStrength: 0.7,
            zoneDistances: [],
            rejectionReason: nil
        )
        let report = EvaluationReport(
            calibrationCapturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            profileName: "Legacy fixture",
            strategy: .passive,
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            records: [EvaluationRecord(
                expectedZone: .leftBottom,
                decision: decision,
                responseLatencyMilliseconds: 80
            )]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any]
        )
        object.removeValue(forKey: "calibrationCapturedAt")
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "feature")
        object["records"] = records
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(EvaluationReport.self, from: legacyData)

        XCTAssertNil(decoded.calibrationCapturedAt)
        XCTAssertNil(decoded.records.first?.feature)
        XCTAssertEqual(decoded.records.first?.predictedZone, .leftBottom)
    }

    func testAcceptanceTargetsAreReportedSeparatelyAndLatencyIsStrict() {
        let correct = ClassificationDecision(
            zone: .leftTop,
            confidence: 0.9,
            signalStrength: 0.8,
            zoneDistances: [],
            rejectionReason: nil
        )
        let report = EvaluationReport(
            profileName: "Test",
            strategy: .passive,
            startedAt: Date(),
            records: [EvaluationRecord(
                expectedZone: .leftTop,
                decision: correct,
                responseLatencyMilliseconds: EvaluationAcceptance.maximumMedianResponseMilliseconds
            )]
        )

        XCTAssertTrue(report.meetsAccuracyTarget)
        XCTAssertFalse(report.meetsLatencyTarget)
        XCTAssertFalse(report.meetsAccuracyAndLatencyTargets)
        XCTAssertFalse(EvaluationReport(
            profileName: "Empty",
            strategy: .passive,
            startedAt: Date(),
            records: []
        ).meetsLatencyTarget)

        let invalidTiming = EvaluationReport(
            profileName: "Invalid timing",
            strategy: .passive,
            startedAt: Date(),
            records: [EvaluationRecord(
                expectedZone: .leftTop,
                decision: correct,
                responseLatencyMilliseconds: AudioTimeline.invalidElapsedMilliseconds
            )]
        )
        XCTAssertFalse(invalidTiming.hasCompleteResponseLatency)
        XCTAssertFalse(invalidTiming.meetsLatencyTarget)
        XCTAssertTrue(invalidTiming.csv().contains("INVALID"))
    }

    func testEvaluationHistoryReturnsLatestReportForExactCalibrationRevision() throws {
        let firstProfile = UUID()
        let secondProfile = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstCalibration = base.addingTimeInterval(-100)
        let oldCalibration = base.addingTimeInterval(-200)
        let secondCalibration = base.addingTimeInterval(-300)
        let reports = [
            EvaluationReport(
                profileID: firstProfile,
                calibrationCapturedAt: oldCalibration,
                profileName: "First",
                strategy: .passive,
                startedAt: base,
                completedAt: base.addingTimeInterval(20),
                records: []
            ),
            EvaluationReport(
                profileID: secondProfile,
                calibrationCapturedAt: secondCalibration,
                profileName: "Second",
                strategy: .hybrid,
                startedAt: base,
                completedAt: base.addingTimeInterval(30),
                records: []
            ),
            EvaluationReport(
                profileID: firstProfile,
                calibrationCapturedAt: firstCalibration,
                profileName: "First",
                strategy: .active,
                startedAt: base,
                completedAt: base.addingTimeInterval(40),
                records: []
            )
        ]

        let latest = try XCTUnwrap(EvaluationHistory.latest(
            for: firstProfile,
            calibrationCapturedAt: firstCalibration,
            in: reports
        ))
        XCTAssertEqual(latest.strategy, .active)
        XCTAssertEqual(latest.completedAt, base.addingTimeInterval(40))
        XCTAssertNil(EvaluationHistory.latest(
            for: firstProfile,
            calibrationCapturedAt: base,
            in: reports
        ))
        XCTAssertNil(EvaluationHistory.latest(
            for: nil,
            calibrationCapturedAt: firstCalibration,
            in: reports
        ))
    }

    func testApproachComparisonSelectsHighestMeasuredAccuracy() throws {
        var samples: [BenchmarkSample] = []
        for strategy in SensingStrategy.allCases {
            for zone in DeskZone.allCases {
                for sampleIndex in 0..<4 {
                    let position: Double
                    switch strategy {
                    case .passive:
                        position = Double(zone.rawValue) * 2
                    case .active:
                        position = 0
                    case .hybrid:
                        position = zone.isLeft ? 0 : 2
                    }
                    let feature = TapFeatureVector(
                        strategy: strategy,
                        names: ["position"],
                        values: [position + Double(sampleIndex) * 0.005],
                        quality: SignalQuality(
                            signalToNoiseDB: 25,
                            peakAmplitude: 0.1,
                            rmsAmplitude: 0.02,
                            clippingFraction: 0,
                            noiseFloorRMS: 0.0005,
                            durationMilliseconds: 90
                        )
                    )
                    samples.append(BenchmarkSample(
                        labeledTap: LabeledTap(zone: zone, feature: feature),
                        processingLatencyMilliseconds: strategy == .passive ? 5 : 2
                    ))
                }
            }
        }

        let profileID = UUID()
        let comparison = try ApproachComparison.measure(samples, profileID: profileID)
        let passive = try XCTUnwrap(comparison.scores.first { $0.strategy == .passive })
        let alternatives = comparison.scores.filter { $0.strategy != .passive }

        XCTAssertEqual(comparison.selectedStrategy, .passive)
        XCTAssertEqual(comparison.scores.count, SensingStrategy.allCases.count)
        XCTAssertTrue(alternatives.allSatisfy { passive.crossValidationAccuracy > $0.crossValidationAccuracy })
        XCTAssertEqual(comparison.topologyZoneCount, DeskZone.allCases.count)
        XCTAssertEqual(comparison.profileID, profileID)
        XCTAssertEqual(comparison.featureSchemaVersion, TapFeatureVector.schemaVersion)
        XCTAssertTrue(comparison.usesCurrentFeatureSchema)
        XCTAssertTrue(comparison.applies(to: profileID))
        XCTAssertFalse(comparison.applies(to: UUID()))
    }
}
