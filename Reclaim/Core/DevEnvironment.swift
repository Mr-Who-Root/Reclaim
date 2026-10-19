import Foundation

/// Whether this Mac has developer tools, so the Developer section only shows up where it's useful.
enum DevEnvironment {
    static let detected: Bool = {
        let markers = ["Library/Developer/Xcode", "Library/Android/sdk", ".nvm", ".pyenv", ".rbenv", ".rustup", ".cargo", ".sdkman",
                       ".gradle", ".npm", ".local/share/mise", ".asdf", ".volta", ".docker", ".local/share/uv"]
        if markers.contains(where: { FS.exists(FS.home.appendingPathComponent($0)) }) { return true }
        if FS.exists(URL(fileURLWithPath: "/Applications/Xcode.app")) || MaintenanceScanner.brewPath != nil || DockerCLI.path != nil { return true }
        return !JunkProjects.roots.isEmpty
    }()
}
