import SwiftUI

/// Feuille d’ajustement manuel du sync audio/vidéo.
struct AVSyncSheet: View {
    @Environment(AppState.self) private var appState
    let target: AVSyncTarget

    /// Avance du son en fin de fichier (positif = son trop tôt et qui empire).
    @State private var endAudioLeadSeconds: Double = 1.0
    /// Décalage constant après correction de dérive (+ = retarder l’audio).
    @State private var audioShiftSeconds: Double = 0
    @State private var statusMessage: String?
    @State private var isBusy = false
    @State private var timing: MediaStreamTiming?

    private let leadRange: ClosedRange<Double> = -3.0...5.0
    private let shiftRange: ClosedRange<Double> = -2.0...2.0
    private let leadPresets: [Double] = [0.5, 1.0, 1.5, 2.0, 3.0]
    private let shiftPresets: [Double] = [-1.0, -0.5, 0, 0.5, 1.0]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(target.title)
                        .font(.headline)
                    Text(target.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let timing {
                        Text(diagnosticsText(timing))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let warning = durationMismatchWarning {
                        Text(warning)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Text("Si le son part juste puis dérive : timeline vidéo étirée (trous PTS). « Recaler » accélère l’audio pour coller — ou re-télécharge avec OpenStream 0.1.3+ (mux fMP4 brut + correction auto).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let skew = timing?.videoTimelineSkewRatio, abs(skew - 1) > 0.002 {
                        Text(String(format: "Timeline vidéo anormale : ×%.4f", skew))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }

                    Button {
                        Task { await applyPlayerAlign() }
                    } label: {
                        Label(
                            isBusy ? "…" : "Recaler (skew / piste courte)",
                            systemImage: "play.circle"
                        )
                    }
                    .disabled(isBusy)
                } header: {
                    Text("Recommandé")
                } footer: {
                    Text("Les fichiers déjà « réparés » plusieurs fois restent souvent irrécupérables — préfère un export neuf.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(leadLabel)
                                .font(.title3.monospacedDigit().weight(.semibold))
                            Spacer()
                            Stepper("", value: $endAudioLeadSeconds, in: leadRange, step: 0.1)
                                .labelsHidden()
                        }

                        Slider(value: $endAudioLeadSeconds, in: leadRange, step: 0.1)

                        HStack {
                            Text("Son trop tard en fin")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Son trop tôt en fin")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Text(leadGuidance)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let atempo = computedAtempo {
                            Text(String(format: "Facteur atempo %.5f", atempo))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 8) {
                        ForEach(leadPresets, id: \.self) { value in
                            Button(String(format: "+%.1fs", value)) {
                                endAudioLeadSeconds = value
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Button {
                        Task { await applyDrift() }
                    } label: {
                        Label(
                            isBusy ? "…" : "Corriger cette dérive",
                            systemImage: "waveform.path"
                        )
                    }
                    .disabled(isBusy || abs(endAudioLeadSeconds) < 0.02)
                } header: {
                    Text("Dérive linéaire (son qui s’éloigne à rythme constant)")
                } footer: {
                    Text("Inutile si le décalage n’est plus mesurable (timeline non linéaire). Dans ce cas, re-télécharge.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(shiftLabel)
                                .font(.title3.monospacedDigit().weight(.semibold))
                            Spacer()
                            Stepper("", value: $audioShiftSeconds, in: shiftRange, step: 0.05)
                                .labelsHidden()
                        }
                        Slider(value: $audioShiftSeconds, in: shiftRange, step: 0.05)
                        Text("Écart fixe restant après le recalage (son toujours en avance/retard d’autant partout).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        ForEach(shiftPresets, id: \.self) { value in
                            Button(presetLabel(value)) {
                                audioShiftSeconds = value
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Button {
                        Task { await applyManual() }
                    } label: {
                        Label(
                            isBusy ? "…" : "Appliquer ce décalage fixe",
                            systemImage: "timeline.selection"
                        )
                    }
                    .disabled(isBusy || abs(audioShiftSeconds) < 0.001)
                } header: {
                    Text("Décalage constant")
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Réparation auto (PTS)") {
                        Task { await applyAuto() }
                    }
                    .disabled(isBusy)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Ajuster sync")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { appState.avSyncTarget = nil }
                }
            }
            .task { await refreshTiming() }
        }
        .frame(width: 480, height: 620)
    }

    private var durationMismatchWarning: String? {
        guard let timing,
              let videoDuration = timing.videoDuration,
              let audioDuration = timing.audioDuration
        else { return nil }
        let delta = audioDuration - videoDuration
        guard abs(delta) > MediaAssembler.avDurationMismatchLimitSeconds else { return nil }
        let shorter = delta < 0 ? "L’audio" : "La vidéo"
        return String(
            format: "%@ est plus court(e) de %.0f s. Souvent des segments incomplets ou une timeline cassée — préfère un re-téléchargement.",
            shorter,
            abs(delta)
        )
    }

    private var computedAtempo: Double? {
        guard let duration = timing?.videoDuration else { return nil }
        return MediaAssembler.atempoForEndAudioLead(
            videoDuration: duration,
            endAudioLeadSeconds: endAudioLeadSeconds
        )
    }

    private var leadLabel: String {
        let ms = Int((endAudioLeadSeconds * 1000).rounded())
        if ms == 0 { return "0 ms en fin" }
        let sign = ms > 0 ? "+" : ""
        return "\(sign)\(ms) ms en fin"
    }

    private var leadGuidance: String {
        let ms = Int((endAudioLeadSeconds * 1000).rounded())
        if ms > 0 {
            return "Son en avance de \(ms) ms à la fin → on ralentit progressivement l’audio."
        }
        if ms < 0 {
            return "Son en retard de \(-ms) ms à la fin → on accélère progressivement l’audio."
        }
        return "Regarde la fin de l’épisode : si le son a ~1 s d’avance, mets +1,0 s."
    }

    private var shiftLabel: String {
        let ms = Int((audioShiftSeconds * 1000).rounded())
        if ms == 0 { return "0 ms" }
        let sign = ms > 0 ? "+" : ""
        return "\(sign)\(ms) ms"
    }

    private func diagnosticsText(_ timing: MediaStreamTiming) -> String {
        let startMs = Int(((timing.startDelta ?? 0) * 1000).rounded())
        let durMs = Int((abs(timing.durationDelta ?? 0) * 1000).rounded())
        return "Écart départ ~\(startMs) ms · écart durée ~\(durMs) ms"
    }

    private func presetLabel(_ value: Double) -> String {
        if value == 0 { return "0" }
        let ms = Int((value * 1000).rounded())
        return ms > 0 ? "+\(ms)" : "\(ms)"
    }

    @MainActor
    private func refreshTiming() async {
        do {
            let ffmpeg = try FFmpegWrapper()
            let probed = try await ffmpeg.probeStreamTiming(url: target.url)
            timing = probed
            if let delta = probed.durationDelta,
               abs(delta) >= 0.05,
               abs(delta) <= 5,
               abs(endAudioLeadSeconds - 1.0) < 0.001
            {
                endAudioLeadSeconds = -delta
            }
        } catch {
            timing = nil
        }
    }

    @MainActor
    private func applyPlayerAlign() async {
        isBusy = true
        statusMessage = "Recalage lecteur…"
        defer { isBusy = false }
        do {
            let assembler = try MediaAssembler()
            let result = try await assembler.realignLikePlayer(at: target.url)
            statusMessage = result.userMessage
            await refreshTiming()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func applyDrift() async {
        isBusy = true
        statusMessage = "Correction dérive…"
        defer { isBusy = false }
        do {
            let assembler = try MediaAssembler()
            let result = try await assembler.correctAVDrift(
                at: target.url,
                endAudioLeadSeconds: endAudioLeadSeconds
            )
            statusMessage = result.userMessage
            await refreshTiming()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func applyManual() async {
        isBusy = true
        statusMessage = "Application…"
        defer { isBusy = false }
        do {
            let result = try await appState.downloadManager.applyManualAudioShift(
                at: target.url,
                audioShiftSeconds: audioShiftSeconds
            )
            statusMessage = result.userMessage
            await refreshTiming()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    private func applyAuto() async {
        isBusy = true
        statusMessage = "Réparation auto…"
        defer { isBusy = false }
        do {
            let assembler = try MediaAssembler()
            let result = try await assembler.repairAVSync(at: target.url)
            statusMessage = result.userMessage
            await refreshTiming()
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
