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
    
    // 使用脚本安装帮助工具
    public func installHelper(completion: @escaping (Bool, String?) -> Void) {
        // 获取脚本资源
        guard let scriptURL = Bundle.module.url(forResource: "install_helper.sh", withExtension: nil) else {
            completion(false, "Helper installation script not found")
            return
        }
        
        // 获取主应用的 Bundle ID
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        
        // 获取开发者 ID
        let developerID = getDeveloperID() ?? "Unknown Developer"
        
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
        
        // 运行安装脚本
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [scriptURL.path, bundleID, developerID]
        
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                completion(false, "Failed to run helper installation script: \(errorOutput)")
                return
            }
            
            // 获取脚本输出（帮助工具路径）
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let helperPath = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                completion(false, "Failed to get helper path from script output")
                return
            }
            
            // 安装帮助工具
            var cfError: Unmanaged<CFError>?
            let result = SMJobBless(kSMDomainSystemLaunchd, helperID as CFString, authRef, &cfError)
            
            if !result {
                var errorMessage = "Failed to bless helper"
                
                if let cfError = cfError {
                    errorMessage = "Failed to bless helper: \(cfError)"
                }
                
                completion(false, errorMessage)
                return
            }
            
            completion(true, nil)
        } catch {
            completion(false, "Failed to run helper installation script: \(error.localizedDescription)")
        }
    }
    
    // 使用脚本安装 XPC 服务
    public func installXPC(completion: @escaping (Bool, String?) -> Void) {
        // 获取脚本资源
        guard let scriptURL = Bundle.module.url(forResource: "install_xpc.sh", withExtension: nil) else {
            completion(false, "XPC installation script not found")
            return
        }
        
        // 获取主应用的 Bundle ID 和路径
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let appPath = Bundle.main.bundlePath
        
        // 运行安装脚本
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [scriptURL.path, bundleID, appPath]
        
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        
        let errorPipe = Pipe()
        task.standardError = errorPipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                completion(false, "Failed to run XPC installation script: \(errorOutput)")
                return
            }
            
            // 获取脚本输出（XPC 服务路径）
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let xpcPath = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                completion(false, "Failed to get XPC path from script output")
                return
            }
            
            completion(true, nil)
        } catch {
            completion(false, "Failed to run XPC installation script: \(error.localizedDescription)")
        }
    }
    
    // 获取开发者 ID
    private func getDeveloperID() -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/codesign"
        task.arguments = ["-dvv", Bundle.main.bundlePath]
        
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
                        return String(output[start..<end])
                    }
                }
            }
        } catch {
            print("Failed to get developer ID: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    // 调试方法
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
        
        return debug
    }
    
    // 检查代码签名
    public func checkCodeSigning() -> String {
        var result = "Code Signing Information:\n"
        
        // 检查主应用的代码签名
        let mainBundle = Bundle.main
        let mainBundlePath = mainBundle.bundlePath
        
        result += "\nMain Application (\(mainBundlePath)):\n"
        result += runCommand("/usr/bin/codesign", arguments: ["-vv", "-d", mainBundlePath])
        
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
