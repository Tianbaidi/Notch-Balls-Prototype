// Verifies against the application's PUBLIC key; never accesses the Keychain.
import Foundation
import CryptoKit

let args = CommandLine.arguments
guard args.count == 4,
      let signature = Data(base64Encoded: args[2]),
      let publicKeyData = Data(base64Encoded: args[3]) else {
    fputs("Usage: verify_signature <archive> <signature> <public-key>\n", stderr)
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: data) else {
        fputs("Ed25519 signature does not match archive and embedded public key\n", stderr)
        exit(1)
    }
    print("Ed25519 signature verified against application public key")
} catch {
    fputs("Signature verification failed: \(error)\n", stderr)
    exit(1)
}
