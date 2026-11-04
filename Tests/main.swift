import Foundation

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func expectFailure(_ action: () throws -> Void) {
    do { try action(); fatalError("Expected rejection") } catch { }
}

assert(hex(HeadphoneProtocol.encode(6)) == "fe06000000c66b")
let mode = try HeadphoneProtocol.decode(HeadphoneProtocol.encode(6, [1, 0]))
assert(mode == HeadphonePacket(command: 6, payload: [1, 0]))
let gains = [-10, -5, -1, 0, 1, 2, 3, 5, 8, 10]
let decodedGains = try HeadphoneProtocol.decodeEQ(HeadphoneProtocol.eqPayload(gains))
assert(decodedGains == gains)
expectFailure { _ = try HeadphoneProtocol.eqPayload([0, 0]) }
expectFailure { _ = try HeadphoneProtocol.eqPayload(Array(repeating: 11, count: 10)) }
expectFailure { _ = try HeadphoneProtocol.decode(Data([0xFE, 6])) }
var corrupt = Array(HeadphoneProtocol.encode(6, [1, 0]))
corrupt[5] ^= 1
expectFailure { _ = try HeadphoneProtocol.decode(Data(corrupt)) }
var stream = PacketStream()
let frame = HeadphoneProtocol.encode(6, [2, 0])
assert(stream.feed(frame.prefix(4)).isEmpty)
assert(stream.feed(frame.dropFirst(4) + frame).count == 2)
let adv = Data([0x22,0xE6,0x00,0x01,0x00,0x02,0x01,0xBF,0x99,0xFB,0xD5,0x37,0x11])
assert(HeadphoneProtocol.classicIdentity(adv) == "12:34:56:78:9A:BC")
assert(HeadphoneProtocol.classicIdentity(Data([0])) == nil)
print("PASS: CRC known vector, mode, signed EQ, invalid ranges, corrupt frames, stream framing, manufacturer identity")
