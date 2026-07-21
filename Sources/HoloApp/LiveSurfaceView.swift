import HoloCore
import SwiftUI

struct LiveSurfaceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.selectedProfile == nil {
            setupPrompt
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(36)
                .background(HoloTheme.background)
        } else if !model.selectedProfileUsesCurrentFeatureSchema {
            recalibrationPrompt
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(36)
                .background(HoloTheme.background)
        } else {
            liveDesk
        }
    }

    private var liveDesk: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 20)

            DeskMapView(
                activeZone: model.activeZone,
                targetZone: nil,
                confidence: model.lastDecision?.confidence ?? 0,
                signalStrength: model.lastDecision?.signalStrength ?? model.audio.liveLevel,
                isListening: model.audio.isListening
            )
            .frame(maxWidth: 760, maxHeight: 490)
            .padding(.horizontal, 36)

            resultStrip

            Spacer(minLength: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
        .background(HoloTheme.background)
    }

    private var setupPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "scope")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text("Set up the desk around your MacBook")
                .font(.title2.weight(.semibold))
            Text("Taps cannot be assigned until Holo learns this desk. You will tap ten times across each of four broad zones: rear and front on both sides of the MacBook.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Text("Microphone access is requested when calibration begins.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Set Up Four Zones") {
                model.openSetup()
            }
            .holoPrimaryButton()
            .controlSize(.large)
        }
        .padding(.top, 4)
    }

    private var recalibrationPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text("Refresh this desk calibration")
                .font(.title2.weight(.semibold))
            Text("Tap windows are now aligned to each detected onset instead of the surrounding audio callback. The saved profile and actions are intact, but its classifier cannot be mixed with the new tap windows.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            Button("Open Calibration") {
                model.prepareRecalibration()
            }
            .holoPrimaryButton()
            .controlSize(.large)
        }
    }

    private var resultStrip: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lastResultTitle)
                    .font(.headline)
                Text(model.lastDecision?.rejectionReason?.displayName ?? model.selectedProfile?.name ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 170, alignment: .leading)

            Divider().frame(height: 34)

            compactGauge("Confidence", value: model.lastDecision?.confidence ?? 0)
            compactGauge("Signal", value: model.lastDecision?.signalStrength ?? model.audio.liveLevel)

            if let latency = model.lastDecision?.processingLatencyMilliseconds, latency > 0 {
                Divider().frame(height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f ms", latency))
                        .font(.callout.monospacedDigit())
                    Text("Processing")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Recalibrate", systemImage: "arrow.triangle.2.circlepath") {
                model.prepareRecalibration()
            }
            .holoSecondaryButton()
        }
        .padding(16)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var lastResultTitle: String {
        guard let decision = model.lastDecision else { return "Waiting for a tap" }
        return decision.zone?.displayName ?? "Tap rejected"
    }

    private func compactGauge(_ label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value * 100))%")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ProgressView(value: value)
                .frame(width: 112)
        }
    }
}
