import Foundation

@objc public protocol UpdaterServiceProtocol {
    // 检查更新
    func checkForUpdates(withOwner owner: String, repo: String, currentVersion: String, allowPrereleases: Bool, reply: @escaping (Bool, String?, [String: Any]?) -> Void)
    
    // 下载更新
    func downloadUpdate(fromURL url: URL, reply: @escaping (Bool, String?, URL?) -> Void)
    
    // 安装更新
    func installUpdate(fromPath path: String, toPath destinationPath: String, reply: @escaping (Bool, String?) -> Void)
    
    // 重启应用
    func restartApplication(bundlePath: String, reply: @escaping (Bool) -> Void)
}

// 用于进度报告的协议
@objc public protocol UpdaterProgressProtocol {
    func updateProgress(progress: Double)
    func updateCompleted(success: Bool, error: String?)
} 