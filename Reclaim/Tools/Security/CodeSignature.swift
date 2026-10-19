import Foundation
import Security
import SwiftUI

/// How a program is signed, from most to least trustworthy.
enum SecuritySignatureStatus: Int, CaseIterable, Comparable, Hashable {
    case apple, appStore, notarized, signedNotNotarized, adHoc, unsigned, invalid

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    enum Severity: Int, Comparable {
        case ok, info, attention
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    var severity: Severity {
        switch self {
        case .apple, .appStore, .notarized: return .ok
        case .signedNotNotarized, .adHoc: return .info
        case .unsigned, .invalid: return .attention
        }
    }

    var title: String {
        switch self {
        case .apple: return "Part of macOS"
        case .appStore: return "From the App Store"
        case .notarized: return "Signed and notarised by Apple"
        case .signedNotNotarized: return "Signed, but not notarised"
        case .adHoc: return "Ad-hoc signature only"
        case .unsigned: return "Unsigned"
        case .invalid: return "Signature does not match the code"
        }
    }

    var explanation: String {
        switch self {
        case .apple:
            return "Apple signed this as part of the operating system."
        case .appStore:
            return "Distributed through the Mac App Store, so Apple reviewed it and it runs sandboxed."
        case .notarized:
            return "A known developer signed it and Apple scanned it for known malicious content before it was distributed."
        case .signedNotNotarized:
            return "A known developer signed it, but it carries no notarisation ticket. Common for older or internally distributed software."
        case .adHoc:
            return "It carries a signature that identifies no developer, so there is nobody to hold responsible for it. Locally built software often looks like this."
        case .unsigned:
            return "It carries no signature, so macOS cannot tell you who made it or whether it has been altered. Scripts and self-built tools are normally unsigned."
        case .invalid:
            return "It is signed, but the signature no longer matches what is on disk. Something changed it after it was signed — an update gone wrong, a modification, or tampering."
        }
    }

    var icon: String {
        switch self {
        case .apple: return "apple.logo"
        case .appStore: return "bag.fill"
        case .notarized: return "checkmark.seal.fill"
        case .signedNotNotarized: return "signature"
        case .adHoc: return "person.crop.circle.badge.questionmark"
        case .unsigned: return "questionmark.diamond.fill"
        case .invalid: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch severity {
        case .ok: return .green
        case .info: return .orange
        case .attention: return .red
        }
    }
}

/// The result of reading one program's code signature.
struct SecuritySignatureInfo: Hashable {
    var status: SecuritySignatureStatus
    /// Common name of the leaf signing certificate.
    var signer: String?
    var teamID: String?
    var identifier: String?
    /// True when the full contents were checked against the signature (Deep Verify).
    var deepVerified = false
    /// Error text when the signature failed to validate.
    var detail: String?

    var verificationNote: String {
        deepVerified ? "Contents deep-verified against the signature." : "Identity checked. Contents were not deep-verified in this pass."
    }
}

/// Reads code signatures with Security.framework. Synchronous; call from a background task.
enum SecuritySignatureReader {
    private static func flags(_ raw: Int) -> SecCSFlags { SecCSFlags(rawValue: UInt32(truncatingIfNeeded: raw)) }

    private static var quickFlags: SecCSFlags { flags(Int(kSecCSDoNotValidateResources)) }

    private static var deepFlags: SecCSFlags {
        flags(Int(kSecCSCheckAllArchitectures) | Int(kSecCSCheckNestedCode) | Int(kSecCSStrictValidate))
    }

    private static let requirementCache = NSCache<NSString, SecRequirement>()

    private static func requirement(_ text: String) -> SecRequirement? {
        if let hit = requirementCache.object(forKey: text as NSString) { return hit }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &req) == errSecSuccess, let req else { return nil }
        requirementCache.setObject(req, forKey: text as NSString)
        return req
    }

    private static func satisfies(_ code: SecStaticCode, _ text: String) -> Bool {
        guard let req = requirement(text) else { return false }
        return SecStaticCodeCheckValidity(code, quickFlags, req) == errSecSuccess
    }

    static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Error \(status)"
    }

    /// Classifies the code at `url` (an app bundle or a plain executable).
    static func check(_ url: URL, deep: Bool) -> SecuritySignatureInfo {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard created == errSecSuccess, let code = staticCode else {
            return SecuritySignatureInfo(status: .unsigned, detail: message(for: created))
        }

        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, flags(Int(kSecCSSigningInformation)), &infoRef)
        let info = (infoRef as? [String: Any]) ?? [:]
        let signer = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
            .flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0

        var result = SecuritySignatureInfo(status: .unsigned, signer: signer, teamID: team, identifier: identifier, deepVerified: deep)

        let validity = SecStaticCodeCheckValidity(code, deep ? deepFlags : quickFlags, nil)
        if Int(validity) == Int(errSecCSUnsigned) {
            result.status = .unsigned
            return result
        }
        if validity != errSecSuccess {
            result.status = .invalid
            result.detail = message(for: validity)
            return result
        }

        if codeFlags & 0x0002 != 0 { // kSecCodeSignatureAdhoc
            result.status = .adHoc
        } else if satisfies(code, "anchor apple") {
            result.status = .apple
        } else if satisfies(code, "anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] or certificate leaf[field.1.2.840.113635.100.6.1.3])")
                    || FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
                    || FileManager.default.fileExists(atPath: url.appendingPathComponent("Wrapper/iTunesMetadata.plist").path) {
            // Mac App Store leaf, or an iPhone/iPad App Store app running on the Mac.
            result.status = .appStore
        } else if satisfies(code, "notarized") {
            result.status = .notarized
        } else {
            result.status = .signedNotNotarized
        }
        return result
    }

    /// The .app bundle that contains `path`, if any.
    static func enclosingApp(of path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if url.pathExtension.lowercased() == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
