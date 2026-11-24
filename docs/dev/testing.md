# Test preparation and platform validation

Run with a supported Rust toolchain and native build tools. Use the actual target OS: WSL and a Linux container do not exercise Windows APIs. Tests use synthetic files, private temporary state and test daemons; do not register real folders or install a background service for them.

## Native runners

Test scripts and diagnostics live in `tests/`; preparation recipes and report details are in `tests/README.md`. Rust tests remain in their Cargo crates.

| Host | Prerequisite probes only | Full strict validation |
| --- | --- | --- |
| Linux/macOS | `./tests/run.sh --check` | `./tests/run.sh` |
| Windows PowerShell 7 | `pwsh -NoProfile -File .\tests\run.ps1 -Check` | `pwsh -NoProfile -File .\tests\run.ps1` |

Full validation checks formatting and Clippy, installer syntax, bounded builds, the complete host-selected workspace through cargo-nextest, all fourteen real-daemon interruption cases, and doctests separately. The interruption matrix uses an isolated debug build under `target/test-checkpoints/`; its opt-in feature refuses release builds and never changes cleanup authorization. Unix also exercises the shell installer with a local fake release. The shared `tests/nextest.toml` starts both strict HEIC workflows first, without repeating them in another phase. All platforms use four workers and no retries. The default per-test deadline is 60 seconds. Only the Windows installer fixture has a longer deadline: 180 seconds for its PowerShell child and 210 seconds for nextest so the fixture can clean up and report errors. Missing prerequisites, skips, incomplete suites, leaked processes and failed checks remain failures. Windows' strict disposition/undo gates remain release blockers.

Reports go to a unique directory under `target/test-reports/`. The console prints phase status and log locations; full output stays in files. Reports contain host/tool versions, revision, working-tree status, the tracked diff, limits, elapsed times and a final summary. Untracked file contents are not captured. Scratch state is private and retained; cleanup reports leaks and stops only identifiable processes associated with that run. Inspect logs and diffs before sharing.

`RETYPE_TEST_TIMEOUT_SECONDS` accepts 1 through 3600, default 300. Clippy, installer checks and compilation have bounded steps; workspace execution and doctests then share a separate budget of that length, so cold compilation does not consume execution time. An unreached phase is incomplete. Formatting has a 60-second limit and tool probes have a 10-second limit. Absolute `RETYPE_TEST_REPORT_DIR` and `RETYPE_TEST_TEMP_DIR` values override report and scratch parents; Unix scratch paths must be short enough for daemon sockets.

Linux uses GNU `timeout`; macOS uses `/usr/bin/perl` and core modules without `gtimeout`. The macOS supervisor records a bounded process-group snapshot after a timeout and before final cleanup. All bounded commands have closed stdin; terminal tests create their own terminals. Check mode validates tool probes, the nextest version requirement and ImageMagick decoding of the checked-in HEIC fixture, not the full conversion or undo workflow. The runners do not establish release-artifact, power-loss, real disk-exhaustion, network-filesystem or every-architecture evidence.

## GitHub Actions

Debian 13 amd64, macOS 15 arm64 and Windows amd64 compatibility CI are required. Debian ARM64, macOS Intel and Windows ARM64 are best effort; failed optional jobs do not upload release artifacts. Debian uses trixie converters, Typst 0.11.1 for its older Pandoc, UID 1000 and dropped capabilities. Its exact preview archive checks the installed scheme default, owned handler path and data workflow. Windows uses the native Rust host, fixed local NTFS scratch and a verified non-administrator worker, then checks the exact release executable/archive with `--preview-cli-only`. That smoke includes real user-PATH mutation and owned cleanup, but no OS scheme registration, notification, or startup qualification. macOS builds its native release executable and fresh unsigned notifier bundle; hosted CI does not authorize real-user integration or finalize the unqualified archive producer. Every platform uses cargo-nextest, and Windows uses PowerShell 7. Reports and filesystem-event probes are uploaded after failures; MSRV and release workspace tests have ten-minute deadlines.

The exact archive test calls the installed CLI to check that legacy URI Undo, an abbreviated ID and JSON Review are refused without changing files, the journal or recovery. Separate direct CLI Undo checks cover exact originals and owned outputs with the daemon running and stopped, with no spawn during offline Undo. No display, notification click or local consent is simulated.

Each native executable earns `png:jpg` and `png:webp` property evidence for its own tool builds. Installed checks require exact archive/manifest bytes and the correct packaged claim record; matching builds require `earned`, changed builds require `unverified`, with conversion and exact undo still mandatory. Every selected pair must succeed. Windows strict disposition/undo still requires qualified local NTFS paths. These manifests do not qualify additional architectures, OS floors or publisher signatures.

Manual workflow dispatch builds preview artifacts. An explicit [unsigned alpha dispatch](https://github.com/LapilliWorks/retype/blob/master/packaging/README.md#unsigned-cli-alpha) stages three checked CLI archives in an unpublished prerelease draft. Signed tag publication verifies an [approved signed candidate](https://github.com/LapilliWorks/retype/blob/master/packaging/README.md#signed-candidate-handoff), including three primary archives, the pinned canonical installers and a separately signed qualification statement tied to the exact signed manifest. Signing and qualification run on the approved hosts before the signed workflow consumes the assets. The assembly failure fixtures and canonical embed checks run in CI. Retain qualification reports outside Cargo `target/`, with exact source revisions, logs, snapshots and failed fixtures.

Hosted Windows Server orchestration may be administrative; product tests run under the verified restricted worker. That is not Windows 10 22H2 or an authorized client desktop. Hosted macOS is not an authorized user's interactive session. These jobs do not test physical power loss, real storage exhaustion, all advertised architectures, network or cloud filesystems, or client-session behavior. Use the separate disposable-VM and native-host tests where those properties matter.

## Initial release scope

Required targets are Windows 10 22H2 amd64, Debian 13 amd64 and macOS 15 arm64, as defined in [Platforms](../reference/platforms.md#1-support-matrix). Other desktop OS/version/architecture combinations are best effort, not mandatory qualification gates. This is the current release scope, not a permanent platform policy. The GUI and managed converter toolchain are out of scope.

Release approval requires the exact signed candidate and real URI, startup, notification, session and owned-removal checks on authorized ordinary-user profiles for the supported targets. Hosted Windows Server compatibility CI is not Windows 10 22H2 client evidence. Controlled sessions, container userspace, synthetic registry/tool fixtures and preview CLI-only smoke checks do not satisfy the signed installed gate. Missing publisher material, native access or required desktop behavior leaves that gate blocked.

Physical-hardware power-loss, sleep/wake and device/controller qualification is deferred and is not an initial-release gate. Existing process-interruption and actual guest power-cut evidence remains valid only within its recorded scope; it does not establish physical storage flush compliance or a physical power-loss guarantee. Original-byte preservation, replacement refusal, recovery, trust-boundary validation and unsupported-path refusal remain mandatory.

### Native notification Review

Use the exact signed candidate and an approved ordinary-user graphical login on each supported target. Use disposable files and record the original, output and unrelated file hashes. This check is manual; installed CLI and synthetic registration results do not replace it.

1. Confirm the OS default `retype` handler belongs to this install: Linux's `xdg-mime` association and desktop entry, Windows' protocol registration pointing to the installed `retype-review.exe`, or macOS' LaunchServices association and installed bundle with the matching inner CLI.
2. Trigger eligible watched conversions and click the real **Review** notification action. Debian Wayland with Zenity must retain batch Review for multiple conversions; on Windows and macOS, each actionable notification must select one job using its full ID. Also open a canonical registered link `retype://job/<full-job-id>` separately. On Windows, neither launch may show a console window. Opening the link or notification must not change job data or start a daemon.
3. Confirm **Close** is the default and preserves current files and recovery. Confirm Escape, window close and timeout are also non-consent. Reopen Review, verify that it shows every affected original and output, then explicitly choose **Undo**. Verify exact original bytes, removal of only matching job outputs, and preservation of unrelated files. On a fresh disposable job, change an output while the dialog is open and verify the stale Review cannot authorize Undo.
4. Disable notification actions on the disposable profile and verify the plain fallback, with no Review action or change to job data from the notification. Record OS/session, install revision and each result, including any unverified behavior.

## 1. Baseline tests

```sh
cargo test --workspace --locked --no-fail-fast
```

This builds and runs the tests selected for the host. It is not complete encoder validation: optional tool tests can return early when prerequisites are absent, and Rust reports those returns as passes. Use strict tool mode for a verification run.

## 2. External prerequisites

Make the programs available on `PATH` in the same terminal that runs Cargo. Reopen the terminal after installation if the installer changed `PATH`.

| Test target | Required preparation |
|---|---|
| `fidelity`, `fidelity_axes` | ImageMagick 7.1 or newer, with 16-bit image support such as a Q16 build; PNG, JPEG, GIF and TIFF support |
| `keep` real watched workflow and core JPEG validation | ImageMagick 7.1 or newer with HEIC decoding and JPEG encoding; FFmpeg with MJPEG decoding |
| `video` | FFmpeg 6 or newer and FFprobe, with `mpeg4`, `aac`, `libvpx-vp9`, `libopus` and `libmp3lame` encoders |
| `documents` | Pandoc 3 or newer and at least one usable PDF engine: `typst`, `xelatex`, `lualatex`, `pdflatex`, `weasyprint` or `wkhtmltopdf` |
| `archives` | Native ZIP/TAR cases need no external archiver; 7z cases require 7-Zip 23 or newer as `7zz`, `7z` or `7za` |
| `data_safety_transactions`, `data_safety_audit_additional`, core `safety` | Native archive and filesystem cases need no external encoder; a few shell/symlink cases are Unix-only |
| `data_safety_audit` | Unix shell and ordinary Unix utilities; currently excluded on Windows |
| Windows Job Object tests | No encoder, PowerShell script or extra runtime: helper processes use the Rust test binary itself |

Pandoc alone is insufficient for the document target. Typst is a straightforward standalone choice. TeX engines also need the packages and fonts used by Pandoc's template; an engine executable alone may not constitute a working installation. Keep Pandoc and the selected engine compatible. Debian 13's Pandoc 3.1.11.1 and Pandoc 3.7.0.2 with Typst 0.15.1 fail PDF generation with `font fallback list must not be empty`; Pandoc 3.11 with that Typst version works. Debian preparation installs the converters; install an older Typst separately for the older Pandoc. [Older Pandoc and Typst](../advanced/converters.md#older-pandoc-and-typst) provides download, verification and absolute-path configuration commands. CI selects Typst 0.11.1 for Debian 13. Debian 13 amd64 preview testing passed PDF conversion and Undo with Pandoc 3.1.11.1 and Typst 0.11.1. Keep the default engine preference and report incompatibilities rather than substituting another engine. The default engine order is the order shown above.

The video tests exercise the shipped WebM and MP3 targets; they do not prove that the MP4, MKV or MOV defaults work without `libx264`. Check capabilities instead of assuming that an installed `ffmpeg` is sufficient:

```sh
magick -version
magick fixtures/native-watch/photo.heic null:
ffmpeg -version
ffprobe -version
ffmpeg -hide_banner -encoders
pandoc --version
typst --version
7z i
```

Use the PDF-engine and 7-Zip command names actually installed on the host. In the encoder listing, verify the five video-test encoder names exactly. Native archive/cancellation/recovery tests do not require these programs.

## 3. Strict tool verification

`RETYPE_REQUIRE_TEST_TOOLS=1` makes the CLI image, fidelity, video, document and archive suites and core JPEG validation tests fail their prerequisite guards instead of returning early. It does not enable tests excluded by `cfg`, and is not a promise that every codec supported by an installed program has been exercised.

Video test commands have bounded probes and conversions; a timeout reports the stage, command and captured output. On Unix, timed-out commands are stopped as process groups. These bounds identify a stalled step, not its underlying cause.

Linux/macOS:

```sh
RETYPE_REQUIRE_TEST_TOOLS=1 cargo test --workspace --locked --no-fail-fast -- --nocapture
```

PowerShell:

```powershell
$env:RETYPE_REQUIRE_TEST_TOOLS = '1'
cargo test --workspace --locked --no-fail-fast -- --nocapture
```

To check only the real-tool targets after installing their prerequisites:

```sh
cargo test -p retype-cli --locked --test keep --test fidelity --test fidelity_axes --test video --test documents --test archives --no-fail-fast -- --nocapture
```

Set strict tool mode in that shell before the targeted command too. Without it, `SKIPPED:` messages still identify missing prerequisites, but the test harness can report those tests as passed. A missing PDF engine is an error once Pandoc is present, including in an ordinary run.

### Strict native rename and undo gate

Run these on each release OS to require real watched and direct HEIC-to-JPEG conversions, normal source disposition and complete undo that restores the exact original bytes and removes the output. Strict mode fails rather than skipping if ImageMagick, its HEIC decoder or JPEG encoder, or FFmpeg is unavailable. The tests copy a checked-in synthetic HEIC fixture into private state and start their own daemons.

Linux/macOS:

```sh
RETYPE_REQUIRE_NATIVE_WORKFLOW=1 cargo test -p retype-cli --locked --test keep a_real_watched_heic_conversion_and_undo_preserve_the_original -- --nocapture
RETYPE_REQUIRE_NATIVE_WORKFLOW=1 cargo test -p retype-cli --locked --test keep a_real_direct_heic_conversion_and_undo_follow_watched_disposition -- --nocapture
```

PowerShell:

```powershell
$env:RETYPE_REQUIRE_NATIVE_WORKFLOW = '1'
cargo test -p retype-cli --locked --test keep a_real_watched_heic_conversion_and_undo_preserve_the_original -- --nocapture
cargo test -p retype-cli --locked --test keep a_real_direct_heic_conversion_and_undo_follow_watched_disposition -- --nocapture
```

This gate fails when the validator retains the visible source or the platform cannot complete destructive undo. A passing ordinary tool suite is not a substitute for this gate.

## 4. Filesystem and OS preparation

Use a normal, non-administrator account and a local filesystem supporting hard links and atomic renames. Prefer ext4/Btrfs on Linux, APFS on macOS and NTFS on Windows. Do not use a cloud-placeholder directory, network share, FAT/exFAT volume or synchronized folder as the test temporary directory.

Tests create their own temporary subdirectories. If Windows `TEMP`/`TMP` points at an unsuitable filesystem, redirect it to a user-writable NTFS directory before testing. Do not delete or relocate existing user data to do this. Current Windows tests do not require Developer Mode or administrator rights for symlinks; the Unix symlink cases remain excluded there.

Use a clean/default retype configuration for validation. Avoid exporting a custom `RETYPE_CONFIG` for the whole run; fixtures that need an override supply their own. Keep the desktop GUI and any manually registered real directories out of the test setup.

On Windows, destructive cleanup requires fixed local NTFS directories without reparse or placeholder ancestors. Unsupported paths and synchronization failures retain originals and recovery. Native qualification must pass actual disposition/undo on supported storage and independently prove refusal on unsupported paths; do not weaken those assertions to hide either failure.

## 5. Focused safety and Windows process tests

```sh
cargo test -p retype-cli --locked --test data_safety_transactions --test data_safety_audit_additional
cargo test -p retype-core --locked --test safety
cargo test -p retype-cli --locked --lib daemon::watcher::tests
cargo test -p retype-core --locked --lib process_completion
```

On native Windows, also run:

```sh
cargo test -p retype-core --locked --lib execute::windows_tests -- --nocapture
cargo test -p retype-core --locked --lib fsx::windows_tests::directory_flush_probe_is_not_durability_evidence -- --exact --nocapture
cargo test -p retype-core --locked --lib fsx::windows_tests::write_through_handle_rename_probe_is_not_durability_evidence -- --exact --nocapture
cargo test -p retype-core --locked --lib correlate::tests::a_hard_link -- --nocapture
cargo test -p retype-cli --locked --test deferral --test video --no-fail-fast -- --nocapture
```

To diagnose the Unix interrupted-runner PID marker on macOS, run the focused probe after building the tests:

```sh
/usr/bin/perl tests/support/run-bounded.pl 90 5 cargo test -p retype-cli --locked --test data_safety_audit interrupted -- --nocapture </dev/null
```

The `Natural` case records the first PID-marker bytes observed during the ordinary shell write. `HeldOpen` deliberately holds the marker between creation and writing so the parent must observe an empty file. Both cases interrupt the real test worker and verify recovery of its committed output. The controlled case proves the interleaving is possible, not that it occurred in an earlier run. The probe also tests cleanup after losing the control channel; timeouts and invalid marker contents fail rather than being retried as successful tests.

The Windows process tests create controlled descendants, require the process tree to finish before accepting completion, and verify kill-on-close after a timeout. The `process_worker` entry point does nothing in an ordinary parent test run. The real FFmpeg target is a separate check of the installed executable and any wrapper it uses.

The directory-flush probe logs the scratch filesystem name and flags when available, and whether a temporary directory can be opened and synced with read, write and combined access. The handle-rename probe checks exclusive mutation access, collision refusal and identity preservation for a write-through rename of a synthetic file. The Windows runner includes both in its workspace output. These are diagnostics only: a filesystem name or successful call does not prove directory-entry or power-loss durability. See [NTFS durability qualification](windows-durability.md) for the interruption matrix and cleanup scope.

Twenty-five CLI archive/transaction safety tests now run on Windows instead of being excluded with their entire files. Twenty-eight cases in the three CLI safety binaries remain Unix-only: the main shell-based audit, two additional shell/symlink cases, and actual post-disposal crash recovery. Cross-platform ownership tests and Windows-specific process tests provide further coverage, not substitutes for the excluded cases.

## Recovery, sessions and fault checks

`recovery`, `lifecycle` and `session` unit tests use controlled barriers and policy inputs; `terminal` uses real pseudo-terminals for interrupt/EOF/stale-prompt checks. `reconnect` kills disposable daemon processes and verifies the shared crash budget and explicit-stop behavior. Session-query fixtures (`RETYPE_TEST_SESSION`) exist only in debug builds and are set by test runners; they do not establish production login or logout behavior.

The core reservation and undo interruption tests terminate child processes before/during/after backup copying and before/after restoration publication, output cleanup and record removal. `tests/storage-faults.py --binary target/debug/retype --report <directory>` uses a private Linux user/mount namespace and synthetic tmpfs to exhaust restoration space, verify responsive control and retained data, free space and retry exact-byte undo. Run only on a host supporting unprivileged namespaces; the script reports failure rather than claiming evidence if setup is unavailable.

## 6. Interpreting results

Record the Git revision, `rustc -vV`, tool versions, complete output and Cargo exit status. With `--no-fail-fast`, inspect all failed targets rather than only the last summary.

A successful `cargo check --target ...` verifies foreign-target compilation only. It does not execute Windows Job Objects, macOS filesystem/event APIs or native recovery.

Process-crash tests do not simulate power loss or a storage device that fails to honor synchronization. Power-loss, storage-fault, remote-filesystem and cloud-provider validation are separate release work and must use disposable virtual machines or scratch storage, not real originals. For read-only host and guest preparation on Hyper-V, use the [information collector](hyperv.md); it does not perform crash tests or enable Windows cleanup.
