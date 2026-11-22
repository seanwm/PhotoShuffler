# Project brief: Apple TV screensaver album rotator

## Goal
Build a small macOS tool that refreshes a dedicated Apple Photos album every night with a tunable selection of photos from my Favorites. Our Apple TV screensaver is set to display that album. Apple TV doesn't allow third-party screensavers and its own selection algorithm isn't adjustable (it leans too hard on recent photos and repeats the same ones), so I want to control the album's contents instead.

## Constraints and preferences
- Keep it simple: a Swift command-line tool with a config file, run nightly by launchd. No GUI for now.
- Use PhotoKit (not AppleScript, which can't remove photos from an album).
- Runs on a Mac that's always on, with iCloud Photos enabled. The album syncs to the Apple TV through iCloud.
- Edit one persistent album in place. Never delete and recreate it, since the Apple TV's screensaver setting points at that specific album.

## Safety rules (important)
- Only add or remove photos in the target album. Never delete assets, never modify Favorites or any other album.
- Find the target album by its stored localIdentifier (record it in the state file on first run). Fall back to the exact album name. Create the album only if neither exists.
- Provide a `--dry-run` flag that prints the proposed selection and the planned changes without writing anything.

## Selection logic
Source pool: the Favorites smart album (`.smartAlbumFavorites`), photos only, no videos (configurable).

Each run builds a target set of N photos (default 150) by drawing from weighted buckets:
- **Recent:** created in the last X days (default 30). Default share 20%.
- **On this date:** created within ±Y days (default 7) of today's month and day in any previous year. Default share 25%.
- **Archive:** everything else. Default share 55%.

If a bucket can't fill its share, spill the leftover slots into the archive bucket.

Anti-repetition: keep a history file of when each asset was last placed in the album. Within each bucket, down-weight recently shown photos. For example, weight = 1 − decay based on days since last shown, with the cooldown length configurable (default 21 days). Use random weighted sampling, with an optional seed for testing.

Applying changes: compute the difference between the current album and the new target set, then remove and add only what changed, in a single `performChanges` block.

## Config
Use a JSON or TOML file in `~/Library/Application Support/<tool-name>/` with:
- album name
- album size
- bucket shares and windows
- cooldown length
- whether to include videos

The state and history files live in the same folder.

## Scheduling and permissions
- Include a launchd agent plist that runs nightly (default 3:00 AM), plus install and uninstall instructions or a script.
- Photos access: request `.readWrite` authorization. A bare CLI run by launchd may not get the permission prompt properly. If so, wrap the tool in a minimal app bundle (or document another approach) so macOS can grant Photos access. Please investigate and handle this.
- Log each run (counts per bucket, added and removed, errors) to a log file.

## Deliverables
1. Swift package with the CLI
2. A sample config file
3. The launchd plist and install steps
4. A README covering setup, the permission grant, and tuning

## Nice to have (later)
- A `--report` command showing current album composition and history stats
- Optional exclusion of screenshots or near-duplicate bursts