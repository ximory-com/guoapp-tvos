import Foundation

/// 一次看剧的分集逻辑：起播、换集、播完自动下一集、失败换线路、预取下一集、落盘进度、退出时释放会话。
/// 全屏播放页与推荐页的 hero 共用；控件、焦点、弹窗等界面留在各自的视图里。
/// （从 PlayerView 原样搬来，规则判断见 PlaybackRules。）
@MainActor
final class PlaybackSession: ObservableObject {
    let drama: Drama
    let episodes: [Episode]
    let controller: PlayerController
    private let store: Store

    @Published private(set) var currentIndex: Int
    @Published private(set) var plan: PlaybackPlan?
    /// 出错时停掉句柄：恢复屏保（避免错误页常亮），重试时照常 load() → play()。
    @Published private(set) var error: String? {
        didSet {
            if error != nil { controller.halt() }
        }
    }

    /// 每次落盘进度前调用（参数为播放位置）；推荐页 hero 换成「真正看满 30 秒」的门槛。
    var saveGate: (Double) -> Bool = { _ in true }
    /// 最后一集播完（或关了自动连播）时调用；全屏播放页传 dismiss。
    var onReachedEnd: (() -> Void)?
    /// 是否允许弹幕（再与设置里的开关相与）；推荐页 hero 的小画面不放弹幕。
    var allowsDanmaku = true

    /// 当前播放位置：已出画面时取播放器的进度，否则是本集的起播位置（转到全屏播放时用）。
    var currentPosition: Double {
        controller.progress.duration > 0 ? controller.progress.position : startPosition
    }

    private var startPosition: Double
    private var lastSavedPosition = -1.0
    /// 下一集预取好的播放计划（还剩 10 秒时后台解析好，切集时直接用）。
    private var prefetchedPlan: PlaybackPlan?
    /// 预取针对的分集下标（成功或失败都记录，避免失败后反复重试刷接口）。
    private var prefetchedIndex: Int?
    private var prefetchTask: Task<Void, Never>?
    /// 当前这次换集 / 重试的加载：新的加载开始或停止时取消旧的，
    /// 只让最后一次加载起播（load() 在解析返回后检查取消）。
    private var loadTask: Task<Void, Never>?
    /// 自动恢复独立于一般换集加载：去重、受限次数、取消旧回调。
    private var recoveryTask: Task<Void, Never>?
    private var recoveryGeneration = 0
    private var recoveryAttempts = 0
    /// 最近三条恢复轨迹持久化到 tvOS UserDefaults，杀掉 App 后依然可查看。
    @Published private(set) var recoveryStatus: String = UserDefaults.standard.string(forKey: "playbackRecoveryTrace") ?? "未记录恢复事件"

    private func traceRecovery(_ event: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        var entries = UserDefaults.standard.stringArray(forKey: "playbackRecoveryHistory") ?? []
        entries.append("\(stamp) \(event)")
        entries = Array(entries.suffix(8))
        UserDefaults.standard.set(entries, forKey: "playbackRecoveryHistory")
        recoveryStatus = entries.suffix(6).joined(separator: "\n")
        UserDefaults.standard.set(recoveryStatus, forKey: "playbackRecoveryTrace")
    }
    /// 仅在失败现场探测本地 Go 代理的 HEAD，不传输媒体正文或记录会话 URL。
    private func probeFailedMediaProxy(_ failed: PlaybackPlan?) {
        guard let failed, let url = URL(string: failed.url) else {
            traceRecovery("代理探测：无有效计划")
            return
        }
        let route = "\(failed.routeIndex + 1)/\(failed.routeCount)"
        if failed.expiresAt > 0 {
            let remaining = failed.expiresAt / 1_000 - Int(Date().timeIntervalSince1970)
            traceRecovery("失败线路 #\(route)，凭证剩余 \(remaining)s")
        } else {
            traceRecovery("失败线路 #\(route)，无凭证到期字段")
        }
        guard url.host == "127.0.0.1", url.scheme == "http" else {
            traceRecovery("代理探测：非本地 HTTP 地址")
            return
        }
        Task { [weak self] in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpMethod = "HEAD"
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    self?.traceRecovery("代理 HEAD: 非 HTTP 响应")
                    return
                }
                self?.traceRecovery("代理 HEAD: HTTP \(http.statusCode), route #\(route)")
            } catch {
                let ns = error as NSError
                self?.traceRecovery("代理 HEAD 错误：\(ns.domain) #\(ns.code), route #\(route)")
            }
        }
    }
    private var recoveryStableFrom: Double?
    private var stopped = false

    init(drama: Drama, episodes: [Episode], startIndex: Int, startPosition: Double, store: Store, controller: PlayerController) {
        self.drama = drama
        self.episodes = episodes
        self.store = store
        self.controller = controller
        self.currentIndex = startIndex
        self.startPosition = startPosition
    }

    // MARK: - 偏好（与设置页的 @AppStorage 同键同默认值，调用时读取）

    private var autoAdvance: Bool { Self.preference("autoAdvance", default: true) }
    private var danmakuEnabled: Bool { allowsDanmaku && Self.preference("danmakuEnabled", default: true) }
    private var preferredQuality: Int { Self.preference("preferredQuality", default: 0) }
    private var playbackSpeed: Double { Self.preference("playbackSpeed", default: 1.0) }

    private static func preference<Value>(_ key: String, default fallback: Value) -> Value {
        UserDefaults.standard.object(forKey: key) as? Value ?? fallback
    }

    // MARK: - 起播 / 换集

    func start() {
        stopped = false
        controller.onStall = { [weak self] position in
            self?.recover(position: position)
        }
        startLoad()
    }

    func retry() {
        // 用户明确重试不受自动恢复预算限制；仍必须释放旧媒体会话。
        recoveryAttempts = 0
        recoveryStableFrom = nil
        recover(position: currentPosition, manual: true)
    }

    /// 播放中选集：与详情页点分集一致，从头播放。先存好旧集进度并停掉旧句柄；
    /// 预取若不是为新位置（本集或下一集）准备的，释放掉，避免用到过期地址。
    func playEpisode(at index: Int) {
        guard index != currentIndex, episodes.indices.contains(index) else { return }
        saveProgress()
        cancelRecovery()
        recoveryAttempts = 0
        recoveryStableFrom = nil
        controller.halt()
        if !PlaybackRules.keepsPrefetch(prefetchedIndex: prefetchedIndex, target: index) {
            if let stale = prefetchedPlan {
                Task { try? await CoreClient.shared.release(session: stale.session) }
            }
            prefetchedPlan = nil
            prefetchedIndex = nil
        }
        currentIndex = index
        startPosition = 0
        lastSavedPosition = -1
        startLoad()
    }

    /// 离开播放：存好进度、销毁句柄、取消加载与预取，释放核心里的播放会话。
    func stop() {
        stopped = true
        controller.onStall = nil
        cancelRecovery()
        saveProgress()
        controller.stop()
        prefetchTask?.cancel()
        prefetchTask = nil
        loadTask?.cancel()
        loadTask = nil
        let sessions = [plan?.session, prefetchedPlan?.session].compactMap { $0 }
        prefetchedPlan = nil
        prefetchedIndex = nil
        Task {
            for session in sessions {
                try? await CoreClient.shared.release(session: session)
            }
        }
    }

    private func startLoad() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    /// 对本地代理失效、起播卡住和 mpv 错误统一做有限次数的自愈。
    /// 重建全新播放会话，而不是反复让 mpv 读取已经释放或过期的 127.0.0.1 地址。
    private func recover(position: Double, manual: Bool = false) {
        guard !stopped, recoveryTask == nil, episodes.indices.contains(currentIndex) else { return }
        guard manual || PlaybackRules.canRecover(attempts: recoveryAttempts) else {
            traceRecovery("自动恢复预算耗尽（\(recoveryAttempts) 次）")
            probeFailedMediaProxy(plan)
            error = "自动恢复已尝试 \(PlaybackRules.maxRecoveryAttempts) 次仍无播放进度，请手动重试。"
            return
        }
        if !manual { recoveryAttempts += 1 }
        recoveryStableFrom = nil
        let resumePosition = max(0, position.isFinite ? position : currentPosition)
        let oldPlan = plan
        let oldPrefetch = prefetchedPlan
        let index = currentIndex
        recoveryGeneration += 1
        let generation = recoveryGeneration
        traceRecovery("开始\(manual ? "手动" : "自动")恢复 #\(recoveryAttempts)，位置 \(Int(resumePosition))s")
        loadTask?.cancel()
        loadTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedPlan = nil
        prefetchedIndex = nil
        plan = nil
        startPosition = resumePosition
        controller.halt()
        error = nil
        recoveryTask = Task {
            defer { if recoveryGeneration == generation { recoveryTask = nil } }
            // 只在第一次自动恢复试备用线路。备用仍无法起播时必须重新解析，
            // 避免反复在同一份已过期凭证的清单内换线直至预算耗尽。
            if let oldPlan, PlaybackRules.shouldTryFallback(
                attempt: recoveryAttempts, manual: manual, hasAlternative: oldPlan.hasAlternative
            ) {
                traceRecovery("等待 Go 核心提供备用线路")
                if let next = try? await CoreClient.shared.fallback(plan: oldPlan) {
                    if Task.isCancelled || stopped || recoveryGeneration != generation || currentIndex != index {
                        try? await CoreClient.shared.release(session: next.session)
                        return
                    }
                    if next.session != oldPlan.session {
                        try? await CoreClient.shared.release(session: oldPlan.session)
                    }
                    if let oldPrefetch, oldPrefetch.session != oldPlan.session && oldPrefetch.session != next.session {
                        try? await CoreClient.shared.release(session: oldPrefetch.session)
                    }
                    guard !Task.isCancelled, !stopped, recoveryGeneration == generation, currentIndex == index else {
                        try? await CoreClient.shared.release(session: next.session)
                        return
                    }
                    activate(next, start: resumePosition)
                    traceRecovery("备用线路交给播放器，等待起播")
                    return
                }
            }
            traceRecovery("开始释放旧媒体会话")
            if let oldPlan { try? await CoreClient.shared.release(session: oldPlan.session) }
            if let oldPrefetch, oldPrefetch.session != oldPlan?.session {
                try? await CoreClient.shared.release(session: oldPrefetch.session)
            }
            guard !Task.isCancelled, !stopped, recoveryGeneration == generation, currentIndex == index else { return }
            do {
                traceRecovery("等待 Go 核心重新解析视频")
                let next = try await CoreClient.shared.resolve(
                    drama: drama, episode: episodes[index], quality: preferredQuality
                )
                guard !Task.isCancelled, !stopped, recoveryGeneration == generation, currentIndex == index else {
                    try? await CoreClient.shared.release(session: next.session)
                    return
                }
                activate(next, start: resumePosition)
                traceRecovery("新媒体地址已交给播放器，等待起播")
            } catch {
                guard !Task.isCancelled, !stopped, recoveryGeneration == generation else { return }
                traceRecovery("重新解析失败：\(String(describing: type(of: error)))")
                self.error = "重新解析播放地址失败：\(error.localizedDescription)"
            }
        }
    }

    private func cancelRecovery() {
        recoveryGeneration += 1
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    /// 覆盖旧计划之后才释放旧会话，避免切集时代理不断累积直至达到容量上限。
    private func activate(_ next: PlaybackPlan, start: Double) {
        let previous = plan
        plan = next
        controller.play(plan: next, start: start, danmakuEnabled: danmakuEnabled, speed: playbackSpeed)
        if let previous, previous.session != next.session {
            Task { try? await CoreClient.shared.release(session: previous.session) }
        }
    }

    private func load() async {
        guard !stopped, currentIndex < episodes.count else {
            if !stopped { onReachedEnd?() }
            return
        }
        error = nil
        let episode = episodes[currentIndex]
        // 预取仅在索引、任务状态有效时才可复用，切集旧计划适时释放。
        if prefetchedIndex == currentIndex {
            let cached = prefetchedPlan
            prefetchedPlan = nil
            prefetchedIndex = nil
            if let cached {
                if Task.isCancelled || stopped {
                    try? await CoreClient.shared.release(session: cached.session)
                    return
                }
                activate(cached, start: startPosition)
                return
            }
        }
        do {
            let resolved = try await CoreClient.shared.resolve(
                drama: drama, episode: episode, quality: preferredQuality
            )
            guard !Task.isCancelled, !stopped else {
                // 过时的 resolve 结果不能留在 Go 核心里成为孤儿会话。
                try? await CoreClient.shared.release(session: resolved.session)
                return
            }
            activate(resolved, start: startPosition)
        } catch {
            guard !Task.isCancelled, !stopped else { return }
            self.error = error.localizedDescription
        }
    }

    // MARK: - 播放器事件

    func handleEnded() {
        cancelRecovery()
        recoveryAttempts = 0
        recoveryStableFrom = nil
        if autoAdvance, currentIndex + 1 < episodes.count {
            currentIndex += 1
            startPosition = 0
            lastSavedPosition = -1
            startLoad()
        } else {
            onReachedEnd?()
        }
    }

    func handleFailed() async {
        // 原实现只在有备用线路时切换，单线路失败就直接终止，无法自愈。
        guard plan != nil, !stopped else { return }
        recover(position: currentPosition)
    }

    func handleProgress(position: Double, duration: Double) {
        guard position > 0, duration > 0 else { return }
        // 成功连续推进 30 秒才重置恢复预算；不能让频繁起播失败无限重试。
        if recoveryAttempts > 0 {
            if let stableFrom = recoveryStableFrom {
                if position < stableFrom { recoveryStableFrom = position }
                else if position - stableFrom >= 30 {
                    recoveryAttempts = 0
                    recoveryStableFrom = nil
                    traceRecovery("连续播放 30 秒，恢复预算归零")
                }
            } else {
                recoveryStableFrom = position
            }
        }
        maybePrefetchNext(position: position, duration: duration)
        // 与 Dart 侧一致：约每 5 秒落一次进度，避免频繁写盘。
        guard PlaybackRules.shouldSaveProgress(position: position, lastSaved: lastSavedPosition) else { return }
        lastSavedPosition = position
        saveProgress(position: position, duration: duration)
    }

    /// 当前集还剩 10 秒时，后台解析下一集播放地址（预取）。
    /// 切集时直接用预取好的计划，免去再等解析地址。
    private func maybePrefetchNext(position: Double, duration: Double) {
        guard let nextIndex = PlaybackRules.prefetchIndex(
            position: position,
            duration: duration,
            currentIndex: currentIndex,
            episodeCount: episodes.count,
            prefetchedIndex: prefetchedIndex,
            prefetchInFlight: prefetchTask != nil
        ) else { return }
        prefetchedIndex = nextIndex
        let episode = episodes[nextIndex]
        prefetchTask = Task {
            defer { prefetchTask = nil }
            guard let plan = try? await CoreClient.shared.resolve(
                drama: drama, episode: episode, quality: preferredQuality
            ) else { return }
            // 解析完成时若用户已不在触发那集（已切集/已退出），
            // 预取的计划用不上，释放其会话避免泄漏。
            guard !Task.isCancelled, currentIndex + 1 == nextIndex else {
                try? await CoreClient.shared.release(session: plan.session)
                return
            }
            prefetchedPlan = plan
        }
    }

    func saveProgress(position: Double? = nil, duration: Double? = nil) {
        guard currentIndex < episodes.count else { return }
        let position = position ?? controller.progress.position
        let duration = duration ?? controller.progress.duration
        guard position > 0, duration > 0, saveGate(position) else { return }
        let episode = episodes[currentIndex]
        store.saveProgress(WatchProgress(
            drama: drama,
            episode: episode.number,
            episodeTitle: episode.title,
            position: position,
            duration: duration,
            updatedAt: Date()
        ))
    }
}
