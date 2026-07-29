import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Bindable var settings: AppSettings
    var onSaved: (() -> Void)?
    @State private var cleanupMessage: String?

    var body: some View {
        Form {
            Section("Enregistrement") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dossier des MP4")
                        .font(.headline)
                    Text(settings.downloadFolderPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    HStack {
                        Button("Choisir…") { settings.chooseDownloadFolder() }
                        Button("Par défaut") { settings.resetDownloadFolderToDefault() }
                    }
                }

                Stepper(value: $settings.maxConcurrentJobs, in: 1...4) {
                    Text("Téléchargements simultanés : \(settings.maxConcurrentJobs)")
                }

                Stepper(value: $settings.maxConcurrentSegments, in: 1...32) {
                    Text("Segments en parallèle : \(settings.maxConcurrentSegments)")
                }
                Text("Plus élevé = plus rapide sur HLS/DASH. 16 est le défaut ; 24–32 sur fibre si le CDN suit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Stepper(value: $settings.maxRetries, in: 0...8) {
                    Text("Tentatives réseau (retry) : \(settings.maxRetries)")
                }
            }

            Section("Nomenclature (Jellyfin…)") {
                Picker("Modèle", selection: $settings.exportNamingPreset) {
                    ForEach(ExportNamingPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .onChange(of: settings.exportNamingPreset) { _, newValue in
                    if newValue != .custom {
                        settings.exportNamingTemplate = newValue.template
                    }
                }

                Text(settings.exportNamingPreset.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.exportNamingPreset == .custom {
                    TextField("Modèle personnalisé", text: $settings.exportNamingTemplate)
                        .font(.body.monospaced())
                    Text("{title} {year} {show} {season} {episode} {episode_title} {kind} {ext}")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Aperçu")
                        .font(.caption.weight(.semibold))
                    Text(settings.namingPreviewPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Qualité HLS") {
                Picker("Variante", selection: $settings.hlsQuality) {
                    ForEach(HLSQualityPreference.allCases) { pref in
                        Text(pref.label).tag(pref)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Automatisation") {
                Toggle("Auto-télécharger HLS détectés", isOn: $settings.automation.autoEnqueueHLS)
                Toggle("Auto-télécharger DASH détectés", isOn: $settings.automation.autoEnqueueDASH)
                Toggle("Auto-télécharger MP4 progressifs", isOn: $settings.automation.autoEnqueueProgressive)
                Text("Attention : peut lancer plusieurs jobs sur certains sites. Les favoris restent manuels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("CLI locale") {
                Text("Inbox : \(LocalCommandPaths.inbox.path)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Text("Exemple : openstream-cli download https://…/index.m3u8")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Réseau / VPN / Proxy") {
                VPNStatusRow(status: appState.vpnMonitor.status) {
                    appState.vpnMonitor.refresh()
                }

                Picker("Voyant VPN", selection: $settings.vpnIndicatorFilter) {
                    ForEach(VPNIndicatorFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .onChange(of: settings.vpnIndicatorFilter) { _, newValue in
                    appState.vpnMonitor.filter = newValue
                }

                Text("Le voyant s’appuie sur les VPN réellement Connected dans macOS (scutil), pas sur les apps en arrière-plan ni sur les utun vides. NordVPN peut rester lancé sans être connecté.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Mode téléchargements", selection: $settings.proxyMode) {
                    ForEach(ProxyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                if settings.proxyMode != .system {
                    TextField("Hôte", text: $settings.proxyHost)
                    TextField("Port", value: $settings.proxyPort, format: .number)
                    TextField("Utilisateur (optionnel)", text: $settings.proxyUsername)
                    SecureField("Mot de passe (optionnel)", text: $settings.proxyPassword)
                }
            }

            Section("Entretien") {
                Button("Nettoyer fichiers temporaires") {
                    let n = settings.cleanupOrphanParts()
                    cleanupMessage = n == 0
                        ? "Rien à nettoyer."
                        : "\(n) élément(s) temporaire(s) supprimé(s)."
                }
                if let cleanupMessage {
                    Text(cleanupMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Enregistrer") {
                    settings.save()
                    onSaved?()
                    cleanupMessage = "Paramètres enregistrés."
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 480, minHeight: 420)
    }
}

struct VPNStatusRow: View {
    let status: SystemVPNStatus
    var onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.isActive ? "lock.shield.fill" : "lock.shield")
                .font(.title2)
                .foregroundStyle(status.isActive ? .green : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(status.shortLabel)
                    .font(.headline)
                    .foregroundStyle(status.isActive ? .green : .primary)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            Button("Actualiser", action: onRefresh)
                .font(.caption)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
