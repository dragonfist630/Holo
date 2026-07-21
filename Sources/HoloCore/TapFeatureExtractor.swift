import Foundation

public struct TapAnalysis: Equatable, Sendable {
    public var feature: TapFeatureVector
    public var spectrum: [SpectrumBand]

    public init(feature: TapFeatureVector, spectrum: [SpectrumBand]) {
        self.feature = feature
        self.spectrum = spectrum
    }
}

public struct TapFeatureExtractor: Sendable {
    public let sampleRate: Double
    public let strategy: SensingStrategy

    public init(sampleRate: Double, strategy: SensingStrategy) {
        self.sampleRate = sampleRate
        self.strategy = strategy
    }

    public func extract(from event: DetectedTap, capturedAt: Date = Date()) -> TapFeatureVector {
        let prepared = prepare(event)
        return makeFeature(
            event: event,
            channels: prepared.channels,
            mono: prepared.mono,
            powerSpectrum: prepared.powerSpectrum,
            capturedAt: capturedAt
        )
    }

    public func analyze(from event: DetectedTap, capturedAt: Date = Date()) -> TapAnalysis {
        let prepared = prepare(event)
        return TapAnalysis(
            feature: makeFeature(
                event: event,
                channels: prepared.channels,
                mono: prepared.mono,
                powerSpectrum: prepared.powerSpectrum,
                capturedAt: capturedAt
            ),
            spectrum: spectrumBands(from: prepared.powerSpectrum, count: 16)
        )
    }

    private func makeFeature(
        event: DetectedTap,
        channels: [[Float]],
        mono: [Double],
        powerSpectrum: [Double],
        capturedAt: Date
    ) -> TapFeatureVector {

        let selected: (names: [String], values: [Double])
        switch strategy {
        case .passive:
            selected = passiveFeatures(
                signal: mono,
                channels: channels,
                onset: event.onsetOffset,
                spectrum: powerSpectrum
            )
        case .active:
            selected = ActiveProbe.responseFeatures(
                signal: mono,
                sampleRate: sampleRate,
                spectrum: powerSpectrum
            )
        case .hybrid:
            let passive = passiveFeatures(
                signal: mono,
                channels: channels,
                onset: event.onsetOffset,
                spectrum: powerSpectrum
            )
            let active = ActiveProbe.responseFeatures(
                signal: mono,
                sampleRate: sampleRate,
                spectrum: powerSpectrum
            )
            selected = (passive.names + active.names, passive.values + active.values)
        }

        let onset = min(max(event.onsetOffset, 0), max(mono.count - 1, 0))
        let preStart = max(0, onset - Int(sampleRate * 0.012))
        let impactEnd = min(mono.count, onset + Int(sampleRate * 0.025))
        let preOnset = onset > preStart ? Array(mono[preStart..<onset]) : []
        let impact = impactEnd > onset ? Array(mono[onset..<impactEnd]) : mono
        let rms = rootMeanSquare(impact)
        let peak = impact.map(abs).max() ?? 0
        let clipping = Double(mono.filter { abs($0) >= 0.995 }.count) / Double(max(mono.count, 1))
        // Compare the onset peak with pre-onset RMS in the same full-band
        // signal. The old metric divided whole-window/full-band RMS by the
        // detector's callback/sub-6-kHz floor, diluting a 3 ms impact by about
        // 15 dB and then silently rejecting it during calibration and live use.
        let localNoiseRMS = max(rootMeanSquare(preOnset), 1e-12)
        let snr = 20 * log10(max(peak, 1e-12) / localNoiseRMS)
        let quality = SignalQuality(
            signalToNoiseDB: snr,
            peakAmplitude: peak,
            rmsAmplitude: rms,
            clippingFraction: clipping,
            noiseFloorRMS: localNoiseRMS,
            durationMilliseconds: Double(mono.count) / sampleRate * 1_000
        )

        return TapFeatureVector(
            strategy: strategy,
            names: selected.names,
            values: selected.values.map { $0.isFinite ? $0 : 0 },
            quality: quality,
            capturedAt: capturedAt
        )
    }

    public func spectrumBands(from event: DetectedTap, count: Int = 16) -> [SpectrumBand] {
        let mono = mixDown(event.channels).map(Double.init)
        let spectrum = Radix2FFT.powerSpectrum(mono, size: min(Radix2FFT.nextPowerOfTwo(mono.count), 4096))
        return spectrumBands(from: spectrum, count: count)
    }

    private func spectrumBands(from spectrum: [Double], count: Int) -> [SpectrumBand] {
        let minimum = 80.0
        let maximum = min(sampleRate * 0.46, 18_000)
        return (0..<count).map { band in
            let low = minimum * pow(maximum / minimum, Double(band) / Double(count))
            let high = minimum * pow(maximum / minimum, Double(band + 1) / Double(count))
            let center = sqrt(low * high)
            let start = frequencyBin(low, spectrumCount: spectrum.count)
            let end = max(start, frequencyBin(high, spectrumCount: spectrum.count))
            let energy = spectrum[start...min(end, spectrum.count - 1)].reduce(0, +) / Double(max(end - start + 1, 1))
            return SpectrumBand(centerFrequency: center, levelDB: 10 * log10(energy + 1e-15))
        }
    }

    private func prepare(_ event: DetectedTap) -> (
        channels: [[Float]],
        mono: [Double],
        powerSpectrum: [Double]
    ) {
        let channels = event.channels.filter { !$0.isEmpty }
        let mono = mixDown(channels).map(Double.init)
        let spectrum = Radix2FFT.powerSpectrum(
            mono,
            size: min(Radix2FFT.nextPowerOfTwo(mono.count), 4096)
        )
        return (channels, mono, spectrum)
    }

    private func passiveFeatures(
        signal: [Double],
        channels: [[Float]],
        onset: Int,
        spectrum: [Double]
    ) -> (names: [String], values: [Double]) {
        guard !signal.isEmpty else {
            return (Self.passiveFeatureNames, Array(repeating: 0, count: Self.passiveFeatureNames.count))
        }

        let rms = rootMeanSquare(signal)
        let peak = signal.map(abs).max() ?? 0
        let crest = peak / max(rms, 1e-12)
        let zeroCrossings = zip(signal, signal.dropFirst()).filter { ($0.0 >= 0) != ($0.1 >= 0) }.count
        let zeroCrossingRate = Double(zeroCrossings) / Double(max(signal.count - 1, 1))
        let peakIndex = signal.enumerated().max(by: { abs($0.element) < abs($1.element) })?.offset ?? onset
        let attackPosition = Double(max(peakIndex - onset, 0)) / Double(max(signal.count - onset, 1))

        let energies = signal.map { $0 * $0 }
        let totalEnergy = energies.reduce(0, +) + 1e-15
        let temporalCentroid = energies.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element } / totalEnergy / Double(max(signal.count - 1, 1))
        let split = min(max(onset + Int(sampleRate * 0.025), 1), signal.count - 1)
        let early = energies[..<split].reduce(0, +)
        let late = energies[split...].reduce(0, +)
        let earlyLateRatio = log10((early + 1e-12) / (late + 1e-12))

        let spectral = spectralFeatures(spectrum)
        let mel = melCepstralFeatures(spectrum, filterCount: 18, coefficientCount: 8)
        let bands = broadBandFeatures(spectrum, count: 10)
        let spatial = spatialFeatures(channels)

        let temporal = [log10(rms + 1e-12), crest, zeroCrossingRate, attackPosition, temporalCentroid, earlyLateRatio]
        return (Self.passiveFeatureNames, temporal + spectral + mel + bands + spatial)
    }

    private func spectralFeatures(_ spectrum: [Double]) -> [Double] {
        let usable = spectrum.enumerated().filter { index, _ in
            let frequency = Double(index) * sampleRate / Double(max((spectrum.count - 1) * 2, 1))
            return frequency >= 60 && frequency <= min(18_000, sampleRate * 0.48)
        }
        let total = usable.reduce(0) { $0 + $1.element } + 1e-15
        let centroid = usable.reduce(0) { partial, item in
            let frequency = Double(item.offset) * sampleRate / Double((spectrum.count - 1) * 2)
            return partial + frequency * item.element
        } / total
        let bandwidth = sqrt(usable.reduce(0) { partial, item in
            let frequency = Double(item.offset) * sampleRate / Double((spectrum.count - 1) * 2)
            return partial + pow(frequency - centroid, 2) * item.element
        } / total)

        var cumulative = 0.0
        var rolloff = 0.0
        for item in usable {
            cumulative += item.element
            if cumulative >= total * 0.85 {
                rolloff = Double(item.offset) * sampleRate / Double((spectrum.count - 1) * 2)
                break
            }
        }
        let arithmetic = total / Double(max(usable.count, 1))
        let geometric = exp(usable.reduce(0) { $0 + log($1.element + 1e-15) } / Double(max(usable.count, 1)))
        let flatness = geometric / max(arithmetic, 1e-15)
        return [centroid / sampleRate, bandwidth / sampleRate, rolloff / sampleRate, flatness]
    }

    private func melCepstralFeatures(_ spectrum: [Double], filterCount: Int, coefficientCount: Int) -> [Double] {
        let minMel = hzToMel(80)
        let maxMel = hzToMel(min(16_000, sampleRate * 0.46))
        let points = (0..<(filterCount + 2)).map { index in
            melToHz(minMel + (maxMel - minMel) * Double(index) / Double(filterCount + 1))
        }
        let bins = points.map { frequencyBin($0, spectrumCount: spectrum.count) }
        var logEnergies = Array(repeating: 0.0, count: filterCount)
        for filter in 0..<filterCount {
            let left = bins[filter]
            let center = max(bins[filter + 1], left + 1)
            let right = max(bins[filter + 2], center + 1)
            var energy = 0.0
            if left < spectrum.count {
                for index in left..<min(center, spectrum.count) {
                    energy += spectrum[index] * Double(index - left) / Double(max(center - left, 1))
                }
                if center < spectrum.count {
                    for index in center..<min(right, spectrum.count) {
                        energy += spectrum[index] * Double(right - index) / Double(max(right - center, 1))
                    }
                }
            }
            logEnergies[filter] = log(energy + 1e-15)
        }
        return (1...coefficientCount).map { coefficient in
            logEnergies.enumerated().reduce(0) { partial, item in
                partial + item.element * cos(Double.pi * Double(coefficient) * (Double(item.offset) + 0.5) / Double(filterCount))
            } / Double(filterCount)
        }
    }

    private func broadBandFeatures(_ spectrum: [Double], count: Int) -> [Double] {
        let minimum = 80.0
        let maximum = min(sampleRate * 0.46, 18_000)
        let total = spectrum.reduce(0, +) + 1e-15
        return (0..<count).map { band in
            let low = minimum * pow(maximum / minimum, Double(band) / Double(count))
            let high = minimum * pow(maximum / minimum, Double(band + 1) / Double(count))
            let start = frequencyBin(low, spectrumCount: spectrum.count)
            let end = max(start, frequencyBin(high, spectrumCount: spectrum.count))
            let energy = spectrum[start...min(end, spectrum.count - 1)].reduce(0, +) / total
            return log10(energy + 1e-12)
        }
    }

    private func spatialFeatures(_ channels: [[Float]]) -> [Double] {
        guard channels.count >= 2, !channels[0].isEmpty, !channels[1].isEmpty else { return [0, 0] }
        let first = channels[0].map(Double.init)
        let second = channels[1].map(Double.init)
        let firstRMS = rootMeanSquare(first)
        let secondRMS = rootMeanSquare(second)
        let energyDelta = log10((firstRMS + 1e-12) / (secondRMS + 1e-12))
        let maximumLag = min(Int(sampleRate * 0.000_75), 36)
        var bestLag = 0
        var bestCorrelation = -Double.infinity
        for lag in -maximumLag...maximumLag {
            var correlation = 0.0
            var count = 0
            for index in first.indices {
                let secondIndex = index + lag
                if secondIndex >= 0 && secondIndex < second.count {
                    correlation += first[index] * second[secondIndex]
                    count += 1
                }
            }
            if count > 0 && correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }
        return [energyDelta, Double(bestLag) / Double(max(maximumLag, 1))]
    }

    private func mixDown(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let count = channels.map(\.count).min() ?? 0
        var result = Array(repeating: Float.zero, count: count)
        for channel in channels {
            for index in 0..<count { result[index] += channel[index] / Float(channels.count) }
        }
        return result
    }

    private func rootMeanSquare(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
    }

    private func frequencyBin(_ frequency: Double, spectrumCount: Int) -> Int {
        let fftSize = max((spectrumCount - 1) * 2, 1)
        return min(max(Int(frequency / sampleRate * Double(fftSize)), 0), spectrumCount - 1)
    }

    private func hzToMel(_ hz: Double) -> Double { 2_595 * log10(1 + hz / 700) }
    private func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2_595) - 1) }

    public static let passiveFeatureNames = [
        "log_rms", "crest_factor", "zero_crossing_rate", "attack_position", "temporal_centroid", "early_late_ratio",
        "spectral_centroid", "spectral_bandwidth", "spectral_rolloff_85", "spectral_flatness"
    ] + (1...8).map { "mfcc_\($0)" }
      + (0..<10).map { "band_\($0)" }
      + ["channel_energy_delta", "interchannel_delay"]
}
