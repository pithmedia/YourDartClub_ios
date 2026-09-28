# Encryption inventory — 28 September 2026

The app uses Apple's URLSession for HTTPS, Security/Keychain for credentials and secure randomness, and Apple media APIs for AirPlay. No app-defined cryptographic algorithm is implemented.

Pinned Google Cast 4.8.3 was inspected in the device static framework with `nm`. TLS references resolve to Apple's SSLCreateContext/SSLHandshake/SSLRead/SSLWrite and certificate verification to SecTrust/SecKey. Its AES wrapper references CommonCrypto CCCryptorCreateWithMode/CCCryptorUpdate. No defined OpenSSL/BoringSSL, AES_, RSA_, EVP_, ChaCha or Sodium implementation symbols were found. The accompanying open-source licenses list Abseil, protobuf/nanoproto and Google Objective-C utilities. Protobuf serializes data; it does not encrypt it.

For this dependency set, App Store Connect build 3 was answered “None of the algorithms mentioned above”: encryption is accessed through Apple's operating system. Both app Info.plists now declare ITSAppUsesNonExemptEncryption=false. Reassess this inventory before changing crypto/network dependencies; this is not an assertion about future SDK versions.

References:
- https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations
- https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance

This inventory concerns the distributed iOS binary, not the separately hosted Laravel/Apple-verification server.
