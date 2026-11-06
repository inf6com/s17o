# s17o Specification

## Document Rule
- 仕様 md はこの 1 ファイルだけです。
- このファイルが最新要件です。
- 要件に反する案は不採用です。

## Product Shape
- s17o は野球専用アプリではありません。
- s17o はライブ動画 Watch の汎用本体です。
- 振る舞いは profile extension で拡張します。
- `baseball` は profile extension の 1 つです。

## Purpose
- 目的は、ライブ動画の進行状態を把握することです。
- 目的は、profile ごとの重要イベントを検出することです。
- 目的は、イベントに応じて音声と前面表示を自動制御することです。
- 目的は、配信が異常状態に入ったことを検出することです。
- 目的は、実況と CM を落とし、球場音を残すことです。
- 映像はそのまま保持し、音だけを処理します。

## Absolute Rule
- スクレイピングは行いません。
- クロールは行いません。
- 外部サーバーへ直接取得する headless fetch / crawl / scrape は不採用です。
- ローカルで実際に表示中の DOM は full control 対象です。
- ユーザーが実際に開いているページだけを対象にします。
- 部分的にしか満たせない案は不採用です。

## Profile System
- profile は extension 単位です。
- active profile の選択は model が行います。
- profile 切替の入力は、表示中動画の文脈とローカル DOM です。
- profile ごとに固定 schema を持ちます。
- 状態抽出の出力 schema は profile 別に決まります。
- 本体は profile 非依存の状態遷移基盤を持ちます。
- 本体は `selected_profile` と `profile_payload` を受け取り、選ばれた profile の schema だけを検証します。
- profile は状態抽出規則・重要イベント・アクション条件を定義します。
- profile は preset profiles と追加 profile に分かれます。
- preset profiles は本体に同梱します。
- 後から profile を追加可能にします。
- preset profile 名は `baseball`, `soccer`, `american_football`, `music_concert`, `creator_stream` とします。

## Baseball Profile Extension
- `baseball` profile は MLB.TV と `mlb.com` カレンダーを対象にします。
- 再生は MLB.TV を前提にします。
- スケジュール取得元は `mlb.com` のカレンダーです。
- カレンダー URL はユーザーが設定します。
- 対象 URL はユーザー自身が開きます。
- 開かれたローカル DOM と動画文脈から、試合進行を判定します。
- 開始時刻は日本時間へ変換します。
- 指定時刻に watch を開始します。
- 大谷の出番予想タイミングで、ユーザー設定が ON なら sound を ON にします。
- 大谷の出番予想タイミングで、ユーザー設定が ON なら MLB.TV を前面へ出します。

## Baseball Signals
- `inning` の変化を検出します。
- `top / bottom` の変化を検出します。
- `current batter` `next batter` `previous batter` を検出します。
- `pitcher` を検出します。
- `baseRunners: [String]` — 塁上にいるランナーの名前一覧を検出します。
- これらの変化から、打席・回の遷移・登板・進塁を判断します。
- 対象プレーヤーが baseRunners に含まれる間は、打席と同じ「unmute」ポリシーを適用します。

## DOM Interpretation Policy
- local DOM は full control 対象ですが、解釈ロジックを個別サイトごとに増殖させません。
- DOM からの意味抽出は model に委ねます。
- profile ごとに許可される出力 schema だけを固定します。
- 本体は schema の差分だけを扱います。
- サイト構造変更時は selector の追加ではなく model 判定の見直しを優先します。

## MLB.TV Watchdog
- MLB.TV の再生状態を Watch します。
- 広告状態が長時間継続し、中継復帰が起きない場合は異常とみなします。
- 試合進行 DOM が更新されているのに再生側が広告状態のままなら、異常候補として通知します。
- 試合進行 DOM も再生 DOM も止まっている場合は、ネットワークまたはページ停止として扱います。

## AI
- AI は補助用途ではなく、profile 判定と状態抽出の中核です。
- AI はまず active profile を決めます。
- AI は次に、選ばれた profile の固定 schema で状態を抽出します。
- profile 選択と状態抽出は同一 model でも別 model でも構いません。
- サービス固有 DOM に対する手続き型ロジックは増やしません。
- DOM 構造の変化に依存する個別 selector ロジックは本体へ埋め込みません。
- local logic は取得・時刻管理・差分管理・アクション実行に限定します。
- 意味判定は model first で行います。
- API は使いません。
- API key は使いません。
- on-device AI（Foundation Models / Core ML）を使います。外部サーバーへの推論リクエストは行いません。

## Audio Core
- s17o の中核は音声 AI です。macOS 専用機能です。
- local DOM は進行状況と profile 判定の入力として使います。
- 音声系の目的は `commentary`, `commercial`, `ballpark ambience` を区別することです。
- 現在の実装はシーン分類（commentary / ballpark / commercial / silence / mixed）と全体ミュートです。
- commentary だけを落として ballpark ambience を残す source separation は未実装です。
- 映像ストリームは変更しません。
- on-device 推論を前提にし、ANE / Core ML / SoundAnalysis を優先します。
- 学習・実測用の音声サンプルを `~/Library/Application Support/s17o/audio-samples/` に保存します。

### Audio Format Contract
- フォーマット仕様は `AudioFormatContract` enum に一元定義します。サイト・ファイル横断での散在を禁じます。
- `capture`: 48kHz / 2ch / Float32 — ScreenCaptureKit 生 PCM
- `analysis`: 48kHz / 2ch / Float32 — `AudioInferenceEngine` へ渡す分析用
- `speech`: 16kHz / 1ch / Float32 — `KeywordRecognizer`（SFSpeech）へ渡す音声認識用

### Dual Detection Channels
- キーワード検出は **PCM チャンネル**（音声認識）と **CC テキストチャンネル**（字幕）の 2 系統で行います。
- `ClosedCaptionSegment { text, capturedAt, source }` — 字幕テキストのデータ型。`AudioFormatContract.swift` に同居させます。
- CC テキストは `KeywordRecognizer.append(caption:onMatch:)` で同一の `detectKeyword` ロジックを通過します。
- ブラウザ拡張側の CC 抽出実装は未完了です（インフラのみ確立済み）。

### System Volume Control
- ScreenCaptureKit はシステム音量適用前の PCM を取得します。
- ミュートは `el.muted` または WebKit メディア制御ではなく、AppleScript `set volume output volume 0` で行います。
- これにより、スピーカーへの出力を止めながら音声認識・推論キャプチャを継続できます。
- 復元時は保存済み音量値を使って `set volume output volume N` で戻します。

## Initial Setup Flow
- 初回起動時は Start Watching や自動ナビゲーションを一切行いません。
- 初回起動時はオンボーディング画面を表示し、最低限の初期設定を完了させます。
- 初期設定が完了するまでメイン UI は表示しません。
- 初期設定の完了状態は `UserDefaults` の `s17o.setupComplete` で管理します。
- 2 回目以降の起動では、初期設定済みならメイン UI を直接表示します。
- 設定をリセットした場合は再度オンボーディングを表示します。

### Setup Steps (順序)
1. ようこそ画面（アプリの説明）
2. キーワード入力（1 行 1 キーワード、空欄不可）
3. 対象 URL 入力（カレンダー URL、任意）
4. 確認画面（入力内容の一覧と「Start」ボタン）

### Platform Notes
- macOS: `AppDelegate` のウィンドウ表示前にオンボーディング完了を確認します。
- 権限（画面収録・音声認識・通知）は Start Watching 時に都度確認するため、オンボーディングでは求めません。

## UI Labels
- 操作状態のラベルは英語とします。
- 開始ボタン: **Start Watching**
- 停止ボタン: **Stop**
- 実行中ステータス: **Watching**
- 停止中ステータス: **Idle**
- 「監視」という語はUI・コード・ドキュメントのいずれにも使用しません。

## Shared Assets
- アイコンのソースは `s17o/Assets.xcassets/AppIcon.appiconset/` の PNG です。
- Windows 用 `.ico` は同 PNG から生成します。生成スクリプトは `tools/gen_icon.py` に置きます。
- アイコンを変更する場合は macOS の PNG を更新し、Windows 用を再生成します。

## State Management & Orchestration

### MonitoringPipelineState
- `isRunning: Bool` は廃止し、`MonitoringPipelineState` 型ステートマシンに置き換えます。
- 状態: `idle → starting → running ↔ stopping → idle` と `failed(String)`
- `isActive`: `.running` または `.starting` のとき true
- `canStart`: `.idle` または `.failed` のとき true
- 定義ファイル: `AppControlState.swift`

### SoundPolicy
- ミュート判定は `SoundPolicy.evaluate(config:at:)` を唯一の決定源とします。
- 優先順位（高い順）: `keywordDOM > keywordAudio > commercial > commentary > waiting > manual`
- `keywordAudio` は検出後 90 秒間有効なウィンドウ（`keywordAudioWindow`）で保持します。
- すべての音声/DOM イベントは SoundPolicy の入力フラグを更新してから `applySoundPolicy()` を呼びます。
- 複数フラグの競合時は上記優先順位が解決します。
- 定義: `AppModel.swift` 内 `struct SoundPolicy`

### AudioPipeline
- `SystemAudioCapture`, `KeywordRecognizer`, `AudioInferenceEngine`, `AudioSampleStore` の生成・接続・破棄を一元管理します。
- `AppModel` から音声配線の責任を分離します。
- `@MainActor final class AudioPipeline` — `start() async throws`, `stop() async`, `append(caption:)`
- コールバック: `onSpeechMatch`, `onTranscript`, `onInference`, `onPipelineStatus`, `onSourceChange`, `onFailure`, `onCaptionMatch`
- 定義ファイル: `AudioPipeline.swift`

## Architecture Decision
- ブラウザ拡張単体案は不採用です。Watch 開始・前面化・音制御・常駐自動化を単体では満たせないためです。
- 本体はネイティブ常駐アプリです（macOS）。
- ブラウザ DOM 制御は Safari App Extension でアプリと協調して行います。
- local DOM full control は Safari App Extension + JavaScript injection で実現します。
- AI 推論はローカルモデル（Foundation Models / Core ML）で行い、アプリ本体が状態遷移とアクション実行を管理します。

## Platform
### macOS
- macOS 版はネイティブ常駐アプリです。
- ブラウザ制御は Safari App Extension で実現します。
- local DOM full control は Safari App Extension + JavaScript injection で実現します。
- on-device AI は Foundation Models (Apple) を使います。Apple Silicon (M 系) + macOS 15.1 以降が必要です。
- Intel Mac は Foundation Models 非対応のため、サポート対象外とします。

### Windows
- Windows 版はネイティブ常駐アプリです。Mac 先行で進めます。
- DOM 制御手段は未決定です。実装時に要件充足を基準に選定します。
- Windows 版は本仕様の現フェーズにおける実装対象ではありません。

## Current Gap

### 実装済み（macOS）
- model による active profile 選択と profile 別 schema 抽出
- preset profiles と追加 profile manifest 読み込み（`~/Library/Application Support/s17o/profiles/*.json`）
- 48kHz stereo capture + on-device 音声分類（`commentary / ballpark / commercial / silence / mixed`）
- scene 安定時の WAV/metadata 保存（`~/Library/Application Support/s17o/audio-samples/`）
- AppleScript によるシステム音量ミュート（ScreenCaptureKit 対応）
- `MonitoringPipelineState` ステートマシン（`AppControlState.swift`）
- `SoundPolicy` 単一判定源（`AppModel.swift`）
- `AudioPipeline` オーケストレーター（`AudioPipeline.swift`）
- `AudioFormatContract` 一元定義（`AudioFormatContract.swift`）
- `ClosedCaptionSegment` インフラ（CC テキストチャンネル基盤）
- `baseRunners: [String]` による塁上在籍中 unmute
- `KeywordRecognizer` に CC テキストチャンネル（`append(caption:onMatch:)`）追加

### 未実装 / 残タスク
- CC テキストチャンネル: Safari 拡張側の字幕 DOM 抽出は未完了（インフラのみ確立）
- source separation: commentary だけを落として ballpark を残す分離は未実装
- AppModel の更なる分解: `MonitoringOrchestrator` / `BrowserOrchestrator` 分離は未着手
- Windows 版: 実装対象外（現フェーズ）

## DevOps Status

- リモートは Azure DevOps (`dev.azure.com/s17o/s17o.com`) に設定済みです。
- パイプラインと hook 自動同期は未設定です。
- `S17O_SPEC.md` の変更は自動でコードへ反映されません。反映は手動実装で行います。

### 変更履歴（主要マイルストーン）
| 日付 | 内容 |
|------|------|
| 2026-04-20 | AudioPipeline / MonitoringPipelineState / SoundPolicy / AudioFormatContract / ClosedCaptionSegment / baseRunners 実装。ビルド成功確認。 |
| 2026-04-18 | onboarding flow, iOS 版骨格, アイコン更新, Windows SETUP 更新 |
| 以前 | 音声分類・プロファイルエンジン・Safari 拡張・AppleScript ミュート初期実装 |
