import Cocoa
import SwiftUI
import WebKit
import CryptoKit

func hasConfiguration() -> Bool {
    ["quark.cookie", "webdav.password", "library-root.txt"].allSatisfy { (try? readSecret($0)) != nil }
}
func savePrivate(_ value: String, name: String) throws {
    try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
    let file = support.appendingPathComponent(name)
    try value.write(to: file, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}
func installedIINA() -> URL? {
    let choices = [URL(fileURLWithPath: "/Applications/IINA.app"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/IINA.app")]
    return choices.first { fm.isExecutableFile(atPath: $0.appendingPathComponent("Contents/MacOS/IINA").path) }
}
func buildLibrary(_ entries: [Entry], root: URL) -> [(Series, Entry)] {
    var result: [(Series, Entry)] = []
    var used = Set<String>()
    for entry in entries where entry.directory {
        if let known = Series.all.first(where: { $0.matches(entry.name) }), !used.contains(known.id) {
            result.append((known, entry)); used.insert(known.id)
        } else {
            let hash = SHA256.hash(data: Data(entry.url.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let show = Series(id: "folder-" + hash, title: entry.name, english: "MY LIBRARY", years: "", description: "从自己的网盘播放原文件。", seasons: 0, background: 0x141817, foreground: 0xf1eee8, accent: 0xc5af83)
            result.append((show, entry))
        }
    }
    if entries.contains(where: { !$0.directory && videos.contains($0.url.pathExtension.lowercased()) }) {
        let show = Series(id: "root-videos", title: "当前目录的视频", english: "MY VIDEOS", years: "", description: "直接放在片库根目录的视频。", seasons: 0, background: 0x141817, foreground: 0xf1eee8, accent: 0xc5af83)
        result.insert((show, Entry(url: root, directory: true)), at: 0)
    }
    return result
}
final class BackendRuntime {
    static let shared = BackendRuntime()
    private let lock = NSRecursiveLock()
    private var child: Process?
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let process = child, process.isRunning { process.terminate(); process.waitUntilExit() }
        child = nil
    }
    func ensureStarted() throws {
        lock.lock(); defer { lock.unlock() }
        let password = try readSecret("webdav.password")
        let code = status(password)
        if code == 207 { return }
        guard code == 0 else { throw Failure.message("本地端口 \(backendPort) 已被其他服务占用，或登录已过期。请关闭其他版本后重新登录。") }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let resources = Bundle.main.resourceURL!
        let binary = resources.appendingPathComponent("backends/\(architecture)/quarkdrive-webdav")
        guard fm.isExecutableFile(atPath: binary.path) else { throw Failure.message("安装包中的网盘组件缺失，请重新下载安装包。") }
        let process = Process(); process.executableURL = binary
        process.arguments = ["--host", "127.0.0.1", "-p", String(backendPort), "--read-only", "--no-self-upgrade", "-I"]
        var env = ProcessInfo.processInfo.environment
        env["QUARK_COOKIE"] = try readSecret("quark.cookie")
        env["WEBDAV_AUTH_USER"] = "quark"; env["WEBDAV_AUTH_PASSWORD"] = password
        process.environment = env
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run(); child = process
        for _ in 0..<35 {
            Thread.sleep(forTimeInterval: 0.35)
            if status(password) == 207 { return }
            if !process.isRunning { break }
        }
        stop(); throw Failure.message("没有连上夸克网盘。请确认网络正常，并重新登录夸克。")
    }
}
func runCommand(_ executable: String, _ arguments: [String]) throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Failure.message("操作没有完成（\(URL(fileURLWithPath: executable).lastPathComponent)）。请检查网络后重试。") }
}
func verifyPlayer(_ app: URL) throws {
    try runCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=anchor apple generic and identifier \"com.colliderli.iina\" and certificate leaf[subject.OU] = \"67CQ77V27R\"", app.path])
}
func installIINA(destinationOverride: URL? = nil, progress: @escaping (String) -> Void) throws {
    if destinationOverride == nil && installedIINA() != nil { return }
    let work = fm.temporaryDirectory.appendingPathComponent("fuckquark-iina-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    let dmg = work.appendingPathComponent("IINA.dmg"), mount = work.appendingPathComponent("volume", isDirectory: true)
    progress("正在从 IINA 官网下载，请稍候…")
    try runCommand("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--connect-timeout", "20", "--max-time", "600", "--retry", "2", "https://dl.iina.io/IINA.v1.5.0.dmg", "--output", dmg.path])
    try fm.createDirectory(at: mount, withIntermediateDirectories: true)
    progress("正在校验并安装 IINA…")
    try runCommand("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, dmg.path])
    defer { try? runCommand("/usr/bin/hdiutil", ["detach", mount.path]) }
    let source = mount.appendingPathComponent("IINA.app")
    try verifyPlayer(source)
    let apps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    try fm.createDirectory(at: apps, withIntermediateDirectories: true)
    let destination = destinationOverride ?? apps.appendingPathComponent("IINA.app")
    guard !fm.fileExists(atPath: destination.path) else { throw Failure.message("个人应用程序目录已有 IINA，请先检查现有安装。") }
    try fm.copyItem(at: source, to: destination)
    do { try verifyPlayer(destination) } catch { try? fm.removeItem(at: destination); throw error }
}
final class LoginSession: NSObject, ObservableObject, WKNavigationDelegate {
    let web: WKWebView
    @Published var message = "在夸克官网完成登录，再点击“登录完成”。"
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(); web.navigationDelegate = self
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.load(URLRequest(url: URL(string: "https://pan.quark.cn/")!))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { message = "登录页加载失败，请检查网络后点“重新加载”。" }
    func cookie(completion: @escaping (String?) -> Void) {
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let values = cookies.filter { ($0.domain == "quark.cn" || $0.domain.hasSuffix(".quark.cn")) && ($0.expiresDate == nil || $0.expiresDate! > Date()) }
            guard values.contains(where: { $0.name == "__puus" }) else { completion(nil); return }
            var pairs: [String: String] = [:]
            for value in values { pairs[value.name] = value.value }
            completion(pairs.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
        }
    }
}
struct LoginWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
struct LoginView: View {
    @StateObject var session = LoginSession()
    let completed: (String) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("登录夸克网盘").font(.title2); Spacer(); Button("重新加载") { session.web.reload() }; Button("取消", action: cancel); Button("登录完成") { session.cookie { value in if let value = value { completed(value) } else { session.message = "还没有读取到登录状态，请先完成官网登录。" } } }.buttonStyle(.borderedProminent) }.padding(18)
            Text(session.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 12)
            LoginWebView(web: session.web)
        }.frame(width: 1000, height: 720)
    }
}
final class SetupModel: ObservableObject {
    @Published var busy = false
    @Published var message = "登录网盘、选择片库，就可以开始。"
    @Published var folders: [Entry] = []
    @Published var current = backend
    @Published var connected = false
    @Published var iinaReady = installedIINA() != nil
    @Published var error: String?
    func connect(cookie: String? = nil) {
        guard !busy else { return }; busy = true; message = "正在连接网盘…"
        DispatchQueue.global().async {
            let previous = try? readSecret("quark.cookie")
            let result = Result { () -> [Entry] in
                if let value = cookie {
                    BackendRuntime.shared.stop()
                    try savePrivate(value, name: "quark.cookie")
                }
                if (try? readSecret("webdav.password")) == nil { try savePrivate(UUID().uuidString + UUID().uuidString, name: "webdav.password") }
                do { try BackendRuntime.shared.ensureStarted(); return try listing(backend).filter { $0.directory } }
                catch {
                    if cookie != nil {
                        BackendRuntime.shared.stop()
                        if let old = previous { try? savePrivate(old, name: "quark.cookie") }
                        else { try? fm.removeItem(at: support.appendingPathComponent("quark.cookie")) }
                    }
                    throw error
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let folders): self.connected = true; self.current = backend; self.folders = folders; self.message = "打开你的影视文件夹，再点击“使用这个目录”。"
                case .failure(let error): self.connected = false; self.error = error.localizedDescription; self.message = "连接未完成，请重试或重新登录。"
                }
            }
        }
    }
    func browse(_ url: URL) {
        guard !busy else { return }; busy = true
        DispatchQueue.global().async {
            let result = Result { try listing(url).filter { $0.directory } }
            DispatchQueue.main.async { self.busy = false; switch result { case .success(let entries): self.current = url; self.folders = entries; case .failure(let error): self.error = error.localizedDescription } }
        }
    }
    func install() {
        guard !busy else { return }; busy = true
        DispatchQueue.global().async {
            let result = Result { try installIINA { value in DispatchQueue.main.async { self.message = value } } }
            DispatchQueue.main.async { self.busy = false; self.iinaReady = installedIINA() != nil; switch result { case .success: self.message = "IINA 已准备好。"; case .failure(let error): self.error = error.localizedDescription } }
        }
    }
    func finish(_ completion: @escaping () -> Void) {
        do { try savePrivate(current.path, name: "library-root.txt"); completion() }
        catch { self.error = error.localizedDescription }
    }
}
struct SetupView: View {
    @StateObject var model = SetupModel()
    @State private var showLogin = false
    @State private var manualCookie = ""
    let completed: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 6) { Text("连接你的私人影院").font(.system(size: 30, weight: .semibold)); Text(model.message).foregroundColor(.secondary) }; Spacer(); if model.busy { ProgressView().controlSize(.small) } }
            HStack { Label(model.iinaReady ? "IINA 已安装" : "准备播放器", systemImage: model.iinaReady ? "checkmark.circle.fill" : "play.circle"); Spacer(); if !model.iinaReady { Button("安装 IINA") { model.install() }.disabled(model.busy); Button("重新检查") { model.iinaReady = installedIINA() != nil }.disabled(model.busy) } }.padding(16).background(Color.white.opacity(0.06)).cornerRadius(12)
            HStack { Label(model.connected ? "夸克网盘已连接" : "登录夸克网盘", systemImage: "externaldrive.badge.wifi"); Spacer(); Button(model.connected ? "切换账号" : "登录夸克") { showLogin = true }.disabled(model.busy); if (try? readSecret("quark.cookie")) != nil && !model.connected { Button("使用已有登录") { model.connect() }.disabled(model.busy) } }
            if model.connected {
                HStack { Text(model.current.path).lineLimit(1).truncationMode(.middle); Spacer(); Button("上一级") { model.browse(model.current.deletingLastPathComponent()) }.disabled(model.current.path == "/" || model.busy) }
                List(model.folders, id: \.url) { folder in Button { model.browse(folder.url) } label: { HStack { Image(systemName: "folder"); Text(folder.name); Spacer(); Image(systemName: "chevron.right") }.contentShape(Rectangle()) }.buttonStyle(.plain).disabled(model.busy) }.frame(minHeight: 160)
            } else {
                Text("登录窗口打开的是夸克官网。登录信息只保存在这台 Mac，不会上传给本项目。IINA 从官网下载安装，不需要管理员密码。").font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("已有 Cookie？手动导入") { SecureField("粘贴自己的夸克 Cookie", text: $manualCookie); Button("连接") { let value = manualCookie.trimmingCharacters(in: .whitespacesAndNewlines); manualCookie = ""; model.connect(cookie: value) }.disabled(manualCookie.isEmpty || model.busy) }
                Spacer()
            }
            if let error = model.error { Text(error).foregroundColor(.orange).font(.callout).textSelection(.enabled) }
            HStack { if hasConfiguration() { Button("返回片库", action: completed).disabled(model.busy) }; Spacer(); Button("使用这个目录，进入片库") { model.finish(completed) }.buttonStyle(.borderedProminent).disabled(!model.connected || !model.iinaReady || model.busy) }
        }.padding(30).frame(width: 780, height: 590).preferredColorScheme(.dark)
        .sheet(isPresented: $showLogin) { LoginView(completed: { value in showLogin = false; model.connect(cookie: value) }, cancel: { showLogin = false }) }
    }
}
