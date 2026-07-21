import HoloCore
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    @State private var showApproachLab = false

    private var diagnosticLabels: [DiagnosticLabel] {
        DeskZone.allCases.map(DiagnosticLabel.zone) + [
            .negative("Talking"), .negative("Typing"), .negative("Laptop touch"), .negative("Background noise")
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Diagnostics")
                    .font(.title.weight(.semibold))
                Text("Inspect the microphone path, capture labeled examples, and compare sensing approaches on this desk.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                Section("Microphone") {
                    if let route = model.audio.diagnostics.audioRoute {
                        LabeledContent("Input", value: endpointDescription(route.input))
                        LabeledContent("Output", value: endpointDescription(route.output))
                        if let issue = AudioHardwarePolicy.issue(for: route, strategy: model.targetStrategy) {
                            Label(hardwareIssueDescription(issue), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        LabeledContent("Input", value: model.audio.diagnostics.deviceName)
                    }
                    LabeledContent("Available channels", value: "\(model.audio.diagnostics.channelCount)")
                    LabeledContent("Channel names", value: model.audio.diagnostics.channelNames.joined(separator: ", "))
                    LabeledContent("Sample rate", value: String(format: "%.0f Hz", model.audio.diagnostics.sampleRate))
                    LabeledContent("Analysis buffer", value: "\(model.audio.diagnostics.bufferFrameCount) frames")
                    LabeledContent("Reported input latency", value: String(format: "%.1f ms", model.audio.diagnostics.timing.estimatedInputLatencyMilliseconds))
                    LabeledContent("Callback jitter", value: String(format: "%.2f ms", model.audio.diagnostics.timing.callbackJitterMilliseconds))
                    LabeledContent("Soft candidates", value: "\(model.audio.detectorStatistics.candidateCount)")
                    LabeledContent("Noise peaks filtered", value: "\(model.audio.detectorStatistics.pendingRejectedCount)")
                    LabeledContent("Sustained sounds filtered", value: "\(model.audio.detectorStatistics.impactRejectedCount)")
                    LabeledContent("Tap windows emitted", value: "\(model.audio.detectorStatistics.emittedCount)")
                    Label(
                        "Holo uses only the channels exposed by AVAudioEngine; physical microphone-array access is not assumed.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Latest detected tap") {
                    if model.audio.diagnostics.latestFrequencyResponse.isEmpty {
                        Text("Tap the desk to inspect its response.")
                            .foregroundStyle(.secondary)
                    } else {
                        spectrumChart(model.audio.diagnostics.latestFrequencyResponse)
                            .frame(height: 150)
                            .padding(.vertical, 6)
                    }

                    if let quality = model.audio.diagnostics.latestSignalQuality {
                        LabeledContent("Quality", value: quality.summary)
                        LabeledContent("Signal-to-noise", value: String(format: "%.1f dB", quality.signalToNoiseDB))
                        LabeledContent("Peak amplitude", value: String(format: "%.3f", quality.peakAmplitude))
                        LabeledContent("Clipping", value: String(format: "%.1f%%", quality.clippingFraction * 100))
                    }
                }

                Section("Labeled capture") {
                    Picker("Label", selection: $model.diagnosticLabel) {
                        ForEach(diagnosticLabels) { label in
                            Text(label.displayName).tag(label)
                        }
                    }

                    HStack {
                        Button(model.diagnosticCaptureArmed ? "Waiting for Signal…" : "Capture Next Tap") {
                            model.armDiagnosticCapture()
                        }
                        .holoPrimaryButton()
                        .disabled(model.diagnosticCaptureArmed || !model.audio.isListening)

                        Text("\(model.diagnosticCaptures.count) feature samples")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Export JSON") { model.exportDiagnosticReport() }
                    }
                }

                Section("Privacy and debug audio") {
                    Toggle("Retain 90 ms debug recordings", isOn: Binding(
                        get: { model.debugRecordingEnabled },
                        set: model.setDebugRecordingEnabled
                    ))
                    Text(model.debugRecordingEnabled
                         ? "Raw WAV windows are being saved locally until you delete them."
                         : "Audio is discarded after feature extraction. Profiles contain features, not recordings.")
                        .font(.caption)
                        .foregroundStyle(model.debugRecordingEnabled ? Color.red : Color.secondary)
                    if model.hasDebugRecordings {
                        Button("Delete All Debug Recordings", role: .destructive) {
                            model.clearDebugRecordings()
                        }
                    }
                }

                Section("Sensing approach") {
                    DisclosureGroup("Compare passive, active, and hybrid sensing", isExpanded: $showApproachLab) {
                        approachLab
                            .padding(.top, 10)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: 760)
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HoloTheme.background)
        .onChange(of: model.benchmarkSession != nil) { _, running in
            if running { showApproachLab = true }
        }
    }

    private func endpointDescription(_ endpoint: AudioEndpointInfo?) -> String {
        guard let endpoint else { return "Unavailable" }
        return "\(endpoint.name) · \(endpoint.isBuiltIn ? "Built-in" : "External")"
    }

    private func hardwareIssueDescription(_ issue: AudioHardwarePolicyIssue) -> String {
        switch issue {
        case .inputUnavailable:
            return "The built-in microphone is unavailable."
        case .builtInInputRequired(let selected):
            return "\(selected) is selected. Holo requires the built-in microphone."
        case .outputUnavailable:
            return "This sensing approach requires the built-in speakers, which are unavailable."
        case .builtInOutputRequired(let selected):
            return "\(selected) is selected. Active sensing requires the built-in speakers."
        }
    }

    private var approachLab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This comparison collects three taps per zone for each approach, then compares cross-validation accuracy and processing latency. Active and hybrid modes emit a quiet chirp.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let session = model.benchmarkSession {
                ProgressView(value: session.progress)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.currentStrategy?.displayName ?? "Computing")
                            .font(.body.weight(.medium))
                        Text(session.currentZone?.instruction ?? "Comparison complete")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(session.samples.count) / \(session.targetPerZone * DeskZone.allCases.count * SensingStrategy.allCases.count)")
                        .font(.caption.monospacedDigit())
                    Button("Cancel", role: .cancel) { model.cancelApproachBenchmark() }
                }

                if session.isSettling {
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing the microphone…")
                            .font(.callout.weight(.medium))
                    }
                } else if session.isArmed {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                        Text("Capture armed")
                            .font(.callout.weight(.medium))
                        if let strategy = session.currentStrategy, let zone = session.currentZone {
                            Text("Tap \(session.count(strategy: strategy, zone: zone) + 1) of \(session.targetPerZone)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let zone = session.currentZone {
                    HStack {
                        Text("Sounds are ignored while you move to \(zone.displayName.lowercased()).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Arm \(zone.displayName)") { model.armApproachBenchmarkZone() }
                            .holoPrimaryButton()
                            .disabled(!model.audio.isListening)
                    }
                }

                if let issue = model.guidedCaptureIssue {
                    Label(issue.guidance, systemImage: "arrow.counterclockwise.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Button(model.approachComparison == nil ? "Run Comparison" : "Run Again") {
                    model.beginApproachBenchmark()
                }
                .holoPrimaryButton()
            }

            if let comparison = model.approachComparison {
                if !comparison.usesCurrentFeatureSchema {
                    Label(
                        "This saved comparison predates the current tap framing. Run it again before using its sensing recommendation.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if comparison.profileID != model.selectedProfile?.id {
                    Label(
                        "This saved comparison belongs to a different or unscoped desk setup. Run it again before using the result here.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Approach").foregroundStyle(.secondary)
                        Text("CV accuracy").foregroundStyle(.secondary)
                        Text("DSP latency").foregroundStyle(.secondary)
                        Text("Samples").foregroundStyle(.secondary)
                    }
                    ForEach(comparison.scores) { score in
                        GridRow {
                            HStack(spacing: 5) {
                                Text(score.strategy.displayName)
                                if score.strategy == comparison.selectedStrategy,
                                   model.applicableApproachComparison != nil {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                            Text("\(Int(score.crossValidationAccuracy * 100))%").monospacedDigit()
                            Text(String(format: "%.1f ms", score.medianProcessingLatencyMilliseconds)).monospacedDigit()
                            Text("\(score.sampleCount)").monospacedDigit()
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    private func spectrumChart(_ bands: [SpectrumBand]) -> some View {
        GeometryReader { geometry in
            let count = max(bands.count, 1)
            let width = geometry.size.width / CGFloat(count)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(bands) { band in
                    let normalized = min(max((band.levelDB + 110) / 90, 0.015), 1)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: max(width - 3, 2), height: geometry.size.height * normalized)
                        .help(String(format: "%.0f Hz • %.1f dB", band.centerFrequency, band.levelDB))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityLabel("Frequency response of latest detected tap")
    }
}
