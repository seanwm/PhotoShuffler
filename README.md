# PhotoShuffler

Every night, PhotoShuffler refreshes one Apple Photos album with a weighted selection from your Favorites. Point the Apple TV screensaver at that album and you choose how much it shows recent photos, "on this date" photos and the archive, with less repetition than the Apple TV's own picks.

## What it does (and doesn't)

- It reads your **Favorites** (photos only by default, screenshots included) and sorts them into three buckets:
  - **Recent:** created in the last 30 days. 20% of the album. A recent photo gets at most about 10 nights in the album as "recent"; after that it competes with the archive.
  - **On this date:** within ±14 days of today's month and day, in a previous year. 25%.
  - **Archive:** everything else. 55%. If a bucket runs short, its unused slots go to the archive.
- **Rolling turnover:** each night it swaps out the oldest third of the album (`nightsInAlbum: 3`), so each photo stays about 3 nights. It also removes anything that's no longer eligible, for example a photo you've un-favorited. Then it fills the open slots with new picks, split by the bucket shares.
- New picks are drawn at random, weighted against repeats: a photo that was in the album recently has a lower chance of coming back until its cooldown ends (21 days by default). A photo that leaves the album is never re-added the same night.
- It compares the album with the new contents, then removes and adds only what changed, in a single Photos transaction.

**Safety:** PhotoShuffler only adds photos to and removes photos from its own album, and creates that album once if it doesn't exist. It never deletes photos, never changes Favorites, and never touches any other album. `Tests/ShufflerCoreTests/SafetyTests.swift` fails the build if code that deletes or edits photos, or edits other albums, ever appears.

It finds the album by the identifier recorded in `state.json` on the first run, falls back to the exact album name, and creates the album only if neither matches. It edits that album in place every night, so the Apple TV keeps pointing at the same album.

## Requirements

- macOS 14 or later, logged in, with iCloud Photos turned on (the album reaches the Apple TV through iCloud).
- Swift 5.10 or later: Xcode or the Command Line Tools (`xcode-select --install`).

## Setup

```bash
scripts/install.sh
```

This:
1. Builds `PhotoShuffler.app` (`scripts/build.sh`) and copies it to `~/Applications`.
2. Copies `config/config.sample.json` to `~/Library/Application Support/PhotoShuffler/config.json`, unless a config already exists there.
3. Installs the launchd agent `~/Library/LaunchAgents/local.photoshuffler.nightly.plist`, which runs at 3:00 AM. To use another time, run `HOUR=4 MINUTE=30 scripts/install.sh`.
4. Asks for Photos access (see below).

Then:

```bash
scripts/run.sh --dry-run
```

Read the output. When you're happy with it, run the real job once:

```bash
launchctl kickstart gui/$(id -u)/local.photoshuffler.nightly
```

Then, on the Apple TV, go to **Settings > General > Screen Saver > Type > Photos** and pick the album.

> **Tip:** to try it out first, set `albumName` to something like `"Screensaver Test"` in your config. When you switch to the real album name, delete `state.json`. Otherwise PhotoShuffler keeps using the album it recorded (it logs a warning when the names differ).

## Photos permission

macOS grants Photos access per app, after asking the user, and attributes the request to the "responsible" process. That's why PhotoShuffler is packaged as a small app:

- **A bare command-line binary doesn't work reliably.** Run from Terminal, the request is attributed to Terminal. Run by launchd, it has no bundle identity or usage description to show in the prompt.
- **The fix:** the executable lives inside `PhotoShuffler.app`, which has a bundle ID (`local.photoshuffler.app`) and an `NSPhotoLibraryUsageDescription`. The launchd job runs the executable inside the bundle, so macOS checks permission against PhotoShuffler.app.
- `scripts/authorize.sh` launches the app through LaunchServices (`open`), so the prompt appears as **PhotoShuffler**. Choose **Allow Full Access**. "Limited" access isn't enough, because the tool needs to see all of your Favorites.
- `scripts/run.sh` also goes through `open`, so your manual runs use the same permission as the nightly job.

**About rebuilds:** the build is signed ad hoc by default, and macOS ties the permission to the signature, so after a rebuild you'll need to grant access again. `install.sh` runs `authorize.sh` for you. If you have an Apple Development or Developer ID certificate, build with `SIGN_IDENTITY="Apple Development: …" scripts/install.sh` and the permission survives rebuilds.

If the prompt never appears, or access is denied, go to **System Settings > Privacy & Security > Photos** and set PhotoShuffler to **Full Access**, then run `scripts/authorize.sh` to confirm. To start over: `tccutil reset Photos local.photoshuffler.app`.

## Tuning

Edit `~/Library/Application Support/PhotoShuffler/config.json`. Every key is optional; missing keys use the defaults shown.

| Key | Default | Meaning |
|---|---|---|
| `albumName` | `"Apple TV Screensaver"` | Album to manage. Used to find the album when `state.json` has no identifier, and as its name when it's created. |
| `albumSize` | `150` | Number of photos in the album. |
| `nightsInAlbum` | `3` | How long each photo stays. Each night, `albumSize / nightsInAlbum` photos (rounded up) are swapped: 50 with the defaults, 38 with `4`. With `1`, the whole album is replaced every night. |
| `includeVideos` | `false` | Include videos from Favorites. |
| `buckets.recent.share` / `.windowDays` | `0.20` / `30` | Share of the album for photos from the last N days. |
| `buckets.recent.maxNights` | `10` | After this many nights in the album, a recent photo competes with the archive instead. This is checked when photos are picked, so a stay that starts before the cap runs its full length. `0` means no cap. |
| `buckets.onThisDate.share` / `.windowDays` | `0.25` / `14` | Share for photos within ±N days of today's date in earlier years. |
| `buckets.archive.share` | `0.55` | Share for everything else. It also gets any slots the other buckets can't fill. |
| `cooldownDays` | `21` | Days after a photo leaves the album before its weight is back to full. Applies to new picks only, not to photos already in the album. |
| `minWeight` | `0.05` | Lowest weight for a photo in cooldown. Set it to `0` to exclude recently shown photos entirely. |
| `seed` | `null` | A fixed random seed makes the selection repeatable. Leave it `null` in normal use. |

Shares don't have to add up to 1; they're scaled proportionally, and the log notes it.

**How turnover works:** PhotoShuffler records when each photo's current stay in the album began, and every night it removes the oldest stays first. Photos whose start date it doesn't know, such as photos already in an album you adopt or photos added by hand, count as oldest. Removing a no-longer-eligible photo also counts toward that night's swaps. Each night's new picks follow the bucket shares, so over time the whole album does too. If there aren't enough fresh favorites to fill the open slots, it keeps some photos that were due to leave rather than let the album shrink.

**How the weights work:** a photo's weight is `daysSinceShown / cooldownDays`, with a floor of `minWeight` and a maximum of 1. Photos that have never been shown get 1. "Shown" counts the last night a photo was in the album. Within each bucket, photos are drawn without replacement using weighted random sampling (Efraimidis–Spirakis). The weights only matter when a bucket has more candidates than open slots.

Some ways to adjust it:
- **Faster or slower turnover:** lower or raise `nightsInAlbum`.
- **Fewer repeats across weeks:** a longer `cooldownDays`, or a lower `minWeight`.
- **More nostalgia:** raise `onThisDate.share`, or widen `onThisDate.windowDays`.
- **Small Favorites pool:** lower `albumSize` or `cooldownDays`. With a small pool, most photos are always in cooldown.

To compare settings, run `scripts/run.sh --dry-run --seed 1` before and after a change.

## Files

| Path | What |
|---|---|
| `~/Library/Application Support/PhotoShuffler/config.json` | Settings |
| `…/state.json` | The managed album's identifier, and the time of the last run |
| `…/history.json` | For each photo: the last night it was in the album, how many nights in total, and when its current stay began. Entries are dropped when a photo leaves Favorites. |
| `~/Library/Logs/PhotoShuffler/PhotoShuffler.log` | One block per run: photos kept, rotated out, removed as ineligible, and added; new picks by bucket; the album's bucket mix after the run; and any errors. Rotates at 5 MB. Opens in Console.app. |
| `~/Library/Logs/PhotoShuffler/launchd.*.log` | Raw stdout and stderr from launchd runs |

`--dry-run` writes none of these files. It prints to the terminal only.

## Command line

```
PhotoShuffler [--dry-run] [--seed <n>] [--config <path>] [--authorize]
```

Exit codes: 0 success, 1 error, 2 a default config was just created (review it, then run again), 3 no Photos access.

If Favorites is empty or can't be read, PhotoShuffler leaves the album unchanged rather than emptying it. If more than one album has the configured name, it stops and asks you to fix that rather than guess.

## Development

```bash
scripts/test.sh     # unit tests (bucketing, weights, selection, rotation, diff, config, safety)
scripts/build.sh    # build and sign build/PhotoShuffler.app
```

The selection logic lives in `Sources/ShufflerCore` and has no PhotoKit dependency, so it can be tested on its own. The PhotoKit code lives in `Sources/PhotoShuffler/PhotoLibrary.swift`, and that's the only file allowed to write to Photos.

`scripts/build.sh` compiles with `swiftc` directly, and `scripts/test.sh` falls back to `swiftc` when `swift package` fails, so both work even when SwiftPM is broken. With a working toolchain, `swift build` and `swift test` work too.

## Uninstall

```bash
scripts/uninstall.sh            # remove the agent and the app; keep config, history and logs
scripts/uninstall.sh --purge    # also remove config, state, history and logs
```

Uninstalling never touches the Photos album.

## Later

Ideas that have been discussed but not built are in [docs/ideas.md](docs/ideas.md). They include a small "discovery" bucket of high-scoring non-favorites (using Vision's aesthetics score), orientation and face signals, and a `--report` command.

## License

MIT. See [LICENSE](LICENSE).
