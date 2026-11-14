import Foundation

/// 播放页的纯规则（预取下一集、进度落盘节流、换集时预取是否还能用），
/// 由 PlaybackSession 调用；抽出来是为了在 Mac 上单测。
enum PlaybackRules {
    /// 前台播放无进度多久视为卡顿（含一直停在 0 秒的起播失败）。
    static let stallTimeoutSeconds: TimeInterval = 20
    /// 同一轮连续故障最多恢复三次，避免无限换线 / 解析请求。
    static let maxRecoveryAttempts = 3

    static func canRecover(attempts: Int) -> Bool {
        attempts >= 0 && attempts < maxRecoveryAttempts
    }

    /// 距本集结束还剩多少秒时开始预取下一集。
    static let prefetchLeadSeconds = 10.0
    /// 进度落盘间隔（秒），与 Dart 侧一致。
    static let saveIntervalSeconds = 5.0

    /// 还剩 10 秒（且大于 0）时返回要预取的下一集下标；最后一集、已预取过或正在预取时为 nil。
    static func prefetchIndex(
        position: Double,
        duration: Double,
        currentIndex: Int,
        episodeCount: Int,
        prefetchedIndex: Int?,
        prefetchInFlight: Bool
    ) -> Int? {
        let remaining = duration - position
        guard remaining <= prefetchLeadSeconds, remaining > 0 else { return nil }
        let nextIndex = currentIndex + 1
        guard nextIndex < episodeCount else { return nil }
        guard prefetchedIndex != nextIndex, !prefetchInFlight else { return nil }
        return nextIndex
    }

    /// 与上次落盘的位置相差至少 5 秒才再存一次。
    static func shouldSaveProgress(position: Double, lastSaved: Double) -> Bool {
        abs(position - lastSaved) >= saveIntervalSeconds
    }

    /// 是否关掉系统空闲计时器（不让屏保出现）：有播放器、正在播放、且这个播放器允许。
    /// 推荐页 hero 不允许（owner 2026-11-08：屏保按电视的设置照常出现，出现时 hero 随之暂停）。
    static func disablesIdleTimer(hasPlayer: Bool, paused: Bool, keepsScreenAwake: Bool) -> Bool {
        keepsScreenAwake && hasPlayer && !paused
    }

    /// 换到 target 集时，预取若是为它或它的下一集准备的就留着，否则释放。
    static func keepsPrefetch(prefetchedIndex: Int?, target: Int) -> Bool {
        prefetchedIndex == target || prefetchedIndex == target + 1
    }
}


/// 独立于 mpv 的纯状态机；后台 / 暂停期间不累计卡顿时间。
/// 只记录进度与时间，不持有播放器或网络资源，便于 Swift 单元测试。
struct PlaybackWatchdog {
    private var lastPosition: Double?
    private var lastAdvanceAt: Date?

    mutating func reset() {
        lastPosition = nil
        lastAdvanceAt = nil
    }

    mutating func observe(position: Double, paused: Bool, foreground: Bool, now: Date) -> Bool {
        guard foreground, !paused, position.isFinite, position >= 0 else {
            reset()
            return false
        }
        guard let previous = lastPosition, let since = lastAdvanceAt else {
            lastPosition = position
            lastAdvanceAt = now
            return false
        }
        // 正常推进及拖动跳转都视为进度变化；避免因快退触发假卡顿。
        if abs(position - previous) > 0.15 || now < since {
            lastPosition = position
            lastAdvanceAt = now
            return false
        }
        guard now.timeIntervalSince(since) >= PlaybackRules.stallTimeoutSeconds else { return false }
        // 防抖：回调触发之后也至少隔一个完整超时周期才能再次触发。
        lastAdvanceAt = now
        return true
    }
}
