# MoleUI

A native macOS interface for [tw93/Mole](https://github.com/tw93/Mole) — the terminal Mac
cleaner, laid out like CleanMyMac: 17 sections (Smart Scan, junk, leftovers, malware,
privacy, permissions, maintenance, updates, duplicates, a shredder and more) plus a
menu bar HUD. The Mole-backed sections drive the `mo` binary through its JSON and
NDJSON interfaces; the rest are native.

Mole is GPL v3 and is **not** bundled here. MoleUI spawns whatever `mo` you have
installed; install it yourself with `brew install mole`.

```bash
./build.sh          # builds, signs, and installs to /Applications
```

`./build.sh --no-install` builds without touching `/Applications`.

The test fixtures in `fixtures/` are real `mo` output with every personal name
replaced by a stand-in (`scripts/sanitize-fixtures.py`). Run that script on any
freshly captured fixture before committing it.

---

## Sections

Laid out like CleanMyMac's sidebar, but with overlapping sections merged, so
each job has exactly one place:

| Section | What it does | Source |
|---|---|---|
| **Smart Scan** | Runs the checks below concurrently and totals what can be freed. Looks only | all of the below |
| **System Junk** | Caches, logs, temp files → `mo clean` | `mo clean --dry-run` |
| **Leftovers** | Used installers + old project build folders + local mail attachment copies | `mo installer --debug`, `mo purge`, Mail store |
| **Trash Bins** | The Trash on every drive — the one *permanent* delete | `~/.Trash`, `/Volumes/*/.Trashes` |
| **Clean History** | What Mole has removed | `mo history --json` |
| **Malware Removal** | Every startup/background item, judged by code signature, location and known adware families. Plus Gatekeeper/SIP/FileVault/Firewall/XProtect status | launchd plists, Security framework |
| **Privacy** | Browser history, cookies, caches, sessions, autofill, **and browser extensions** for Safari, Chrome, Brave, Edge, Arc, Vivaldi, Opera, Firefox; macOS recent items | browser profile folders |
| **Permissions** | Every privacy grant (camera, mic, screen recording, FDA…) with Reset | TCC databases, `tccutil` |
| **Saved Wi-Fi** | Remembered networks, with Forget | `networksetup` |
| **Maintenance** | `mo optimize`, free RAM, flush DNS, rebuild Launch Services, reset Quick Look, compact Mail's index, thin Time Machine snapshots, reindex Spotlight, verify disk | system tools |
| **System Monitor** | Live CPU/memory/disk/network/battery | `mo status --watch` |
| **Uninstaller** | Remove apps and their leftovers; an **Unused** filter shows apps not opened in N days | `mo uninstall --dry-run` plan, Spotlight + app activity |
| **Extensions** | Third-party plug-ins and panes (Quick Look, Spotlight, audio, screen savers…) | `~/Library` & `/Library` |
| **Updater** | Homebrew packages, self-updating (Sparkle) apps, macOS | `brew outdated`, appcasts, `softwareupdate` |
| **Space Lens** | Drill-down disk usage | `mo analyze --json` |
| **Large Files** | Your big files by age, plus known space-heavy folders (caches, AI models, device backups, VMs) | Spotlight, fts |
| **Duplicates** | Byte-identical files (size → partial hash → SHA-256) | your folders |
| **Shredder** | Permanent deletion of files you pick, honest about APFS | — |

Merged on purpose: Installers/Project Junk/Mail Attachments → **Leftovers**;
Large & Old Files/Disk Hogs → **Large Files**; Browser Extensions → **Privacy**;
Optimization → **Maintenance**; Unused Apps → a filter in **Uninstaller**; and
startup items live only in **Malware Removal**, never twice.

Everything that removes things goes to the **Trash**, except Trash Bins and
Shredder, whose whole point is permanence. Root-owned items ask for your password
through macOS's own dialog (`osascript … with administrator privileges`) — the
app never sees it.

### Battery

The only continuous cost is the `mo status --watch` collector (1.7s of CPU per
minute at a 2s interval, measured). It now runs only on demand:

- 2s while System Monitor is on screen, 5s for the sidebar footer elsewhere.
- **Stopped** whenever the window is hidden, minimised or fully covered
  (AppKit occlusion), when the display or Mac sleeps, and on fast user switch.
- Half the rate in Low Power Mode. The menu-bar CPU readout is opt-in (10s).

Measured: hidden for 60s, the whole app used 0.09s of CPU with no collector
running. `~/Library/Logs/MoleUI/monitor.log` records every start/stop decision.

### Speed

Every list scan runs its sources concurrently, sizes trees with fts(3) across all
cores, and uses Spotlight where it already knows the answer. Measured on this Mac
with `open -n -a MoleUI.app --args --scan all`: every section scans in under 1s
except Updater (~3s; up to ~20s when Homebrew's hourly catalog refresh is due).
Results are cached, so revisiting a section is instant.

## Why this works without screen-scraping

Mole exposes a machine-readable surface underneath its TUI; the Mole-backed
sections use it.

Three behaviours of the CLI shape the whole design:

1. **`mo status` and `mo uninstall --list` switch to JSON when stdout is not a TTY.**
   A `Process` pipe never is, so JSON comes for free. The flags are passed
   explicitly anyway.

2. **`mo clean` skips its confirmation prompt when stdin is not a TTY**
   (`bin/clean.sh` — *"Running in non-interactive mode … User-level cleanup will
   proceed automatically"*). MoleUI's confirm sheet is therefore the **only** gate
   between a click and deletion. It always names the total.

3. **`mo uninstall --dry-run` prompts anyway, and treats EOF as abort** — so the
   preview never prints unless confirmation is fed to stdin. See
   `UninstallPlan.confirmationInput`.

4. **Since Mole 1.62, a real `mo uninstall` refuses to run without a terminal**
   (`lib/uninstall/batch.sh`: a script "could confirm an uninstall nobody
   reviewed"). MoleUI respects that rather than faking a TTY. Mole still produces
   the plan; you review it in the pane and confirm it in the sheet; MoleUI then
   moves exactly the files in that plan to the Trash itself
   (`UninstallPlan.remove`), with one macOS password prompt for root-owned App
   Store bundles. Homebrew-installed apps are refused with a pointer to
   `brew uninstall --cask`, so Homebrew's records stay correct.

### Two things the terminal UI doesn't give you

- **Per-file review before you commit.** `mo clean --dry-run` writes every exact
  path to `~/.config/mole/clean-list.txt`; the TUI only shows category rollups.
  MoleUI parses that file so you can read the actual list, grouped by category,
  before confirming.
- **Totals that match.** Mole deduplicates paths that appear under several
  categories before totalling, so summing the sections double-counts (it
  overstated by ~22GB here). MoleUI takes the total from Mole's own summary line
  and uses section sums only for bar proportions.
- **Sorting.** Every list that shows a size can be ordered largest-first,
  smallest-first, or by name (`ListSort`, `Views/Components/SortControl.swift`).
  The choice is per pane and persists across launches. Mole's own output arrives
  in scan order, so "which single thing is eating the most space" was previously
  a question you had to answer by reading.
- **Scans that survive leaving the pane.** `mo clean --dry-run` walks the whole
  disk, and each pane's model is a `@StateObject` destroyed when the sidebar
  switches away — so every visit used to re-run the scan. `ScanCache`
  (`Core/ScanCache.swift`) keeps the raw output under
  `~/Library/Caches/MoleUI/`, and the pane restores it instead, labelled with
  its age. Clean, Uninstall, Purge, Installers and the Analyze overview all use
  it.

Two rules keep the cache from lying:

- **Anything that deletes clears it.** A finished `mo clean`, uninstall or
  Move to Trash wipes the relevant keys, so a stale total can never end up behind
  an armed destructive button.
- **The Clean file list is snapshotted, never re-read.** Every `mo` run
  overwrites `~/.config/mole/clean-list.txt` in place, so re-reading it later
  would pair a newer list of paths with an older summary that never counted
  them. Entries older than 24 hours are ignored outright.

### How the delete works, and why it is a Trash move

Purge and Installers had no removal path at all, and Analyze offered only Reveal
in Finder. Every one of those lists, plus Clean's per-file list, now has row
checkboxes and a **Move to Trash** button (`Core/Trash.swift`).

`FileManager.trashItem`, one call per path — never `rm`, never a shelled-out
delete, never mole's own selector driven by synthetic keystrokes. The worst
outcome of a mis-click is opening the Trash and putting it back, which is the
only kind of delete a single click in a GUI should do. Three consequences:

- `mo clean`'s own button still deletes **permanently**, because that is what
  mole does. Ticking a file swaps that button out for the Trash one, so the two
  are never side by side.
- Nothing trashed from here appears in **History** — `mo history` records what
  mole deleted, and these removals do not go through mole.
- **Emptying the Trash is yours to do.** MoleUI has no path to it.

`Trash.rejection(for:)` is the guard, and it runs twice: once to decide whether a
row is even tickable, and again inside the delete itself, because a UI-only check
is one refactor away from being no check at all. It refuses `/`, every macOS
subtree (`/System`, `/usr`, `/bin`, `/etc`, …), the home folder, and every
standard folder inside it — `~/Downloads/Foo.dmg` can go, `~/Downloads` cannot.
That last rule matters most in Analyze, whose overview lists exactly those
directories as rows. The self-test asserts all 32 of them are refused, and does
one real round trip through `trashItem` to prove the delete itself works.

### Installers needed a different data source

`mo installer --dry-run` prints a selector page: names clipped to the column
width (`Invoke.Community.E...`), one page of them (18 of 22 here), and no paths.
That can back an inventory but never a delete — you cannot safely remove a file
whose name you only have three quarters of.

`mo installer --dry-run --debug` writes every installer to **stderr** with its
full path (`[DEBUG] Found installer:   * /Users/…/Downloads/Affinity.dmg`). The
pane reads that instead, takes sizes from the filesystem, and derives the
location label the same way `get_source_display()` in `bin/installer.sh` does.
The old selector parser survives as a fallback: if that debug line ever
disappears, the pane still lists what it can and simply offers no delete.


---

## Design

Dark-first "burrow" palette; follows the system appearance.

- **Red appears nowhere except destructive confirmation.** Warnings are amber,
  brand is purple. If something is red, it deletes.
- **Stratum bars** — every size breakdown is a flat horizontal soil-strata bar,
  never a pie or a rounded pill, so any two rows in any pane compare directly.
- **SF Mono with tabular figures for every byte count and path**, so sizes align
  into one scannable column.

---

## Findings from an adversarial audit

Three independent reviewers (destructive paths, parsers, process/concurrency),
each finding then checked by a skeptic. 13 confirmed. The ones worth carrying
forward, because none were visible from normal use:

- **Writing to a pipe kills the app.** Feeding stdin to a child that already
  exited raises `SIGPIPE`, and `try?` cannot catch a signal. `signal(SIGPIPE,
  SIG_IGN)` at startup turns it into a catchable `EPIPE`.
- **A `readabilityHandler` left installed spins a core.** A dispatch read source
  stays permanently signalled after EOF — measured at ~1.9M empty callbacks in
  two seconds. Terminating the child is what *causes* the EOF, so `stop()` must
  clear the handler, not just kill the process.
- **Mole's bash sizes are decimal.** `bytes_to_human()` in lib/core/base.sh
  branches on 1e9/1e6/1e3, so `parseBytes` is decimal. (Its *Go* commands are
  binary — see the second audit round; that needed two formatters, not one.)
- **`parseBytes` returned the biggest unit, not the first size.** `mo purge`
  always appends free disk space to its summary, so a sub-gigabyte result
  matched the trailing "GB" and the pane reported the whole disk as reclaimable.
- **An in-flight preview could back the wrong confirmation.** The uninstall list
  stays clickable during the dry run; a late-landing result re-armed the
  destructive button with a plan for the previous selection. Previews now record
  what they were for and are discarded if the selection moved on.
- **Selection was keyed on a non-unique field.** Three bundles here share the
  name "ChatGPT", so ticking one checked all three. Keyed on path now.
- **`allSatisfy` is vacuously true.** A section whose lines all failed to parse
  rendered as a confident "Nothing to clean".
- **`queue: .main` destroys a call stack.** NotificationCenter enqueues rather
  than running inline, so the window-close diagnostic was reporting itself
  instead of the caller. `queue: nil` delivers synchronously.

## Three SwiftUI gotchas this app hit

**1. Never observe a fast-changing object at App scope.** A `@StateObject` or
`@ObservedObject` property on the `App` makes every `@Published` change
invalidate `body` — and `body` is the *Scene* graph. `StatusMonitor` emits a
snapshot every 2 seconds, so observing it there rebuilt `WindowGroup` and
`MenuBarExtra` continuously, and the window eventually got torn down and never
came back: process alive, zero windows, main thread idle. Both shared objects are
singletons reached through computed properties now, and observation lives in the
leaf views that read them.

**2. `ScrollView` reports its *content* height as its ideal height.** Put one
inside a content-sized container and that container becomes thousands of points
tall — the whole `NavigationSplitView` then lays out off the top of the window,
taking the sidebar and pane header with it. The fix is
`.scrollableCardContent()` (`minHeight: 0, maxHeight: .infinity`); `maxHeight`
alone is not enough, because the problem is the *floor*, not the ceiling.

**3. `LazyVStack`, not `VStack`, for anything Mole produces.** With Full Disk
Access a single clean category runs to tens of thousands of paths. A plain
`VStack` instantiates every row up front and wedges the main thread.

## The "window disappears" bug — resolved

The window appeared to vanish on its own, leaving the app running invisibly.
Instrumenting the actual close (`--debug-windows`, see `WindowWatcher`) settled
it: over minutes of idle plus a full whole-disk Analyze scan, **not one
`NSWindow.willCloseNotification` fired**. The window never closed by itself. The
disappearances only ever happened during automated testing that drove the app
with synthetic clicks and keystrokes — input that lands wherever the pointer is,
and which at one point demonstrably went to a different application entirely.

What *was* genuinely broken is that nothing about the app made that survivable:

1. **`WindowGroup` accumulated duplicates.** ⌘N minted new windows and macOS
   restored every one from the previous session — three at once at one point.
   That alone made "is the window gone?" unanswerable.
2. **Closing it was a dead end.** `MenuBarExtra` keeps the app alive with no
   windows, and the reopen path called `makeKeyAndOrderFront` on
   `NSApp.windows.first`, a no-op in exactly the case that mattered.
3. **Quitting while closed restored *closed*.** The next launch came up with no
   window, so the app looked broken from the very first run.

Fixes: a single-instance **`Window`** scene instead of `WindowGroup` (no
duplicates, and the window object survives being closed so it can be ordered
back in), plus `applicationShouldHandleReopen` in `AppDelegate` so a Dock click
or `open` always restores it, plus **Open** in the menu bar HUD.

Verified: close the window → app alive, zero windows → `open` restores it; quit
while windowless → relaunch comes up with a window.

`--debug-windows` is kept. If it ever does recur, the log names the window and
prints the call stack of whoever closed it.

## Driving the app for testing

Headless scanner check — scans only, never acts. Launch through LaunchServices
so TCC attributes it to MoleUI rather than your terminal:

```bash
open -n -a /Applications/MoleUI.app --args --scan all     # or a pane: --scan malware, --scan smart
cat ~/Library/Logs/MoleUI/scan.txt
```

Every action's real code path, on disposable data the test creates (probe
files, a throwaway launch agent, MoleUI's own permission record) — never your
files, grants or networks — with everything it trashes removed again:

```bash
open -n -a /Applications/MoleUI.app --args --actiontest
cat ~/Library/Logs/MoleUI/actiontest.txt
```

Admin-only steps (Wi-Fi forget, free RAM, flush DNS, snapshots, Spotlight,
system-wide removals) are tested up to the password prompt: the identical
quoting runs unprivileged against a hostile name and must echo it verbatim.

**Toolchain note:** the macOS 27 SDK made SwiftUI's `@State` a macro whose plugin
ships only with full Xcode. With Command Line Tools alone, `build.sh` detects this
and builds against the newest macOS 26 SDK; for `swift build` by hand, set
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.


Never with synthetic clicks — they land wherever the pointer is, which during
this project meant keystrokes going into an unrelated application. Use launch
arguments through LaunchServices instead:

```bash
open -a MoleUI.app --args --pane clean --autoscan     # open a pane, run its preview
open -a MoleUI.app --args --debug-windows             # log window lifecycle
open -a MoleUI.app --args --fdacheck                  # report Full Disk Access
swift run MoleUI --icon /tmp/icon.png                 # redraw the app icon
```

Reports land in `~/Library/Logs/MoleUI/`.

One caveat learned the hard way: **`count windows` via System Events is
unreliable** when the app is not frontmost — it returns 0 for a window that is
demonstrably visible. Trust `--debug-windows` (which reads `NSApp.windows`
directly) over the accessibility API when the two disagree.

`--autoscan` only ever starts a **preview**. Nothing destructive is reachable
from a launch argument: `mo clean` skips its own confirmation when stdin is not
a TTY, so the confirm sheet is the only gate there is, and it stays in the UI.

---

## Permissions

`mo` walks the filesystem, so **macOS will prompt for Desktop / Documents /
Downloads access**, and the prompt is attributed to MoleUI. Until it is granted,
scans stall on those dialogs.

Grant **Full Disk Access** to `MoleUI.app` once
(System Settings → Privacy & Security → Full Disk Access) to replace the
per-folder prompts.

What it actually changes, measured on this machine:

| | Reclaimable | Items |
|---|---|---|
| No FDA | 16.49 GB | 665 |
| FDA, Trash full | 160.09 GB | 1820 |
| FDA, Trash empty | 16.50 GB | 666 |

So for **Clean**, FDA is almost entirely about `~/.Trash` — that directory is
TCC-protected, and `clean_trash()` in `lib/clean/user.sh` empties it. The cache
directories that make up the rest (`~/Library/Caches`, `~/.npm`, `~/.cargo` …)
are not protected, so they are found either way. Beyond the Trash it added six
sandboxed container caches and nothing under Desktop/Documents/Downloads —
because `mo clean` does not target those in the first place.

Where FDA genuinely pays off is **Analyze**, which walks the whole disk and is
meaningless if Downloads, Documents and Desktop are invisible to it.

The corollary matters before you click Clean: a large headline figure may be
mostly Trash. Read the file list.

### Why the grant used to reset on every build

TCC remembers an app by its *designated requirement*. Ad-hoc signing produces:

```
designated => cdhash H"0367c605…"
```

which is derived from the binary's contents, so every rebuild is a different app
as far as macOS is concerned and the grant silently stops applying.

A **self-signed certificate** fixes this — the requirement becomes:

```
designated => identifier "dev.rushil.moleui" and certificate leaf = H"<your certificate hash>"
```

No `cdhash`, so it is byte-identical across rebuilds. Verified by changing the
bundle and rebuilding: the code seal changed (`706162e6…` → `8b5fce24…`) while
the requirement did not.

`build.sh` prefers a real Apple identity, then falls back to one named
`MoleUI Self Signed`. Note that lookup deliberately drops `-v`: a self-signed
cert reports `CSSMERR_TP_NOT_TRUSTED` and never appears among "valid
identities", but `codesign` signs with it fine. Trust is a Gatekeeper and
distribution concern; all that is needed here is a *stable* identity.

To recreate the certificate (new machine, or if the keychain item is deleted):

```bash
cat > cert.cnf <<'CNF'
[ req ]
default_bits = 2048
distinguished_name = dn
prompt = no
x509_extensions = v3_codesign
[ dn ]
CN = MoleUI Self Signed
[ v3_codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -config cert.cnf

# -certpbe/-keypbe/-macalg are required: OpenSSL 3 defaults to a PKCS#12 MAC
# that macOS's importer rejects with "MAC verification failed".
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "MoleUI Self Signed" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 \
  -out identity.p12 -passout pass:moleui

security import identity.p12 -k ~/Library/Keychains/login.keychain-db \
  -P moleui -T /usr/bin/codesign -T /usr/bin/security

rm -f key.pem identity.p12   # the private key now lives in the keychain
```

Regenerating produces a different certificate, so Full Disk Access has to be
granted once more after that — but only once.

Two failure modes `build.sh` now guards against, both of which silently break
the grant rather than erroring:

- **`cp -R` does not preserve a bundle's code signature.** The copy degrades to
  an ad-hoc cdhash requirement. `ditto` is used instead.
- **`codesign` can fail transiently with `errSecInternalComponent`** when the
  keychain does not release the key. The old script fell through to ad-hoc
  signing without a word; it now retries, verifies the requirement really is
  certificate-based, and says so loudly if it is not.

Because TCC keys on bundle id + requirement rather than path, one grant covers
both the build copy and `/Applications` — installing does not cost a re-grant.

System caches additionally need an active sudo session. MoleUI never asks for a
password; the Clean pane shows a notice with the `sudo -v` command to run first,
or enable Touch ID for sudo via `mo touchid`.

---

## Layout

```
Sources/MoleUI/
├── MoleUIApp.swift          entry point, WindowGroup + MenuBarExtra, Router
├── Core/
│   ├── MoleCLI.swift        locate binary, run, runJSON, NDJSON streaming
│   ├── MoleModels.swift     Codable models for every JSON command
│   ├── CleanPreview.swift   parsers for the two text-only commands
│   ├── UninstallPlan.swift  parser for uninstall --dry-run
│   ├── StatusMonitor.swift  shared, ref-counted status collector
│   └── SelfTest.swift       fixture decoding check
├── Views/                   one file per pane + Components/
└── MenuBar/StatusHUD.swift
```

`MoleCLI` handles the three things that actually bite: a GUI app inherits
launchd's `PATH` rather than the shell's (so the binary is probed at known
prefixes, then via a login shell); both pipes must be drained concurrently or a
full stderr buffer deadlocks a megabyte-scale `analyze`; and NDJSON snapshots run
to ~8KB and straddle read boundaries, so partial lines are buffered.

Models decode with missing scalar keys defaulting to zero — Mole marks many Go
fields `omitempty`, and Swift's synthesized decoder otherwise fails a whole
snapshot over one absent `purgeable`.

---

## Verification

```bash
swift run MoleUI --selftest      # decodes every fixture, checks the size parser
```

Fixtures cover both halves of every command that has them: the `--dry-run`
preview *and* the completion output of a real run, which is worded differently
(`Tracked cleanup:` vs `Potential space:`, `Applied N` vs `Would apply N`) and
went unparsed for a long time because only previews were ever captured.

`clean_run.txt` is a genuine non-dry-run `mo clean`, captured with
`MOLE_TEST_MODE=1` so the real code path executes and deletes nothing —
confirmed by the deletions log and `~/Library/Caches` being byte-identical
before and after.

Checking Full Disk Access — worth doing explicitly, because without it `mo` does
not fail loudly, it just quietly reports less, and an under-reporting scan looks
exactly like a scan that found little:

```bash
open -a MoleUI.app --args --fdacheck && sleep 3 && cat ~/MoleUI/fdacheck.txt
```

**It must be launched with `open`.** TCC attributes a request to the
*responsible* process, so running the binary straight from a terminal measures
the terminal's permissions, not the app's — which will happily report success
while the app itself has no access. The check prints which case it is
(`responsible: LaunchServices` vs `shell (RESULT INVALID)`).

The verdict rests on `~/Downloads`, `~/Documents`, `~/Desktop` and `~/.Trash`.
The classic `TCC.db` canary is reported but not counted: on this macOS that path
does not exist even for a process that does hold Full Disk Access, so its
failure means nothing.

Fixtures in `fixtures/` are real captured output, not hand-written. Re-capture
them after a Mole upgrade and re-run the self-test to catch JSON drift:

```bash
cd fixtures
NO_COLOR=1 mo status --json      > status.json
NO_COLOR=1 mo analyze --json     > analyze_overview.json
NO_COLOR=1 mo uninstall --list   > apps.json
NO_COLOR=1 mo history --json     > history.json
NO_COLOR=1 mo clean --dry-run    < /dev/null > clean_dryrun.txt
NO_COLOR=1 mo optimize --dry-run < /dev/null > optimize_dryrun.txt
```

## Second audit round

Re-run after the round-one fixes, since the code had changed substantially.
Five confirmed, all fixed — and two of them were defects *introduced by the
round-one fixes*, which is the argument for auditing again after fixing:

- **One formatter could not serve both sources.** Switching everything to
  decimal fixed the bash-derived sizes and broke the Go-derived ones — mole's
  `status`/`analyze` render binary (`24.0 GB` = 24 GiB), its `clean`/`purge`
  render decimal. There are now two: `formatBytes` (binary, for JSON byte
  counts) and `formatSize` (decimal, for anything `parseBytes` produced).
- **The dry-run banner was counted as pending work.** Mole's `ICON_DRY_RUN` is
  U+2192 — the same glyph as an action item — so "→ DRY RUN MODE, No files will
  be modified" was parsed as one. Every preview overstated its actionable count
  by one. The selftest now asserts the parsed count equals the number of `→`
  lines actually inside sections.
- **Uninstall errors were unreachable.** `model.error` was only rendered in the
  branch that requires the app list to be empty, so every later failure — a
  preview with no plan, a flag-shaped name, a failed removal — was invisible.
- **The new restart cap did not cap anything.** `ingest()` cleared
  `restartAttempts` on the *first* snapshot, so any collector that emitted one
  line before dying reset the counter every cycle — a bounded retry that was
  actually an unbounded process-spawn loop, worse than the bug it replaced. The
  counter now only resets once a stream has stayed up a minute, retries are
  spaced two seconds apart, and a fresh subscribe restores the quota. Verified
  by killing the collector five times: three respawns, then it stays down.
- **Dropping a Stream reference does not stop it.** A `Stream` is retained by its
  own `readabilityHandler` closure, so `stream = nil` never runs `deinit`. If the
  error belonged to a superseded stream, that orphaned the live child instead of
  the dead one. The error path calls `stop()` now.

Round one found 13, round two found 3. The trend is the useful signal: the code
is converging, but "no findings" has not happened yet.

## Third audit round

Scoped deliberately to only the code written after round two, on the reasoning
that the riskiest code is the most recently written — round two's worst finding
was created by round one's fix. Four confirmed, and they overturned something I
had asserted confidently twice:

**Byte units are per command, not per language.** The earlier note here claimed
"Go renders binary, bash renders decimal". Measured against the real tool:

| Command | Base | Evidence |
|---|---|---|
| `mo status` | binary | `memory.total` 25769803776 → its own `"24.0 GB"` (= GiB) |
| `mo analyze` | **decimal** | TUI renders 105671585330 as `105.7 GB`, not the 98.4 GiB binary gives |
| `mo clean` / `mo purge` | decimal | `bytes_to_human()` branches on 1e9/1e6/1e3 |
| `mo history` | decimal, `size_kb` in KiB | `bytes_to_human_kb` multiplies by 1024, then formats decimally |

So the Analyze pane had been showing 98.4GB where mole itself shows 105.7GB.
The formatters are now named for their divisor (`formatBytesBinary` /
`formatBytesDecimal`) so a call site cannot be wrong by accident, and decimal
places match per command — Mole prints two at GB from bash (`16.57GB`) and one
from `status`/`analyze` (`24.0 GB`, `105.7 GB`).

Also fixed: a snapshot delivered after its collector died could set
`isRunning = true` and clear the error, putting the green "live" dot back over
frozen data. Callbacks now carry a generation token, so a superseded stream's
snapshot is dropped — `stream != nil` alone could not tell the difference once a
replacement had started.

Also fixed: `Int64(value * multiplier)` in `parseBytes` **traps** on overflow
rather than saturating, which aborts the whole app. Scanning by position made it
more reachable, not less — a filename like `…/9999999999999999999KB_dump` is now
examined before the real size. It returns nil for absurd values instead, with
`Int64(exactly:(x).rounded())`; the `.rounded()` is required, since
`163.3 * 1e6` is `163300000.00000003` and `exactly:` alone would reject every
normal MB figure.

Findings by round: **13 → 5 → 5.** Not zero, and each round has found at least
one defect created by the previous round's fixes.
