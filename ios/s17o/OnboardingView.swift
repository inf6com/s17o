import SwiftUI

// ---------------------------------------------------------------------------
// OnboardingView — 初回起動時の初期設定導線
// ---------------------------------------------------------------------------

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var step: Step = .welcome
    @State private var keywordsInput: String = ""
    @State private var urlInput: String = ""

    enum Step: Int, CaseIterable {
        case welcome
        case keywords
        case url
        case confirm
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 24)
                .padding(.bottom, 16)

            Group {
                switch step {
                case .welcome:
                    welcomeStep
                case .keywords:
                    keywordsStep
                case .url:
                    urlStep
                case .confirm:
                    confirmStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            navigationButtons
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            keywordsInput = model.keywordsText
            urlInput = model.automationURLText
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
                .font(.system(size: 64))
                .foregroundStyle(.accent)

            Text("s17o へようこそ")
                .font(.title.bold())

            Text("ライブ動画の進行状態を把握し、\n重要イベントを自動検出するアプリです。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Text("まず、いくつかの初期設定を行います。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Keywords

    private var keywordsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("キーワードを設定")
                .font(.title2.bold())
                .padding(.horizontal, 24)

            Text("検出したい選手名やイベント名を、1 行に 1 つ入力してください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            TextEditor(text: $keywordsInput)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(minHeight: 140)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 24)

            if keywordsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("最低 1 つのキーワードが必要です。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - URL

    private var urlStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("カレンダー URL（任意）")
                .font(.title2.bold())
                .padding(.horizontal, 24)

            Text("試合スケジュールを取得するカレンダー URL を入力できます。後から設定画面で変更できます。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            TextField("https://www.mlb.com/schedule", text: $urlInput)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.callout)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 24)

            Text("空欄にすると、カレンダー連携なしで利用できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Confirm

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("設定の確認")
                .font(.title2.bold())
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 12) {
                confirmRow(title: "キーワード", value: formattedKeywords)
                confirmRow(title: "カレンダー URL", value: urlInput.isEmpty ? "（なし）" : urlInput)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 24)

            Text("設定は後から設定画面でいつでも変更できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            Spacer()
        }
        .padding(.top, 8)
    }

    private func confirmRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(4)
        }
    }

    private var formattedKeywords: String {
        keywordsInput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // MARK: - Navigation Buttons

    private var canAdvance: Bool {
        switch step {
        case .welcome:
            return true
        case .keywords:
            return !keywordsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .url:
            return true
        case .confirm:
            return true
        }
    }

    private var navigationButtons: some View {
        HStack {
            if step != .welcome {
                Button("戻る") {
                    withAnimation {
                        step = Step(rawValue: step.rawValue - 1) ?? .welcome
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if step == .confirm {
                Button("はじめる") {
                    completeSetup()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("次へ") {
                    withAnimation {
                        step = Step(rawValue: step.rawValue + 1) ?? .confirm
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
            }
        }
    }

    // MARK: - Complete

    private func completeSetup() {
        model.keywordsText = keywordsInput
        model.automationURLText = urlInput
        model.completeSetup()
    }
}
