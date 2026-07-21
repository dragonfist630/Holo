import Foundation

public struct SignalQuality: Codable, Equatable, Sendable {
    public static let minimumReliablePeakAmplitude = 0.003
    public static let maximumReliableClippingFraction = 0.20
    // Onset-relative peak-to-pre-onset RMS. Five decibels still requires a
    // clear 1.78x local contrast, while avoiding a second rejection for
    // comfortable taps that already passed the filtered 2x onset detector.
    public static let minimumClassificationSignalToNoiseDB = 5.0

    public var signalToNoiseDB: Double
    public var peakAmplitude: Double
    public var rmsAmplitude: Double
    public var clippingFraction: Double
    public var noiseFloorRMS: Double
    public var durationMilliseconds: Double

    public init(
        signalToNoiseDB: Double,
        peakAmplitude: Double,
        rmsAmplitude: Double,
        clippingFraction: Double,
        noiseFloorRMS: Double,
        durationMilliseconds: Double
    ) {
        self.signalToNoiseDB = signalToNoiseDB
        self.peakAmplitude = peakAmplitude
        self.rmsAmplitude = rmsAmplitude
        self.clippingFraction = clippingFraction
        self.noiseFloorRMS = noiseFloorRMS
        self.durationMilliseconds = durationMilliseconds
    }

    public var score: Double {
        let snr = min(max((signalToNoiseDB - 4) / 30, 0), 1)
        let strength = min(max((peakAmplitude - Self.minimumReliablePeakAmplitude) / 0.15, 0), 1)
        let clean = 1 - min(clippingFraction * 4, 1)
        return 0.55 * snr + 0.25 * strength + 0.20 * clean
    }

    public var summary: String {
        if clippingFraction > Self.maximumReliableClippingFraction { return "Clipped" }
        if peakAmplitude < Self.minimumReliablePeakAmplitude { return "Weak" }
        if signalToNoiseDB < Self.minimumClassificationSignalToNoiseDB { return "Noisy" }
        if score > 0.72 { return "Excellent" }
        if score > 0.48 { return "Good" }
        return "Fair"
    }
}

public struct TapFeatureVector: Codable, Equatable, Sendable {
    /// Version 2 binds features to fixed onset-relative candidate framing. The
    /// vector names are unchanged, but version 1 values were measured from a
    /// callback-relative window and must not be mixed into the same model.
    public static let schemaVersion = 2

    public var version: Int
    public var strategy: SensingStrategy
    public var names: [String]
    public var values: [Double]
    public var quality: SignalQuality
    public var capturedAt: Date

    public init(
        strategy: SensingStrategy,
        names: [String],
        values: [Double],
        quality: SignalQuality,
        capturedAt: Date = Date()
    ) {
        self.version = Self.schemaVersion
        self.strategy = strategy
        self.names = names
        self.values = values
        self.quality = quality
        self.capturedAt = capturedAt
    }
}

public struct LabeledTap: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var zone: DeskZone?
    public var negativeLabel: String?
    public var feature: TapFeatureVector

    public init(
        id: UUID = UUID(),
        zone: DeskZone?,
        negativeLabel: String? = nil,
        feature: TapFeatureVector
    ) {
        self.id = id
        self.zone = zone
        self.negativeLabel = negativeLabel
        self.feature = feature
    }
}

public struct DetectedTap: Sendable {
    public var channels: [[Float]]
    public var onsetOffset: Int
    public var streamSampleIndex: Int64
    public var noiseFloorRMS: Double

    public init(
        channels: [[Float]],
        onsetOffset: Int,
        streamSampleIndex: Int64,
        noiseFloorRMS: Double
    ) {
        self.channels = channels
        self.onsetOffset = onsetOffset
        self.streamSampleIndex = streamSampleIndex
        self.noiseFloorRMS = noiseFloorRMS
    }
}

public struct SpectrumBand: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { Int(centerFrequency.rounded()) }
    public var centerFrequency: Double
    public var levelDB: Double

    public init(centerFrequency: Double, levelDB: Double) {
        self.centerFrequency = centerFrequency
        self.levelDB = levelDB
    }
}
