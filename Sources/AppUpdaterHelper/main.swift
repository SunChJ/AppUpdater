import Foundation
import AppUpdaterShared

class UpdaterHelper: NSObject, UpdaterServiceProtocol {
    // 实现检查更新的方法
    func checkForUpdates(withOwner owner: String, repo: String, currentVersion: String, allowPrereleases: Bool, reply: @escaping (Bool, String?, [String: Any]?) -> Void) {
        // 从 GitHub API 获取发布信息
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases")!
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                reply(false, error.localizedDescription, nil)
                return
            }
            
            guard let data = data else {
                reply(false, "No data received", nil)
                return
            }
            
            do {
                // 解析 JSON 数据
                guard let releasesJSON = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    reply(false, "Invalid JSON format", nil)
                    return
                }
                
                // 过滤预发布版本
                let filteredReleases = allowPrereleases ? releasesJSON : releasesJSON.filter { !($0["prerelease"] as? Bool ?? false) }
                
                guard !filteredReleases.isEmpty else {
                    reply(false, "No releases found", nil)
                    return
                }
                
                // 查找最新版本
                guard let latestRelease = filteredReleases.first else {
                    reply(false, "No releases found", nil)
                    return
                }
                
                // 比较版本
                guard let tagName = latestRelease["tag_name"] as? String else {
                    reply(false, "Invalid release format", nil)
                    return
                }
                
                let cleanTagName = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                let cleanCurrentVersion = currentVersion.hasPrefix("v") ? String(currentVersion.dropFirst()) : currentVersion
                
                // 简单版本比较 (可以使用更复杂的版本比较逻辑)
                let tagComponents = cleanTagName.split(separator: ".").compactMap { Int($0) }
                let currentComponents = cleanCurrentVersion.split(separator: ".").compactMap { Int($0) }
                
                var isNewer = false
                for i in 0..<min(tagComponents.count, currentComponents.count) {
                    if tagComponents[i] > currentComponents[i] {
                        isNewer = true
                        break
                    } else if tagComponents[i] < currentComponents[i] {
                        break
                    }
                }
                
                if !isNewer && tagComponents.count > currentComponents.count {
                    isNewer = true
                }
                
                if !isNewer {
                    reply(false, "Already up to date", nil)
                    return
                }
                
                // 返回发布信息
                reply(true, nil, latestRelease)
            } catch {
                reply(false, "Failed to parse releases: \(error.localizedDescription)", nil)
            }
        }
        
        task.resume()
    }
    
    // 实现下载更新的方法
    func downloadUpdate(fromURL url: URL, reply: @escaping (Bool, String?, URL?) -> Void) {
        // 创建临时目录
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
            
            // 创建下载目标路径
            let destination = tempDir.appendingPathComponent(url.lastPathComponent)
            
            // 创建下载任务
            let downloadTask = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                if let error = error {
                    reply(false, error.localizedDescription, nil)
                    return
                }
                
                guard let tempURL = tempURL else {
                    reply(false, "Download failed: no temporary URL", nil)
                    return
                }
                
                do {
                    // 移动下载的文件到目标位置
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    
                    // 解压文件
                    let extractedURL = try self.extractArchive(at: destination, to: tempDir)
                    
                    reply(true, nil, extractedURL)
                } catch {
                    reply(false, "Failed to process download: \(error.localizedDescription)", nil)
                }
            }
            
            downloadTask.resume()
        } catch {
            reply(false, "Failed to create temporary directory: \(error.localizedDescription)", nil)
        }
    }
    
    // 辅助方法：解压归档文件
    private func extractArchive(at archiveURL: URL, to destinationURL: URL) throws -> URL {
        let fileManager = FileManager.default
        
        // 确定归档类型
        let archiveExtension = archiveURL.pathExtension.lowercased()
        
        // 创建进程
        let process = Process()
        
        switch archiveExtension {
        case "zip":
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", archiveURL.path, "-d", destinationURL.path]
        case "tar", "tgz", "gz":
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", archiveURL.path, "-C", destinationURL.path]
        default:
            throw NSError(domain: "AppUpdaterErrorDomain", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported archive format: \(archiveExtension)"])
        }
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw NSError(domain: "AppUpdaterErrorDomain", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to extract archive"])
        }
        
        // 查找解压后的应用
        let contents = try fileManager.contentsOfDirectory(at: destinationURL, includingPropertiesForKeys: nil, options: [])
        
        for item in contents {
            if item.pathExtension.lowercased() == "app" {
                return item
            }
        }
        
        // 如果没有直接找到 .app，尝试在子目录中查找
        for item in contents {
            if item.hasDirectoryPath {
                let subContents = try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [])
                if let subContents = subContents {
                    for subItem in subContents {
                        if subItem.pathExtension.lowercased() == "app" {
                            return subItem
                        }
                    }
                }
            }
        }
        
        throw UpdaterError.fileSystemError
    }
    
    // 实现安装更新的方法
    func installUpdate(fromPath path: String, toPath destinationPath: String, reply: @escaping (Bool, String?) -> Void) {
        let fileManager = FileManager.default
        let sourcePath = URL(fileURLWithPath: path)
        let destinationURL = URL(fileURLWithPath: destinationPath)
        
        do {
            // 创建备份
            let backupURL = destinationURL.deletingLastPathComponent().appendingPathComponent("AppBackup.app")
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            
            if fileManager.fileExists(atPath: destinationPath) {
                try fileManager.copyItem(at: destinationURL, to: backupURL)
                try fileManager.removeItem(at: destinationURL)
            }
            
            // 移动新应用到目标位置
            try fileManager.copyItem(at: sourcePath, to: destinationURL)
            
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }
    
    // 实现重启应用的方法
    func restartApplication(bundlePath: String, reply: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [bundlePath]
        
        do {
            try process.run()
            reply(true)
        } catch {
            reply(false)
        }
    }
}

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 验证连接的安全性
        // 在生产环境中，应该检查连接的代码签名要求
        
        // 设置连接
        newConnection.exportedInterface = NSXPCInterface(with: UpdaterServiceProtocol.self)
        newConnection.exportedObject = UpdaterHelper()
        newConnection.resume()
        
        return true
    }
}

// 主入口点
let delegate = HelperDelegate()
// 获取主应用的 Bundle ID
let mainAppBundleID = Bundle.main.bundleIdentifier ?? ""
let helperID = mainAppBundleID.isEmpty ? "com.yourdomain.appupdater.helper" : "\(mainAppBundleID).helper"

let listener = NSXPCListener(machServiceName: helperID)
listener.delegate = delegate
listener.resume()

// 保持运行
RunLoop.main.run() 
