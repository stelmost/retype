# Platforms

Supported targets, delivery tiers and their consequences.

## 1. Support matrix

| Platform | Supported OS for the initial release | Required architecture | Other combinations |
|---|---|---|---|
| Linux | Debian 13 (trixie), glibc 2.41 | amd64 (x86_64) | Best effort |
| macOS | macOS 15 | arm64 (aarch64) | Best effort |
| Windows | Windows 10 22H2 | amd64 (x86_64) | Best effort |
| BSD, WSL 2 | No support commitment | None | Best effort |
| Android, iOS | Out of scope | None | Out of scope |

This is the current initial-release scope, not a permanent platform policy. Other desktop OS versions and architectures are not mandatory qualification gates. Physical-hardware power-loss, sleep/wake and device qualification is [deferred](../dev/testing.md#initial-release-scope). The GUI and managed converter toolchain are not part of this release.

Required qualification uses the exact release candidate on each supported OS and architecture. Hosted Windows Server compatibility CI does not establish Windows 10 22H2 or interactive desktop behavior. Native Windows 10 22H2 qualification remains required before release approval. Container and controlled-session results do not establish real desktop login or notification behavior.

Earlier [Debian qualification run 44814840504](https://github.com/lapilliworks/retype/actions/runs/44814840504) passed native userspace, interruption, architecture-specific fidelity and installed-archive checks on amd64 and ARM64 for its recorded revision. That evidence does not qualify a changed release candidate or promote ARM64 from best effort.

- Linux desktop support is Wayland-only; X11 is unsupported
- Linux builds and qualification use Debian 13 stable userspace; the older Debian 11/glibc 2.31 floor is retired
- Other desktop combinations may work, but carry no initial-release support commitment

## 2. Toolchain

| Item | Value |
|---|---|
| MSRV | Rust 1.88 |
| Pinned toolchain in CI | The stable channel at build time, plus one job on the MSRV |
| Edition | 2024 |

## 3. Filesystems

| Filesystem | Identity | Attributes | Notes |
|---|---|---|---|
| ext4, xfs, btrfs | device and inode | `user.*` | btrfs subvolumes report distinct device ids |
| APFS, HFS+ | device and inode | `com.*` | |
| NTFS | volume serial and file id | stream, pending decision | Cleanup requires checked fixed-local NTFS directories without reparse or placeholder ancestors |
| ReFS | volume serial and file id | stream, pending decision | Destructive cleanup unsupported |
| exFAT, FAT32 | volume serial and file id | none | Identity works on Windows; attributes are lost |
| Network shares | unreliable | unreliable | See `docs/reference/watch.md` §9 |

Nothing in the product requires an attribute or a stream. Identity is the mechanism of record, and it works on every filesystem in the table that reports a stable identifier. Identity support does not establish directory durability: Windows source disposal and destructive undo qualify each recovery, source and output directory, and retain files on unsupported paths or synchronization failure. See [NTFS durability qualification](../dev/windows-durability.md) for the evidence boundary.

## 4. Path handling

| Item | Rule |
|---|---|
| Length | Long path awareness is enabled in the Windows manifest, and paths are passed with the `\\?\` prefix where the API requires it |
| Encoding | Paths are handled in the platform's native form; no lossy conversion outside diagnostics |
| Case sensitivity | Detected by probing at startup, not assumed per platform. Extension comparison is case-insensitive regardless |
| Unicode normalisation | Not performed. macOS reports NFD, and the product compares bytes rather than normalising |
| Reserved names | Windows device names are rejected as output names rather than producing an unusable file |

## 5. Delivery tiers

Two delivery tiers are defined. Explicit previews sit outside the signed installed tier; signed/native release approval remains blocked until all required inputs and gates are complete.

| Tier | How | Contains | Supported |
|---|---|---|---|
| Source | `cargo install --git`, or a Homebrew source formula | The CLI binary only | As a workaround, for people who build their own |
| Installed | Platform installer, signed | CLI, daemon, notifier bundle, URI scheme registration, opt-in startup. No external tool binaries | Supported matrix, after signed/native release approval |

`cargo install` is **CLI only and a workaround**. The binary can run the daemon in the foreground and `retype watch` registrations persist, but it cannot install a user service, register a URI scheme on macOS, or create a Start-menu shortcut on Windows. The documentation states this rather than implying feature parity.

Installer entrypoints are signed by default and refuse missing trust inputs. Preview must be selected explicitly with `RETYPE_INSTALL_MODE=preview`; it never satisfies signed publication or native installed qualification.

Linux and macOS:

```sh
curl -fsSL https://retype.name/install.sh | bash
```

Windows, in PowerShell:

```powershell
irm https://retype.name/install.ps1 | iex
```

Signed mode authenticates the final publisher manifest before extraction or helper execution and verifies native signatures independently. Preview checksums detect corruption, not publisher identity. Windows preview installs the CLI/assets and adds its owned `bin` token to user `PATH`, without URI/notifier/startup integration. Linux retains its notification/URI desktop entry and disabled systemd user unit, requires Python 3 and `xdg-mime`, and preserves service enablement and user edits on update. Unix `--uninstall` and Windows `RETYPE_ACTION=remove` preserve configuration, watches and recovery data. macOS native bundle, safe extraction, metadata/staple preservation and real-user integration remain unqualified; no private or ephemeral HOME is accepted as desktop proof.

What the installed-tier installer does, per platform:

| Platform | Actions |
|---|---|
| Linux | Binary, notifier desktop entry, `retype://` via `xdg-mime`, systemd user unit (not enabled) |
| macOS | Prebuilt app with the exact signed CLI and notifier/URL shim, scheme registration, launchd only with explicit `--enable-startup` |
| Windows | Binary, Start-menu shortcut carrying the AppUserModelID, registry entries for `retype://`, optional startup entry |

None of these actions is performed implicitly by running the binary.

### 5.1 Tool acquisition

External tools are not part of the installer. The GUI and its managed converter toolchain are outside this initial release. Acquisition differs by interface: the CLI does not manage tools, while the separate GUI contract does.

A CLI user installs tools with the platform's package manager or by hand, then leaves them on `PATH` or pins an absolute path in configuration. A source build has no other route. The GUI manages a signed set for users who may not know what the tools are, may not know what a package manager is, or may not want to bother.

| Platform | CLI | GUI |
|---|---|---|
| Linux | Distribution packages, then `PATH` | Managed set when the user asks for it |
| macOS | Homebrew or the system, then `PATH` | Managed set as a fallback when neither has the tool |
| Windows | A manual install, then `PATH` | Managed set offered during setup or first use, with an explicit prompt |

The managed set is a per-user directory described by a signed distribution list, `docs/advanced/converters.md` §2. The CLI and daemon resolve it before `PATH` when the GUI has installed it, but never install, update or verify it. An offline pack is the same artifacts and manifest on disk, for machines with no network or a controlled one. No conversion downloads anything; acquisition is an explicit GUI action or an installer prompt.

A system tool is supported but not pinned. Its version and build fingerprint are recorded, and a fidelity claim that was earned against a different build is reported as `unverified`, `docs/advanced/fidelity.md`.

## 6. Signing

| Platform | Requirement | When |
|---|---|---|
| macOS | Developer ID, hardened runtime and notarisation | Before signed installed publication |
| Windows | Authenticode, independently pinned publisher certificate and secure timestamp; existing stable certificate is the provisional signing selector | Before signed installed publication |
| Linux | Publisher-signed `SHA256SUMS.minisig` and checksums | Before signed installed publication |
| Toolchain, Windows | Authenticode with a secure timestamp on every artifact | With the first managed artifact |
| Toolchain, macOS | Developer ID, hardened runtime, and a notarised archive containing the signed Mach-O files | With the first managed artifact |
| Toolchain, Linux | Detached minisign or Sigstore signature, beside the checksum | With the first managed artifact |

Publisher identity is fixed: Lapilli Works LLC. The GUI is `com.lapilliworks.retype`, the CLI is `com.lapilliworks.retype.cli`, and a standalone notifier is `com.lapilliworks.retype.notifier`. The display name is `retype`. Reputation is bound to the publisher identity, so it is never changed casually.

Signed archives and their standalone installers require the final publisher-signed `SHA256SUMS.minisig`. Canonical verifier blocks are embedded from trusted source before checksums. Publisher keys, native certificate/Team pins and existing signing selectors must be independently approved. Both macOS app and CLI use the fixed `com.lapilliworks.retype.cli` identifier. The [unsigned CLI alpha](../../packaging/README.md#unsigned-cli-alpha) is a manual download with SHA-256 checksums. The macOS alpha executable has an ad-hoc signature. Installed-tier qualification requires publisher trust.

The distribution manifest has its own Ed25519 key, kept offline and separate from the platform code-signing certificate. Its public key is embedded in the GUI that manages the set. Rotation dual-signs one release, so an old client accepts the new key before it is the only key.

## 7. Notifications and scheme registration

Capability per platform:

| Platform | Review | Integration |
|---|---|---|
| Linux | Batch Review with notification actions and Zenity | Daemon and per-user desktop entry |
| Windows | One job per Review action on a supported toast from the signed installation | Per-user AppUserModelID and protocol handler |
| macOS | One job per Review action in User Notifications from the signed installation | Notifier app and LaunchServices registration |

Windows and macOS native Review use one `retype://job/<full-job-id>` link per actionable notification. The full ID selects the job; it does not authorize anything. The installed handler may request a native dialog, never consent or daemon startup. When actions are unavailable, notifications are plain if the session can show them, otherwise the daemon logs the result. See [Saying what happened](watch.md#11-saying-what-happened).

## 8. Out of scope

| Target | Why |
|---|---|
| Android, iOS | No rename surface to hang the product on |
| GUI and managed converter toolchain | Not part of this CLI and daemon release |
| Network filesystems | Not supported yet; see [Watch scope](watch.md) §9 |
| Fonts, 3D, CAD formats | Not formats this product converts |
