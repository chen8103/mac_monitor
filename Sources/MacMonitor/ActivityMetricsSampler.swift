import Darwin
import Foundation
import IOKit
import IOKit.storage

extension SystemMetricsSampler {
    static func readDiskCounters() throws -> TransferCounters {
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

        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var deviceCount = 0

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS,
                let properties,
                let dictionary = properties.takeRetainedValue() as? [String: Any],
                let statistics = dictionary[kIOBlockStorageDriverStatisticsKey] as? [String: Any] else {
                continue
            }

            if let read = statistics[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber,
               let written = statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber {
                bytesRead += read.uint64Value
                bytesWritten += written.uint64Value
                deviceCount += 1
            }
        }

        guard deviceCount > 0 else {
            throw SamplingError.invalidValue("disk counters")
        }
        return TransferCounters(inbound: bytesRead, outbound: bytesWritten)
    }

    static func readNetworkCounters() throws -> TransferCounters {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else {
            throw SamplingError.systemCall("getifaddrs", errno)
        }
        defer { freeifaddrs(addresses) }

        var downloaded: UInt64 = 0
        var uploaded: UInt64 = 0
        var interfaceCount = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = addresses

        while let interface = cursor {
            let flags = Int32(interface.pointee.ifa_flags)
            let isActive = flags & IFF_UP != 0 && flags & IFF_RUNNING != 0
            let isLoopback = flags & IFF_LOOPBACK != 0

            if isActive,
               !isLoopback,
               let address = interface.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               let rawData = interface.pointee.ifa_data {
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                downloaded += UInt64(data.ifi_ibytes)
                uploaded += UInt64(data.ifi_obytes)
                interfaceCount += 1
            }
            cursor = interface.pointee.ifa_next
        }

        guard interfaceCount > 0 else {
            throw SamplingError.invalidValue("network interfaces")
        }
        return TransferCounters(inbound: downloaded, outbound: uploaded)
    }
}
