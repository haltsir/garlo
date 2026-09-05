# Code signing

Garlo is signed with a stable, self-signed identity named `Garlo Signing` in the owner's login keychain. Not ad-hoc, because macOS keys privacy grants (the "access files on a removable volume" prompt the layout probe triggers) to the signature: an ad-hoc signature changes with every build and the prompt comes back after each rebuild. Garlo never reuses another project's identity. Notarisation and Developer ID can be added later without changing this layout.

## The identity

- Common name: `Garlo Signing`, organization `Strahil Minev`.
- RSA 2048, valid 10 years from 2026-09-05.
- Extensions: `keyUsage = digitalSignature` (critical), `extendedKeyUsage = codeSigning` (critical), `basicConstraints = CA:FALSE` (critical).
- Stored in `~/Library/Keychains/login.keychain-db` with `/usr/bin/codesign` granted key access; user-domain trust set for the code-signing policy.

## How it was created (reproducible)

Created 2026-09-05 with the CLI equivalent of Keychain Access's Certificate Assistant. To recreate (only if the identity is lost; a new certificate is a new identity and saved permissions reset):

```sh
cat > ext.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Garlo Signing
O = Strahil Minev
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:FALSE
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config ext.cnf
openssl pkcs12 -export -out identity.p12 -inkey key.pem -in cert.pem -passout pass:CHOOSE_A_PASSPHRASE
security import identity.p12 -k ~/Library/Keychains/login.keychain-db -P CHOOSE_A_PASSPHRASE -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
```

The `add-trusted-cert` step opens a macOS authorization dialog; approve it. Verify with `security find-identity -p codesigning -v`. Delete `key.pem` and `identity.p12` after importing.

## Backup

Export once from Keychain Access: My Certificates > Garlo Signing > Export as `.p12` with a strong passphrase, stored outside this repository.

## How builds are signed

`make app` signs `Garlo.app` with `Garlo Signing` when the identity is in the keychain (`SIGN_IDENTITY` in the Makefile), and ad-hoc (`-`) otherwise, for example on another machine. Override with `make app SIGN_IDENTITY=-`.
