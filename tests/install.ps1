# Synthetic Windows delivery regressions: private files/shortcut and mocked publisher/user integration.
# The registry backend is checked only beneath a fresh, non-OS-recognized fixture key.
param([Parameter(Mandatory = $true)][string]$Binary, [string]$Report)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Run this fixture on native Windows.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal $identity
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Refusing elevated installer qualification.' }
$architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($architecture -notin @('X64', 'Arm64') -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -ne $architecture) {
	throw 'Expected native 64-bit Windows and PowerShell architecture.'
}
$Root = Split-Path $PSScriptRoot -Parent
$Binary = [IO.Path]::GetFullPath($Binary)
$Review = Join-Path (Split-Path -Parent $Binary) 'retype-review.exe'
if (-not $Report) {
	$parent = if ($env:RETYPE_TEST_REPORT_DIR) { $env:RETYPE_TEST_REPORT_DIR } else { Join-Path $env:LOCALAPPDATA 'retype-test-reports' }
	$Report = Join-Path $parent ('installer-' + [guid]::NewGuid().ToString('N'))
}
$Report = [IO.Path]::GetFullPath($Report)
$cargoTarget = if ($env:CARGO_TARGET_DIR) { [IO.Path]::GetFullPath($env:CARGO_TARGET_DIR) } else { Join-Path $Root 'target' }
if ($Report -eq $cargoTarget -or $Report.StartsWith($cargoTarget.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
	throw 'Retain installer evidence outside Cargo target.'
}
if ($Report -notmatch '^[A-Za-z]:\\') { throw 'The report must be on fixed local NTFS, not a network path.' }
$drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Report))
if ($drive.DriveType -ne [IO.DriveType]::Fixed -or $drive.DriveFormat -ne 'NTFS') { throw 'The report must be on fixed local NTFS.' }
$ancestor = $Report
while ($ancestor) {
	if (Test-Path -LiteralPath $ancestor) {
		if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
			throw "Refusing a redirected fixture path: $ancestor"
		}
	}
	$ancestor = Split-Path -Parent $ancestor
}
if (Test-Path -LiteralPath $Report) { throw 'Use a new report directory; previous evidence is never overwritten.' }
New-Item -ItemType Directory -Path $Report | Out-Null
Start-Transcript -Path (Join-Path $Report 'fixture.log') | Out-Null
$Temp = Join-Path $Report 'fixture'
$Prefix = Join-Path $Temp "prefix's files"
$Programs = Join-Path $Temp 'programs'
$State = Join-Path $Prefix 'share\retype\user-state'
$Config = Join-Path $Prefix 'user-config.toml'
$Tag = 'v0.0.0-test'
$Target = if ($architecture -eq 'Arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$Name = "retype-$Tag-$Target"
$Release = Join-Path $Temp $Name
$Archive = Join-Path $Temp "$Name.tar.gz"
$Sums = Join-Path $Temp 'SHA256SUMS'
$AppId = 'com.lapilliworks.retype.cli'
$UriKey = 'HKCU:\Software\Classes\retype'
$IdentityKey = 'HKCU:\Software\Classes\AppUserModelId\' + $AppId
$Registry = @{}
$Run = $null
$UserPath = 'C:\first;;C:\last'
$Writes = 0
$Trace = @()
$FailPublication = $null
$FailIntegration = $false
$Checks = @()
$variables = @('RETYPE_PREFIX', 'RETYPE_TARGET', 'RETYPE_VERSION', 'RETYPE_RELEASE_BASE', 'RETYPE_REPO',
	'RETYPE_ACTION', 'RETYPE_INSTALL_MODE', 'RETYPE_STARTUP', 'RETYPE_PUBLIC_KEY', 'RETYPE_PUBLISHER_CERTIFICATE_SHA256',
	'RETYPE_STATE_DIR', 'RETYPE_CONFIG', 'PATH')
$environment = @{}
foreach ($variable in $variables) { $environment[$variable] = [Environment]::GetEnvironmentVariable($variable, 'Process') }

function Check([string]$Name, [bool]$Condition) {
	if (-not $Condition) { throw $Name }
	$script:Checks += $Name
	$script:Checks | ConvertTo-Json | Set-Content (Join-Path $Report 'checks.json') -Encoding UTF8
	Write-Host "PASS: $Name"
}
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Snapshot($Value) { return ConvertTo-Json -InputObject $Value -Depth 16 -Compress }
function Clone($Value) { return (Snapshot $Value) | ConvertFrom-Json }
function Invoke-RestMethod {
	param($Uri, $Headers)
	if ($Uri -notlike '*/releases?per_page=100') { throw "Unexpected release endpoint: $Uri" }
	[pscustomobject]@{ tag_name = $script:Tag; prerelease = $true; draft = $false }
}
function Invoke-WebRequest {
	param([switch]$UseBasicParsing, $Uri, $OutFile)
	if ($Uri.EndsWith('/SHA256SUMS.minisig')) { [IO.File]::WriteAllText($OutFile, 'fixture-only mock signature'); return }
	$source = if ($Uri.EndsWith('/SHA256SUMS')) { $script:Sums } else { $script:Archive }
	Copy-Item -LiteralPath $source -Destination $OutFile
}
function Get-Process { param($Name, $ErrorAction) }
function Read-RetypeRegistryTree([string]$Path) {
	if ($null -eq $script:Registry[$Path]) { return $null }
	return ,@($script:Registry[$Path])
}
function Write-RetypeRegistryTree([string]$Path, $Tree) {
	$script:Writes++
	if ($script:FailIntegration -and $Path -eq $script:IdentityKey) {
		$script:FailIntegration = $false
		throw 'Simulated notification-identity publication failure'
	}
	if ($null -eq $Tree) { $script:Registry.Remove($Path) } else { $script:Registry[$Path] = Clone $Tree }
}
function Read-RetypeStartup { return $script:Run }
function Write-RetypeStartup($Value) { $script:Writes++; $script:Run = Clone $Value }
function Read-RetypeUserPath { return $script:UserPath }
function Write-RetypeUserPath([string]$Value) { $script:Writes++; $script:UserPath = $Value }
function Get-RetypePrograms { return $script:Programs }
function Get-RetypeLockPath { return Join-Path $script:Temp 'installer-lock' }
function Assert-RetypeReleaseTrust {
	param($Archive, $Checksums, $Signature, $PublicKey)
	Check 'Synthetic manifest hook has explicit inputs' ((Test-Path $Archive) -and (Test-Path $Checksums) -and (Test-Path $Signature) -and $PublicKey)
	$script:Trace += 'manifest'
}
function Assert-RetypeWindowsTrust {
	param($Path, $PublisherCertificateSha256)
	if ($script:Trace -notcontains 'manifest' -or -not (Test-Path $Path) -or $PublisherCertificateSha256 -ne ('0' * 64)) {
		throw 'Synthetic platform hook ran before manifest verification or without fixture inputs'
	}
	$script:Trace += [IO.Path]::GetFileName($Path)
}
function Move-Item {
	param($LiteralPath, $Destination, [switch]$Force)
	$leaf = [IO.Path]::GetFileName($LiteralPath)
	$kind = if ($leaf.StartsWith('.retype-install.')) { 'receipt' }
		elseif ($leaf.StartsWith('.retype.') -and $Destination.EndsWith('\retype.exe')) { 'binary' }
		elseif ($leaf.StartsWith('.retype.') -and $Destination.EndsWith('\retype-review.exe')) { 'review' }
		elseif ($leaf.StartsWith('.retype.') -and $Destination.EndsWith('\fidelity.toml')) { 'asset' }
		elseif ($Destination.EndsWith('\removed-retype-review.exe')) { 'removal' } else { '' }
	if ($kind -and $script:FailPublication -eq $kind) {
		$script:FailPublication = $null
		throw "Simulated $kind publication failure"
	}
	Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}
function Pack-Release([string]$Label) {
	if (Test-Path $Archive) { Copy-Item $Archive (Join-Path $Report ($Label + '-previous.tar.gz')) }
	& tar.exe -czf $Archive -C $Temp $Name
	if ($LASTEXITCODE -ne 0) { throw 'Could not assemble the local release' }
	[IO.File]::WriteAllText($Sums, "$(Hash $Archive)  $Name.tar.gz`n")
	Copy-Item $Archive (Join-Path $Report ($Label + '.tar.gz'))
}
function Installed-Snapshot {
	$orderedRegistry = [ordered]@{}
	foreach ($key in @($script:Registry.Keys | Sort-Object)) { $orderedRegistry[$key] = $script:Registry[$key] }
	return Snapshot ([ordered]@{
		Binary = Hash (Join-Path $Prefix 'bin\retype.exe')
		Review = Hash (Join-Path $Prefix 'bin\retype-review.exe')
		Asset = Hash (Join-Path $Prefix 'share\retype\fidelity.toml')
		Receipt = Hash (Join-Path $Prefix '.retype-install.json')
		Shortcut = Hash (Join-Path $Programs 'retype.lnk')
		Registry = $orderedRegistry; Run = $script:Run; UserPath = $script:UserPath
	})
}
function Refused([string]$Label, [string]$Message) {
	$receipt = Join-Path $script:Prefix '.retype-install.json'
	if (Test-Path $receipt) { Copy-Item $receipt (Join-Path $Report ($Label + '-receipt.json')) }
	Snapshot ([ordered]@{ Registry = $script:Registry; Run = $script:Run; UserPath = $script:UserPath }) |
		Set-Content (Join-Path $Report ($Label + '-integration.json')) -Encoding UTF8
	$failed = $false
	try { & $script:Installer } catch {
		$failed = $true
		$_.ToString() | Set-Content (Join-Path $Report ($Label + '.error.log')) -Encoding UTF8
		Check "$Label reports the intended refusal" ($_.ToString() -like "*$Message*")
	}
	Check "$Label was refused" $failed
}

try {
	$revision = & git -C $Root rev-parse HEAD
	if ($LASTEXITCODE -ne 0) { throw 'The exact source revision is required.' }
	@{ Revision = $revision; Binary = $Binary; BinarySha256 = Hash $Binary; ReviewSha256 = Hash $Review;
		User = $identity.Name; Elevated = $false;
		OSVersion = [Environment]::OSVersion.Version.ToString(); Architecture = $architecture;
		Scope = 'Synthetic publisher/URI/AppID/Run/PATH boundaries; native private NTFS, registry backend and shell-link property' } |
		ConvertTo-Json | Set-Content (Join-Path $Report 'identity.json') -Encoding UTF8
	& git -C $Root status --porcelain | Set-Content (Join-Path $Report 'source-status.txt') -Encoding UTF8
	New-Item -ItemType Directory -Path (Join-Path $Report 'sources'), (Join-Path $Release 'bin'),
		(Join-Path $Release 'share\retype\packaging\windows'), $State, (Join-Path $State 'recovery') -Force | Out-Null
	foreach ($path in @('packaging/install.ps1', 'packaging/windows/shortcut.ps1', 'tests/install.ps1')) {
		$destination = Join-Path $Report ('sources/' + $path)
		New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
		Copy-Item (Join-Path $Root $path) $destination
	}
	$Source = [IO.File]::ReadAllText((Join-Path $Root 'packaging\install.ps1'))
	$tokens = $null; $errors = $null
	$ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
	Check 'Installer parses with the native PowerShell parser' ($errors.Count -eq 0)

	# These native functions operate only on this new private key, never on real URI/AppID/Run keys.
	$backends = @('Read-RetypeRegistryTree', 'Write-RetypeRegistryTree', 'Read-RetypeStartup', 'Write-RetypeStartup')
	$native = foreach ($name in $backends) {
		$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
		if (-not $definition) { throw "Missing native registry boundary: $name" }
		$definition.Extent.Text
	}
	$native = $native -join "`n"
	foreach ($name in $backends) { $native = $native.Replace($name, 'Native-' + $name) }
	. ([scriptblock]::Create($native))
	$privateKey = 'HKCU:\Software\retype-installer-tests\' + [guid]::NewGuid().ToString('N')
	$RunKey = Join-Path $privateKey 'Run'
	try {
		$tree = @([ordered]@{ Name = ''; Values = @([ordered]@{ Name = ''; Kind = 'String'; Value = 'fixture' }) },
			[ordered]@{ Name = 'empty'; Values = @() })
		Native-Write-RetypeRegistryTree $privateKey $tree
		Check 'Native registry round-trip preserves the default value and empty child key' ((Snapshot (Native-Read-RetypeRegistryTree $privateKey)) -ceq (Snapshot $tree))
		$key = New-Item -Path $RunKey
		$key.SetValue('other-application', 'untouched')
		Native-Write-RetypeStartup ([ordered]@{ Kind = 'String'; Value = 'fixture startup' })
		Check 'Native startup write preserves other applications' ((Get-Item $RunKey).GetValue('other-application') -eq 'untouched')
		Native-Write-RetypeStartup $null
		Check 'Native startup removal preserves other applications' ((Get-Item $RunKey).GetValue('other-application') -eq 'untouched')
	} finally {
		if (Test-Path $privateKey) {
			Native-Read-RetypeRegistryTree $privateKey | ConvertTo-Json -Depth 16 | Set-Content (Join-Path $Report 'private-registry-before-cleanup.json') -Encoding UTF8
			Microsoft.PowerShell.Management\Remove-Item -LiteralPath $privateKey -Recurse -Force
		}
	}

	$boundaries = $backends + @('Read-RetypeUserPath', 'Write-RetypeUserPath', 'Get-RetypePrograms', 'Get-RetypeLockPath',
		'Assert-RetypeReleaseTrust', 'Assert-RetypeWindowsTrust')
	foreach ($name in $boundaries) {
		$marker = 'function ' + $name
		if (-not $Source.Contains($marker)) { throw "Missing isolated installer boundary: $name" }
		$Source = $Source.Replace($marker, 'function Unused-' + $name)
	}
	$Installer = [scriptblock]::Create($Source)
	$SourceBinary = Join-Path $Release 'bin\retype.exe'
	$SourceAsset = Join-Path $Release 'share\retype\fidelity.toml'
	Copy-Item -LiteralPath $Binary -Destination $SourceBinary
	Copy-Item (Join-Path $Root 'packaging\windows\shortcut.ps1') (Join-Path $Release 'share\retype\packaging\windows\shortcut.ps1')
	[IO.File]::WriteAllText($SourceAsset, 'asset A')
	[IO.File]::WriteAllText($Config, 'user configuration, never overwritten')
	foreach ($relative in @('watches.toml', 'jobs.jsonl', 'recovery/request.json', 'recovery/original.bin')) {
		[IO.File]::WriteAllText((Join-Path $State $relative), 'retained user data: ' + $relative)
	}
	Pack-Release 'initial'
	$env:RETYPE_PREFIX = $Prefix; $env:RETYPE_TARGET = $Target; $env:RETYPE_VERSION = 'latest'
	$env:RETYPE_RELEASE_BASE = 'https://local-release.invalid'; $env:RETYPE_STATE_DIR = $State; $env:RETYPE_CONFIG = $Config
	$env:RETYPE_ACTION = 'install'; $env:RETYPE_STARTUP = 'preserve'; $env:RETYPE_INSTALL_MODE = 'signed'
	$env:RETYPE_PUBLIC_KEY = ''; $env:RETYPE_PUBLISHER_CERTIFICATE_SHA256 = ''
	Refused 'missing-trust' 'independently approved publisher'
	Check 'Missing trust refuses before user integration or executable publication' ($Writes -eq 0 -and -not (Test-Path (Join-Path $Prefix 'bin\retype.exe')))

	$env:RETYPE_INSTALL_MODE = 'preview'
	& $Installer
	Check 'Preview preserves user PATH discovery but installs no URI, identity or startup integration' ($Writes -eq 1 -and $Registry.Count -eq 0 -and
		$null -eq $Run -and -not (Test-Path (Join-Path $Programs 'retype.lnk')) -and $UserPath.StartsWith((Join-Path $Prefix 'bin') + ';'))
	Check 'Preview installs the exact packaged executable' ((Hash (Join-Path $Prefix 'bin\retype.exe')) -eq (Hash $Binary))
	$env:RETYPE_ACTION = 'remove'
	& $Installer
	Check 'Preview removal retains assets/data and removes only its owned PATH token' ((Test-Path (Join-Path $Prefix 'share\retype\fidelity.toml')) -and
		(Test-Path $Config) -and (Test-Path (Join-Path $State 'recovery/original.bin')) -and $Writes -eq 2 -and $UserPath -ceq 'C:\first;;C:\last')

	$Prefix = Join-Path $Temp "installed's files"; $env:RETYPE_PREFIX = $Prefix
	$State = Join-Path $Prefix 'share\retype\user-state'; $Config = Join-Path $Prefix 'user-config.toml'
	New-Item -ItemType Directory -Path $State, (Join-Path $State 'recovery') -Force | Out-Null
	[IO.File]::WriteAllText($Config, 'user configuration, never overwritten')
	foreach ($relative in @('watches.toml', 'jobs.jsonl', 'recovery/request.json', 'recovery/original.bin')) {
		[IO.File]::WriteAllText((Join-Path $State $relative), 'retained user data: ' + $relative)
	}
	$env:RETYPE_STATE_DIR = $State; $env:RETYPE_CONFIG = $Config
	$env:RETYPE_ACTION = 'install'; $env:RETYPE_INSTALL_MODE = 'signed'
	$env:RETYPE_PUBLIC_KEY = 'FIXTURE-ONLY-NOT-PUBLISHER-TRUST'; $env:RETYPE_PUBLISHER_CERTIFICATE_SHA256 = '0' * 64
	$plain = @([ordered]@{ Name = ''; Values = @([ordered]@{ Name = 'DisplayName'; Kind = 'String'; Value = 'retype' }) })
	$Registry[$IdentityKey] = Clone $plain
	Refused 'missing-review' 'does not contain bin/retype-review.exe'
	$SourceReview = Join-Path $Release 'bin\retype-review.exe'
	Copy-Item -LiteralPath $Binary -Destination $SourceReview
	Pack-Release 'console-review'
	Refused 'console-review' 'Unexpected Windows executable subsystem'
	Check 'Missing or console-subsystem launcher never publishes a URI handler' (-not $Registry.ContainsKey($UriKey))
	Copy-Item -LiteralPath $Review -Destination $SourceReview -Force
	Pack-Release 'gui-review'
	& $Installer
	Check 'Fresh full integration leaves startup disabled' ($null -eq $Run)
	$InstalledReview = Join-Path $Prefix 'bin\retype-review.exe'
	$expectedUri = '"' + $InstalledReview + '" --state-dir "' + $State + '" -- "%1"'
	Check 'URI directly launches the GUI executable with one quoted operand' ($Registry[$UriKey][-1].Values[0].Value -ceq $expectedUri)
	Check 'Manifest and platform hooks verify the CLI, Review launcher and shortcut helper' ($Trace[0] -eq 'manifest' -and
		$Trace -contains 'shortcut.ps1' -and $Trace -contains 'retype.exe' -and $Trace -contains 'retype-review.exe' -and
		@($Trace | Where-Object { $_ -like '.retype.*.retype-review.exe' }).Count -gt 0)
	Check 'Exact packaged executables are installed' ((Hash (Join-Path $Prefix 'bin\retype.exe')) -eq (Hash $Binary) -and
		(Hash $InstalledReview) -eq (Hash $Review))
	$Shortcut = Join-Path $Programs 'retype.lnk'
	$shell = New-Object -ComObject Shell.Application
	try {
		$folder = $shell.NameSpace($Programs); $item = $folder.ParseName('retype.lnk')
		Check 'Native shell sees the publisher AppUserModelID on the private shortcut' ($item.ExtendedProperty('System.AppUserModel.ID') -ceq $AppId)
		[Runtime.InteropServices.Marshal]::ReleaseComObject($item) | Out-Null
		[Runtime.InteropServices.Marshal]::ReleaseComObject($folder) | Out-Null
	} finally { [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null }
	[IO.File]::WriteAllText($SourceAsset, 'asset B'); Pack-Release 'update'
	$env:RETYPE_STARTUP = 'enable'; & $Installer
	Check 'Startup is explicitly enabled with existing daemon start and quoted paths' ($Run.Value.EndsWith(' daemon start') -and $Run.Value.StartsWith('"' + (Join-Path $Prefix 'bin\retype.exe') + '"'))
	$env:RETYPE_STARTUP = 'preserve'; & $Installer
	Check 'Update preserves prior startup opt-in and nested share state in place' ($null -ne $Run -and
		[IO.File]::ReadAllText((Join-Path $State 'jobs.jsonl')) -ceq 'retained user data: jobs.jsonl')
	$env:RETYPE_STARTUP = 'disable'; & $Installer
	Check 'Startup can be explicitly disabled without purging watch data' ($null -eq $Run -and (Test-Path (Join-Path $State 'watches.toml')))

	[IO.File]::WriteAllText($SourceAsset, 'asset C'); Pack-Release 'failure-cases'
	$previous = Installed-Snapshot
	foreach ($kind in @('binary', 'review', 'asset', 'receipt')) {
		$script:FailPublication = $kind
		Refused $kind "Simulated $kind publication failure"
		Check "$kind failure restores exact previous files, receipt, shortcut and user integration" ((Installed-Snapshot) -ceq $previous)
	}
	$script:FailIntegration = $true
	Refused 'identity' 'Simulated notification-identity publication failure'
	Check 'Identity failure rolls back both files and user integration' ((Installed-Snapshot) -ceq $previous)
	$env:RETYPE_STATE_DIR = Join-Path $Prefix 'share\retype'
	Refused 'state-overlap' 'overlaps configured user data'
	Check 'State under managed share refuses overlapping update without changing bytes' ((Installed-Snapshot) -ceq $previous)
	$env:RETYPE_STATE_DIR = $State

	$registryBefore = Clone $Registry
	$Registry[$UriKey] = @([ordered]@{ Name = ''; Values = @([ordered]@{ Name = ''; Kind = 'String'; Value = 'foreign handler' }) })
	$foreign = Installed-Snapshot
	Refused 'foreign-uri' 'foreign or changed URI registration'
	Check 'Foreign URI definition is never replaced' ((Installed-Snapshot) -ceq $foreign)
	$Registry = @{}; foreach ($property in $registryBefore.PSObject.Properties) { $Registry[$property.Name] = $property.Value }
	$receiptPath = Join-Path $Prefix '.retype-install.json'
	$receiptBytes = [IO.File]::ReadAllBytes($receiptPath)
	$forged = [Text.Encoding]::UTF8.GetString($receiptBytes).TrimStart([char]0xfeff) | ConvertFrom-Json
	$forged.Files += [pscustomobject]@{ Path = 'share/retype/../../user-config.toml'; Sha256 = Hash $Config }
	$forged | ConvertTo-Json -Depth 16 | Set-Content $receiptPath -Encoding UTF8
	$env:RETYPE_ACTION = 'remove'
	Refused 'forged-inventory' 'Invalid installed-file inventory entry'
	Check 'Forged receipt cannot remove configuration or executable' ((Test-Path $Config) -and (Hash (Join-Path $Prefix 'bin\retype.exe')) -eq (Hash $Binary))
	[IO.File]::WriteAllBytes($receiptPath, $receiptBytes)
	$installedBinary = Join-Path $Prefix 'bin\retype.exe'
	[IO.File]::WriteAllText($installedBinary, 'synthetic user configuration, not an executable')
	Copy-Item $installedBinary (Join-Path $Report 'forged-bin-user-data.txt')
	$forged = [Text.Encoding]::UTF8.GetString($receiptBytes).TrimStart([char]0xfeff) | ConvertFrom-Json
	foreach ($file in $forged.Files) { if ($file.Path -eq 'bin/retype.exe') { $file.Sha256 = Hash $installedBinary } }
	$forged | ConvertTo-Json -Depth 16 | Set-Content $receiptPath -Encoding UTF8
	Refused 'forged-bin-data' 'Not a Windows executable'
	Check 'A forged hash cannot authorize removal of non-executable user data' ([IO.File]::ReadAllText($installedBinary) -ceq 'synthetic user configuration, not an executable')
	Copy-Item -LiteralPath $Binary -Destination $installedBinary -Force
	[IO.File]::WriteAllBytes($receiptPath, $receiptBytes)
	$env:RETYPE_ACTION = 'install'
	$sumsBytes = [IO.File]::ReadAllBytes($Sums)
	[IO.File]::AppendAllText($Sums, "$(Hash $Archive)  $Name.tar.gz`n")
	Copy-Item $Sums (Join-Path $Report 'duplicate-SHA256SUMS')
	Refused 'duplicate-checksum' 'exactly one valid checksum'
	Check 'Duplicate checksum leaves installation exact' ((Installed-Snapshot) -ceq $previous)
	[IO.File]::WriteAllBytes($Sums, $sumsBytes)
	Copy-Item $Archive (Join-Path $Report 'before-duplicate-archive.tar.gz')
	& tar.exe -czf $Archive -C $Temp $Name $Name
	if ($LASTEXITCODE -ne 0) { throw 'Could not assemble the duplicate-member fixture' }
	[IO.File]::WriteAllText($Sums, "$(Hash $Archive)  $Name.tar.gz`n")
	Copy-Item $Archive (Join-Path $Report 'duplicate-archive.tar.gz')
	Refused 'duplicate-archive' 'Unsafe or duplicate archive member'
	Check 'Duplicate archive members refuse before publication' ((Installed-Snapshot) -ceq $previous)
	Pack-Release 'after-duplicate-archive'
	[IO.File]::WriteAllBytes($SourceBinary, [byte[]](0, 1, 2, 3)); Pack-Release 'invalid-executable'
	Refused 'invalid-executable' 'Not a Windows executable'
	Check 'Invalid executable leaves original installation exact' ((Installed-Snapshot) -ceq $previous)
	Copy-Item -LiteralPath $Binary -Destination $SourceBinary -Force
	Pack-Release 'restored-release'

	$forgedData = Join-Path $Prefix 'share\retype\packaging\user-data\recovery\original.bin'
	New-Item -ItemType Directory -Path (Split-Path -Parent $forgedData) -Force | Out-Null
	[IO.File]::WriteAllText($forgedData, 'user original, never receipt-authorized for removal')
	$forged = [Text.Encoding]::UTF8.GetString($receiptBytes).TrimStart([char]0xfeff) | ConvertFrom-Json
	$forged.Files += [pscustomobject]@{ Path = 'share/retype/packaging/user-data/recovery/original.bin'; Sha256 = Hash $forgedData }
	$forged | ConvertTo-Json -Depth 16 | Set-Content $receiptPath -Encoding UTF8
	$env:RETYPE_ACTION = 'remove'; $script:FailPublication = 'removal'
	$previousRemoval = Installed-Snapshot
	Refused 'removal' 'Simulated removal publication failure'
	Check 'Removal failure preserves exact installation and integration' ((Installed-Snapshot) -ceq $previousRemoval)
	& $Installer
	Check 'Removal removes the two executables and owned URI/startup/shortcut only' (-not (Test-Path (Join-Path $Prefix 'bin\retype.exe')) -and
		-not (Test-Path $InstalledReview) -and -not $Registry.ContainsKey($UriKey) -and $null -eq $Run -and -not (Test-Path $Shortcut))
	Check 'Removal restores only the known pre-existing plain notification identity' ((Snapshot @($Registry[$IdentityKey])) -ceq (Snapshot $plain))
	Check 'Even forged share inventory cannot authorize user-data deletion' ([IO.File]::ReadAllText($forgedData) -ceq 'user original, never receipt-authorized for removal')
	Check 'Configuration, watches, journal and recovery originals remain byte-exact' ([IO.File]::ReadAllText($Config) -ceq 'user configuration, never overwritten' -and
		[IO.File]::ReadAllText((Join-Path $State 'recovery/original.bin')) -ceq 'retained user data: recovery/original.bin' -and
		[IO.File]::ReadAllText((Join-Path $State 'watches.toml')) -ceq 'retained user data: watches.toml' -and
		[IO.File]::ReadAllText((Join-Path $State 'jobs.jsonl')) -ceq 'retained user data: jobs.jsonl')
	Check 'PATH removes only the installer-owned token and preserves empty entries' ($UserPath -ceq 'C:\first;;C:\last')
	$retired = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
	Check 'Removal retains a retired receipt without purge authority' (-not $retired.Installed -and -not $retired.AddedPath)
	$env:RETYPE_ACTION = 'install'
	& $Installer
	Check 'Reinstall through mocked verification preserves retired-prefix state and shared data' ((Hash (Join-Path $Prefix 'bin\retype.exe')) -eq (Hash $Binary) -and
		[IO.File]::ReadAllText($forgedData) -ceq 'user original, never receipt-authorized for removal' -and
		[IO.File]::ReadAllText((Join-Path $State 'watches.toml')) -ceq 'retained user data: watches.toml')
	$backups = @(Get-ChildItem (Join-Path $Prefix 'share') -Directory -Filter 'retype-backup-*')
	Check 'Previous executable and integration backups are persistent' (@($backups | Where-Object { Test-Path (Join-Path $_.FullName 'retype.exe') }).Count -gt 0 -and
		@($backups | Where-Object { Test-Path (Join-Path $_.FullName 'removed-retype-review.exe') }).Count -gt 0 -and
		@($backups | Where-Object { Test-Path (Join-Path $_.FullName 'integration.json') }).Count -gt 0)
	@{ Checks = $Checks.Count; Revision = $revision; BinarySha256 = Hash $Binary; Result = 'passed'; Scope = 'Synthetic, not publisher trust or desktop/session qualification';
		Cleanup = 'Private HKCU child removed after snapshot; files, backups, failed attempts and source snapshots retained' } |
		ConvertTo-Json | Set-Content (Join-Path $Report 'result.json') -Encoding UTF8
	Write-Host "Windows installer tests passed; $($Checks.Count) checks; reports and fixture retained: $Report"
} catch {
	@{ Result = 'failed'; Error = $_.ToString(); Checks = $Checks.Count; Scope = 'Synthetic'; RetainedFixture = $Temp } |
		ConvertTo-Json | Set-Content (Join-Path $Report 'result.json') -Encoding UTF8
	throw
} finally {
	foreach ($variable in $variables) { [Environment]::SetEnvironmentVariable($variable, $environment[$variable], 'Process') }
	Stop-Transcript | Out-Null
}
