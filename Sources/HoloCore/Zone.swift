import Foundation

public enum DeskZone: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case leftTop = 0
    case leftBottom
    case rightTop
    case rightBottom

    public var id: Int { rawValue }
    public var verticalIndex: Int { rawValue % 2 }
    public var row: Int { verticalIndex }
    public var column: Int { rawValue < 2 ? 0 : 1 }
    public var isLeft: Bool { rawValue < 2 }

    public var positionName: String {
        verticalIndex == 0 ? "Rear" : "Front"
    }

    public var shortName: String {
        ["LR", "LF", "RR", "RF"][rawValue]
    }

    public var displayName: String {
        ["Left Rear", "Left Front", "Right Rear", "Right Front"][rawValue]
    }

    public var instruction: String {
        let edge = verticalIndex == 0 ? "display" : "trackpad"
        return "Tap beside the MacBook on the \(isLeft ? "left" : "right"), near the \(edge) edge"
    }
}

public enum SensingStrategy: String, CaseIterable, Codable, Sendable, Identifiable {
    case passive
    case active
    case hybrid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .passive: return "Passive tap acoustics"
        case .active: return "Active acoustic probe"
        case .hybrid: return "Hybrid"
        }
    }

    public var detail: String {
        switch self {
        case .passive:
            return "Uses only the sound and vibration produced by a tap."
        case .active:
            return "Measures how a quiet repeating chirp changes around a tap."
        case .hybrid:
            return "Combines tap acoustics with the chirp response."
        }
    }
}

public enum RejectionReason: String, Codable, Sendable, Equatable {
    case missedDetection
    case weakSignal
    case lowSignalToNoise
    case clippedSignal
    case outOfDistribution
    case ambiguousZone
    case resemblesNegativeExample
    case schemaMismatch
    case paused

    public var displayName: String {
        switch self {
        case .missedDetection: return "Tap not detected"
        case .weakSignal: return "Signal too weak"
        case .lowSignalToNoise: return "Background noise too high"
        case .clippedSignal: return "Signal clipped"
        case .outOfDistribution: return "Unlike calibrated taps"
        case .ambiguousZone: return "Zone ambiguous"
        case .resemblesNegativeExample: return "Recognized non-desk sound"
        case .schemaMismatch: return "Profile is incompatible"
        case .paused: return "Listening paused"
        }
    }
}
