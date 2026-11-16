#!/usr/bin/env python3
"""Signs dist/latest.json with the release key, when the repository has one.

    UPDATE_SIGNING_KEY   secret: the Ed25519 private key (PEM)
    UPDATE_PUBLIC_KEY    variable: its public key, 64 hex digits, built into Borne

The signed manifest is `{"signature":"<hex>",` followed by the manifest without its opening `{`;
the signature covers that manifest as it was (see core/src/update.rs, verify_manifest).
Builds made with UPDATE_PUBLIC_KEY refuse unsigned manifests, so a public key without its private
key stops the release here rather than leaving those builds unable to update.
"""
import os, subprocess, sys, tempfile

key, pub = os.environ.get("UPDATE_SIGNING_KEY", ""), os.environ.get("UPDATE_PUBLIC_KEY", "")
if not key and not pub:
    print("no release key: manifest left unsigned")
    sys.exit(0)
if not key or not pub:
    sys.exit("UPDATE_SIGNING_KEY and UPDATE_PUBLIC_KEY go together: set both or neither")

path = sys.argv[1] if len(sys.argv) > 1 else "dist/latest.json"
body = open(path, "rb").read().strip()
if not body.startswith(b"{") or body.startswith(b'{"signature"'):
    sys.exit("unexpected manifest")

with tempfile.TemporaryDirectory() as d:
    k, m, s = (os.path.join(d, n) for n in ("key.pem", "body", "sig"))
    with open(k, "w") as f:
        f.write(key)
    os.chmod(k, 0o600)
    open(m, "wb").write(body)
    subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", k, "-in", m, "-out", s], check=True)
    sig = open(s, "rb").read().hex()
    # The private key must be the public key's: checked here, not by clients failing later.
    der = subprocess.run(["openssl", "pkey", "-in", k, "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
    if der[-32:].hex() != pub.strip().lower():
        sys.exit("UPDATE_SIGNING_KEY does not match UPDATE_PUBLIC_KEY")

signed = b"{\"signature\":\"" + sig.encode() + b"\"," + body[1:]
open(path, "wb").write(signed)
# SHA256SUMS lists the manifest too: its line follows the signed file.
sums = os.path.join(os.path.dirname(path), "SHA256SUMS")
if os.path.exists(sums):
    import hashlib
    name = os.path.basename(path)
    lines = [l if not l.endswith("  " + name) else f"{hashlib.sha256(signed).hexdigest()}  {name}" for l in open(sums).read().splitlines()]
    open(sums, "w").write("\n".join(lines) + "\n")
print("manifest signed")
