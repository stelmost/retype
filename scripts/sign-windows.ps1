# Provisional stable-certificate path only; no service/provider or identity discovery.
param(
	[string[]]$UnsignedPath,
	[string]$OutputDirectory,
	[string]$SignTool,
	[string]$CertificateThumbprint,
	[string]$PublisherCertificateSha256,
	[string]$TimestampUrl
)
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
	throw 'retype trust: native Windows signing is required'
}
if ($CertificateThumbprint -notmatch '\A[0-9A-Fa-f]{40}\z' -or
	$PublisherCertificateSha256 -notmatch '\A[0-9A-Fa-f]{64}\z') {
	throw 'retype trust: approved stable-certificate selector and publisher SHA256 pin are required'
}
$timestamp = $null
if (-not [Uri]::TryCreate($TimestampUrl, [UriKind]::Absolute, [ref]$timestamp) -or
	$timestamp.Scheme -cne 'https' -or -not $timestamp.Host -or $timestamp.UserInfo) {
	throw 'retype trust: approved HTTPS RFC 3161 timestamp URL is required'
}
if (-not $UnsignedPath -or -not $SignTool -or -not (Test-Path -LiteralPath $SignTool -PathType Leaf)) {
	throw 'retype trust: unsigned artifact paths and an approved installed SignTool are required'
}
if (-not $OutputDirectory -or -not [IO.Path]::IsPathRooted($OutputDirectory) -or
	$OutputDirectory.StartsWith('\\') -or (Test-Path -LiteralPath $OutputDirectory)) {
	throw 'retype trust: fresh absolute local signing output is required; no replacements'
}
$files = @()
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($path in $UnsignedPath) {
	$item = Get-Item -LiteralPath $path -ErrorAction Stop
	if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
		-not $names.Add($item.Name)) {
		throw 'retype trust: artifacts must be regular non-reparse files with unique basenames'
	}
	$files += $item
}
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'packaging\trust\verify-windows.ps1')
# Creation is exclusive. Failed copies, signatures and native checks remain available for inspection.
New-Item -ItemType Directory -Path $OutputDirectory -ErrorAction Stop | Out-Null
$staged = @()
foreach ($file in $files) {
	$destination = Join-Path $OutputDirectory $file.Name
	[IO.File]::Copy($file.FullName, $destination, $false)
	$staged += $destination
}
foreach ($path in $staged) {
	& $SignTool sign /sha1 $CertificateThumbprint /s My /fd SHA256 /tr $TimestampUrl /td SHA256 $path
	if ($LASTEXITCODE -ne 0) { throw 'retype trust: SignTool signing failed; original and output retained' }
	& $SignTool verify /pa /all /tw $path
	if ($LASTEXITCODE -ne 0) { throw 'retype trust: SignTool verification failed; original and output retained' }
	Assert-RetypeWindowsTrust -Path $path -PublisherCertificateSha256 $PublisherCertificateSha256
}
Write-Host "Publisher-signed artifacts verified; original inputs preserved: $OutputDirectory"
