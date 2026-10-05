func runChecks() throws {
    func entry(_ name: String, _ directory: Bool) -> Entry { Entry(url: backend.appendingPathComponent(name, isDirectory: directory), directory: directory) }
    let library = buildLibrary([entry("我的纪录片", true), entry("火线全集", true), entry("火线另一版", true), entry("sample.mp4", false)], root: backend)
    precondition(library.count == 4)
    precondition(Set(library.map { $0.0.id }).count == 4)
    precondition(library.contains { $0.0.id == "wire" })
    precondition(library.contains { $0.0.title == "我的纪录片" })
    precondition(friendlyName(entry("Unknown.S01E01.1080p.mkv", false)) != "A Girl from Akita")
    precondition(seasonNumber("Season 12") == 12)
    let video = entry("Show.S01E01.mkv", false)
    precondition(matchingSubtitles(video, entries: [entry("Show.S01E01.ass", false), entry("Show.S01E02.ass", false)]).count == 1)
    let special = backend.appendingPathComponent("100%20收藏", isDirectory: true)
    precondition(special.path.contains("100%20收藏"))
    try savePrivate("test-only-not-an-account", name: "fixture.txt")
    let attributes = try fm.attributesOfItem(atPath: support.appendingPathComponent("fixture.txt").path)
    precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    print("PASS: arbitrary folders, duplicate known shows, root videos, names, subtitles, percent paths, private permissions")
}
try runChecks()
if CommandLine.arguments.contains("--installer") {
    func checkInstaller() throws {
        let folder = fm.temporaryDirectory.appendingPathComponent("fq-installer-check-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("IINA.app")
        try installIINA(destinationOverride: destination) { print($0) }
        precondition(fm.isExecutableFile(atPath: destination.appendingPathComponent("Contents/MacOS/IINA").path))
        try verifyPlayer(destination)
        print("PASS: official IINA downloaded, mounted, signature checked, installed and cleaned up")
    }
    try checkInstaller()
}
