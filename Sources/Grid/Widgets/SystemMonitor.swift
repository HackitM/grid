import Darwin
import Foundation
import IOKit.ps
import Observation

/// Measured system telemetry for widgets. Samples only while at least one widget that needs it
/// is on screen (reference-counted), every 2 seconds. Every number shown comes from the kernel.
@Observable
@MainActor
final class SystemMonitor {
    static let shared = SystemMonitor()
    static let interval: TimeInterval = 2
    static let historyLength = 60

    private(set) var cpu: Double?                 // 0...1, all cores
    private(set) var cpuHistory: [Double] = []
    private(set) var memoryUsed: UInt64?          // bytes: active + wired + compressed
    private(set) var memoryHistory: [Double] = [] // fraction of physical memory
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    private(set) var load: (Double, Double, Double)?
    private(set) var net: [String: NetRate] = [:] // interface -> rate
    private(set) var netHistory: [String: [Double]] = [:]  // download bytes/s
    private(set) var power: PowerInfo?
    private(set) var sampledAt: Date?

    struct NetRate: Equatable { var rx: Double; var tx: Double; var ipv4: String? }
    struct PowerInfo: Equatable {
        var hasBattery: Bool
        var percent: Int?
        var charging: Bool
        var onAC: Bool
        var minutesRemaining: Int?   // to empty (on battery) or to full (charging)
    }

    @ObservationIgnored private var subscribers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTicks: [(UInt32, UInt32, UInt32, UInt32)] = []
    @ObservationIgnored private var lastNet: [String: (rx: UInt32, tx: UInt32, at: Date)] = [:]
    /// `mach_host_self()` hands out a new reference to the host port on every call; asking once
    /// keeps a monitor that samples for days from accumulating them.
    private static let hostPort = mach_host_self()

    func subscribe() {
        subscribers += 1
        if timer == nil {
            sample()
            let t = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            t.tolerance = 0.2      // lets macOS batch this wake-up with others
            timer = t
        }
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 { timer?.invalidate(); timer = nil }
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        var l = [Double](repeating: 0, count: 3)
        if getloadavg(&l, 3) == 3 { load = (l[0], l[1], l[2]) }
        sampleNetwork()
        // Assigning an @Observable property redraws its readers even when the value is the same.
        let p = Self.readPower()
        if p != power { power = p }
        sampledAt = Date()
    }

    private func push(_ v: Double, into a: inout [Double]) {
        a.append(v)
        if a.count > Self.historyLength { a.removeFirst(a.count - Self.historyLength) }
    }

    private func sampleCPU() {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(Self.hostPort, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var ticks: [(UInt32, UInt32, UInt32, UInt32)] = []
        for i in 0..<Int(count) {
            let b = Int(CPU_STATE_MAX) * i
            ticks.append((UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]), UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                          UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]), UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])))
        }
        if lastTicks.count == ticks.count {
            var busy: UInt64 = 0, total: UInt64 = 0
            for (n, o) in zip(ticks, lastTicks) {
                let u = UInt64(n.0 &- o.0), s = UInt64(n.1 &- o.1), i = UInt64(n.2 &- o.2), ni = UInt64(n.3 &- o.3)
                busy += u + s + ni
                total += u + s + i + ni
            }
            if total > 0 {
                let v = Double(busy) / Double(total)
                cpu = v
                push(v, into: &cpuHistory)
            }
        }
        lastTicks = ticks
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(Self.hostPort, HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        memoryUsed = used
        push(Double(used) / Double(max(memoryTotal, 1)), into: &memoryHistory)
    }

    private func sampleNetwork() {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return }
        defer { freeifaddrs(ifap) }
        var counters: [String: (UInt32, UInt32)] = [:]
        var ips: [String: String] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let name = String(cString: cur.pointee.ifa_name)
            if let addr = cur.pointee.ifa_addr {
                if addr.pointee.sa_family == UInt8(AF_LINK), let data = cur.pointee.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    counters[name] = (d.ifi_ibytes, d.ifi_obytes)
                } else if addr.pointee.sa_family == UInt8(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        ips[name] = String(cString: host)
                    }
                }
            }
            p = cur.pointee.ifa_next
        }
        let now = Date()
        var rates: [String: NetRate] = [:]
        for (name, (rx, tx)) in counters where name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("bridge") || ips[name] != nil {
            if let last = lastNet[name] {
                let dt = max(now.timeIntervalSince(last.at), 0.1)
                // 32-bit kernel counters wrap at 4 GiB; &- handles one wrap per interval.
                let r = NetRate(rx: Double(rx &- last.rx) / dt, tx: Double(tx &- last.tx) / dt, ipv4: ips[name])
                rates[name] = r
                var h = netHistory[name] ?? []
                push(r.rx, into: &h)
                netHistory[name] = h
            }
            lastNet[name] = (rx, tx, now)
        }
        if rates != net { net = rates }
    }

    /// Busiest active interface with an IPv4 address (what "auto" shows).
    var primaryInterface: String? {
        net.filter { $0.value.ipv4 != nil && !$0.key.hasPrefix("lo") }
            .max { ($0.value.rx + $0.value.tx, $1.key) < ($1.value.rx + $1.value.tx, $0.key) }?.key
            ?? net.keys.sorted().first { $0.hasPrefix("en") }
    }

    static func readPower() -> PowerInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let onAC = providing == kIOPMACPowerKey
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let tte = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            let ttf = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
            let minutes = charging ? ttf : (onAC ? -1 : tte)
            return PowerInfo(hasBattery: true, percent: max > 0 ? cur * 100 / max : nil, charging: charging,
                             onAC: onAC, minutesRemaining: minutes > 0 ? minutes : nil)
        }
        return PowerInfo(hasBattery: false, percent: nil, charging: false, onAC: true, minutesRemaining: nil)
    }
}

enum Volumes {
    struct Info: Equatable { var name: String; var total: Int64; var available: Int64 }

    static func mounted() -> [URL] {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                               options: [.skipHiddenVolumes]) ?? [URL(fileURLWithPath: "/")]
    }

    static func info(_ url: URL) -> Info? {
        guard let v = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]),
              let total = v.volumeTotalCapacity else { return nil }
        let avail = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return Info(name: v.volumeName ?? url.lastPathComponent, total: Int64(total), available: avail)
    }
}
