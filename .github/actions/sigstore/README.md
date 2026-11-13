# Sigstore signing

This action installs pinned Cosign, signs with GitHub Actions OIDC (audience
`sigstore`), and requires verification of the exact certificate identity and
issuer. Image inputs must include a SHA-256 digest. File signatures cover the
actual bytes and produce adjacent `.sigstore.json` bundles containing signatures,
certificates, and transparency evidence. No persistent signing keys are used.

## Images

Grant `contents: read`, `packages: write`, and `id-token: write` to the signing
job. Keep read-only build jobs without OIDC permission. After the pinned
`sentenz/actions/docker` step with `id: docker-build`:

```yaml
- uses: ./.github/actions/sigstore
  with:
    image: ${{ steps.docker-build.outputs.image }}@${{ steps.docker-build.outputs.digest }}
    identity: https://github.com/${{ github.repository }}/.github/workflows/docker.yml@refs/heads/main
```

For a reusable workflow, the identity names the called workflow, not its caller.
The repository's release caller delegates OIDC permission to that workflow;
GitHub does not allow the called workflow to elevate it. Protect `main`, release
tags, and workflow/action changes with review requirements.

## Archives, SBOMs, and firmware

Provide `files` instead of `image`; globs are not expanded:

```yaml
- uses: ./.github/actions/sigstore
  with:
    identity: https://github.com/ORG/REPO/.github/workflows/firmware.yml@refs/heads/main
    files: |
      dist/firmware.bin
      dist/sbom.spdx.json
```

The SBOM workflow signs its two SBOMs and generated source archives before
uploading them with their bundles. GitHub's automatically generated source
archives are separate and are not signed. This repository has no firmware build;
a firmware producer can use the same action and retain the binary and bundle.

## Trust and consumption

`deployment: public` is an explicit default for this public repository: signing
metadata is disclosed to public Sigstore. Cosign uses the embedded public TUF
trust anchor and authenticated updates. For confidential/private infrastructure,
set `deployment: private` and supply both `signing-config` and `trusted-root`
paths. These must be reviewed, independently distributed configuration files for
approved services and trust roots (Fulcio, CT, and Rekor), with no public fallback
endpoints. Private Fulcio must accept GitHub Actions OIDC with audience `sigstore`.
Missing configuration fails; no transparency or certificate checks are disabled.

The shared Docker action pushes tags before signing. A failed signature check
fails the job but cannot retract an already pushed image. Consumers must verify
an approved immutable digest before deployment or installation, for example:

```bash
cosign verify "$IMAGE_DIGEST" \
  --certificate-identity 'https://github.com/sentenz/template-k8s/.github/workflows/docker.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  && deploy-command "$IMAGE_DIGEST"
```

For files, use `cosign verify-blob --bundle FILE.sigstore.json` with the approved
identity/issuer and `FILE`, and run the installer only on success. Private
consumers must also pass their approved `--trusted-root`. Registry signatures
and release bundles must be retained throughout the artifact support lifetime;
the additional image bundle uploaded to Actions has 90-day retention. This change
does not configure cluster admission control or redesign release publication.

## Make tasks for Software Supply Chain Security

Install host Cosign v3.1.4, matching the CI version, and authenticate to the
registry with `docker login` when needed. `SSCS_COSIGN` can select an executable
path. Native execution retains access to registry credentials and browser OIDC;
the previous container wrapper did not forward either registry or CI OIDC credentials.

| Target | Operation |
| --- | --- |
| `sscs-cosign-sign` | Sign an image digest, retain its bundle, then verify |
| `sscs-cosign-verify` | Verify the image signature |
| `sscs-cosign-attest` | Attach a CycloneDX SBOM attestation, retain its bundle, then verify |
| `sscs-cosign-verify-attestation` | Verify the CycloneDX attestation and emit its envelopes |

```bash
make sscs-cosign-verify \
  SSCS_COSIGN_IMAGE='ghcr.io/sentenz/k8s@sha256:<64-hex-digest>' \
  SSCS_COSIGN_IDENTITY='https://github.com/sentenz/template-k8s/.github/workflows/docker.yml@refs/heads/main'
```

`SSCS_COSIGN_IDENTITY` is required; the default issuer is GitHub Actions.
Local signing uses interactive OIDC: explicitly supply the approved personal
identity and its issuer through `SSCS_COSIGN_IDENTITY` and `SSCS_COSIGN_ISSUER`.
It does not create a GitHub workflow identity. Within GitHub Actions, signing
selects its ambient provider and requires job-level `id-token: write`.

The SBOM default is `logs/sbom/sbom-image.cdx.json`, matching the existing image
SBOM generator; override `SSCS_COSIGN_SBOM` for another path. The SBOM must describe
the exact image digest. An attestation proves its signed association, not SBOM
completeness or absence of vulnerabilities. CI currently signs SBOM files as blobs;
that does not create an OCI attestation, so `verify-attestation` requires a
separately produced attestation. Its stdout contains envelopes, not raw CycloneDX.

For private infrastructure, provide `SSCS_COSIGN_TRUSTED_ROOT` for verification
and also `SSCS_COSIGN_SIGNING_CONFIG` for signing. Signature bundles default to
`logs/sscs/image.sigstore.json` and `logs/sscs/sbom.sigstore.json`. Retain them as
needed; no private key is written. Legacy `sast-cosign-*` names and the key-pair
generator are removed. The old verification target's attestation behavior is
now explicitly named `sscs-cosign-verify-attestation`. Use named Make variables;
a positional image name is interpreted by Make as another target.
