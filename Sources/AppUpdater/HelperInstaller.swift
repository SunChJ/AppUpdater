import Foundation
import ServiceManagement

public class HelperInstaller {
    public static let shared = HelperInstaller()
    
    private let helperID: String
    private let helperURL: URL
    private let xpcID: String
    private let xpcURL: URL
    
    init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "app"
        helperID = "\(bundleID).helper"
        helperURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(helperID)")
        xpcID = "\(bundleID).xpc"
        xpcURL = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/\(xpcID).xpc")
    }
    
    public func isHelperInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: helperURL.path)
    }
    
    public func isXPCInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: xpcURL.path)
    }
    
    public func installHelper(completion: @escaping (Bool, String?) -> Void) {
        // 获取帮助工具源代码路径
        guard let helperSourcePath = getHelperSourcePath() else {
            let errorMessage = "Helper source not found. Searched in: \(Bundle.module.bundlePath), \(Bundle.module.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path), and \(FileManager.default.currentDirectoryPath)"
            completion(false, errorMessage)
            return
        }
        
        // 获取共享源代码路径
        guard let sharedSourcePath = getSharedSourcePath() else {
            completion(false, "Shared source not found")
            return
        }
        
        // 1. 构建帮助工具
        buildHelper { [weak self] success, helperPath, error in
            guard let self = self, success, let helperPath = helperPath else {
                completion(false, error ?? "Failed to build helper")
                return
            }
            
            // 2. 安装帮助工具
            self.installBuiltHelper(at: helperPath) { success, error in
                completion(success, error)
            }
        }
    }
    
    private func buildHelper(completion: @escaping (Bool, URL?, String?) -> Void) {
        // 从包资源中提取帮助工具源代码
        guard let helperSourceURL = getHelperSourcePath() else {
            completion(false, nil, "Helper source not found")
            return
        }
        
        // 创建临时目录
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // 复制源代码到临时目录
            let tempSourceDir = tempDir.appendingPathComponent("Sources")
            try FileManager.default.createDirectory(at: tempSourceDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: helperSourceURL, to: tempSourceDir.appendingPathComponent("AppUpdaterHelper"))
            
            // 创建 Package.swift
            let packageContent = """
            // swift-tools-version:5.5
            import PackageDescription
            
            let package = Package(
                name: "AppUpdaterHelper",
                platforms: [.macOS(.v10_13)],
                products: [
                    .executable(name: "AppUpdaterHelper", targets: ["AppUpdaterHelper"]),
                ],
                targets: [
                    .executableTarget(name: "AppUpdaterHelper", dependencies: []),
                ]
            )
            """
            try packageContent.write(to: tempDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            
            // 构建帮助工具
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            process.arguments = ["build", "--configuration", "release"]
            process.currentDirectoryURL = tempDir
            
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                // 构建成功
                let helperPath = tempDir.appendingPathComponent(".build/release/AppUpdaterHelper")
                completion(true, helperPath, nil)
            } else {
                completion(false, nil, "Build failed with status \(process.terminationStatus)")
            }
        } catch {
            completion(false, nil, error.localizedDescription)
        }
    }
    
    private func installBuiltHelper(at helperPath: URL, completion: @escaping (Bool, String?) -> Void) {
        var authRef: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authRef)
        
        guard status == errAuthorizationSuccess, let auth = authRef else {
            completion(false, "Failed to create authorization: \(status)")
            return
        }
        
        defer {
            AuthorizationFree(auth, [])
        }
        
        // 获取管理员权限
        var authItem = AuthorizationItem(name: kSMRightBlessPrivilegedHelper, valueLength: 0, value: nil, flags: 0)
        var authRights = AuthorizationRights(count: 1, items: &authItem)
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        
        let authStatus = AuthorizationCreate(&authRights, nil, flags, &authRef)
        guard authStatus == errAuthorizationSuccess else {
            completion(false, "Authorization failed: \(authStatus)")
            return
        }
        
        // 准备 launchd.plist
        guard let launchdTemplate = Bundle.module.url(forResource: "launchd.plist", withExtension: "template"),
              let launchdData = try? Data(contentsOf: launchdTemplate),
              var launchdContent = String(data: launchdData, encoding: .utf8) else {
            completion(false, "Failed to load launchd.plist template")
            return
        }
        
        launchdContent = launchdContent.replacingOccurrences(of: "{{HELPER_ID}}", with: helperID)
        
        let launchdURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(helperID).plist")
        do {
            try launchdContent.write(to: launchdURL, atomically: true, encoding: .utf8)
            
            // 复制帮助工具到目标位置
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = [
                "cp",
                helperPath.path,
                helperURL.path
            ]
            
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                completion(false, "Failed to copy helper")
                return
            }
            
            // 设置权限
            let chmodProcess = Process()
            chmodProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            chmodProcess.arguments = [
                "chmod",
                "744",  // rwxr--r--
                helperURL.path
            ]
            
            try chmodProcess.run()
            chmodProcess.waitUntilExit()
            
            if chmodProcess.terminationStatus != 0 {
                completion(false, "Failed to set permissions")
                return
            }
            
            // 复制 launchd.plist
            let launchdDestURL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(helperID).plist")
            let copyProcess = Process()
            copyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            copyProcess.arguments = [
                "cp",
                launchdURL.path,
                launchdDestURL.path
            ]
            
            try copyProcess.run()
            copyProcess.waitUntilExit()
            
            if copyProcess.terminationStatus != 0 {
                completion(false, "Failed to copy launchd.plist")
                return
            }
            
            // 设置 launchd.plist 权限
            let chownProcess = Process()
            chownProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            chownProcess.arguments = [
                "chown",
                "root:wheel",
                launchdDestURL.path
            ]
            
            try chownProcess.run()
            chownProcess.waitUntilExit()
            
            if chownProcess.terminationStatus != 0 {
                completion(false, "Failed to set launchd.plist ownership")
                return
            }
            
            // 加载 launchd 服务
            let loadProcess = Process()
            loadProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            loadProcess.arguments = [
                "launchctl",
                "load",
                launchdDestURL.path
            ]
            
            try loadProcess.run()
            loadProcess.waitUntilExit()
            
            if loadProcess.terminationStatus != 0 {
                completion(false, "Failed to load launchd service")
                return
            }
            
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }
    
    public func buildAndInstallXPC(completion: @escaping (Bool, String?) -> Void) {
        // 1. 构建 XPC 服务
        buildXPC { [weak self] success, xpcPath, error in
            guard let self = self, success, let xpcPath = xpcPath else {
                completion(false, error ?? "Failed to build XPC service")
                return
            }
            
            // 2. 安装 XPC 服务
            self.installBuiltXPC(at: xpcPath) { success, error in
                completion(success, error)
            }
        }
    }
    
    private func buildXPC(completion: @escaping (Bool, URL?, String?) -> Void) {
        // 从包资源中提取 XPC 服务源代码
        guard let xpcSourceURL = getXPCSourcePath() else {
            completion(false, nil, "XPC service source not found")
            return
        }
        
        // 创建临时目录
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // 复制源代码到临时目录
            let tempSourceDir = tempDir.appendingPathComponent("Sources")
            try FileManager.default.createDirectory(at: tempSourceDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: xpcSourceURL, to: tempSourceDir.appendingPathComponent("AppUpdaterXPC"))
            
            // 创建 Package.swift
            let packageContent = """
            // swift-tools-version:5.5
            import PackageDescription
            
            let package = Package(
                name: "AppUpdaterXPC",
                platforms: [.macOS(.v10_13)],
                products: [
                    .executable(name: "AppUpdaterXPC", targets: ["AppUpdaterXPC"]),
                ],
                targets: [
                    .executableTarget(name: "AppUpdaterXPC", dependencies: []),
                ]
            )
            """
            try packageContent.write(to: tempDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            
            // 构建 XPC 服务
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            process.arguments = ["build", "--configuration", "release"]
            process.currentDirectoryURL = tempDir
            
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                // 构建成功
                let xpcExecutablePath = tempDir.appendingPathComponent(".build/release/AppUpdaterXPC")
                
                // 创建 XPC 服务包结构
                let xpcBundleDir = tempDir.appendingPathComponent("\(xpcID).xpc")
                try FileManager.default.createDirectory(at: xpcBundleDir, withIntermediateDirectories: true)
                
                // 创建 Contents 目录
                let contentsDir = xpcBundleDir.appendingPathComponent("Contents")
                try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
                
                // 创建 MacOS 目录
                let macOSDir = contentsDir.appendingPathComponent("MacOS")
                try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
                
                // 复制可执行文件
                try FileManager.default.copyItem(at: xpcExecutablePath, to: macOSDir.appendingPathComponent("AppUpdaterXPC"))
                
                // 创建 Info.plist
                guard let infoPlistTemplate = Bundle.module.url(forResource: "Info.plist.xpc", withExtension: "template"),
                      let infoPlistData = try? Data(contentsOf: infoPlistTemplate),
                      var infoPlistContent = String(data: infoPlistData, encoding: .utf8) else {
                    completion(false, nil, "Failed to load Info.plist template")
                    return
                }
                
                // 替换占位符
                let bundleID = Bundle.main.bundleIdentifier ?? "app"
                let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App"
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                let year = Calendar.current.component(.year, from: Date())
                
                infoPlistContent = infoPlistContent
                    .replacingOccurrences(of: "{{BUNDLE_ID}}", with: bundleID)
                    .replacingOccurrences(of: "{{APP_NAME}}", with: appName)
                    .replacingOccurrences(of: "{{VERSION}}", with: version)
                    .replacingOccurrences(of: "{{YEAR}}", with: String(year))
                
                try infoPlistContent.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
                
                completion(true, xpcBundleDir, nil)
            } else {
                completion(false, nil, "Build failed with status \(process.terminationStatus)")
            }
        } catch {
            completion(false, nil, error.localizedDescription)
        }
    }
    
    private func installBuiltXPC(at xpcPath: URL, completion: @escaping (Bool, String?) -> Void) {
        do {
            // 确保 XPC 服务目录存在
            let xpcServicesDir = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices")
            if !FileManager.default.fileExists(atPath: xpcServicesDir.path) {
                try FileManager.default.createDirectory(at: xpcServicesDir, withIntermediateDirectories: true)
            }
            
            // 如果已存在，先删除旧的 XPC 服务
            if FileManager.default.fileExists(atPath: xpcURL.path) {
                try FileManager.default.removeItem(at: xpcURL)
            }
            
            // 复制 XPC 服务到目标位置
            try FileManager.default.copyItem(at: xpcPath, to: xpcURL)
            
            // 设置权限
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/chmod")
            process.arguments = [
                "-R",
                "755",  // rwxr-xr-x
                xpcURL.path
            ]
            
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                completion(false, "Failed to set XPC service permissions")
                return
            }
            
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }
    
    // 辅助方法：签名帮助工具和 XPC 服务
    private func signExecutable(at path: URL, completion: @escaping (Bool, String?) -> Void) {
        do {
            // 获取应用的签名身份
            let identityProcess = Process()
            identityProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            identityProcess.arguments = ["find-identity", "-v", "-p", "codesigning"]
            
            let outputPipe = Pipe()
            identityProcess.standardOutput = outputPipe
            
            try identityProcess.run()
            identityProcess.waitUntilExit()
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: outputData, encoding: .utf8) else {
                completion(false, "Failed to read code signing identities")
                return
            }
            
            // 解析输出以获取签名身份
            let identityLines = output.components(separatedBy: "\n")
            var signingIdentity: String?
            
            for line in identityLines {
                if line.contains("Developer ID Application") || line.contains("Apple Development") {
                    let components = line.components(separatedBy: "\"")
                    if components.count >= 2 {
                        signingIdentity = components[1]
                        break
                    }
                }
            }
            
            guard let identity = signingIdentity else {
                completion(false, "No suitable code signing identity found")
                return
            }
            
            // 签名可执行文件
            let signProcess = Process()
            signProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signProcess.arguments = [
                "--force",
                "--sign",
                identity,
                "--options", "runtime",
                path.path
            ]
            
            try signProcess.run()
            signProcess.waitUntilExit()
            
            if signProcess.terminationStatus != 0 {
                completion(false, "Code signing failed with status \(signProcess.terminationStatus)")
                return
            }
            
            completion(true, nil)
        } catch {
            completion(false, error.localizedDescription)
        }
    }
    
    // 辅助方法：验证帮助工具是否正在运行
    func isHelperRunning(completion: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: outputData, encoding: .utf8) {
                completion(output.contains(helperID))
            } else {
                completion(false)
            }
        } catch {
            completion(false)
        }
    }
    
    // 辅助方法：启动帮助工具
    func startHelper(completion: @escaping (Bool, String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [
            "launchctl",
            "load",
            "/Library/LaunchDaemons/\(helperID).plist"
        ]
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                completion(true, nil)
            } else {
                completion(false, "Failed to start helper with status \(process.terminationStatus)")
            }
        } catch {
            completion(false, error.localizedDescription)
        }
    }
    
    // 辅助方法：停止帮助工具
    func stopHelper(completion: @escaping (Bool, String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [
            "launchctl",
            "unload",
            "/Library/LaunchDaemons/\(helperID).plist"
        ]
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                completion(true, nil)
            } else {
                completion(false, "Failed to stop helper with status \(process.terminationStatus)")
            }
        } catch {
            completion(false, error.localizedDescription)
        }
    }
    
    // 辅助方法：卸载帮助工具
    public func uninstallHelper(completion: @escaping (Bool, String?) -> Void) {
        // 先停止帮助工具
        stopHelper { [weak self] success, error in
            guard let self = self else { return }
            
            if !success {
                completion(false, error)
                return
            }
            
            // 删除 launchd.plist
            let launchdProcess = Process()
            launchdProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            launchdProcess.arguments = [
                "rm",
                "/Library/LaunchDaemons/\(self.helperID).plist"
            ]
            
            do {
                try launchdProcess.run()
                launchdProcess.waitUntilExit()
                
                if launchdProcess.terminationStatus != 0 {
                    completion(false, "Failed to remove launchd.plist")
                    return
                }
                
                // 删除帮助工具
                let helperProcess = Process()
                helperProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                helperProcess.arguments = [
                    "rm",
                    self.helperURL.path
                ]
                
                try helperProcess.run()
                helperProcess.waitUntilExit()
                
                if helperProcess.terminationStatus != 0 {
                    completion(false, "Failed to remove helper")
                    return
                }
                
                completion(true, nil)
            } catch {
                completion(false, error.localizedDescription)
            }
        }
    }
    
    private func getHelperSourcePath() -> URL? {
        // 首先尝试从包资源中获取
        if let resourceURL = Bundle.module.url(forResource: "AppUpdaterHelper", withExtension: nil) {
            return resourceURL
        }
        
        // 如果包资源中没有，尝试从包目录中获取
        let packageURL = Bundle.module.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let sourcePath = packageURL.appendingPathComponent("Sources/AppUpdaterHelper")
        
        if FileManager.default.fileExists(atPath: sourcePath.path) {
            return sourcePath
        }
        
        // 最后尝试从当前目录获取
        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let currentSourcePath = currentDirectoryURL.appendingPathComponent("Sources/AppUpdaterHelper")
        
        if FileManager.default.fileExists(atPath: currentSourcePath.path) {
            return currentSourcePath
        }
        
        return nil
    }
    
    private func getXPCSourcePath() -> URL? {
        // 首先尝试从包资源中获取
        if let resourceURL = Bundle.module.url(forResource: "AppUpdaterXPC", withExtension: nil) {
            return resourceURL
        }
        
        // 如果包资源中没有，尝试从包目录中获取
        let packageURL = Bundle.module.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let sourcePath = packageURL.appendingPathComponent("Sources/AppUpdaterXPC")
        
        if FileManager.default.fileExists(atPath: sourcePath.path) {
            return sourcePath
        }
        
        // 最后尝试从当前目录获取
        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let currentSourcePath = currentDirectoryURL.appendingPathComponent("Sources/AppUpdaterXPC")
        
        if FileManager.default.fileExists(atPath: currentSourcePath.path) {
            return currentSourcePath
        }
        
        return nil
    }
    
    private func getSharedSourcePath() -> URL? {
        // 首先尝试从包资源中获取
        if let resourceURL = Bundle.module.url(forResource: "AppUpdaterShared", withExtension: nil) {
            return resourceURL
        }
        
        // 如果包资源中没有，尝试从包目录中获取
        let packageURL = Bundle.module.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let sourcePath = packageURL.appendingPathComponent("Sources/AppUpdaterShared")
        
        if FileManager.default.fileExists(atPath: sourcePath.path) {
            return sourcePath
        }
        
        // 最后尝试从当前目录获取
        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let currentSourcePath = currentDirectoryURL.appendingPathComponent("Sources/AppUpdaterShared")
        
        if FileManager.default.fileExists(atPath: currentSourcePath.path) {
            return currentSourcePath
        }
        
        return nil
    }
    
    public func debugResourcePaths() -> String {
        var debug = "Bundle.module.bundlePath: \(Bundle.module.bundlePath)\n"
        debug += "Bundle.module.resourcePath: \(Bundle.module.resourcePath ?? "nil")\n"
        
        debug += "Resources in bundle:\n"
        if let resourcePath = Bundle.module.resourcePath,
           let resources = try? FileManager.default.contentsOfDirectory(atPath: resourcePath) {
            for resource in resources {
                debug += "- \(resource)\n"
            }
        } else {
            debug += "- Could not list resources\n"
        }
        
        debug += "\nPackage directory: \(Bundle.module.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path)\n"
        debug += "Current directory: \(FileManager.default.currentDirectoryPath)\n"
        
        debug += "\nHelper source path: \(getHelperSourcePath()?.path ?? "nil")\n"
        debug += "XPC source path: \(getXPCSourcePath()?.path ?? "nil")\n"
        debug += "Shared source path: \(getSharedSourcePath()?.path ?? "nil")\n"
        
        return debug
    }
} 