# Changelog

All notable changes to PaperNote are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.12.0] - 2026-07-21

### Fixed
- **Deleting a note on one device now really deletes it everywhere.** Deletions
  were resolved like any other edit — last-write-wins on a timestamp taken from
  whichever device made the change. Because two devices' clocks are never
  exactly in step, a delete made on your phone could carry an *older* timestamp
  than your desktop's copy, lose the comparison, and be discarded; the desktop
  then re-uploaded the live note, resurrecting it on the phone too. A permanent
  delete is now **terminal** and always wins over a live copy, whatever the
  clocks say.
- **Sync no longer gets permanently stuck.** When a device decided its own copy
  was newer, it never recorded that it had seen the remote file and never
  pushed its copy either — so it re-downloaded and re-discarded the same file on
  *every* sync, forever, and pressing "Sync now" could never fix it. Both sides
  now converge in a single cycle.
- **No more resurrected notes.** A note whose Drive file was already cleaned up
  by another device is now removed locally instead of lingering and being
  re-uploaded on its next edit. The sweep is deliberately conservative: it never
  touches unsynced or locally-edited notes, and it stands down entirely on an
  empty or unrecognized Drive listing, so signing into a different account can't
  wipe a device.
- **Deletes are never sent by the fast after-edit sync**, which uploads without
  reading Drive first and could otherwise overwrite a deletion it hadn't seen.
- Tombstones with a missing deletion date are now cleaned up rather than kept
  forever (a SQL comparison against NULL is never true, so they were skipped).

### Added
- **Folder tags on note cards.** A note filed in a folder now shows that folder's
  name in its card footer, so you can tell where a note lives from Archive,
  Trash, and search results. It's hidden while you're already viewing that
  folder, since the title bar names it there.
- **Re-sync everything** (Settings → Sync). Forgets this device's sync
  bookkeeping and does a full two-way reconcile with Drive. Nothing is deleted —
  it's an escape hatch if a device ever looks out of date.
- Sync now reports what it actually did — "Up to date", or e.g. "Synced · 2
  updated · 1 removed" — instead of the old "↓0 ↑0".

### Notes
- Delete propagation had **no test coverage**, which is how this shipped: the
  existing tests applied remote changes directly and never exercised the
  conflict resolution. There is now a suite that runs two real sync engines
  against one shared Drive, covering clock skew, resurrection, convergence, and
  the safety guards. Five of its cases fail against the previous engine.

## [0.11.0] - 2026-07-13

### Added
- **App lock.** Protect PaperNotes behind a privacy gate, separate from note
  encryption. Turn it on in **Settings → App lock** and set a **PIN** (available
  on every platform). On devices with biometric hardware you can additionally
  **unlock with your fingerprint (Android)** or **Touch ID (macOS)** — it falls
  back to the PIN, and the option is hidden when no biometric is enrolled.
  Windows uses the PIN.
- **Manual & automatic locking.** A **Lock now** action (in the side menu and in
  Settings) locks the app immediately. **Auto-lock** re-locks the app after it
  has been in the background for a chosen interval — 1, 2, 5, 10, 30 minutes;
  1, 2, 4, 8, 12, 24 hours; or **Until app restart**. With App lock on, the app
  also locks on every cold start.

### Notes
- There is **no PIN recovery** — a forgotten PIN cannot be reset from inside the
  app, so keep it safe. Turning App lock off requires entering your current PIN.

## [0.9.0] - 2026-07-07

### Added
- **Attachments now sync across devices.** Files attached on one device upload
  to Google Drive (into the same private appDataFolder as notes) and download
  automatically on your other signed-in devices. Each note payload carries its
  attachments' Drive references; binaries are fetched on pull when they aren't
  already present locally. Removing an attachment (or permanently deleting its
  note) reclaims the Drive copy during the next full sync. Previously
  attachments were device-local — this replaces that behaviour.

### Fixed
- **Document scanner no longer crashes on Android.** Tapping **Scan document**
  threw `PlatformException(… NullPointerException)` because release
  minification (R8) stripped/renamed ML Kit's internal components, breaking its
  reflection-based initialization. Minification is now disabled for the release
  build, so ML Kit initializes correctly. (The APK is a few MB larger; for a
  Flutter app the engine dominates, so the difference is negligible.)

### Notes
- Attachment binaries count against your Google Drive storage, and large files
  transfer over your connection on each device — keep that in mind for big
  scans/videos.

## [0.8.0] - 2026-07-07

### Added
- **Note attachments.** Attach files to any note or checklist via the paperclip
  in the editor. On **Android** the attach button offers three sources: pick a
  file, **scan a document** (ML Kit document scanner with edge detection and
  auto-capture; multi-page scans land as a single PDF), or **take a photo**.
  On desktop (Windows/macOS/Linux) attachments are file-picker only. Attachments
  show as slim tiles under the note body (images get thumbnails) — tap to open
  with the system handler, × to remove. Cards show a paperclip badge.
  Attachments are **device-local**: binaries are never uploaded to Drive, and
  incoming synced edits never disturb the local attachment list. Files live in
  the app's private storage and are cleaned up when their note is permanently
  deleted (with a launch-time sweep for notes removed via sync).
  Storage: drift schema **v5** (additive `attachments` metadata column).

### Performance
- **Typing no longer serializes the whole document per keystroke.** The editor
  used to serialize + JSON-encode the full Fleather document on every keystroke
  *and* selection change (3–4 full document walks) just to detect edits; it now
  listens to the document's change stream and serializes once per debounced
  autosave. Long notes type noticeably smoother.
- **The editor no longer rebuilds after every background sync.** It watched the
  whole settings object, and each sync refreshed that object (also re-reading
  the encrypted secret store); it now selects just what it uses, and the
  post-sync refresh only touches the last-synced timestamp.
- **Autosaves no longer re-run the Archive and Trash queries forever.** Those
  watchers now dispose when their screens close; previously, after visiting
  Archive/Trash once, every autosave re-queried and re-mapped all three note
  lists for the rest of the session.
- **Auto-sync after an edit no longer re-lists the entire Drive folder.** The
  debounced after-edit sync now just uploads the changed rows when possible
  (full two-way sync still runs on launch, on the periodic timer, and manually).
- **Faster, calmer startup.** Notification/timezone initialization no longer
  blocks the first frame (on first Android launch the permission dialog could
  hold the splash screen indefinitely); reminders reconcile as soon as it
  completes.
- **Search stays fast past 512 notes.** The note-preview text cache is now
  keyed per note (validated by edit time), so large libraries no longer
  re-decode every body on each search keystroke.
- Added SQLite indexes for the note-list and sync queries; fixed an HTTP client
  leak in the update downloader and quadratic byte accumulation in Drive
  downloads.

## [0.7.1] - 2026-06-23

### Fixed
- **List view rows are now uniform.** In single-column list view, every note now
  renders at a fixed, content-independent height and full width, so rows no
  longer vary in size with note length. `NoteCard` gained a `uniform` mode (fixed
  height scaled by the user's font setting; the preview fills and clips the
  remaining space via `OverflowBox` + `ClipRect`). The masonry grid is unchanged.
- **Settings: last item no longer hidden under the navigation bar.** The Settings
  list now adds the system nav-bar inset to its bottom padding, so "Check for
  updates" clears Android's edge-to-edge navigation bar.

### Tests
- Added a widget test asserting a uniform list card renders at identical width
  and height regardless of body length, with no overflow.

## [0.7.0] - 2026-06-23

### Added
- **Configurable note swipe actions (Android).** Swipe a note left or right to
  run an action: delete (to Trash), pin, archive, reminder, or move to folder.
  Each direction is configurable in **Settings → Swipe actions** (Android only);
  defaults are right = Archive, left = Delete. Works in both list and grid views
  on active notes. Reuses the existing context-menu handlers, so undo snackbars
  and the reminder/folder sheets behave identically.

### Performance
- **Note preview/search no longer re-parse on every build.** `plainTextFromBody`
  now memoizes its result in a bounded (512-entry) content-keyed cache, so the
  Delta-JSON decode no longer runs per card build and per note on every search
  keystroke.
- Markdown-marker regexes are compiled once (hoisted to top-level finals) instead
  of on every call.
- List/grid cards are wrapped in `RepaintBoundary` to isolate repaints.
