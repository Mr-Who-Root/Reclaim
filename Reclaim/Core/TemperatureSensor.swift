import Foundation
import IOKit

/// Reads CPU die temperatures from the Apple silicon sensor hub (the IOHID temperature services).
/// The functions are looked up at runtime, so if a future macOS removes them the reading simply goes away.
final class TemperatureSensor {
    /// One shared reader; setting up the sensor client is the expensive part.
    static let shared = TemperatureSensor()

    struct Reading {
        /// Average across the CPU die sensors.
        let average: Double
        /// The hottest single sensor.
        let hottest: Double
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias FloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    private let copyEvent: CopyEventFn?
    private let floatValue: FloatValueFn?
    private var client: CFTypeRef?
    /// CPU sensor services, found once.
    private var cpuServices: [CFTypeRef] = []

    private static let temperatureEvent: Int64 = 15   // kIOHIDEventTypeTemperature

    init() {
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let createSym = dlsym(lib, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(lib, "IOHIDEventSystemClientSetMatching"),
              let servicesSym = dlsym(lib, "IOHIDEventSystemClientCopyServices"),
              let propertySym = dlsym(lib, "IOHIDServiceClientCopyProperty"),
              let eventSym = dlsym(lib, "IOHIDServiceClientCopyEvent"),
              let floatSym = dlsym(lib, "IOHIDEventGetFloatValue") else {
            copyEvent = nil
            floatValue = nil
            return
        }
        copyEvent = unsafeBitCast(eventSym, to: CopyEventFn.self)
        floatValue = unsafeBitCast(floatSym, to: FloatValueFn.self)
        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let setMatching = unsafeBitCast(matchSym, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(servicesSym, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(propertySym, to: CopyPropertyFn.self)

        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        // Vendor usage page 0xff00, usage 5: temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (copyServices(client)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        cpuServices = services.filter { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String else { return false }
            // "PMU tdie…" are the CPU die sensors; other chips name clusters "pACC"/"eACC".
            return name.contains("tdie") || name.contains("pACC") || name.contains("eACC")
        }
    }

    var isAvailable: Bool { !cpuServices.isEmpty }

    func read() -> Reading? {
        guard let copyEvent, let floatValue, !cpuServices.isEmpty else { return nil }
        let field = Int32(Self.temperatureEvent << 16)
        let values: [Double] = cpuServices.compactMap { service in
            guard let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let v = floatValue(event, field)
            // Some sensors report placeholder values; keep only physically sensible ones.
            return (5...130).contains(v) ? v : nil
        }
        guard !values.isEmpty else { return nil }
        return Reading(average: values.reduce(0, +) / Double(values.count), hottest: values.max() ?? 0)
    }

    /// "54 °C", or °F where the locale prefers it.
    static func format(_ celsius: Double) -> String {
        let f = MeasurementFormatter()
        f.numberFormatter.maximumFractionDigits = 0
        return f.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }
}
