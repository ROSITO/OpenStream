import AppKit
import SwiftUI

struct FFmpegSetupBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.ffmpegStatus {
        case .readyBundled, .readySystem:
            EmptyView()
        case .missingFFmpeg:
            bar(
                title: "FFmpeg embarqué manquant",
                detail: "Relance ./scripts/fetch-bundled-ffmpeg.sh puis rebuild. Secours : installer via Homebrew."
            ) {
                Button("Installer via Homebrew") {
                    appState.installFFmpegWithBrew()
                }
                .disabled(appState.ffmpegInstallInProgress)
            }
        case .missingHomebrew:
            bar(
                title: "FFmpeg embarqué manquant",
                detail: "Pas de Helpers dans le bundle. Lance ./scripts/fetch-bundled-ffmpeg.sh puis rebuild l’app."
            ) {
                EmptyView()
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
