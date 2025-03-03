// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import class AppKit.NSBackgroundActivityScheduler
import var AppKit.NSApp
import Foundation
import Version
import Path

public class AppUpdater: ObservableObject {
  public typealias OnSuccess = () -> Void
  public typealias OnFail = (Swift.Error) -> Void
  
  let activity: NSBackgroundActivityScheduler
  let owner: String
  let repo: String
  let releasePrefix: String
  
  var slug: String {
    return "\(owner)/\(repo)"
  }
  
  var proxy: URLRequestProxy?
  
  @available(*, deprecated, message: "This variable is deprecated. Use state instead.")
  @Published public var downloadedAppBundle: Bundle?
  
  /// update state
  @MainActor
  @Published public var state: UpdateState = .none
  
  /// all releases
  @MainActor
  @Published public var releases: [Release] = []
  
  public var onDownloadSuccess: OnSuccess? = nil
  public var onDownloadFail: OnFail? = nil
  
  public var onInstallSuccess: OnSuccess? = nil
  public var onInstallFail: OnFail? = nil
  
  public var allowPrereleases = false
  
  private var progressTimer: Timer? = nil
  
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.shouldUseExtendedBackgroundIdleMode = true
    config.timeoutIntervalForRequest = 3 * 60
    
    return URLSession(configuration: config)
  }()
  
  /// 在调试模式下是否强制使用 Developer ID 证书
  public var forceDeveloperIDInDebug = true
  
  public init(owner: String, repo: String, releasePrefix: String? = nil, interval: TimeInterval = 24 * 60 * 60, proxy: URLRequestProxy? = nil) {
    self.owner = owner
    self.repo = repo
    self.releasePrefix = releasePrefix ?? repo
    self.proxy = proxy
    
    activity = NSBackgroundActivityScheduler(identifier: "AppUpdater.\(Bundle.main.bundleIdentifier ?? "")")
    activity.repeats = true
    activity.interval = interval
    activity.schedule { [unowned self] completion in
      guard !self.activity.shouldDefer else {
        return completion(.deferred)
      }
      self.check(success: {
        self.onDownloadSuccess?()
        completion(.finished)
      }, fail: { err in
        self.onDownloadFail?(err)
        completion(.finished)
      })
    }
  }
  
  deinit {
    activity.invalidate()
  }
  
  public enum Error: Swift.Error {
    case bundleExecutableURL
    case codeSigningIdentity
    case invalidDownloadedBundle
    case noValidUpdate
    case unzipFailed
    case downloadFailed
  }
  
  public func check(success: OnSuccess? = nil, fail: OnFail? = nil) {
    Task {
      do {
        try await checkThrowing()
        success?()
      } catch {
        fail?(error)
      }
    }
  }
  
  public func install(success: OnSuccess? = nil, fail: OnFail? = nil) {
    guard let appBundle = downloadedAppBundle else {
      fail?(Error.invalidDownloadedBundle)
      return
    }
    install(appBundle, success: success, fail: fail)
  }
  
  public func install(_ appBundle: Bundle, success: OnSuccess? = nil, fail: OnFail? = nil) {
    do {
      try installThrowing(appBundle)
      success?()
      onInstallSuccess?()
    } catch {
      fail?(error)
      onInstallFail?(error)
    }
  }
  
  public func checkThrowing() async throws {
    guard Bundle.main.executableURL != nil else {
      aulog("Error: Failed to get bundle executable URL")
      throw Error.bundleExecutableURL
    }
    let currentVersion = Bundle.main.version
    aulog("Checking for updates. Current version:", currentVersion)
    
    func validate(codeSigning b1: Bundle, _ b2: Bundle) async throws -> Bool {
      do {
        aulog("Validating code signing...")
        
        // 检查当前应用是否签名
        let currentSigned = await b1.isCodeSigned()
        aulog("Current app signed:", currentSigned)
        
        // 检查下载的应用是否签名
        let downloadedSigned = await b2.isCodeSigned()
        aulog("Downloaded app signed:", downloadedSigned)
        
        // 如果两个应用都签名了，则比较签名身份
        if currentSigned && downloadedSigned {
          let csi1 = try await b1.codeSigningIdentity()
          let csi2 = try await b2.codeSigningIdentity()
          
          if csi1 == nil || csi2 == nil {
            aulog("Error: Failed to get code signing identity")
            throw Error.codeSigningIdentity
          }
          
          // 在调试模式下，如果设置了强制使用 Developer ID，则只检查是否包含 Developer ID
          #if DEBUG
          if forceDeveloperIDInDebug {
            let isDeveloperID2 = csi2?.contains("Developer ID") ?? false
            aulog("Debug mode: Checking for Developer ID - Current:", "Downloaded:", isDeveloperID2)
            return isDeveloperID2
          }
          #endif
          
          aulog("Comparing signing identities - Current:", csi1, "Downloaded:", csi2)
          return csi1 == csi2
        }
        
        aulog("Warning: At least one app is not signed")
        return false
      }
    }
    
    func update(with asset: Release.Asset, belongs release: Release) async throws -> Bundle? {
      aulog("Starting update process for release:", release.tag_name)
      aulog("Downloading asset:", asset.name)
      
      let tmpdir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)
      aulog("Created temporary directory:", tmpdir)
      
      let downloadState = try await session.downloadTask(with: asset.browser_download_url, to: tmpdir.appendingPathComponent("download"), proxy: proxy)
      
      var dst: URL? = nil
      for try await state in downloadState {
        switch state {
        case .progress(let progress):
          DispatchQueue.main.async {
            self.progressTimer?.invalidate()
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
              self.notifyStateChanged(newState: .downloading(release, asset, fraction: progress.fractionCompleted))
            }
          }
          
          break
        case .finished(let saveLocation, _):
          dst = saveLocation
          progressTimer?.invalidate()
          progressTimer = nil
        }
      }
      
      guard let dst = dst else {
        aulog("Error: Download failed - no destination URL")
        throw Error.downloadFailed
      }
      
      aulog("Download completed successfully:", dst)
      
      guard let unziped = try await unzip(dst, contentType: asset.content_type) else {
        aulog("Error: Failed to unzip downloaded file")
        throw Error.unzipFailed
      }
      
      aulog("Unzip completed successfully:", unziped)
      
      let downloadedAppBundle = Bundle(url: unziped)!
      aulog("Created bundle from unzipped file")
      
      if try await validate(codeSigning: .main, downloadedAppBundle) {
        aulog("Code signing validation passed")
        return downloadedAppBundle
      } else {
        aulog("Error: Code signing validation failed")
        throw Error.codeSigningIdentity
      }
    }
    
    let url = URL(string: "https://api.github.com/repos/\(slug)/releases")!
    aulog("Fetching releases from:", url)
    
    guard let task = try await URLSession.shared.dataTask(with: url, proxy: proxy)?.validate() else {
      aulog("Error: Failed to fetch releases")
      throw Error.bundleExecutableURL
    }
    let releases = try JSONDecoder().decode([Release].self, from: task.data)
    aulog("Found", releases.count, "releases")
    
    notifyReleasesDidChange(releases)
    
    guard let (release, asset) = try releases.findViableUpdate(appVersion: currentVersion, releasePrefix: self.releasePrefix, prerelease: self.allowPrereleases) else {
      throw Error.noValidUpdate
    }
    
    notifyStateChanged(newState: .newVersionDetected(release, asset))
    
    if let bundle = try await update(with: asset, belongs: release) {
      /// @deprecated
      Task { @MainActor in
        self.downloadedAppBundle = bundle
      }
      /// in new version:
      notifyStateChanged(newState: .downloaded(release, asset, bundle))
    }
  }
  
  public func installThrowing(_ downloadedAppBundle: Bundle) throws {
    aulog("Starting installation process")
    let installedAppBundle = Bundle.main
    guard let exe = downloadedAppBundle.executable, exe.exists else {
      aulog("Error: Invalid downloaded bundle - executable not found")
      throw Error.invalidDownloadedBundle
    }
    let finalExecutable = installedAppBundle.path/exe.relative(to: downloadedAppBundle.path)
    
    // 创建临时备份目录
    let backupDir = try FileManager.default.url(for: .itemReplacementDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: installedAppBundle.bundleURL,
                                                create: true)
    let backupPath = backupDir.appendingPathComponent("\(installedAppBundle.bundleIdentifier ?? "app")-backup.app")
    do {
      aulog("Creating backup at:", backupPath)
      // 备份当前应用
      
      if installedAppBundle.path.exists {
        try FileManager.default
          .copyItem(
            atPath: installedAppBundle.path.string,
            toPath: backupPath.absoluteString
          )
        aulog("Backup created successfully")
      }
      
      aulog("Replacing application...")
      // 删除旧应用并移动新应用
      try installedAppBundle.path.delete()
      try downloadedAppBundle.path.move(to: installedAppBundle.path)
      aulog("Application replaced successfully")
      
      // 验证新应用是否完整
      guard Bundle(url: installedAppBundle.bundleURL) != nil else {
        throw Error.invalidDownloadedBundle
      }
      
      aulog("Attempting to restart application using AppleScript")
      let script = """
            tell application "\(installedAppBundle.bundleIdentifier ?? "")"
                quit
                delay 1
                activate
            end tell
            """
      
      let appleScript = NSAppleScript(source: script)
      var error: NSDictionary?
      appleScript?.executeAndReturnError(&error)
      
      if error != nil {
        aulog("Warning: AppleScript failed, falling back to direct launch")
        // 如果 AppleScript 失败，回退到直接启动
        let proc = Process()
        if #available(OSX 10.13, *) {
          proc.executableURL = finalExecutable.url
        } else {
          proc.launchPath = finalExecutable.string
        }
        proc.launch()
        NSApp.terminate(self)
      }
      
      aulog("Cleaning up backup")
      try? FileManager.default.removeItem(at: backupPath)
      
    } catch {
      aulog("Error during installation:", error)
      // 发生错误时恢复备份
      if FileManager.default.fileExists(atPath: backupPath.absoluteString) {
        try? FileManager.default
          .removeItem(at: installedAppBundle.bundleURL)
        _ = try? FileManager.default
          .moveItem(
            atPath: backupPath.absoluteString,
            toPath: installedAppBundle.bundleURL.absoluteString
          )
      }
      throw error
    }
  }
  
  private func notifyStateChanged(newState: UpdateState) {
    Task { @MainActor in
      state = newState
    }
  }
  
  private func notifyReleasesDidChange(_ releases: [Release]) {
    Task { @MainActor in
      self.releases = releases
    }
  }
}

public struct Release: Decodable {
  let tag_name: Version
  public var tagName: Version { tag_name }
  
  public let prerelease: Bool
  public struct Asset: Decodable {
    public let name: String
    let browser_download_url: URL
    public var downloadUrl: URL { browser_download_url }
    
    let content_type: ContentType
    public var contentTyle: ContentType { content_type }
  }
  public let assets: [Asset]
  public let body: String
  public let name: String
  
  let html_url: String
  public var htmlUrl: String { html_url }
  
  func viableAsset(forRelease releasePrefix: String) -> Asset? {
    return assets.first(where: { (asset) -> Bool in
      let prefix = "\(releasePrefix.lowercased())-\(tag_name)"
      let name = (asset.name as NSString).deletingPathExtension.lowercased()
      let fileExtension = (asset.name as NSString).pathExtension
      
      aulog("name, content_type, prefix, fileExtension", name, asset.content_type, prefix, fileExtension)
      
      switch (name, asset.content_type, fileExtension) {
      case ("\(prefix).tar", .tar, "tar"):
        return true
      case (prefix, .zip, "zip"):
        return true
      default:
        return false
      }
    })
  }
}

public enum ContentType: Decodable {
  public init(from decoder: Decoder) throws {
    switch try decoder.singleValueContainer().decode(String.self) {
    case "application/x-bzip2", "application/x-xz", "application/x-gzip":
      self = .tar
    case "application/zip":
      self = .zip
    default:
      self = .unknown
    }
  }
  
  case zip
  case tar
  case unknown
}

extension Release: Comparable {
  public static func < (lhs: Release, rhs: Release) -> Bool {
    return lhs.tag_name < rhs.tag_name
  }
  
  public static func == (lhs: Release, rhs: Release) -> Bool {
    return lhs.tag_name == rhs.tag_name
  }
}

private extension Array where Element == Release {
  func findViableUpdate(appVersion: Version, releasePrefix: String, prerelease: Bool) throws -> (Release, Release.Asset)? {
    aulog(appVersion, "releasePrefix:", releasePrefix, "prerelease", prerelease, "in", self)
    
    let suitableReleases = prerelease ? self : filter { !$0.prerelease }
    aulog("found releases", suitableReleases)
    
    guard let latestRelease = suitableReleases.sorted().last else { return nil }
    aulog("latestRelease", latestRelease)
    
    guard appVersion < latestRelease.tag_name else { throw AUError.cancelled }
    aulog("\(appVersion) < \(latestRelease.tag_name)")
    
    guard let asset = latestRelease.viableAsset(forRelease: releasePrefix) else { return nil }
    aulog("found asset", latestRelease, asset)
    
    return (latestRelease, asset)
  }
}

private func unzip(_ url: URL, contentType: ContentType) async throws -> URL? {
  
  let proc = Process()
  if #available(OSX 10.13, *) {
    proc.currentDirectoryURL = url.deletingLastPathComponent()
  } else {
    proc.currentDirectoryPath = url.deletingLastPathComponent().path
  }
  
  switch contentType {
  case .tar:
    proc.launchPath = "/usr/bin/tar"
    proc.arguments = ["xf", url.path]
  case .zip:
    proc.launchPath = "/usr/bin/unzip"
    proc.arguments = [url.path]
  default:
    throw AUError.badInput
  }
  
  func findApp() async throws -> URL? {
    let cnts = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.isDirectoryKey], options: .skipsSubdirectoryDescendants)
    for url in cnts {
      guard url.pathExtension == "app" else { continue }
      guard let foo = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, foo else { continue }
      return url
    }
    return nil
  }
  
  let _ = try await proc.launching()
  return try await findApp()
}

public extension Bundle {
  func isCodeSigned() async -> Bool {
    let proc = Process()
    proc.launchPath = "/usr/bin/codesign"
    proc.arguments = ["-dv", bundlePath]
    return (try? await proc.launching()) != nil
  }
  
  func codeSigningIdentity() async throws -> String? {
    let proc = Process()
    proc.launchPath = "/usr/bin/codesign"
    proc.arguments = ["-dvvv", bundlePath]
    
    let (_, err) = try await proc.launching()
    guard let errInfo = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.split(separator: "\n") else {
      return nil
    }
    let result = errInfo.filter { $0.hasPrefix("Authority=") }
      .first.map { String($0.dropFirst(10)) }
    
    aulog("result \(String(describing: result))")
    
    return result
  }
}
