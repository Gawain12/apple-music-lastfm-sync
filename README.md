# Apple Music Last.fm Sync

A small native Swift command-line tool for syncing Apple Music play records from macOS Music.app to Last.fm. It uses the Music app's AppleScript interface, the Last.fm API, and the macOS Keychain. It is not a resident process unless you explicitly install the optional launchd schedule.

## Build

```sh
swiftc LastFmAppleMusicSync.swift -parse-as-library \
  -framework AppKit -framework CryptoKit -framework Foundation -framework Security \
  -o lastfm-sync
```

## First-time setup

```sh
./lastfm-sync setup       # opens Last.fm's API account creation page
./lastfm-sync configure   # enter the API key and shared secret
./lastfm-sync auth        # opens browser authorization and saves the session
```

The key and shared secret are hidden from the repository and stored in the macOS Keychain. `auth` opens the authorization URL automatically and asks you to press Enter after approving it. Music.app may ask for Automation permission the first time it is queried.

## Sync

```sh
./lastfm-sync sync --dry-run --since-days 14
./lastfm-sync sync --since-days 14   # force a fresh 14-day scan
./lastfm-sync sync                    # resume from the previous scan cursor
./lastfm-sync status
```

Every scan is merged into a local pending queue at `~/Library/Application Support/Apple Music Last.fm Sync/state.json`. A record is removed from that queue only after Last.fm accepts it, or after the tool confirms the same artist/title/timestamp is already on Last.fm. This makes retries safe after a crash, network error, or API rate limit. Local submissions are marked `computer`; matching remote records are marked `unknown` because Last.fm does not expose a reliable device field in this API.

## Optional schedule

Install a per-user hourly sync without root access:

```sh
./lastfm-sync schedule install --interval 3600
./lastfm-sync schedule status
./lastfm-sync schedule uninstall
```

The schedule uses the exact executable path used during installation, so install it only after building the binary at a stable location. Logs go to `~/Library/Logs/AppleMusicLastFmSync.log` and `AppleMusicLastFmSync.error.log`.

## Download Last.fm history

`user.getRecentTracks` is paginated, so the tool can export all records returned by the API as JSONL:

```sh
./lastfm-sync download --output ~/Downloads/lastfm-history.jsonl
./lastfm-sync download --from 1704067200 --to 1735689600 --output ~/Downloads/lastfm-2024.jsonl
./lastfm-sync download --max-pages 1 --output /tmp/lastfm-page.jsonl
```

The export includes the Last.fm timestamp, artist, track, album, URL, and `source: "unknown"`. Use `--max-pages` for a test or partial export; omit it for the complete paginated history available to the account.

## Limits and privacy

Music.app exposes the latest played date for each library track rather than a complete per-play event log. The tool can guarantee no duplicate submission for the events it observes and can preserve pending events, but it cannot reconstruct multiple plays of the same track that happened between scans if Music.app no longer exposes them individually. For continuous completeness, use the schedule or run `sync` regularly.

The Last.fm scrobbling API accepts artist, track, album, duration, and timestamp, but does not provide a reliable computer/phone label. Therefore the tool only labels its own local submissions as `computer`; downloaded historical records remain `unknown` rather than being guessed.

If Last.fm returns API error 29, it is temporarily rate-limiting the account or IP. The tool leaves those records pending and records the error in `status`; retry later instead of marking them as submitted.

Official references: [API account](https://www.last.fm/api/account/create), [authentication](https://www.last.fm/api/authentication), [user.getRecentTracks](https://www.last.fm/api/show/user.getRecentTracks), [track.scrobble](https://www.last.fm/api/show/track.scrobble).
