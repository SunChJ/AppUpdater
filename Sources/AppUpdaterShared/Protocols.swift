import Foundation

@objc public protocol UpdaterServiceProtocol {
    func checkForUpdates(withOwner owner: String, repo: String, currentVersion: String, allowPrereleases: Bool, reply: @escaping (Bool, String?, [String: Any]?) -> Void)
    func downloadUpdate(fromURL url: URL, reply: @escaping (Bool, String?, URL?) -> Void)
    func installUpdate(fromPath path: String, toPath destinationPath: String, reply: @escaping (Bool, String?) -> Void)
    func restartApplication(bundlePath: String, reply: @escaping (Bool) -> Void)
}

@objc public protocol UpdaterProgressProtocol {
    func updateProgress(progress: Double)
    func updateCompleted(success: Bool, error: String?)
} 