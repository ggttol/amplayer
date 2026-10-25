import Foundation

/// 歌词：LRC 同步歌词或纯文本歌词。
public struct Lyrics: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        public var id: Int
        /// 开始时间（秒）；纯文本歌词为 nil
        public var time: TimeInterval?
        /// 同一时间戳的多行（如中英对照）用换行合并
        public var text: String
    }

    public var lines: [Line]
    public var isSynced: Bool { lines.first?.time != nil }

    public init(lines: [Line]) { self.lines = lines }

    /// 解析 LRC。支持一行多个时间戳、[offset:]、增强格式的 <mm:ss.xx> 逐字时间（忽略）；
    /// 没有时间戳时按纯文本处理。内容为空返回 nil。
    public static func parse(_ text: String) -> Lyrics? {
        var offset: TimeInterval = 0
        var timed: [(time: TimeInterval, order: Int, text: String)] = []
        var plain: [String] = []
        var order = 0
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var times: [TimeInterval] = []
            var isTag = false
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = timestamp(tag) {
                    times.append(t)
                } else if let colon = tag.firstIndex(of: ":") {
                    let key = tag[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    if key == "offset", let ms = Double(tag[tag.index(after: colon)...].trimmingCharacters(in: .whitespaces)) {
                        offset = ms / 1000
                    }
                    isTag = true
                } else {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }
            let body = stripWordTimes(String(rest)).trimmingCharacters(in: .whitespaces)
            if !times.isEmpty {
                for t in times {
                    timed.append((t, order, body))
                    order += 1
                }
            } else if !isTag, !body.isEmpty {
                plain.append(body)
            }
        }
        if !timed.isEmpty {
            // 正的 offset 表示歌词整体提前
            let sorted = timed.sorted { ($0.time, $0.order) < ($1.time, $1.order) }
            var lines: [Line] = []
            for item in sorted {
                let time = max(0, item.time - offset)
                if let last = lines.last, let lt = last.time, abs(lt - time) < 0.001 {
                    if !item.text.isEmpty {
                        lines[lines.count - 1].text = last.text.isEmpty ? item.text : last.text + "\n" + item.text
                    }
                } else {
                    lines.append(Line(id: lines.count, time: time, text: item.text))
                }
            }
            // 全是空行（只有时间戳）就不算有歌词
            guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
            return Lyrics(lines: lines)
        }
        guard !plain.isEmpty else { return nil }
        return Lyrics(lines: plain.enumerated().map { Line(id: $0.offset, time: nil, text: $0.element) })
    }

    /// 繁体转简体（系统自带的 ICU 转换）
    public func simplified() -> Lyrics {
        Lyrics(lines: lines.map { line in
            var l = line
            l.text = line.text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? line.text
            return l
        })
    }

    /// 纯文本歌词没有时间轴：按播放进度估计唱到哪一行（假定前奏、尾奏各占一成），用来跟着滚动
    public func estimatedIndex(progress: Double) -> Int? {
        guard !lines.isEmpty, progress.isFinite else { return nil }
        let p = (progress - 0.1) / 0.8
        return min(max(Int(p * Double(lines.count)), 0), lines.count - 1)
    }

    /// 当前时间对应的行（最后一个开始时间 <= time 的行）
    public func index(at time: TimeInterval) -> Int? {
        guard isSynced else { return nil }
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if let t = lines[mid].time, t <= time + 0.05 {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }

    /// 歌词文件的文本编码：带 BOM 的 UTF-8/UTF-16，否则 UTF-8，再退到 GB18030（国内 LRC 常见）和 Big5
    public static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian).map { String($0.drop { $0 == "\u{FEFF}" }) } }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian).map { String($0.drop { $0 == "\u{FEFF}" }) } }
        if let s = String(data: data, encoding: .utf8) { return s }
        for cf in [CFStringEncodings.GB_18030_2000, .big5] {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
            if let s = String(data: data, encoding: encoding) { return s }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// 把同步歌词写回 LRC 文本（用于缓存）
    public var lrcText: String {
        lines.map { line in
            guard let t = line.time else { return line.text }
            let stamp = String(format: "[%02d:%05.2f]", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
            return line.text.components(separatedBy: "\n").map { stamp + $0 }.joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    /// mm:ss、mm:ss.xx、mm:ss:xx
    static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let minutes = Int(parts[0].trimmingCharacters(in: .whitespaces)), minutes >= 0 else { return nil }
        let secondsText = parts.count == 3 ? "\(parts[1]).\(parts[2])" : String(parts[1])
        guard let seconds = Double(secondsText.trimmingCharacters(in: .whitespaces)), seconds >= 0, seconds < 60 else { return nil }
        return TimeInterval(minutes * 60) + seconds
    }

    /// 去掉增强 LRC 的 <mm:ss.xx> 逐字时间
    static func stripWordTimes(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = ""
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "<") {
            out += rest[..<open]
            if let close = rest[open...].firstIndex(of: ">"), timestamp(rest[rest.index(after: open)..<close]) != nil {
                rest = rest[rest.index(after: close)...]
            } else {
                out.append("<")
                rest = rest[rest.index(after: open)...]
            }
        }
        return out + rest
    }
}
