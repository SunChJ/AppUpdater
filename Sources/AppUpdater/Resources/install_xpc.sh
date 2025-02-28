#!/bin/bash
# 安装 XPC 服务脚本

# 获取参数
BUNDLE_ID="$1"
APP_PATH="$2"
XPC_ID="${BUNDLE_ID}.xpc"
XPC_PATH="${APP_PATH}/Contents/XPCServices/${XPC_ID}.xpc"

# 创建 XPC 服务目录
mkdir -p "${APP_PATH}/Contents/XPCServices"

# 创建 XPC 服务包
XPC_BUNDLE="${APP_PATH}/Contents/XPCServices/${XPC_ID}.xpc"
mkdir -p "${XPC_BUNDLE}/Contents/MacOS"

# 创建 XPC 服务可执行文件
cat > "${XPC_BUNDLE}/Contents/MacOS/${XPC_ID##*.}" << 'EOF'
#!/usr/bin/swift

import Foundation

// 帮助工具服务协议
@objc protocol UpdaterHelperProtocol {
    func checkForUpdates(withOwner owner: String, repo: String, currentVersion: String, allowPrereleases: Bool, reply: @escaping (Bool, String?, [String: Any]?) -> Void)
    func downloadUpdate(fromURL url: URL, reply: @escaping (Bool, String?, URL?) -> Void)
    func installUpdate(fromPath path: String, toPath destinationPath: String, reply: @escaping (Bool, String?) -> Void)
}

// 更新服务协议
@objc protocol UpdaterServiceProtocol {
    func checkForUpdates(withOwner owner: String, repo: String, currentVersion: String, allowPrereleases: Bool, reply: @escaping (Bool, String?, [String: Any]?) -> Void)
    func downloadUpdate(fromURL url: URL, reply: @escaping (Bool, String?, URL?) -> Void)
    func installUpdate(fromPath path: String, toPath destinationPath: String, reply: @escaping (Bool, String?) -> Void)
}

// 进度更新协议
@objc protocol UpdaterProgressProtocol {
    func updateProgress(progress: Double)
}

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 设置连接接口
        newConnection.exportedInterface = NSXPCInterface(with: UpdaterServiceProtocol.self)
        
        // 设置导出对象
        let exportedObject = UpdaterService()
        newConnection.exportedObject = exportedObject
        
        // 设置远程对象接口
        newConnection.remoteObjectInterface = NSXPCInterface(with: UpdaterProgressProtocol.self)
        
        // 保存客户端连接
        clientConnection = newConnection
        
        // 设置连接失效处理
        newConnection.invalidationHandler = {
            clientConnection = nil
        }
        
        // 恢复连接
        newConnection.resume()
        
        return true
    }
}

class UpdaterService: NSObject, UpdaterServiceProtocol {
    func checkForUpdates(withOwner owner: String, repo: String, currentVersion: String, allowPrereleases: Bool, reply: @escaping (Bool, String?, [String : Any]?) -> Void) {
        // 连接到帮助工具
        guard let helper = connectToHelper() else {
            reply(false, "Failed to connect to helper", nil)
            return
        }
        
        // 调用帮助工具的方法
        helper.checkForUpdates(withOwner: owner, repo: repo, currentVersion: currentVersion, allowPrereleases: allowPrereleases, reply: reply)
    }
    
    func downloadUpdate(fromURL url: URL, reply: @escaping (Bool, String?, URL?) -> Void) {
        // 连接到帮助工具
        guard let helper = connectToHelper() else {
            reply(false, "Failed to connect to helper", nil)
            return
        }
        
        // 重置进度
        currentProgress = 0.0
        updateProgress(progress: 0.0)
        
        // 调用帮助工具的方法
        helper.downloadUpdate(fromURL: url) { success, error, downloadedURL in
            // 下载完成，更新进度为 100%
            if success {
                updateProgress(progress: 1.0)
            }
            
            reply(success, error, downloadedURL)
        }
    }
    
    func installUpdate(fromPath path: String, toPath destinationPath: String, reply: @escaping (Bool, String?) -> Void) {
        // 连接到帮助工具
        guard let helper = connectToHelper() else {
            reply(false, "Failed to connect to helper", nil)
            return
        }
        
        // 调用帮助工具的方法
        helper.installUpdate(fromPath: path, toPath: destinationPath, reply: reply)
    }
}

// 全局变量
var clientConnection: NSXPCConnection?
var currentProgress: Double = 0.0

// 连接到帮助工具
func connectToHelper() -> UpdaterHelperProtocol? {
    // 获取主应用的 Bundle ID
    let mainAppBundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
    let helperID = mainAppBundleID.isEmpty ? "com.yourdomain.appupdater.helper" : "\(mainAppBundleID).helper"
    
    // 创建连接
    let connection = NSXPCConnection(machServiceName: helperID)
    connection.remoteObjectInterface = NSXPCInterface(with: UpdaterHelperProtocol.self)
    
    // 设置连接失效处理
    connection.invalidationHandler = {
        print("Helper connection invalidated")
    }
    
    // 启动连接
    connection.resume()
    
    // 获取远程对象代理
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        print("Helper connection error: \(error)")
    } as? UpdaterHelperProtocol
    
    return proxy
}

// 更新进度
func updateProgress(progress: Double) {
    currentProgress = progress
    
    // 将进度传递给客户端
    if let connection = clientConnection {
        let proxy = connection.remoteObjectProxy as? UpdaterProgressProtocol
        proxy?.updateProgress(progress: progress)
    }
}

// 主入口点
let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

// 输出启动信息
print("AppUpdater XPC Service started")

// 保持运行
RunLoop.main.run()
EOF

# 设置可执行权限
chmod +x "${XPC_BUNDLE}/Contents/MacOS/${XPC_ID##*.}"

# 创建 Info.plist
cat > "${XPC_BUNDLE}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${XPC_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${XPC_ID}</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>XPCService</key>
    <dict>
        <key>ServiceType</key>
        <string>Application</string>
    </dict>
</dict>
</plist>
EOF

# 对 XPC 服务进行代码签名
codesign -f -s "Developer ID Application" "${XPC_BUNDLE}"

# 输出 XPC 服务路径
echo "${XPC_BUNDLE}" 