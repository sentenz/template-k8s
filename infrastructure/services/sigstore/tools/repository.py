"""Sign public TUF targets on the operator host. Never export the role keys."""
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from securesystemslib.signer import CryptoSigner
from tuf.api.metadata import Metadata, MetaFile, Root, Snapshot, TargetFile, Targets, Timestamp


def publish(state, source):
    keys = state / "roles"
    meta = state / "metadata"
    targets = state / "targets"
    for directory in (keys, meta, targets):
        directory.mkdir(exist_ok=True)
    root_path = meta / "1.root.json"
    signers = {}
    for role in ("root", "targets", "snapshot", "timestamp"):
        path = keys / role
        if not path.exists() and not root_path.exists():
            key = Ed25519PrivateKey.generate()
            with path.open("xb") as out:
                out.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                            serialization.NoEncryption()))
        signers[role] = CryptoSigner(serialization.load_pem_private_key(path.read_bytes(), None))
    now = datetime.now(timezone.utc)
    if root_path.exists():
        root = Metadata.from_file(str(root_path))
        for role, signer in signers.items():
            if signer.public_key.keyid not in root.signed.roles[role].keyids:
                raise ValueError(f"restore the original {role} role key")
        if root.signed.expires <= now:
            raise ValueError("expired root, perform a signed root rotation")
    else:
        root = Metadata(Root(expires=now + timedelta(days=365), consistent_snapshot=False))
        for role, signer in signers.items():
            root.signed.add_key(signer.public_key, role)
        root.sign(signers["root"])
        root.to_file(str(root_path))
    # timestamp is published last. Each refresh advances all online roles.
    version = max((Metadata.from_file(str(p)).signed.version for p in meta.glob("*.json")), default=0) + 1
    target_role = Targets(version=version, expires=now + timedelta(days=30))
    for p in source.iterdir():
        data = p.read_bytes()
        target_role.targets[p.name] = TargetFile.from_data(p.name, data, ["sha256"])
        (targets / p.name).write_bytes(data)
    snapshot = Snapshot(version=version, expires=now + timedelta(days=14))
    timestamp = Timestamp(version=version, expires=now + timedelta(days=7))
    for name, role in (("targets", target_role), ("snapshot", snapshot), ("timestamp", timestamp)):
        md = Metadata(role)
        md.sign(signers[name])
        data = md.to_bytes()
        path = meta / (name + ".json")
        path.with_suffix(".tmp").write_bytes(data)
        path.with_suffix(".tmp").replace(path)
        info = MetaFile.from_data(version, data, ["sha256"])
        if name == "targets":
            snapshot.meta["targets.json"] = info
        elif name == "snapshot":
            timestamp.snapshot_meta = info
    (meta / "root.json").write_bytes(root_path.read_bytes())


if __name__ == "__main__":
    os.umask(0o077)
    publish(*(Path(arg) for arg in sys.argv[1:]))
