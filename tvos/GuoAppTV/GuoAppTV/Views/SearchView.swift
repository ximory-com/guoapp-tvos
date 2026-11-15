import SwiftUI

/// 搜索页使用系统 SwiftUI .searchable：由 tvOS 自己管理键盘、焦点与结果区。
/// 不再混合 UIKit UISearchContainerViewController 与 SwiftUI NavigationStack。
/// 输入文本为单向同步：model 只接收输入，不反向重写键盘中的组字。
struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: Store
    @StateObject private var model = SearchModel()
    @StateObject private var launcher = PlaybackLauncher()
    @State private var path: [Drama] = []
    @State private var searchText = ""

    var body: some View {
        NavigationStack(path: $path) {
            SearchResultsView(model: model, launcher: launcher) { drama in
                path.append(drama)
            }
            .environmentObject(store)
            .searchable(text: $searchText, prompt: "输入剧名、演员或关键词")
            .searchSuggestions {
                ForEach(model.suggestions.prefix(8), id: \.self) { suggestion in
                    Text(suggestion).searchCompletion(suggestion)
                }
            }
            .navigationDestination(for: Drama.self) { drama in
                DetailView(drama: drama)
            }
            .navigationDestination(for: ProducerRoute.self) { route in
                ProducerView(drama: route.drama)
            }
            .playbackLauncher(launcher)
        }
        .onAppear {
            model.source = appState.selectedSource
            model.loadPopular()
        }
        .onChange(of: searchText) { text in
            // 不从 SearchModel 回写到 searchText。保持 iPhone 远程输入
            // 的编辑状态、组字候选和系统键盘焦点完全归系统管理。
            model.update(text: text)
        }
        .onChange(of: appState.selectedSource) { source in
            model.source = source
            model.loadPopular()
        }
    }
}

/// 搜索结果与状态：没输入时「大家都在看」；输入后「找到 N 部短剧」+ 网格 / 加载骨架 / 没有找到 / 失败重试。
private struct SearchResultsView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var launcher: PlaybackLauncher
    let onOpen: (Drama) -> Void

    @EnvironmentObject private var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                resultSection
            }
            .padding(.horizontal, TVTheme.posterPageInset)
            .padding(.top, 24)
            .padding(.bottom, 56)
        }
        // Treat the results grid as a focus destination when moving down
        // from the native tvOS keyboard. Do not force focus onto a poster
        // while the user is still entering text.
        .focusSection()
    }

    @ViewBuilder
    private var resultSection: some View {
        if let error = model.error {
            TVFailureView(message: error) {
                model.retry()
            }
            .padding(.vertical, 100)
        } else if LiveSearch.query(from: model.query) == nil {
            popularSection
        } else if model.results.isEmpty, model.isAwaitingResults {
            PosterGridSkeleton(showsTitle: false)
                .padding(.top, 12)
        } else if model.results.isEmpty {
            TVStatusView(
                icon: "magnifyingglass",
                title: SearchCopy.notFound(model.searchedQuery ?? model.query),
                message: SearchCopy.notFoundHint,
                expands: false
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 100)
        } else {
            // 换关键词时旧结果先变暗，新结果回来再替换，不闪成整块加载。
            VStack(alignment: .leading, spacing: 24) {
                sectionTitle(SearchCopy.found(model.results.count))
                resultGrid
            }
            .padding(.top, 12)
            .opacity(model.isAwaitingResults ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.2), value: model.isAwaitingResults)
        }
    }

    /// 还没输入：「大家都在看」（推荐流前 14 部）；加载中是骨架，失败可重试。
    @ViewBuilder
    private var popularSection: some View {
        switch PopularState.make(count: model.popular.count, loading: model.popularLoading, error: model.popularError) {
        case .posters:
            VStack(alignment: .leading, spacing: 24) {
                sectionTitle(SearchCopy.popularTitle)
                LazyVGrid(columns: TVTheme.posterColumns(), spacing: 32) {
                    ForEach(model.popular) { drama in
                        TVPosterCard(drama: drama, isLoading: launcher.loadingDramaID == drama.id, onSelect: { onOpen(drama) })
                            .onPlayPauseCommand { launcher.play(drama, store: store) }
                    }
                }
                .prefetchesOnPosterFocus(model.popular)
            }
            .padding(.top, 12)
        case .loading:
            PosterGridSkeleton()
                .padding(.top, 12)
        case .failed(let error):
            TVFailureView(message: error) {
                model.loadPopular(force: true)
            }
            .padding(.vertical, 100)
        case .empty:
            VStack(spacing: 28) {
                TVStatusView(icon: "sparkles", title: SearchCopy.popularEmptyTitle, message: SearchCopy.popularEmptyHint, expands: false)
                TVPrimaryButton(title: "重试", icon: "arrow.clockwise") {
                    model.loadPopular(force: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 100)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TVTheme.TextSize.callout, weight: .bold))
            .foregroundColor(TVTheme.textPrimary)
    }

    /// 搜索结果：同一系列的各部合成一张卡片（「共 N 部」），其余单部剧原样显示。
    private var resultGrid: some View {
        let entries = SeriesGrouping.group(model.results, title: \.title, source: \.source)
        return LazyVGrid(columns: TVTheme.posterColumns(), spacing: 32) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .single(let drama):
                    TVPosterCard(drama: drama, isLoading: launcher.loadingDramaID == drama.id, onSelect: { onOpen(drama) })
                        .onPlayPauseCommand { launcher.play(drama, store: store) }
                case .series(let group):
                    let target = seriesTarget(group)
                    TVPosterCard(
                        drama: group.parts[0].item,
                        title: group.base,
                        subtitle: SeriesGrouping.partsLabel(group.partNumbers, unit: group.unit),
                        badge: "共 \(group.parts.count) \(group.unit)",
                        linkValue: target,
                        isLoading: launcher.loadingDramaID == target.id,
                        onSelect: { onOpen(target) }
                    )
                    .onPlayPauseCommand { launcher.play(target, store: store) }
                }
            }
        }
        .prefetchesOnPosterFocus(model.results)
    }

    /// 系列卡片进入 / 播放哪一部：最近看过的那部，没看过就第一部。
    private func seriesTarget(_ group: SeriesGroup<Drama>) -> Drama {
        let watched = group.parts.compactMap { part in
            store.latestProgress(for: part.item.id).map { (part.item, $0.updatedAt) }
        }
        return watched.max { $0.1 < $1.1 }?.0 ?? group.parts[0].item
    }
}
