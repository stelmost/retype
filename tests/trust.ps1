# Native Windows unsigned refusal plus synthetic adapters; no signing identity or store changes.
param([string]$Report)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
	throw 'Native Windows is required; missing native checks are not passes'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	throw 'Use an ordinary unelevated user for these owned fixtures'
}
if (-not $Report -or -not [IO.Path]::IsPathRooted($Report) -or (Test-Path -LiteralPath $Report)) {
	throw 'A fresh absolute persistent report directory is required'
}
$Root = Split-Path $PSScriptRoot -Parent
$Report = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Report)
$target = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $Root 'target' }
if ($Report.StartsWith($target.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
	throw 'Reports must be outside Cargo target'
}
New-Item -ItemType Directory -Path $Report | Out-Null
$sources = @('packaging\trust\verify.ps1', 'packaging\trust\verify-windows.ps1',
	'scripts\sign-windows.ps1', 'tests\trust.ps1')
@{
	utc = [DateTime]::UtcNow.ToString('o'); source = $Root; revision = (& git -C $Root rev-parse HEAD)
	os = [Environment]::OSVersion.ToString(); architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
	user = $identity.Name; elevated = $false; fixtures = $Report; powershell = $PSVersionTable.PSVersion.ToString()
	scope = 'One real unsigned-file refusal; remaining checks use invalid non-key/certificate bytes and tool doubles'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Report 'metadata.json')
foreach ($source in $sources) {
	$destination = Join-Path (Join-Path $Report 'source') $source
	New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
	Copy-Item -LiteralPath (Join-Path $Root $source) -Destination $destination
}
$results = @()

function Test-TrustCase {
	param([string]$Name, [scriptblock]$Action, [bool]$Succeeds = $true, [string]$Scope = 'synthetic')
	$accepted = $false
	try {
		& $Action *> (Join-Path $Report "$Name.log")
		$accepted = $true
	} catch {
		$_.Exception.Message | Add-Content -LiteralPath (Join-Path $Report "$Name.log")
	}
	$passed = $accepted -eq $Succeeds
	$script:results += @{ case = $Name; scope = $Scope; passed = $passed }
	if (-not $passed) { throw "Unexpected trust result: $Name. All fixtures retained: $Report" }
}

try {
	foreach ($source in $sources) {
		$tokens = $null
		$errors = $null
		[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $source), [ref]$tokens, [ref]$errors) | Out-Null
		if ($errors.Count) { throw "PowerShell parse rejected $source`: $errors" }
	}
	. (Join-Path $Root 'packaging\trust\verify.ps1')
	. (Join-Path $Root 'packaging\trust\verify-windows.ps1')
	$Name = 'retype-v0.0.0-synthetic-x86_64-pc-windows-msvc.tar.gz'
	$fixture = Join-Path $Report 'unsigned.ps1'
	[IO.File]::WriteAllText($fixture, "Write-Output 'synthetic, never executed'`n")
	$before = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
	# This is deliberately invalid DER, not a certificate/key or publisher trust material.
	$raw = [byte[]](0, 1, 2, 3)
	$sha256 = [Security.Cryptography.SHA256]::Create()
	try { $Pin = [BitConverter]::ToString($sha256.ComputeHash($raw)).Replace('-', '') } finally { $sha256.Dispose() }
	Test-TrustCase 'native-unsigned-refusal' {
		Assert-RetypeWindowsTrust -Path $fixture -PublisherCertificateSha256 $Pin
	} $false 'native-refusal'
	$signature = [pscustomobject]@{ Status = 'Valid'; SignatureType = 'Authenticode'
		SignerCertificate = [pscustomobject]@{ RawData = $raw }; TimeStamperCertificate = [pscustomobject]@{ RawData = $raw } }
	function Get-AuthenticodeSignature {
		[CmdletBinding()] param([string]$LiteralPath)
		$script:signature
	}
	Test-TrustCase 'authenticode-adapter-positive' { Assert-RetypeWindowsTrust $fixture $Pin }
	Test-TrustCase 'publisher-pin-refusal' { Assert-RetypeWindowsTrust $fixture ('0' * 64) } $false
	Test-TrustCase 'missing-publisher-refusal' { Assert-RetypeWindowsTrust $fixture '' } $false
	$signature.TimeStamperCertificate = $null
	Test-TrustCase 'timestamp-refusal' { Assert-RetypeWindowsTrust $fixture $Pin } $false
	$signature.TimeStamperCertificate = [pscustomobject]@{ RawData = $raw }
	$signature.Status = 'HashMismatch'
	Test-TrustCase 'native-status-refusal' { Assert-RetypeWindowsTrust $fixture $Pin } $false
	$signature.Status = 'Valid'
	$signature.SignatureType = 'Catalog'
	Test-TrustCase 'catalog-refusal' { Assert-RetypeWindowsTrust $fixture $Pin } $false
	$signature.SignatureType = 'Authenticode'

	$bin = Join-Path $Report 'tool-doubles'
	New-Item -ItemType Directory -Path $bin | Out-Null
	[IO.File]::WriteAllText((Join-Path $bin 'minisign.cmd'), "@echo off`r`n" +
		"if not `"%~1`"==`"-V`" exit /b 64`r`nif not `"%~3`"==`"$('A' * 56)`" exit /b 64`r`n" +
		"if not exist `"%~7`" exit /b 1`r`nexit /b 0`r`n")
	$previousPath = $env:PATH
	$env:PATH = "$bin;$previousPath"
	$archive = Join-Path $Report $Name
	[IO.File]::WriteAllText($archive, 'Synthetic, not a tar archive')
	$digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
	$cases = @(
		@('manifest-positive', "$digest  $Name`n", $true),
		@('manifest-crlf', "$digest *$Name`r`n", $true),
		@('manifest-duplicate', "$digest  $Name`n$digest  $Name`n", $false),
		@('manifest-case-collision', "$digest  $Name`n$digest  $($Name.ToUpperInvariant())`n", $false),
		@('manifest-traversal', "$digest  $Name`n$digest  ../outside`n", $false),
		@('manifest-extra-cr', "$digest  $Name`r`r`n", $false),
		@('manifest-mismatch', "$('0' * 64)  $Name`n", $false)
	)
	foreach ($case in $cases) {
		$directory = Join-Path $Report $case[0]
		New-Item -ItemType Directory -Path $directory | Out-Null
		$sums = Join-Path $directory 'SHA256SUMS'
		$sig = Join-Path $directory 'SHA256SUMS.minisig'
		[IO.File]::WriteAllText($sums, $case[1])
		[IO.File]::WriteAllText($sig, 'SYNTHETIC-NOT-A-SIGNATURE')
		Test-TrustCase $case[0] { Assert-RetypeReleaseTrust $archive $sums $sig ('A' * 56) } $case[2]
	}
	Test-TrustCase 'missing-release-key' { Assert-RetypeReleaseTrust $archive $sums $sig '' } $false
	$signTool = Join-Path $bin 'signtool.cmd'
	[IO.File]::WriteAllText($signTool, @'
@echo off
if "%~1"=="verify" exit /b 0
if not "%~1"=="sign" exit /b 64
for %%a in (%*) do set "artifact=%%~a"
echo SYNTHETIC-NOT-A-SIGNATURE>>"%artifact%"
exit /b 0
'@)
	$output = Join-Path $Report 'signed-adapter-output'
	$arguments = @{ UnsignedPath = @($fixture); OutputDirectory = $output; SignTool = $signTool
		CertificateThumbprint = '0' * 40; PublisherCertificateSha256 = $Pin; TimestampUrl = 'https://timestamp.invalid' }
	Test-TrustCase 'signing-copy-adapter-positive' { & (Join-Path $Root 'scripts\sign-windows.ps1') @arguments }
	if ((Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash -cne $before) { throw 'Original fixture changed' }
	Test-TrustCase 'signing-no-replacement' { & (Join-Path $Root 'scripts\sign-windows.ps1') @arguments } $false
	$arguments.OutputDirectory = Join-Path $Report 'missing-selector-output'
	$arguments.CertificateThumbprint = ''
	Test-TrustCase 'signing-missing-selector' { & (Join-Path $Root 'scripts\sign-windows.ps1') @arguments } $false
} finally {
	if ($null -ne $previousPath) { $env:PATH = $previousPath }
	$results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Report 'results.json')
	@("Completed checks: $($results.Count); failed: $(($results | Where-Object { -not $_.passed }).Count)",
		'Real publisher positives remain BLOCKED; synthetic objects are not certificate trust',
		'All source/fixtures/logs retained; no cleanup or store changes') | Set-Content (Join-Path $Report 'summary.txt')
}
Write-Host "Windows refusal/adapter checks passed. No publisher positive. Report: $Report"
