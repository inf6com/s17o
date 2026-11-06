import Foundation

// MARK: - MonitoringPipelineState

/// 音声監視パイプラインの状態機械。
/// isRunning: Bool の代わりにこの型で遷移を管理する。
///
/// 遷移:
///   idle → starting → running ↔ (stopping → idle)
///                   ↘ failed
enum MonitoringPipelineState: Equatable {
    case idle                  // 未起動
    case starting              // 起動処理中
    case running               // 動作中
    case stopping              // 停止処理中
    case failed(String)        // 失敗（メッセージ付き）

    var isActive: Bool {
        self == .running || self == .starting
    }

    var canStart: Bool {
        self == .idle || {
            if case .failed = self { return true }
            return false
        }()
    }

    static func == (lhs: MonitoringPipelineState, rhs: MonitoringPipelineState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.starting, .starting), (.running, .running), (.stopping, .stopping):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

enum SetupPermissionState: Equatable {
    case unknown
    case notRequested
    case granted
    case denied
    case restricted
    case unavailable
    case unsupported
    case disabled
    case restartRequired

    var label: String {
        switch self {
        case .unknown:
            return "未確認"
        case .notRequested:
            return "未要求"
        case .granted:
            return "許可"
        case .denied:
            return "拒否"
        case .restricted:
            return "制限"
        case .unavailable:
            return "利用不可"
        case .unsupported:
            return "非対応"
        case .disabled:
            return "無効"
        case .restartRequired:
            return "再起動待ち"
        }
    }

    var isGranted: Bool {
        self == .granted
    }
}

enum BrowserExtensionState: Equatable {
    case unknown
    case checking
    case enabled
    case disabled
    case notDetected
    case failed
    case browserNotRunning

    var label: String {
        switch self {
        case .unknown:
            return "未確認"
        case .checking:
            return "確認待ち"
        case .enabled:
            return "有効"
        case .disabled:
            return "無効"
        case .notDetected:
            return "未検出"
        case .failed:
            return "確認失敗"
        case .browserNotRunning:
            return "Safari 未起動"
        }
    }

    var isEnabled: Bool {
        self == .enabled
    }
}

enum MonitoringReadiness: Equatable {
    case running
    case restartRequired
    case setupRequired
    case browserExtensionRequired(BrowserExtensionState)
    case browserTargetRequired
    case ready

    var statusMessage: String {
        switch self {
        case .running:
            return "動作中"
        case .restartRequired:
            return "再起動待ち"
        case .setupRequired:
            return "初期設定待ち"
        case .browserTargetRequired:
            return "対象タブ未選択"
        case .ready:
            return "準備完了"
        case .browserExtensionRequired(let state):
            switch state {
            case .disabled:
                return "Safari拡張待ち"
            case .unknown:
                return "ブラウザ確認待ち"
            default:
                return "ブラウザ設定確認待ち"
            }
        }
    }
}
