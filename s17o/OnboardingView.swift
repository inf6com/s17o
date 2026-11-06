import SwiftUI

// ---------------------------------------------------------------------------
// OnboardingView (macOS) — 初回起動時の初期設定導線
// ---------------------------------------------------------------------------

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var step: Step = .welcome
    @State private var keywordsInput: String = ""

    enum Step: Int, CaseIterable {
        case welcome
        case keywords
        case audio
        case permissions
        case browserExtension
        case safariJavaScript
    }

    /// 音声自動制御のうち do JavaScript を必要とする機能が有効かどうか
    private var needsSafariJavaScript: Bool {
        model.suppressCommercialAudioEnabled || model.suppressEnglishCommentaryEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 28)
                .padding(.bottom, 20)

            Group {
                switch step {
                case .welcome:           welcomeStep
                case .keywords:          keywordsStep
                case .audio:             audioStep
                case .permissions:       permissionsStep
                case .browserExtension:  browserExtensionStep
                case .safariJavaScript:  safariJavaScriptStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            navigationButtons
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
        }
        .frame(width: 520, height: 480)
        .onAppear {
            keywordsInput = model.keywordsText
        }
        .task {
            await model.refreshSetupStatus()
            await model.refreshBrowserControlStateAndWait()
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("s17o へようこそ")
                .font(.title.bold())

            Text("ライブ動画の進行状態を把握し、\n重要イベントを自動検出するアプリです。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("まず、いくつかの初期設定を行います。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Keywords

    private var keywordsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("キーワードを設定")
                .font(.title2.bold())

            Text("検出したい選手名やイベント名を、1 行に 1 つ入力してください。")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $keywordsInput)
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .padding(8)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                }

            if keywordsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("最低 1 つのキーワードが必要です。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Audio

    private var audioStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音声の自動制御")
                .font(.title2.bold())

            Text("s17o がリアルタイムで音声を制御します。後からでも変更できます。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                audioToggleRow(
                    title: "打席時にミュート解除",
                    subtitle: "キーワードの選手が打席に立ったとき、自動でミュートを解除します。",
                    systemImage: "speaker.wave.2.fill",
                    isOn: $model.autoSoundControlEnabled
                )
                Divider().padding(.leading, 52)
                audioToggleRow(
                    title: "広告中はミュート",
                    subtitle: "CM・広告の再生中は自動でミュートし、試合再開時に戻します。",
                    systemImage: "speaker.slash.fill",
                    isOn: $model.suppressCommercialAudioEnabled
                )
                Divider().padding(.leading, 52)
                audioToggleRow(
                    title: "英語実況をミュート",
                    subtitle: "英語の実況トラックを自動でミュートします。",
                    systemImage: "mic.slash.fill",
                    isOn: $model.suppressEnglishCommentaryEnabled
                )
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func audioToggleRow(title: String, subtitle: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("アクセス権限")
                .font(.title2.bold())

            Text("音声認識・画面収録・通知の許可が必要です。「許可する」を押すとシステムダイアログが表示されます。")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                permissionRow(
                    title: "音声認識",
                    subtitle: "実況音声からキーワードを検出します。",
                    systemImage: "waveform",
                    status: model.speechStatus
                ) {
                    Task { await model.handleSpeechSetupAction() }
                }
                Divider().padding(.leading, 44)
                permissionRow(
                    title: "画面収録",
                    subtitle: "システム音声をキャプチャします。",
                    systemImage: "rectangle.dashed",
                    status: model.screenCaptureStatus
                ) {
                    Task { await model.handleScreenCaptureSetupAction() }
                }
                Divider().padding(.leading, 44)
                permissionRow(
                    title: "通知",
                    subtitle: "キーワード検出時に通知を送ります。",
                    systemImage: "bell.fill",
                    status: model.notificationStatus
                ) {
                    Task { await model.handleNotificationSetupAction() }
                }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }

            Spacer()
        }
        .padding(.horizontal, 32)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshSetupStatus() }
        }
    }

    private func permissionRow(title: String, subtitle: String, systemImage: String, status: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status == "許可" {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("許可する", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Browser Extension

    private var browserExtensionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Safari 拡張を有効化")
                .font(.title2.bold())

            Text("s17o は Safari 拡張が有効でないと動作しません。Safari の「設定」→「機能拡張」で s17o にチェックを入れてください。")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox {
                HStack {
                    if model.isBrowserExtensionReady {
                        Label("有効", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("未有効", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(4)
            }

            Button("Safari の機能拡張設定を開く") {
                model.openBrowserControlPreferences()
            }
            .buttonStyle(.borderedProminent)

            if !model.isBrowserExtensionReady {
                Label("Safari 拡張が有効になると完了できます。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshBrowserControlStateAndWait() }
        }
        .task {
            while !Task.isCancelled && !model.isBrowserExtensionReady {
                try? await Task.sleep(for: .seconds(2))
                await model.refreshBrowserControlStateAndWait()
            }
        }
    }

    // MARK: - Safari JavaScript

    private var safariJavaScriptStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Safari の JavaScript 許可")
                .font(.title2.bold())

            Text("「広告中はミュート」と「英語実況をミュート」に必要な設定です。")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Safari 設定（⌘,）を開く", systemImage: "1.circle.fill")
                    Label("「デベロッパ」タブを選択", systemImage: "2.circle.fill")
                    Label("「オートメーション」→「Apple Event からの JavaScript を許可」をチェック", systemImage: "3.circle.fill")
                }
                .font(.callout)
                .padding(4)
            }

            Button("Safari を開く") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Safari.app"))
            }
            .buttonStyle(.borderedProminent)

            Text("設定後、「初期設定を完了」を押してください。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Navigation

    private var isLastStep: Bool {
        if needsSafariJavaScript {
            return step == .safariJavaScript
        } else {
            return step == .browserExtension
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .welcome:           return true
        case .keywords:          return !keywordsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .audio:             return true
        case .permissions:       return model.isMonitoringSetupReady
        case .browserExtension:  return model.isBrowserExtensionReady
        case .safariJavaScript:  return true
        }
    }

    private func nextStep() {
        if step == .keywords { model.keywordsText = keywordsInput }
        // browserExtension の次: safariJavaScript が必要なら移動、不要なら完了
        if step == .browserExtension && !needsSafariJavaScript {
            completeSetup()
            return
        }
        if let next = Step(rawValue: step.rawValue + 1) {
            withAnimation { step = next }
        }
    }

    private func prevStep() {
        // safariJavaScript から戻るとき: needsSafariJavaScript なので browserExtension へ
        if let prev = Step(rawValue: step.rawValue - 1) {
            withAnimation { step = prev }
        }
    }

    private var navigationButtons: some View {
        HStack {
            if step != .welcome {
                Button("戻る") { prevStep() }
            }
            Spacer()
            if isLastStep {
                Button("初期設定を完了") { completeSetup() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
            } else {
                Button("次へ") { nextStep() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance && step == .permissions)
            }
        }
    }

    // MARK: - Complete

    private func completeSetup() {
        model.keywordsText = keywordsInput
        model.completeSetup()
    }
}
