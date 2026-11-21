# Retype

Rename the extension, the file converts.

Status: pre-alpha. The manual marks which behaviour has landed.

## What it will be

A file watcher and a command line tool that convert a file when you rename its
extension. `photo.heic` becomes `photo.jpg`, and the bytes follow the name.
Transformations ride on the same gesture: `photo.heic` becomes `photo.webp+q80`.

- Initial release: Debian 13 amd64, macOS 15 arm64, Windows 10 22H2 amd64
- Local only: no upload, no account, no telemetry
- Scriptable, with the same intent string accepted by the filename, the command
  line and the editor

Other desktop OS and architecture combinations are best effort, not qualification gates. Physical-hardware power, sleep/wake and device checks are deferred. This release covers the CLI and daemon, not the GUI or managed converter toolchain.

## Documentation

[`docs/`](docs/README.md) is the user manual: the intent grammar, operations, configuration, command line, and what each conversion preserves. [`docs/dev/`](docs/dev/README.md) holds the internal contracts, filesystem measurements, and the commands for building and testing.

## Installation tiers

Two tiers exist, and the difference is deliberate. Pre-release installers are a
convenience on top of the source tier, not a third tier.

- **Installed**: platform installer, signed. Command line, daemon, notifier,
  URI scheme, user service. External tools are acquired separately. Supported
- **Source**: `cargo install --git https://github.com/LapilliWorks/retype retype-cli`. The
  binary includes the daemon, but no service, URI registration or notifier
  bundle is installed. A workaround, not the supported path

Installer entrypoints do not require a Rust toolchain. Signed mode is the default and fails closed without approved publisher material; the first signed/native release is not yet qualified. Manual build artifacts are explicit previews, not signed installed delivery.

Linux and macOS:

```sh
curl -fsSL https://retype.name/install.sh | bash
```

Windows, in PowerShell:

```powershell
irm https://retype.name/install.ps1 | iex
```

The signed route authenticates the publisher manifest and native signatures before extraction or helper execution. Preview must be selected explicitly with `RETYPE_INSTALL_MODE=preview`; checksums and build attestations are not publisher trust. Windows preview installs the CLI/assets and adds its owned `bin` token to user `PATH`, but does not install URI/notifier/startup integration. Linux keeps its desktop/URI definition and disabled user-service unit, with Python 3 and `xdg-mime` required and Wayland-only desktop support. Unix `--uninstall` and Windows `-Uninstall` preserve configuration and recovery data. macOS bundle/extraction/native-user qualification and all signed release inputs remain blocked; see [release packaging](packaging/README.md).

Updates validate the staged binary before publication, retain the previous installation in a `share/retype-backup.*` or `share/retype-backup-*` directory under the prefix, and restore it on installation failure. The scripts print the backup path; old backups are not automatically pruned.

Tool acquisition follows the interface. The CLI does not install or manage tools: a
CLI user uses the platform's package manager or installs them by hand. The GUI manages
the signed toolchain for users who should not need to know what a package manager is.

## Tests

See the [native test harness](tests/README.md) for preparation, `./tests/run.sh` on Linux/macOS, the Windows runner, and report locations. The strict runner requires real tools; ordinary `cargo test --workspace` is a contributor baseline, not release evidence.

## Licence

ISC. See `LICENSE`. The graphical application is a separate, proprietary
product and lives in its own repository.
