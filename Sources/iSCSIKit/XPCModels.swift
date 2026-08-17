//
//  XPCModels.swift
//  Data transfer objects for the daemon's XPC surface.
//
//  These cross the wire as `Data` holding Codable structs, not as
//  NSSecureCoding classes. NSXPC can carry object graphs, but every method that
//  returns a collection then needs its classes allowlisted with
//  setClasses(_:for:argumentIndex:ofReply:) — a step the compiler does not
//  check, that is invisible until the call silently fails at runtime, and that
//  has to be repeated for every new method. Encoding to Data moves the problem
//  into Codable, where the compiler does check it.
//

import Foundation

/// Identity and liveness of the running daemon.
///
/// The setup flow's whole question is "is the thing I registered actually alive
/// and is it the build I shipped?", and neither half is answerable from
/// `SMAppService.status`: launchd reporting `.enabled` only means it is willing
/// to start the job. This is the round trip that distinguishes "approved and
/// working" from "approved and crashing", which need opposite instructions.
public struct DaemonInfo: Codable, Sendable, Equatable {
    /// CFBundleShortVersionString of the app bundle the daemon shipped inside,
    /// or "dev" when it is running loose from `swift run`.
    public let version: String
    /// CFBundleVersion, to tell two builds of the same marketing version apart.
    public let build: String
    public let pid: Int32
    /// True when the daemon skipped its XPC code-signing check because it was
    /// built with DEBUG. Surfaced so the UI can say so rather than looking
    /// identical to a hardened one.
    public let authorizationRelaxed: Bool

    public init(version: String, build: String, pid: Int32, authorizationRelaxed: Bool) {
        self.version = version
        self.build = build
        self.pid = pid
        self.authorizationRelaxed = authorizationRelaxed
    }
}

/// A target the user has configured. Persisted by the daemon; the CHAP *secret*
/// is deliberately not a field — it lives in the keychain and is referenced by
/// `id`, so a targets file that leaks discloses no credentials.
public struct TargetRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var host: String
    public var port: UInt16
    public var targetIQN: String
    public var lun: UInt64
    /// CHAP username, if the target requires authentication. Keyed by `id` in
    /// the keychain rather than by username, because two targets can legitimately
    /// share a username with different secrets.
    public var chapUser: String?
    /// Mutual CHAP: we authenticate the target too.
    public var mutualChapUser: String?
    public var autoAttach: Bool
    /// Durability trade-off, as the user configured it. nil (the default, and
    /// what every pre-0.3.9 record decodes as) means write-through: FUA on
    /// every write. N > 0 means no FUA and a SYNCHRONIZE CACHE every N
    /// seconds; 0 means the user has declared the target's cache non-volatile
    /// and wants no periodic flush at all. See `FlushPolicy`.
    public var flushIntervalSeconds: Int?
    /// Pins this LUN's readahead depth, overriding the adaptive controller.
    ///
    /// nil — every record, unless someone hand-edited this file — means no
    /// override: `ReadaheadDepthController` sets the depth from measured waste.
    /// There is no UI for this and it is not expected to be set; it exists so a
    /// depth can be held still for debugging or A/B measurement, which is how
    /// the evidence for removing the setting was gathered in the first place.
    /// See `WorkloadProfile`.
    public var workloadProfile: String?

    public init(id: String, displayName: String, host: String, port: UInt16 = 3260,
                targetIQN: String, lun: UInt64 = 0, chapUser: String? = nil,
                mutualChapUser: String? = nil, autoAttach: Bool = false,
                flushIntervalSeconds: Int? = nil, workloadProfile: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.targetIQN = targetIQN
        self.lun = lun
        self.chapUser = chapUser
        self.mutualChapUser = mutualChapUser
        self.autoAttach = autoAttach
        self.flushIntervalSeconds = flushIntervalSeconds
        self.workloadProfile = workloadProfile
    }
}

/// How much speculation a LUN's access pattern justifies.
///
/// Readahead only pays on streams, and it stops paying well before it stops
/// costing. Measured on one array in one session, a soak that is 46%
/// sequential runs, 21% writes and 17% seeks:
///
///     budget   depth   blocks/600s   hit    unused   wasted/read
///     1 MiB        4       151,643   93.1%    11.1%        0.115x
///     4 MiB       16       212,710   93.2%    32.4%        0.443x
///     8 MiB       32       212,033   93.2%    48.8%        0.882x
///
/// The hit rate never moves, so depth is not buying residency — only queue
/// occupancy at the target, where speculation that a write or a seek will throw
/// away sits ahead of reads that are real. 8 MiB bought nothing over 4 and
/// wasted twice the bandwidth. A guest booting a VM image is locality without
/// streams and wastes proportionally more; a media file is the case the deep
/// window was built for.
///
/// These are no longer a user-facing choice. Measurement is why: the throughput
/// column above moved 2.4x between two consecutive days on identical code, and
/// 48% within a single morning at a fixed depth, while `unused` reproduced to
/// the digit. A setting whose options differ only in wasted bandwidth is not a
/// choice worth offering, so `ReadaheadDepthController` steers depth from that
/// waste directly and these survive only as a debugging override in
/// targets.json.
///
/// The stored form is the symbolic name rather than the byte count, unlike
/// `TargetRecord.flushIntervalSeconds` where the number is itself the user's
/// choice. Here the number is derived from a three-way pick, so storing bytes
/// would let the file hold values the editor cannot represent.
public enum WorkloadProfile: String, Sendable {
    /// Scattered small reads: a database, or a VM image being booted.
    case randomAccess = "random"
    /// A middling override. No longer a default — nothing is, since an
    /// unpinned target is steered by `ReadaheadDepthController`.
    case mixed = "mixed"
    /// Long sequential reads: media files, backups, bulk copies.
    case sequential = "sequential"

    /// Readahead budget. `ReadaheadPolicy` divides this by the chunk size to
    /// get the depth cap, so at the usual 256 KiB chunk these are depths 2, 8
    /// and 16.
    public var readaheadBudgetBytes: Int {
        switch self {
        case .randomAccess: return 512 << 10
        case .mixed: return 2 << 20
        case .sequential: return 4 << 20
        }
    }

    /// The readahead budget a stored `TargetRecord.workloadProfile` pins, or
    /// nil for no override — which is the normal case, and means
    /// `ReadaheadDepthController` chooses the depth instead. An unrecognised
    /// string pins nothing: targets.json is hand-editable, and a typo must not
    /// silently fix how deeply a volume reads ahead.
    public static func pinnedBudgetBytes(stored: String?) -> Int? {
        stored.flatMap(WorkloadProfile.init(rawValue:))?.readaheadBudgetBytes
    }
}

/// What keeps an acknowledged write from being a lie.
///
/// FSKit never delivers a barrier (see the header of iSCSIFSExtension.swift),
/// so the initiator cannot know when the filesystem above the disk image
/// wanted a flush. `.writeThrough` closes that hole per-write with FUA and is
/// the only mode that preserves APFS's ordering assumptions; the other two
/// trade that away and are only genuinely safe when the target's cache is
/// non-volatile. Derived from `TargetRecord.flushIntervalSeconds` rather than
/// stored, so the persisted format stays a plain optional integer.
public enum FlushPolicy: Sendable, Equatable {
    /// Every WRITE carries FUA. The default.
    case writeThrough
    /// No FUA; SYNCHRONIZE CACHE every `seconds`, and always on detach.
    /// Bounds staleness after a power cut, but not corruption: between
    /// flushes the target destages in arbitrary order.
    case interval(seconds: Int)
    /// No FUA and no periodic flush; the user has declared the target's cache
    /// non-volatile. Still flushes on detach.
    case never

    public init(intervalSeconds: Int?) {
        switch intervalSeconds {
        case nil: self = .writeThrough
        case 0: self = .never
        case let n? where n > 0: self = .interval(seconds: n)
        // The record file is hand-editable; a nonsense value must not
        // silently become a durability downgrade.
        case .some: self = .writeThrough
        }
    }
}

/// One target as advertised by a portal's SendTargets response.
public struct DiscoveredTargetInfo: Codable, Sendable, Equatable {
    public var targetIQN: String
    public var addresses: [String]

    public init(targetIQN: String, addresses: [String]) {
        self.targetIQN = targetIQN
        self.addresses = addresses
    }
}

/// One LUN behind a target, from REPORT LUNS.
public struct LUNInfo: Codable, Sendable, Equatable {
    public var lun: UInt64
    public var blockSize: Int?
    public var blockCount: UInt64?

    public var byteCount: UInt64? {
        guard let blockSize, let blockCount else { return nil }
        return UInt64(blockSize) * blockCount
    }

    public init(lun: UInt64, blockSize: Int? = nil, blockCount: UInt64? = nil) {
        self.lun = lun
        self.blockSize = blockSize
        self.blockCount = blockCount
    }
}

/// Everything known about a live session.
///
/// This is the diagnostic surface, and it is deliberately generous. Every field
/// here already existed inside the daemon and none of it had ever crossed XPC,
/// which meant a bug report could say "it was slow" but not "firstBurstLength
/// negotiated down to 64 KiB and the session recovered four times". The data
/// costs nothing to send and is the difference between an actionable report and
/// a guess.
public struct SessionInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { handle }
    public var handle: String
    public var targetIQN: String
    public var lun: UInt64
    public var blockSize: Int?
    public var blockCount: UInt64?
    /// nil when the target returned no caching mode page.
    public var writeCacheEnabled: Bool?
    /// Whether we force FUA on every write, which is what makes durability
    /// independent of a flush the FSKit path never receives.
    public var writeThrough: Bool
    /// How many times this session has been transparently rebuilt under a
    /// dropped connection. Non-zero is not an error, but it is the first thing
    /// worth knowing when someone reports intermittent slowness.
    public var recoveryCount: Int
    /// Negotiated login parameters, as label/value pairs ready to display.
    /// A dictionary rather than a mirror of OperationalParameters so that adding
    /// a parameter to the engine does not break the wire format.
    public var negotiated: [String: String]

    public var byteCount: UInt64? {
        guard let blockSize, let blockCount else { return nil }
        return UInt64(blockSize) * blockCount
    }

    public init(handle: String, targetIQN: String, lun: UInt64,
                blockSize: Int? = nil, blockCount: UInt64? = nil,
                writeCacheEnabled: Bool? = nil, writeThrough: Bool,
                recoveryCount: Int, negotiated: [String: String]) {
        self.handle = handle
        self.targetIQN = targetIQN
        self.lun = lun
        self.blockSize = blockSize
        self.blockCount = blockCount
        self.writeCacheEnabled = writeCacheEnabled
        self.writeThrough = writeThrough
        self.recoveryCount = recoveryCount
        self.negotiated = negotiated
    }
}

extension OperationalParameters {
    /// Display pairs for the Sessions detail pane. Ordered by how often they
    /// explain a performance question, not by their order in the RFC.
    public var displayPairs: [String: String] {
        var out: [String: String] = [
            "MaxBurstLength": String(maxBurstLength),
            "FirstBurstLength": String(firstBurstLength),
            "MaxRecvDataSegmentLength (target)": String(targetMaxRecvDataSegmentLength),
            "MaxRecvDataSegmentLength (initiator)": String(initiatorMaxRecvDataSegmentLength),
            "ImmediateData": immediateData ? "Yes" : "No",
            "InitialR2T": initialR2T ? "Yes" : "No",
            "MaxOutstandingR2T": String(maxOutstandingR2T),
            "HeaderDigest": headerDigest ? "CRC32C" : "None",
            "DataDigest": dataDigest ? "CRC32C" : "None",
            "ErrorRecoveryLevel": String(errorRecoveryLevel),
            "MaxConnections": String(maxConnections),
            "DefaultTime2Wait": String(defaultTime2Wait),
            "DefaultTime2Retain": String(defaultTime2Retain),
            "DataPDUInOrder": dataPDUInOrder ? "Yes" : "No",
            "DataSequenceInOrder": dataSequenceInOrder ? "Yes" : "No",
        ]
        if let tag = targetPortalGroupTag { out["TargetPortalGroupTag"] = String(tag) }
        if let alias = targetAlias { out["TargetAlias"] = alias }
        return out
    }
}
