import Foundation

enum HeadphoneError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

enum ListeningMode: UInt8, CaseIterable, Identifiable {
    case hifi = 0, anc = 1, transparency = 2
    var id: UInt8 { rawValue }
    var name: String {
        switch self { case .hifi: return "HiFi"; case .anc: return "降噪"; case .transparency: return "通透" }
    }
    var symbol: String {
        switch self { case .hifi: return "waveform"; case .anc: return "ear.badge.waveform"; case .transparency: return "ear" }
    }
}

struct HeadphonePacket: Equatable {
    let command: UInt8
    let payload: [UInt8]
}

enum HeadphoneProtocol {
    static let frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let service = "0000FF77-0000-1000-8000-00805F9B34FB"
    static let tx = "0000FF88-0000-1000-8000-00805F9B34FB"
    static let rx = "0000FF99-0000-1000-8000-00805F9B34FB"

    static func crc(_ bytes: [UInt8]) -> UInt16 {
        var result: UInt16 = 0xFFFF
        for byte in bytes {
            result ^= UInt16(byte) << 8
            for _ in 0..<8 {
                result = result & 0x8000 != 0 ? (result &<< 1) ^ 0x1021 : result &<< 1
            }
        }
        return result
    }

    static func encode(_ command: UInt8, _ payload: [UInt8] = []) -> Data {
        precondition(payload.count <= 2041)
        var bytes: [UInt8] = [0xFE, command, 0, UInt8(payload.count >> 8), UInt8(payload.count & 255)]
        bytes += payload
        let checksum = crc(bytes)
        bytes += [UInt8(checksum >> 8), UInt8(checksum & 255)]
        return Data(bytes)
    }

    static func decode(_ data: Data) throws -> HeadphonePacket {
        let b = Array(data)
        guard b.count >= 7, b[0] == 0xFE,
              b.count == 7 + (Int(b[3]) << 8) + Int(b[4]) else {
            throw HeadphoneError.message("耳机响应长度无效")
        }
        let expected = UInt16(b[b.count - 2]) << 8 | UInt16(b[b.count - 1])
        guard expected == crc(Array(b.dropLast(2))) else {
            throw HeadphoneError.message("耳机响应校验失败")
        }
        return HeadphonePacket(command: b[1], payload: Array(b[5..<(b.count - 2)]))
    }

    static func eqPayload(_ gains: [Int]) throws -> [UInt8] {
        guard gains.count == 10, gains.allSatisfy({ (-10...10).contains($0) }) else {
            throw HeadphoneError.message("EQ 需要 10 个 -10 至 +10 dB 的整数")
        }
        return [101, 10] + gains.map { UInt8(bitPattern: Int8($0)) }
    }

    static func decodeEQ(_ payload: [UInt8]) throws -> [Int] {
        guard payload.count == 12, payload[1] == 10 else {
            throw HeadphoneError.message("耳机 EQ 格式不受支持")
        }
        let values = payload.dropFirst(2).map { Int(Int8(bitPattern: $0)) }
        guard values.allSatisfy({ (-10...10).contains($0) }) else {
            throw HeadphoneError.message("耳机 EQ 数据超出范围")
        }
        return values
    }

    // iOS includes the little-endian Company Identifier in manufacturer data.
    static func classicIdentity(_ data: Data) -> String? {
        let b = Array(data)
        guard b.count >= 13, b[0] == 0x22, b[1] == 0xE6,
              b[4] == 0, b[5] == 2 else { return nil }
        return b[7..<13].map { String(format: "%02X", $0 ^ 0xAD) }.joined(separator: ":")
    }
}

struct PacketStream {
    private var buffer: [UInt8] = []
    mutating func clear() { buffer.removeAll() }
    mutating func feed(_ data: Data) -> [HeadphonePacket] {
        buffer += Array(data)
        var packets: [HeadphonePacket] = []
        while !buffer.isEmpty {
            if buffer[0] != 0xFE { buffer.removeFirst(); continue }
            if buffer.count < 5 { break }
            let length = 7 + (Int(buffer[3]) << 8) + Int(buffer[4])
            if length > 2048 { buffer.removeFirst(); continue }
            if buffer.count < length { break }
            let frame = Data(buffer.prefix(length))
            buffer.removeFirst(length)
            if let packet = try? HeadphoneProtocol.decode(frame) { packets.append(packet) }
        }
        return packets
    }
}
