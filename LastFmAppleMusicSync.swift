import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

private let apiURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
private let apiAccountURL = URL(string: "https://www.last.fm/api/account/create")!
private let keychainService = "Codex Apple Music Last.fm Sync"
private let keychainAccount = NSUserName()
private let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Apple Music Last.fm Sync/state.json")
private let launchAgentLabel = "com.gawain12.apple-music-lastfm-sync"
private let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
private let recordSeparator = String(UnicodeScalar(30))
private let fieldSeparator = String(UnicodeScalar(31))

struct Credentials: Codable {
    var api_key: String
    var shared_secret: String
    var session_key: String?
    var username: String?
}

struct SubmissionRecord: Codable {
    var recordedAt: Int
    var source: String
    var result: String
}

struct Track: Codable, Hashable {
    let persistentID: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let duration: Double
    let timestamp: Int
}

struct SyncState: Codable {
    var submitted: [String: SubmissionRecord] = [:]
    var pending: [Track] = []
    var scanCursor: Int?
    var lastScanStartedAt: Int?
    var lastScanCompletedAt: Int?
    var lastSubmittedAt: Int?
    var lastError: String?
    var lastScanCount: Int = 0
    var source: String = "computer"

    private enum CodingKeys: String, CodingKey {
        case submitted
        case pending
        case scanCursor
        case lastScanStartedAt
        case lastScanCompletedAt
        case lastSubmittedAt
        case lastError
        case lastScanCount
        case source
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let records = try? container.decode([String: SubmissionRecord].self, forKey: .submitted) {
            submitted = records
        } else if let legacy = try? container.decode([String: Int].self, forKey: .submitted) {
            submitted = legacy.mapValues {
                SubmissionRecord(recordedAt: $0, source: "computer", result: "accepted")
            }
        }
        pending = try container.decodeIfPresent([Track].self, forKey: .pending) ?? []
        scanCursor = try container.decodeIfPresent(Int.self, forKey: .scanCursor)
        lastScanStartedAt = try container.decodeIfPresent(Int.self, forKey: .lastScanStartedAt)
        lastScanCompletedAt = try container.decodeIfPresent(Int.self, forKey: .lastScanCompletedAt)
        lastSubmittedAt = try container.decodeIfPresent(Int.self, forKey: .lastSubmittedAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastScanCount = try container.decodeIfPresent(Int.self, forKey: .lastScanCount) ?? 0
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "computer"
    }
}

struct RemoteScrobble {
    let artist: String
    let title: String
    let album: String
    let timestamp: Int
    let source: String
}

struct RecentTracksPage {
    let tracks: [RemoteScrobble]
    let rawTracks: [[String: Any]]
    let page: Int
    let totalPages: Int
    let total: Int
}

struct ScrobbleResult {
    let accepted: Bool
    let ignoredCode: Int?
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

func recentTracks(sinceDays: Int, sinceTimestamp: Int? = nil) throws -> [Track] {
    let seconds = max(0, sinceDays) * 86400
    let cutoffExpression: String
    if let sinceTimestamp {
        cutoffExpression = "epochDate + \(max(0, sinceTimestamp))"
    } else {
        cutoffExpression = "(current date) - \(seconds)"
    }
    let source = """
tell application "Music"
    set epochDate to date "Thursday, January 1, 1970 at 00:00:00"
    set cutoffDate to \(cutoffExpression)
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

func integerValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

func stringValue(_ value: Any?) -> String {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return ""
}

func nestedText(_ dictionary: [String: Any], key: String) -> String {
    if let nested = dictionary[key] as? [String: Any] {
        return stringValue(nested["#text"])
    }
    return stringValue(dictionary[key])
}

func remoteScrobble(from dictionary: [String: Any]) -> RemoteScrobble? {
    guard let date = dictionary["date"] as? [String: Any],
          let timestamp = integerValue(date["uts"]), timestamp > 0 else {
        return nil
    }
    return RemoteScrobble(
        artist: nestedText(dictionary, key: "artist"),
        title: stringValue(dictionary["name"]),
        album: nestedText(dictionary, key: "album"),
        timestamp: timestamp,
        source: "unknown"
    )
}

func recentTracksPage(
    credentials: Credentials,
    username: String,
    page: Int,
    from: Int? = nil,
    to: Int? = nil
) async throws -> RecentTracksPage {
    var parameters = [
        "user": username,
        "limit": "200",
        "page": String(max(1, page))
    ]
    if let from { parameters["from"] = String(max(0, from)) }
    if let to { parameters["to"] = String(max(0, to)) }
    let response = try await apiCall(
        credentials: credentials,
        method: "user.getRecentTracks",
        parameters: parameters,
        signed: false
    )
    guard let recent = response["recenttracks"] as? [String: Any] else {
        throw SyncError.message("Last.fm returned no recent track data.")
    }
    let rawTracks: [[String: Any]]
    if let list = recent["track"] as? [[String: Any]] {
        rawTracks = list
    } else if let one = recent["track"] as? [String: Any] {
        rawTracks = [one]
    } else {
        rawTracks = []
    }
    let attributes = recent["@attr"] as? [String: Any]
    let currentPage = integerValue(attributes?["page"]) ?? page
    let totalPages = max(1, integerValue(attributes?["totalPages"]) ?? 1)
    let total = integerValue(attributes?["total"]) ?? rawTracks.count
    return RecentTracksPage(
        tracks: rawTracks.compactMap(remoteScrobble),
        rawTracks: rawTracks,
        page: currentPage,
        totalPages: totalPages,
        total: total
    )
}

func allRecentScrobbles(
    credentials: Credentials,
    username: String,
    from: Int? = nil,
    to: Int? = nil,
    maxPages: Int? = nil
) async throws -> [RemoteScrobble] {
    var page = 1
    var result: [RemoteScrobble] = []
    while true {
        let current = try await recentTracksPage(
            credentials: credentials,
            username: username,
            page: page,
            from: from,
            to: to
        )
        result.append(contentsOf: current.tracks)
        if page >= current.totalPages || (maxPages != nil && page >= maxPages!) { break }
        page += 1
        try await Task.sleep(nanoseconds: 300_000_000)
    }
    return result
}

func openAuthorizationURL(_ url: URL) {
    NSWorkspace.shared.open(url)
}

func setup() {
    print("Opening the Last.fm API account page:")
    print(apiAccountURL.absoluteString)
    print("Create an API account there, then run 'configure' to save its key and shared secret.")
    openAuthorizationURL(apiAccountURL)
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
    print("If you do not have an API account yet, run 'setup' first.")
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

func scrobbleBatch(credentials: Credentials, tracks: [Track]) async throws -> ScrobbleResult {
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
    let accepted = integerValue(attributes?["accepted"]) ?? 0
    let ignoredCode: Int?
    if let one = scrobbles?["scrobble"] as? [String: Any],
       let ignored = one["ignoredMessage"] as? [String: Any] {
        let code = integerValue(ignored["code"]) ?? 0
        ignoredCode = code == 0 ? nil : code
    } else if let list = scrobbles?["scrobble"] as? [[String: Any]],
              let ignored = list.first?["ignoredMessage"] as? [String: Any] {
        let code = integerValue(ignored["code"]) ?? 0
        ignoredCode = code == 0 ? nil : code
    } else {
        ignoredCode = nil
    }
    return ScrobbleResult(accepted: accepted > 0, ignoredCode: ignoredCode)
}

func normalized(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .lowercased()
}

func fingerprint(_ track: Track) -> String {
    "\(track.persistentID):\(track.timestamp)"
}

func matchesRemote(_ track: Track, _ remote: RemoteScrobble) -> Bool {
    normalized(track.artist) == normalized(remote.artist)
        && normalized(track.title) == normalized(remote.title)
        && abs(track.timestamp - remote.timestamp) <= 30
}

func mergeTracks(_ existing: [Track], _ newTracks: [Track]) -> [Track] {
    var byFingerprint: [String: Track] = [:]
    for track in existing + newTracks where !track.artist.isEmpty && !track.title.isEmpty {
        byFingerprint[fingerprint(track)] = track
    }
    return byFingerprint.values.sorted { $0.timestamp < $1.timestamp }
}

func isPermanentIgnored(_ code: Int) -> Bool {
    [1, 2, 3, 4].contains(code)
}

func syncHistory(sinceDays: Int, explicitLookback: Bool, dryRun: Bool) async throws {
    let credentials = try readKeychain()
    guard let sessionKey = credentials.session_key, !sessionKey.isEmpty else {
        throw SyncError.message("Run 'auth' first.")
    }
    guard let username = credentials.username, !username.isEmpty else {
        throw SyncError.message("Run 'auth' first so the Last.fm account is known.")
    }
    var state = try loadState()
    let now = Int(Date().timeIntervalSince1970)
    let cursor = explicitLookback ? nil : state.scanCursor.map { max(0, $0 - 600) }
    let tracks = try recentTracks(sinceDays: sinceDays, sinceTimestamp: cursor)
    let merged = mergeTracks(state.pending, tracks)
    state.lastScanStartedAt = now
    state.lastScanCompletedAt = now
    state.scanCursor = now
    state.lastScanCount = tracks.count
    state.source = "computer"
    print("Apple Music scan: \(tracks.count); queued: \(merged.count)")
    if dryRun {
        for track in merged where state.submitted[fingerprint(track)] == nil {
            print("DRY RUN  \(track.artist) - \(track.title)  (\(track.timestamp))")
        }
        return
    }

    state.pending = merged.filter { state.submitted[fingerprint($0)] == nil }
    try saveState(state)
    guard !state.pending.isEmpty else {
        state.lastError = nil
        try saveState(state)
        print("Nothing new to submit.")
        return
    }

    do {
        let firstTimestamp = state.pending.map(\.timestamp).min() ?? now
        let lastTimestamp = state.pending.map(\.timestamp).max() ?? now
        let remote = try await allRecentScrobbles(
            credentials: credentials,
            username: username,
            from: max(0, firstTimestamp - 30),
            to: lastTimestamp + 30
        )
        var submitted = 0
        var alreadyPresent = 0
        var ignored = 0
        let queue = state.pending
        for track in queue {
            let key = fingerprint(track)
            if remote.contains(where: { matchesRemote(track, $0) }) {
                state.submitted[key] = SubmissionRecord(
                    recordedAt: Int(Date().timeIntervalSince1970),
                    source: "unknown",
                    result: "already-on-lastfm"
                )
                state.pending.removeAll { fingerprint($0) == key }
                state.lastSubmittedAt = Int(Date().timeIntervalSince1970)
                alreadyPresent += 1
                try saveState(state)
                continue
            }

            let result = try await scrobbleBatch(credentials: credentials, tracks: [track])
            if result.accepted {
                state.submitted[key] = SubmissionRecord(
                    recordedAt: Int(Date().timeIntervalSince1970),
                    source: "computer",
                    result: "accepted"
                )
                state.pending.removeAll { fingerprint($0) == key }
                state.lastSubmittedAt = Int(Date().timeIntervalSince1970)
                submitted += 1
                try saveState(state)
            } else if let code = result.ignoredCode, isPermanentIgnored(code) {
                state.submitted[key] = SubmissionRecord(
                    recordedAt: Int(Date().timeIntervalSince1970),
                    source: "computer",
                    result: "ignored-\(code)"
                )
                state.pending.removeAll { fingerprint($0) == key }
                ignored += 1
                print("Ignored code \(code): \(track.artist) - \(track.title)")
                try saveState(state)
            } else {
                print("Not accepted; kept pending: \(track.artist) - \(track.title)")
            }
            if !state.pending.isEmpty {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        state.lastError = state.pending.isEmpty
            ? nil
            : "Some records remain pending; retry after the temporary Last.fm rejection or rate limit clears."
        try saveState(state)
        print("Submitted: \(submitted); already on Last.fm: \(alreadyPresent); permanently ignored: \(ignored); pending: \(state.pending.count)")
    } catch {
        state.lastError = error.localizedDescription
        try saveState(state)
        throw error
    }
}

func resolvedURL(_ path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(expanded)
        .standardizedFileURL
}

func downloadHistory(outputPath: String, from: Int?, to: Int?, maxPages: Int?) async throws {
    let credentials = try readKeychain()
    guard let username = credentials.username, !username.isEmpty else {
        throw SyncError.message("Run 'auth' first.")
    }
    let outputURL = resolvedURL(outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: outputURL)
    defer { try? handle.close() }

    var page = 1
    var exported = 0
    var total = 0
    while true {
        let current = try await recentTracksPage(
            credentials: credentials,
            username: username,
            page: page,
            from: from,
            to: to
        )
        total = current.total
        for raw in current.rawTracks {
            guard let track = remoteScrobble(from: raw) else { continue }
            var record: [String: Any] = [
                "timestamp": track.timestamp,
                "artist": track.artist,
                "track": track.title,
                "album": track.album,
                "source": track.source,
                "url": stringValue(raw["url"])
            ]
            if let date = raw["date"] as? [String: Any] {
                record["date"] = stringValue(date["#text"])
            }
            let data = try JSONSerialization.data(withJSONObject: record, options: [])
            handle.write(data)
            handle.write(Data("\n".utf8))
            exported += 1
        }
        print("Downloaded page \(page)/\(current.totalPages), records: \(exported)/\(total)")
        if page >= current.totalPages || (maxPages != nil && page >= maxPages!) { break }
        page += 1
        try await Task.sleep(nanoseconds: 300_000_000)
    }
    print("Wrote \(exported) records to \(outputURL.path)")
}

func formattedTimestamp(_ timestamp: Int?) -> String {
    guard let timestamp else { return "never" }
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
}

func printStatus() throws {
    let state = try loadState()
    if let credentials = try? readKeychain() {
        print("Last.fm account: \(credentials.username ?? "configured, not authorized")")
    } else {
        print("Last.fm account: not configured")
    }
    print("Source: \(state.source) (Apple Music on this Mac)")
    print("Pending: \(state.pending.count)")
    print("Recorded outcomes: \(state.submitted.count)")
    print("Last scan: \(formattedTimestamp(state.lastScanCompletedAt))")
    print("Last submitted or deduplicated: \(formattedTimestamp(state.lastSubmittedAt))")
    print("Last error: \(state.lastError ?? "none")")
    print("State file: \(stateURL.path)")
}

func processOutput(_ executable: String, arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Command failed."
        throw SyncError.message(message)
    }
    return String(data: outputData, encoding: .utf8) ?? ""
}

func executablePath() -> String {
    let argument = CommandLine.arguments[0]
    if argument.contains("/") {
        return URL(fileURLWithPath: argument, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }
    for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(argument)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
    }
    return argument
}

func launchctlDomain() -> String {
    "gui/\(getuid())"
}

func scheduleInstall(interval: Int) throws {
    let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "Label": launchAgentLabel,
        "ProgramArguments": [executablePath(), "sync"],
        "WorkingDirectory": FileManager.default.currentDirectoryPath,
        "RunAtLoad": false,
        "StartInterval": max(300, interval),
        "StandardOutPath": logDirectory.appendingPathComponent("AppleMusicLastFmSync.log").path,
        "StandardErrorPath": logDirectory.appendingPathComponent("AppleMusicLastFmSync.error.log").path
    ]
    let directory = launchAgentURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: launchAgentURL, options: .atomic)
    _ = try? processOutput("/bin/launchctl", arguments: ["bootout", "\(launchctlDomain())/\(launchAgentLabel)"])
    _ = try processOutput("/bin/launchctl", arguments: ["bootstrap", launchctlDomain(), launchAgentURL.path])
    print("Installed hourly-style schedule every \(max(300, interval)) seconds.")
    print("Executable: \(executablePath())")
    print("Logs: \(logDirectory.path)")
}

func scheduleUninstall() throws {
    _ = try? processOutput("/bin/launchctl", arguments: ["bootout", "\(launchctlDomain())/\(launchAgentLabel)"])
    if FileManager.default.fileExists(atPath: launchAgentURL.path) {
        try FileManager.default.removeItem(at: launchAgentURL)
    }
    print("Removed the schedule.")
}

func scheduleStatus() {
    guard FileManager.default.fileExists(atPath: launchAgentURL.path) else {
        print("Schedule: not installed")
        return
    }
    do {
        _ = try processOutput("/bin/launchctl", arguments: ["print", "\(launchctlDomain())/\(launchAgentLabel)"])
        print("Schedule: installed and loaded")
    } catch {
        print("Schedule: installed but not loaded")
    }
    print("Plist: \(launchAgentURL.path)")
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
    print("Usage: lastfm-sync <setup|configure|auth|current|sync|status|download|schedule|verify> [options]")
    print("  setup                        Open Last.fm's API account creation page")
    print("  configure                    Save API key and shared secret in Keychain")
    print("  auth                         Open browser authorization and save session")
    print("  current                      Show the current Music.app track")
    print("  sync                         Resume and submit queued Apple Music records")
    print("       [--since-days N]        Force a fresh lookback instead of the cursor")
    print("       [--dry-run]")
    print("  status                       Show cursor, queue, outcomes and last error")
    print("  download [options]           Export paginated Last.fm history as JSONL")
    print("       [--output PATH] [--from UNIX] [--to UNIX] [--max-pages N]")
    print("  schedule install             Install a per-user launchd schedule")
    print("       [--interval SECONDS]")
    print("  schedule uninstall|status")
    print("  verify                       Show the five latest Last.fm scrobbles")
}

@main
struct LastFmAppleMusicSync {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else { printUsage(); return }
            switch command {
            case "setup":
                setup()
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
                var explicitLookback = false
                var dryRun = false
                var index = 1
                while index < args.count {
                    if args[index] == "--dry-run" { dryRun = true }
                    else if args[index] == "--since-days", index + 1 < args.count {
                        sinceDays = Int(args[index + 1]) ?? 14
                        explicitLookback = true
                        index += 1
                    }
                    index += 1
                }
                try await syncHistory(sinceDays: sinceDays, explicitLookback: explicitLookback, dryRun: dryRun)
            case "status":
                try printStatus()
            case "download":
                var output = "lastfm-history.jsonl"
                var from: Int?
                var to: Int?
                var maxPages: Int?
                var index = 1
                while index < args.count {
                    if args[index] == "--output", index + 1 < args.count {
                        output = args[index + 1]
                        index += 1
                    } else if args[index] == "--from", index + 1 < args.count {
                        from = Int(args[index + 1])
                        index += 1
                    } else if args[index] == "--to", index + 1 < args.count {
                        to = Int(args[index + 1])
                        index += 1
                    } else if args[index] == "--max-pages", index + 1 < args.count {
                        maxPages = Int(args[index + 1])
                        index += 1
                    }
                    index += 1
                }
                try await downloadHistory(outputPath: output, from: from, to: to, maxPages: maxPages)
            case "schedule":
                let action = args.count > 1 ? args[1] : "status"
                if action == "install" {
                    var interval = 3600
                    var index = 2
                    while index < args.count {
                        if args[index] == "--interval", index + 1 < args.count {
                            interval = Int(args[index + 1]) ?? 3600
                            index += 1
                        }
                        index += 1
                    }
                    try scheduleInstall(interval: interval)
                } else if action == "uninstall" {
                    try scheduleUninstall()
                } else if action == "status" {
                    scheduleStatus()
                } else {
                    printUsage()
                }
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
