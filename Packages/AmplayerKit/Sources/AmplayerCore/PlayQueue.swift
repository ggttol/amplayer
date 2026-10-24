import Foundation

public enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off, all, one

    public var title: String {
        switch self {
        case .off: "顺序播放"
        case .all: "列表循环"
        case .one: "单曲循环"
        }
    }
}

/// 播放列表与播放顺序（随机、循环）。纯值类型，便于测试和持久化。
public struct PlayQueue: Codable, Sendable, Equatable {
    public private(set) var tracks: [Track] = []
    /// 当前曲目在 tracks 中的下标
    public private(set) var currentIndex: Int?
    public var repeatMode: RepeatMode = .off
    public private(set) var shuffle = false
    /// 随机模式下的播放顺序（tracks 下标的排列）
    private var order: [Int] = []

    public init(tracks: [Track] = []) {
        self.tracks = tracks
        rebuildOrder(keepCurrentFirst: false)
    }

    public var current: Track? { currentIndex.map { tracks[$0] } }
    public var isEmpty: Bool { tracks.isEmpty }
    public var totalDuration: TimeInterval { tracks.reduce(0) { $0 + ($1.duration ?? 0) } }

    // MARK: 编辑

    public mutating func append(_ newTracks: [Track]) {
        let start = tracks.count
        tracks.append(contentsOf: newTracks)
        let added = Array(start..<tracks.count)
        if shuffle { order.append(contentsOf: added.shuffled()) } else { order.append(contentsOf: added) }
    }

    public mutating func insertNext(_ newTracks: [Track]) {
        let at = (currentIndex ?? -1) + 1
        tracks.insert(contentsOf: newTracks, at: at)
        if let c = currentIndex, c >= at { currentIndex = c + newTracks.count }
        rebuildOrder(keepCurrentFirst: true)
    }

    public mutating func replace(with newTracks: [Track], startAt index: Int? = 0) {
        tracks = newTracks
        currentIndex = newTracks.isEmpty ? nil : index.map { min(max($0, 0), newTracks.count - 1) }
        rebuildOrder(keepCurrentFirst: true)
    }

    public mutating func remove(at offsets: IndexSet) {
        let currentID = current?.id
        let currentRemoved = currentIndex.map { offsets.contains($0) } ?? false
        var kept: [Track] = []
        for (i, t) in tracks.enumerated() where !offsets.contains(i) { kept.append(t) }
        tracks = kept
        if currentRemoved {
            currentIndex = nil
        } else if let currentID {
            currentIndex = tracks.firstIndex { $0.id == currentID }
        }
        rebuildOrder(keepCurrentFirst: true)
    }

    public mutating func move(from source: IndexSet, to destination: Int) {
        let currentID = current?.id
        let moving = source.sorted().map { tracks[$0] }
        var rest: [Track] = []
        var insertAt = destination
        for (i, t) in tracks.enumerated() {
            if source.contains(i) {
                if i < destination { insertAt -= 1 }
            } else {
                rest.append(t)
            }
        }
        rest.insert(contentsOf: moving, at: min(max(insertAt, 0), rest.count))
        tracks = rest
        if let currentID { currentIndex = tracks.firstIndex { $0.id == currentID } }
        rebuildOrder(keepCurrentFirst: true)
    }

    public mutating func removeAll() {
        tracks = []
        currentIndex = nil
        order = []
    }

    public mutating func sort(by areInIncreasingOrder: (Track, Track) -> Bool) {
        let currentID = current?.id
        tracks.sort(by: areInIncreasingOrder)
        if let currentID { currentIndex = tracks.firstIndex { $0.id == currentID } }
        rebuildOrder(keepCurrentFirst: true)
    }

    public mutating func reverse() {
        sortPreservingCurrent { $0.reverse() }
    }

    public mutating func randomize() {
        sortPreservingCurrent { $0.shuffle() }
    }

    private mutating func sortPreservingCurrent(_ body: (inout [Track]) -> Void) {
        let currentID = current?.id
        body(&tracks)
        if let currentID { currentIndex = tracks.firstIndex { $0.id == currentID } }
        rebuildOrder(keepCurrentFirst: true)
    }

    /// 用新的元数据替换同 ID 曲目（例如下载后读出了标签）
    public mutating func update(_ track: Track) {
        for i in tracks.indices where tracks[i].id == track.id { tracks[i] = track }
    }

    // MARK: 导航

    public mutating func select(index: Int) {
        guard tracks.indices.contains(index) else { return }
        currentIndex = index
    }

    public mutating func setShuffle(_ on: Bool) {
        shuffle = on
        rebuildOrder(keepCurrentFirst: true)
    }

    /// 下一首的下标；auto 为 true 表示当前曲目自然播完（单曲循环时重复当前）
    public func nextIndex(auto: Bool) -> Int? {
        guard !tracks.isEmpty else { return nil }
        guard let currentIndex else { return order.first }
        if auto && repeatMode == .one { return currentIndex }
        guard let pos = order.firstIndex(of: currentIndex) else { return order.first }
        if pos + 1 < order.count { return order[pos + 1] }
        return repeatMode == .off && auto ? nil : order.first
    }

    public func previousIndex() -> Int? {
        guard !tracks.isEmpty else { return nil }
        guard let currentIndex, let pos = order.firstIndex(of: currentIndex) else { return order.first }
        if pos > 0 { return order[pos - 1] }
        return repeatMode == .off ? order.first : order.last
    }

    @discardableResult
    public mutating func advance(auto: Bool) -> Track? {
        guard let next = nextIndex(auto: auto) else { return nil }
        currentIndex = next
        return tracks[next]
    }

    @discardableResult
    public mutating func goBack() -> Track? {
        guard let prev = previousIndex() else { return nil }
        currentIndex = prev
        return tracks[prev]
    }

    private mutating func rebuildOrder(keepCurrentFirst: Bool) {
        var indices = Array(tracks.indices)
        if shuffle {
            indices.shuffle()
            if keepCurrentFirst, let c = currentIndex, let pos = indices.firstIndex(of: c) {
                indices.swapAt(0, pos)
            }
        }
        order = indices
    }
}
