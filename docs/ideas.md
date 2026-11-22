# Ideas for later

Ideas that have been talked through but not built yet, with enough detail to pick up later.

## Discovery bucket: high-scoring photos that aren't favorites

Each night, set aside a small fixed number of slots (5–6, not a share) for photos that are **not** in Favorites but that Apple's Vision framework rates as high quality. It's a way to bring forgotten photos back to the surface. If you favorite one you like, it joins the regular pool.

**Scoring.** Vision's `CalculateImageAestheticsScoresRequest` (macOS 15+) runs on-device and returns:
- `overallScore`, from −1 (least desirable) to 1 (most desirable). It combines an aesthetic score, a "failure" score (blur, bad exposure and the like), and utility labels.
- `isUtility`: images that aren't necessarily poor quality but lack memorable content, such as screenshots, receipts and documents.

Photos computes its own quality scores, but PhotoKit doesn't expose them, so PhotoShuffler would score photos itself.

**Cost.** Scoring is cheap. On an Apple silicon Mac, a 512 px thumbnail took about 3 ms (80 test images; the model loads in 0.06 s). The slower step is fetching thumbnails from Photos with `PHImageManager`, which hasn't been measured. It may need iCloud downloads when "Optimize Mac Storage" is on.

**Sketch.**
- Each night, score a random sample of a few hundred non-favorite photos that haven't been scored yet. Save the results (`scores.json`: asset id, score, isUtility, model revision) so no photo is ever scored twice. Coverage of the library builds up over time.
- Candidates: photos only, not hidden (PhotoKit excludes hidden photos by default), not `isUtility`, score ≥ a configurable minimum, and not in an exclusion album.
- Pick the top N by score, weighted by the usual cooldown. These photos follow the same rotation (`nightsInAlbum`) as the rest of the album.
- Config: `discovery.count` (0 = off), `discovery.minScore`, `discovery.sampleSize`, `discovery.excludeAlbum`.

**Before turning it on.**
- **Exclusion album.** Favorites are already vetted; the rest of the library isn't. A well-composed photo can still be private, sad, or something you don't want on the living-room TV. Add an exclusion album (for example "Not on TV") whose photos are never picked, and show the discovery picks in `--dry-run`.
- **Calibrate the minimum score.** Professional images (macOS desktop pictures) scored 0.65–0.9, and personal photos will spread out much more. Build a score-only report first: an HTML contact sheet of the highest- and lowest-scoring photos with a histogram, then pick the cutoff by eye.

## Other selection signals

- **Orientation.** `pixelWidth`/`pixelHeight` are free from PhotoKit. Portrait photos are letterboxed on a landscape TV. Weight them down or give them a share, rather than exclude them.
- **Faces.** PhotoKit doesn't expose Photos' People data: no names and no face regions.
  - Vision's face detection (`DetectFaceRectanglesRequest`) can tell whether a photo has faces, how many, and how big. It can't tell who they are.
  - For a specific person, use a Photos album or smart album ("Person is X"). It's unverified whether PhotoKit on macOS can read smart albums you create yourself.
- **Location.** Spread picks across places and trips instead of drawing several photos from the same day.
- **Media subtypes and bursts.** Panorama, Portrait mode, HDR and Live Photo. Also detecting near-duplicate bursts.

## Tooling

- `--report`: the album's current composition plus history statistics (nights per photo, repeat rate, bucket mix over time).
