import Foundation
import Combine
import Darwin
import IOKit

struct SystemProcessUsage: Identifiable {
    let pid: pid_t
    let name: String
    let memoryBytes: UInt64
    let cpuPercent: Double?
    let gpuPercent: Double?

    var id: pid_t { pid }
}

@MainActor
final class SystemProcessMonitor: ObservableObject {
    @Published private(set) var processes: [SystemProcessUsage] = []
    @Published private(set) var hasCaptured = false
    @Published private(set) var hasSample = false
    @Published private(set) var gpuAvailable = false

    private var previous: SystemProcessSnapshot?
    private let cpuTimeToNanoseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    func refresh() async {
        let snapshot = await Task.detached(priority: .utility) {
            SystemProcessSnapshot.capture()
        }.value
        guard !Task.isCancelled else { return }

        let elapsed = previous.map { snapshot.time - $0.time } ?? 0
        var gpuByPID: [pid_t: UInt64] = [:]
        if let previous, elapsed > 0 {
            for (id, client) in snapshot.gpuClients {
                guard let old = previous.gpuClients[id], old.pid == client.pid,
                      let process = snapshot.processes[client.pid],
                      let oldProcess = previous.processes[client.pid],
                      process.start == oldProcess.start,
                      client.time >= old.time else { continue }
                gpuByPID[client.pid, default: 0] += client.time - old.time
            }
        }
        processes = snapshot.processes.map { pid, process in
            let old = previous?.processes[pid]
            let cpu: Double?
            if elapsed > 0, let old, old.start == process.start, process.cpuTime >= old.cpuTime {
                cpu = Double(process.cpuTime - old.cpuTime) * cpuTimeToNanoseconds / 1_000_000_000 / elapsed * 100
            } else {
                cpu = nil
            }
            let gpu = elapsed > 0 && snapshot.gpuAvailable && (previous?.gpuAvailable ?? false)
                ? Double(gpuByPID[pid, default: 0]) / 1_000_000_000 / elapsed * 100 : nil
            return SystemProcessUsage(pid: pid, name: process.name, memoryBytes: process.memoryBytes,
                                      cpuPercent: cpu, gpuPercent: gpu)
        }
        gpuAvailable = snapshot.gpuAvailable
        hasSample = previous != nil
        hasCaptured = true
        previous = snapshot
    }
}

private struct SystemProcessSnapshot {
    struct Process {
        let name: String
        let start: UInt64
        let memoryBytes: UInt64
        let cpuTime: UInt64
    }
    struct GPUClient {
        let pid: pid_t
        let time: UInt64
    }

    let time: TimeInterval
    let processes: [pid_t: Process]
    let gpuClients: [UInt64: GPUClient]
    let gpuAvailable: Bool

    static func capture() -> SystemProcessSnapshot {
        let capacity = Int(proc_listallpids(nil, 0)) + 128
        var pids = [pid_t](repeating: 0, count: max(capacity, 0))
        let count = capacity > 128
            ? proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count)) : 0
        var processes: [pid_t: Process] = [:]
        for pid in pids.prefix(max(0, min(Int(count), pids.count))) where pid > 0 {
            var bsd = proc_bsdinfo()
            var task = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  bsd.pbi_status != UInt32(SZOMB),
                  proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) == MemoryLayout<proc_taskinfo>.size else { continue }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            let name = length > 0 ? String(cString: buffer) : "PID \(pid)"
            processes[pid] = Process(name: name, start: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec,
                                     memoryBytes: task.pti_resident_size,
                                     cpuTime: task.pti_total_user + task.pti_total_system)
        }

        // AppUsage 是驱动提供的累计 GPU 时间；按设备客户端分别比较，避免客户端退出导致总数回退。
        var clients: [UInt64: GPUClient] = [:]
        var gpuAvailable = false
        var iterator: io_iterator_t = 0
        if IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                    IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                guard let creator = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                      let usage = IORegistryEntryCreateCFProperty(entry, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] else { continue }
                gpuAvailable = true
                guard creator.hasPrefix("pid "),
                      let pidText = creator.dropFirst(4).split(separator: ",", maxSplits: 1).first,
                      let pid = pid_t(pidText) else { continue }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { continue }
                let time = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                clients[id] = GPUClient(pid: pid, time: time)
            }
        }
        return SystemProcessSnapshot(time: ProcessInfo.processInfo.systemUptime, processes: processes,
                                     gpuClients: clients, gpuAvailable: gpuAvailable)
    }
}
