# Apple Music Last.fm Sync

Small macOS command-line tool for manually syncing Apple Music play history to Last.fm.

It uses the Music app's AppleScript interface, Last.fm's Scrobbling API, and the macOS Keychain. It does not run a background service.

## Build

```sh
swiftc LastFmAppleMusicSync.swift -parse-as-library -framework AppKit -framework CryptoKit -framework Foundation -framework Security -o lastfm-sync
```

## Commands

```sh
./lastfm-sync configure
./lastfm-sync auth
./lastfm-sync sync --dry-run --since-days 14
./lastfm-sync sync --since-days 14
./lastfm-sync verify
```

The first run needs a Last.fm API key and shared secret. Run `configure` to enter them; the shared secret is hidden and both values are stored in the macOS Keychain, never in the repository. `auth` opens Last.fm to grant this app write access. Music.app may ask for Automation permission the first time it is queried.

## Notes

Apple Music exposes the latest played date for each library track, not a complete per-play event log. The tool therefore imports one new event per track/date and keeps a local deduplication state file.
