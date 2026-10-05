import Cocoa
import SwiftUI
import NetFS
import Darwin

let fm = FileManager.default
let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QuarkCinema")
let checkOnly = CommandLine.arguments.contains("--check")
let backend = URL(string: "http://127.0.0.1:18080/")!
let server = URL(string: "http://127.0.0.1:18082/")!

enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
func readSecret(_ name: String) throws -> String {
    let value = try String(contentsOf: support.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { throw Failure.message("登录信息缺失，请重新配置夸克登录。") }
    return value
}
func status(_ password: String, path: String = "", endpoint: URL = backend) -> Int {
    var request = URLRequest(url: path.isEmpty ? endpoint : endpoint.appendingPathComponent(path))
    request.httpMethod = "PROPFIND"
    request.timeoutInterval = 4
    request.setValue("0", forHTTPHeaderField: "Depth")
    request.setValue("Basic " + Data("quark:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    let sem = DispatchSemaphore(value: 0)
    var code = 0
    URLSession.shared.dataTask(with: request) { _, response, _ in
        code = (response as? HTTPURLResponse)?.statusCode ?? 0
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 5)
    return code
}
func existingMount() -> String? {
    var entries: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&entries, MNT_NOWAIT)
    guard let entries = entries else { return nil }
    for i in 0..<Int(count) {
        var entry = entries[i]
        let source = withUnsafePointer(to: &entry.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        if let url = URL(string: source), url.host == "127.0.0.1", url.port == 18082 {
            return withUnsafePointer(to: &entry.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        }
    }
    return nil
}
func connect() throws -> URL {
    let password = try readSecret("webdav.password")
    var code = status(password)
    if code == 0 {
        let cookie = try readSecret("quark.cookie")
        let log = support.appendingPathComponent("service.log")
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        let p = Process()
        p.executableURL = Bundle.main.resourceURL!.appendingPathComponent("quarkdrive-webdav")
        p.arguments = ["--host", "127.0.0.1", "-p", "18080", "--read-only", "--no-self-upgrade", "-I"]
        var env = ProcessInfo.processInfo.environment
        env["QUARK_COOKIE"] = cookie
        env["WEBDAV_AUTH_USER"] = "quark"
        env["WEBDAV_AUTH_PASSWORD"] = password
        p.environment = env
        p.standardOutput = handle; p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.3)
            code = status(password)
            if code != 0 { break }
            if !p.isRunning { break }
        }
    }
    guard code == 207 else { throw Failure.message("夸克连接失败（状态 \(code)）。请检查网络和夸克登录状态，然后再次打开。") }
    let rootPath = try readSecret("library-root.txt").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard status(password, path: rootPath) == 207 else {
        throw Failure.message("暂时无法读取影视目录。请检查网络，或更新已过期的夸克登录信息。")
    }
    return backend.appendingPathComponent(rootPath, isDirectory: true)
}

struct Entry {
    let url: URL
    let directory: Bool
    var name: String { url.lastPathComponent }
}
final class DAVParser: NSObject, XMLParserDelegate {
    var entries: [Entry] = []; var href = ""; var directory = false; var field = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        field = name.components(separatedBy: ":").last!
        if field == "response" { href = ""; directory = false }
        if field == "collection" { directory = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if field == "href" { href += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name.components(separatedBy: ":").last == "response", let url = URL(string: href, relativeTo: backend)?.absoluteURL,
           url.host == backend.host, url.port == backend.port {
            entries.append(Entry(url: url, directory: directory))
        }
        field = ""
    }
}
func requestData(_ url: URL, method: String = "GET") throws -> Data {
    if method == "GET" {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--show-error", "--fail", "--location", "--max-time", "35", "--retry", "1", "--config", "-"]
        let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let auth = Data("quark:\(try readSecret("webdav.password"))".utf8).base64EncodedString()
        let config = "url = \"\(url.absoluteString)\"\nheader = \"Authorization: Basic \(auth)\"\n"
        try process.run(); input.fileHandleForWriting.write(Data(config.utf8)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.message("字幕下载暂时失败，请检查网络后再点一次播放。") }
        return data
    }
    var req = URLRequest(url: url); req.httpMethod = method; req.timeoutInterval = 30
    req.setValue("Basic " + Data("quark:\(try readSecret("webdav.password"))".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    if method == "PROPFIND" { req.setValue("1", forHTTPHeaderField: "Depth") }
    let sem = DispatchSemaphore(value: 0)
    var result: Result<Data, Error> = .failure(Failure.message("连接超时，请重试。"))
    let task = URLSession.shared.dataTask(with: req) { data, response, error in
        if let error = error { result = .failure(error) }
        else if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let data = data { result = .success(data) }
        else { result = .failure(Failure.message("无法读取网盘，请检查网络或夸克登录状态。")) }
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + 35) == .timedOut { task.cancel(); throw Failure.message("连接超时，请重试。") }
    return try result.get()
}
func listing(_ url: URL) throws -> [Entry] {
    let parser = DAVParser(); let xml = XMLParser(data: try requestData(url, method: "PROPFIND")); xml.delegate = parser
    guard xml.parse() else { throw Failure.message("目录数据无法读取，请重试。") }
    return parser.entries.filter { $0.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.sorted {
        if $0.directory != $1.directory { return $0.directory }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
}
let videos: Set<String> = ["mkv", "mp4", "avi", "mov", "m4v", "ts", "webm"]
let subtitles: Set<String> = ["srt", "ass", "ssa", "vtt", "sub"]
func episode(_ name: String) -> String? {
    let pattern = #"(?i)s\d{1,2}e\d{1,3}"#
    guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
    return String(name[range]).lowercased()
}
func matchingSubtitles(_ video: Entry, entries: [Entry]) -> [Entry] {
    let stem = video.url.deletingPathExtension().lastPathComponent.lowercased()
    return entries.filter { item in
        guard !item.directory, subtitles.contains(item.url.pathExtension.lowercased()) else { return false }
        let sub = item.url.deletingPathExtension().lastPathComponent.lowercased()
        return sub == stem || sub.hasPrefix(stem + ".") || (episode(stem) != nil && episode(stem) == episode(sub))
    }
}

func ipc(_ socketPath: String, _ command: [Any]) throws -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure.message("无法连接播放器。") }
    defer { close(fd) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.message("播放器连接路径过长。") }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in socketPath.withCString { strcpy(dst, $0) } } }
    let code = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard code == 0 else { throw Failure.message("正在等待播放器启动。") }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var data = try JSONSerialization.data(withJSONObject: ["command": command, "request_id": 42]); data.append(10)
    let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, data.count) }
    guard sent == data.count else { throw Failure.message("播放器连接中断。") }
    var received = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
    while received.count < 1_048_576 {
        let n = Darwin.read(fd, &buffer, buffer.count)
        guard n > 0 else { throw Failure.message("播放器暂时没有响应。") }
        received.append(contentsOf: buffer.prefix(n))
        while let end = received.firstIndex(of: 10) {
            let line = received.prefix(upTo: end); received.removeSubrange(...end)
            if let json = try JSONSerialization.jsonObject(with: line) as? [String: Any], json["request_id"] as? Int == 42 { return json }
        }
    }
    throw Failure.message("播放器响应异常。")
}

func playVideo(_ item: Entry, entries: [Entry]) throws -> Int {
    let subs = matchingSubtitles(item, entries: entries)
                let cli = "/Applications/IINA.app/Contents/MacOS/iina-cli"
                guard fm.isExecutableFile(atPath: cli) else { throw Failure.message("没有找到 IINA，请将 IINA 安装到应用程序文件夹。") }
                let cache = support.appendingPathComponent("Playback", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let socketPath = support.appendingPathComponent("p-" + String(UUID().uuidString.prefix(8)) + ".sock").path
                var args = ["--no-stdin", "--separate-windows", "--mpv-input-ipc-server=" + socketPath, "--mpv-force-media-title=" + item.name]
                var subtitlePaths: [String] = []
                var loaded = 0
                for sub in subs {
                    do {
                        let data = try requestData(sub.url)
                        let dest = cache.appendingPathComponent(sub.name)
                        try data.write(to: dest); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                        subtitlePaths.append(dest.path)
                    }
                }
                var url = URLComponents(url: item.url, resolvingAgainstBaseURL: false)!
                url.user = "quark"; url.password = try readSecret("webdav.password")
                let playlist = cache.appendingPathComponent("play.m3u")
                try ("#EXTM3U\n" + url.url!.absoluteString + "\n").write(to: playlist, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: playlist.path)
                args.append(playlist.path)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = args
                configuration.createsNewApplicationInstance = true
                configuration.activates = true
                let done = DispatchSemaphore(value: 0)
                var launchError: Error?
                DispatchQueue.main.async {
                    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/IINA.app", isDirectory: true), configuration: configuration) { _, error in
                        launchError = error; done.signal()
                    }
                }
                guard done.wait(timeout: .now() + 15) == .success else { throw Failure.message("IINA 启动超时，请重试。") }
                if let error = launchError { throw error }
                var ready = false
                let deadline = Date().addingTimeInterval(120)
                while Date() < deadline {
                    if let tracks = try? ipc(socketPath, ["get_property", "track-list"])["data"] as? [[String: Any]], tracks.contains(where: { $0["type"] as? String == "video" }) { ready = true; break }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                guard ready else { throw Failure.message("IINA 已启动，但视频尚未加载成功。请检查网络后重试。") }
                for path in subtitlePaths {
                    let response = try ipc(socketPath, ["sub-add", path, loaded == 0 ? "select" : "auto"])
                    guard response["error"] as? String == "success" else { throw Failure.message("视频已打开，但字幕加载失败。请在 IINA 的字幕菜单中手动加载。") }
                    loaded += 1
                }
                if loaded > 0 {
                    _ = try ipc(socketPath, ["set_property", "sub-visibility", true])
                    let tracks = try ipc(socketPath, ["get_property", "track-list"])["data"] as? [[String: Any]] ?? []
                    guard tracks.contains(where: { $0["type"] as? String == "sub" && $0["external"] as? Bool == true && $0["selected"] as? Bool == true }) else { throw Failure.message("字幕已发送，但未能确认选中。请查看 IINA 的字幕菜单。") }
                }
                try socketPath.write(to: support.appendingPathComponent("last-player-socket.txt"), atomically: true, encoding: .utf8)
                return loaded
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255) }
}
struct Series: Identifiable, Equatable {
    let id: String; let title: String; let english: String; let years: String
    let description: String; let seasons: Int; let background: UInt32; let foreground: UInt32; let accent: UInt32
    var dark: Bool { id != "tokyo" }
    var font: Font.Design { id == "wire" ? .monospaced : .serif }
    var place: String { id == "wire" ? "BALTIMORE · MAJOR CRIMES" : id == "suits" ? "NEW YORK · PEARSON HARDMAN" : "TOKYO · CITY JOURNAL" }
    static let all = [
        Series(id: "suits", title: "金装律师", english: "SUITS", years: "2011—2019", description: "走进曼哈顿的律所。\n一场关于野心、忠诚与规则的博弈。", seasons: 9, background: 0x191a19, foreground: 0xf2e7d5, accent: 0xcaa66c),
        Series(id: "wire", title: "火线", english: "THE WIRE", years: "2002—2008", description: "一座城市，两边的人。\n从街角到重案组，走进巴尔的摩。", seasons: 5, background: 0x161d1e, foreground: 0xe7e9df, accent: 0xd6b862),
        Series(id: "tokyo", title: "东京女子图鉴", english: "TOKYO GIRL", years: "2016—2017", description: "从秋田到东京。\n住过的街区，成为人生的章节。", seasons: 1, background: 0xf1ece4, foreground: 0x342f32, accent: 0xab5267)
    ]
    func matches(_ name: String) -> Bool { id == "suits" ? name.contains("金装") : id == "wire" ? name.contains("火线") : name.contains("东京女子") }
}
func seasonNumber(_ name: String) -> Int? {
    let patterns = [#"(?i)(?:season\s*|\bS)(\d{1,2})"#, #"第\s*(\d+)\s*季"#]
    for pattern in patterns {
        let r = try! NSRegularExpression(pattern: pattern)
        if let m = r.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), let range = Range(m.range(at: 1), in: name) { return Int(name[range]) }
    }; return nil
}
func episodeNumber(_ item: Entry) -> String {
    if let e = episode(item.name), let r = e.range(of: "e", options: .backwards) { return String(e[r.upperBound...]) }
    return "—"
}
let episodeTitles: [String: String] = {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("posters/episode-titles.json"), let data = try? Data(contentsOf: url) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
}()
func friendlyName(_ item: Entry) -> String {
    let key = item.name.contains("金装") || item.name.lowercased().contains("suits") ? "suits" : item.name.lowercased().contains("wire") ? "wire" : "tokyo"
    if let e = episode(item.name), let title = episodeTitles[key + ":" + e] { return title }

    var name = item.url.deletingPathExtension().lastPathComponent
    if let r = name.range(of: #"(?i)s\d{1,2}e\d{1,3}[ ._-]*"#, options: .regularExpression) { name = String(name[r.upperBound...]) }
    if let r = name.range(of: #"(?i)[ .\[(]*(?:1080p|2160p|720p|BluRay|WEB-DL).*"#, options: .regularExpression) { name = String(name[..<r.lowerBound]) }
    return name.replacingOccurrences(of: ".", with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
}
struct WatchRecord: Codable { let url: String; let name: String; let series: String; let season: Int; let date: Date }
final class CinemaModel: ObservableObject {
    @Published var selected: Series?
    @Published var roots: [String: Entry] = [:]
    @Published var seasonEntries: [Int: Entry] = [:]
    @Published var activeSeason = 1
    @Published var entries: [Entry] = []
    @Published var loading = false
    @Published var playing = false
    @Published var statusText = "正在连接网盘…"
    @Published var errorText: String?
    @Published var search = ""
    @Published var history: [String: WatchRecord] = [:]
    var generation = 0
    let historyFile = support.appendingPathComponent("watch-history.json")
    init() { if let d = try? Data(contentsOf: historyFile), let h = try? JSONDecoder().decode([String: WatchRecord].self, from: d) { history = h }; refresh() }
    var filtered: [Entry] { entries.filter { !$0.directory && videos.contains($0.url.pathExtension.lowercased()) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || friendlyName($0).localizedCaseInsensitiveContains(search)) } }
    var extraFolders: [Entry] { entries.filter { $0.directory } }
    func refresh() {
        if loading { return }; loading = true
        DispatchQueue.global().async {
            let result = Result { try listing(connect()) }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let items):
                    self.roots = Dictionary(uniqueKeysWithValues: Series.all.compactMap { show in items.first(where: { $0.directory && show.matches($0.name) }).map { (show.id, $0) } })
                    self.statusText = "网盘已连接"
                    if let show = self.selected { self.open(show) }
                case .failure(let error): self.statusText = "连接失败"; self.errorText = error.localizedDescription
                }
            }
        }
    }
    func home() { generation += 1; selected = nil; entries = []; search = ""; loading = false }
    func open(_ show: Series) {
        guard let folder = roots[show.id] else { errorText = "网盘里暂时没有找到这部剧的目录，请刷新片库。"; return }
        generation += 1; let token = generation
        selected = show; loading = true; entries = []; seasonEntries = [:]; search = ""
        DispatchQueue.global().async {
            let result = Result { try listing(folder.url) }
            DispatchQueue.main.async {
                guard token == self.generation else { return }; self.loading = false
                switch result {
                case .success(let items):
                    var seasons: [Int: Entry] = [:]
                    for item in items where item.directory { if let n = seasonNumber(item.name) { seasons[n] = item } }
                    if seasons.isEmpty { self.seasonEntries = [1: folder]; self.activeSeason = 1; self.entries = items }
                    else { self.seasonEntries = seasons; let preferred = self.history[show.id]?.season ?? seasons.keys.min()!; self.loadSeason(seasons[preferred] != nil ? preferred : seasons.keys.min()!) }
                case .failure(let error): self.errorText = error.localizedDescription
                }
            }
        }
    }
    func loadSeason(_ number: Int) { guard let folder = seasonEntries[number] else { return }; activeSeason = number; loadFolder(folder) }
    func loadFolder(_ folder: Entry) {
        generation += 1; let token = generation; loading = true; search = ""
        DispatchQueue.global().async {
            let result = Result { try listing(folder.url) }
            DispatchQueue.main.async {
                guard token == self.generation else { return }; self.loading = false
                switch result { case .success(let items): self.entries = items; case .failure(let error): self.errorText = error.localizedDescription }
            }
        }
    }
    func play(_ item: Entry) {
        guard !playing, let show = selected else { return }
        playing = true; statusText = "正在打开 IINA…"
        let files = entries; let season = activeSeason
        DispatchQueue.global().async {
            let result = Result { try playVideo(item, entries: files) }
            DispatchQueue.main.async {
                self.playing = false
                switch result {
                case .success(let count):
                    self.statusText = count > 0 ? "IINA 正在播放 · 外挂字幕已启用" : "IINA 正在播放"
                    self.history[show.id] = WatchRecord(url: item.url.absoluteString, name: item.name, series: show.id, season: season, date: Date())
                    if let data = try? JSONEncoder().encode(self.history) { try? data.write(to: self.historyFile, options: .atomic); try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.historyFile.path) }
                case .failure(let error): self.statusText = "播放未完成"; self.errorText = error.localizedDescription
                }
            }
        }
    }
    func playLast(_ record: WatchRecord) {
        guard !playing, let url = URL(string: record.url), let show = Series.all.first(where: { $0.id == record.series }) else { return }
        open(show); activeSeason = record.season; playing = true; statusText = "正在打开上次观看…"
        DispatchQueue.global().async {
            let result = Result { () -> Int in let items = try listing(url.deletingLastPathComponent()); return try playVideo(Entry(url: url, directory: false), entries: items) }
            DispatchQueue.main.async { self.playing = false; switch result { case .success: self.statusText = "IINA 正在播放"; self.open(show); case .failure(let error): self.errorText = error.localizedDescription } }
        }
    }
}
struct Poster: View {
    let key: String
    var body: some View {
        Group {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("posters/" + key + ".jpg"), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { ZStack { Color(hex: 0x303736); Image(systemName: "film").font(.system(size: 36)).foregroundColor(.gray) } }
        }
    }
}
struct CinemaView: View {
    @ObservedObject var model: CinemaModel
    var theme: Series? { model.selected }
    var fg: Color { Color(hex: theme?.foreground ?? 0xf1eee8) }
    var accent: Color { Color(hex: theme?.accent ?? 0xc5af83) }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                HStack {
                    if model.selected != nil { Button(action: model.home) { Image(systemName: "chevron.left"); Text("片库") }.buttonStyle(.plain) }
                    Spacer()
                    if model.loading || model.playing { ProgressView().controlSize(.small) }
                    Text(model.statusText).font(.system(size: 12)).foregroundColor(fg.opacity(0.6))
                    Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).disabled(model.loading || model.playing).help("刷新网盘片库")
                }.padding(.horizontal, 36).frame(height: 56)
                if let show = model.selected { detail(show) } else { library }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: theme?.background ?? 0x141817))
        }.foregroundColor(fg)
        .preferredColorScheme(theme?.id == "tokyo" ? .light : .dark)
        .alert("暂时无法完成", isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } })) { Button("好") { model.errorText = nil } } message: { Text(model.errorText ?? "") }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let path = Bundle.main.url(forResource: "QuarkCinema-v3", withExtension: "icns"), let icon = NSImage(contentsOf: path) { Image(nsImage: icon).resizable().frame(width: 35, height: 35) }
                Text("fuck quark").font(.system(size: 18, weight: .semibold))
            }.padding(.bottom, 44)
            Button(action: model.home) { Label("我的片库", systemImage: "square.grid.2x2").font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(model.selected == nil ? Color.white.opacity(0.09) : .clear).cornerRadius(9) }.buttonStyle(.plain)
            Text("收藏的剧集").font(.system(size: 12)).foregroundColor(.white.opacity(0.4)).padding(.top, 34).padding(.bottom, 14).padding(.leading, 12)
            ForEach(Series.all) { show in
                Button { model.open(show) } label: {
                    HStack { Rectangle().fill(Color(hex: show.accent)).frame(width: 3, height: 18); Text(show.title).font(.system(size: 14)); Spacer() }
                        .padding(12).background(model.selected?.id == show.id ? Color.white.opacity(0.09) : .clear).cornerRadius(9)
                }.buttonStyle(.plain).padding(.bottom, 4)
            }
            Spacer()
            HStack(spacing: 8) { Image(systemName: "play.circle.fill"); Text("使用 IINA 播放") }.font(.system(size: 13)).foregroundColor(.white.opacity(0.65))
            Menu { Link("海报与资料：TVmaze", destination: URL(string: "https://www.tvmaze.com")!); Link("quarkdrive-webdav", destination: URL(string: "https://github.com/chenqimiao/quarkdrive-webdav")!); Link("IINA", destination: URL(string: "https://iina.io")!) } label: { Text("关于与资料来源").font(.system(size: 11)).foregroundColor(.white.opacity(0.35)) }.menuStyle(.borderlessButton).padding(.top, 16)
        }.padding(22).frame(width: 210).frame(maxHeight: .infinity).background(Color(hex: 0x0e1211)).foregroundColor(Color(hex: 0xe9e7df))
    }
    var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 10) { Text("今晚，想看哪一部？").font(.system(size: 34, weight: .medium, design: .serif)); Text("我的片库").font(.system(size: 15)).foregroundColor(fg.opacity(0.5)) }.padding(.top, 16)
                HStack(alignment: .top, spacing: 25) {
                    ForEach(Series.all) { show in
                        Button { model.open(show) } label: {
                            VStack(alignment: .leading, spacing: 13) {
                                Poster(key: show.id).frame(height: 355).clipped().cornerRadius(9).overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.12), lineWidth: 1))
                                Text(show.title).font(.system(size: 23, weight: .semibold))
                                HStack { Text(show.english).font(.system(size: 11, weight: .medium)).tracking(1); Spacer(); Text("\(show.seasons) 季").font(.system(size: 12)) }.foregroundColor(fg.opacity(0.5))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                if let record = model.history.values.sorted(by: { $0.date > $1.date }).first, let show = Series.all.first(where: { $0.id == record.series }) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("上次看到").font(.system(size: 18, weight: .medium))
                        HStack(spacing: 16) {
                            Poster(key: show.id).frame(width: 44, height: 62).clipped().cornerRadius(4)
                            VStack(alignment: .leading, spacing: 6) { Text(show.title).font(.system(size: 15, weight: .medium)); Text("第 \(record.season) 季 · " + friendlyName(Entry(url: URL(string: record.url)!, directory: false))).font(.system(size: 13)).foregroundColor(fg.opacity(0.5)).lineLimit(1) }
                            Spacer(); Button { model.playLast(record) } label: { Label("继续观看", systemImage: "play.fill").padding(.horizontal, 16).padding(.vertical, 10).background(accent).foregroundColor(.black).cornerRadius(7) }.buttonStyle(.plain).disabled(model.playing)
                        }.padding(16).background(Color.white.opacity(0.045)).cornerRadius(10)
                    }
                }
            }.padding(.horizontal, 36).padding(.bottom, 35)
        }
    }
    func detail(_ show: Series) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 30) {
                    Poster(key: show.id).frame(width: 159, height: 230).clipped().cornerRadius(show.id == "wire" ? 1 : 5).shadow(color: .black.opacity(0.2), radius: 12, y: 8)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(show.place).font(.system(size: 11, weight: .medium, design: show.font)).tracking(2).foregroundColor(accent)
                        Text(show.english).font(.system(size: show.id == "tokyo" ? 42 : 54, weight: .medium, design: show.font)).tracking(show.id == "wire" ? -3 : 3)
                        HStack(spacing: 18) { Text(show.title).font(.system(size: 21, weight: .medium)); Text(show.years + "  ·  \(show.seasons) 季").font(.system(size: 13)).foregroundColor(fg.opacity(0.5)) }
                        Text(show.description).font(.system(size: 14)).lineSpacing(6).foregroundColor(fg.opacity(0.62)).padding(.top, 2)
                    }.padding(.top, 10)
                    Spacer(minLength: 0)
                }.padding(.top, 10)
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text(show.id == "wire" ? "案卷 / 季" : "选择一季").font(.system(size: 16, weight: .medium, design: show.font)); Spacer(); Text("\(model.seasonEntries.count) 季在库").font(.system(size: 12)).foregroundColor(fg.opacity(0.45)) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 13) {
                            ForEach(model.seasonEntries.keys.sorted(), id: \.self) { n in
                                Button { model.loadSeason(n) } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        Poster(key: show.id + "-s\(n)").frame(width: 94, height: 137).clipped().cornerRadius(show.id == "wire" ? 1 : 4).overlay(RoundedRectangle(cornerRadius: show.id == "wire" ? 1 : 4).stroke(model.activeSeason == n ? accent : .clear, lineWidth: 3))
                                        Text("第 \(n) 季").font(.system(size: 12, weight: model.activeSeason == n ? .semibold : .regular)).foregroundColor(model.activeSeason == n ? accent : fg.opacity(0.55))
                                    }.padding(3)
                                }.buttonStyle(.plain).disabled(model.loading)
                            }
                        }.padding(3)
                    }
                }
                HStack {
                    Text(show.id == "wire" ? "EPISODES / 第 \(model.activeSeason) 季" : "第 \(model.activeSeason) 季").font(.system(size: 20, weight: .medium, design: show.font))
                    Text("\(model.filtered.count) 集").font(.system(size: 13)).foregroundColor(fg.opacity(0.45))
                    Spacer(); HStack { Image(systemName: "magnifyingglass"); TextField("搜索本季", text: $model.search).textFieldStyle(.plain) }.font(.system(size: 13)).padding(9).frame(width: 180).background(fg.opacity(0.06)).cornerRadius(7)
                }
                VStack(spacing: 0) {
                    ForEach(model.extraFolders, id: \.url) { folder in Button { model.loadFolder(folder) } label: { HStack { Image(systemName: "folder"); Text(folder.name); Spacer(); Image(systemName: "chevron.right") }.padding(16) }.buttonStyle(.plain) }
                    ForEach(model.filtered, id: \.url) { item in
                        Button { model.play(item) } label: {
                            HStack(spacing: 19) {
                                Text(episodeNumber(item)).font(.system(size: 20, weight: .light, design: .monospaced)).foregroundColor(accent).frame(width: 34)
                                VStack(alignment: .leading, spacing: 5) { Text(friendlyName(item)).font(.system(size: 15, weight: .medium)).lineLimit(1); Text(item.name.contains("2160") ? "4K 原文件" : item.name.contains("1080") ? "1080p 原文件" : "原文件").font(.system(size: 11)).foregroundColor(fg.opacity(0.4)) }
                                Spacer()
                                if !matchingSubtitles(item, entries: model.entries).isEmpty { Label("外挂字幕", systemImage: "captions.bubble").font(.system(size: 12)).foregroundColor(fg.opacity(0.5)) }
                                Image(systemName: "play.circle.fill").font(.system(size: 25)).foregroundColor(accent)
                            }.padding(.horizontal, 18).padding(.vertical, 16).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.playing || model.loading).help(item.name)
                        Rectangle().fill(fg.opacity(0.08)).frame(height: 1)
                    }
                    if !model.loading && model.filtered.isEmpty && model.extraFolders.isEmpty { Text(model.search.isEmpty ? "这个目录暂时没有视频" : "没有找到匹配的剧集").foregroundColor(fg.opacity(0.5)).padding(30) }
                }.background(fg.opacity(0.025)).cornerRadius(show.id == "wire" ? 1 : 8)
            }.padding(.horizontal, 36).padding(.bottom, 36)
        }
    }
}
final class CinemaDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var model: CinemaModel!
    func applicationDidFinishLaunching(_ note: Notification) {
        model = CinemaModel()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "fuck quark"; window.minSize = NSSize(width: 1120, height: 760); window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CinemaView(model: model)); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func exportScreenshot(_ sender: Any?) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/QuarkCinema", isDirectory: true)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true); try data.write(to: folder.appendingPathComponent((model.selected?.id ?? "library") + ".png")) }
        catch { model.errorText = error.localizedDescription }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
if checkOnly {
    do { let root = try connect(); print("连接正常，影视目录 \(try listing(root).count) 项") } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    if let icon = Bundle.main.url(forResource: "QuarkCinema-v3", withExtension: "icns") { app.applicationIconImage = NSImage(contentsOf: icon) }
    let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item); let submenu = NSMenu(); submenu.addItem(withTitle: "退出fuck quark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = submenu; app.mainMenu = menu
    let delegate = CinemaDelegate(); app.delegate = delegate
    let fileItem = NSMenuItem(); fileItem.title = "文件"; let fileMenu = NSMenu(title: "文件")
    let export = NSMenuItem(title: "保存界面截图", action: #selector(CinemaDelegate.exportScreenshot(_:)), keyEquivalent: "s"); export.keyEquivalentModifierMask = [.command, .shift]; export.target = delegate; fileMenu.addItem(export); fileItem.submenu = fileMenu; menu.addItem(fileItem)
    app.run()
}
