import Foundation

struct EQProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var gains: [Int]
    func validate() throws {
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 40,
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw HeadphoneError.message("收藏 ID 或名称无效；名称须为 1–40 字")
        }
        _ = try HeadphoneProtocol.eqPayload(gains)
    }
}

struct EQLibrary: Codable, Equatable {
    static let maximumBytes = 65536
    var format = "svanar-eq"
    var version = 1
    var frequencies = HeadphoneProtocol.frequencies
    var profiles: [EQProfile] = []
    var links: [String: String] = [:]
    static func initial() -> EQLibrary {
        var result = EQLibrary()
        result.profiles = EQPresets.values.enumerated().map { EQProfile(id: "builtin-\($0.offset)", name: $0.element.0, gains: $0.element.1) }
        return result
    }
    func validate() throws {
        guard format == "svanar-eq", version == 1, frequencies == HeadphoneProtocol.frequencies,
              profiles.count <= 64, Set(profiles.map(\.id)).count == profiles.count else {
            throw HeadphoneError.message("EQ 文件版本、频段或收藏数量无效")
        }
        for p in profiles { try p.validate() }
        let ids = Set(profiles.map(\.id))
        guard links.allSatisfy({ ["0", "1", "2"].contains($0.key) && ids.contains($0.value) }) else {
            throw HeadphoneError.message("模式绑定引用了无效收藏")
        }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw HeadphoneError.message("EQ 文件超过 64 KiB") }
        return data
    }
    static func decode(_ data: Data) throws -> EQLibrary {
        guard data.count <= maximumBytes else { throw HeadphoneError.message("EQ 文件超过 64 KiB") }
        var depth = 0, quoted = false, escaped = false
        for c in data {
            if quoted {
                if escaped { escaped = false }
                else if c == 92 { escaped = true }
                else if c == 34 { quoted = false }
            } else if c == 34 { quoted = true }
            else if c == 123 || c == 91 { depth += 1; if depth > 16 { throw HeadphoneError.message("JSON 嵌套过深") } }
            else if c == 125 || c == 93 { depth -= 1 }
        }
        let library = try JSONDecoder().decode(EQLibrary.self, from: data)
        try library.validate(); return library
    }
    mutating func add(_ profile: EQProfile) throws {
        try profile.validate()
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile }
        else { guard profiles.count < 64 else { throw HeadphoneError.message("最多保存 64 套收藏") }; profiles.append(profile) }
    }
    mutating func remove(_ id: String) { profiles.removeAll { $0.id == id }; links = links.filter { $0.value != id } }
    func merged(with imported: EQLibrary) throws -> EQLibrary {
        try imported.validate(); var result = self; var ids: [String: String] = [:]
        for p in imported.profiles {
            var copy = p
            if let old = result.profiles.first(where: { $0.id == p.id }), old != p { copy.id = UUID().uuidString }
            try result.add(copy); ids[p.id] = copy.id
        }
        for (key, value) in imported.links { result.links[key] = ids[value] }
        try result.validate(); return result
    }
    func gains(for mode: ListeningMode) -> [Int]? {
        guard let id = links[String(mode.rawValue)] else { return nil }; return profiles.first { $0.id == id }?.gains
    }
}

struct EQPreferences: Codable { var library: EQLibrary; var enabled: Bool }

enum EQPresets {
    static let values: [(String, [Int])] = [
        ("平直", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("低频增强", [3, 3, 2, 1, 0, 0, 0, 0, 0, 0]),
        ("人声清晰", [-2, -1, 0, 0, 1, 2, 2, 1, 0, 0]),
        ("柔和高频", [0, 0, 0, 0, 0, 0, -1, -2, -3, -3]),
        ("流行", [1, 2, 1, 0, -1, 0, 1, 2, 1, 0]),
        ("摇滚", [2, 3, 2, 0, -1, 0, 2, 3, 2, 1]),
        ("电子", [4, 3, 2, 0, -1, 0, 1, 2, 2, 1]),
        ("爵士", [1, 2, 1, 0, 1, 1, 0, 1, 1, 0]),
        ("古典", [0, 0, 0, -1, 0, 0, 1, 1, 1, 1]),
        ("电影", [3, 3, 2, 0, 0, 1, 2, 1, 0, 0]),
        ("游戏", [-2, -2, -1, 0, 0, 1, 3, 2, 1, 0]),
        ("播客", [-3, -2, -1, 0, 1, 2, 2, 1, -1, -2]),
        ("女声", [-2, -1, -1, 0, 0, 1, 2, 2, 1, 0]),
        ("男声", [0, 1, 2, 1, 0, 1, 1, 0, -1, -1])
    ]
}
