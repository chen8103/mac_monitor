import Darwin
import Foundation

enum SamplingError: Error, LocalizedError {
    case systemCall(String, Int32)
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case let .systemCall(name, code):
            "\(name) 读取失败（\(code)）"
        case let .invalidValue(name):
            "\(name) 返回了无效数据"
        }
    }
}

enum SystemMetricsSampler {
    static func readProfile() throws -> SystemProfile {
        SystemProfile(
            hostName: ProcessInfo.processInfo.hostName,
            coreCount: Int(try readSysctlValue("hw.logicalcpu", defaultValue: Int32(0))),
            darwinVersion: try readSysctlString("kern.osrelease"),
            architecture: try readSysctlString("hw.machine"),
            totalMemory: try readSysctlValue("hw.memsize", defaultValue: UInt64(0))
        )
    }

    static func readCPUTicks() throws -> [CPUTicks] {
        try withHostPort { host in
            var processorCount = mach_msg_type_number_t()
            var info: processor_info_array_t?
            var infoCount = mach_msg_type_number_t()
            let result = host_processor_info(
                host,
                PROCESSOR_CPU_LOAD_INFO,
                &processorCount,
                &info,
                &infoCount
            )
            defer {
                if let info {
                    let byteCount = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size)
                    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), byteCount)
                }
            }

            guard result == KERN_SUCCESS, let info else {
                throw SamplingError.systemCall("host_processor_info", result)
            }

            let ticksPerCore = Int(CPU_STATE_MAX)
            guard processorCount > 0, Int(infoCount) == Int(processorCount) * ticksPerCore else {
                throw SamplingError.invalidValue("CPU ticks")
            }

            return (0 ..< Int(processorCount)).map { core in
                let offset = core * ticksPerCore
                return CPUTicks(
                    user: UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)])),
                    system: UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)])),
                    idle: UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)])),
                    nice: UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
                )
            }
        }
    }

    static func readUsedMemory() throws -> UInt64 {
        let statistics = try withHostPort { host in
            var statistics = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &statistics) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    host_statistics64(host, HOST_VM_INFO64, rebound, &count)
                }
            }
            guard result == KERN_SUCCESS else {
                throw SamplingError.systemCall("host_statistics64", result)
            }
            return statistics
        }

        let pageSize = try readSysctlValue("hw.pagesize", defaultValue: UInt64(0))
        let used = usedBytes(
            active: UInt64(statistics.active_count),
            wired: UInt64(statistics.wire_count),
            compressor: UInt64(statistics.compressor_page_count),
            pageSize: pageSize
        )
        return min(used, try readSysctlValue("hw.memsize", defaultValue: UInt64(0)))
    }

    static func readLoadAverages() throws -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        let count = values.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, 3)
        }
        guard count == 3 else {
            throw SamplingError.systemCall("getloadavg", errno)
        }
        return values
    }

    static func usedBytes(active: UInt64, wired: UInt64, compressor: UInt64, pageSize: UInt64) -> UInt64 {
        (active + wired + compressor) * pageSize
    }

    private static func readSysctlValue<T>(_ name: String, defaultValue: T) throws -> T {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
            throw SamplingError.systemCall(name, errno)
        }
        guard size == MemoryLayout<T>.size else {
            throw SamplingError.invalidValue(name)
        }

        var value = defaultValue
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            sysctlbyname(name, pointer, &size, nil, 0)
        }
        guard result == 0 else {
            throw SamplingError.systemCall(name, errno)
        }
        return value
    }

    private static func withHostPort<T>(_ body: (host_t) throws -> T) throws -> T {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        return try body(host)
    }

    private static func readSysctlString(_ name: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            throw SamplingError.systemCall(name, errno)
        }

        var buffer = [CChar](repeating: 0, count: size)
        let result = sysctlbyname(name, &buffer, &size, nil, 0)
        guard result == 0 else {
            throw SamplingError.systemCall(name, errno)
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
