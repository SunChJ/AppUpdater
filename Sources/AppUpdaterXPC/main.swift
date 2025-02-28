import Foundation
import AppUpdaterShared

class XPCService: NSObject, UpdaterServiceProtocol, UpdaterProgressProtocol {
    private var clientConnection: NSXPCConnection?
    private var helperConnection: NSXPCConnection?
    private var helperProxy: UpdaterServiceProtocol?
    
    // 存储当前进度
    private var currentProgress: Double = 0.0
    
    // 连接到特权帮助工具
    func connectToHelper() -> UpdaterServiceProtocol? {
        if helperProxy != nil {
            return helperProxy
        }
        
        // 获取主应用的 Bundle ID
        let mainAppBundleID = Bundle.main.bundleIdentifier?.components(separatedBy: ".xpc").first ?? ""
        let helperID = "\(mainAppBundleID).helper"
        
        // 连接到帮助工具
        helperConnection = NSXPCConnection(machServiceName: helperID, options: .privileged)
        helperConnection?.remoteObjectInterface = NSXPCInterface(with: UpdaterServiceProtocol.self)
        helperConnection?.invalidationHandler = { [weak self] in
            self?.helperProxy = nil
            self?.helperConnection = nil
        }
        helperConnection?.resume()
        
        helperProxy = helperConnection?.remoteObjectProxyWithErrorHandler { error in
            print("Helper connection error: \(error)")
        } as? UpdaterServiceProtocol
        
        return helperProxy
    }
    
    // 设置客户端连接
    func setClientConnection(_ connection: NSXPCConnection) {
        clientConnection = connection
    }
    
    // MARK: - UpdaterServiceProtocol 实现
    
    func checkForUpdates(withOwner owner: String, repo: String, currentVersion: String, allowPrereleases: Bool, reply: @escaping (Bool, String?, [String: Any]?) -> Void) {
        guard let helper = connectToHelper() else {
            reply(false, "Failed to connect to helper", nil)
            return
        }
        
        helper.checkForUpdates(withOwner: owner, repo: repo, currentVersion: currentVersion, allowPrereleases: allowPrereleases) { success, error, releaseInfo in
            reply(success, error, releaseInfo)
        }
    }
    
    func downloadUpdate(fromURL url: URL, reply: @escaping (Bool, String?, URL?) -> Void) {
        guard let helper = connectToHelper() else {
            reply(false, "Failed to connect to helper", nil)
            return
        }
        
        // 重置进度
        currentProgress = 0.0
        updateProgress(progress: 0.0)
        
        // 创建下载任务
        helper.downloadUpdate(fromURL: url) { [weak self] success, error, downloadedURL in
            // 下载完成，更新进度为 100%
            if success {
                self?.updateProgress(progress: 1.0)
            }
            
            reply(success, error, downloadedURL)
        }
    }
    
    func installUpdate(fromPath path: String, toPath destinationPath: String, reply: @escaping (Bool, String?) -> Void) {
        guard let helper = connectToHelper() else {
            reply(false, "Failed to connect to helper", nil)
            return
        }
        
        helper.installUpdate(fromPath: path, toPath: destinationPath) { [weak self] success, error in
            // 通知客户端安装完成
            self?.updateCompleted(success: success, error: error)
            
            reply(success, error)
        }
    }
    
    func restartApplication(bundlePath: String, reply: @escaping (Bool) -> Void) {
        guard let helper = connectToHelper() else {
            reply(false)
            return
        }
        
        helper.restartApplication(bundlePath: bundlePath, reply: reply)
    }
    
    // MARK: - UpdaterProgressProtocol 实现
    
    func updateProgress(progress: Double) {
        // 更新当前进度
        currentProgress = progress
        
        // 将进度传递给客户端
        if let connection = clientConnection {
            let proxy = connection.remoteObjectProxy as? UpdaterProgressProtocol
            proxy?.updateProgress(progress: progress)
        }
    }
    
    func updateCompleted(success: Bool, error: String?) {
        // 将完成状态传递给客户端
        if let connection = clientConnection {
            let proxy = connection.remoteObjectProxy as? UpdaterProgressProtocol
            proxy?.updateCompleted(success: success, error: error)
        }
    }
}

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 创建服务实例
        let service = XPCService()
        service.setClientConnection(newConnection)
        
        // 设置连接
        newConnection.exportedInterface = NSXPCInterface(with: UpdaterServiceProtocol.self)
        newConnection.exportedObject = service
        
        // 设置远程对象接口，用于接收进度更新
        newConnection.remoteObjectInterface = NSXPCInterface(with: UpdaterProgressProtocol.self)
        
        // 设置连接失效处理
        newConnection.invalidationHandler = {
            print("Client connection invalidated")
        }
        
        // 启动连接
        newConnection.resume()
        return true
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