import Foundation

public enum CalibrationGuidance {
    public static let targetTapsPerZone = 10

    /// Below this leave-one-out agreement, the UI recommends recapturing the weakest zone.
    public static let minimumCleanAgreement = 0.80
}

public struct CalibrationDraft: Sendable, Equatable {
    public var name: String
    public var surfaceDescription: String
    public var laptopPositionNote: String
    public var strategy: SensingStrategy

    public init(
        name: String = "My Desk",
        surfaceDescription: String = "Rigid desk",
        laptopPositionNote: String = "Laptop centered; position unchanged",
        strategy: SensingStrategy = .passive
    ) {
        self.name = name
        self.surfaceDescription = surfaceDescription
        self.laptopPositionNote = laptopPositionNote
        self.strategy = strategy
    }
}

public struct CalibrationSession: Sendable {
    public let targetPerZone: Int
    public var draft: CalibrationDraft
    public var positiveSamples: [LabeledTap]
    public var negativeSamples: [LabeledTap]
    public var negativeLabel: String?
    public var isArmed: Bool
    public var isSettling: Bool

    public init(
        draft: CalibrationDraft,
        targetPerZone: Int = CalibrationGuidance.targetTapsPerZone
    ) {
        self.draft = draft
        self.targetPerZone = targetPerZone
        self.positiveSamples = []
        self.negativeSamples = []
        self.negativeLabel = nil
        self.isArmed = false
        self.isSettling = false
    }

    public var currentZone: DeskZone? {
        DeskZone.allCases.first { zone in count(for: zone) < targetPerZone }
    }

    public var zonesComplete: Bool { currentZone == nil }
    public var totalRequired: Int { targetPerZone * DeskZone.allCases.count }
    public var progress: Double { Double(positiveSamples.count) / Double(totalRequired) }

    public func count(for zone: DeskZone) -> Int {
        positiveSamples.filter { $0.zone == zone }.count
    }

    public func negativeCount(for label: String) -> Int {
        negativeSamples.filter { $0.negativeLabel == label }.count
    }
}

public enum EvaluationAttemptPhase: Equatable, Sendable {
    case ready
    case preparing(UUID)
    case listening(UUID)
    case resolving(UUID)

    public var id: UUID? {
        switch self {
        case .ready: return nil
        case .preparing(let id), .listening(let id), .resolving(let id): return id
        }
    }

    public var isInFlight: Bool { id != nil }
}

public enum EvaluationAttemptTiming {
    /// Exceeds the detector's 0.75-second room-learning period, including a
    /// callback margin when evaluation starts a fresh audio engine.
    public static let preparationSeconds = 1.0
    public static let listeningSeconds = 1.50
    public static let processingGraceSeconds = 0.25
}

public struct EvaluationAttemptWindow: Equatable, Sendable {
    public let id: UUID
    public let openedAtUptime: Double
    public let closesAtUptime: Double

    public init(id: UUID, openedAtUptime: Double, closesAtUptime: Double) {
        self.id = id
        self.openedAtUptime = openedAtUptime
        self.closesAtUptime = closesAtUptime
    }

    public func contains(eventHostTimeSeconds: Double) -> Bool {
        eventHostTimeSeconds.isFinite
            && eventHostTimeSeconds >= openedAtUptime
            && eventHostTimeSeconds <= closesAtUptime
    }
}

public struct EvaluationSession: Sendable {
    public let startedAt: Date
    public let targetPerZone: Int
    public var records: [EvaluationRecord]
    public var attemptPhase: EvaluationAttemptPhase

    public init(
        startedAt: Date = Date(),
        targetPerZone: Int = EvaluationAcceptance.tapsPerZone
    ) {
        self.startedAt = startedAt
        self.targetPerZone = targetPerZone
        self.records = []
        self.attemptPhase = .ready
    }

    public var currentZone: DeskZone? {
        DeskZone.allCases.first { zone in
            records.filter { $0.expectedZone == zone }.count < targetPerZone
        }
    }

    public var progress: Double {
        Double(records.count) / Double(targetPerZone * DeskZone.allCases.count)
    }

    @discardableResult
    public mutating func beginAttempt(id: UUID = UUID()) -> UUID? {
        guard attemptPhase == .ready, currentZone != nil else { return nil }
        attemptPhase = .preparing(id)
        return id
    }

    @discardableResult
    public mutating func beginListening(id: UUID) -> Bool {
        guard attemptPhase == .preparing(id) else { return false }
        attemptPhase = .listening(id)
        return true
    }

    @discardableResult
    public mutating func beginResolving(id: UUID) -> Bool {
        guard attemptPhase == .listening(id) else { return false }
        attemptPhase = .resolving(id)
        return true
    }

    public func acceptsObservation(
        in window: EvaluationAttemptWindow,
        eventHostTimeSeconds: Double
    ) -> Bool {
        let activeID: UUID?
        switch attemptPhase {
        case .listening(let id), .resolving(let id): activeID = id
        case .ready, .preparing: activeID = nil
        }
        return activeID == window.id
            && window.contains(eventHostTimeSeconds: eventHostTimeSeconds)
    }

    @discardableResult
    public mutating func completeAttempt(id: UUID) -> Bool {
        guard attemptPhase == .listening(id) || attemptPhase == .resolving(id) else {
            return false
        }
        attemptPhase = .ready
        return true
    }

    @discardableResult
    public mutating func record(
        _ record: EvaluationRecord,
        forAttempt id: UUID
    ) -> Bool {
        guard record.expectedZone == currentZone, completeAttempt(id: id) else {
            return false
        }
        records.append(record)
        return true
    }

    public mutating func cancelAttempt() {
        attemptPhase = .ready
    }
}

public struct BenchmarkSession: Sendable {
    public let targetPerZone: Int
    public var samples: [BenchmarkSample]
    public var isArmed: Bool
    public var isSettling: Bool

    public init(targetPerZone: Int = 3) {
        self.targetPerZone = targetPerZone
        self.samples = []
        self.isArmed = false
        self.isSettling = false
    }

    public var currentStrategy: SensingStrategy? {
        SensingStrategy.allCases.first { strategy in
            DeskZone.allCases.contains { zone in
                count(strategy: strategy, zone: zone) < targetPerZone
            }
        }
    }

    public var currentZone: DeskZone? {
        guard let strategy = currentStrategy else { return nil }
        return DeskZone.allCases.first {
            count(strategy: strategy, zone: $0) < targetPerZone
        }
    }

    public var progress: Double {
        Double(samples.count)
            / Double(targetPerZone * DeskZone.allCases.count * SensingStrategy.allCases.count)
    }

    public func count(strategy: SensingStrategy, zone: DeskZone) -> Int {
        samples.filter {
            $0.labeledTap.feature.strategy == strategy && $0.labeledTap.zone == zone
        }.count
    }
}
