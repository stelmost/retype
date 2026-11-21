# Embed the complete marked block in the independently trusted PowerShell installer.
param(
	[Alias('Archive')][string]$RetypeTrustArchive,
	[Alias('Checksums')][string]$RetypeTrustChecksums,
	[Alias('Signature')][string]$RetypeTrustSignature,
	[Alias('PublicKey')][string]$RetypeTrustPublicKey
)

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

if ($MyInvocation.InvocationName -ne '.') {
	Assert-RetypeReleaseTrust -Archive $RetypeTrustArchive -Checksums $RetypeTrustChecksums `
		-Signature $RetypeTrustSignature -PublicKey $RetypeTrustPublicKey
}
