import Darwin
import Foundation
import IOKit
import IOKit.storage

extension SystemMetricsSampler {
    static func readDiskCounters() throws -> TransferCounterSample {
        var iterator = io_iterator_t()
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            throw SamplingError.systemCall("IOServiceGetMatchingServices", result)
        }
        defer { IOObjectRelease(iterator) }

        var counters: TransferCounterSample = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            let idResult = IORegistryEntryGetRegistryEntryID(service, &id)
            guard idResult == KERN_SUCCESS else {
                throw SamplingError.systemCall("IORegistryEntryGetRegistryEntryID", idResult)
            }
            var properties: Unmanaged<CFMutableDictionary>?
            let propertyResult = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
            guard propertyResult == KERN_SUCCESS else {
                throw SamplingError.systemCall("IORegistryEntryCreateCFProperties", propertyResult)
            }
            guard let properties,
                  let dictionary = properties.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary[kIOBlockStorageDriverStatisticsKey] as? [String: Any],
                  let read = statistics[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber,
                  let written = statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber else {
                throw SamplingError.invalidValue("disk counters")
            }
            counters[String(id)] = TransferCounters(inbound: read.uint64Value, outbound: written.uint64Value)
        }
        guard IOIteratorIsValid(iterator) != 0 else {
            throw SamplingError.invalidValue("disk devices")
        }
        return counters
    }

    static func readNetworkCounters() throws -> TransferCounterSample {
        guard let interfaces = if_nameindex() else {
            throw SamplingError.systemCall("if_nameindex", errno)
        }
        defer { if_freenameindex(interfaces) }
        var indices: [UInt32] = []
        var cursor = interfaces
        while cursor.pointee.if_index != 0 {
            indices.append(cursor.pointee.if_index)
            cursor = cursor.advanced(by: 1)
        }
        return try networkCounters(indices: indices, read: readNetworkInterface)
    }

    static func networkCounters(
        indices: [UInt32],
        read: (UInt32) throws -> NetworkInterfaceCounters
    ) throws -> TransferCounterSample {
        try networkCounters(from: indices.map { try read($0) })
    }

    private static func readNetworkInterface(index: UInt32) throws -> NetworkInterfaceCounters {
        // The routing-socket counters cap byte totals at 32 bits. IFMIB matches netstat's 64-bit totals.
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
        var data = ifmibdata()
        var length = MemoryLayout<ifmibdata>.size
        let result = withUnsafeMutablePointer(to: &data) { pointer in
            sysctl(&mib, u_int(mib.count), pointer, &length, nil, 0)
        }
        guard result == 0 else {
            throw SamplingError.systemCall("IFMIB_IFDATA", errno)
        }
        guard length == MemoryLayout<ifmibdata>.size else {
            throw SamplingError.invalidValue("network counters")
        }
        let name = withUnsafeBytes(of: data.ifmd_name) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return NetworkInterfaceCounters(
            id: "\(index):\(name)",
            flags: data.ifmd_flags,
            received: data.ifmd_data.ifi_ibytes,
            sent: data.ifmd_data.ifi_obytes
        )
    }

    static func networkCounters(from interfaces: [NetworkInterfaceCounters]) throws -> TransferCounterSample {
        var counters: TransferCounterSample = [:]
        for interface in interfaces {
            let isActive = interface.flags & UInt32(IFF_UP) != 0 && interface.flags & UInt32(IFF_RUNNING) != 0
            let isLoopback = interface.flags & UInt32(IFF_LOOPBACK) != 0
            if isActive, !isLoopback {
                counters[interface.id] = TransferCounters(inbound: interface.received, outbound: interface.sent)
            }
        }
        return counters
    }
}

struct NetworkInterfaceCounters: Equatable, Sendable {
    var id: String
    var flags: UInt32
    var received: UInt64
    var sent: UInt64
}
