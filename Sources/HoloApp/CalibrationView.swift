import HoloCore
import SwiftUI

struct CalibrationView: View {
    @ObservedObject var model: AppModel
    @State private var showRejectionTraining = true

    var body: some View {
        Group {
            if let session = model.calibrationSession {
                activeCalibration(session)
            } else {
                setup
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HoloTheme.background)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up your desk")
                    .font(.title.weight(.semibold))
                Text("Ten clean taps in each of four broad zones. Spread them around each highlighted area so Holo learns the whole zone, not one point.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                Section("Profile") {
                    TextField("Name", text: $model.calibrationDraft.name, prompt: Text("My Desk"))
                    TextField("Surface", text: $model.calibrationDraft.surfaceDescription, prompt: Text("Wood, laminate, glass…"))
                    TextField("MacBook position", text: $model.calibrationDraft.laptopPositionNote, prompt: Text("Centered, near the back edge…"))
                }

                Section("Sensing") {
                    Picker("Approach", selection: $model.calibrationDraft.strategy) {
                        ForEach(SensingStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    Text(model.calibrationDraft.strategy.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.calibrationDraft.strategy != .passive {
                        Label("Uses a quiet repeating speaker chirp", systemImage: "speaker.wave.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Before calibration") {
                    Label("Put the MacBook where it normally stays", systemImage: "macbook")
                    Label("Clear objects and cables that touch the MacBook", systemImage: "rectangle.dashed")
                    Label("Use one finger and a similar natural force, but vary the position within each zone", systemImage: "hand.tap")
                }

                Section {
                    if let comparison = model.applicableApproachComparison {
                        Label(
                            "The latest diagnostics comparison selected \(comparison.selectedStrategy.displayName).",
                            systemImage: "checkmark.circle"
                        )
                    } else {
                        Label(
                            model.selectedProfile == nil
                                ? "Passive sensing is selected until you compare approaches in Diagnostics."
                                : "This profile keeps its saved approach until you compare approaches on this desk.",
                            systemImage: "info.circle"
                        )
                    }

                    HStack {
                        if let profile = model.selectedProfile {
                            Button("Recalibrate \(profile.name)") {
                                model.beginCalibration(draft: model.calibrationDraft, recalibrating: profile)
                            }
                            .holoPrimaryButton()
                            .controlSize(.large)

                            Button("Create New Profile") {
                                model.beginCalibration(draft: model.calibrationDraft)
                            }
                            .holoSecondaryButton()
                        } else {
                            Button("Begin Calibration") {
                                model.beginCalibration(draft: model.calibrationDraft)
                            }
                            .holoPrimaryButton()
                            .controlSize(.large)
                        }
                    }
                    .disabled(model.calibrationDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func activeCalibration(_ session: CalibrationSession) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.zonesComplete ? "All zones captured" : session.currentZone?.displayName ?? "Calibration")
                            .font(.title.weight(.semibold))
                        Text(session.zonesComplete ? "Save the profile, then assign actions." : instruction(for: session))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(session.positiveSamples.count) of \(session.totalRequired)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: session.progress)
                    .accessibilityLabel("Calibration progress")

                DeskMapView(
                    activeZone: nil,
                    targetZone: session.currentZone,
                    confidence: 0,
                    signalStrength: model.audio.liveLevel,
                    isListening: model.audio.isListening,
                    counts: DeskZone.allCases.map { session.count(for: $0) }
                )
                .frame(maxWidth: 760)

                if session.zonesComplete {
                    completionControls(session)
                } else {
                    zoneControls(session)
                }
            }
            .frame(maxWidth: 820)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    private func zoneControls(_ session: CalibrationSession) -> some View {
        VStack(spacing: 14) {
            if session.isSettling {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(settlingMessage(for: session))
                        .font(.headline)
                }
                .accessibilityElement(children: .combine)
            } else if session.isArmed {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                    Text("Listening for this zone")
                        .font(.headline)
                    if let zone = session.currentZone {
                        Text("Tap \(session.count(for: zone) + 1) of \(session.targetPerZone)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } else if let zone = session.currentZone {
                Text("Move your hand to the \(zone.displayName.lowercased()) area. Holo ignores all sounds until you arm the zone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Arm \(zone.displayName)") {
                    model.armCalibrationZone()
                }
                .holoPrimaryButton()
                .controlSize(.large)
                .disabled(!model.audio.isListening)
                .help(model.audio.isListening ? "Start collecting this zone" : "Resume the microphone before arming")
                .accessibilityHint(model.audio.isListening
                    ? "Starts listening for taps in this zone."
                    : "The microphone is paused. Resume it before arming.")
            }

            if let issue = model.guidedCaptureIssue {
                Label(issue.guidance, systemImage: "arrow.counterclockwise.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Capture guidance: \(issue.guidance)")
            } else if let quality = model.audio.diagnostics.latestSignalQuality {
                HStack(spacing: 18) {
                    Label(quality.summary, systemImage: quality.score > 0.48 ? "checkmark.circle" : "exclamationmark.circle")
                    Text(String(format: "%.1f dB SNR", quality.signalToNoiseDB))
                    Text(String(format: "%.3f peak", quality.peakAmplitude))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Signal quality")
                .accessibilityValue("\(quality.summary). \(String(format: "%.1f", quality.signalToNoiseDB)) decibels signal to noise.")
            }

            let detectorStatistics = model.audio.detectorStatistics
            Text(
                "Detector: \(detectorStatistics.candidateCount) candidates • "
                    + "\(detectorStatistics.pendingRejectedCount + detectorStatistics.impactRejectedCount) filtered • "
                    + "\(detectorStatistics.emittedCount) tap windows"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Tap detector status")
            .accessibilityValue(
                "\(detectorStatistics.candidateCount) candidates, "
                    + "\(detectorStatistics.pendingRejectedCount + detectorStatistics.impactRejectedCount) filtered, "
                    + "\(detectorStatistics.emittedCount) tap windows"
            )

            HStack {
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    model.undoLastCalibrationTap()
                }
                .holoSecondaryButton()
                .disabled(session.positiveSamples.isEmpty)

                Button("Redo Zone", systemImage: "arrow.counterclockwise") {
                    model.retryCalibrationZone()
                }
                .holoSecondaryButton()
                .disabled(session.positiveSamples.isEmpty)

                Spacer()

                Button("Cancel", role: .cancel) {
                    model.cancelCalibration()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func completionControls(_ session: CalibrationSession) -> some View {
        let weakest = model.calibrationValidation.flatMap { weakestResult(in: $0) }
        let needsReview = (model.calibrationValidation?.accuracy ?? 1) < CalibrationGuidance.minimumCleanAgreement

        return VStack(alignment: .leading, spacing: 14) {
            if let validation = model.calibrationValidation {
                consistencyReview(validation)
                Divider()
            }

            HStack {
                if needsReview, let weakest {
                    Button("Redo \(weakest.zone.displayName)") {
                        model.retryCalibrationZone(weakest.zone)
                    }
                    .holoPrimaryButton()
                    .controlSize(.large)

                    Menu("Save Anyway") {
                        Button("Save and Set Actions") {
                            model.finishCalibration(openActions: true)
                        }
                        Button("Save for Later") {
                            model.finishCalibration()
                        }
                    }
                    .holoSecondaryButton()
                } else {
                    Button("Save and Set Actions") {
                        model.finishCalibration(openActions: true)
                    }
                    .holoPrimaryButton()
                    .controlSize(.large)

                    Button("Save for Later") {
                        model.finishCalibration()
                    }
                    .holoSecondaryButton()
                }

                Spacer()
            }

            DisclosureGroup("Teach Holo sounds to reject (recommended)", isExpanded: $showRejectionTraining) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Capture Talking first: speak normally for a few seconds. Only speech peaks that reach the classifier are counted, and only acoustic features are saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(["Talking", "Typing", "Laptop touch", "Background noise"], id: \.self) { label in
                        HStack {
                            Button {
                                model.collectNegativeExamples(label: session.negativeLabel == label ? nil : label)
                            } label: {
                                Label(
                                    session.negativeLabel == label ? "Stop \(label)" : "Capture \(label)",
                                    systemImage: session.negativeLabel == label ? "stop.circle.fill" : "record.circle"
                                )
                            }
                            .holoSecondaryButton()
                            .disabled(!model.audio.isListening)
                            Text("\(session.negativeCount(for: label)) captured")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("\(session.negativeCount(for: label)) \(label) examples captured")
                            if session.negativeCount(for: label) > 0 {
                                Button("Clear") {
                                    model.clearNegativeExamples(label: label)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Clear \(label) examples")
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(18)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func consistencyReview(_ validation: CrossValidationResult) -> some View {
        let weakest = weakestResult(in: validation)
        let needsReview = validation.accuracy < CalibrationGuidance.minimumCleanAgreement

        return VStack(alignment: .leading, spacing: 8) {
            Label(
                "Calibration agreement: \(Int(validation.accuracy * 100))%",
                systemImage: needsReview ? "exclamationmark.triangle" : "checkmark.circle"
            )
            .font(.headline)
            .foregroundStyle(needsReview ? Color.orange : Color.primary)

                    Text("Each tap was classified while left out of training. This checks consistency; it is not the separate accuracy test.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if needsReview, let weakest {
                Text("Weakest zone: \(weakest.zone.displayName) · \(Int(weakest.accuracy * 100))%. Recapture it for a cleaner profile, or save anyway from the secondary menu.")
                    .font(.callout)
            }
        }
    }

    private func weakestResult(in validation: CrossValidationResult) -> ZoneAccuracy? {
        validation.perZoneAccuracy.min { lhs, rhs in
            if lhs.accuracy == rhs.accuracy { return lhs.zone.rawValue < rhs.zone.rawValue }
            return lhs.accuracy < rhs.accuracy
        }
    }

    private func instruction(for session: CalibrationSession) -> String {
        guard session.currentZone != nil else { return "" }
        if session.isSettling {
            return "Move to the highlighted zone. Listening starts automatically."
        }
        if session.isArmed {
            return "Spread natural taps across the highlighted area and pause between taps."
        }
        return "Move to the highlighted zone, then arm it when ready."
    }

    private func settlingMessage(for session: CalibrationSession) -> String {
        guard let zone = session.currentZone else { return "Preparing…" }
        if session.positiveSamples.isEmpty {
            return "Preparing \(zone.displayName)…"
        }
        return "Move to \(zone.displayName) • listening starts automatically"
    }
}
