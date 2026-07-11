import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

private let apiURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
private let keychainService = "Codex Apple Music Last.fm Sync"
private let keychainAccount = NSUserName()
private let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Apple Music Last.fm Sync/state.json")
private let recordSeparator = String(UnicodeScalar(30))
private let fieldSeparator = String(UnicodeScalar(31))

struct Credentials: Codable {
    var api_key: String
    var shared_secret: String
    var session_key: String?
    var username: String?
}

struct SyncState: Codable {
    var submitted: [String: Int] = [:]
}

struct Track {
    let persistentID: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let duration: Double
    let timestamp: Int
}

enum SyncError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(1)
}

func readKeychain() throws -> Credentials {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        throw SyncError.message("API credentials are not in the macOS Keychain.")
    }
    do {
        return try JSONDecoder().decode(Credentials.self, from: data)
    } catch {
        throw SyncError.message("Keychain data is invalid: \(error.localizedDescription)")
    }
}

func writeKeychain(_ credentials: Credentials) throws {
    let data = try JSONEncoder().encode(credentials)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount
    ]
    let attributes: [String: Any] = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecItemNotFound {
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SyncError.message("Could not store credentials in Keychain: \(addStatus)")
        }
    } else if updateStatus != errSecSuccess {
        throw SyncError.message("Could not update Keychain: \(updateStatus)")
    }
}

func runAppleScript(_ source: String) throws -> String {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    input.fileHandleForWriting.write(Data(source.utf8))
    input.fileHandleForWriting.closeFile()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Music.app automation failed."
        throw SyncError.message(message)
    }
    return String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func currentTrack() throws -> [String: String]? {
    let source = #"""
tell application "Music"
    if not (exists current track) then return "NO_TRACK"
    set t to current track
    if player state is playing then
        set stateText to "playing"
    else if player state is paused then
        set stateText to "paused"
    else
        set stateText to "stopped"
    end if
    set fs to ASCII character 31
    return stateText & fs & (persistent ID of t as text) & fs & (name of t as text) & fs & (artist of t as text) & fs & (album of t as text) & fs & (album artist of t as text) & fs & (duration of t as text) & fs & (player position as text)
end tell
"""#
    let output = try runAppleScript(source)
    if output == "NO_TRACK" { return nil }
    let fields = output.components(separatedBy: fieldSeparator)
    guard fields.count == 8 else {
        throw SyncError.message("Could not parse the current Music.app track.")
    }
    return [
        "state": fields[0],
        "persistent_id": fields[1],
        "track": fields[2],
        "artist": fields[3],
        "album": fields[4],
        "album_artist": fields[5],
        "duration": fields[6],
        "position": fields[7]
    ]
}

func recentTracks(sinceDays: Int) throws -> [Track] {
    let seconds = max(0, sinceDays) * 86400
    let source = """
tell application "Music"
    set cutoffDate to (current date) - \(seconds)
    set epochDate to date "Thursday, January 1, 1970 at 00:00:00"
    set rs to ASCII character 30
    set fs to ASCII character 31
    set rows to {}
    set matchingTracks to every file track of library playlist 1 whose played date is greater than cutoffDate
    repeat with t in matchingTracks
        try
            set pDate to played date of t
            if pDate is not missing value and pDate is greater than cutoffDate then
                set playedSeconds to (pDate - epochDate) as integer
                set rowText to (persistent ID of t as text) & fs & (name of t as text) & fs & (artist of t as text) & fs & (album of t as text) & fs & (album artist of t as text) & fs & (duration of t as text) & fs & (playedSeconds as text)
                set end of rows to rowText
            end if
        end try
    end repeat
    set AppleScript's text item delimiters to rs
    return rows as text
end tell
"""
    let output = try runAppleScript(source)
    guard !output.isEmpty else { return [] }
    return output.split(separator: Character(recordSeparator), omittingEmptySubsequences: true).compactMap { row in
        let fields = row.split(separator: Character(fieldSeparator), omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 7,
              let duration = Double(fields[5]),
              let timestampValue = Double(fields[6]),
              timestampValue > 0 else { return nil }
        let timestamp = Int(timestampValue.rounded())
        return Track(
            persistentID: fields[0],
            title: fields[1],
            artist: fields[2],
            album: fields[3],
            albumArtist: fields[4],
            duration: duration,
            timestamp: timestamp
        )
    }
}

func percentEncode(_ value: String) -> String {
    let allowed = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    var output = ""
    for byte in value.utf8 {
        let character = Character(UnicodeScalar(byte))
        if allowed.contains(character) {
            output.append(character)
        } else if byte == 32 {
            output.append("+")
        } else {
            output += String(format: "%%%02X", byte)
        }
    }
    return output
}

func formEncode(_ params: [String: String]) -> Data {
    let body = params.keys.sorted().map { "\(percentEncode($0))=\(percentEncode(params[$0] ?? ""))" }.joined(separator: "&")
    return Data(body.utf8)
}

func md5(_ value: String) -> String {
    Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

func apiSignature(_ params: [String: String], sharedSecret: String) -> String {
    let material = params.keys.sorted().filter { $0 != "format" }.map { "\($0)\(params[$0] ?? "")" }.joined()
    return md5(material + sharedSecret)
}

func apiCall(credentials: Credentials, method: String, parameters: [String: String], signed: Bool = true) async throws -> [String: Any] {
    var params = parameters
    params["method"] = method
    params["api_key"] = credentials.api_key
    if signed {
        params["api_sig"] = apiSignature(params, sharedSecret: credentials.shared_secret)
    }
    params["format"] = "json"
    var request = URLRequest(url: apiURL)
    request.httpMethod = "POST"
    request.setValue("AppleMusicLastFmSync/0.1", forHTTPHeaderField: "User-Agent")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formEncode(params)
    let (data, response) = try await URLSession.shared.data(for: request)
    let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SyncError.message("Last.fm HTTP status \(httpStatus) with invalid JSON.")
    }
    if let error = json["error"] as? Int {
        throw SyncError.message("Last.fm API error \(error): \(json["message"] as? String ?? "unknown error")")
    }
    guard (200..<300).contains(httpStatus) else {
        throw SyncError.message("Last.fm HTTP status \(httpStatus)")
    }
    return json
}

func openAuthorizationURL(_ url: URL) {
    NSWorkspace.shared.open(url)
}

func authorize() async throws {
    var credentials = try readKeychain()
    let tokenResponse = try await apiCall(credentials: credentials, method: "auth.getToken", parameters: [:])
    guard let token = tokenResponse["token"] as? String else {
        throw SyncError.message("Last.fm did not return an auth token.")
    }
    var components = URLComponents(string: "https://www.last.fm/api/auth/")!
    components.queryItems = [
        URLQueryItem(name: "api_key", value: credentials.api_key),
        URLQueryItem(name: "token", value: token)
    ]
    print("Authorize the app in the browser, then press Enter here:")
    print(components.url!.absoluteString)
    openAuthorizationURL(components.url!)
    _ = readLine()
    let sessionResponse = try await apiCall(credentials: credentials, method: "auth.getSession", parameters: ["token": token])
    guard let session = sessionResponse["session"] as? [String: Any],
          let key = session["key"] as? String,
          let username = session["name"] as? String else {
        throw SyncError.message("Last.fm did not return a session.")
    }
    credentials.session_key = key
    credentials.username = username
    try writeKeychain(credentials)
    print("Authorized as \(username).")
}

func configure() throws {
    print("Last.fm API key:", terminator: " ")
    guard let apiKey = readLine(), !apiKey.isEmpty else {
        throw SyncError.message("API key is required.")
    }
    guard let secretPointer = getpass("Last.fm shared secret: ") else {
        throw SyncError.message("Shared secret is required.")
    }
    let sharedSecret = String(cString: secretPointer)
    guard !sharedSecret.isEmpty else {
        throw SyncError.message("Shared secret is required.")
    }
    try writeKeychain(Credentials(api_key: apiKey, shared_secret: sharedSecret, session_key: nil, username: nil))
    print("API credentials saved to the macOS Keychain.")
}

func loadState() throws -> SyncState {
    guard FileManager.default.fileExists(atPath: stateURL.path) else { return SyncState() }
    do {
        return try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: stateURL))
    } catch {
        throw SyncError.message("State file is invalid: \(error.localizedDescription)")
    }
}

func saveState(_ state: SyncState) throws {
    let directory = stateURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(state)
    try data.write(to: stateURL, options: .atomic)
}

func scrobbleBatch(credentials: Credentials, tracks: [Track]) async throws -> Int {
    var params: [String: String] = ["sk": credentials.session_key!]
    for (index, track) in tracks.enumerated() {
        params["artist[\(index)]"] = track.artist
        params["track[\(index)]"] = track.title
        params["timestamp[\(index)]"] = String(track.timestamp)
        params["chosenByUser[\(index)]"] = "1"
        if !track.album.isEmpty { params["album[\(index)]"] = track.album }
        if !track.albumArtist.isEmpty { params["albumArtist[\(index)]"] = track.albumArtist }
        if track.duration > 0 { params["duration[\(index)]"] = String(Int(track.duration)) }
    }
    let response = try await apiCall(credentials: credentials, method: "track.scrobble", parameters: params)
    let scrobbles = response["scrobbles"] as? [String: Any]
    let attributes = scrobbles?["@attr"] as? [String: Any]
    if let accepted = attributes?["accepted"] as? Int { return accepted }
    return Int(attributes?["accepted"] as? String ?? "0") ?? 0
}

func syncHistory(sinceDays: Int, dryRun: Bool) async throws {
    var credentials = try readKeychain()
    guard credentials.session_key != nil else { throw SyncError.message("Run 'auth' first.") }
    var state = try loadState()
    let tracks = try recentTracks(sinceDays: sinceDays).sorted { $0.timestamp < $1.timestamp }
    let pending = tracks.filter { track in
        !track.artist.isEmpty && !track.title.isEmpty && state.submitted["\(track.persistentID):\(track.timestamp)"] == nil
    }
    print("Apple Music recent tracks: \(tracks.count); pending: \(pending.count)")
    if dryRun {
        for track in pending {
            print("DRY RUN  \(track.artist) - \(track.title)  (\(track.timestamp))")
        }
        return
    }
    var accepted = 0
    for start in pending.indices {
        let batch = [pending[start]]
        accepted += try await scrobbleBatch(credentials: credentials, tracks: batch)
        for track in batch {
            state.submitted["\(track.persistentID):\(track.timestamp)"] = Int(Date().timeIntervalSince1970)
        }
        try saveState(state)
        if start + 1 < pending.count {
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
    print("Submitted: \(accepted)")
    credentials = try readKeychain()
}

func verify() async throws {
    let credentials = try readKeychain()
    guard let username = credentials.username else { throw SyncError.message("Run 'auth' first.") }
    let response = try await apiCall(credentials: credentials, method: "user.getRecentTracks", parameters: ["user": username, "limit": "5"], signed: false)
    guard let recent = response["recenttracks"] as? [String: Any] else { return }
    let values: [[String: Any]]
    if let list = recent["track"] as? [[String: Any]] { values = list }
    else if let one = recent["track"] as? [String: Any] { values = [one] }
    else { values = [] }
    for track in values {
        let artist = (track["artist"] as? [String: Any])?["#text"] as? String ?? ""
        let title = track["name"] as? String ?? ""
        let nowPlaying = ((track["@attr"] as? [String: Any])?["nowplaying"] as? String) == "true" ? " now-playing" : ""
        print("\(artist) - \(title)\(nowPlaying)")
    }
}

func printUsage() {
    print("Usage: lastfm-sync <configure|auth|current|sync|verify> [options]")
    print("  configure                    Save API key and shared secret in Keychain")
    print("  auth                         Authorize the Last.fm API app")
    print("  current                      Show the current Music.app track")
    print("  sync [--since-days N]        Submit new Apple Music play records")
    print("       [--dry-run]")
    print("  verify                       Show the five latest Last.fm scrobbles")
}

@main
struct LastFmAppleMusicSync {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else { printUsage(); return }
            switch command {
            case "configure":
                try configure()
            case "auth":
                try await authorize()
            case "current":
                if let track = try currentTrack() {
                    print(JSONSerialization.string(from: track))
                } else {
                    print("No current Music.app track.")
                }
            case "sync":
                var sinceDays = 14
                var dryRun = false
                var index = 1
                while index < args.count {
                    if args[index] == "--dry-run" { dryRun = true }
                    else if args[index] == "--since-days", index + 1 < args.count {
                        sinceDays = Int(args[index + 1]) ?? 14
                        index += 1
                    }
                    index += 1
                }
                try await syncHistory(sinceDays: sinceDays, dryRun: dryRun)
            case "verify":
                try await verify()
            default:
                printUsage()
            }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

extension JSONSerialization {
    static func string(from dictionary: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
