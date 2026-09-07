import Foundation
import AppKit

// MARK: - Tool layer types

public enum ToolPermission: Sendable, Equatable {
    case readOnly
    case destructive
}

public struct ToolArguments: Sendable {
    public let raw: [String: String]

    public init(raw: [String: String] = [:]) { self.raw = raw }

    public func string(_ key: String) -> String? { raw[key] }
    public func int64(_ key: String) -> Int64? { raw[key].flatMap(Int64.init) }
    public func double(_ key: String) -> Double? { raw[key].flatMap(Double.init) }
    public func paths(_ key: String = "paths") -> [String] {
        (raw[key] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
}

public enum ToolResult: Sendable {
    case text(String)
    case rows([[String: String]])
    case plan(CleanupPlan)
    case error(String)
}

public enum ToolError: Error, Equatable {
    case approvalRequired(String)
    case notAvailable(String)
    case invalidArguments(String)
}

/// Services and data available to tools during one invocation.
public struct ToolContext: @unchecked Sendable {
    public var scanResult: ScanResult?
    public var candidates: [CleanupCandidate]
    public var duplicates: [DuplicateGroup]
    public var history: HistoryStore?
    public var safety: SafetyEngine
    public var approval: ApprovalToken?

    public init(scanResult: ScanResult? = nil, candidates: [CleanupCandidate] = [],
                duplicates: [DuplicateGroup] = [], history: HistoryStore? = nil,
                safety: SafetyEngine = SafetyEngine(), approval: ApprovalToken? = nil) {
        self.scanResult = scanResult
        self.candidates = candidates
        self.duplicates = duplicates
        self.history = history
        self.safety = safety
        self.approval = approval
    }
}

// MARK: - Protocol & policy

/// RoboOS agents operate through explicit typed tools only — never shell
/// commands, never raw filesystem access (spec §33–34).
public protocol AgentTool: Sendable {
    var name: String { get }
    var permission: ToolPermission { get }
    var description: String { get }
    func execute(_ arguments: ToolArguments, context: ToolContext) async throws -> ToolResult
}

/// Deterministic authorization gate. A destructive tool without a live approval
/// token is denied — no agent (or LLM) can authorize deletion itself.
public enum PolicyEngine: Sendable {
    public enum Decision: Equatable, Sendable {
        case allowed
        case denied(reason: String)
    }

    public static func authorize(tool: AgentTool, context: ToolContext) -> Decision {
        switch tool.permission {
        case .readOnly:
            return .allowed
        case .destructive:
            guard context.approval != nil else {
                return .denied(reason: "Destructive tool '\(tool.name)' requires an explicit user approval token.")
            }
            return .allowed
        }
    }
}

// MARK: - Tools

public struct ListLargeFilesTool: AgentTool {
    public let name = "listLargeFiles"
    public let permission = ToolPermission.readOnly
    public let description = "List the largest files from the most recent scan."
    public init() {}

    public func execute(_ arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard let result = context.scanResult else { throw ToolError.notAvailable("No scan has been completed yet.") }
        let limit = Int(arguments.int64("limit") ?? 20)
        return .rows(result.largestFiles.prefix(Int(max(1, min(300, limit)))).map {
            ["name": $0.name, "path": $0.url.path, "size": String($0.size)]
        })
    }
}

public struct EstimateRecoverableSpaceTool: AgentTool {
    public let name = "estimateRecoverableSpace"
    public let permission = ToolPermission.readOnly
    public let description = "Summarize recoverable space by risk level."
    public init() {}

    public func execute(_ arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard !context.candidates.isEmpty || context.scanResult != nil else {
            throw ToolError.notAvailable("No candidates available — run a scan first.")
        }
        var lines: [String] = []
        for risk in [RiskLevel.green, .yellow, .orange] {
            let items = context.candidates.filter { $0.risk == risk }
            let bytes = items.reduce(0) { $0 + $1.sizeBytes }
            if !items.isEmpty {
                lines.append("\(risk.displayName): \(items.count) items, \(Format.bytes(bytes))")
            }
        }
        return .text(lines.isEmpty ? "No cleanup candidates found." : lines.joined(separator: "\n"))
    }
}

public struct GenerateCleanupPlanTool: AgentTool {
    public let name = "generateCleanupPlan"
    public let permission = ToolPermission.readOnly
    public let description = "Build a cleanup plan (quick/smart/deep/target). Planning is read-only; execution needs approval."
    public init() {}

    public func execute(_ arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let mode: CleanMode
        switch arguments.string("mode") {
        case "quick": mode = .quick
        case "smart": mode = .smart
        case "deep": mode = .deep
        case "target":
            guard let gb = arguments.double("gigabytes") else { throw ToolError.invalidArguments("target mode requires 'gigabytes'") }
            mode = .target(gigabytes: gb)
        default: mode = .smart
        }
        return .plan(RoboPlanner.buildPlan(from: context.candidates, mode: mode))
    }
}

public struct QueryStorageHistoryTool: AgentTool {
    public let name = "queryStorageHistory"
    public let permission = ToolPermission.readOnly
    public let description = "List stored snapshots."
    public init() {}

    public func execute(_ arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard let history = context.history else { throw ToolError.notAvailable("History store unavailable.") }
        let snapshots = history.loadSnapshots()
        return .rows(snapshots.suffix(30).map {
            ["date": String($0.date.timeIntervalSince1970), "usedBytes": String($0.usedBytes), "root": $0.rootPath]
        })
    }
}

public struct InspectFileMetadataTool: AgentTool {
    public let name = "inspectFileMetadata"
    public let permission = ToolPermission.readOnly
    public let description = "Inspect size/mtime metadata for a path."
    public init() {}

    public func execute(_ arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard let path = arguments.string("path") else { throw ToolError.invalidArguments("path is required") }
        guard let fp = await ItemFingerprint.capture(path: path) else { throw ToolError.notAvailable("Item not found: \(path)") }
        return .text("\(path) — \(Format.bytes(fp.size)), modified \(Date(timeIntervalSince1970: fp.mtime))")
    }
}

public struct FindDuplicatesTool: AgentTool {
    public let name = "findDuplicates"
    public let permission = ToolPermission.readOnly
    public let description = "Summarize verified duplicate groups from the last duplicate scan."
    public init() {}

    public func execute(_ arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard !context.duplicates.isEmpty else { throw ToolError.notAvailable("No duplicate scan results available.") }
        let wasted = context.duplicates.reduce(0) { $0 + $1.wastedBytes }
        return .text("\(context.duplicates.count) duplicate groups, \(Format.bytes(wasted)) wasted.")
    }
}

/// The only destructive tool. Requires: policy approval token in context,
/// token coverage of every path, and per-item SafetyEngine validation.
public struct MoveToTrashTool: AgentTool {
    public let name = "moveToTrash"
    public let permission = ToolPermission.destructive
    public let description = "Move approved items to the Trash. Requires an approval token covering every path."
    public init() {}

    public func execute(_ arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        let paths = arguments.paths()
        guard !paths.isEmpty else { throw ToolError.invalidArguments("paths is required") }
        guard let approval = context.approval else {
            throw ToolError.approvalRequired("An explicit user approval token is required to trash items.")
        }
        let executor = TrashExecutor(safety: context.safety, history: context.history)
        let items = paths.map {
            TrashedItem(url: URL(fileURLWithPath: $0), kind: "agent", userInitiated: false, approval: approval)
        }
        let outcome = await executor.trashItems(items)
        return .text("Trashed \(outcome.trashedCount) items, freed \(Format.bytes(outcome.freedBytes)). "
            + "Blocked \(outcome.blockedCount), failed \(outcome.failedCount).")
    }
}

public struct RevealInFinderTool: AgentTool {
    public let name = "revealInFinder"
    public let permission = ToolPermission.readOnly
    public let description = "Reveal a path in Finder (no deletion)."
    public init() {}

    public func execute(_ arguments: ToolArguments, context: ToolContext) async throws -> ToolResult {
        guard let path = arguments.string("path") else { throw ToolError.invalidArguments("path is required") }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
        return .text("Revealed in Finder.")
    }
}

/// The registry agents (and the Phase-2 assistant) may invoke.
public enum ToolRegistry {
    public static let all: [any AgentTool] = [
        ListLargeFilesTool(),
        EstimateRecoverableSpaceTool(),
        GenerateCleanupPlanTool(),
        QueryStorageHistoryTool(),
        InspectFileMetadataTool(),
        FindDuplicatesTool(),
        MoveToTrashTool(),
        RevealInFinderTool(),
    ]
}
