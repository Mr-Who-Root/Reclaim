import Foundation
import CoreServices

/// Finds app bundles outside the Applications folders — builds in project folders, apps in Downloads and so on —
/// using the Spotlight index, so they can be checked and uninstalled too.
enum AppLocator {
    /// Apps under the Home folder that aren't in an Applications folder, a hidden folder, ~/Library or another app.
    static func appsOutsideApplications() -> [URL] {
        let home = FS.home.standardizedFileURL.path
        let skipPrefixes = [home + "/Library/", home + "/Applications/", home + "/.Trash/"]
        let skipParts = ["/DerivedData/", "/node_modules/", "/Pods/", "/Carthage/"]
        var seen = Set<String>()
        return spotlightApps(in: FS.home).filter { url in
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(home + "/"), !skipPrefixes.contains(where: path.hasPrefix),
                  !skipParts.contains(where: path.contains) else { return false }
            let parts = url.pathComponents.dropFirst(FS.home.pathComponents.count)
            // Hidden folders (build caches like .build) and apps nested inside other bundles.
            guard !parts.contains(where: { $0.hasPrefix(".") }),
                  parts.dropLast().allSatisfy({ !$0.lowercased().hasSuffix(".app") }) else { return false }
            return FileManager.default.fileExists(atPath: path) && seen.insert(path).inserted
        }
    }

    private static func spotlightApps(in root: URL) -> [URL] {
        let text = "kMDItemContentType == 'com.apple.application-bundle'" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, text, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, [root.path] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var urls: [URL] = []
        for i in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String {
                urls.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        return urls
    }
}
