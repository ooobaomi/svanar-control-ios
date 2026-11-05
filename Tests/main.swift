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

let android = try EQLibrary.decode(Data(contentsOf: URL(fileURLWithPath: "Tests/android-eq-sample.json")))
assert(android.profiles.count == 14)
let androidRoundTrip = try EQLibrary.decode(android.encoded()); assert(androidRoundTrip == android)
var library = EQLibrary(); try library.add(EQProfile(id: "test", name: "测试", gains: gains)); library.links["1"] = "test"
assert(library.gains(for: .anc) == gains)
let exported = try library.encoded(); let restoredLibrary = try EQLibrary.decode(exported); assert(restoredLibrary == library)
var collision = EQLibrary(); try collision.add(EQProfile(id: "test", name: "不同", gains: Array(repeating: 0, count: 10))); collision.links["0"] = "test"
let merged = try library.merged(with: collision); assert(merged.profiles.count == 2 && merged.links["0"] != "test")
var broken = library; broken.links["2"] = "missing"; expectFailure { try broken.validate() }
library.remove("test"); assert(library.links.isEmpty)
expectFailure { _ = try EQLibrary.decode(Data(repeating: 32, count: 65537)) }
expectFailure { _ = try EQLibrary.decode(Data(String(repeating: "[", count: 18).utf8)) }
expectFailure { try EQProfile(id: "../bad", name: "测试", gains: gains).validate() }
expectFailure { _ = try EQLibrary.decode(Data("{\"format\":\"svanar-eq\",\"version\":9,\"frequencies\":[],\"profiles\":[],\"links\":{}}".utf8)) }
let touch = try TouchBinding.decode([1,1,1,1,2,3,2,1,1]); assert(touch.count == 3 && touch[1].action == 3)
expectFailure { _ = try TouchBinding.decode([1,1,1,1,1,1]) }
expectFailure { _ = try TouchBinding.decode([1,5,1]) }
expectFailure { _ = try TouchBinding.decode([1,1,99]) }
var features = DeviceFeatures(); features.accept(2,[1,1,1,0,0,0]); features.accept(5,[0,0,1,0,2,0]); features.accept(9,[0]); features.accept(11,[1,0,0]); features.accept(13,[1,1,1,0,0,0,0,0,0,0,0,0])
assert(features.supportsGame == true && features.gameEnabled == false && features.ldacDeclared == true)
assert(features.strengthSummary.contains("档位字段 0") && features.summary.contains("AAC"))
print("PASS: Android/iOS JSON fixture, EQ library roundtrip, collision-safe merge, bounds/version/depth validation, touch parser, feature flags")

var malformed = try JSONSerialization.jsonObject(with: android.encoded()) as! [String: Any]
var badProfiles = malformed["profiles"] as! [[String: Any]]
badProfiles[0]["gains"] = [1.5,0,0,0,0,0,0,0,0,0]; malformed["profiles"] = badProfiles
let fractionJSON = try JSONSerialization.data(withJSONObject: malformed)
expectFailure { _ = try EQLibrary.decode(fractionJSON) }
print("PASS: fractional EQ rejection and Android fixture compatibility")
