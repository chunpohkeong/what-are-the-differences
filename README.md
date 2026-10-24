# Delta

A native macOS app for comparing and merging files and folders. The app builds with SwiftPM; the Finder extension is compiled by `scripts/bundle.sh` with Xcode's `swiftc`.

- **Text Compare**: two editable panes, line and in-line highlights, synced scrolling, a difference map, and ignore-whitespace/case options. ⌘↓ / ⌘↑ move between differences.
- **Folder Compare**: tree view with Same / Newer / Different / Left-only / Right-only status, plus filters, include/exclude masks and an optional byte-by-byte check. Copy either way or move items to the Trash, each after a confirmation. Double-click a row to compare that pair.
- **Folder Sync**: Update right, Update both, or Mirror. You always see the full list of operations first.
  It can also compare against the clipboard (⇧⌘V) and compare PDFs as text. The More menu exports a patch, applies a patch to the left side (the result shows unsaved on the right), and saves an HTML report.
- **Text Merge**: 3-way merge (left, base, right) into an editable output. Clean changes merge automatically; conflicts get Take Left / Right / Both / Base.
- **Folder Merge**: 3-way folder merge into an output folder. Files are decided by comparing their contents against base. Conflicts can be taken from either side or opened in Text Merge.
- **Hex Compare**: side-by-side bytes and ASCII, with differing bytes highlighted. Files are memory-mapped, so large files open quickly.
- **Table Compare**: CSV/TSV with quoted fields. Rows match by key columns (e.g. `1,3`) or by position; changed cells show `old → new`.
- **Picture Compare**: left, right and a difference overlay, with a tolerance slider.
- **Archives and snapshots**: a `.zip`/`.tar`/`.tgz`/`.7z` (read-only) or a saved `.deltasnap` folder listing can stand in for a folder in Folder Compare. Save a snapshot or an HTML report from the More menu.
- **Finder extension**: right-click to Select Left Side, Compare to it, or Compare two selected items.
- **`delta` CLI**: opens any of the above from a terminal or git, or prints a unified diff.

Delta never hard-deletes. Anything it removes or overwrites goes to the Trash first, so the Trash is your undo.

## Install

Download `Delta-<version>.dmg` from the [Releases](../../releases) page, open it, and drag **Delta** into **Applications**.

Delta is signed ad-hoc ("Sign to Run Locally"), not with an Apple Developer ID, and it is not notarized. The first time you open it, macOS will block it. Either:

- right-click Delta in Applications and choose **Open**, then **Open** again; or
- run `xattr -dr com.apple.quarantine /Applications/Delta.app` once.

Requires macOS 15 or later on Apple Silicon.

## Build

```bash
./scripts/test.sh       # DiffCore unit tests
./scripts/bundle.sh     # release build → build/Delta.app (symlink into ~/Library/Caches/DeltaBuild)
open build/Delta.app
```

Both scripts keep build output in `~/Library/Caches/DeltaBuild`. iCloud-synced folders add Finder metadata that makes `codesign` fail. `test.sh` also points the compiler at Swift Testing's macro plugin, which Command Line Tools does not find on its own.

## Command line

```bash
ln -s "$PWD/build/Delta.app/Contents/MacOS/delta" /usr/local/bin/delta   # once (may need sudo)

delta a.txt b.txt                          # Text Compare
delta dirA dirB                            # Folder Compare
delta local.txt remote.txt base.txt --output merged.txt   # Text Merge
delta a.bin b.bin                          # Hex Compare (any binary file)
delta a.csv b.csv                          # Table Compare
delta a.png b.png                          # Picture Compare
delta dir app.zip                          # folder vs archive (or a .deltasnap snapshot)
delta dirL dirR dirBase --output dirOut    # Folder Merge
delta a.txt b.txt --text                   # unified diff on stdout
delta a.txt b.txt --report diff.html       # HTML report (text files or folders), no window
```

`--wait` blocks until the window closes. Exit status: 0 means same or merged cleanly, 1 means different or conflicts remain, 2 means error.

## Git

```bash
git config --global diff.tool delta
git config --global difftool.delta.cmd 'delta "$LOCAL" "$REMOTE" --wait'
git config --global merge.tool delta
git config --global mergetool.delta.cmd 'delta "$LOCAL" "$REMOTE" "$BASE" --output "$MERGED" --wait'
git config --global mergetool.delta.trustExitCode true
```

`git difftool -d` opens a Folder Compare.

## Finder extension

`bundle.sh` builds `Delta.app/Contents/PlugIns/DeltaFinder.appex` and registers it with `pluginkit`. Turn it on in **System Settings › General › Login Items & Extensions**, in the Extensions section (listed as Delta). It is signed ad-hoc ("Sign to Run Locally"), so after a rebuild you may need to turn it off and on again.

## Layout

- `Sources/DiffCore`: UI-free engine. Line diff (Myers via the stdlib), in-line diff, diff3 merge, folder compare (folders or snapshots), sync planner, folder merge, file-operations actor, text loading (encoding, BOM and line endings preserved), unified diff and patch apply, hex/CSV/image compare, archives, and HTML reports.
- `Sources/DeltaApp`: SwiftUI shell with AppKit text views (TextKit 1) for large files.
- `Sources/DeltaCLI`: the `delta` tool. It talks to the app via `delta://open?...` URLs.
- `Extensions/DeltaFinder`: the Finder Sync extension.
- `scripts/make-icon.swift`: draws the app icon (`Resources/AppIcon.icns`).
- `Tests/DiffCoreTests`: Swift Testing.
- `Fixtures/`: sample inputs for trying each mode.

Test hook: launching with `DELTA_SNAPSHOT_DIR=<dir>` writes each session window to a PNG. Adding `DELTA_SNAPSHOT_CLOSE=1` also closes the window afterwards, which exercises `--wait`.

## Known limits

- Hex Compare matches bytes by offset, so one inserted byte marks every later row.
- Snapshots record size and date only, not contents.
- Folder Merge ignores empty folders.
- PDF text comes from PDFKit, which drops indentation; use Ignore whitespace.
- `delta --wait` waits forever if the app is force-quit (press Ctrl-C).
