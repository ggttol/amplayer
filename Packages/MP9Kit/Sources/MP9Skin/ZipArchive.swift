import Compression
import Foundation

/// 极简 ZIP 读取器（仅支持 stored / deflate，足够解析 .wsz 皮肤包）
public struct ZipArchive: Sendable {
    public struct Entry: Sendable {
        public var path: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    public enum ZipError: Error, Sendable {
        case notZip, corrupt, unsupportedMethod(UInt16)
    }

    private let bytes: [UInt8]
    public let entries: [Entry]

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        guard bytes.count >= 22 else { throw ZipError.notZip }

        // 从末尾找 End of Central Directory
        var eocd = -1
        let lowest = max(0, bytes.count - 65_557)
        var i = bytes.count - 22
        while i >= lowest {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }

        let count = Int(Self.u16(bytes, eocd + 10))
        var offset = Int(Self.u32(bytes, eocd + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, Self.u32(bytes, offset) == 0x02014B50 else { throw ZipError.corrupt }
            let flags = Self.u16(bytes, offset + 8)
            let method = Self.u16(bytes, offset + 10)
            let compressed = Int(Self.u32(bytes, offset + 20))
            let uncompressed = Int(Self.u32(bytes, offset + 24))
            let nameLength = Int(Self.u16(bytes, offset + 28))
            let extraLength = Int(Self.u16(bytes, offset + 30))
            let commentLength = Int(Self.u16(bytes, offset + 32))
            let local = Int(Self.u32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else { throw ZipError.corrupt }
            let nameBytes = Array(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            let utf8 = flags & 0x0800 != 0
            let name = (utf8 ? String(bytes: nameBytes, encoding: .utf8) : nil)
                ?? String(bytes: nameBytes, encoding: .utf8)
                ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            entries.append(Entry(path: name, method: method, compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: local))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// 按文件名（忽略目录与大小写）查找
    public func entry(named name: String) -> Entry? {
        let lower = name.lowercased()
        return entries.first { entry in
            let base = entry.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? entry.path
            return base.lowercased() == lower && !entry.path.hasSuffix("/")
        }
    }

    public func data(for entry: Entry) throws -> Data {
        let o = entry.localHeaderOffset
        guard o + 30 <= bytes.count, Self.u32(bytes, o) == 0x04034B50 else { throw ZipError.corrupt }
        let start = o + 30 + Int(Self.u16(bytes, o + 26)) + Int(Self.u16(bytes, o + 28))
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw ZipError.corrupt }
        switch entry.method {
        case 0:
            return Data(bytes[start..<end])
        case 8:
            let capacity = max(entry.uncompressedSize, 1)
            var output = [UInt8](repeating: 0, count: capacity)
            let written = bytes.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, capacity, src.baseAddress! + start, entry.compressedSize, nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 || entry.uncompressedSize == 0 else { throw ZipError.corrupt }
            return Data(output.prefix(written))
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    public func data(named name: String) -> Data? {
        entry(named: name).flatMap { try? data(for: $0) }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
