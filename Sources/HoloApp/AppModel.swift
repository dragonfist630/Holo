import AppKit
import Combine
import Foundation
import HoloCore

enum DiagnosticLabel: Hashable, Identifiable {
    case zone(DeskZone)
    case negative(String)

    var id: String {
        switch self {
        case .zone(let zone): return "zone-\(zone.rawValue)"
        case .negative(let label): return "negative-\(label)"
        }
    }

    var displayName: String {
        switch self {
        case .zone(let zone): return zone.displayName
        case .negative(let label): return label
        }
    }

    var zone: DeskZone? {
        if case .zone(let zone) = self { return zone }
        return nil
    }
}

enum HoloStorageError: Error, LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let area):
            return "\(area) storage is unavailable. Holo did not save this change."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .live
    @Published private(set) var profiles: [HoloProfile] = []
    @Published var selectedProfileID: UUID?
    @Published private(set) var activeZone: DeskZone?
    @Published private(set) var lastDecision: ClassificationDecision?
    @Published private(set) var statusMessage = "Ready to map your desk"
    @Published private(set) var calibrationSession: CalibrationSession?
    @Published private(set) var calibrationValidation: CrossValidationResult?
    @Published private(set) var evaluationSession: EvaluationSession?
    @Published private(set) var latestEvaluation: EvaluationReport?
    @Published private(set) var evaluationHistory: [EvaluationReport] = []
    @Published private(set) var latestEvaluationIsPersisted = false
    @Published private(set) var benchmarkSession: BenchmarkSession?
    @Published private(set) var approachComparison: ApproachComparison?
    @Published private(set) var diagnosticCaptures: [DiagnosticCaptureRecord] = []
    @Published var diagnosticLabel: DiagnosticLabel = .zone(.leftTop)
    @Published var diagnosticCaptureArmed = false
    @Published private(set) var guidedCaptureIssue: GuidedCaptureQualityIssue?
    @Published var debugRecordingEnabled = false
    @Published private(set) var hasDebugRecordings = false
    @Published var errorMessage: String?

    let audio = AudioCaptureService()
    @Published var calibrationDraft = CalibrationDraft()

    private let profileStore: ProfileStore?
    private let evaluationStore: EvaluationStore?
    private let comparisonStore: ApproachComparisonStore?
    private let debugStore: DebugRecordingStore?
    private let actionDispatcher = LocalActionDispatcher()
    private var recalibratingProfileID: UUID?
    private var calibrationAcceptAfter = Date.distantPast
    private var benchmarkAcceptAfter = Date.distantPast
    private var calibrationArmTask: Task<Void, Never>?
    private var evaluationAttemptTask: Task<Void, Never>?
    private var evaluationAttemptWindow: EvaluationAttemptWindow?
    private var benchmarkArmTask: Task<Void, Never>?
    private var activeZoneClearTask: Task<Void, Never>?
    private var pausedByUser = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        var startupErrors: [String] = []
        do { profileStore = try ProfileStore() }
        catch {
            profileStore = nil
            startupErrors.append("Profiles: \(error.localizedDescription)")
        }
        do { evaluationStore = try EvaluationStore() }
        catch {
            evaluationStore = nil
            startupErrors.append("Evaluations: \(error.localizedDescription)")
        }
        do { comparisonStore = try ApproachComparisonStore() }
        catch {
            comparisonStore = nil
            startupErrors.append("Sensing comparison: \(error.localizedDescription)")
        }
        do { debugStore = try DebugRecordingStore() }
        catch {
            debugStore = nil
            startupErrors.append("Debug recordings: \(error.localizedDescription)")
        }

        if let debugStore {
            do { hasDebugRecordings = try debugStore.containsRecordings() }
            catch { startupErrors.append("Debug recordings: \(error.localizedDescription)") }
        }
        if let profileStore {
            do { profiles = try profileStore.loadAll() }
            catch { startupErrors.append("Profiles: \(error.localizedDescription)") }
        }
        selectedProfileID = profiles.first?.id
        if let evaluationStore {
            do { evaluationHistory = try evaluationStore.loadAll() }
            catch { startupErrors.append("Evaluations: \(error.localizedDescription)") }
        }
        refreshLatestEvaluation()
        if let comparisonStore {
            do { approachComparison = try comparisonStore.load() }
            catch { startupErrors.append("Sensing comparison: \(error.localizedDescription)") }
        }
        if let profile = profiles.first {
            calibrationDraft = draft(for: profile)
        } else {
            calibrationDraft.strategy = applicableApproachComparison?.selectedStrategy ?? .passive
        }
        if !startupErrors.isEmpty {
            statusMessage = "Local storage needs attention"
            errorMessage = "Some local data could not be opened:\n\n" + startupErrors.joined(separator: "\n")
        }

        audio.onObservation = { [weak self] observation in
            self?.handle(observation)
        }
        audio.onRouteInvalidated = { [weak self] message in
            self?.disarmAllCaptureIntents()
            self?.activeZone = nil
            self?.statusMessage = "Built-in audio route required"
            self?.errorMessage = message
        }
        actionDispatcher.onAsyncError = { [weak self] error in
            self?.errorMessage = "The assigned action failed. \(error.localizedDescription)"
        }
        audio.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    var selectedProfile: HoloProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first { $0.id == selectedProfileID }
    }

    var selectedProfileUsesCurrentFeatureSchema: Bool {
        selectedProfile?.classifier.usesCurrentFeatureSchema ?? false
    }

    var canStartEvaluationAttempt: Bool {
        evaluationSession?.attemptPhase == .ready
            && audio.isListening
            && audio.strategy == targetStrategy
    }

    var guidedSection: AppSection? {
        GuidedNavigationGate.guidedSection(
            calibrationActive: calibrationSession != nil,
            evaluationActive: evaluationSession != nil,
            benchmarkActive: benchmarkSession != nil
        )
    }

    func canNavigate(to candidate: AppSection) -> Bool {
        GuidedNavigationGate.canNavigate(to: candidate, guidedSection: guidedSection)
    }

    var targetStrategy: SensingStrategy {
        SensingStrategyResolver.resolve(
            benchmark: benchmarkSession?.currentStrategy,
            calibration: calibrationSession?.draft.strategy,
            profile: selectedProfile?.sensingStrategy,
            comparison: applicableApproachComparison?.selectedStrategy
        )
    }

    var applicableApproachComparison: ApproachComparison? {
        guard let comparison = approachComparison else { return nil }
        return comparison.applies(to: selectedProfile?.id) ? comparison : nil
    }

    func activate() async {
        do {
            try await audio.start(strategy: targetStrategy)
            if let zone = calibrationSession?.currentZone {
                statusMessage = "Calibration ready • move to \(zone.displayName), then arm"
            } else if selectedProfile != nil && !selectedProfileUsesCurrentFeatureSchema {
                statusMessage = "Recalibration required • tap preprocessing changed"
            } else if let zone = evaluationSession?.currentZone {
                statusMessage = "Accuracy test ready • move to \(zone.displayName), then start the next tap"
            } else if let benchmark = benchmarkSession,
                      let strategy = benchmark.currentStrategy,
                      let zone = benchmark.currentZone {
                statusMessage = "Sensing comparison ready • \(strategy.displayName) • \(zone.displayName)"
            } else {
                statusMessage = selectedProfile == nil ? "Listening • calibration needed" : "Listening for desk taps"
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Microphone unavailable"
        }
    }

    func activateOnLaunch() async {
        guard selectedProfile != nil else {
            section = .calibrate
            statusMessage = "Setup required • calibrate the four desk zones"
            return
        }

        switch audio.authorizationState {
        case .authorized:
            await activate()
        case .notDetermined:
            statusMessage = selectedProfile == nil
                ? "Microphone access will be requested when calibration begins"
                : "Press Resume to enable microphone access"
        case .unavailable:
            statusMessage = "Microphone access is off"
        }
    }

    func togglePause() {
        if audio.isListening {
            pausedByUser = true
            disarmAllCaptureIntents()
            audio.stop()
            statusMessage = "Paused"
            activeZone = nil
        } else if selectedProfile == nil && guidedSection == nil {
            openSetup()
        } else {
            pausedByUser = false
            Task { await activate() }
        }
    }

    func openSetup() {
        guard guidedSection == nil else { return }
        section = .calibrate
        statusMessage = "Setup required • calibrate the four desk zones"
    }

    func selectProfile(_ id: UUID?) {
        guard guidedSection == nil else { return }
        selectedProfileID = id
        activeZoneClearTask?.cancel()
        activeZone = nil
        lastDecision = nil
        refreshLatestEvaluation()
        if let profile = selectedProfile {
            calibrationDraft = draft(for: profile)
        }
        Task {
            do { try await reconfigureListeningAudio(to: targetStrategy) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func beginCalibration(draft: CalibrationDraft, recalibrating: HoloProfile? = nil) {
        pausedByUser = false
        calibrationArmTask?.cancel()
        evaluationAttemptTask?.cancel()
        evaluationAttemptWindow = nil
        benchmarkArmTask?.cancel()
        calibrationDraft = draft
        recalibratingProfileID = recalibrating?.id
        calibrationSession = CalibrationSession(draft: draft)
        audio.resetDetectorStatistics()
        calibrationValidation = nil
        guidedCaptureIssue = nil
        calibrationAcceptAfter = Date().addingTimeInterval(0.5)
        evaluationSession = nil
        benchmarkSession = nil
        section = .calibrate
        statusMessage = "Calibration • \(DeskZone.leftTop.displayName)"
        Task {
            do {
                try await prepareGuidedAudio(to: draft.strategy)
                guard calibrationSession != nil,
                      audio.isListening,
                      audio.strategy == draft.strategy else { return }
                armCalibrationZone()
            }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func prepareRecalibration() {
        guard guidedSection == nil else { return }
        if let profile = selectedProfile {
            calibrationDraft = draft(for: profile)
        }
        section = .calibrate
    }

    func cancelCalibration() {
        calibrationArmTask?.cancel()
        calibrationSession = nil
        calibrationValidation = nil
        guidedCaptureIssue = nil
        recalibratingProfileID = nil
        statusMessage = "Calibration cancelled"
        Task {
            do { try await reconfigureListeningAudio(to: targetStrategy) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func armCalibrationZone() {
        guard var session = calibrationSession, let zone = session.currentZone else { return }
        calibrationArmTask?.cancel()
        session.isArmed = false
        session.isSettling = true
        guidedCaptureIssue = nil
        calibrationSession = session
        statusMessage = "Get ready • listening starts in one second"
        scheduleCalibrationArm(for: zone, delayNanoseconds: 1_000_000_000)
    }

    private func scheduleCalibrationArm(for zone: DeskZone, delayNanoseconds: UInt64) {
        calibrationArmTask?.cancel()
        calibrationArmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  var current = self.calibrationSession,
                  self.audio.isListening,
                  self.audio.strategy == current.draft.strategy,
                  current.currentZone == zone,
                  current.isSettling else { return }
            current.isSettling = false
            current.isArmed = true
            self.calibrationAcceptAfter = Date()
            self.calibrationSession = current
            self.statusMessage = "Calibration armed • \(zone.displayName) • tap 1 of \(current.targetPerZone)"
        }
    }

    func collectNegativeExamples(label: String?) {
        calibrationSession?.negativeLabel = label
        calibrationSession?.isArmed = label != nil
        calibrationSession?.isSettling = false
        guidedCaptureIssue = nil
        calibrationAcceptAfter = Date().addingTimeInterval(label == nil ? 0 : 0.8)
        if let label {
            statusMessage = "Rejection training • make a \(label.lowercased()) sound"
        } else {
            statusMessage = "Calibration zones complete"
        }
    }

    func clearNegativeExamples(label: String) {
        guard var session = calibrationSession else { return }
        session.negativeSamples.removeAll { $0.negativeLabel == label }
        if session.negativeLabel == label {
            session.negativeLabel = nil
            session.isArmed = false
            session.isSettling = false
        }
        guidedCaptureIssue = nil
        calibrationSession = session
        statusMessage = "Cleared \(label.lowercased()) examples"
    }

    func undoLastCalibrationTap() {
        calibrationArmTask?.cancel()
        guard var session = calibrationSession else { return }
        if session.negativeLabel != nil, !session.negativeSamples.isEmpty {
            session.negativeSamples.removeLast()
        } else if !session.positiveSamples.isEmpty {
            session.positiveSamples.removeLast()
        }
        session.isArmed = false
        session.isSettling = false
        calibrationValidation = nil
        guidedCaptureIssue = nil
        calibrationSession = session
        calibrationAcceptAfter = Date().addingTimeInterval(0.35)
        if let zone = session.currentZone {
            statusMessage = "\(zone.displayName) • tap \(session.count(for: zone) + 1) of \(session.targetPerZone)"
        }
    }

    func retryCalibrationZone(_ requestedZone: DeskZone? = nil) {
        calibrationArmTask?.cancel()
        guard var session = calibrationSession else { return }
        let zone: DeskZone?
        if let requestedZone {
            zone = requestedZone
        } else {
            let current = session.currentZone
            if let current, session.count(for: current) > 0 {
                zone = current
            } else if let current {
                zone = DeskZone.allCases.last {
                    $0.rawValue < current.rawValue && session.count(for: $0) > 0
                }
            } else {
                zone = DeskZone.allCases.last
            }
        }
        guard let zone else { return }
        session.positiveSamples.removeAll { $0.zone == zone }
        session.negativeLabel = nil
        session.isArmed = false
        session.isSettling = false
        calibrationValidation = nil
        guidedCaptureIssue = nil
        calibrationSession = session
        calibrationAcceptAfter = Date().addingTimeInterval(0.5)
        statusMessage = "Retry \(zone.displayName) • tap 1 of \(session.targetPerZone)"
    }

    func finishCalibration(openActions: Bool = false) {
        guard let session = calibrationSession, session.zonesComplete else { return }
        do {
            let classifier = try TrainedTapClassifier.train(
                positiveExamples: session.positiveSamples,
                negativeExamples: session.negativeSamples
            )
            let crossValidation = try calibrationValidation
                ?? ClassifierEvaluator.leaveOneOut(session.positiveSamples)
            let counts = DeskZone.allCases.map { session.count(for: $0) }
            let summary = CalibrationSummary(
                sampleCount: session.positiveSamples.count,
                samplesPerZone: counts,
                leaveOneOutAccuracy: crossValidation.accuracy
            )
            let oldProfile = profiles.first { $0.id == recalibratingProfileID }
            var profile = HoloProfile(
                id: oldProfile?.id ?? UUID(),
                name: session.draft.name,
                surfaceDescription: session.draft.surfaceDescription,
                laptopPositionNote: session.draft.laptopPositionNote,
                classifier: classifier,
                calibration: summary,
                zones: oldProfile?.zones ?? DeskZone.allCases.map { ZoneConfiguration(zone: $0) }
            )
            if let oldProfile { profile.createdAt = oldProfile.createdAt }
            guard let profileStore else { throw HoloStorageError.unavailable("Desk profile") }
            try profileStore.save(profile)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.insert(profile, at: 0)
            }
            selectedProfileID = profile.id
            refreshLatestEvaluation()
            calibrationArmTask?.cancel()
            calibrationSession = nil
            calibrationValidation = nil
            guidedCaptureIssue = nil
            recalibratingProfileID = nil
            section = openActions ? .actions : .live
            statusMessage = "Calibration saved • listening"
            Task {
                do { try await reconfigureListeningAudio(to: profile.sensingStrategy) }
                catch { errorMessage = error.localizedDescription }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginEvaluation() {
        guard let profile = selectedProfile else {
            errorMessage = "Calibrate a desk profile before evaluating it."
            return
        }
        guard profile.classifier.usesCurrentFeatureSchema else {
            errorMessage = "This profile was calibrated with an older tap window. Create a fresh calibration before evaluating it."
            return
        }
        pausedByUser = false
        calibrationSession = nil
        benchmarkSession = nil
        calibrationArmTask?.cancel()
        benchmarkArmTask?.cancel()
        evaluationAttemptTask?.cancel()
        evaluationAttemptWindow = nil
        latestEvaluation = nil
        latestEvaluationIsPersisted = false
        activeZoneClearTask?.cancel()
        guidedCaptureIssue = nil
        activeZone = nil
        lastDecision = nil
        evaluationSession = EvaluationSession()
        audio.resetDetectorStatistics()
        section = .evaluate
        statusMessage = "Accuracy test ready • move to \(DeskZone.leftTop.displayName), then start tap 1"
        Task {
            do { try await prepareGuidedAudio(to: targetStrategy) }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func startEvaluationAttempt() {
        guard var session = evaluationSession,
              let zone = session.currentZone,
              audio.isListening,
              audio.strategy == targetStrategy else { return }
        let attemptID = UUID()
        guard session.beginAttempt(id: attemptID) != nil else { return }

        evaluationAttemptTask?.cancel()
        evaluationAttemptWindow = nil
        evaluationSession = session
        statusMessage = "Hold still • tap prompt starts shortly"
        let strategy = targetStrategy

        evaluationAttemptTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(
                    EvaluationAttemptTiming.preparationSeconds
                ))
            } catch { return }
            guard let self,
                  var current = self.evaluationSession,
                  self.audio.isListening,
                  self.audio.strategy == strategy,
                  current.currentZone == zone,
                  current.beginListening(id: attemptID) else { return }

            let openedAt = ProcessInfo.processInfo.systemUptime
            self.evaluationAttemptWindow = EvaluationAttemptWindow(
                id: attemptID,
                openedAtUptime: openedAt,
                closesAtUptime: openedAt + EvaluationAttemptTiming.listeningSeconds
            )
            self.evaluationSession = current
            let count = current.records.filter { $0.expectedZone == zone }.count
            self.statusMessage = "Tap now • \(zone.displayName) • \(count + 1)/\(current.targetPerZone)"

            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(
                    EvaluationAttemptTiming.listeningSeconds
                ))
            } catch { return }
            guard var resolving = self.evaluationSession,
                  resolving.beginResolving(id: attemptID) else { return }
            self.evaluationSession = resolving
            self.statusMessage = "Checking for the tap…"

            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(
                    EvaluationAttemptTiming.processingGraceSeconds
                ))
            } catch { return }
            self.recordMissedEvaluationAttempt(id: attemptID)
        }
    }

    func cancelEvaluation() {
        evaluationAttemptTask?.cancel()
        evaluationAttemptTask = nil
        evaluationAttemptWindow = nil
        evaluationSession = nil
        activeZone = nil
        refreshLatestEvaluation()
        statusMessage = "Accuracy test cancelled"
    }

    func beginApproachBenchmark() {
        pausedByUser = false
        calibrationArmTask?.cancel()
        evaluationAttemptTask?.cancel()
        evaluationAttemptWindow = nil
        benchmarkArmTask?.cancel()
        calibrationSession = nil
        evaluationSession = nil
        benchmarkSession = BenchmarkSession()
        audio.resetDetectorStatistics()
        guidedCaptureIssue = nil
        section = .diagnostics
        statusMessage = "Sensing comparison ready • move to \(DeskZone.leftTop.displayName), then arm"
        Task {
            do { try await prepareGuidedAudio(to: .passive) }
            catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func armApproachBenchmarkZone() {
        guard var session = benchmarkSession,
              let strategy = session.currentStrategy,
              let zone = session.currentZone else { return }
        benchmarkArmTask?.cancel()
        session.isArmed = false
        session.isSettling = true
        guidedCaptureIssue = nil
        benchmarkSession = session
        statusMessage = "Get ready • \(strategy.displayName) • \(zone.displayName)"
        benchmarkArmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  var current = self.benchmarkSession,
                  self.audio.isListening,
                  self.audio.strategy == strategy,
                  current.currentStrategy == strategy,
                  current.currentZone == zone,
                  current.isSettling else { return }
            current.isSettling = false
            current.isArmed = true
            self.benchmarkAcceptAfter = Date()
            self.benchmarkSession = current
            self.statusMessage = "Sensing comparison armed • \(strategy.displayName) • \(zone.displayName)"
        }
    }

    func cancelApproachBenchmark() {
        benchmarkArmTask?.cancel()
        benchmarkSession = nil
        guidedCaptureIssue = nil
        statusMessage = "Sensing comparison cancelled"
        Task {
            do { try await reconfigureListeningAudio(to: targetStrategy) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func armDiagnosticCapture() {
        diagnosticCaptureArmed = true
        statusMessage = "Diagnostic armed • tap \(diagnosticLabel.displayName)"
    }

    func exportDiagnosticReport() {
        let report = DiagnosticSessionReport(
            microphone: audio.diagnostics,
            captures: diagnosticCaptures,
            approachComparison: approachComparison,
            recordingsRetained: debugRecordingEnabled
        )
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "holo-diagnostic-\(Self.fileTimestamp()).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.jsonData().write(to: url, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
    }

    func setDebugRecordingEnabled(_ enabled: Bool) {
        guard enabled else {
            debugRecordingEnabled = false
            return
        }
        guard debugStore != nil else {
            debugRecordingEnabled = false
            errorMessage = HoloStorageError.unavailable("Debug recording").localizedDescription
            return
        }
        debugRecordingEnabled = true
    }

    func clearDebugRecordings() {
        do {
            guard let debugStore else { throw HoloStorageError.unavailable("Debug recording") }
            try debugStore.clear()
            hasDebugRecordings = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func updateAction(for zone: DeskZone, action: ZoneActionConfiguration) -> Bool {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == selectedProfileID }),
              let zoneIndex = profiles[profileIndex].zones.firstIndex(where: { $0.zone == zone }) else { return false }
        var updatedProfile = profiles[profileIndex]
        updatedProfile.zones[zoneIndex].action = action
        do {
            guard let profileStore else { throw HoloStorageError.unavailable("Desk profile") }
            try profileStore.save(updatedProfile)
            profiles[profileIndex] = updatedProfile
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func testAction(_ action: ZoneActionConfiguration) {
        do { try actionDispatcher.perform(action) }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteSelectedProfile() {
        guard let profile = selectedProfile else { return }
        do {
            guard let profileStore else { throw HoloStorageError.unavailable("Desk profile") }
            try profileStore.delete(profile)
            profiles.removeAll { $0.id == profile.id }
            selectedProfileID = profiles.first?.id
            refreshLatestEvaluation()
            if let nextProfile = selectedProfile {
                calibrationDraft = draft(for: nextProfile)
            }
            statusMessage = profiles.isEmpty ? "Calibration needed" : "Profile deleted"
            Task {
                do { try await reconfigureListeningAudio(to: targetStrategy) }
                catch { errorMessage = error.localizedDescription }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handle(_ observation: TapObservation) {
        if debugRecordingEnabled {
            let label = currentCaptureLabel
            do {
                guard let debugStore else { throw HoloStorageError.unavailable("Debug recording") }
                try debugStore.save(
                   observation,
                   label: label,
                   sampleRate: audio.diagnostics.sampleRate
                )
                hasDebugRecordings = true
            } catch {
                debugRecordingEnabled = false
                errorMessage = "Debug recording stopped because the WAV could not be saved. \(error.localizedDescription)"
            }
        }

        if var benchmark = benchmarkSession {
            handleBenchmark(observation, session: &benchmark)
            benchmarkSession = benchmark.currentStrategy == nil ? nil : benchmark
            return
        }

        if var calibration = calibrationSession {
            handleCalibration(observation, session: &calibration)
            calibrationSession = calibration
            return
        }

        if let evaluation = evaluationSession, let profile = selectedProfile {
            guard let window = evaluationAttemptWindow,
                  evaluation.acceptsObservation(
                    in: window,
                    eventHostTimeSeconds: observation.eventHostTimeSeconds
                  ) else { return }
            var decision = profile.classifier.predict(observation.feature)
            decision.processingLatencyMilliseconds = observation.processingLatencyMilliseconds
            recordEvaluation(
                attemptID: window.id,
                decision: decision,
                responseLatencyMilliseconds: responseLatencyMilliseconds(for: observation),
                feature: observation.feature,
                capturedAt: observation.feature.capturedAt
            )
            return
        }

        if section == .diagnostics {
            if diagnosticCaptureArmed {
                let capture = DiagnosticCaptureRecord(
                    label: diagnosticLabel.displayName,
                    zone: diagnosticLabel.zone,
                    feature: observation.feature,
                    responseLatencyMilliseconds: responseLatencyMilliseconds(for: observation)
                )
                diagnosticCaptures.append(capture)
                diagnosticCaptureArmed = false
                statusMessage = "Diagnostic captured • \(observation.feature.quality.summary)"
            }
            return
        }

        guard let profile = selectedProfile else {
            statusMessage = "Tap detected • calibrate to identify its zone"
            return
        }
        var decision = profile.classifier.predict(observation.feature)
        decision.processingLatencyMilliseconds = observation.processingLatencyMilliseconds
        present(decision)
        if let zone = decision.zone {
            if LocalActionDispatchPolicy.allowsAutomaticDispatch(
                for: decision,
                isDeskActive: section == .live
            ) {
                statusMessage = "\(zone.displayName) • \(Int(decision.confidence * 100))% confidence"
                do { try actionDispatcher.perform(profile.action(for: zone)) }
                catch {
                    statusMessage = "\(zone.displayName) accepted • action failed"
                    errorMessage = error.localizedDescription
                }
            } else {
                statusMessage = "\(zone.displayName) detected • actions paused outside Desk"
            }
        } else {
            statusMessage = "Rejected • \(decision.rejectionReason?.displayName ?? "low confidence")"
        }
    }

    private func handleCalibration(_ observation: TapObservation, session: inout CalibrationSession) {
        guard session.isArmed else { return }
        guard Date() >= calibrationAcceptAfter else { return }
        guard observation.feature.strategy == session.draft.strategy else { return }
        let quality = observation.feature.quality

        if let zone = session.currentZone {
            if let issue = GuidedCaptureQuality.issue(for: quality) {
                guidedCaptureIssue = issue
                statusMessage = issue.guidance
                return
            }
            guidedCaptureIssue = nil
            session.positiveSamples.append(LabeledTap(zone: zone, feature: observation.feature))
            let count = session.count(for: zone)
            if let next = session.currentZone {
                if count == session.targetPerZone {
                    session.isArmed = false
                    session.isSettling = true
                    statusMessage = "Zone saved • move to \(next.displayName) • listening starts automatically"
                    scheduleCalibrationArm(for: next, delayNanoseconds: 2_000_000_000)
                } else {
                    statusMessage = "\(zone.displayName) • tap \(count + 1) of \(session.targetPerZone)"
                }
            } else {
                session.isArmed = false
                session.isSettling = false
                do {
                    calibrationValidation = try ClassifierEvaluator.leaveOneOut(session.positiveSamples)
                    statusMessage = "All four zones captured • save or add rejection examples"
                } catch {
                    calibrationValidation = nil
                    statusMessage = "Calibration review unavailable"
                    errorMessage = "Holo could not review calibration consistency. \(error.localizedDescription)"
                }
            }
        } else if let label = session.negativeLabel {
            // Rejection examples are intentionally not required to resemble a
            // clean tap. Their job is to represent talking, typing, laptop
            // touches, and other sounds that should never run an action.
            guidedCaptureIssue = nil
            session.negativeSamples.append(LabeledTap(zone: nil, negativeLabel: label, feature: observation.feature))
            statusMessage = "\(label) examples • \(session.negativeCount(for: label)) captured"
        }
    }

    private func handleBenchmark(_ observation: TapObservation, session: inout BenchmarkSession) {
        guard session.isArmed,
              Date() >= benchmarkAcceptAfter,
              let strategy = session.currentStrategy,
              let zone = session.currentZone,
              observation.feature.strategy == strategy else { return }
        let quality = observation.feature.quality
        if let issue = GuidedCaptureQuality.issue(for: quality) {
            guidedCaptureIssue = issue
            statusMessage = "Sensing comparison • \(issue.guidance)"
            return
        }
        guidedCaptureIssue = nil
        let oldStrategy = strategy
        session.samples.append(BenchmarkSample(
            labeledTap: LabeledTap(zone: zone, feature: observation.feature),
            processingLatencyMilliseconds: observation.processingLatencyMilliseconds
        ))
        benchmarkAcceptAfter = Date().addingTimeInterval(0.40)

        guard let nextStrategy = session.currentStrategy, let nextZone = session.currentZone else {
            do {
                let comparison = try ApproachComparison.measure(
                    session.samples,
                    profileID: selectedProfile?.id
                )
                approachComparison = comparison
                guard let comparisonStore else { throw HoloStorageError.unavailable("Sensing comparison") }
                try comparisonStore.save(comparison)
                calibrationDraft.strategy = comparison.selectedStrategy
                benchmarkSession = nil
                statusMessage = "Comparison selected • \(comparison.selectedStrategy.displayName)"
                let resumeStrategy = selectedProfile?.sensingStrategy ?? comparison.selectedStrategy
                Task {
                    do { try await reconfigureListeningAudio(to: resumeStrategy) }
                    catch { errorMessage = error.localizedDescription }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        let completedZone = session.count(strategy: strategy, zone: zone) == session.targetPerZone
        if completedZone {
            session.isArmed = false
            session.isSettling = false
            statusMessage = "Set saved • move to \(nextZone.displayName), then arm \(nextStrategy.displayName)"
        } else {
            let nextTap = session.count(strategy: strategy, zone: zone) + 1
            statusMessage = "Sensing comparison • \(strategy.displayName) • \(zone.displayName) • \(nextTap)/\(session.targetPerZone)"
        }
        if nextStrategy != oldStrategy {
            Task {
                do { try await reconfigureListeningAudio(to: nextStrategy) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func finishEvaluation(_ session: EvaluationSession) {
        guard let profile = selectedProfile else { return }
        let report = EvaluationReport(
            profileID: profile.id,
            calibrationCapturedAt: profile.calibration.capturedAt,
            profileName: profile.name,
            strategy: profile.sensingStrategy,
            startedAt: session.startedAt,
            records: session.records,
            notes: "Guided held-out session; \(EvaluationAcceptance.tapsPerZone) prompted attempts per zone."
        )
        latestEvaluation = report
        latestEvaluationIsPersisted = false
        evaluationSession = nil
        do {
            guard let evaluationStore else { throw HoloStorageError.unavailable("Evaluation report") }
            try evaluationStore.save(report)
            evaluationHistory.removeAll {
                $0.profileID == report.profileID && $0.completedAt == report.completedAt
            }
            evaluationHistory.append(report)
            evaluationHistory.sort { $0.completedAt > $1.completedAt }
            latestEvaluationIsPersisted = true
            statusMessage = report.meetsAccuracyAndLatencyTargets
                ? "Accuracy test passed"
                : "Accuracy test complete • review results"
        } catch {
            statusMessage = "Accuracy test complete • report not saved"
            errorMessage = "The accuracy test completed, but its JSON/CSV report was not saved. \(error.localizedDescription)"
        }
    }

    private func recordEvaluation(
        attemptID: UUID,
        decision: ClassificationDecision,
        responseLatencyMilliseconds: Double,
        feature: TapFeatureVector?,
        capturedAt: Date
    ) {
        guard var evaluation = evaluationSession,
              let expected = evaluation.currentZone else { return }

        let record = EvaluationRecord(
            id: attemptID,
            expectedZone: expected,
            decision: decision,
            responseLatencyMilliseconds: responseLatencyMilliseconds,
            feature: feature,
            capturedAt: capturedAt
        )
        guard evaluation.record(record, forAttempt: attemptID) else { return }

        evaluationAttemptTask?.cancel()
        evaluationAttemptTask = nil
        evaluationAttemptWindow = nil

        present(decision)

        let completedExpectedZone = evaluation.records.filter {
            $0.expectedZone == expected
        }.count == evaluation.targetPerZone
        if completedExpectedZone {
            activeZone = nil
        }
        evaluationSession = evaluation

        if let next = evaluation.currentZone {
            let nextTap = evaluation.records.filter { $0.expectedZone == next }.count + 1
            if completedExpectedZone {
                statusMessage = decision.rejectionReason == .missedDetection
                    ? "No tap detected • attempt counted • move to \(next.displayName)"
                    : "Zone complete • move to \(next.displayName), then start the next tap"
            } else {
                statusMessage = decision.rejectionReason == .missedDetection
                    ? "No tap detected • attempt counted • \(next.displayName) • tap \(nextTap)/\(evaluation.targetPerZone)"
                    : "Accuracy test ready • \(next.displayName) • tap \(nextTap)/\(evaluation.targetPerZone)"
            }
        } else {
            finishEvaluation(evaluation)
        }
    }

    private func recordMissedEvaluationAttempt(id: UUID) {
        let decision = ClassificationDecision(
            zone: nil,
            confidence: 0,
            signalStrength: 0,
            zoneDistances: [],
            rejectionReason: .missedDetection
        )
        recordEvaluation(
            attemptID: id,
            decision: decision,
            responseLatencyMilliseconds: AudioTimeline.invalidElapsedMilliseconds,
            feature: nil,
            capturedAt: Date()
        )
    }

    private var currentCaptureLabel: String {
        if let session = calibrationSession {
            if let zone = session.currentZone { return "calibration-\(zone.shortName)" }
            if let label = session.negativeLabel { return "negative-\(label)" }
        }
        if let session = evaluationSession, let zone = session.currentZone { return "evaluation-\(zone.shortName)" }
        if let session = benchmarkSession, let strategy = session.currentStrategy, let zone = session.currentZone {
            return "benchmark-\(strategy.rawValue)-\(zone.shortName)"
        }
        return diagnosticLabel.displayName
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func nanoseconds(_ seconds: Double) -> UInt64 {
        UInt64(max(seconds, 0) * 1_000_000_000)
    }

    private func responseLatencyMilliseconds(for observation: TapObservation) -> Double {
        AudioTimeline.elapsedMilliseconds(
            since: observation.eventHostTimeSeconds,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    private func refreshLatestEvaluation() {
        latestEvaluation = EvaluationHistory.latest(
            for: selectedProfile?.id,
            calibrationCapturedAt: selectedProfile?.calibration.capturedAt,
            in: evaluationHistory
        )
        latestEvaluationIsPersisted = latestEvaluation != nil
    }

    private func disarmAllCaptureIntents() {
        calibrationArmTask?.cancel()
        evaluationAttemptTask?.cancel()
        evaluationAttemptTask = nil
        evaluationAttemptWindow = nil
        benchmarkArmTask?.cancel()
        calibrationSession?.isArmed = false
        calibrationSession?.isSettling = false
        calibrationSession?.negativeLabel = nil
        evaluationSession?.cancelAttempt()
        benchmarkSession?.isArmed = false
        benchmarkSession?.isSettling = false
        diagnosticCaptureArmed = false
        guidedCaptureIssue = nil
    }

    private func present(_ decision: ClassificationDecision) {
        activeZoneClearTask?.cancel()
        lastDecision = decision
        activeZone = decision.zone
        guard let zone = decision.zone else { return }
        activeZoneClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.activeZone == zone else { return }
            self.activeZone = nil
        }
    }

    private func reconfigureListeningAudio(to strategy: SensingStrategy) async throws {
        guard audio.isListening else { return }
        try await audio.reconfigure(strategy: strategy)
    }

    private func prepareGuidedAudio(to strategy: SensingStrategy) async throws {
        guard !pausedByUser else { return }
        if audio.isListening {
            try await audio.reconfigure(strategy: strategy)
        } else {
            try await audio.start(strategy: strategy)
        }
    }

    private func draft(for profile: HoloProfile) -> CalibrationDraft {
        CalibrationDraft(
            name: profile.name,
            surfaceDescription: profile.surfaceDescription,
            laptopPositionNote: profile.laptopPositionNote,
            strategy: applicableApproachComparison?.selectedStrategy ?? profile.sensingStrategy
        )
    }
}
