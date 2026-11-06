import AppKit
import Combine
import SwiftUI

struct MonitoringView: View {
    @ObservedObject var model: AppModel
    @State private var showSettings = false
    @State private var bannerKeyword = ""
    @State private var bannerDetails = ""
    @State private var bannerVisible = false
    @State private var bannerTask: Task<Void, Never>?

    // アイコンと同色
    private let bg = Color(nsColor: NSColor(srgbRed: 0.118, green: 0.294, blue: 0.663, alpha: 1.0))
    private let cardBg = Color.white.opacity(0.12)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                statusRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                ScrollView {
                    VStack(spacing: 12) {
                        keywordSection
                        tabSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.hidden)

                controlBar
            }

            // MARK: - キーワード検出バナー
            if bannerVisible {
                detectionBanner
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .zIndex(10)
            }
        }
        .onReceive(model.$latestDetection.compactMap { $0 }) { event in
            bannerKeyword = event.keyword
            bannerDetails = event.details
            bannerTask?.cancel()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                bannerVisible = true
            }
            bannerTask = Task {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.5)) { bannerVisible = false }
            }
        }
        .frame(width: 460, height: 640)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 30, x: 0, y: 14)
        .padding(14)
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .task {
            await model.refreshSetupStatus()
            model.refreshBrowserControlState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await model.refreshSetupStatus()
                model.refreshBrowserControlState()
                model.retryFailedAudioAutomationsIfNeeded()
            }
        }
        .task(id: "\(model.isBrowserExtensionReady)-\(model.isRunning)") {
            guard model.isBrowserExtensionReady else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, !model.isRunning else { continue }
                model.refreshBrowserControlState()
            }
        }
    }

    // MARK: - Detection Banner

    private var detectionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "baseball.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                Text(bannerKeyword.uppercased())
                    .font(.title.weight(.black))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.3)) { bannerVisible = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            if !bannerDetails.isEmpty {
                Text(bannerDetails)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [Color(nsColor: NSColor(srgbRed: 0.90, green: 0.35, blue: 0.10, alpha: 1)),
                         Color(nsColor: NSColor(srgbRed: 0.75, green: 0.20, blue: 0.05, alpha: 1))],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        ZStack(alignment: .top) {
            Image("LargeIcon")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // ウィンドウコントロール行
            HStack {
                // 最小化（非表示）ボタン
                Button {
                    NSApp.keyWindow?.orderOut(nil)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.85))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                // 設定ボタン
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.callout)
                        .foregroundStyle(bg)
                        .padding(8)
                        .background(.white.opacity(0.92))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
                .overlay {
                    if model.isRunning {
                        Circle()
                            .fill(statusDotColor.opacity(0.4))
                            .frame(width: 16, height: 16)
                    }
                }

            Text(model.statusMessage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))

            Spacer()
        }
    }

    private var statusDotColor: Color {
        if model.isRunning { return .green }
        if model.isMonitoringSetupReady && model.isBrowserExtensionReady { return .white.opacity(0.5) }
        return .orange
    }

    // MARK: - Keywords

    private var keywordSection: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label("キーワード", systemImage: "text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                TextEditor(text: keywordBinding)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80, maxHeight: 120)
                    .padding(10)
                    .background(.white.opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(model.isRunning)

                Text("1 行に 1 キーワードです。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    // MARK: - Tab section

    private var tabSection: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label("対象タブ", systemImage: "safari")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                if model.isBrowserExtensionReady {
                    Picker("", selection: tabBinding) {
                        Text("選択してください").tag(nil as Int?)
                        ForEach(model.browserTabCandidates) { tab in
                            Text(tab.summary).tag(Optional(tab.id))
                        }
                    }
                    .disabled(model.browserTabCandidates.isEmpty || model.isRunning)
                    .labelsHidden()
                } else {
                    Text("Safari 拡張を有効にしてください。")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.startMonitoring() }
            } label: {
                HStack(spacing: 6) {
                    if model.isRunning {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                    }
                    Text(model.isRunning ? "Watching…" : "Start Watching")
                        .font(.headline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(model.isRunning ? .white.opacity(0.15) : .white)
                .foregroundStyle(model.isRunning ? .white : bg)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!model.canStartWatching)
            .opacity(model.canStartWatching || model.isRunning ? 1.0 : 0.35)

            Button {
                Task { await model.stopMonitoring() }
            } label: {
                Text("Stop")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: 100)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.15))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!model.isRunning)
            .opacity(model.isRunning ? 1.0 : 0.35)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.black.opacity(0.20))
    }

    // MARK: - Helpers

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }

    private var keywordBinding: Binding<String> {
        Binding(get: { model.keywordsText }, set: { model.keywordsText = $0 })
    }

    private var tabBinding: Binding<Int?> {
        Binding(get: { model.selectedBrowserTabID }, set: { model.selectBrowserTab($0) })
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keywordsInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("設定")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    settingsSection(title: "キーワード", systemImage: "text.magnifyingglass") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $keywordsInput)
                                .font(.body.monospaced())
                                .frame(minHeight: 100)
                                .padding(8)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                                }
                            Text("1 行に 1 キーワードです。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // 権限
                    settingsSection(title: "アクセス権限", systemImage: "lock.shield") {
                        VStack(spacing: 0) {
                            permissionRow(
                                title: "音声認識",
                                status: model.speechStatus
                            ) { Task { await model.handleSpeechSetupAction() } }
                            Divider().padding(.leading, 14)
                            permissionRow(
                                title: "画面収録",
                                status: model.screenCaptureStatus
                            ) { Task { await model.handleScreenCaptureSetupAction() } }
                            Divider().padding(.leading, 14)
                            permissionRow(
                                title: "通知",
                                status: model.notificationStatus
                            ) { Task { await model.handleNotificationSetupAction() } }
                        }
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        }
                    }

                    Divider()

                    settingsSection(title: "Safari 拡張", systemImage: "safari") {
                        VStack(spacing: 0) {
                            // 拡張の有効状態
                            HStack {
                                if model.isBrowserExtensionReady {
                                    Label("有効", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Label("未有効", systemImage: "xmark.circle")
                                        .foregroundStyle(.red)
                                }
                                Spacer()
                                Button("設定を開く") {
                                    model.openBrowserControlPreferences()
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                            Divider().padding(.leading, 14)

                            // Apple Event JavaScript 許可の案内
                            HStack(spacing: 12) {
                                Image(systemName: "applescript")
                                    .font(.body)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Apple Event の JavaScript 許可")
                                        .font(.callout.weight(.medium))
                                    Text("広告ミュート・英語実況ミュートに必要。Safari 設定 → デベロッパ → オートメーション")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("設定を開く") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Safari.app"))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        }
                    }

                    Divider()

                    settingsSection(title: "音声の自動制御", systemImage: "speaker.wave.2.fill") {
                        VStack(spacing: 0) {
                            audioToggleRow(
                                title: "打席時にミュート解除",
                                status: model.soundAutomationStatus,
                                systemImage: "speaker.wave.2.fill",
                                isOn: $model.autoSoundControlEnabled
                            )
                            Divider().padding(.leading, 44)
                            audioToggleRow(
                                title: "広告中はミュート",
                                status: model.commercialAudioStatus,
                                systemImage: "speaker.slash.fill",
                                isOn: $model.suppressCommercialAudioEnabled
                            )
                            Divider().padding(.leading, 44)
                            audioToggleRow(
                                title: "英語実況をミュート",
                                status: model.commentaryTrackStatus,
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
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                Spacer()
                Button("保存") {
                    model.keywordsText = keywordsInput
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(keywordsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 460, height: 620)
        .onAppear {
            keywordsInput = model.keywordsText
            Task { await model.refreshSetupStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshSetupStatus() }
        }
    }

    private func permissionRow(title: String, status: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if status == "再起動待ち" {
                    Text("許可されました。アプリを再起動してください。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if status == "許可" {
                Label("許可済み", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if status == "再起動待ち" {
                Button("再起動") {
                    NSApplication.shared.relaunch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button("許可する", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func settingsSection<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func audioToggleRow(title: String, status: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusColor(for: status))
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statusColor(for status: String) -> Color {
        switch status {
        case "許可済み", "有効", "英語実況オフ", "ミュート解除中", "球場音":
            return .green
        case _ where status.hasPrefix("英語実況オフ"):
            return .green
        case "CMミュート", "CMミュート維持", "ミュート待機", "英語実況オフ（ミュート）":
            return .orange
        case "失敗", "未許可", "未有効":
            return .red
        case _ where status.hasPrefix("失敗"):
            return .red
        default:
            return .secondary
        }
    }
}
