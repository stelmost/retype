# Release packaging

The unsigned CLI alpha is available as manual archives once its draft is published. The signed installed tier includes the CLI and daemon, the notifier, URI registration and a user service. External converter tools are installed separately.

## Asset layout

Every archive is named `retype-<tag>-<target>.tar.gz` and contains `bin/retype` (`retype.exe` on Windows) and these shared assets. Windows release archives also carry `bin/retype-review.exe` for signed per-user URI registration.

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

The signed Linux installer targets Debian 13 (trixie), with glibc 2.41. The older Debian 11/glibc 2.31 target is retired. Builds and converter evidence must be checked in the stable userspace.

The current required targets are defined in [Platforms](../docs/reference/platforms.md#1-support-matrix). Other desktop combinations are best effort, not qualification gates. The first signed handoff publishes only the three required archives; other targets remain previews.

| Scope | Target | CI host and evidence limit |
|---|---|---|
| Required Debian 13 amd64 | `x86_64-unknown-linux-gnu` | Debian trixie container; exact preview archive, scheme registration, CLI URI refusal and online/offline Undo; not a real desktop session |
| Required macOS 15 arm64 | `aarch64-apple-darwin` | `macos-15`; native build, fidelity and unsigned bundle smoke; safe archive/installed qualification still blocked |
| Required Windows 10 22H2 amd64 | `x86_64-pc-windows-msvc` | `windows-2025` compatibility CI; exact unsigned preview CLI/data and owned PATH smoke, not Windows 10 desktop proof |
| Best effort Debian ARM64 | `aarch64-unknown-linux-gnu` | Native Debian userspace and exact preview archive checks |
| Best effort macOS Intel | `x86_64-apple-darwin` | `macos-15-intel`; its own native preview checks |
| Best effort Windows ARM64 | `aarch64-pc-windows-msvc` | `windows-11-arm`; its own native preview archive checks, never cross-rebuilt for publication |

Windows MSVC builds use `-C target-feature=+crt-static`; a compile-time test guard refuses a dynamic CRT. The qualified Windows build/copy/`tar.exe`/hash/restricted-worker pipeline is retained. The release workflow does not rebuild those archives or manufacture additional architectures from another run's evidence.

Manual dispatch assembles `retype-preview-*` artifacts. The `unsigned_alpha` option stages a draft after checks pass. The signed tag workflow verifies and publishes the exact approved assets from a separate draft release in this repository. The tag must match the workspace version and the qualification's source revision.

### Unsigned CLI alpha

Run the `release` workflow on the alpha branch with `unsigned_alpha` enabled. It checks that the workspace has an alpha version, builds and tests that commit, verifies the four required archives, and stages an unpublished GitHub prerelease draft targeting that commit. The draft contains the archives and `SHA256SUMS`. Review the results and publish the draft from GitHub Releases.

| Archive target | Platform |
|---|---|
| `x86_64-unknown-linux-gnu` | Linux x86-64 with glibc 2.41 or newer |
| `x86_64-unknown-linux-musl` | Linux x86-64 with a statically linked CLI |
| `x86_64-pc-windows-msvc` | Windows x86-64 |
| `aarch64-apple-darwin` | macOS 15 on Apple silicon |

Extract the archive, keep `bin/` and `share/` together, and run `bin/retype --version` or `bin/retype.exe --version`. Install any external converters separately. The macOS archive contains an ad-hoc-signed CLI, which the workflow tests after extraction. Windows and macOS may warn about or block a downloaded executable. The source build remains available. The alpha covers the CLI and daemon. Signed desktop installation has its own qualification below.

### Signed candidate handoff

1. Build the three primary archives from the exact tag revision. Verify native signatures on the applicable native hosts. Use fresh staging and independently approved public pins; run `bash scripts/assemble-release.sh --signed <candidate-dir>` to generate both pinned installers and the final checksums. Sign `SHA256SUMS` with `scripts/sign-release.sh` on the approved signing host before qualifying the signed candidate.
2. Run [installed qualification](../docs/dev/testing.md#initial-release-scope) on the exact candidate, including [native notification Review](../docs/dev/testing.md#native-notification-review). Retain each platform's evidence report. After review, create `QUALIFICATION.json` with `tag`, `revision` (full Git commit), `manifest_sha256`, `macos_team_id`, `windows_certificate_sha256`, and `platforms` (an object keyed by the three required target triples). Each platform records its exact `platform` label (`Debian 13 amd64`, `macOS 15 arm64`, or `Windows 10 22H2 amd64`), `report_sha256`, and `checks`: `native_trust`, `recovery`, `uri`, `startup`, `notification`, `session`, and `removal`. Each check must be `passed` on its required platform. Sign the reviewed statement with the approved publisher key as `QUALIFICATION.json.minisig`.
3. Upload only the three archives, both installers, their `.sha256` files, and the signed manifest and qualification pairs to a draft named by the tag `candidate-<release-tag>`. Keep private keys and full qualification reports off the runner and out of release assets. Record the draft release ID and SHA-256 of the reviewed qualification separately in the protected `signed-release` GitHub environment. Require a release reviewer and restrict deployments to protected release tags.
4. Approve the tag workflow, or rerun the tag workflow after staging. The workflow verifies both publisher signatures, the reviewed qualification digest, revision, exact asset hashes and canonical pinned installers before creating the release. It does not claim external builds were built by GitHub Actions. A failed or pre-existing release is not overwritten; investigate it before retrying.

The evidence signature records release approval; it does not independently prove that desktop tests were executed. Missing or unapproved evidence remains a release blocker.

## Script install

`install.sh` is the `curl | bash` installer and updater for Linux and macOS.
`install.ps1` is the PowerShell installer and updater for Windows. Both resolve
the release tag through the GitHub API. Signed mode is the default: authenticate `SHA256SUMS.minisig` with independently approved publisher material before extraction or helper execution, verify the archive digest, then verify native signatures. Missing keys, tools or signatures refuses installation; no preview fallback is inferred. `RETYPE_INSTALL_MODE=preview` selects checksum-only preview explicitly and is not installed-tier evidence.
`install.sh` uses `~/.local` by default; `install.ps1` uses
`%LOCALAPPDATA%\Programs\retype` and adds its `bin` directory to the user
`PATH`. Running either again updates in place.

```sh
bash ./install.sh
bash ./install.sh --version '<supported-release-tag>'
bash ./install.sh --prefix "$HOME/.local"
```

```powershell
& .\install.ps1
$env:RETYPE_VERSION = '<supported-release-tag>'; & .\install.ps1
$env:RETYPE_PREFIX = 'C:\Tools\retype'; & .\install.ps1
```

Source installers contain complete canonical verifier blocks, checked with `python3 scripts/embed-trust.py --check <installer>`. Signed release installers embed only independently approved public pins, before checksums. Use independently trusted pinned installers for signed installation; the product site's unconfigured source copy is not a trust root. No installer downloads its own verifier. On Linux, `install.sh` requires Python 3.12 or newer and `xdg-mime` (`xdg-utils`). It validates archive paths and file types before extraction, then installs `retype-uri.desktop` under `$XDG_DATA_HOME/applications` (default `~/.local/share/applications`) for notification identity and `retype://` dispatch, and `retype.service` under `$XDG_CONFIG_HOME/systemd/user` (default `~/.config/systemd/user`). Both entries use the absolute installation path. New services stay disabled; enablement is unchanged on updates, and an already active owned service drains its conversions before restarting. Linux desktop support is Wayland-only.

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

Removal stops and disables the owned service and drains an unsupervised daemon from the installation in the selected state directory (`RETYPE_STATE_DIR`, otherwise the default). It never spawns a daemon, contacts an unrelated daemon for shutdown, or forces a supervised daemon to exit. A drain timeout leaves the installation in place. Removal restores overwritten desktop/unit definitions and previous URI preferences, and preserves configuration, watches and recovery data. Modified definitions and URI choices made after installation are preserved. Each update/removal keeps a persistent `share/retype-backup.*` directory, including integration rollback records. One prefix owns these per-user definitions; remove it before installing under another prefix. Use the original `XDG_CONFIG_HOME` and `XDG_DATA_HOME` for updates and removal. Windows preview installs the CLI/assets and user PATH token, but no URI, notifier identity, menu shortcut or startup entry. macOS signed installation still requires native signing and an authorized user profile.

## Per platform

| Platform | Files | What installs them |
|---|---|---|
| Linux | `share/retype/packaging/linux/retype.service`, `retype-uri.desktop`, `integrate.py` | `install.sh` installs per-user definitions and registers the URI through `xdg-mime`; the desktop entry also identifies libnotify notifications |
| macOS | `share/retype/macos/retype.app`, `share/retype/macos-installation/environment.plist` | Prebuilt notifier/URL shim with the exact CLI under `Contents/Resources/retype`; per-user app registration and explicit opt-in launchd |
| Windows | `share/retype/packaging/windows/retype.manifest`, `share/retype/packaging/windows/retype.rc` | The executable's manifest resource and the Start-menu shortcut |

The launchd plist, Linux desktop entry and systemd unit name the install prefix as `@PREFIX@`; the installer substitutes and escapes it for the destination format.

Signing is mandatory for installed-tier publication and execution. All platforms require the final publisher-signed manifest. Windows additionally requires Authenticode with an independently pinned publisher certificate and a secure timestamp. macOS requires Developer ID, hardened runtime and notarisation. Both app and CLI use `st.elmo.retype.cli`. Sign fresh staging outputs, copy the final signed inner CLI to `bin/retype`, and require byte equality. Qualify extraction and metadata/staple preservation on the exact macOS archive.

Required public inputs for the protected environment and native preparation:

| Input | Meaning |
|---|---|
| `RETYPE_PUBLISHER_KEY` | Independently approved minisign public key value |
| `RETYPE_MACOS_TEAM_ID`, `RETYPE_PUBLISHER_CERTIFICATE_SHA256` | Independently approved Apple Team ID and Authenticode certificate pin |
| `RETYPE_CANDIDATE_RELEASE_ID`, `RETYPE_CANDIDATE_QUALIFICATION_SHA256` | Approved draft release ID and SHA-256 of the exact reviewed qualification statement |
| macOS Team ID, existing signing identity, existing notary profile | Explicit approved selectors for `scripts/sign-macos.sh`; fixed app/CLI IDs, no new keychain identities |
| Windows `SignTool`, `CertificateThumbprint`, `PublisherCertificateSha256`, `TimestampUrl` | Explicit inputs for `scripts/sign-windows.ps1`; existing CurrentUser/My SHA1 selector, independent SHA256 pin, HTTPS RFC3161 endpoint |

`bash scripts/sign-release.sh <final-dir> <approved-existing-key-path> <approved-public-key>` creates the signature exclusively after all final assets exist. `bash packaging/trust/verify.sh <asset> <SHA256SUMS> <SHA256SUMS.minisig> <approved-public-key>` verifies it. Test doubles, placeholder keys, checksum-only previews and GitHub attestations cannot satisfy these gates. No actual publisher material, signing authorization or native-profile approval is assumed.

## Rename or move

The daemon is local and per user. There is no system service and no privileged
helper. The launchd agent and systemd unit run in the user session, not as root.
