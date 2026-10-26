import Foundation

// Decoders are written against real captured output in fixtures/, not against
// Mole's Go structs. Shell- and Go-generated JSON both emit `null` for empty
// slices (see `sensors` in fixtures/status.json), so every collection is
// optional with an empty default.

// Mole's Go structs mark many fields `omitempty` (`purgeable`, `insight`,
// `cleanable`, `memory_bytes`…), so those keys simply vanish when the value is
// zero — and Swift's synthesized decoder ignores a property's default value for
// a missing key, failing the whole snapshot over one absent `purgeable`.
//
// These overloads shadow the container's `decode` for scalars so a missing key
// yields the zero value instead of throwing. Scoped to this app, which decodes
// nothing but Mole's output, where "absent" genuinely does mean zero/empty —
// and it makes the models tolerate the next field upstream marks omitempty.
extension KeyedDecodingContainer {
    func decode(_: Bool.Type, forKey key: Key) throws -> Bool {
        try decodeIfPresent(Bool.self, forKey: key) ?? false
    }
    func decode(_: String.Type, forKey key: Key) throws -> String {
        try decodeIfPresent(String.self, forKey: key) ?? ""
    }
    func decode(_: Int.Type, forKey key: Key) throws -> Int {
        try decodeIfPresent(Int.self, forKey: key) ?? 0
    }
    func decode(_: Int64.Type, forKey key: Key) throws -> Int64 {
        try decodeIfPresent(Int64.self, forKey: key) ?? 0
    }
    func decode(_: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try decodeIfPresent(UInt64.self, forKey: key) ?? 0
    }
    func decode(_: Double.Type, forKey key: Key) throws -> Double {
        try decodeIfPresent(Double.self, forKey: key) ?? 0
    }
}

// MARK: - mo status --json / --watch

struct StatusSnapshot: Decodable {
    var host = ""
    var platform = ""
    var uptime = ""
    var procs: UInt64 = 0
    var hardware = Hardware()
    var healthScore: Int = 0
    var healthScoreMsg = ""
    var cpu = CPU()
    var gpu: [GPU]? = nil
    var memory = Memory()
    var disks: [Disk]? = nil
    var trashSize: UInt64 = 0
    var diskIO = DiskIO()
    var network: [Network]? = nil
    var networkHistory = NetworkHistory()
    var batteries: [Battery]? = nil
    var thermal = Thermal()
    var topProcesses: [ProcessInfo]? = nil
    var processAlerts: [ProcessAlert]? = nil

    enum CodingKeys: String, CodingKey {
        case host, platform, uptime, procs, hardware, cpu, gpu, memory, disks
        case healthScore = "health_score"
        case healthScoreMsg = "health_score_msg"
        case trashSize = "trash_size"
        case diskIO = "disk_io"
        case network
        case networkHistory = "network_history"
        case batteries, thermal
        case topProcesses = "top_processes"
        case processAlerts = "process_alerts"
    }

    struct Hardware: Decodable {
        var model = ""
        var cpuModel = ""
        var totalRAM = ""
        var diskSize = ""
        var osVersion = ""
        enum CodingKeys: String, CodingKey {
            case model
            case cpuModel = "cpu_model"
            case totalRAM = "total_ram"
            case diskSize = "disk_size"
            case osVersion = "os_version"
        }
    }

    struct CPU: Decodable {
        var usage: Double = 0
        var perCore: [Double]? = nil
        var load1: Double = 0
        var load5: Double = 0
        var load15: Double = 0
        var coreCount: Int = 0
        var pCoreCount: Int = 0
        var eCoreCount: Int = 0
        enum CodingKeys: String, CodingKey {
            case usage, load1, load5, load15
            case perCore = "per_core"
            case coreCount = "core_count"
            case pCoreCount = "p_core_count"
            case eCoreCount = "e_core_count"
        }
    }

    struct GPU: Decodable, Identifiable {
        var name = ""
        var usage: Double = -1   // -1 means the platform did not report it
        var coreCount: Int = 0
        var id: String { name }
        enum CodingKeys: String, CodingKey {
            case name, usage
            case coreCount = "core_count"
        }
    }

    struct Memory: Decodable {
        var used: UInt64 = 0
        var total: UInt64 = 0
        var available: UInt64 = 0
        var usedPercent: Double = 0
        var swapUsed: UInt64 = 0
        var swapTotal: UInt64 = 0
        var cached: UInt64 = 0
        var pressure = ""
        enum CodingKeys: String, CodingKey {
            case used, total, available, cached, pressure
            case usedPercent = "used_percent"
            case swapUsed = "swap_used"
            case swapTotal = "swap_total"
        }
    }

    struct Disk: Decodable, Identifiable {
        var mount = ""
        var device = ""
        var used: UInt64 = 0
        var total: UInt64 = 0
        var usedPercent: Double = 0
        var external = false
        var smartStatus = ""
        var purgeable: UInt64 = 0
        var id: String { mount }
        enum CodingKeys: String, CodingKey {
            case mount, device, used, total, external, purgeable
            case usedPercent = "used_percent"
            case smartStatus = "smart_status"
        }
    }

    struct DiskIO: Decodable {
        var readRate: Double = 0
        var writeRate: Double = 0
        enum CodingKeys: String, CodingKey {
            case readRate = "read_rate"
            case writeRate = "write_rate"
        }
    }

    struct Network: Decodable, Identifiable {
        var name = ""
        var rxRateMBs: Double = 0
        var txRateMBs: Double = 0
        var ip = ""
        var id: String { name }
        enum CodingKeys: String, CodingKey {
            case name, ip
            case rxRateMBs = "rx_rate_mbs"
            case txRateMBs = "tx_rate_mbs"
        }
    }

    struct NetworkHistory: Decodable {
        var rxHistory: [Double]? = nil
        var txHistory: [Double]? = nil
        enum CodingKeys: String, CodingKey {
            case rxHistory = "rx_history"
            case txHistory = "tx_history"
        }
    }

    struct Battery: Decodable {
        var percent: Int = 0
        var status = ""
        var timeLeft = ""
        var cycleCount: Int = 0
        enum CodingKeys: String, CodingKey {
            case percent, status
            case timeLeft = "time_left"
            case cycleCount = "cycle_count"
        }
    }

    struct Thermal: Decodable {
        var cpuTemp: Double = 0
        var fanSpeed: Int = 0
        var systemPower: Double = 0
        enum CodingKeys: String, CodingKey {
            case cpuTemp = "cpu_temp"
            case fanSpeed = "fan_speed"
            case systemPower = "system_power"
        }
    }

    struct ProcessInfo: Decodable, Identifiable {
        var pid: Int = 0
        var name = ""
        var cpu: Double = 0
        var memoryBytes: UInt64 = 0
        var id: Int { pid }
        enum CodingKeys: String, CodingKey {
            case pid, name, cpu
            case memoryBytes = "memory_bytes"
        }
    }

    struct ProcessAlert: Decodable, Identifiable {
        var pid: Int = 0
        var name = ""
        var message = ""
        var id: Int { pid }
    }
}

// MARK: - mo analyze --json

struct AnalyzeResult: Decodable {
    var path = ""
    var overview = false
    var entries: [Entry]? = nil
    var largeFiles: [LargeFile]? = nil
    var totalSize: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case path, overview, entries
        case largeFiles = "large_files"
        case totalSize = "total_size"
    }

    struct Entry: Decodable, Identifiable {
        var name = ""
        var path = ""
        var size: Int64 = 0
        var isDir = false
        var insight = false
        var cleanable = false
        var lastAccess: String? = nil
        var id: String { path }
        enum CodingKeys: String, CodingKey {
            case name, path, size, insight, cleanable
            case isDir = "is_dir"
            case lastAccess = "last_access"
        }
    }

    struct LargeFile: Decodable, Identifiable {
        var name = ""
        var path = ""
        var size: Int64 = 0
        var id: String { path }
    }
}

// MARK: - mo uninstall --list

struct InstalledApp: Decodable, Identifiable {
    var name = ""
    var bundleID = ""
    var source = ""          // "App" or "Homebrew"
    var uninstallName = ""   // the exact token `mo uninstall` accepts
    var path = ""
    var size = ""            // pre-formatted, or "--" when not measured
    var id: String { path }

    var isHomebrew: Bool { source == "Homebrew" }
    var hasKnownSize: Bool { size != "--" && !size.isEmpty }

    enum CodingKeys: String, CodingKey {
        case name, source, path, size
        case bundleID = "bundle_id"
        case uninstallName = "uninstall_name"
    }
}

// MARK: - mo history --json

struct HistoryLog: Decodable {
    var limit: Int = 0
    var sessions: [Session]? = nil
    var deletions: [Deletion]? = nil

    struct Session: Decodable, Identifiable {
        var command = ""
        var startedAt = ""
        var endedAt = ""
        var items: Int = 0
        var size = ""            // pre-formatted, e.g. "12.4GB"
        var failedTasks: Int = 0
        var actions = Actions()
        var id: String { command + startedAt }

        enum CodingKeys: String, CodingKey {
            case command, items, size, actions
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case failedTasks = "failed_tasks"
        }

        struct Actions: Decodable {
            var removed = 0, trashed = 0, skipped = 0, failed = 0, rebuilt = 0, other = 0
        }
    }

    struct Deletion: Decodable, Identifiable {
        var timestamp = ""
        var mode = ""
        var status = ""
        var sizeKB: Int64? = nil   // explicitly null when the size was unknown
        var path = ""
        var id: String { timestamp + path }
        enum CodingKeys: String, CodingKey {
            case timestamp, mode, status, path
            case sizeKB = "size_kb"
        }
    }
}
