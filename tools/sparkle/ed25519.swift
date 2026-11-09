// Ed25519 helper for CryTerm's Sparkle update feed.
//
//   swift tools/sparkle/ed25519.swift generate <private-key-out-file>
//       Writes a new base64 private key (32-byte seed) to the file (mode 0600)
//       and prints the base64 public key for SUPublicEDKey.
//   swift tools/sparkle/ed25519.swift public
//       Prints the public key for the private key in $SPARKLE_ED_PRIVATE_KEY.
//   swift tools/sparkle/ed25519.swift sign <file>
//       Prints the base64 signature of <file> made with $SPARKLE_ED_PRIVATE_KEY
//       (Sparkle's sparkle:edSignature).
//   swift tools/sparkle/ed25519.swift verify <file> <base64-signature> <base64-public-key>
//       Exits 0 only if the signature is valid.
//
// The private key is read from the environment, never from the command line, so
// it does not appear in process listings or CI logs.

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func privateKeyFromEnvironment() -> Curve25519.Signing.PrivateKey {
    guard let encoded = ProcessInfo.processInfo.environment["SPARKLE_ED_PRIVATE_KEY"],
          let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("SPARKLE_ED_PRIVATE_KEY is not set or is not base64")
    }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
        fail("SPARKLE_ED_PRIVATE_KEY is not a 32-byte Ed25519 seed")
    }
    return key
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("Cannot read \(path)")
    }
    return data
}

let args = CommandLine.arguments
switch (args.count, args.count > 1 ? args[1] : "") {
case (3, "generate"):
    let path = args[2]
    guard !FileManager.default.fileExists(atPath: path) else {
        fail("\(path) already exists; refusing to overwrite a key")
    }
    let key = Curve25519.Signing.PrivateKey()
    let ok = FileManager.default.createFile(atPath: path,
                                            contents: (key.rawRepresentation.base64EncodedString() + "\n").data(using: .utf8),
                                            attributes: [.posixPermissions: 0o600])
    guard ok else {
        fail("Cannot write \(path)")
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case (2, "public"):
    print(privateKeyFromEnvironment().publicKey.rawRepresentation.base64EncodedString())
case (3, "sign"):
    let signature = try! privateKeyFromEnvironment().signature(for: readFile(args[2]))
    print(signature.base64EncodedString())
case (5, "verify"):
    guard let signature = Data(base64Encoded: args[3]),
          let publicKeyData = Data(base64Encoded: args[4]),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
        fail("Malformed signature or public key")
    }
    guard publicKey.isValidSignature(signature, for: readFile(args[2])) else {
        fail("Signature is NOT valid")
    }
    print("Signature valid")
default:
    fail("usage: ed25519.swift generate <out> | public | sign <file> | verify <file> <sig> <pubkey>")
}
