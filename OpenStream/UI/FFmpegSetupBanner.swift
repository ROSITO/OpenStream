import AppKit
import SwiftUI

struct FFmpegSetupBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.ffmpegStatus {
        case .ready:
            EmptyView()
        case .missingFFmpeg:
            bar(
                title: "FFmpeg n’est pas installé",
                detail: "Nécessaire pour assembler les MP4. Homebrew va l’installer (quelques minutes)."
            ) {
                Button("Installer FFmpeg") {
                    appState.installFFmpegWithBrew()
                }
                .disabled(appState.ffmpegInstallInProgress)
            }
        case .missingHomebrew:
            bar(
                title: "FFmpeg et Homebrew manquent",
                detail: "Installez Homebrew, puis FFmpeg. Sans ça, les téléchargements ne pourront pas être assemblés."
            ) {
                Button("Ouvrir brew.sh") {
                    if let url = URL(string: "https://brew.sh") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bar(
        title: String,
        detail: String,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(appState.ffmpegInstallLog ?? detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            if appState.ffmpegInstallInProgress {
                ProgressView()
                    .controlSize(.small)
            }
            action()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.yellow.opacity(0.18))
    }
}
