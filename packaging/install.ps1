# Install, update or remove retype for the current, non-elevated Windows user.
#   irm https://retype.name/install.ps1 | iex
#
# Environment:
#   RETYPE_VERSION       Release tag, or latest (default)
#   RETYPE_PREFIX        Default: $env:LOCALAPPDATA\Programs\retype
#   RETYPE_REPO          Default: stelmost/retype
#   RETYPE_RELEASE_BASE  Release download base, for a mirror
#   RETYPE_TARGET        Native x86_64-pc-windows-msvc or aarch64-pc-windows-msvc
#   RETYPE_ACTION        install (default) or remove; removal never downloads or purges user data
#   RETYPE_INSTALL_MODE  signed (default) or explicitly preview
#   RETYPE_STARTUP       preserve (default), enable or disable; applies at the next sign-in
#   RETYPE_PUBLIC_KEY    Independently approved minisign publisher public key
#   RETYPE_PUBLISHER_CERTIFICATE_SHA256  Independently approved Authenticode leaf-certificate SHA256
#
# Preview checksums are corruption checks, not publisher trust. No external tools are installed.
& {
	Set-StrictMode -Version Latest
	$ErrorActionPreference = 'Stop'
	$ProgressPreference = 'SilentlyContinue'
	$publisherKey = ''
	$publisherCertificateSha256 = ''
	if (-not $publisherKey) { $publisherKey = $env:RETYPE_PUBLIC_KEY }
	if (-not $publisherCertificateSha256) { $publisherCertificateSha256 = $env:RETYPE_PUBLISHER_CERTIFICATE_SHA256 }

# BEGIN RETYPE_RELEASE_TRUST
function Assert-RetypeReleaseTrust {
	param([string]$Archive, [string]$Checksums, [string]$Signature, [string]$PublicKey)
	$ErrorActionPreference = 'Stop'
	if ($PublicKey -cnotmatch '\A[A-Za-z0-9+/]{56}\z') {
		throw 'retype trust: missing or malformed pinned minisign public key'
	}
	$files = @($Archive, $Checksums, $Signature)
	foreach ($file in $files) {
		if (-not $file) { throw 'retype trust: missing archive, manifest or signature path' }
		$item = Get-Item -LiteralPath $file -ErrorAction Stop
		if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
			throw "retype trust: not a regular non-reparse file: $file"
		}
	}
	foreach ($file in @($Checksums, $Signature)) {
		$size = (Get-Item -LiteralPath $file).Length
		if ($size -le 0 -or $size -gt 1048576) { throw 'retype trust: empty or oversized trust file' }
	}
	$tool = Get-Command minisign -CommandType Application -ErrorAction SilentlyContinue
	if (-not $tool) { throw 'retype trust: signed installation requires an independently trusted minisign' }
	& $tool.Source -V -P $PublicKey -m $Checksums -x $Signature
	if ($LASTEXITCODE -ne 0) { throw 'retype trust: publisher manifest signature rejected' }
	$manifest = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes(
		$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Checksums)))
	$lines = $manifest.Split([char]10)
	$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
	$wanted = [IO.Path]::GetFileName($Archive)
	$expected = $null
	for ($index = 0; $index -lt $lines.Length; $index++) {
		$line = $lines[$index]
		if ($index -eq $lines.Length - 1 -and $line -eq '') { continue }
		if ($line.EndsWith("`r")) { $line = $line.Substring(0, $line.Length - 1) }
		if ($line -cnotmatch '\A([0-9a-f]{64}) [ *]([A-Za-z0-9][A-Za-z0-9._+-]*)\z') {
			throw 'retype trust: malformed publisher manifest'
		}
		$digest = $Matches[1]
		$asset = $Matches[2]
		if (-not $seen.Add($asset)) { throw 'retype trust: duplicate publisher manifest asset' }
		if ([string]::Equals($asset, $wanted, [StringComparison]::Ordinal)) { $expected = $digest }
	}
	if (-not $expected) { throw 'retype trust: missing exact archive entry in publisher manifest' }
	$actual = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
	if ($actual -cne $expected) { throw 'retype trust: archive does not match publisher manifest' }
}
# END RETYPE_RELEASE_TRUST
# BEGIN RETYPE_WINDOWS_TRUST
function Assert-RetypeWindowsTrust {
	param([string]$Path, [string]$PublisherCertificateSha256)
	$ErrorActionPreference = 'Stop'
	if ($PublisherCertificateSha256 -notmatch '\A[0-9A-Fa-f]{64}\z') {
		throw 'retype trust: missing or malformed approved publisher certificate SHA256'
	}
	if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
		throw 'retype trust: native Windows Authenticode verification is required'
	}
	if (-not $Path) { throw 'retype trust: missing Authenticode artifact path' }
	$item = Get-Item -LiteralPath $Path -ErrorAction Stop
	if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
		throw 'retype trust: Authenticode artifact must be a regular non-reparse file'
	}
	$signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
	if ($signature.Status.ToString() -cne 'Valid' -or $signature.SignatureType.ToString() -cne 'Authenticode') {
		throw 'retype trust: embedded Authenticode signature rejected by Windows'
	}
	if (-not $signature.SignerCertificate -or -not $signature.TimeStamperCertificate) {
		throw 'retype trust: publisher certificate and timestamp are required'
	}
	$sha256 = [Security.Cryptography.SHA256]::Create()
	try {
		$pin = [BitConverter]::ToString($sha256.ComputeHash($signature.SignerCertificate.RawData)).Replace('-', '')
	} finally {
		$sha256.Dispose()
	}
	if ($pin -cne $PublisherCertificateSha256.ToUpperInvariant()) {
		throw 'retype trust: Authenticode publisher certificate does not match the approved pin'
	}
}
# END RETYPE_WINDOWS_TRUST

	function Assert-RetypeHost {
		if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
			throw 'This installer is for native Windows. Use install.sh on Linux or macOS.'
		}
		$principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
		if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
			throw 'Run this per-user installer from a non-elevated PowerShell session.'
		}
	}

	function Assert-RetypePath([string]$Path) {
		if ($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '["%;\x00-\x1f]' -or $Path.Substring(2).Contains(':')) {
			throw "Unsupported installation path: $Path. Use a fixed local NTFS path without command/PATH delimiters."
		}
		if (@($Path.Substring(3) -split '\\' | Where-Object {
			$_.EndsWith('.') -or $_.EndsWith(' ') -or $_ -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)'
		}).Count) { throw "Refusing an aliased or reserved Windows path: $Path" }
		$drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Path))
		if ($drive.DriveType -ne [IO.DriveType]::Fixed -or $drive.DriveFormat -ne 'NTFS') {
			throw "Unsupported installation filesystem at $Path; a fixed local NTFS volume is required."
		}
		$ancestor = $Path
		while ($ancestor) {
			if (Test-Path -LiteralPath $ancestor) {
				$item = Get-Item -LiteralPath $ancestor -Force
				if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing redirected path: $ancestor" }
			}
			$ancestor = Split-Path -Parent $ancestor
		}
	}

	function Get-RetypePath([string]$Path) {
		$full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
		$full = [IO.Path]::GetFullPath($full)
		Assert-RetypePath $full
		return $full
	}

	function Get-RetypeOwnedPath([string]$Relative) {
		if ((-not $executableSubsystems.Contains($Relative) -and
			$Relative -notin @('README.md', 'LICENSE') -and
			$Relative -notmatch '^share/retype/(fidelity\.toml|fixtures/fidelity/[A-Za-z0-9._/-]+|packaging/[A-Za-z0-9._/-]+)$') -or
			@($Relative -split '/' | Where-Object { $_ -in @('', '.', '..') -or $_.EndsWith('.') }).Count) {
			throw "Invalid installed-file inventory entry: $Relative"
		}
		return Get-RetypePath (Join-Path $Prefix $Relative)
	}

	function Get-RetypeHash([string]$Path) {
		if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Expected an ordinary file: $Path" }
		Assert-RetypePath $Path
		return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
	}

	function Read-RetypeRegistryTree([string]$Path) {
		if (-not (Test-Path -LiteralPath $Path)) { return $null }
		$root = Get-Item -LiteralPath $Path
		$keys = @($root) + @(Get-ChildItem -LiteralPath $Path -Recurse | Sort-Object Name)
		$tree = foreach ($key in $keys) {
			$values = @(foreach ($name in @($key.GetValueNames() | Sort-Object)) {
				[ordered]@{
					Name = $name
					Kind = $key.GetValueKind($name).ToString()
					Value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
				}
			})
			[ordered]@{ Name = $key.Name.Substring($root.Name.Length).TrimStart('\'); Values = @($values) }
		}
		return ,@($tree)
	}

	function Write-RetypeRegistryTree([string]$Path, $Tree) {
		if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
		foreach ($entry in @($Tree)) {
			if ($null -eq $entry) { continue }
			$keyPath = if ($entry.Name) { Join-Path $Path $entry.Name } else { $Path }
			$key = New-Item -Path $keyPath -Force
			foreach ($value in @($entry.Values)) {
				$key.SetValue($value.Name, $value.Value, [Microsoft.Win32.RegistryValueKind]$value.Kind)
			}
		}
	}

	function Read-RetypeStartup {
		if (-not (Test-Path -LiteralPath $RunKey)) { return $null }
		$key = Get-Item -LiteralPath $RunKey
		if ($key.GetValueNames() -notcontains $AppId) { return $null }
		return [ordered]@{
			Kind = $key.GetValueKind($AppId).ToString()
			Value = $key.GetValue($AppId, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
		}
	}

	function Write-RetypeStartup($Value) {
		if ($null -eq $Value) {
			if ($null -ne (Read-RetypeStartup)) { Remove-ItemProperty -LiteralPath $RunKey -Name $AppId }
		} else {
			if (-not (Test-Path -LiteralPath $RunKey)) { New-Item -Path $RunKey | Out-Null }
			New-ItemProperty -LiteralPath $RunKey -Name $AppId -PropertyType $Value.Kind `
				-Value $Value.Value -Force | Out-Null
		}
	}

	function Read-RetypeUserPath { return [Environment]::GetEnvironmentVariable('Path', 'User') }
	function Write-RetypeUserPath([string]$Value) { [Environment]::SetEnvironmentVariable('Path', $Value, 'User') }
	function Get-RetypePrograms { return [Environment]::GetFolderPath('Programs') }
	function Get-RetypeLockPath { return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'retype-installer\lock' }

	function Enter-RetypeInstallLock {
		$path = Get-RetypeLockPath
		Assert-RetypePath $path
		New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
		try { return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
		catch { throw "Could not acquire the per-user installer lock; another installation may be active: $_" }
	}
	function Convert-RetypeSnapshot($Value) { return ConvertTo-Json -InputObject $Value -Depth 16 -Compress }

	function Assert-RetypeSnapshot($Actual, $Expected, [string]$Name) {
		if ((Convert-RetypeSnapshot $Actual) -cne (Convert-RetypeSnapshot $Expected)) {
			throw "Refusing to replace a foreign or changed $Name. Existing installation and user data are unchanged."
		}
	}

	function Get-RetypeUriTree([string]$Command) {
		return ,@(
			[ordered]@{ Name = ''; Values = @(
				[ordered]@{ Name = ''; Kind = 'String'; Value = 'URL:retype Protocol' },
				[ordered]@{ Name = 'RetypeInstallPrefix'; Kind = 'String'; Value = $Prefix },
				[ordered]@{ Name = 'URL Protocol'; Kind = 'String'; Value = '' }
			) },
			[ordered]@{ Name = 'shell'; Values = @() },
			[ordered]@{ Name = 'shell\open'; Values = @() },
			[ordered]@{ Name = 'shell\open\command'; Values = @([ordered]@{ Name = ''; Kind = 'String'; Value = $Command }) }
		)
	}

	function Get-RetypeIdentityTree {
		return ,@([ordered]@{ Name = ''; Values = @(
			[ordered]@{ Name = 'DisplayName'; Kind = 'String'; Value = 'retype' },
			[ordered]@{ Name = 'RetypeInstallPrefix'; Kind = 'String'; Value = $Prefix }
		) })
	}

	function Assert-RetypeShortcut([string]$Path, [string]$Arguments) {
		$shell = New-Object -ComObject WScript.Shell
		$application = New-Object -ComObject Shell.Application
		try {
			$link = $shell.CreateShortcut($Path)
			$folder = $application.NameSpace((Split-Path -Parent $Path))
			$item = $folder.ParseName([IO.Path]::GetFileName($Path))
			try {
				if ($link.TargetPath -ne $targetBinary -or $link.Arguments -cne $Arguments -or
					$item.ExtendedProperty('System.AppUserModel.ID') -cne $AppId) {
					throw 'Refusing a foreign Start-menu shortcut, regardless of its mutable receipt hash.'
				}
			} finally {
				foreach ($object in @($item, $folder, $link)) { [Runtime.InteropServices.Marshal]::ReleaseComObject($object) | Out-Null }
			}
		} finally {
			[Runtime.InteropServices.Marshal]::ReleaseComObject($application) | Out-Null
			[Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
		}
	}

	function Get-RetypeArguments($Settings) {
		$arguments = ''
		if ($Settings.StateDir) { $arguments += ' --state-dir "' + (Get-RetypePath $Settings.StateDir) + '"' }
		if ($Settings.Config) { $arguments += ' --config "' + (Get-RetypePath $Settings.Config) + '"' }
		return $arguments
	}

	function Get-RetypeReviewCommand($Settings) {
		$arguments = ''
		if ($Settings.StateDir) {
			$state = Get-RetypePath $Settings.StateDir
			# Trailing backslashes must be doubled before the closing Windows argument quote.
			$state += '\' * ($state.Length - $state.TrimEnd('\').Length)
			$arguments = ' --state-dir "' + $state + '"'
		}
		return '"' + $targetReview + '"' + $arguments + ' -- "%1"'
	}

	function Assert-RetypeExecutable([string]$Path, [uint16]$Subsystem) {
		$bytes = [IO.File]::ReadAllBytes($Path)
		if ($bytes.Length -lt 64 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 2) -ne 'MZ') { throw 'Not a Windows executable.' }
		$offset = [BitConverter]::ToUInt32($bytes, 60)
		if ($offset -lt 64 -or $offset -gt $bytes.Length - 94 -or
			[BitConverter]::ToUInt32($bytes, $offset) -ne 0x00004550 -or
			[BitConverter]::ToUInt16($bytes, $offset + 20) -lt 70 -or
			[BitConverter]::ToUInt16($bytes, $offset + 24) -ne 0x020B) { throw 'Invalid Windows executable header.' }
		$expected = if ($machine -eq 'ARM64') { 0xAA64 } else { 0x8664 }
		if ([BitConverter]::ToUInt16($bytes, $offset + 4) -ne $expected) { throw 'The executable does not match the native Windows architecture.' }
		if ([BitConverter]::ToUInt16($bytes, $offset + 92) -ne $Subsystem) { throw "Unexpected Windows executable subsystem: $Path" }
	}

	function Backup-RetypeFile([string]$Path, [string]$Relative) {
		$destination = Join-Path $backup $Relative
		New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
		Copy-Item -LiteralPath $Path -Destination $destination
		if ((Get-RetypeHash $Path) -ne (Get-RetypeHash $destination)) { throw "Backup verification failed for $Path" }
		return $destination
	}

	function Restore-RetypeFiles {
		$changed = @($files | Where-Object Changed)
		[array]::Reverse($changed)
		foreach ($file in $changed) {
			Assert-RetypePath $file.Destination
			if (Test-Path -LiteralPath $file.Destination) {
				if ((Get-RetypeHash $file.Destination) -notin @($file.Hash, $file.PreviousHash)) {
					throw "Rollback found a replacement at $($file.Destination)"
				}
			}
			if ($file.Previous) {
				if ((Get-RetypeHash $file.Previous) -ne $file.PreviousHash) { throw 'The retained backup changed; refusing rollback.' }
				Copy-Item -LiteralPath $file.Previous -Destination $file.Stage -Force
				Move-Item -LiteralPath $file.Stage -Destination $file.Destination -Force
			} elseif (Test-Path -LiteralPath $file.Destination) {
				Remove-Item -LiteralPath $file.Destination
			}
		}
	}

	Assert-RetypeHost
	$Action = if ($env:RETYPE_ACTION) { $env:RETYPE_ACTION } else { 'install' }
	$Mode = if ($env:RETYPE_INSTALL_MODE) { $env:RETYPE_INSTALL_MODE } else { 'signed' }
	$Startup = if ($env:RETYPE_STARTUP) { $env:RETYPE_STARTUP } else { 'preserve' }
	if ($Action -notin @('install', 'remove')) { throw 'RETYPE_ACTION must be install or remove.' }
	if ($Mode -notin @('signed', 'preview')) { throw 'RETYPE_INSTALL_MODE must be signed or explicitly preview.' }
	if ($Startup -notin @('preserve', 'enable', 'disable')) { throw 'RETYPE_STARTUP must be preserve, enable or disable.' }
	$Prefix = if ($env:RETYPE_PREFIX) { $env:RETYPE_PREFIX } else { Join-Path $env:LOCALAPPDATA 'Programs\retype' }
	$Prefix = (Get-RetypePath $Prefix).TrimEnd('\')
	if ($Prefix -eq [IO.Path]::GetPathRoot($Prefix).TrimEnd('\')) { throw 'The install prefix cannot be a drive root.' }
	$binDir = Join-Path $Prefix 'bin'
	$targetBinary = Join-Path $binDir 'retype.exe'
	$targetReview = Join-Path $binDir 'retype-review.exe'
	# PE subsystems: Windows console (3) and Windows GUI (2).
	$executableSubsystems = [ordered]@{ 'bin/retype.exe' = 3; 'bin/retype-review.exe' = 2 }
	$receiptPath = Join-Path $Prefix '.retype-install.json'
	$machine = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
	if ($machine -notin @('AMD64', 'ARM64')) { throw "Unsupported architecture: $machine" }
	$AppId = 'st.elmo.retype.cli'
	$UriKey = 'HKCU:\Software\Classes\retype'
	$IdentityKey = 'HKCU:\Software\Classes\AppUserModelId\' + $AppId
	$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
	$receipt = $null
	$owned = @{}
	if (Test-Path -LiteralPath $receiptPath) {
		Assert-RetypePath $receiptPath
		$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
		if ($receipt.Schema -ne 'retype-windows-install-1' -or $receipt.Prefix -ne $Prefix -or
			$receipt.Mode -notin @('signed', 'preview') -or $receipt.Integration -notin @('user', 'none') -or
			($receipt.Mode -eq 'signed') -ne ($receipt.Integration -eq 'user') -or
			$receipt.Installed -isnot [bool] -or $receipt.Startup -isnot [bool] -or $receipt.AddedPath -isnot [bool] -or
			$receipt.HadPlainIdentity -isnot [bool] -or ($receipt.Integration -eq 'none' -and $receipt.Startup)) {
			throw "Invalid installation receipt at $receiptPath"
		}
		foreach ($file in @($receipt.Files)) {
			$null = Get-RetypeOwnedPath $file.Path
			if ($file.Sha256 -notmatch '^[a-f0-9]{64}$' -or $owned.ContainsKey($file.Path)) { throw 'Invalid installed-file inventory.' }
			$owned[$file.Path] = $file.Sha256
		}
		if (-not $owned.ContainsKey('bin/retype.exe')) { throw 'The installation receipt has no executable.' }
	} elseif (Test-Path -LiteralPath $targetBinary) {
		throw 'This prefix has no ownership receipt. Preserve the legacy installation and choose a new RETYPE_PREFIX.'
	}
	if ($Action -eq 'remove' -and (-not $receipt -or -not $receipt.Installed)) { throw 'There is no active owned installation to remove at this prefix.' }
	$Integration = if ($Action -eq 'remove') { $receipt.Integration } elseif ($Mode -eq 'signed') { 'user' } else { 'none' }
	if ($Action -eq 'install' -and $receipt -and $receipt.Installed -and $receipt.Mode -eq 'signed' -and $Mode -eq 'preview') {
		throw 'An installed signed delivery cannot be downgraded to a CLI-only preview in place.'
	}
	if ($Startup -eq 'enable' -and $Integration -eq 'none') { throw 'Startup requires signed per-user installed delivery.' }
	$settings = [ordered]@{
		StateDir = if ($env:RETYPE_STATE_DIR) { Get-RetypePath $env:RETYPE_STATE_DIR } elseif ($receipt) { $receipt.StateDir } else { $null }
		Config = if ($env:RETYPE_CONFIG) { Get-RetypePath $env:RETYPE_CONFIG } elseif ($receipt) { $receipt.Config } else { $null }
	}
	if ($settings.StateDir) { $settings.StateDir = Get-RetypePath $settings.StateDir }
	if ($settings.Config) { $settings.Config = Get-RetypePath $settings.Config }
	$arguments = Get-RetypeArguments $settings
	if ($Action -eq 'install' -and $Integration -eq 'user' -and $settings.Config -and
		-not (Test-Path -LiteralPath $settings.Config -PathType Leaf)) {
		throw 'An explicitly selected installed-integration configuration must exist; no default substitution is allowed.'
	}
	$startAtLogin = $Integration -eq 'user' -and ($Startup -eq 'enable' -or ($Startup -eq 'preserve' -and $receipt -and $receipt.Startup))
	$startCommand = '"' + $targetBinary + '"' + $arguments + ' daemon start'
	$uriCommand = Get-RetypeReviewCommand $settings
	$shortcut = Join-Path (Get-RetypePrograms) 'retype.lnk'
	Assert-RetypePath $shortcut
	$oldUserPath = Read-RetypeUserPath
	$entries = if ($oldUserPath) { @($oldUserPath -split ';') } else { @() }
	$ownedPath = $receipt -and $receipt.Installed -and $receipt.AddedPath
	$addedPath = $ownedPath -or $entries -notcontains $binDir
	$before = [ordered]@{
		Uri = Read-RetypeRegistryTree $UriKey
		Identity = Read-RetypeRegistryTree $IdentityKey
		Startup = Read-RetypeStartup
		UserPath = $oldUserPath
	}
	$plainIdentity = @([ordered]@{ Name = ''; Values = @([ordered]@{ Name = 'DisplayName'; Kind = 'String'; Value = 'retype' }) })
	$hadPlainIdentity = $false
	if ($receipt -and $receipt.Installed -and $receipt.Integration -eq 'user') {
		# Registry ownership is derived from fixed contracts, never from receipt-supplied registry trees.
		$oldArguments = Get-RetypeArguments $receipt
		$oldCommand = '"' + $targetBinary + '"' + $oldArguments
		$oldUri = if ($owned.ContainsKey('bin/retype-review.exe')) { Get-RetypeReviewCommand $receipt }
			else { $oldCommand + ' uri -- "%1"' }
		Assert-RetypeSnapshot $before.Uri (Get-RetypeUriTree $oldUri) 'URI registration'
		Assert-RetypeSnapshot $before.Identity (Get-RetypeIdentityTree) 'notification identity'
		$oldRun = if ($receipt.Startup) { [ordered]@{ Kind = 'String'; Value = $oldCommand + ' daemon start' } } else { $null }
		Assert-RetypeSnapshot $before.Startup $oldRun 'startup entry'
		if (-not (Test-Path -LiteralPath $shortcut) -or (Get-RetypeHash $shortcut) -ne $receipt.ShortcutSha256) {
			throw 'Refusing a missing, foreign or changed Start-menu shortcut.'
		}
		Assert-RetypeShortcut $shortcut ($oldArguments + ' daemon start').TrimStart()
		$hadPlainIdentity = $receipt.HadPlainIdentity
	} elseif ($Integration -eq 'user' -and $Action -eq 'install') {
		if ($before.Uri -or $before.Startup -or (Test-Path -LiteralPath $shortcut)) {
			throw 'A URI handler, startup entry or Start-menu shortcut already exists without this installation ownership receipt.'
		}
		if ($before.Identity) { Assert-RetypeSnapshot $before.Identity $plainIdentity 'notification identity' }
		$hadPlainIdentity = $null -ne $before.Identity
	}
	$previousIdentity = if ($hadPlainIdentity) { $plainIdentity } else { $null }
	if (Get-Process -Name retype, retype-review -ErrorAction SilentlyContinue) {
		throw 'retype is running. Close Review and stop the daemon before install, update or removal.'
	}

	$temp = $null
	$backup = $null
	$files = @()
	$installLock = $null
	$beforeReceiptHash = if ($receipt) { Get-RetypeHash $receiptPath } else { $null }
	$beforeShortcutHash = if (Test-Path -LiteralPath $shortcut) { Get-RetypeHash $shortcut } else { $null }
	$changedIntegration = $false
	$changedPath = $false
	$newUserPath = $oldUserPath
	$receiptChanged = $false
	$shortcutStage = $null
	$receiptStage = Join-Path $Prefix ('.retype-install.' + [guid]::NewGuid().ToString('N') + '.json')
	try {
		if ($Action -eq 'install') {
			if ($Mode -eq 'signed') {
		if (-not $publisherKey -or $publisherCertificateSha256 -notmatch '^[a-fA-F0-9]{64}$') {
					throw 'retype trust: signed delivery requires independently approved publisher public key and certificate SHA256.'
				}
			} else {
				Write-Warning 'Explicit CLI-only preview: no publisher signature or URI/notification/startup registration; bin is added to user PATH.'
			}
			[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
			$Repo = if ($env:RETYPE_REPO) { $env:RETYPE_REPO } else { 'stelmost/retype' }
			$Version = if ($env:RETYPE_VERSION) { $env:RETYPE_VERSION } else { 'latest' }
			$ReleaseBase = if ($env:RETYPE_RELEASE_BASE) { $env:RETYPE_RELEASE_BASE } else { "https://github.com/$Repo/releases/download" }
			$Target = switch ($machine) { 'AMD64' { 'x86_64-pc-windows-msvc' } 'ARM64' { 'aarch64-pc-windows-msvc' } default { throw "Unsupported architecture: $machine" } }
			if ($env:RETYPE_TARGET -and $env:RETYPE_TARGET -ne $Target) { throw 'RETYPE_TARGET must match the native Windows architecture.' }
			if ($Version -eq 'latest') {
				$api = "https://api.github.com/repos/$Repo/releases?per_page=100"
				$releases = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'retype-installer' }
				$Tag = ($releases | Where-Object { -not $_.draft } | Select-Object -First 1).tag_name
			} else { $Tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" } }
			if ($Tag -notmatch '^v[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Invalid release tag: $Tag" }
			$Name = "retype-$Tag-$Target"
			$Archive = "$Name.tar.gz"
			$Base = $ReleaseBase.TrimEnd('/') + '/' + $Tag
			$temp = Join-Path ([IO.Path]::GetTempPath()) ('retype-install-' + [guid]::NewGuid().ToString('N'))
			Assert-RetypePath $temp
			New-Item -ItemType Directory -Path $temp | Out-Null
			$sumsPath = Join-Path $temp 'SHA256SUMS'
			$archivePath = Join-Path $temp $Archive
			Invoke-WebRequest -UseBasicParsing -Uri "$Base/SHA256SUMS" -OutFile $sumsPath
			Invoke-WebRequest -UseBasicParsing -Uri "$Base/$Archive" -OutFile $archivePath
			$checksumLines = @(foreach ($line in Get-Content -LiteralPath $sumsPath) {
				$fields = $line -split '\s+', 2
				if ($fields.Count -eq 2 -and $fields[1] -in @($Archive, "*$Archive")) { $line }
			})
			if ($checksumLines.Count -ne 1 -or $checksumLines[0] -notmatch ('^[a-fA-F0-9]{64}\s+\*?' + [regex]::Escape($Archive) + '$')) {
				throw "Release $Tag must have exactly one valid checksum for $Archive."
			}
			$expected = ($checksumLines[0] -split '\s+', 2)[0].ToLowerInvariant()
			if ((Get-RetypeHash $archivePath) -ne $expected) { throw "Checksum mismatch for $Archive." }
			if ($Mode -eq 'signed') {
				$signaturePath = Join-Path $temp 'SHA256SUMS.minisig'
				Invoke-WebRequest -UseBasicParsing -Uri "$Base/SHA256SUMS.minisig" -OutFile $signaturePath
		Assert-RetypeReleaseTrust -Archive $archivePath -Checksums $sumsPath -Signature $signaturePath -PublicKey $publisherKey
			}
			$tar = Get-Command tar.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
			$members = @(& $tar.Source -tzf $archivePath)
			if ($LASTEXITCODE -ne 0) { throw 'Could not list the release archive.' }
			$seen = @{}
			foreach ($member in $members) {
				$relative = $member.TrimEnd('/')
				if ($relative -notmatch ('^' + [regex]::Escape($Name) + '(/[A-Za-z0-9._-]+)*$') -or
					@($relative -split '/' | Where-Object {
						$_ -in @('.', '..') -or $_.EndsWith('.') -or $_ -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)'
					}).Count -or $seen.ContainsKey($relative)) {
					throw "Unsafe or duplicate archive member: $member"
				}
				$seen[$relative] = $true
			}
			$types = @(& $tar.Source -tvzf $archivePath)
			if ($LASTEXITCODE -ne 0 -or @($types | Where-Object { $_ -notmatch '^[d-]' -or $_ -match ' -> | link to ' }).Count) {
				throw 'Release archives may contain only ordinary files and directories, never links or devices.'
			}
			& $tar.Source -xzf $archivePath -C $temp
			if ($LASTEXITCODE -ne 0) { throw "tar failed with exit status $LASTEXITCODE." }
			$source = Join-Path $temp $Name
			$sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -File -Force)
			if (-not $sourceFiles.Count) { throw 'The archive contains no installation files.' }
			foreach ($sourceFile in $sourceFiles) {
				$relative = $sourceFile.FullName.Substring($source.Length + 1).Replace('\', '/')
				$destination = Get-RetypeOwnedPath $relative
				if ($Mode -eq 'preview' -and $relative -eq 'bin/retype-review.exe') { continue }
				$hash = Get-RetypeHash $sourceFile.FullName
				if (Test-Path -LiteralPath $destination) {
					if (-not $owned.ContainsKey($relative) -or (Get-RetypeHash $destination) -ne $owned[$relative]) {
						throw "Refusing to replace an unowned or changed file: $destination"
					}
				}
				foreach ($dataPath in @($settings.StateDir, $settings.Config)) {
					if ($dataPath -and ($destination -eq $dataPath -or $destination.StartsWith($dataPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) {
						throw "An installation file overlaps configured user data: $destination"
					}
				}
				$files += [pscustomobject]@{
					Path = $relative; Source = $sourceFile.FullName; Destination = $destination; Hash = $hash
					Stage = $null; Previous = $null; PreviousHash = $null; Changed = $false
				}
			}
			foreach ($relative in $executableSubsystems.Keys) {
				if ($Mode -eq 'preview' -and $relative -eq 'bin/retype-review.exe') { continue }
				$path = Join-Path $source $relative
				if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Archive does not contain $relative." }
				Assert-RetypeExecutable $path $executableSubsystems[$relative]
				if ($Mode -eq 'signed') {
			Assert-RetypeWindowsTrust -Path $path -PublisherCertificateSha256 $publisherCertificateSha256
				}
			}
			$sourceShortcut = Join-Path $source 'share\retype\packaging\windows\shortcut.ps1'
			if ($Mode -eq 'signed') {
				if (-not (Test-Path -LiteralPath $sourceShortcut -PathType Leaf)) { throw 'The release has no Windows shortcut identity helper.' }
		Assert-RetypeWindowsTrust -Path $sourceShortcut -PublisherCertificateSha256 $publisherCertificateSha256
				. $sourceShortcut
			}
		}

		$installLock = Enter-RetypeInstallLock
		$currentReceiptHash = if (Test-Path -LiteralPath $receiptPath) { Get-RetypeHash $receiptPath } else { $null }
		$currentShortcutHash = if (Test-Path -LiteralPath $shortcut) { Get-RetypeHash $shortcut } else { $null }
		Assert-RetypeSnapshot $currentReceiptHash $beforeReceiptHash 'installation receipt'
		Assert-RetypeSnapshot $currentShortcutHash $beforeShortcutHash 'Start-menu shortcut'
		Assert-RetypeSnapshot (Read-RetypeRegistryTree $UriKey) $before.Uri 'URI registration'
		Assert-RetypeSnapshot (Read-RetypeRegistryTree $IdentityKey) $before.Identity 'notification identity'
		Assert-RetypeSnapshot (Read-RetypeStartup) $before.Startup 'startup entry'
		Assert-RetypeSnapshot (Read-RetypeUserPath) $oldUserPath 'user PATH'
		$stageId = [guid]::NewGuid().ToString('N')
		$backup = Join-Path $Prefix "share\retype-backup-$stageId"
		New-Item -ItemType Directory -Path $backup -Force | Out-Null
		$before | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $backup 'integration.json') -Encoding UTF8
		if ($receipt) { $null = Backup-RetypeFile $receiptPath 'receipt.json' }
		if ($receipt -and $receipt.Installed -and $receipt.Integration -eq 'user') { $null = Backup-RetypeFile $shortcut 'retype.lnk' }
		if ($Action -eq 'remove') {
			# A mutable inventory never grants permission to purge shared assets or user data.
			foreach ($relative in $executableSubsystems.Keys) {
				if (-not $owned.ContainsKey($relative)) { continue }
				$destination = Get-RetypeOwnedPath $relative
				if (-not (Test-Path -LiteralPath $destination)) { continue }
				Assert-RetypeExecutable $destination $executableSubsystems[$relative]
				if ((Get-RetypeHash $destination) -ne $owned[$relative]) { throw "Refusing to remove a changed executable: $relative" }
				foreach ($dataPath in @($settings.StateDir, $settings.Config)) {
					if ($dataPath -and ($destination -eq $dataPath -or $destination.StartsWith($dataPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) {
						throw 'The executable overlaps configured user data; refusing removal.'
					}
				}
				$leaf = [IO.Path]::GetFileName($destination)
				$files += [pscustomobject]@{
					Path = $relative; Destination = $destination; Hash = $owned[$relative]
					Stage = Join-Path $binDir ".retype.$stageId.$leaf"; Previous = $null; PreviousHash = $null; Changed = $false
				}
			}
		}
		foreach ($file in $files) {
			New-Item -ItemType Directory -Path (Split-Path -Parent $file.Destination) -Force | Out-Null
			if (Test-Path -LiteralPath $file.Destination) {
				$file.PreviousHash = Get-RetypeHash $file.Destination
				if ($file.PreviousHash -ne $owned[$file.Path]) { throw "The destination changed before backup: $($file.Destination)" }
				$relative = if ($executableSubsystems.Contains($file.Path)) { [IO.Path]::GetFileName($file.Destination) }
					else { 'share/' + $file.Path.Substring('share/retype/'.Length) }
				$file.Previous = Backup-RetypeFile $file.Destination $relative
			}
			if ($Action -eq 'install') {
				$file.Stage = Join-Path (Split-Path -Parent $file.Destination) ('.retype.' + $stageId + '.' + [IO.Path]::GetFileName($file.Destination))
				Copy-Item -LiteralPath $file.Source -Destination $file.Stage
			}
		}
		if ($Action -eq 'install') {
			$stagedBinary = ($files | Where-Object Path -eq 'bin/retype.exe').Stage
			if ($Mode -eq 'signed') {
				foreach ($file in $files | Where-Object { $executableSubsystems.Contains($_.Path) }) {
			Assert-RetypeWindowsTrust -Path $file.Stage -PublisherCertificateSha256 $publisherCertificateSha256
				}
			}
			$output = & $stagedBinary --version 2>&1
			if ($LASTEXITCODE -ne 0) { throw "The staged binary does not run; installation unchanged: $output" }
		}
		foreach ($file in $files) {
			if (Test-Path -LiteralPath $file.Destination) {
				if (-not $file.Previous -or (Get-RetypeHash $file.Destination) -ne $file.PreviousHash) {
					throw "The destination changed before publication/removal: $($file.Destination)"
				}
			} elseif ($file.Previous) { throw "The destination disappeared before publication/removal: $($file.Destination)" }
			if ($Action -eq 'install' -and (Get-RetypeHash $file.Stage) -ne $file.Hash) { throw 'A staged file changed before publication.' }
			$file.Changed = $true
			if ($Action -eq 'install') { Move-Item -LiteralPath $file.Stage -Destination $file.Destination -Force }
			else {
				$removed = 'removed-' + [IO.Path]::GetFileName($file.Destination)
				Move-Item -LiteralPath $file.Destination -Destination (Join-Path $backup $removed)
			}
			$owned[$file.Path] = $file.Hash
		}
		if ($Integration -eq 'user' -or ($receipt -and $receipt.Installed -and $receipt.Integration -eq 'user')) {
			$changedIntegration = $true
			if ($Action -eq 'install' -and $Integration -eq 'user') {
				Write-RetypeRegistryTree $UriKey (Get-RetypeUriTree $uriCommand)
				Write-RetypeRegistryTree $IdentityKey (Get-RetypeIdentityTree)
				$run = if ($startAtLogin) { [ordered]@{ Kind = 'String'; Value = $startCommand } } else { $null }
				Write-RetypeStartup $run
				New-Item -ItemType Directory -Path (Split-Path -Parent $shortcut) -Force | Out-Null
				$shortcutStage = Join-Path (Split-Path -Parent $shortcut) ".retype.$stageId.lnk"
				New-RetypeShortcut -Path $shortcutStage -Target $targetBinary -Arguments ($arguments + ' daemon start').TrimStart()
				Move-Item -LiteralPath $shortcutStage -Destination $shortcut -Force
			} else {
				Write-RetypeStartup $null
				Write-RetypeRegistryTree $UriKey $null
				Write-RetypeRegistryTree $IdentityKey $previousIdentity
				Remove-Item -LiteralPath $shortcut
			}
		}
		if ($Action -eq 'install') {
			if ($entries -notcontains $binDir) { $newUserPath = (@($binDir) + $entries) -join ';' }
		} elseif ($ownedPath) { $newUserPath = @($entries | Where-Object { $_ -ne $binDir }) -join ';' }
		if ($newUserPath -cne $oldUserPath) { $changedPath = $true; Write-RetypeUserPath $newUserPath }
		if ($Action -eq 'install') {
			$newReceipt = [ordered]@{
				Schema = 'retype-windows-install-1'; Prefix = $Prefix; Mode = $Mode; Integration = $Integration; Installed = $true
				Startup = [bool]$startAtLogin; AddedPath = [bool]$addedPath; StateDir = $settings.StateDir; Config = $settings.Config
				Files = @($owned.Keys | Sort-Object | ForEach-Object { [ordered]@{ Path = $_; Sha256 = $owned[$_] } })
				HadPlainIdentity = [bool]$hadPlainIdentity
				ShortcutSha256 = if ($Integration -eq 'user') { Get-RetypeHash $shortcut } else { $null }
			}
			$newReceipt | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $receiptStage -Encoding UTF8
			$receiptChanged = $true
			Move-Item -LiteralPath $receiptStage -Destination $receiptPath -Force
			if (($env:Path -split ';') -notcontains $binDir) { $env:Path = "$binDir;$env:Path" }
			Write-Host "retype installed at $targetBinary ($Mode)"
			Write-Host "Startup at next sign-in: $startAtLogin. No daemon was started by this installer."
			Write-Host 'Next: retype doctor; install any external converters yourself.'
		} else {
			$receipt.Installed = $false; $receipt.Startup = $false; $receipt.AddedPath = $false; $receipt.ShortcutSha256 = $null
			$receipt | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $receiptStage -Encoding UTF8
			$receiptChanged = $true
			Move-Item -LiteralPath $receiptStage -Destination $receiptPath -Force
			if ($ownedPath) { $env:Path = @($env:Path -split ';' | Where-Object { $_ -ne $binDir }) -join ';' }
			Write-Host 'retype removed. Shared assets, retired receipt, configuration, watch registrations and recovery data were retained in place.'
		}
		Write-Host "Previous installation and integration backup: $backup"
	} catch {
		$failure = $_
		if ($backup) {
			try {
				if ($changedPath) {
					$currentPath = Read-RetypeUserPath
					if ($currentPath -cne $newUserPath -and $currentPath -cne $oldUserPath) { throw 'User PATH changed concurrently; refusing rollback replacement.' }
					Write-RetypeUserPath $oldUserPath
				}
				if ($changedIntegration) {
					Write-RetypeStartup $before.Startup
					Write-RetypeRegistryTree $UriKey $before.Uri
					Write-RetypeRegistryTree $IdentityKey $before.Identity
					$previousShortcut = Join-Path $backup 'retype.lnk'
					if (Test-Path -LiteralPath $previousShortcut) { Copy-Item -LiteralPath $previousShortcut -Destination $shortcut -Force }
					elseif (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut }
				}
				Restore-RetypeFiles
				if ($receiptChanged) {
					$previousReceipt = Join-Path $backup 'receipt.json'
					if (Test-Path -LiteralPath $previousReceipt) { Copy-Item -LiteralPath $previousReceipt -Destination $receiptPath -Force }
					elseif (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath }
				}
			} catch { throw "Install/removal failed: $failure. Rollback failed: $_. Recover from $backup" }
			Write-Warning "Previous installation preserved; backup: $backup"
		}
		throw $failure
	} finally {
		try {
			$cleanup = @($receiptStage, $shortcutStage)
			foreach ($file in $files) { $cleanup += $file.Stage }
			foreach ($path in $cleanup) {
				if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
			}
			if ($temp -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Recurse -Force }
		} finally {
			if ($installLock) { $installLock.Dispose() }
		}
	}
}
