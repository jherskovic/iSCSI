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
    stateless(data)
    // Again at a non-zero startIndex: fresh Data always starts at 0, which
    // cannot catch indexing a *slice* with an absolute offset. This pins the
    // `self[startIndex + offset]` accessors in Support/Endian.
    var prefixed = Data([0xAA, 0x55, 0x00])
    prefixed.append(data)
    stateless(prefixed.dropFirst(3))

    chapParsers(data)
    loginExchange(data)
}

/// Stateless parsers of target-controlled bytes.
private func stateless(_ data: Data) {
    // Two digest configurations, not four: mutated inputs essentially never
    // carry a valid CRC, so the mixed configs decoded nothing and cost half
    // the CPU budget.
    for digests in [DigestConfig(), DigestConfig(headerDigest: true, dataDigest: true)] {
        var deframer = PDUDeframer(digests: digests, maxDataSegmentLength: 1 << 20)
        deframer.append(data)
        while let raw = try? deframer.next() {
            if let pdu = try? AnyPDU.decode(raw) {
                // Re-encode of a decoded PDU must never crash.
                _ = pdu.encode()
            }
        }
    }
    _ = try? TextParameters.decode(data)
    // Target-controlled SCSI payloads. Data's accessors trap on an
    // out-of-range offset rather than returning nil, so any missed bounds
    // check here is a crash, not a wrong answer.
    _ = ModeSense.writeCacheEnabled(inResponse: data)
    _ = SenseData(data)
    // READ CAPACITY(16). Extracted as a pure function precisely so it could be
    // reached from here: three separate remote aborts lived in the four lines
    // that used to parse this inline, and none of them were fuzzable.
    _ = try? ISCSIBlockDevice.geometry(fromReadCapacity16: data)
}

/// The CHAP value parsers, which run on attacker-chosen text *before*
/// authentication completes and had never been fuzzed.
private func chapParsers(_ data: Data) {
    let text = String(decoding: data, as: UTF8.self)
    _ = try? CHAP.decodeValue(text)
    _ = try? CHAP.decodeID(text)
    // The prefixed forms are the ones that actually reach the hex and base64
    // branches; raw bytes almost never start with "0x".
    _ = try? CHAP.decodeValue("0x" + text)
    _ = try? CHAP.decodeValue("0b" + text)
    // And as key/value pairs, the way they arrive.
    if let params = try? TextParameters.decode(data) {
        for key in ["CHAP_A", "CHAP_I", "CHAP_C", "CHAP_N", "CHAP_R"] {
            if let value = params[key] {
                _ = try? CHAP.decodeValue(value)
                _ = try? CHAP.decodeID(value)
            }
        }
    }
}

/// Drive the login state machine — negotiation engine, CHAP, continuation
/// buffers — through a multi-round exchange sliced from the input. Rounds are
/// bounded: a never-terminating script is real target behaviour, but this
/// loop must return.
private func loginExchange(_ data: Data) {
    guard !data.isEmpty else { return }
    for withCHAP in [false, true] {
        var config = LoginConfig(
            initiatorName: "iqn.2026-08.com.example:fuzz",
            sessionType: .normal,
            targetName: "iqn.2026-08.com.example:disk0",
            chap: withCHAP ? CHAP.Credentials(name: "u", secret: "secretsecret1234") : nil
        )
        config.desired.offerDigests = true

        var machine = LoginStateMachine(config: config, cmdSN: 1)
        var request = machine.start()
        var cursor = data.startIndex
        var rounds = 0
        while cursor < data.endIndex, rounds < 24 {
            rounds += 1
            let take = 1 + Int(data[cursor]) % 96
            let end = min(data.index(cursor, offsetBy: take, limitedBy: data.endIndex)
                          ?? data.endIndex, data.endIndex)
            let chunk = data[cursor ..< end]
            cursor = end

            var resp = LoginResponsePDU()
            let flags = chunk.first ?? 0
            resp.transit = flags & 0x80 != 0
            resp.continued = !resp.transit && (flags & 0x40 != 0)
            resp.currentStage = LoginStage(rawValue: (flags >> 2) & 3) ?? .securityNegotiation
            resp.nextStage = LoginStage(rawValue: flags & 3) ?? .securityNegotiation
            resp.statusClass = (flags & 0x20) != 0 ? 1 : 0
            resp.statSN = UInt32(rounds - 1)
            resp.expCmdSN = 1
            resp.maxCmdSN = 64
            resp.dataSegment = Data(chunk)

            guard let outcome = try? machine.receive(resp) else { break }
            switch outcome {
            case .send(let next): request = next
            case .success, .redirect: cursor = data.endIndex
            }
            _ = request
        }
    }
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

    // A CHAP challenge, so mutation lands inside the authentication parsers
    // rather than only near them. These values are the ones a hostile target
    // controls, and they are consumed before the login completes.
    var challenge = LoginResponsePDU()
    challenge.currentStage = .securityNegotiation
    challenge.nextStage = .securityNegotiation
    var chapKeys = TextParameters()
    chapKeys.append("CHAP_A", "5")
    chapKeys.append("CHAP_I", "42")
    chapKeys.append("CHAP_C", "0x8f1e2d3c4b5a69780f1e2d3c4b5a6978")
    challenge.dataSegment = chapKeys.encode()
    seeds.append(plain.serialize(challenge))

    // A continued login response: the shape that grew an unbounded buffer
    // before the login text cap, and the one worth keeping under mutation.
    var continued = LoginResponsePDU()
    continued.transit = false
    continued.continued = true
    continued.currentStage = .loginOperationalNegotiation
    continued.nextStage = .loginOperationalNegotiation
    var opKeys = TextParameters()
    opKeys.append("MaxRecvDataSegmentLength", "262144")
    opKeys.append("MaxBurstLength", "1048576")
    opKeys.append("HeaderDigest", "CRC32C")
    continued.dataSegment = opKeys.encode()
    seeds.append(plain.serialize(continued))

    // A READ CAPACITY(16) payload, for the geometry parser. Bare bytes rather
    // than a PDU: `geometry(fromReadCapacity16:)` takes a data segment.
    var capacity = Data(count: 32)
    capacity.setU8(0x00, 0); capacity.setU8(0x1F, 6); capacity.setU8(0xFF, 7)  // lastLBA
    capacity.setU8(0x00, 8); capacity.setU8(0x00, 9)
    capacity.setU8(0x02, 10); capacity.setU8(0x00, 11)                          // 512-byte blocks
    seeds.append(capacity)

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
