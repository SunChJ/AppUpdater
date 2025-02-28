#!/bin/bash
# 安装帮助工具脚本

# 获取参数
BUNDLE_ID="$1"
DEVELOPER_ID="$2"
HELPER_ID="${BUNDLE_ID}.helper"
HELPER_PATH="/Library/PrivilegedHelperTools/${HELPER_ID}"

# 创建临时目录
TEMP_DIR=$(mktemp -d)
HELPER_DIR="${TEMP_DIR}/${HELPER_ID}"

# 清理函数
cleanup() {
    rm -rf "${TEMP_DIR}"
}

# 设置退出时清理
trap cleanup EXIT

# 创建帮助工具目录结构
mkdir -p "${HELPER_DIR}/Contents/MacOS"
mkdir -p "${HELPER_DIR}/Contents/Resources"

# 创建帮助工具可执行文件
cat > "${HELPER_DIR}/Contents/MacOS/${HELPER_ID##*.}" << 'EOF'
#!/usr/bin/swift

import Foundation

// 帮助工具服务协议
@objc protocol UpdaterHelperProtocol {
    func checkForUpdates(withOwner owner: String, repo: String, currentVersion: String, allowPrereleases: Bool, reply: @escaping (Bool, String?, [String: Any]?) -> Void)
    func downloadUpdate(fromURL url: URL, reply: @escaping (Bool, String?, URL?) -> Void)
    func installUpdate(fromPath path: String, toPath destinationPath: String, reply: @escaping (Bool, String?) -> Void)
}

// 进度更新协议
@objc protocol UpdaterProgressProtocol {
    func updateProgress(progress: Double)
}

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 设置连接接口
        newConnection.exportedInterface = NSXPCInterface(with: UpdaterHelperProtocol.self)
        
        // 设置导出对象
        let exportedObject = HelperService()
        newConnection.exportedObject = exportedObject
        
        // 设置远程对象接口
        newConnection.remoteObjectInterface = NSXPCInterface(with: UpdaterProgressProtocol.self)
        
        // 设置连接失效处理
        newConnection.invalidationHandler = {
            print("XPC connection invalidated")
        }
        
        // 恢复连接
        newConnection.resume()
        
        return true
    }
}

class HelperService: NSObject, UpdaterHelperProtocol {
    func checkForUpdates(withOwner owner: String, repo: String, currentVersion: String, allowPrereleases: Bool, reply: @escaping (Bool, String?, [String : Any]?) -> Void) {
        // 实现检查更新的逻辑
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases")!
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                reply(false, error.localizedDescription, nil)
                return
            }
            
            guard let data = data,
                  let releases = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
                reply(false, "Invalid response format", nil)
                return
            }
            
            // 查找最新的发布版本
            for release in releases {
                let isPre = release["prerelease"] as? Bool ?? false
                if isPre && !allowPrereleases {
                    continue
                }
                
                reply(true, nil, release)
                return
            }
            
            reply(false, "No suitable release found", nil)
        }
        
        task.resume()
    }
    
    func downloadUpdate(fromURL url: URL, reply: @escaping (Bool, String?, URL?) -> Void) {
        // 实现下载更新的逻辑
        let downloadTask = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            if let error = error {
                reply(false, error.localizedDescription, nil)
                return
            }
            
            guard let tempURL = tempURL else {
                reply(false, "Download failed: No temporary URL", nil)
                return
            }
            
            // 移动下载的文件到应用支持目录
            let fileManager = FileManager.default
            let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let downloadDir = appSupportDir.appendingPathComponent("AppUpdater/Downloads", isDirectory: true)
            
            do {
                // 创建下载目录（如果不存在）
                if !fileManager.fileExists(atPath: downloadDir.path) {
                    try fileManager.createDirectory(at: downloadDir, withIntermediateDirectories: true, attributes: nil)
                }
                
                // 生成唯一的文件名
                let fileName = url.lastPathComponent
                let destinationURL = downloadDir.appendingPathComponent(fileName)
                
                // 如果目标文件已存在，先删除它
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                
                // 移动下载的文件
                try fileManager.moveItem(at: tempURL, to: destinationURL)
                
                reply(true, nil, destinationURL)
            } catch {
                reply(false, "Failed to save downloaded file: \(error.localizedDescription)", nil)
            }
        }
        
        downloadTask.resume()
    }
    
    func installUpdate(fromPath path: String, toPath destinationPath: String, reply: @escaping (Bool, String?) -> Void) {
        // 实现安装更新的逻辑
        let fileManager = FileManager.default
        let sourcePath = URL(fileURLWithPath: path)
        let destinationPath = URL(fileURLWithPath: destinationPath)
        
        do {
            // 备份原始应用
            let backupPath = destinationPath.deletingLastPathComponent().appendingPathComponent("\(destinationPath.lastPathComponent).backup")
            
            // 如果备份已存在，先删除它
            if fileManager.fileExists(atPath: backupPath.path) {
                try fileManager.removeItem(at: backupPath)
            }
            
            // 创建备份
            try fileManager.copyItem(at: destinationPath, to: backupPath)
            
            // 删除原始应用
            try fileManager.removeItem(at: destinationPath)
            
            // 复制新应用
            try fileManager.copyItem(at: sourcePath, to: destinationPath)
            
            // 设置权限
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath.path)
            
            reply(true, nil)
        } catch {
            reply(false, "Failed to install update: \(error.localizedDescription)")
        }
    }
}

// 主入口点
let delegate = HelperDelegate()

// 获取主应用的 Bundle ID
let mainAppBundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let helperID = mainAppBundleID.isEmpty ? "com.yourdomain.appupdater.helper" : "\(mainAppBundleID).helper"

let listener = NSXPCListener(machServiceName: helperID)
listener.delegate = delegate
listener.resume()

// 保持运行
RunLoop.main.run()
EOF

# 设置可执行权限
chmod +x "${HELPER_DIR}/Contents/MacOS/${HELPER_ID##*.}"

# 创建 Info.plist
cat > "${HELPER_DIR}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${HELPER_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${HELPER_ID}</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>SMAuthorizedClients</key>
    <array>
        <string>identifier "${BUNDLE_ID}" and anchor apple generic and certificate leaf[subject.CN] = "${DEVELOPER_ID}" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */</string>
    </array>
</dict>
</plist>
EOF

# 创建 launchd.plist
cat > "${HELPER_DIR}/Contents/Resources/launchd.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${HELPER_ID}</string>
    <key>MachServices</key>
    <dict>
        <key>${HELPER_ID}</key>
        <true/>
    </dict>
    <key>Program</key>
    <string>/Library/PrivilegedHelperTools/${HELPER_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/${HELPER_ID}</string>
        <string>${BUNDLE_ID}</string>
    </array>
</dict>
</plist>
EOF

# 对帮助工具进行代码签名
codesign -f -s "Developer ID Application" "${HELPER_DIR}"

# 输出帮助工具路径
echo "${HELPER_DIR}" 