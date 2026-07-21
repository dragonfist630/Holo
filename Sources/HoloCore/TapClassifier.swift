import Foundation

public enum ClassifierDefaults {
    public static let minimumConfidence = 0.36
    public static let minimumRelativeSeparation = 0.035
    public static let minimumLinearScoreMargin = 0.075
}

/// A compact ridge-regression model trained on the normalized calibration
/// features. The nearest-example model remains responsible for novelty and
/// negative-example rejection; this model supplies the more stable zone boundary.
public struct RegularizedLinearZoneModel: Codable, Equatable, Sendable {
    public var coefficients: [[Double]]

    public init(coefficients: [[Double]]) {
        self.coefficients = coefficients
    }
}

public struct ClassificationDecision: Codable, Equatable, Sendable {
    public var zone: DeskZone?
    public var confidence: Double
    public var signalStrength: Double
    public var zoneDistances: [Double]
    public var rejectionReason: RejectionReason?
    public var processingLatencyMilliseconds: Double

    public init(
        zone: DeskZone?,
        confidence: Double,
        signalStrength: Double,
        zoneDistances: [Double],
        rejectionReason: RejectionReason?,
        processingLatencyMilliseconds: Double = 0
    ) {
        self.zone = zone
        self.confidence = confidence
        self.signalStrength = signalStrength
        self.zoneDistances = zoneDistances
        self.rejectionReason = rejectionReason
        self.processingLatencyMilliseconds = processingLatencyMilliseconds
    }

    public var wasAccepted: Bool { zone != nil && rejectionReason == nil }
}

public enum ClassifierTrainingError: Error, LocalizedError, Equatable {
    case notEnoughSamples
    case inconsistentFeatures
    case onlyOneZone

    public var errorDescription: String? {
        switch self {
        case .notEnoughSamples: return "At least two examples per represented zone are required."
        case .inconsistentFeatures: return "All calibration examples must use the same sensing strategy and feature schema."
        case .onlyOneZone: return "Examples from at least two zones are required."
        }
    }
}

public struct TrainedTapClassifier: Codable, Equatable, Sendable {
    public var strategy: SensingStrategy
    public var featureNames: [String]
    public var center: [Double]
    public var scales: [Double]
    public var featureWeights: [Double]
    public var positiveExamples: [LabeledTap]
    public var negativeExamples: [LabeledTap]
    public var outlierThreshold: Double
    public var positiveNoveltyThreshold: Double?
    public var linearZoneModel: RegularizedLinearZoneModel?
    public var minimumConfidence: Double

    public var featureSchemaVersion: Int {
        positiveExamples.first?.feature.version ?? 0
    }

    public var usesCurrentFeatureSchema: Bool {
        let examples = positiveExamples + negativeExamples
        return !examples.isEmpty && examples.allSatisfy {
            $0.feature.version == TapFeatureVector.schemaVersion
        }
    }

    public static func train(
        positiveExamples: [LabeledTap],
        negativeExamples: [LabeledTap] = [],
        minimumConfidence: Double = ClassifierDefaults.minimumConfidence
    ) throws -> TrainedTapClassifier {
        let positives = positiveExamples.filter { $0.zone != nil }
        let grouped = Dictionary(grouping: positives, by: { $0.zone! })
        guard grouped.count >= 2 else { throw ClassifierTrainingError.onlyOneZone }
        guard grouped.values.allSatisfy({ $0.count >= 2 }) else { throw ClassifierTrainingError.notEnoughSamples }
        guard let first = positives.first else { throw ClassifierTrainingError.notEnoughSamples }
        let names = first.feature.names
        let strategy = first.feature.strategy
        let featureVersion = first.feature.version
        let allExamples = positives + negativeExamples
        guard !names.isEmpty,
              featureVersion == TapFeatureVector.schemaVersion,
              allExamples.allSatisfy({
                  $0.feature.version == featureVersion &&
                  $0.feature.names == names &&
                  $0.feature.values.count == names.count &&
                  $0.feature.strategy == strategy
              }) else {
            throw ClassifierTrainingError.inconsistentFeatures
        }

        let dimensions = names.count
        var center = Array(repeating: 0.0, count: dimensions)
        var scales = Array(repeating: 1.0, count: dimensions)
        for dimension in 0..<dimensions {
            let values = positives.map { $0.feature.values[dimension] }
            center[dimension] = median(values)
            let deviations = values.map { abs($0 - center[dimension]) }
            let robustScale = median(deviations) * 1.4826
            let mean = values.reduce(0, +) / Double(values.count)
            let standardDeviation = sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(values.count - 1, 1)))
            scales[dimension] = max(robustScale, standardDeviation * 0.35, 1e-6)
        }

        let normalized = positives.map { normalize($0.feature.values, center: center, scales: scales) }
        var weights = Array(repeating: 1.0, count: dimensions)
        for dimension in 0..<dimensions {
            let overall = normalized.map { $0[dimension] }.reduce(0, +) / Double(normalized.count)
            var between = 0.0
            var within = 0.0
            for zone in grouped.keys {
                let indices = positives.indices.filter { positives[$0].zone == zone }
                let zoneValues = indices.map { normalized[$0][dimension] }
                let zoneMean = zoneValues.reduce(0, +) / Double(zoneValues.count)
                between += Double(zoneValues.count) * pow(zoneMean - overall, 2)
                within += zoneValues.reduce(0) { $0 + pow($1 - zoneMean, 2) }
            }
            let ratio = between / max(within, 1e-6)
            weights[dimension] = min(max(sqrt(ratio + 0.02), 0.12), 4.0)
        }
        let weightMean = weights.reduce(0, +) / Double(max(weights.count, 1))
        weights = weights.map { $0 / max(weightMean, 1e-9) }

        var sameZoneNearestDistances: [Double] = []
        var sameZoneNoveltyDistances: [Double] = []
        for index in positives.indices {
            let candidates = positives.indices.filter { $0 != index && positives[$0].zone == positives[index].zone }
            let nearest = candidates.map {
                distance(normalized[index], normalized[$0], weights: weights)
            }.min()
            if let nearest { sameZoneNearestDistances.append(nearest) }
            let nearestNovelty = candidates.map {
                unweightedDistance(normalized[index], normalized[$0])
            }.min()
            if let nearestNovelty { sameZoneNoveltyDistances.append(nearestNovelty) }
        }
        let percentile = quantile(sameZoneNearestDistances, probability: 0.95)
        let threshold = max(percentile * 2.6, 0.85)
        let noveltyPercentile = quantile(sameZoneNoveltyDistances, probability: 0.95)
        let noveltyThreshold = max(noveltyPercentile * 2.6, 0.95)
        let linearModel = trainLinearZoneModel(normalized: normalized, positives: positives)

        return TrainedTapClassifier(
            strategy: strategy,
            featureNames: names,
            center: center,
            scales: scales,
            featureWeights: weights,
            positiveExamples: positives,
            negativeExamples: negativeExamples,
            outlierThreshold: threshold,
            positiveNoveltyThreshold: noveltyThreshold,
            linearZoneModel: linearModel,
            minimumConfidence: minimumConfidence
        )
    }

    public func predict(_ feature: TapFeatureVector) -> ClassificationDecision {
        guard feature.version == featureSchemaVersion,
              feature.strategy == strategy,
              feature.names == featureNames,
              feature.values.count == center.count else {
            return rejected(feature, reason: .schemaMismatch)
        }
        if feature.quality.clippingFraction > SignalQuality.maximumReliableClippingFraction {
            return rejected(feature, reason: .clippedSignal)
        }
        if feature.quality.peakAmplitude < SignalQuality.minimumReliablePeakAmplitude {
            return rejected(feature, reason: .weakSignal)
        }
        if feature.quality.signalToNoiseDB < SignalQuality.minimumClassificationSignalToNoiseDB {
            return rejected(feature, reason: .lowSignalToNoise)
        }

        let normalizedInput = Self.normalize(feature.values, center: center, scales: scales)
        var distances = Array(repeating: Double.infinity, count: DeskZone.allCases.count)
        for zone in DeskZone.allCases {
            let candidates = positiveExamples.filter { $0.zone == zone }.map {
                Self.distance(
                    normalizedInput,
                    Self.normalize($0.feature.values, center: center, scales: scales),
                    weights: featureWeights
                )
            }.sorted()
            if !candidates.isEmpty {
                let nearest = candidates.prefix(3)
                let rankWeights = [0.58, 0.28, 0.14]
                let usedWeights = rankWeights.prefix(nearest.count)
                let denominator = usedWeights.reduce(0, +)
                distances[zone.rawValue] = zip(nearest, usedWeights).reduce(0) { $0 + $1.0 * $1.1 } / denominator
            }
        }

        let ranked = distances.enumerated().filter { $0.element.isFinite }.sorted { $0.element < $1.element }
        guard ranked.count >= 2 else {
            return rejected(feature, reason: .schemaMismatch, distances: distances)
        }
        let best = ranked[0].element
        let second = ranked[1].element

        if best > outlierThreshold {
            return rejected(feature, reason: .outOfDistribution, distances: distances)
        }

        let positiveNoveltyDistances = positiveExamples.map {
            Self.unweightedDistance(
                normalizedInput,
                Self.normalize($0.feature.values, center: center, scales: scales)
            )
        }
        let nearestPositiveNovelty = positiveNoveltyDistances.min() ?? .infinity
        if let positiveNoveltyThreshold,
           nearestPositiveNovelty > positiveNoveltyThreshold {
            return rejected(feature, reason: .outOfDistribution, distances: distances)
        }

        if !negativeExamples.isEmpty {
            let nearestNegative = negativeExamples.map {
                Self.unweightedDistance(
                    normalizedInput,
                    Self.normalize($0.feature.values, center: center, scales: scales)
                )
            }.min() ?? .infinity
            if nearestNegative <= nearestPositiveNovelty * 1.10 {
                return rejected(feature, reason: .resemblesNegativeExample, distances: distances)
            }
        }

        if let linearDecision = linearDecision(
            normalizedInput: normalizedInput,
            nearestPositiveNovelty: nearestPositiveNovelty,
            distances: distances,
            feature: feature
        ) {
            return linearDecision
        }

        guard let bestZone = DeskZone(rawValue: ranked[0].offset) else {
            return rejected(feature, reason: .schemaMismatch, distances: distances)
        }
        let separation = (second - best) / max(second, 1e-9)
        let separationScore = min(max(separation / 0.38, 0), 1)
        let fitScore = min(max(1 - best / outlierThreshold, 0), 1)
        let confidence = 0.72 * separationScore + 0.28 * fitScore

        if separation < ClassifierDefaults.minimumRelativeSeparation || confidence < minimumConfidence {
            return rejected(feature, reason: .ambiguousZone, confidence: confidence, distances: distances)
        }

        return ClassificationDecision(
            zone: bestZone,
            confidence: confidence,
            signalStrength: feature.quality.score,
            zoneDistances: distances,
            rejectionReason: nil
        )
    }

    private func linearDecision(
        normalizedInput: [Double],
        nearestPositiveNovelty: Double,
        distances: [Double],
        feature: TapFeatureVector
    ) -> ClassificationDecision? {
        guard let model = linearZoneModel,
              model.coefficients.count == DeskZone.allCases.count,
              model.coefficients.allSatisfy({ $0.count == normalizedInput.count + 1 }) else {
            return nil
        }

        let representedZones = Set(positiveExamples.compactMap(\.zone))
        let input = [1.0] + normalizedInput
        let scores = DeskZone.allCases.compactMap { zone -> (zone: DeskZone, score: Double)? in
            guard representedZones.contains(zone) else { return nil }
            let score = zip(model.coefficients[zone.rawValue], input).reduce(0) {
                $0 + $1.0 * $1.1
            }
            guard score.isFinite else { return nil }
            return (zone, score)
        }.sorted { $0.score > $1.score }
        guard scores.count >= 2 else { return nil }

        let margin = scores[0].score - scores[1].score
        let marginScore = min(max(margin / 0.30, 0), 1)
        let fitThreshold = positiveNoveltyThreshold ?? max(outlierThreshold, 1e-9)
        let fitScore = min(max(1 - nearestPositiveNovelty / fitThreshold, 0), 1)
        let confidence = 0.76 * marginScore + 0.24 * fitScore

        if margin < ClassifierDefaults.minimumLinearScoreMargin || confidence < minimumConfidence {
            // A weak linear boundary is not evidence against an otherwise
            // well-separated local match. Let the established nearest-example
            // ambiguity gate decide these close but still usable cases.
            return nil
        }

        return ClassificationDecision(
            zone: scores[0].zone,
            confidence: confidence,
            signalStrength: feature.quality.score,
            zoneDistances: distances,
            rejectionReason: nil
        )
    }

    private func rejected(
        _ feature: TapFeatureVector,
        reason: RejectionReason,
        confidence: Double = 0,
        distances: [Double] = []
    ) -> ClassificationDecision {
        ClassificationDecision(
            zone: nil,
            confidence: confidence,
            signalStrength: feature.quality.score,
            zoneDistances: distances,
            rejectionReason: reason
        )
    }

    private static func normalize(_ values: [Double], center: [Double], scales: [Double]) -> [Double] {
        zip(values, zip(center, scales)).map { value, pair in
            (value - pair.0) / max(pair.1, 1e-9)
        }
    }

    private static func distance(_ lhs: [Double], _ rhs: [Double], weights: [Double]) -> Double {
        let weighted = zip(zip(lhs, rhs), weights).reduce(0.0) { partial, item in
            let delta = item.0.0 - item.0.1
            return partial + item.1 * delta * delta
        }
        return sqrt(weighted / max(weights.reduce(0, +), 1e-9))
    }

    private static func unweightedDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let squared = zip(lhs, rhs).reduce(0.0) { partial, pair in
            partial + pow(pair.0 - pair.1, 2)
        }
        return sqrt(squared / Double(max(min(lhs.count, rhs.count), 1)))
    }

    private static func trainLinearZoneModel(
        normalized: [[Double]],
        positives: [LabeledTap]
    ) -> RegularizedLinearZoneModel? {
        guard let dimension = normalized.first?.count,
              dimension > 0,
              normalized.count == positives.count else { return nil }

        let parameterCount = dimension + 1
        let zoneCount = DeskZone.allCases.count
        var normal = Array(
            repeating: Array(repeating: 0.0, count: parameterCount),
            count: parameterCount
        )
        var rightHandSide = Array(
            repeating: Array(repeating: 0.0, count: zoneCount),
            count: parameterCount
        )

        for index in normalized.indices {
            guard let zone = positives[index].zone else { continue }
            let row = [1.0] + normalized[index]
            for lhs in 0..<parameterCount {
                rightHandSide[lhs][zone.rawValue] += row[lhs]
                for rhs in 0..<parameterCount {
                    normal[lhs][rhs] += row[lhs] * row[rhs]
                }
            }
        }

        // Scale regularization with the number of captures so 20- and 40-tap
        // profiles have comparable shrinkage. The intercept is left unpenalized.
        let regularization = max(3.0, Double(positives.count) * 0.25)
        for index in 1..<parameterCount {
            normal[index][index] += regularization
        }

        guard let solution = solvePositiveDefinite(normal, rightHandSide) else { return nil }
        let coefficients = (0..<zoneCount).map { zone in
            solution.map { $0[zone] }
        }
        guard coefficients.flatMap({ $0 }).allSatisfy(\.isFinite) else { return nil }
        return RegularizedLinearZoneModel(coefficients: coefficients)
    }

    /// Solves A·X=B using a Cholesky factorization. Ridge regularization makes
    /// the normal matrix positive definite even when features outnumber taps.
    private static func solvePositiveDefinite(
        _ matrix: [[Double]],
        _ rightHandSide: [[Double]]
    ) -> [[Double]]? {
        let count = matrix.count
        guard count > 0,
              matrix.allSatisfy({ $0.count == count }),
              rightHandSide.count == count,
              let resultColumns = rightHandSide.first?.count,
              rightHandSide.allSatisfy({ $0.count == resultColumns }) else { return nil }

        var lower = Array(repeating: Array(repeating: 0.0, count: count), count: count)
        for row in 0..<count {
            for column in 0...row {
                var value = matrix[row][column]
                if column > 0 {
                    for index in 0..<column {
                        value -= lower[row][index] * lower[column][index]
                    }
                }
                if row == column {
                    guard value.isFinite, value > 1e-10 else { return nil }
                    lower[row][column] = sqrt(value)
                } else {
                    lower[row][column] = value / lower[column][column]
                }
            }
        }

        var intermediate = Array(
            repeating: Array(repeating: 0.0, count: resultColumns),
            count: count
        )
        for row in 0..<count {
            for output in 0..<resultColumns {
                var value = rightHandSide[row][output]
                if row > 0 {
                    for index in 0..<row {
                        value -= lower[row][index] * intermediate[index][output]
                    }
                }
                intermediate[row][output] = value / lower[row][row]
            }
        }

        var solution = Array(
            repeating: Array(repeating: 0.0, count: resultColumns),
            count: count
        )
        for row in stride(from: count - 1, through: 0, by: -1) {
            for output in 0..<resultColumns {
                var value = intermediate[row][output]
                if row + 1 < count {
                    for index in (row + 1)..<count {
                        value -= lower[index][row] * solution[index][output]
                    }
                }
                solution[row][output] = value / lower[row][row]
            }
        }
        return solution
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }

    private static func quantile(_ values: [Double], probability: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = min(max(probability, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }
}
