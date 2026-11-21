# Embedded Authenticode is additional to the detached signature over the whole archive.
param(
	[Alias('Path')][string]$RetypeTrustPath,
	[Alias('PublisherCertificateSha256')][string]$RetypeTrustCertificateSha256
)

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

if ($MyInvocation.InvocationName -ne '.') {
	Assert-RetypeWindowsTrust -Path $RetypeTrustPath -PublisherCertificateSha256 $RetypeTrustCertificateSha256
}
