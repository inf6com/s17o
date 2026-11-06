import SwiftUI

// ---------------------------------------------------------------------------
// SettingsView — 設定シート
// ---------------------------------------------------------------------------

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var browser: BrowserController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                keywordsSection
                automationSection
                statusSection
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // キーワード
    // -----------------------------------------------------------------------

    private var keywordsSection: some View {
        Section {
            TextEditor(text: $model.keywordsText)
                .font(.body)
                .frame(minHeight: 80)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("Keywords (one per line)")
        } footer: {
            Text("選手名など、DOM から検出するキーワードを入力します。")
        }
    }

    // -----------------------------------------------------------------------
    // 自動化
    // -----------------------------------------------------------------------

    private var automationSection: some View {
        Section("自動化") {
            VStack(alignment: .leading, spacing: 4) {
                Text("カレンダー / ターゲット URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://www.mlb.com/schedule", text: $model.automationURLText)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.callout)
            }
            .padding(.vertical, 2)

            DatePicker(
                "開始日時",
                selection: $model.automationStartDate,
                displayedComponents: [.date, .hourAndMinute]
            )

            Toggle("指定時刻にページを開く", isOn: $model.autoOpenTargetPage)
            Toggle("Start Watching at scheduled time", isOn: $model.autoStartMonitoringAtSchedule)
            Toggle("キーワード一致時に音声を自動 ON", isOn: $model.autoSoundControlEnabled)
            Toggle("キーワード一致時に前面表示", isOn: $model.autoBringToFrontEnabled)

            HStack(spacing: 12) {
                Button("今すぐ URL を開く") {
                    model.openConfiguredTargetPageNow()
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("今すぐ自動実行") {
                    Task { await model.runAutomationNow() }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)

            LabeledContent("自動化状態", value: model.automationStatus)
                .font(.callout)
            LabeledContent("カレンダー", value: model.calendarStatus)
                .font(.callout)
        }
    }

    // -----------------------------------------------------------------------
    // 状態
    // -----------------------------------------------------------------------

    private var statusSection: some View {
        Section("状態") {
            LabeledContent("AI エンジン",     value: model.aiEngineStatus)
            LabeledContent("プロファイル",     value: model.activeProfileLabel)
            LabeledContent("選択理由",         value: model.profileReason)
            LabeledContent("野球文脈",         value: model.baseballSummary)
            LabeledContent("音声制御",         value: model.soundAutomationStatus)
            LabeledContent("DOM 更新",         value: model.lastDOMUpdate)
            LabeledContent("ページタイトル",   value: model.pageTitle.isEmpty ? "—" : model.pageTitle)
            LabeledContent("ページ URL",       value: model.pageURL.isEmpty ? "—" : model.pageURL)
                .lineLimit(1)
            if !model.lastError.isEmpty {
                LabeledContent("エラー", value: model.lastError)
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
    }
}
