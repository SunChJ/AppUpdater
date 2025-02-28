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
        
        // 创建临时目录
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            completion(false, "Failed to create temporary directory: \(error.localizedDescription)")
            return
        }
        
        // 构建帮助工具
        buildHelper(sourcePath: helperSourcePath, sharedSourcePath: sharedSourcePath, outputDir: tempDir) { success, error, helperURL in
            if !success || helperURL == nil {
                completion(false, "Failed to build helper: \(error ?? "Unknown error")")
                return
            }
            
            guard let helperURL = helperURL else {
                completion(false, "Helper URL is nil")
                return
            }
            
            // 安装帮助工具
            self.installBuiltHelper(helperURL: helperURL) { success, error in
                // 清理临时目录
                try? FileManager.default.removeItem(at: tempDir)
                
                completion(success, error)
            }
        }
    }
    
    private func buildHelper(sourcePath: URL, sharedSourcePath: URL, outputDir: URL, completion: @escaping (Bool, String?, URL?) -> Void) {
        // 从包资源中提取帮助工具源代码
        guard let helperSourceURL = getHelperSourcePath() else {
            completion(false, "Helper source not found", nil)
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
                completion(true, nil, helperPath)
            } else {
                completion(false, "Build failed with status \(process.terminationStatus)", nil)
            }
        } catch {
            completion(false, error.localizedDescription, nil)
        }
    }
    
    private func installBuiltHelper(helperURL: URL, completion: @escaping (Bool, String?) -> Void) {
        // 获取主应用的 Bundle ID
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let helperID = bundleID.isEmpty ? "com.yourdomain.appupdater.helper" : "\(bundleID).helper"
        
        // 创建授权引用
        var authRef: AuthorizationRef?
        var authStatus = AuthorizationCreate(nil, nil, AuthorizationFlags(), &authRef)
        
        guard authStatus == errAuthorizationSuccess else {
            completion(false, "Failed to create authorization: \(authStatus)")
            return
        }
        
        defer {
            if let authRef = authRef {
                AuthorizationFree(authRef, AuthorizationFlags())
            }
        }
        
        // 获取授权
        let authItem = AuthorizationItem(name: kSMRightBlessPrivilegedHelper, valueLength: 0, value: nil, flags: 0)
        var authItems = [authItem]
        var authRights = AuthorizationRights(count: 1, items: &authItems)
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        
        authStatus = AuthorizationCreate(&authRights, nil, flags, &authRef)
        
        guard authStatus == errAuthorizationSuccess else {
            completion(false, "Failed to get authorization: \(authStatus)")
            return
        }
        
        // 安装帮助工具
        var cfError: Unmanaged<CFError>?
        let result = SMJobBless(kSMDomainSystemLaunchd, helperID as CFString, authRef, &cfError)
        
        if !result {
            var errorMessage = "Failed to bless helper"
            
            if let cfError = cfError {
              errorMessage = "Failed to bless helper: \(cfError)"
                
//                // 添加更多详细信息
//                if let reasons = nsError.userInfo["BlessErrorReasons"] as? [String] {
//                    errorMessage += "\nReasons: \(reasons.joined(separator: ", "))"
//                } else {
//                    errorMessage += "\nCan't find or decode reasons"
//                }
                
                // 检查帮助工具的代码签名
                let task = Process()
                task.launchPath = "/usr/bin/codesign"
                task.arguments = ["-vv", "-d", helperURL.path]
                
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                
                do {
                    try task.run()
                    task.waitUntilExit()
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8) {
                        errorMessage += "\nCode signing info: \(output)"
                    }
                } catch {
                    errorMessage += "\nFailed to check code signing: \(error.localizedDescription)"
                }
            }
            
            completion(false, errorMessage)
            return
        }
        
        completion(true, nil)
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
    
    public func checkCodeSigning() -> String {
        var result = "Code Signing Information:\n"
        
        // 检查主应用的代码签名
        let mainBundle = Bundle.main
        let mainBundlePath = mainBundle.bundlePath
        
        result += "\nMain Application (\(mainBundlePath)):\n"
        result += runCommand("/usr/bin/codesign", arguments: ["-vv", "-d", mainBundlePath])
        
        // 获取开发者 ID
        let task = Process()
        task.launchPath = "/usr/bin/codesign"
        task.arguments = ["-dvv", mainBundlePath]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // 解析输出以获取开发者 ID
                if let range = output.range(of: "Authority=Developer ID Application: ") {
                    let start = range.upperBound
                    if let end = output[start...].range(of: " (")?.lowerBound {
                        let developerID = String(output[start..<end])
                        result += "\nDeveloper ID: \(developerID)\n"
                    }
                }
            }
        } catch {
            result += "\nFailed to get developer ID: \(error.localizedDescription)\n"
        }
        
        // 检查帮助工具的代码签名（如果已安装）
        if isHelperInstalled() {
            result += "\nHelper Tool (\(helperURL.path)):\n"
            result += runCommand("/usr/bin/codesign", arguments: ["-vv", "-d", helperURL.path])
        } else {
            result += "\nHelper Tool: Not installed\n"
        }
        
        // 检查 XPC 服务的代码签名（如果已安装）
        if isXPCInstalled() {
            result += "\nXPC Service (\(xpcURL.path)):\n"
            result += runCommand("/usr/bin/codesign", arguments: ["-vv", "-d", xpcURL.path])
        } else {
            result += "\nXPC Service: Not installed\n"
        }
        
        return result
    }
    
    private func runCommand(_ command: String, arguments: [String]) -> String {
        let task = Process()
        task.launchPath = command
        task.arguments = arguments
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? "No output"
        } catch {
            return "Error running command: \(error.localizedDescription)"
        }
    }
} 
