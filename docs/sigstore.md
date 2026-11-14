# Sigstore signing

The shared [Sigstore action](https://github.com/sentenz/actions/tree/2f64add54257e1cb22b66ff4755a2ca9fd4454fc/sigstore) supports both `cosign sign` for OCI images and
`cosign sign-blob` for local files. Both use keyless GitHub Actions OIDC signing
and require immediate verification. No persistent signing keys are used.

## Supported features

| Feature | Behavior |
| --- | --- |
| Container images | `image:` accepts one immutable `@sha256:…` reference; tag-only references are rejected |
| Release archives, SBOMs, and firmware | `files:` accepts newline-separated exact local file paths; globs are not expanded |
| Keyless authentication | Uses the `github-actions` OIDC provider with audience `sigstore`; the calling job needs `id-token: write` |
| Non-interactive signing | Both signing commands use `--yes` |
| Mandatory verification | Runs `cosign verify` for images or `cosign verify-blob` for each file; failures fail the action |
| Signer restrictions | Matches the exact supplied `identity:` and `issuer:`; the default issuer is `https://token.actions.githubusercontent.com` |
| Verification bundles | Images use `bundle:` (default `image.sigstore.json`); each file receives an adjacent `FILE.sigstore.json` |
| Public Sigstore | Default `deployment: public` uses Cosign's embedded public TUF trust anchor and authenticated updates |
| Private Sigstore | `deployment: private` requires both approved `signing-config:` and `trusted-root:` files |
| Input validation | Rejects conflicting image/file inputs, empty file lists, missing or empty artifacts, artifact symlinks, and symlinked bundle destinations |
| Tool installation | Installs Cosign v3.1.4 through a commit-pinned `sigstore/cosign-installer` |

## Action reference

### Inputs

| Input | Default | Required | Purpose |
| --- | --- | --- | --- |
| `image` | Empty | In image mode | Fully qualified OCI image reference ending in `@sha256:<64 lowercase hex characters>`. |
| `files` | Empty | In file mode | Newline-delimited exact paths to existing, nonempty regular files. Globs are not expanded. |
| `identity` | None | Yes | Exact expected certificate identity, including the signing workflow path and Git ref. |
| `issuer` | `https://token.actions.githubusercontent.com` | No | Exact expected certificate OIDC issuer. |
| `bundle` | `image.sigstore.json` | No | Local output path for the image signature bundle. File mode uses adjacent bundles. |
| `deployment` | `public` | No | Selects the public or private Sigstore deployment. |
| `signing-config` | Empty | In private mode | Path to an approved, nonempty signing configuration file. |
| `trusted-root` | Empty | In private mode | Path to an approved, nonempty trusted root file used for signing and verification. |

Supply exactly one of `image` and `files`. Leave `signing-config` and
`trusted-root` empty in public mode.

### Outputs

The composite action declares no GitHub Actions step outputs. Use the
following paths and registry artifacts in subsequent steps:

| Mode | Result |
| --- | --- |
| Image | Cosign publishes the signature to the registry and writes a local bundle at `bundle`. |
| Files | Cosign writes `<file>.sigstore.json` next to each input file. |

Upload or retain local bundles in the calling workflow. The action fails if
an expected bundle is missing or empty, or if verification fails.

### Permissions

Grant the permissions needed by the signing job and its checkout or
publishing steps.

| Permission | Access | Purpose |
| --- | --- | --- |
| `id-token` | `write` | Request a GitHub Actions OIDC token for image or file signing. |
| `contents` | `read` | Check out the repository, as in the Docker publishing job. |
| `contents` | `write` | Check out the repository and publish GitHub release assets, as in the SBOM job. |
| `packages` | `write` | Publish the image and its signature to GHCR. File signing alone does not require this permission. |

> [!NOTE]
> When using a reusable workflow, the calling job must grant `id-token: write`
> so the called signing job can use it.

## Image and file signing

| | Image | Local file |
| --- | --- | --- |
| Action input | `image:` | `files:` |
| Signing command | `cosign sign` | `cosign sign-blob` |
| Signed content | Signature payload identifying the immutable OCI image digest | File contents through a cryptographic digest |
| Signature storage | OCI registry plus the requested local bundle | Adjacent local bundle |
| Verification command | `cosign verify` | `cosign verify-blob` |

Bundles contain signatures, signing certificates, and verification evidence.
The calling workflow must upload and retain local bundles; for files, distribute
each artifact with its bundle. The action checks that bundles were created.

## Boundaries

- Each invocation accepts **one image or a list of files**, never both.
- The action signs and verifies; it has no verification-only mode. Downstream
  consumers use Cosign verification commands or the Make targets below.
- It does not run `cosign attest`. Signing an SBOM file proves that document's
  integrity and signer identity; it does not bind the SBOM to an image digest.
  The separate Make attestation targets support that association.
- It does not build firmware, publish release assets, or configure admission
  control. Those responsibilities remain with producers and consumers.
- It does not prevent the preceding Docker action from pushing an image before
  signing. A failure stops subsequent workflow steps but does not retract the
  image; downstream verification remains required.
- The caller supplies the trusted identity and issuer. The action does not
  independently maintain an identity allowlist or enforce branch restrictions.

## Images

Grant `contents: read`, `packages: write`, and `id-token: write` to the signing
job. Keep read-only build jobs without OIDC permission. After the pinned
`sentenz/actions/docker` step with `id: docker-build`, sign and verify its output:

```yaml
- uses: sentenz/actions/sigstore@2f64add54257e1cb22b66ff4755a2ca9fd4454fc
  with:
    image: ${{ steps.docker-build.outputs.image }}@${{ steps.docker-build.outputs.digest }}
    identity: https://github.com/${{ github.repository }}/.github/workflows/docker.yml@refs/heads/main
```

For a reusable workflow, the identity names the called workflow, not its caller.
The repository's release caller delegates OIDC permission to that workflow;
GitHub does not allow the called workflow to elevate it. Protect `main`, release
tags, and workflow/action changes with review requirements.

## Archives, SBOMs, and firmware

Grant `id-token: write` to the signing job. Blob signing itself does not require
`packages: write`; add only permissions needed for checkout or artifact publication.
Provide `files` instead of `image`:

```yaml
- uses: sentenz/actions/sigstore@2f64add54257e1cb22b66ff4755a2ca9fd4454fc
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

## Action source and troubleshooting

The [Docker workflow](../.github/workflows/docker.yml) and
[SBOM workflow](../.github/workflows/sbom.yml) use the shared action pinned to
`2f64add54257e1cb22b66ff4755a2ca9fd4454fc`. Its `action.yml` was verified to be
byte-for-byte identical to the former local implementation at migration, including
all inputs, Cosign v3.1.4, OIDC options, validation, and mandatory verification.
Future dependency updates must preserve these requirements.

GitHub downloads the shared composite action separately from the release-tag
checkout. No `.signing-tools` checkout is needed, and older release tags do not
need to contain the action. The expected certificate identity remains the signing
workflow in `sentenz/template-k8s`; using an external composite action does not
change it to an identity in `sentenz/actions`.

If an older run reports `Can't find action.yml` under a local action path, start
a new workflow run from `main` after this migration is merged, using the desired
release tag. Rerunning an old run retains its original workflow revision. For a
shared-action download failure, check the pinned commit, action path, and repository
access rather than adding another checkout of the artifact source.

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
