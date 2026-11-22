# Release packaging

The source build in `README.md` is a workaround. A release is the installed tier:
the CLI and daemon, the notifier, URI registration and a user service, with no
external tool binaries. Manual workflow dispatch produces non-publishing preview artifacts. Tagged publication is signed-only and refuses missing signed/qualified archives, installer closure or publisher inputs. Preview success is not an installed-tier pass; native qualification and core safety blockers still prevent release approval.

## Asset layout

Every archive is named `retype-<tag>-<target>.tar.gz` and contains `bin/retype`
(`retype.exe` on Windows) and these shared assets:

```
share/retype/fidelity.toml
share/retype/fixtures/fidelity/
share/retype/packaging/
```

`retype why` and `retype fidelity` look in `<prefix>/share/retype`; a packaged
build therefore reads the shipped claims rather than a source tree. The native verification workflow earns `png:jpg` and `png:webp` claims with real tools and property fixtures, and retains `fidelity.toml` and its log in the platform report. Every selected pair must succeed. Archive builds wait for that gate and require the downloaded evidence manifest; a missing manifest fails assembly.

The manifest names the tested backend and engine builds. Each checked archive carries evidence from its own native release executable and tool builds, not another architecture's run. The installed check requires the executable and `fidelity.toml` to match their exact archive members and each selected claim to match the appropriate packaged record. Matching backend/engine versions and fingerprints require `earned`; changed builds require `unverified`. Supported conversion and exact undo remain checked in either case. Conditional tool evidence does not qualify an OS floor or a signed installed desktop.

To earn additional local claims:

```
retype fidelity --pair png:jpg --pair png:webp --write fidelity.toml
```

Debian qualification runs independently of Windows/macOS failures. Publication requires every primary target's signed/native qualification; a fidelity manifest, preview CLI smoke or hosted Server result does not bypass it.

## Release pipeline

Current Debian stable is the Linux support baseline, currently Debian 13 (trixie), with glibc 2.41. The older Debian 11/glibc 2.31 target is retired. Other distributions may run the binary but do not carry a support commitment. Builds and converter evidence must be checked in the stable userspace.

The current required targets are defined in [Platforms](../docs/reference/platforms.md#1-support-matrix). Other desktop combinations are best effort, not qualification gates. Optional artifacts may be published only after their own successful tests and trust verification.

| Scope | Target | CI host and evidence limit |
|---|---|---|
| Required Debian 13 amd64 | `x86_64-unknown-linux-gnu` | Debian trixie container; exact preview archive, scheme registration, CLI URI refusal and online/offline Undo; not a real desktop session |
| Required macOS 15 arm64 | `aarch64-apple-darwin` | `macos-15`; native build, fidelity and unsigned bundle smoke; safe archive/installed qualification still blocked |
| Required Windows 10 22H2 amd64 | `x86_64-pc-windows-msvc` | `windows-2025` compatibility CI; exact unsigned preview CLI/data and owned PATH smoke, not Windows 10 desktop proof |
| Best effort Debian ARM64 | `aarch64-unknown-linux-gnu` | Native Debian userspace and exact preview archive checks |
| Best effort macOS Intel | `x86_64-apple-darwin` | `macos-15-intel`; its own native preview checks |
| Best effort Windows ARM64 | `aarch64-pc-windows-msvc` | `windows-11-arm`; its own native preview archive checks, never cross-rebuilt for publication |

Windows MSVC builds use `-C target-feature=+crt-static`; a compile-time test guard refuses a dynamic CRT. The qualified Windows build/copy/`tar.exe`/hash/restricted-worker pipeline is retained. The release workflow does not rebuild those archives or manufacture additional architectures from another run's evidence.

Manual dispatch consumes only `retype-preview-*` artifacts and cannot publish. Tags consume only `retype-signed-*` artifacts and require all three primary archives; current preview producers cannot satisfy that gate. Canonical installer closure is generated before checksums. The final `SHA256SUMS` is signed last as `SHA256SUMS.minisig`, then every final archive and installer is reverified from trusted source. The tag must match the workspace version. Missing signed/native producers or inputs fails closed, not to preview.

The signed asset set is archives, per-archive `.sha256` files, both standalone installers and their checksums, `SHA256SUMS`, `SHA256SUMS.minisig`, and GitHub build attestations. Attestations describe build provenance; they are not publisher signatures. Native Windows 10 22H2 and real desktop/session qualification, including [native notification Review](../docs/dev/testing.md#native-notification-review), remain separate release-approval gates.

## Script install

`install.sh` is the `curl | bash` installer and updater for Linux and macOS.
`install.ps1` is the PowerShell installer and updater for Windows. Both resolve
the release tag through the GitHub API. Signed mode is the default: authenticate `SHA256SUMS.minisig` with independently approved publisher material before extraction or helper execution, verify the archive digest, then verify native signatures. Missing keys, tools or signatures refuses installation; no preview fallback is inferred. `RETYPE_INSTALL_MODE=preview` selects checksum-only preview explicitly and is not installed-tier evidence.
`install.sh` uses `~/.local` by default; `install.ps1` uses
`%LOCALAPPDATA%\Programs\retype` and adds its `bin` directory to the user
`PATH`. Running either again updates in place.

```sh
curl -fsSL https://retype.name/install.sh | bash
curl -fsSL https://retype.name/install.sh | bash -s -- --version v0.1.0-alpha
curl -fsSL https://retype.name/install.sh | bash -s -- --prefix "$HOME/.local"
```

```powershell
irm https://retype.name/install.ps1 | iex
$env:RETYPE_VERSION = 'v0.1.0-alpha'; irm https://retype.name/install.ps1 | iex
$env:RETYPE_PREFIX = 'C:\Tools\retype'; irm https://retype.name/install.ps1 | iex
```

Source installers contain complete canonical verifier blocks, checked with `python3 scripts/embed-trust.py --check <installer>`. Release assets are generated exclusively with `python3 scripts/embed-trust.py <source-installer> <new-output>` before checksums; generation never supplies publisher pins. The product site copies those canonical source installers, with no downloaded verifier bootstrap. On Linux, `install.sh` requires Python 3 and `xdg-mime` (`xdg-utils`). It installs `retype-uri.desktop` under `$XDG_DATA_HOME/applications` (default `~/.local/share/applications`) for notification identity and `retype://` dispatch, and `retype.service` under `$XDG_CONFIG_HOME/systemd/user` (default `~/.config/systemd/user`). Both entries use the absolute installation path. New services stay disabled; enablement is unchanged on updates, and an already active service drains its conversions before restarting. Without a running user manager for that configuration directory, the unit is available on the next user-manager start. Linux desktop support is Wayland-only.

Start the installed service explicitly when automatic watching should persist across logins:

```sh
systemctl --user enable --now retype.service
```

Without lingering or another session for that user, systemd stops the user manager and daemon after the last logout. The enabled unit starts again at the next login and reloads its watch registrations. This is not uninterrupted daemon execution: waiting jobs from the stopped daemon are reported as `E_JOB_INTERRUPTED`, not automatically replayed. Service enablement does not enable lingering or change this recovery policy.

Linux removal uses the same installer without contacting the release server:

```sh
curl -fsSL https://retype.name/install.sh | bash -s -- --uninstall
# Or run the installed copy while offline:
bash "$HOME/.local/share/retype/packaging/install.sh" --uninstall
# Include --prefix if the installation used a custom prefix.
```

Removal stops and disables the owned service, removes installed files, restores overwritten desktop/unit definitions and previous URI preferences, and preserves configuration, watches and recovery data. Modified definitions and URI choices made after installation are preserved. Each update/removal keeps a persistent `share/retype-backup.*` directory, including integration rollback records. Other MIME preferences are preserved. One prefix owns these per-user definitions; remove it before installing under another prefix. Use the original `XDG_CONFIG_HOME` and `XDG_DATA_HOME` for updates and removal. Windows preview installs the CLI/assets and user PATH token, but no URI, notifier identity, menu shortcut or startup entry. Removal removes only the installer-added PATH token. macOS app/native installation remains gated on safe extraction, native signing and an authorized user profile.

## Per platform

| Platform | Files | What installs them |
|---|---|---|
| Linux | `share/retype/packaging/linux/retype.service`, `retype-uri.desktop`, `integrate.py` | `install.sh` installs per-user definitions and registers the URI through `xdg-mime`; the desktop entry also identifies libnotify notifications |
| macOS | `share/retype/macos/retype.app`, `share/retype/macos-installation/environment.plist` | Prebuilt notifier/URL shim with the exact CLI under `Contents/Resources/retype`; per-user app registration and explicit opt-in launchd |
| Windows | `share/retype/packaging/windows/retype.manifest`, `share/retype/packaging/windows/retype.rc` | The executable's manifest resource and the Start-menu shortcut |

The launchd plist, Linux desktop entry and systemd unit name the install prefix as `@PREFIX@`; the installer substitutes and escapes it for the destination format.

Signing is mandatory for tagged publication and installed-tier execution. All platforms require the final publisher-signed manifest. Windows additionally requires Authenticode with an independently pinned publisher certificate and a secure timestamp. macOS requires Developer ID, hardened runtime and notarisation; both app and CLI use `com.lapilliworks.retype.cli`. Sign fresh staging outputs, copy the final signed inner CLI to `bin/retype`, and require byte equality. Native macOS extraction, metadata/staple preservation and installed qualification remain blocked; no USTAR/no-xattrs restriction is adopted to hide those gaps.

Required input names are documented here, not configured or populated by CI:

| Input | Meaning |
|---|---|
| `RETYPE_PUBLISHER_KEY` | Independently approved minisign public key value |
| `RETYPE_SIGNING_KEY_FILE` | Existing approved private-key path for final manifest signing |
| macOS Team ID, existing signing identity, existing notary profile | Explicit approved selectors for `scripts/sign-macos.sh`; fixed app/CLI IDs, no new keychain identities |
| Windows `SignTool`, `CertificateThumbprint`, `PublisherCertificateSha256`, `TimestampUrl` | Explicit inputs for `scripts/sign-windows.ps1`; existing CurrentUser/My SHA1 selector, independent SHA256 pin, HTTPS RFC3161 endpoint |

`bash scripts/sign-release.sh <final-dir> <approved-existing-key-path> <approved-public-key>` creates the signature exclusively after all final assets exist. `bash packaging/trust/verify.sh <asset> <SHA256SUMS> <SHA256SUMS.minisig> <approved-public-key>` verifies it. Test doubles, placeholder keys, checksum-only previews and GitHub attestations cannot satisfy these gates. No actual publisher material, signing authorization or native-profile approval is assumed.

## Rename or move

The daemon is local and per user. There is no system service and no privileged
helper. The launchd agent and systemd unit run in the user session, not as root.
