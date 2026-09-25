//
//  compat_runner.swift
//  eul (linux)
//
//  macOS only. Seals snapshots and derives keys with the exact primitives
//  the eul app ships (CommonCrypto PBKDF2 + CryptoKit HKDF/ChaChaPoly) so
//  the C implementation can be checked against them. Modes:
//
//    swift compat_runner.swift keys  SECRET          -> topic hex, seal hex
//    swift compat_runner.swift seal  SECRET JSON     -> combined hex
//    swift compat_runner.swift open  SECRET HEX      -> plaintext
//

import CommonCrypto
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: compat_runner.swift (keys|seal|open) SECRET [JSON|HEX]\n", stderr)
    exit(2)
}

let mode = args[1]
let secret = args[2]

let salt = Array("eul-peer".utf8)
var master = [UInt8](repeating: 0, count: 32)
CCKeyDerivationPBKDF(
    CCPBKDFAlgorithm(kCCPBKDF2),
    secret, secret.utf8.count,
    salt, salt.count,
    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
    &master, master.count
)
let ikm = SymmetricKey(data: master)

func derive(_ label: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, info: Data(label.utf8), outputByteCount: 32)
}

func hex(of data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func keyData(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

switch mode {
case "keys":
    // the topic uses the first 16 bytes, mirroring PeerDiscoveryStore
    print(hex(of: keyData(derive("topic")).prefix(16)))
    print(hex(of: keyData(derive("seal"))))

case "seal":
    guard args.count >= 4, let json = args[3].data(using: .utf8) else {
        fputs("seal needs JSON\n", stderr)
        exit(2)
    }
    let sealed = try ChaChaPoly.seal(json, using: derive("seal"))
    print(hex(of: sealed.combined))

case "open":
    guard args.count >= 4 else {
        fputs("open needs hex\n", stderr)
        exit(2)
    }
    let hexString = args[3]
    var combined = Data()
    var index = hexString.startIndex
    while index < hexString.endIndex {
        let next = hexString.index(index, offsetBy: 2)
        combined.append(UInt8(hexString[index..<next], radix: 16) ?? 0)
        index = next
    }
    do {
        let box = try ChaChaPoly.SealedBox(combined: combined)
        let plain = try ChaChaPoly.open(box, using: derive("seal"))
        print(String(data: plain, encoding: .utf8) ?? "<not utf8>")
    } catch {
        fputs("swift open failed: \(error)\n", stderr)
        exit(1)
    }

default:
    fputs("unknown mode \(mode)\n", stderr)
    exit(2)
}
