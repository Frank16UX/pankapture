#!/usr/bin/env bash
# Gives the release workflow (.github/workflows/release.yml) the signing
# identity, as two encrypted repository secrets. Run once, on the Mac that has
# "Pankapture Development" in its login keychain (see scripts/create-dev-cert.sh).
#
#   make ci-secrets
#
# Only that identity is exported (not the rest of the keychain). macOS asks
# for your login password to allow exporting its private key. The .p12 and
# its password exist only in a temporary folder, deleted on exit, and are
# never printed.
set -euo pipefail

NAME="${PK_SIGN_IDENTITY:-Pankapture Development}"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSWORD="$(uuidgen)"

cat > "$TMP/export.swift" <<'SWIFT'
import Foundation
import Security

let arguments = CommandLine.arguments
let (label, password, output) = (arguments[1], arguments[2], arguments[3])
let query: [String: Any] = [
    kSecClass as String: kSecClassIdentity,
    kSecMatchLimit as String: kSecMatchLimitAll,
    kSecReturnRef as String: true,
]
var result: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let identities = result as? [SecIdentity] else {
    FileHandle.standardError.write(Data("No identities found\n".utf8)); exit(1)
}
let matching = identities.first { identity in
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return false }
    return SecCertificateCopySubjectSummary(certificate) as String? == label
}
guard let identity = matching else {
    FileHandle.standardError.write(Data("\"\(label)\" not found in the keychain\n".utf8)); exit(1)
}
var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
parameters.passphrase = Unmanaged.passRetained(password as CFString)
var data: CFData?
let status = SecItemExport(identity, .formatPKCS12, [], &parameters, &data)
guard status == errSecSuccess, let data else {
    FileHandle.standardError.write(Data("Export failed (\(status))\n".utf8)); exit(1)
}
try (data as Data).write(to: URL(fileURLWithPath: output))
SWIFT

echo "▸ Exporting \"$NAME\" (macOS will ask to allow it)"
swift "$TMP/export.swift" "$NAME" "$PASSWORD" "$TMP/identity.p12"

echo "▸ Setting secrets on $REPO"
base64 -i "$TMP/identity.p12" | gh secret set PK_SIGNING_P12_BASE64 --repo "$REPO"
printf '%s' "$PASSWORD" | gh secret set PK_SIGNING_P12_PASSWORD --repo "$REPO"

echo "✓ The release workflow can now sign with \"$NAME\"."
