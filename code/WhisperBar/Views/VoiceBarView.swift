import SwiftUI
import AppKit

struct VoiceBarView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    let onOpenVocabulary: () -> Void
    let onOpenRecordings: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)

            VStack(spacing: 0) {
                // ── Main control row ──
                HStack(spacing: 12) {
                    RecordButton()
                        .environmentObject(engine)

                    statusContent
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: onOpenRecordings) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("录音记录")

                    Button(action: onOpenVocabulary) {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("自定义词汇")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // ── Transcription result ──
                if !engine.transcribedText.isEmpty {
                    Divider().opacity(0.4).padding(.horizontal, 12)

                    HStack(alignment: .top, spacing: 8) {
                        Text(engine.transcribedText)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Button(action: copyNow) {
                            Image(systemName: engine.autoCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 13))
                                .foregroundStyle(engine.autoCopied ? .green : .blue)
                        }
                        .buttonStyle(.plain)
                        .help("复制")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                }

                // ── Accessibility permission warning ──
                if engine.needsAccessibility {
                    Divider().opacity(0.3).padding(.horizontal, 12)
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12))
                        Text("授权辅助功能可自动粘贴到光标位置")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("去授权") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            )
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.link)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: 500)
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var statusContent: some View {
        if engine.isRecording {
            WaveformView(levels: engine.audioLevels)
                .frame(height: 32)
        } else if engine.isTranscribing {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("转写中…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        } else if engine.autoCopied {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text(engine.statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(engine.statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func copyNow() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.transcribedText, forType: .string)
    }
}

// MARK: - Record Button

struct RecordButton: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @State private var isPressing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(buttonColor)
                .frame(width: 42, height: 42)
                .shadow(color: buttonColor.opacity(0.4), radius: 6)
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
        }
        .scaleEffect(isPressing ? 0.9 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressing)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressing {
                        isPressing = true
                        engine.handleButtonDown()
                    }
                }
                .onEnded { _ in
                    isPressing = false
                    engine.handleButtonUp()
                }
        )
    }

    private var buttonColor: Color {
        switch engine.modelState {
        case .loading: return .gray
        case .ready:   return engine.isRecording ? .red : .accentColor
        case .error:   return .orange
        }
    }

    private var iconName: String {
        switch engine.modelState {
        case .loading: return "ellipsis"
        case .ready:   return engine.isRecording ? "stop.fill" : "mic.fill"
        case .error:   return "exclamationmark.triangle"
        }
    }
}

// MARK: - Waveform

struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                let h = CGFloat(max(0.08, levels[i]))
                Capsule()
                    .fill(Color.red.opacity(0.75 + Double(h) * 0.25))
                    .frame(width: 3, height: 4 + h * 28)
                    .animation(.easeOut(duration: 0.08), value: h)
            }
        }
    }
}
