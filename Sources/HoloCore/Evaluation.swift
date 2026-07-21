import Foundation

public enum EvaluationAcceptance {
    public static let tapsPerZone = 15
    public static let minimumAccuracy = 0.80
    public static let maximumMedianResponseMilliseconds = 200.0
}

public struct EvaluationRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var expectedZone: DeskZone
    public var predictedZone: DeskZone?
    public var confidence: Double
    public var responseLatencyMilliseconds: Double
    public var rejectionReason: RejectionReason?
    public var capturedAt: Date
    /// Feature-only evidence for replaying classifier challengers. Raw audio is
    /// still stored only when the user separately enables debug recording.
    public var feature: TapFeatureVector?

    public init(
        id: UUID = UUID(),
        expectedZone: DeskZone,
        decision: ClassificationDecision,
        responseLatencyMilliseconds: Double,
        feature: TapFeatureVector? = nil,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.expectedZone = expectedZone
        self.predictedZone = decision.zone
        self.confidence = decision.confidence
        self.responseLatencyMilliseconds = responseLatencyMilliseconds
        self.rejectionReason = decision.rejectionReason
        self.capturedAt = capturedAt
        self.feature = feature
    }

    public var isCorrect: Bool { expectedZone == predictedZone }
}

public struct ZoneAccuracy: Codable, Equatable, Sendable, Identifiable {
    public var zone: DeskZone
    public var correct: Int
    public var total: Int
    public var id: Int { zone.rawValue }
    public var accuracy: Double { total == 0 ? 0 : Double(correct) / Double(total) }
}

public struct EvaluationReport: Codable, Equatable, Sendable {
    public var topologyZoneCount: Int?
    public var profileID: UUID?
    /// A profile ID survives recalibration so actions remain attached. This
    /// timestamp binds the report to the exact calibration/model revision.
    public var calibrationCapturedAt: Date?
    public var profileName: String
    public var strategy: SensingStrategy
    public var startedAt: Date
    public var completedAt: Date
    public var records: [EvaluationRecord]
    public var notes: String

    public init(
        topologyZoneCount: Int? = DeskZone.allCases.count,
        profileID: UUID? = nil,
        calibrationCapturedAt: Date? = nil,
        profileName: String,
        strategy: SensingStrategy,
        startedAt: Date,
        completedAt: Date = Date(),
        records: [EvaluationRecord],
        notes: String = ""
    ) {
        self.topologyZoneCount = topologyZoneCount
        self.profileID = profileID
        self.calibrationCapturedAt = calibrationCapturedAt
        self.profileName = profileName
        self.strategy = strategy
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.records = records
        self.notes = notes
    }

    public var overallAccuracy: Double {
        records.isEmpty ? 0 : Double(records.filter(\.isCorrect).count) / Double(records.count)
    }

    public var medianResponseLatencyMilliseconds: Double {
        Self.median(validResponseLatencies)
    }

    public var hasCompleteResponseLatency: Bool {
        !records.isEmpty && validResponseLatencies.count == records.count
    }

    public var perZoneAccuracy: [ZoneAccuracy] {
        DeskZone.allCases.map { zone in
            let matching = records.filter { $0.expectedZone == zone }
            return ZoneAccuracy(zone: zone, correct: matching.filter(\.isCorrect).count, total: matching.count)
        }
    }

    public var confusionMatrix: [[Int]] {
        DeskZone.allCases.map { expected in
            DeskZone.allCases.map { predicted in
                records.filter { $0.expectedZone == expected && $0.predictedZone == predicted }.count
            }
        }
    }

    public var rejectedPerZone: [Int] {
        DeskZone.allCases.map { zone in
            records.filter { $0.expectedZone == zone && $0.predictedZone == nil }.count
        }
    }

    public var missedDetectionCount: Int {
        records.filter { $0.rejectionReason == .missedDetection }.count
    }

    public var classifierRejectionCount: Int {
        records.filter {
            $0.predictedZone == nil && $0.rejectionReason != .missedDetection
        }.count
    }

    public var isBalancedAcceptanceSession: Bool {
        records.count == DeskZone.allCases.count * EvaluationAcceptance.tapsPerZone
            && DeskZone.allCases.allSatisfy { zone in
                records.filter { $0.expectedZone == zone }.count == EvaluationAcceptance.tapsPerZone
        }
    }

    public var meetsAccuracyTarget: Bool {
        !records.isEmpty && overallAccuracy >= EvaluationAcceptance.minimumAccuracy
    }

    public var meetsLatencyTarget: Bool {
        hasCompleteResponseLatency
            && medianResponseLatencyMilliseconds < EvaluationAcceptance.maximumMedianResponseMilliseconds
    }

    public var meetsAccuracyAndLatencyTargets: Bool {
        isBalancedAcceptanceSession
            && meetsAccuracyTarget
            && meetsLatencyTarget
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public func csv() -> String {
        var lines = ["timestamp,expected,predicted,confidence,latency_ms,rejection_reason,correct"]
        let formatter = ISO8601DateFormatter()
        for record in records {
            let latency = record.responseLatencyMilliseconds.isFinite
                && record.responseLatencyMilliseconds >= 0
                ? String(format: "%.2f", record.responseLatencyMilliseconds)
                : "INVALID"
            lines.append([
                formatter.string(from: record.capturedAt),
                record.expectedZone.shortName,
                record.predictedZone?.shortName ?? "REJECTED",
                String(format: "%.4f", record.confidence),
                latency,
                record.rejectionReason?.rawValue ?? "",
                record.isCorrect ? "1" : "0"
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private var validResponseLatencies: [Double] {
        records.map(\.responseLatencyMilliseconds).filter { $0.isFinite && $0 >= 0 }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }
}

public enum EvaluationHistory {
    public static func latest(
        for profileID: UUID?,
        calibrationCapturedAt: Date?,
        in reports: [EvaluationReport]
    ) -> EvaluationReport? {
        guard let profileID, let calibrationCapturedAt else { return nil }
        return reports
            .filter {
                $0.profileID == profileID
                    && $0.calibrationCapturedAt == calibrationCapturedAt
            }
            .max { $0.completedAt < $1.completedAt }
    }
}

public struct CrossValidationResult: Codable, Equatable, Sendable {
    public var accuracy: Double
    public var acceptedAccuracy: Double
    public var rejectionRate: Double
    public var perZoneAccuracy: [ZoneAccuracy]
    public var predictions: [EvaluationRecord]
}

public enum ClassifierEvaluator {
    public static func leaveOneOut(
        _ samples: [LabeledTap],
        minimumConfidence: Double = ClassifierDefaults.minimumConfidence
    ) throws -> CrossValidationResult {
        let positives = samples.filter { $0.zone != nil }
        guard positives.count >= 4 else { throw ClassifierTrainingError.notEnoughSamples }
        var records: [EvaluationRecord] = []
        for index in positives.indices {
            let heldOut = positives[index]
            let training = positives.enumerated().filter { $0.offset != index }.map(\.element)
            guard let expected = heldOut.zone else { continue }
            let classifier = try TrainedTapClassifier.train(
                positiveExamples: training,
                minimumConfidence: minimumConfidence
            )
            let decision = classifier.predict(heldOut.feature)
            records.append(EvaluationRecord(
                expectedZone: expected,
                decision: decision,
                responseLatencyMilliseconds: 0,
                capturedAt: heldOut.feature.capturedAt
            ))
        }
        let correct = records.filter(\.isCorrect).count
        let accepted = records.filter { $0.predictedZone != nil }
        return CrossValidationResult(
            accuracy: records.isEmpty ? 0 : Double(correct) / Double(records.count),
            acceptedAccuracy: accepted.isEmpty ? 0 : Double(accepted.filter(\.isCorrect).count) / Double(accepted.count),
            rejectionRate: records.isEmpty ? 0 : Double(records.filter { $0.predictedZone == nil }.count) / Double(records.count),
            perZoneAccuracy: DeskZone.allCases.map { zone in
                let matching = records.filter { $0.expectedZone == zone }
                return ZoneAccuracy(zone: zone, correct: matching.filter(\.isCorrect).count, total: matching.count)
            },
            predictions: records
        )
    }
}

public struct BenchmarkSample: Codable, Equatable, Sendable {
    public var labeledTap: LabeledTap
    public var processingLatencyMilliseconds: Double

    public init(labeledTap: LabeledTap, processingLatencyMilliseconds: Double) {
        self.labeledTap = labeledTap
        self.processingLatencyMilliseconds = processingLatencyMilliseconds
    }
}

public struct ApproachScore: Codable, Equatable, Sendable, Identifiable {
    public var strategy: SensingStrategy
    public var crossValidationAccuracy: Double
    public var rejectionRate: Double
    public var medianProcessingLatencyMilliseconds: Double
    public var sampleCount: Int
    public var id: String { strategy.rawValue }
}

public struct ApproachComparison: Codable, Equatable, Sendable {
    public var scores: [ApproachScore]
    public var selectedStrategy: SensingStrategy
    public var measuredAt: Date
    public var topologyZoneCount: Int?
    public var profileID: UUID?
    /// Nil on reports saved before feature framing was versioned.
    public var featureSchemaVersion: Int?

    public init(
        scores: [ApproachScore],
        selectedStrategy: SensingStrategy,
        measuredAt: Date,
        topologyZoneCount: Int? = DeskZone.allCases.count,
        profileID: UUID? = nil,
        featureSchemaVersion: Int? = TapFeatureVector.schemaVersion
    ) {
        self.scores = scores
        self.selectedStrategy = selectedStrategy
        self.measuredAt = measuredAt
        self.topologyZoneCount = topologyZoneCount
        self.profileID = profileID
        self.featureSchemaVersion = featureSchemaVersion
    }

    public static func measure(
        _ samples: [BenchmarkSample],
        profileID: UUID? = nil
    ) throws -> ApproachComparison {
        var scores: [ApproachScore] = []
        for strategy in SensingStrategy.allCases {
            let matching = samples.filter { $0.labeledTap.feature.strategy == strategy }
            guard !matching.isEmpty else { continue }
            let validation = try ClassifierEvaluator.leaveOneOut(matching.map(\.labeledTap))
            let latencies = matching.map(\.processingLatencyMilliseconds).sorted()
            let median: Double
            if latencies.isEmpty { median = 0 }
            else if latencies.count.isMultiple(of: 2) {
                median = (latencies[latencies.count / 2 - 1] + latencies[latencies.count / 2]) / 2
            } else { median = latencies[latencies.count / 2] }
            scores.append(ApproachScore(
                strategy: strategy,
                crossValidationAccuracy: validation.accuracy,
                rejectionRate: validation.rejectionRate,
                medianProcessingLatencyMilliseconds: median,
                sampleCount: matching.count
            ))
        }
        guard let selected = scores.sorted(by: {
            if $0.crossValidationAccuracy == $1.crossValidationAccuracy {
                return $0.medianProcessingLatencyMilliseconds < $1.medianProcessingLatencyMilliseconds
            }
            return $0.crossValidationAccuracy > $1.crossValidationAccuracy
        }).first else {
            throw ClassifierTrainingError.notEnoughSamples
        }
        return ApproachComparison(
            scores: scores,
            selectedStrategy: selected.strategy,
            measuredAt: Date(),
            topologyZoneCount: DeskZone.allCases.count,
            profileID: profileID
        )
    }

    public func applies(to profileID: UUID?) -> Bool {
        self.profileID == profileID && usesCurrentFeatureSchema
    }

    public var usesCurrentFeatureSchema: Bool {
        featureSchemaVersion == TapFeatureVector.schemaVersion
    }
}
