"""Generate development credentials on first use. Secret files stay in .local."""
import json
import secrets
import sys
from pathlib import Path

import bcrypt

state = Path(sys.argv[1])
for name in ("dex", "registry"):
    path = state / (name + ".password")
    if not path.exists():
        with path.open("x") as f:
            f.write(secrets.token_urlsafe(32))
    digest = bcrypt.hashpw(path.read_bytes(), bcrypt.gensalt()).decode()
    if name == "registry":
        (state / "htpasswd").write_text(f"publisher:{digest}\n")
    else:
        config = {
            "issuer": "https://dex.sigstore.local",
            "storage": {"type": "sqlite3", "config": {"file": "/data/dex.db"}},
            "web": {"http": "0.0.0.0:5556"}, "telemetry": {"http": "0.0.0.0:5558"},
            "enablePasswordDB": True,
            "staticClients": [{"id": "sigstore", "name": "Cosign", "public": True,
                               "redirectURIs": ["http://localhost:5555/auth/callback"]}],
            "staticPasswords": [{"email": "developer@sigstore.local", "username": "developer",
                                 "userID": "b03f8d91-966b-4f63-9c62-6fa219b761fb", "hash": digest}],
        }
        (state / "dex.json").write_text(json.dumps(config))
