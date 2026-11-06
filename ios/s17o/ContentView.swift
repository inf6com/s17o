import SwiftUI

// ---------------------------------------------------------------------------
// ContentView — メインレイアウト
// ---------------------------------------------------------------------------

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var browser: BrowserController
    @State private var showSettings = false
    @State private var urlInput = ""

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                if geo.size.width > 700 {
                    // iPad: ブラウザ左, パネル右
                    HStack(spacing: 0) {
                        BrowserView(controller: browser)
                        Divider()
                        MonitorPanel()
                            .frame(width: 320)
                    }
                } else {
                    // iPhone: 上下分割
                    VStack(spacing: 0) {
                        BrowserView(controller: browser)
                            .frame(height: geo.size.height * 0.55)
                        Divider()
                        MonitorPanel()
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("s17o")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    BrowserNavBar()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
                .environmentObject(browser)
        }
        .onAppear {
            urlInput = model.pageURL
        }
    }
}

// ---------------------------------------------------------------------------
// BrowserNavBar — URL 入力 + 前後 + リロード
// ---------------------------------------------------------------------------

private struct BrowserNavBar: View {
    @EnvironmentObject var browser: BrowserController
    @State private var urlInput = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!browser.canGoBack)

            Button { browser.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!browser.canGoForward)

            TextField("URL", text: $urlInput)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color(.secondarySystemFill))
                .cornerRadius(6)
                .frame(maxWidth: 200)
                .onSubmit {
                    var raw = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !raw.hasPrefix("http://"), !raw.hasPrefix("https://") { raw = "https://" + raw }
                    if let url = URL(string: raw) { browser.navigate(to: url) }
                    focused = false
                }
                .onChange(of: browser.pageURL) { _, newURL in
                    if !focused { urlInput = newURL }
                }

            if browser.isLoading {
                Button { browser.reload() } label: {
                    Image(systemName: "xmark")
                }
            } else {
                Button { browser.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MonitorPanel — 状態表示 + 操作
// ---------------------------------------------------------------------------

private struct MonitorPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                StatusGrid()
                Divider()
                ControlRow()
                if !model.lastError.isEmpty {
                    Text(model.lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                if !model.recentMatches.isEmpty {
                    MatchList()
                }
            }
            .padding(.vertical, 10)
        }
    }
}

// ---------------------------------------------------------------------------
// StatusGrid — ステータスブロック
// ---------------------------------------------------------------------------

private struct StatusGrid: View {
    @EnvironmentObject var model: AppModel

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            StatusBlock(title: "状態",          value: model.statusMessage)
            StatusBlock(title: "プロファイル",   value: model.activeProfileLabel)
            StatusBlock(title: "野球文脈",       value: model.baseballSummary)
            StatusBlock(title: "音声制御",       value: model.soundAutomationStatus)
            StatusBlock(title: "DOM 更新",       value: model.lastDOMUpdate)
            StatusBlock(title: "自動化",         value: model.automationStatus)
        }
        .padding(.horizontal)
    }
}

private struct StatusBlock: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(8)
    }
}

// ---------------------------------------------------------------------------
// ControlRow — 開始/停止ボタン
// ---------------------------------------------------------------------------

private struct ControlRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if model.isRunning {
                Button(role: .destructive) {
                    Task { await model.stopMonitoring() }
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await model.startMonitoring() }
                } label: {
                    Label("Start Watching", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                Task { await model.runAutomationNow() }
            } label: {
                Label("今すぐ実行", systemImage: "bolt")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
    }
}

// ---------------------------------------------------------------------------
// MatchList — 一致履歴
// ---------------------------------------------------------------------------

private struct MatchList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("一致履歴")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            ForEach(model.recentMatches.prefix(10)) { match in
                HStack(alignment: .top, spacing: 6) {
                    Text(match.timestampLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(match.keyword)
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text(match.details)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
