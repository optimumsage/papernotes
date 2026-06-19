# PaperNotes

A fast, lightweight notes & checklist app for **Android, Windows, macOS, and Linux**, built with Flutter from a single codebase. Notes live on-device by default and optionally sync two-way through **your own** Google Drive.

## Features

- **Notes & checklists** — plain-text notes (title optional) and checklists (title required).
- **Hidden titles** — a note's title field stays hidden until you tap **⋮ → Add title**.
- **Colors** — assign a color from a curated, light/dark-aware palette.
- **Search** — live search across titles, body text, and checklist items.
- **Sort & view** — order by last edited / created / title / color; switch between grid and list layouts.
- **Context menu** — right-click (desktop) or tap-and-hold (Android) any note for quick actions (pin, color, archive, delete).
- **Archive & Trash** — archive notes out of the way, or delete to Trash. Trash supports restore, individual permanent delete, **Empty trash**, and configurable auto-empty. Reach both from the side drawer.
- **Pin** — keep important notes at the top.
- **Settings** — theme, font size, default note color, sync-on-launch, background auto-sync interval, confirm-before-delete, and trash retention.
- **Local-first** — with sync off, nothing leaves the device.
- **Two-way Google Drive sync** — edits from any of your devices merge by
  last-write-wins. Each note is one `<uuid>.json` file in Drive's hidden
  **appDataFolder**, so filenames never collide and the rest of your Drive is
  never touched (scope: `drive.appdata`). Deletions propagate via tombstones.

## Architecture

```
lib/
  core/        theme, color palette, constants
  data/
    local/     drift (SQLite) database + DAO
    models/    Note, ChecklistItem (+ JSON)
    repositories/  NoteRepository (CRUD, search)
    sync/      drive_auth, drive_client, sync_engine
    settings_service.dart
  features/    notes_list, editor, settings (UI)
  providers/   Riverpod wiring
```

- **State:** Riverpod. The UI reacts to drift streams, so local edits and
  incoming syncs update the grid automatically.
- **DB:** drift over `sqlite3` (native on every target).
- **Secrets:** client secret and refresh token are kept in the OS keystore via
  `flutter_secure_storage`.

## Running

```bash
flutter pub get
dart run build_runner build       # regenerate drift code if models change
dart run flutter_launcher_icons   # regenerate app icons if assets/icon/* change

flutter run -d macos          # or windows / linux / <android-device>
```

## Enabling Google Drive sync

Sync uses **your own** Google OAuth credentials so your notes stay in your
account. One-time setup:

1. Go to the [Google Cloud Console](https://console.cloud.google.com/), create
   a project.
2. **APIs & Services → Library →** enable **Google Drive API**.
3. **APIs & Services → OAuth consent screen:** configure it (External is fine),
   add the scope `.../auth/drive.appdata`, and add your Google account under
   **Test users**.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID →
   Application type: Desktop app.** Copy the **Client ID** and **Client
   secret**. (The desktop client's loopback flow is what PaperNotes uses on every
   platform.)
5. In PaperNotes: **Settings → Google Drive sync**, paste the Client ID and
   secret, then **Sign in & enable sync**. A browser window opens for consent;
   approve it and return to the app.

After that, **Sync now** runs a full two-way sync, and the app also syncs on
launch, on resume, and every few minutes while enabled.

> **Note on Android:** the loopback redirect works through the system browser.
> If you publish to multiple Google accounts or hit redirect restrictions, you
> may add a dedicated **Android** OAuth client in the same project; the sign-in
> flow is abstracted in `lib/data/sync/drive_auth.dart`.

## Releases & updates

Pushing a version tag (e.g. `git tag v0.1.0 && git push origin v0.1.0`) triggers
the GitHub Actions workflow in `.github/workflows/release.yml`, which builds
Android (signed APK), macOS, Windows, and Linux artifacts and publishes them to
a **GitHub Release**. The app can check for and install updates from there via
**Settings → About → Check for updates** (on Android it downloads and installs
the APK; on desktop it opens the release download).

Android signing uses a release keystore; the secret material lives in the repo's
GitHub Actions secrets (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`). Keep a backup of
`android/app/papernotes-release.jks` — it is required to publish updates and is
deliberately not committed.

## Testing

```bash
flutter analyze
flutter test
```

Unit tests cover JSON round-trips, the empty/discard rules, search, and the
sync conflict resolution (last-write-wins + tombstones) against an in-memory
database.
