import Foundation

struct TouchBinding: Codable, Identifiable, Equatable {
    let ear: Int
    let gesture: Int
    let action: Int
    var id: Int { ear * 10 + gesture }
    static let gestures = ["", "单击", "双击", "三击", "长按"]
    static let actions = ["无操作", "播放 / 暂停", "上一曲", "下一曲", "音量增加", "音量减小", "语音助手", "模式切换", "接听电话", "挂断电话"]
    var name: String { "\(ear == 1 ? "左耳" : "右耳") · \(Self.gestures[gesture])" }
    func validate() throws {
        guard (1...2).contains(ear), (1...4).contains(gesture), Self.actions.indices.contains(action) else { throw HeadphoneError.message("触控数据含未知耳侧、手势或动作") }
    }
    var payload: [UInt8] { [UInt8(ear), UInt8(gesture), UInt8(action)] }
    static func decode(_ bytes: [UInt8]) throws -> [TouchBinding] {
        guard !bytes.isEmpty, bytes.count <= 24, bytes.count % 3 == 0 else { throw HeadphoneError.message("触控映射响应格式无效") }
        var result: [TouchBinding] = []
        for i in stride(from: 0, to: bytes.count, by: 3) {
            let e = TouchBinding(ear: Int(bytes[i]), gesture: Int(bytes[i + 1]), action: Int(bytes[i + 2])); try e.validate()
            guard !result.contains(where: { $0.id == e.id }) else { throw HeadphoneError.message("触控响应有重复手势") }; result.append(e)
        }
        return result.sorted { $0.id < $1.id }
    }
}

struct TouchBackup: Codable { var identity: String; var mappings: [TouchBinding] }

struct DeviceFeatures {
    var raw: [UInt8: [UInt8]] = [:]
    mutating func accept(_ command: UInt8, _ payload: [UInt8]) { raw[command] = payload }
    var supportsGame: Bool? { guard let p = raw[2], p.count >= 3 else { return nil }; return p[2] & 127 == 1 }
    var gameEnabled: Bool? { guard let p = raw[9], p.count == 1, p[0] <= 1 else { return nil }; return p[0] == 1 }
    var ldacDeclared: Bool? { guard let p = raw[13], p.count >= 3 else { return nil }; return p[2] & 127 == 1 }
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
    var strengthSummary: String {
        let flags = raw[2]
        func flag(_ i: Int) -> String { guard let p = flags, p.count > i else { return "未读取" }; return p[i] & 127 == 1 ? "声明支持" : "未声明支持" }
        func level(_ mode: UInt8) -> String {
            guard let p = raw[5], p.count % 2 == 0 else { return "—" }
            for i in stride(from: 0, to: p.count, by: 2) where p[i] == mode { return String(p[i + 1] & 127) }; return "—"
        }
        return "降噪强度：\(flag(4))；档位字段 \(level(1))\n通透强度：\(flag(5))；档位字段 \(level(2))\n强度接口未经验证时不开放滑块；EQ 不等于降噪或通透强度。"
    }
    var summary: String {
        var lines = ["最近一次耳机回读，不代表 iOS 系统音频协商"]
        if let p = raw[12], p.count > 8 {
            let model = String(decoding: p.dropLast(8), as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
            lines += ["型号：\(model)", "固件字节：\(Self.hex(Array(p.suffix(8).prefix(4))))", "充电盒版本字节：\(Self.hex(Array(p.suffix(4))))"]
        }
        if let p = raw[11], p.count >= 3 {
            let codecs = ["SBC", "AAC", "LDAC", "aptX", "aptX Adaptive", "aptX Lossless", "aptX HD", "LHDC 4", "LHDC 5", "LC3", "LC3 Plus", "L2HC"]
            let depth = ["16 bit", "24 bit", "32 bit"], rates = ["44.1 kHz", "48 kHz", "96 kHz", "192 kHz", "88.2 kHz", "384 kHz"]
            func label(_ names: [String], _ byte: UInt8) -> String { let index = Int(byte & 127); return names.indices.contains(index) ? names[index] : "未知" }
            lines.append("耳机编码报告：\(label(codecs, p[0])) / \(label(depth, p[1])) / \(label(rates, p[2]))")
        }
        lines += ["LDAC 能力声明：\(ldacDeclared.map { $0 ? "支持" : "未声明" } ?? "未取得")", "游戏模式：\(gameEnabled.map { $0 ? "开启" : "关闭" } ?? "未取得")", strengthSummary]
        lines += raw.keys.sorted().map { String(format: "%02X", $0) + ": " + Self.hex(raw[$0] ?? []) }
        return lines.joined(separator: "\n")
    }
}
