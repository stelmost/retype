# Windows per-user delivery

The first-release qualification target is Windows 10 22H2 AMD64. Other Windows combinations are best effort for this release. Hosted Windows Server checks do not establish the Windows 10 desktop/session gate.

## Install and update

Run `packaging/install.ps1` from a native, non-elevated PowerShell session. The default prefix is `%LOCALAPPDATA%\Programs\retype`; `RETYPE_PREFIX` selects another fixed local NTFS prefix. Reparse paths, network paths, drive roots and command/PATH-delimited prefixes are refused.

Signed delivery is the default. It requires an independently trusted installer, `minisign`, an independently approved `RETYPE_PUBLIC_KEY` and `RETYPE_PUBLISHER_CERTIFICATE_SHA256`, and these release artifacts:

- `SHA256SUMS` and its detached `SHA256SUMS.minisig` signature
- The exact native archive named by that authenticated manifest
- Valid, approved-leaf-certificate-pinned, timestamped Authenticode on the CLI and the executed Windows shortcut helper

The embedded verifiers authenticate the manifest/archive before extraction and validate extracted code before execution. They do not import certificates, change stores, sign files, install tools or infer a preview fallback. An unverified script piped into `iex` is not an independently authenticated bootstrap; verify the installer/source before executing signed delivery.

Signed installation creates only per-user integration:

- `HKCU\Software\Classes\retype`: A direct executable command ending in `uri -- "%1"`, never a shell command
- `HKCU\Software\Classes\AppUserModelId\com.lapilliworks.retype.cli`: The existing plain-toast identity and display name
- The user's `Programs\retype.lnk`: A native shell link with `System.AppUserModel.ID = com.lapilliworks.retype.cli`, targeting existing `daemon start`
- The install `bin` directory in the user PATH, unless already present

The URI handler retains the existing CLI undo/cancel/resolve contract. Notifications remain plain toasts; action buttons and a GUI are not required. The installer neither launches the daemon nor installs converters.

### Startup

A fresh install leaves startup disabled. Updates preserve the previous opt-in by default. `RETYPE_STARTUP=enable` adds only `com.lapilliworks.retype.cli` in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, invoking the exact installed CLI's existing `daemon start`. `RETYPE_STARTUP=disable` removes only that owned value. Both changes apply at the next sign-in, not immediately. Other startup entries are retained.

An explicitly selected `RETYPE_STATE_DIR` or `RETYPE_CONFIG` is pinned into the shortcut/URI/startup arguments and preserved on update unless explicitly changed. A selected integration configuration must exist. Paths that overlap incoming installed files are refused rather than replaced with defaults or overwritten.

### Preview

`RETYPE_INSTALL_MODE=preview` explicitly selects the old CLI-only convenience route. It verifies a unique archive checksum, installs the CLI/shared assets and preserves user PATH command discovery. It does not install URI, notification identity, shortcut or startup integration, and it does not establish publisher trust. A live signed installation cannot be silently downgraded to preview in place.

## Ownership, backups and removal

Updates replace files individually on the destination filesystem. Unowned or modified destination files and foreign/changed integration definitions are refused. Unknown files and custom state beneath `share` are not moved as a directory or purged. A per-user filesystem lock serializes installer changes, and preflight snapshots are rechecked after download.

Every update/removal retains a unique `share\retype-backup-<id>` directory containing prior executable bytes, prior touched shared files, the prior receipt, the owned shortcut and the integration snapshot when present. Rollback uses these verified copies and refuses unexpected file replacements. A failure or interrupted attempt does not authorize cleanup of recovery data; inspect the retained backup before retrying or manually repairing installation files.

Set `RETYPE_ACTION=remove` with the same prefix and run the trusted installer. Removal does not download or execute an installed helper. It validates fixed ownership contracts, moves only unchanged `bin\retype.exe` to backup, removes the owned URI/shortcut/startup integration, restores only the known pre-existing plain toast identity when applicable, and removes only an installer-added `bin` PATH token. A mutable receipt never supplies an arbitrary deletion path or registry tree.

Removal deliberately retains these in place:

- Shared release assets and all unknown files
- Configuration, watch registrations, journal, undo originals and recovery data
- All prior installation/integration backups
- A retired `.retype-install.json`, allowing a later verified reinstall without adopting unrelated files
- The installer lock file under the user's local application data

This is safe application removal, not complete disk cleanup. A legacy installation without an ownership receipt is not adopted automatically; preserve it and use a new prefix. Another prefix owning the same per-user integration must be removed explicitly before replacement.

## Qualification fixture

Run on native Windows with a verified ordinary-user token and an exact native CLI:

```powershell
.\tests\install.ps1 -Binary 'C:\owned\retype.exe' -Report 'C:\owned\new-installer-report'
```

The fixture records revision/status, exact source snapshots, executable hash, OS/architecture/token scope, checks, failures and persistent backups. It uses mocked publisher verification and mocked OS-recognized URI/AppID/Run/PATH operations, a private filesystem/shortcut, and only a fresh `HKCU\Software\retype-installer-tests\<id>` key for native registry round-trip checks. That child key is snapshotted before removal; files, source snapshots and failed attempts remain in the report. It does not register a real URI, create a real Start-menu shortcut, start a daemon or alter the user's real PATH/startup definitions.

Synthetic checks do not prove Authenticode/minisign publisher positives, actual OS URI activation, banner/Focus Assist, authenticated unlock, sign-out/sign-in or normal-reboot persistence. Those require independent signing inputs and named-action approval on the supported native profile. Missing tools, skipped checks or an unsigned preview cannot turn those gates into a release pass.
