# Installed-release trust helpers

These helpers always require publisher trust. They do not select preview mode, fetch trust material, install tools, import certificates, change keychains, create an identity or publish artifacts. Technical implementation approval is not permission to use a signing key or certificate store.

## Installer embedding

Copy the complete column-zero `# BEGIN RETYPE_RELEASE_TRUST` / `# END RETYPE_RELEASE_TRUST` block from `verify.sh` or `verify.ps1`. Unix installers additionally include `RETYPE_MACOS_TRUST` from `verify-macos.sh`; Windows installers include `RETYPE_WINDOWS_TRUST` from `verify-windows.ps1`. Internal functions inside each block are part of that block's closure. Parameter/CLI wrappers outside the markers are not embedded.

Generate a fresh standalone installer before generating checksums or signing any installer:

```sh
python3 scripts/embed-trust.py packaging/install.sh /approved/fresh/install.sh
python3 scripts/embed-trust.py packaging/install.ps1 /approved/fresh/install.ps1
python3 scripts/embed-trust.py --check packaging/install.sh
python3 scripts/embed-trust.py --check packaging/install.ps1
```

The embedder refuses missing/duplicate/malformed markers and occupied output paths. It copies canonical code, not publisher pins; independently approved pins must already be in the trusted installer or be an explicit trusted-user input. Never run a release-downloaded bootstrap helper or obtain its trust key from the same unauthenticated release. Normal return/exit 0 means only the requested check succeeded. Explicit refusals use `retype trust:`; native tool and filesystem exceptions also refuse, never downgrade.

## Before extraction

```sh
retype_verify_release "$archive" "$checksums" "$signature" "$approved_minisign_public_key"
# Separately trusted source-tree CLI has the same four arguments:
bash packaging/trust/verify.sh "$archive" "$checksums" "$signature" "$approved_minisign_public_key"
```

```powershell
Assert-RetypeReleaseTrust -Archive $Archive -Checksums $Checksums -Signature $Signature -PublicKey $ApprovedPublicKey
# Separately trusted source-tree CLI accepts identical named arguments:
& ./packaging/trust/verify.ps1 -Archive $Archive -Checksums $Checksums -Signature $Signature -PublicKey $ApprovedPublicKey
```

An independently trusted installed minisign verifies `SHA256SUMS.minisig` over the exact final SHA256SUMS bytes. The key argument is its 56-character public-key value, not a path or a key discovered in an artifact. The parser permits SHA256SUMS text/binary records with LF or CRLF, requires lowercase SHA-256 and safe ASCII basenames, rejects malformed and case-colliding/duplicate entries, and selects the exact case-sensitive archive basename. Hashing follows successful signature verification. Missing keys, files, tools, valid signatures or matching digests refuse.

Inputs must be regular non-link files in caller-owned private staging. These helpers do not extract or structurally validate tar archives, prevent later staging modification, or authorize installation mutation. Platform installers must separately refuse unsafe roots, traversal, links/special files, duplicate members and unsupported archive formats before extracting into an empty private directory. All extracted executable code remains forbidden until the applicable native check succeeds.

## After authenticated extraction

Windows checks each executed executable or script, including integration scripts, before running it:

```powershell
Assert-RetypeWindowsTrust -Path $StagedPath -PublisherCertificateSha256 $ApprovedLeafCertificateSha256
# verify-windows.ps1 accepts identical named arguments
```

Require embedded Authenticode, Windows trust status Valid, a timestamp certificate and the independently approved SHA-256 hash of the signer certificate's public DER bytes. This is not a hash of the executable. The native signer additionally enforces file/timestamp SHA256 and RFC 3161 timestamping through SignTool. The provisional pin contract assumes a stable certificate; Azure Trusted Signing requires an approved authenticated per-release pin or separately human-approved publisher policy before support is added. No ad hoc subject matching or provider framework is supplied. A tar.gz is not Authenticode-signable; its entire contents are authenticated by the detached manifest.

macOS checks both the app and the CLI explicitly, because Resources binaries are not necessarily recognized as nested code:

```sh
retype_verify_macos "$app" Contents/Resources/retype "$approved_team_id" \
  com.lapilliworks.retype.cli com.lapilliworks.retype.cli
# verify-macos.sh accepts the same five arguments
```

Require Apple Developer ID Application, the approved Team ID/code identifiers, strict code integrity, hardened runtime and a secure timestamp on app and CLI. The bundle executable is `Contents/MacOS/retype-notifier`. The full verifier requires the native codesign notarisation predicate and an uncached `spctl` assessment with source `Notarized Developer ID`; disabled/override allow policy is not sufficient. Installation needs trusted minisign and built-in codesign/plutil/spctl and a SHA256 utility, not Python, an SDK or xcrun. The separately distributed `bin/retype` must byte-match the final signed `Contents/Resources/retype` before installation mutation; the platform owner checks that equality.

## Signing order and authorization

On approved fresh staging only: build the platform artifacts, sign Windows files or sign/notarise/staple the macOS app, copy its final signed CLI to `bin/retype`, assemble the exact archives and generated installers, compute final SHA256SUMS, sign that manifest last, reverify and qualify the exact signed archives natively. The macOS native build job must additionally validate stapling with xcrun on the exact packaged/extracted bundle before signing the final archive manifest; a pre-archive app check alone does not prove the ticket survived packaging.

These installed-tool wrappers require separate authorization before real signing. No signing inputs are configured or discovered for the caller.

```sh
# Linux release assembly: directory, existing private-key path, approved public-key value
bash scripts/sign-release.sh "$final_release_directory" "$existing_signing_key_path" "$approved_public_key"
# Native macOS: app, CLI relative path, Team, app ID, CLI ID, existing identity, existing profile, fresh output
bash scripts/sign-macos.sh "$unsigned_app" Contents/Resources/retype "$approved_team_id" \
  com.lapilliworks.retype.cli com.lapilliworks.retype.cli \
  "$existing_developer_id_identity" "$existing_notarytool_profile" "$fresh_output_directory"
```

```powershell
# Provisional stable certificate in CurrentUser/My; SHA1 is only SignTool's certificate selector
& ./scripts/sign-windows.ps1 -UnsignedPath $UnsignedFiles -OutputDirectory $FreshOutputDirectory `
  -SignTool $ApprovedInstalledSignTool -CertificateThumbprint $ApprovedSha1CertificateSelector `
  -PublisherCertificateSha256 $ApprovedLeafCertificateSha256 -TimestampUrl $ApprovedHttpsRfc3161Url
```

The manifest signer verifies every listed asset and requires both installers and at least one archive, signs an immutable manifest snapshot, verifies the signature/assets again and exclusively creates `SHA256SUMS.minisig`. Its private staging is retained; a signing key is read only by minisign and is never copied. macOS signs the CLI then the app on a fresh copy, notarises a ditto ZIP using the existing profile, requires Accepted, staples/validates and runs the complete native verifier. Windows signs fresh file copies with `/fd SHA256 /tr <approved HTTPS URL> /td SHA256`, requires successful `verify /pa /all /tw`, then checks the approved certificate pin and native timestamped signature. Originals and failed staging remain intact. Missing inputs/tools or occupied outputs refuse. Checksums and GitHub attestations alone are preview evidence, not publisher signatures.

## Checks and limits

```sh
python3 tests/trust.py --report /approved/fresh/trust-report
# On an approved ordinary-user native Windows test host:
pwsh -NoProfile -File tests/trust.ps1 -Report C:\approved\fresh\trust-report
```

The Python check uses invalid non-key bytes and tool doubles only, retaining fixtures, source snapshots and logs outside Cargo target. It tests verifier/signing command wiring, manifest parsing/refusals, native-policy adapter predicates, original-copy preservation and embedding/no-replacement behavior. The Windows check additionally exercises a real unsigned-script refusal, then uses invalid DER/non-key objects and tool doubles; it does not use a certificate store or claim a publisher positive. It never establishes real publisher cryptography, native Authenticode/Developer ID/notarisation or an installed-release pass. Publisher public material, signing operator/certificate/Team/notary access, trusted tools and exact supported native artifact qualification remain mandatory separate gates. No test key, pin, policy bypass or production default is introduced.
