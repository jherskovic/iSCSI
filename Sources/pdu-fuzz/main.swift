import Foundation
import iSCSIKit

/// Fuzz body: everything reachable from untrusted wire bytes must not crash.
/// Kept libFuzzer-compatible (LLVMFuzzerTestOneInput) even though Apple's
/// Xcode toolchain ships no libFuzzer runtime — scripts/fuzz.sh drives the
/// built-in mutation engine below under ASan instead.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOne(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    fuzzBody(Data(bytes: start, count: count))
    return 0
}

func fuzzBody(_ data: Data) {
    for header in [false, true] {
        for dataDigest in [false, true] {
            var deframer = PDUDeframer(
                digests: DigestConfig(headerDigest: header, dataDigest: dataDigest),
                maxDataSegmentLength: 1 << 20
            )
            deframer.append(data)
            while let raw = try? deframer.next() {
                if let pdu = try? AnyPDU.decode(raw) {
                    // Re-encode of a decoded PDU must never crash.
                    _ = pdu.encode()
                }
            }
        }
    }
    _ = try? TextParameters.decode(data)
}

#if !FUZZING

// MARK: - Deterministic mutation engine

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Valid serialized PDUs used as mutation bases.
func seedCorpus() -> [Data] {
    var seeds: [Data] = []
    let plain = PDUSerializer()
    let digested = PDUSerializer(digests: DigestConfig(headerDigest: true, dataDigest: true))

    var login = LoginRequestPDU()
    login.transit = true
    login.currentStage = .securityNegotiation
    login.nextStage = .loginOperationalNegotiation
    var keys = TextParameters()
    keys.append("InitiatorName", "iqn.2026-08.com.example:fuzz")
    keys.append("SessionType", "Normal")
    keys.append("AuthMethod", "CHAP,None")
    login.dataSegment = keys.encode()
    seeds.append(plain.serialize(login))

    var loginResp = LoginResponsePDU()
    loginResp.transit = true
    var respKeys = TextParameters()
    respKeys.append("TargetPortalGroupTag", "1")
    respKeys.append("HeaderDigest", "CRC32C")
    loginResp.dataSegment = respKeys.encode()
    seeds.append(plain.serialize(loginResp))

    var cmd = SCSICommandPDU()
    cmd.read = true
    cmd.cdb = Data([0x28, 0, 0, 0, 0, 0x40, 0, 0, 0x08, 0])
    cmd.expectedDataTransferLength = 4096
    seeds.append(plain.serialize(cmd))

    var dataIn = DataInPDU()
    dataIn.statusPresent = true
    dataIn.dataSegment = Data(repeating: 0x5A, count: 1024)
    seeds.append(digested.serialize(dataIn))

    var r2t = R2TPDU()
    r2t.targetTransferTag = 1
    r2t.desiredDataTransferLength = 65536
    seeds.append(plain.serialize(r2t))

    var nopIn = NopInPDU()
    nopIn.targetTransferTag = 0x1234
    nopIn.dataSegment = Data("ping".utf8)
    seeds.append(digested.serialize(nopIn))

    var reject = RejectPDU()
    reject.reason = .protocolError
    reject.dataSegment = Data(count: 48)
    seeds.append(plain.serialize(reject))

    var text = TextResponsePDU()
    var t = TextParameters()
    t.append("TargetName", "iqn.2026-08.com.example:disk0")
    t.append("TargetAddress", "10.0.0.1:3260,1")
    text.dataSegment = t.encode()
    seeds.append(plain.serialize(text))

    return seeds
}

/// Derive the fuzz input for (seed, iteration) — fully deterministic so any
/// crash reproduces from the two numbers ASan prints alongside our progress.
func deriveInput(seeds: [Data], seed: UInt64, iteration: UInt64) -> Data {
    var rng = SplitMix64(state: seed &* 0x9E37_79B9 &+ iteration)
    var input = seeds[Int(rng.next() % UInt64(seeds.count))]

    // Occasionally concatenate a second PDU (stream handling).
    if rng.next() % 4 == 0 {
        input += seeds[Int(rng.next() % UInt64(seeds.count))]
    }

    let mutations = 1 + Int(rng.next() % 8)
    for _ in 0 ..< mutations {
        switch rng.next() % 10 {
        case 0 where input.count > 1: // truncate
            input = input.prefix(Int(rng.next() % UInt64(input.count)) + 1)
        case 1: // extend with junk
            input += Data((0 ..< (rng.next() % 64)).map { _ in UInt8(rng.next() % 256) })
        case 2: // attack the length fields (AHS len, DataSegmentLength)
            let off = 4 + Int(rng.next() % 4)
            if input.count > off {
                var d = Data(input)
                d.setU8(UInt8(rng.next() % 256), off)
                input = d
            }
        case 3: // swap opcode byte
            if !input.isEmpty {
                var d = Data(input)
                d.setU8(UInt8(rng.next() % 256), 0)
                input = d
            }
        default: // random byte flip
            if !input.isEmpty {
                var d = Data(input)
                let off = Int(rng.next() % UInt64(d.count))
                d.setU8(d.u8(off) ^ UInt8(1 << (rng.next() % 8)), off)
                input = d
            }
        }
    }
    return input
}

// MARK: - CLI

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "help" {
case "fuzz":
    let seconds = args.count > 2 ? Double(args[2]) ?? 30 : 30
    let seed = args.count > 3 ? UInt64(args[3]) ?? 1 : 1
    let seeds = seedCorpus()
    // Self-check: all seeds must survive the body un-mutated.
    for s in seeds { fuzzBody(s) }
    let deadline = Date().addingTimeInterval(seconds)
    var iteration: UInt64 = 0
    print("fuzzing: seed=\(seed) (reproduce any crash with: pdu-fuzz derive \(seed) <iteration>)")
    while Date() < deadline {
        for _ in 0 ..< 10000 {
            fuzzBody(deriveInput(seeds: seeds, seed: seed, iteration: iteration))
            iteration += 1
        }
        print("iteration \(iteration)")
    }
    print("done: \(iteration) inputs, no crashes")

case "derive":
    // Re-create one input and run it: pdu-fuzz derive <seed> <iteration> [out-file]
    guard args.count >= 4, let seed = UInt64(args[2]), let iter = UInt64(args[3]) else {
        FileHandle.standardError.write(Data("usage: pdu-fuzz derive <seed> <iteration> [out]\n".utf8))
        exit(2)
    }
    let input = deriveInput(seeds: seedCorpus(), seed: seed, iteration: iter)
    if args.count > 4 {
        try input.write(to: URL(fileURLWithPath: args[4]))
        print("wrote \(input.count) bytes to \(args[4])")
    }
    fuzzBody(input)
    print("ok (\(input.count) bytes)")

case "replay":
    for path in args.dropFirst(2) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
            continue
        }
        fuzzBody(data)
        print("ok \(path) (\(data.count) bytes)")
    }

default:
    print("""
    usage:
      pdu-fuzz fuzz [seconds] [seed]        run the mutation fuzzer
      pdu-fuzz derive <seed> <iteration>    reproduce one input
      pdu-fuzz replay <files...>            run saved inputs
    """)
}
#endif
