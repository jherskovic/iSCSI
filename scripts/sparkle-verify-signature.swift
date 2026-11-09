// Check a Sparkle EdDSA signature the way an installed copy of the app will.
//
//   xcrun swift scripts/sparkle-verify-signature.swift <SUPublicEDKey> <edSignature> <file>
//
// Exits 0 when <edSignature> is a valid Ed25519 signature of <file>'s bytes
// under <SUPublicEDKey>, 1 when it is not, 2 on bad input. Both keys are
// base64, exactly as they appear in Info.plist and in sign_update's output.
//
// scripts/release.sh runs this after sign_update and before anything is
// published, with the key taken from the app it just built. sign_update signs
// with whatever private key it is handed, so a wrong SPARKLE_ED_PRIVATE_KEY, or
// a keychain holding some other project's key, produces a signature that looks
// fine and that every installed copy rejects. Sparkle reports that as a failed
// update with no reason given, and nothing else in the pipeline would notice.
//
// Sparkle signs the archive's raw bytes with plain Ed25519, no prehash, which
// is what CryptoKit's Curve25519.Signing verifies.
import CryptoKit
import Foundation

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = CommandLine.arguments.dropFirst()
guard args.count == 3 else {
    fail(2, "usage: sparkle-verify-signature.swift <SUPublicEDKey> <edSignature> <file>")
}
let (keyText, signatureText, path) = (args[args.startIndex], args[args.startIndex + 1], args[args.startIndex + 2])

guard let keyBytes = Data(base64Encoded: keyText), keyBytes.count == 32 else {
    fail(2, "the public key is not base64 of 32 bytes: \(keyText)")
}
guard let signature = Data(base64Encoded: signatureText), signature.count == 64 else {
    fail(2, "the signature is not base64 of 64 bytes: \(signatureText)")
}
let key: Curve25519.Signing.PublicKey
do {
    key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
} catch {
    fail(2, "not an Ed25519 public key: \(error)")
}
guard let data = FileManager.default.contents(atPath: path) else {
    fail(2, "cannot read \(path)")
}

if key.isValidSignature(signature, for: data) {
    print("  ok  EdDSA signature verifies against \(keyText.prefix(12))… over \(data.count) bytes")
    exit(0)
}
fail(1, "the EdDSA signature does NOT verify against \(keyText) over \(data.count) bytes of \(path)")
