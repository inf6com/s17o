# s17o Windows 版 セットアップ手順

## 前提

**Windows 環境が必要です。** macOS・Linux ではビルドできません。

- Windows 10 22H2 以降、または Windows 11
- アーキテクチャ: x64 または ARM64

---

## 1. 必要ソフトウェアのインストール

### 1-1. .NET 8 SDK

https://dotnet.microsoft.com/download/dotnet/8.0

- 「SDK」(Runtime ではなく SDK) をダウンロードしてインストール
- インストール後、コマンドプロンプトで確認:

```
dotnet --version
```

`8.x.x` と表示されれば OK

---

### 1-2. Visual Studio 2022

https://visualstudio.microsoft.com/downloads/

Community（無料）で構いません。

インストール時に以下のワークロードを選択してください:

| ワークロード | 必須理由 |
|---|---|
| .NET デスクトップ開発 | WPF アプリのビルドに必要 |
| ユニバーサル Windows プラットフォーム開発 | WinRT API（Toast 通知）に必要 |

---

### 1-3. Microsoft Edge（Dev チャンネル）

on-device AI（`window.ai` / Prompt API）を使用するため、通常版の Edge ではなく
**Dev チャンネル以降**が必要です。

https://www.microsoft.com/edge/download/insider

「Dev チャンネル」または「Canary チャンネル」をインストールしてください。

#### window.ai の有効化手順

1. Edge Dev を起動
2. アドレスバーに `edge://flags/#prompt-api-for-gemini-nano` と入力
3. フラグを **Enabled** に変更
4. Edge を再起動
5. アドレスバーに `edge://components` と入力
6. 「**Optimization Guide On Device Model**」を探し、「アップデートを確認」をクリック
7. モデルのダウンロードが完了するまで待つ（数分〜数十分、ファイルサイズ大）
8. アドレスバーに `edge://on-device-internals` と入力し、モデルの状態が `READY` であることを確認

> **ハードウェア要件**: RAM 16GB 以上を推奨。モデルのダウンロードにディスク空き容量 約 4GB 必要。

---

### 1-4. WebView2 Runtime

WebView2 は通常 Edge と一緒にインストールされています。
未インストールの場合:

https://developer.microsoft.com/microsoft-edge/webview2/

「Evergreen Bootstrapper」をダウンロードして実行してください。

---

## 2. Azure DevOps への SSH 接続

### 2-1. SSH キーを生成

コマンドプロンプトまたは PowerShell で実行:

```
ssh-keygen -t ed25519 -C "s17o-windows"
```

- 保存先: そのまま Enter（`C:\Users\ユーザー名\.ssh\id_ed25519`）
- パスフレーズ: 任意（空でも可）

### 2-2. 公開鍵を表示してコピー

```
type %USERPROFILE%\.ssh\id_ed25519.pub
```

表示された内容（`ssh-ed25519 AAAA...` で始まる 1 行）を全部コピーします。

### 2-3. Azure DevOps に公開鍵を登録

1. ブラウザで `https://dev.azure.com/s17o` を開く
2. 右上のユーザーアイコン → **Security** → **SSH public keys**
3. **+ New Key** をクリック
4. Name: `windows-dev`（任意）
5. Key Data: コピーした公開鍵を貼り付け
6. **Save**

### 2-4. 接続確認

```
ssh -T git@ssh.dev.azure.com
```

`remote: Shell access is not supported.` と表示されれば**接続成功**です。

---

## 3. リポジトリのクローン

```
git clone git@ssh.dev.azure.com:v3/s17o/s17o.com/s17o.com
cd s17o.com
```

---

## 4. git hook の有効化

`S17O_SPEC.md` を変更してコミットすると、Claude Code が自動でコードを更新します。
以下を **1 回だけ** 実行してください:

```
git config core.hooksPath .githooks
```

> hook を動作させるには Claude Code CLI と `ANTHROPIC_API_KEY` 環境変数の設定が必要です。
> 設定しない場合でも、ビルドと実行には影響しません。

---

## 5. プロジェクトを開く

Visual Studio 2022 でリポジトリルートにある以下のファイルを開いてください:

```
s17o.sln
```

`File → Open → Project/Solution` でも、エクスプローラーからダブルクリックでも開けます。

---

## 6. NuGet パッケージの復元

Visual Studio が自動で復元します。
手動で実行する場合:

```
dotnet restore windows/s17o/s17o.csproj
```

使用しているパッケージ:

| パッケージ | 用途 |
|---|---|
| Microsoft.Web.WebView2 (1.0.2739.15) | WebView2 内蔵ブラウザ |
| NAudio (2.2.1) | WASAPI ループバック音声キャプチャ |
| Microsoft.Windows.SDK.Contracts (10.0.22621.2) | WinRT API（Toast 通知など） |

---

## 7. ビルドと実行

```
dotnet build windows/s17o/s17o.csproj -c Release
dotnet run --project windows/s17o/s17o.csproj
```

または Visual Studio 2022 の **F5**（デバッグ実行）/ **Ctrl+F5**（通常実行）。

---

## 8. アプリの設定項目

起動後、画面右上の Settings ボタンから設定できます。

| 設定項目 | 説明 |
|---|---|
| Keywords | 検出したい選手名など（1行1キーワード） |
| カレンダー / ターゲット URL | `mlb.com/schedule` など AI に読ませるページの URL |
| 開始日時 | 自動化を起動する日時 |
| 指定時刻にブラウザを開く | ON にすると指定時刻に URL を自動オープン |
| Start Watching at scheduled time | ON にすると指定時刻に Start Watching |
| キーワード一致時に音声を自動 ON | ON にすると打者・投手一致でミュート解除 |
| キーワード一致時に前面表示 | ON にするとキーワード一致でブラウザを前面に出す |

---

## 9. 追加プロファイルの配置（任意）

プリセット以外のプロファイル定義（JSON）を追加したい場合:

```
%APPDATA%\s17o\profiles\*.json
```

に配置してください。起動時に自動で読み込まれます。

---

## 10. アイコンについて

アイコン（`windows/s17o/Resources/icon.ico`）は macOS の
`s17o/Assets.xcassets/AppIcon.appiconset/icon_256x256.png` と共通のソースから生成されています。

アイコンを変更する場合は macOS 側の PNG を更新し、以下を実行してください:

```
pip install pillow
python3 tools/gen_icon.py
```

---

## 11. トラブルシューティング

| 症状 | 確認箇所 |
|---|---|
| `window.ai` が利用不可と表示される | Edge Dev チャンネルか確認。`edge://on-device-internals` でモデル状態が `READY` か確認 |
| WebView2 初期化エラー | WebView2 Runtime がインストールされているか確認 |
| ビルドエラー（WinRT 型が見つからない） | Visual Studio の「UWP 開発」ワークロードを追加インストール |
| 音声キャプチャが動作しない | 「サウンドの設定 → 音量ミキサー」でアプリの音声出力デバイスを確認 |
| Toast 通知が表示されない | 「設定 → 通知 → アプリごとの通知」で s17o を許可 |
| SSH 接続失敗 | `ssh -T git@ssh.dev.azure.com` で確認。公開鍵が Azure DevOps に登録されているか確認 |

---

## 12. ファイル構成（参考）

```
s17o.sln                        ソリューションファイル（ルート）
windows/
├── SETUP.md                    この手順書
└── s17o/
    ├── s17o.csproj             プロジェクト定義（.NET 8 / WPF）
    ├── App.xaml / .cs          エントリポイント・システムトレイ常駐
    ├── MainWindow.xaml / .cs   メイン画面
    ├── SettingsWindow.xaml / .cs 設定ウィンドウ
    ├── AppModel.cs             状態管理・自動化ロジック
    ├── ProfileEngine.cs        window.ai によるプロファイル判定
    ├── BrowserController.cs    WebView2 + JS injection
    ├── AudioCapture.cs         WASAPI ループバック
    ├── KeywordRecognizer.cs    音声キーワード認識
    ├── Resources/
    │   └── icon.ico            アプリアイコン（macOS PNG から生成）
    └── Properties/
        └── Settings.cs         ユーザー設定の永続化
tools/
└── gen_icon.py                 icon.ico 再生成スクリプト
```
