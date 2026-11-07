import Foundation
import CoreML
import CoreAI
import Metal
import CIOReport

public struct HardwareProfile: Sendable {
    public let cpuBrand: String
    public let osVersion: String
    public let coreAIArchitecture: String
    public let aneCoreCount: Int
    public let gpuName: String
    public let unifiedMemoryGB: Int

    public var aneDescription: String {
        if aneCoreCount > 0 {
            return "\(aneCoreCount)-Core Apple Neural Engine (\(coreAIArchitecture))"
        }
        return "Apple Neural Engine (\(coreAIArchitecture))"
    }

    public static func detect() -> HardwareProfile {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brandBytes = [UInt8](repeating: 0, count: max(size, 64))
        sysctlbyname("machdep.cpu.brand_string", &brandBytes, &size, nil, 0)
        let nullIdx = brandBytes.firstIndex(of: 0) ?? brandBytes.endIndex
        let cpuBrand = String(decoding: brandBytes[..<nullIdx], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        let arch = AIModel.deviceArchitectureName

        var aneCores = 0
        var gpuName = MTLCreateSystemDefaultDevice()?.name ?? "Apple Silicon GPU"
        for dev in MLComputeDevice.allComputeDevices {
            switch dev {
            case .neuralEngine(let ane):
                aneCores = max(aneCores, ane.totalCoreCount)
            case .gpu(let gpu):
                if let name = gpu.metalDevice?.name {
                    gpuName = name
                }
            default:
                break
            }
        }

        let memBytes = ProcessInfo.processInfo.physicalMemory
        let memGB = Int(memBytes / (1024 * 1024 * 1024))

        return HardwareProfile(
            cpuBrand: cpuBrand.isEmpty ? "Apple Silicon" : cpuBrand,
            osVersion: "macOS \(osVer)",
            coreAIArchitecture: arch,
            aneCoreCount: aneCores,
            gpuName: gpuName,
            unifiedMemoryGB: memGB
        )
    }
}

public struct TelemetrySample: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let durationSeconds: Double
    /// Each ANE channel's residency-weighted bandwidth, summed across channels.
    public var aneFabricBandwidthGBps: Double?
    /// Each ANE channel's highest occupied bin, summed across channels: an upper bound on the
    /// combined peak, and never below `aneFabricBandwidthGBps`.
    public var anePeakFabricBandwidthGBps: Double?
    public var aneOverdriveResidencyPercent: Double?
    public var gpuPowerWatts: Double?
    public var cpuPowerWatts: Double?

    static func nullable(_ value: Double?) -> Any { value as Any? ?? NSNull() }

    static func json(_ sample: TelemetrySample?) -> [String: Any] {
        let readings: [String: Double?] = [
            "ane_fabric_bw_gbps": sample?.aneFabricBandwidthGBps,
            "ane_peak_bw_gbps": sample?.anePeakFabricBandwidthGBps,
            "ane_vmax_overdrive_pct": sample?.aneOverdriveResidencyPercent,
            "gpu_power_watts": sample?.gpuPowerWatts,
            "cpu_power_watts": sample?.cpuPowerWatts
        ]
        var object = readings.mapValues { nullable($0) }
        let missing = readings.filter { $0.value == nil }.map(\.key).sorted()
        object["status"] = missing.count == readings.count ? "unavailable" : missing.isEmpty ? "available" : "partial"
        object["unavailable_fields"] = missing
        return object
    }
}

public final class SiliconTelemetrySampler: @unchecked Sendable {
    private var subscription: IOReportSubscriptionRef?
    private var subscribedChannels: CFMutableDictionary?
    private var lastRawSample: CFDictionary?
    private var lastSampleTime: CFAbsoluteTime = 0
    private let lock = NSLock()

    public init() {
        setupSubscription()
    }

    private func setupSubscription() {
        // Subscribe to whichever of these groups this chip provides; channel sets vary by chip and OS.
        let candidateGroups = ["Energy Model", "PMP0", "PMP1", "PMP"]
        var mergedChannels: CFMutableDictionary?

        for groupName in candidateGroups {
            if let groupDict = IOReportCopyChannelsInGroup(groupName as CFString, nil, 0, 0, 0)?.takeRetainedValue() {
                if let existing = mergedChannels {
                    IOReportMergeChannels(existing, groupDict, nil)
                } else {
                    mergedChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, groupDict)
                }
            }
        }

        guard let desired = mergedChannels else { return }
        var subbed: Unmanaged<CFMutableDictionary>?
        if let sub = IOReportCreateSubscription(nil, desired, &subbed, 0, nil),
           let subbedDict = subbed?.takeRetainedValue() {
            self.subscription = sub
            self.subscribedChannels = subbedDict
            self.lastRawSample = IOReportCreateSamples(sub, subbedDict, nil)?.takeRetainedValue()
            self.lastSampleTime = CFAbsoluteTimeGetCurrent()
        }
    }

    public struct RawSnapshot: @unchecked Sendable {
        fileprivate let sample: CFDictionary
        fileprivate let time: CFAbsoluteTime
    }

    public func takeSnapshot() -> RawSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let sub = subscription, let subbed = subscribedChannels,
              let s = IOReportCreateSamples(sub, subbed, nil)?.takeRetainedValue() else {
            return nil
        }
        return RawSnapshot(sample: s, time: CFAbsoluteTimeGetCurrent())
    }

    public func computeDelta(from start: RawSnapshot, to end: RawSnapshot) -> TelemetrySample {
        let dt = max(end.time - start.time, 1e-4)
        guard let deltaDict = IOReportCreateSamplesDelta(start.sample, end.sample, nil)?.takeRetainedValue() as NSDictionary?,
              let channels = deltaDict["IOReportChannels"] as? [CFDictionary] else {
            return TelemetrySample(timestamp: Date(), durationSeconds: dt)
        }
        return Self.parseChannels(channels, durationSeconds: dt)
    }

    public func sampleNext() -> TelemetrySample? {
        lock.lock()
        defer { lock.unlock() }
        guard let sub = subscription,
              let subbed = subscribedChannels,
              let prev = lastRawSample,
              let current = IOReportCreateSamples(sub, subbed, nil)?.takeRetainedValue() else {
            return nil
        }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(now - lastSampleTime, 1e-4)
        lastRawSample = current
        lastSampleTime = now

        guard let deltaDict = IOReportCreateSamplesDelta(prev, current, nil)?.takeRetainedValue() as NSDictionary?,
              let channels = deltaDict["IOReportChannels"] as? [CFDictionary] else {
            return nil
        }
        return Self.parseChannels(channels, durationSeconds: dt)
    }

    private static func parseChannels(_ channels: [CFDictionary], durationSeconds dt: Double) -> TelemetrySample {
        var sample = TelemetrySample(timestamp: Date(), durationSeconds: dt)
        var energyCPU: Double?
        var histogramCPU: Double?
        for item in channels {
            let subgroup = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as String? ?? ""
            let name = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String? ?? ""
            if name == "GPU Energy" || name == "CPU Energy" {
                let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as String? ?? ""
                let value = IOReportSimpleGetIntegerValue(item, 0)
                if let watts = wattsFromEnergy(value: value, unit: unit, duration: dt) {
                    if name == "GPU Energy" { sample.gpuPowerWatts = (sample.gpuPowerWatts ?? 0) + watts }
                    else { energyCPU = (energyCPU ?? 0) + watts }
                }
            } else if subgroup == "AF BW", name.hasPrefix("ANE"), name.contains("RD+WR") {
                if let histogram = parseHistogram(item, unit: "GB/s") {
                    // Sum both figures across channels so the peak stays comparable to the average.
                    sample.aneFabricBandwidthGBps = (sample.aneFabricBandwidthGBps ?? 0) + histogram.average
                    sample.anePeakFabricBandwidthGBps = (sample.anePeakFabricBandwidthGBps ?? 0) + histogram.peak
                }
            } else if subgroup == "SOC Floor", name.hasPrefix("ANE"), name.contains("AF-BW") {
                var total = 0.0
                var overdrive = 0.0
                for index in 0..<max(0, IOReportStateGetCount(item)) {
                    let residency = Double(IOReportStateGetResidency(item, index))
                    guard residency >= 0 else { continue }
                    let label = IOReportStateGetNameForIndex(item, index)?.takeUnretainedValue() as String? ?? ""
                    total += residency
                    if label.contains("VMAX") || label.contains("VOVD") { overdrive += residency }
                }
                if total > 0 {
                    sample.aneOverdriveResidencyPercent = max(sample.aneOverdriveResidencyPercent ?? 0, overdrive / total * 100)
                }
            } else if subgroup == "Energy", name.hasPrefix("PACC") || name.hasPrefix("MACC") || name.hasPrefix("EACC") {
                if let histogram = parseHistogram(item, unit: "W") { histogramCPU = (histogramCPU ?? 0) + histogram.average }
            }
        }
        sample.cpuPowerWatts = histogramCPU ?? energyCPU
        return sample
    }

    static func wattsFromEnergy(value: Int64, unit: String, duration: Double) -> Double? {
        let factors: [String: Double] = ["J": 1, "mJ": 1e-3, "uJ": 1e-6, "µJ": 1e-6, "μJ": 1e-6, "nJ": 1e-9, "pJ": 1e-12]
        guard value >= 0, duration.isFinite, duration > 0, let factor = factors[unit.trimmingCharacters(in: .whitespaces)] else { return nil }
        return Double(value) * factor / duration
    }

    private static func parseHistogram(_ item: CFDictionary, unit: String) -> (average: Double, peak: Double)? {
        var bins: [(String, Int64)] = []
        for index in 0..<max(0, IOReportStateGetCount(item)) {
            let label = IOReportStateGetNameForIndex(item, index)?.takeUnretainedValue() as String? ?? ""
            bins.append((label, IOReportStateGetResidency(item, index)))
        }
        return histogram(bins, unit: unit)
    }

    static func histogram(_ bins: [(String, Int64)], unit: String) -> (average: Double, peak: Double)? {
        var weighted = 0.0
        var total = 0.0
        var peak = 0.0
        for (label, count) in bins where count > 0 {
            let clean = label.trimmingCharacters(in: .whitespaces)
            // An explicit unit in the histogram label is required; an unknown
            // state label must not silently turn into a measured zero.
            guard clean.hasSuffix(unit), let value = Double(clean.dropLast(unit.count).trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 else { return nil }
            weighted += value * Double(count)
            total += Double(count)
            peak = max(peak, value)
        }
        guard total > 0 else { return nil }
        return (weighted / total, peak)
    }
}

extension SiliconTelemetrySampler {
    /// Readings since `start`, as responses report them in `ane_telemetry`.
    func json(since start: RawSnapshot?, host: HardwareProfile) -> [String: Any] {
        let delta: TelemetrySample?
        if let start, let end = takeSnapshot() { delta = computeDelta(from: start, to: end) }
        else { delta = nil }
        var json = TelemetrySample.json(delta)
        // Describes the host. Apple's frameworks choose the execution device for each operation.
        json["host_ane"] = host.aneDescription
        return json
    }
}
