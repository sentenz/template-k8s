# Public verification fixture

Unmodified Cosign v3.0.2 release assets, downloaded from:

- https://github.com/sigstore/cosign/releases/download/v3.0.2/cosign_checksums.txt
- https://github.com/sigstore/cosign/releases/download/v3.0.2/cosign_checksums.txt.sigstore.json

Upstream project: https://github.com/sigstore/cosign (Apache-2.0).
Expected signer: `keyless@projectsigstore.iam.gserviceaccount.com`.
Expected issuer: `https://accounts.google.com`.

These identities are test-only and are never added to production policy. Tests
use Cosign's authenticated public TUF trust; they need network access on an
uncached runner. The positive control must succeed before negative tests run.
