# Attestation, Signing, and Verification

Attestation, signing, and verification establish claims about software artifacts, bind those artifacts to a signer, and evaluate the resulting evidence against an explicit trust policy. This repository combines Docker BuildKit attestations with [Sigstore Cosign](https://docs.sigstore.dev/cosign/verifying/verify/) signatures for container images and software bills of materials (SBOMs).

This article describes the [Docker Sigstore workflow](../.github/workflows/docker-sigstore.yml) and [Trivy SBOM Sigstore workflow](../.github/workflows/trivy-sbom-sigstore.yml). It distinguishes configured publication behavior from evidence that a particular release completed successfully.

- [1. Artifact Categories](#1-artifact-categories)
- [2. Trust Model](#2-trust-model)
  - [2.1. Workflow Identity](#21-workflow-identity)
  - [2.2. Verification Boundaries](#22-verification-boundaries)
- [3. Attestation and Signing](#3-attestation-and-signing)
  - [3.1. Container Image](#31-container-image)
  - [3.2. Release SBOMs](#32-release-sboms)
- [4. Verification](#4-verification)
  - [4.1. Prerequisites](#41-prerequisites)
  - [4.2. Container Signature](#42-container-signature)
  - [4.3. Build Attestations](#43-build-attestations)
  - [4.4. Release SBOM Signatures](#44-release-sbom-signatures)
  - [4.5. Image Bundle Retention](#45-image-bundle-retention)
- [5. Troubleshooting](#5-troubleshooting)
- [6. Terminology](#6-terminology)
- [7. References](#7-references)

## 1. Artifact Categories

Artifacts are classified by their subject and verification mechanism. The image SBOM and release SBOM files have different scan targets and are not interchangeable.

| Artifact | Producer and subject | Publication location | Validation mechanism |
| --- | --- | --- | --- |
| Multi-platform container image | Docker build of `container/k8s/Dockerfile` for `linux/amd64,linux/arm64` | `ghcr.io/sentenz/k8s:<tag>` | Cosign verification of the published digest |
| Build provenance | BuildKit, with `provenance: mode=max` | Attestation metadata associated with the image index | Verify the image index signature, then inspect and evaluate provenance |
| Image SBOM | BuildKit, with `sbom: true` | Attestation metadata associated with the image index | Verify the image index signature, then inspect image inventory |
| Image signature bundle | Cosign image signing | Actions artifact containing `image.sigstore.json` | Retained signature evidence; the action verifies through the registry |
| CycloneDX SBOM | Trivy filesystem scan of the repository checkout | Release asset `sbom.cdx.json` | `cosign verify-blob` with `sbom.cdx.json.sigstore.json` |
| SPDX SBOM | Trivy filesystem scan of the repository checkout | Release asset `sbom.spdx.json` | `cosign verify-blob` with `sbom.spdx.json.sigstore.json` |

The [Docker action](https://github.com/sentenz/actions/blob/df6abdf4c93db5d926177c074f25362775658ca3/docker/action.yml) resolves the registry name from owner `sentenz` and input `image-name: k8s`. The workflow disables publication of `latest`.

## 2. Trust Model

The pinned [Sigstore action](https://github.com/sentenz/actions/blob/2f64add54257e1cb22b66ff4755a2ca9fd4454fc/sigstore/action.yml) installs Cosign `v3.1.4` and uses GitHub Actions OpenID Connect (OIDC) authentication. Both workflows grant `id-token: write` to the signing job and use the action's public Sigstore deployment default.

The action requests signing with `--oidc-provider github-actions --oidc-client-id sigstore`. Verification requires both an exact certificate identity and the issuer `https://token.actions.githubusercontent.com`. The action uses public Sigstore trust material rather than an artifact-supplied custom root.

### 2.1. Workflow Identity

A workflow's filename and Git ref are security-relevant parts of the expected certificate identity. For these directly executed workflows, the expected identities are:

| Workflow | Expected certificate identity |
| --- | --- |
| Docker | `https://github.com/sentenz/template-k8s/.github/workflows/docker-sigstore.yml@refs/tags/<tag>` |
| Trivy SBOM | `https://github.com/sentenz/template-k8s/.github/workflows/trivy-sbom-sigstore.yml@refs/tags/<tag>` |

Here, `<tag>` denotes the selected release tag, including its exact spelling.

Both workflows derive the identity for immediate verification from the [GitHub Actions context](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts). The `github.workflow_ref` property contains the repository, workflow file path, and full Git ref; `github.server_url` supplies the server URL. This expression follows workflow renames without duplicating the filename.

Example: the same identity input applies to both workflows:

```yaml
identity: ${{ github.server_url }}/${{ github.workflow_ref }}
```

The action's `identity` input constrains verification; it does not change the certificate identity issued to the signer. This expression applies to the directly executed workflows described here. A migration to reusable workflows requires reassessing the expected signing identity.

External consumers must retain an independently approved repository, workflow path, and release tag. The verification examples below therefore keep explicit `-sigstore.yml` identities rather than deriving trust from the artifact or its bundle. A workflow rename requires a corresponding reviewed update to consumer policy; broad wildcard matching would weaken that boundary.

### 2.2. Verification Boundaries

- Artifact Integrity
  > A valid signature binds the signed content or image digest to the certificate identity. A mutable tag alone does not provide a stable deployment reference.

- Signer Authorization
  > Certificate validity and signer authorization are separate decisions. The accepted repository, workflow, and tag must come from an approved release policy.

- Attestation Policy
  > An image signature authenticates the selected index digest. Content-addressed references bind the index to its included manifests and attestation blobs, but signature verification does not evaluate provenance fields or SBOM contents.

- Security Assessment
  > A successful signature check does not establish that software is vulnerability-free, that an inventory is complete, or that build inputs satisfy organizational policy.

## 3. Attestation and Signing

Both workflows run on matching numeric release tags and support manual dispatch. Publishing jobs require a tag ref and exclude deleted-tag events. A recovery dispatch must therefore select an existing tag containing the intended workflow configuration.

### 3.1. Container Image

The Docker pull-request job builds without pushing. The tag publication job checks out `github.sha`, builds and pushes the multi-platform image with maximum-mode provenance and an image SBOM, then passes the action's image name and digest to Cosign.

[BuildKit attestations](https://docs.docker.com/build/metadata/attestations/) are in-toto records attached through the image index. The Sigstore action runs `cosign sign --bundle image.sigstore.json` against the immutable image reference, followed by `cosign verify` against that same reference.

After successful verification, the workflow uploads `image.sigstore.json` as `image-signature-<tag>-<run_attempt>` with a requested retention of 90 days. The bundle is an Actions artifact, not a release asset.

Image publication occurs before signing and verification. A failed signing step can therefore leave a published image, and an identity-verification failure can occur after signing. Registry presence alone is insufficient evidence of a successful release.

### 3.2. Release SBOMs

The pinned [Trivy action](https://github.com/sentenz/actions/blob/ac68a6837f8890c4570767c0d1f21bcfc133ab1a/trivy/action.yml) maps `sbom-generate` with target `.` to a filesystem scan. It generates CycloneDX and SPDX JSON inventories of the checked-out repository, rather than scanning the published container image.

The workflow scans both generated SBOMs with `exit-code: "1"` and no continuation on error. Signing and release publication run only after those scans succeed. The action signs each file with `cosign sign-blob`, writes an adjacent `.sigstore.json` bundle, and immediately checks it with `cosign verify-blob`.

The release receives four assets: two SBOMs and their two bundles. These are signed blobs; neither workflow invokes `cosign attest` or publishes a separate Cosign predicate attestation. The signed SBOMs also do not constitute signed vulnerability reports.

## 4. Verification

Verification must fail closed: artifacts are accepted only after every required check succeeds. Examples use Bash and stop on command errors.

### 4.1. Prerequisites

Install Cosign `v3.1.4` to match the pinned action, Docker with Buildx for image inspection, and the GitHub CLI for asset downloads. Registry reads require access to the package; authenticated GitHub access is required for Actions artifact downloads.

Set `TAG` to an approved release tag. For image verification, set `IMAGE_DIGEST` to the published index digest recorded for that release. For bundle retrieval, set `RUN_ID` and `RUN_ATTEMPT` from the corresponding successful Docker run. These are release-specific inputs, not values inferred from an untrusted bundle.

Example:

```bash
set -euo pipefail
: "${TAG:?Set TAG to the approved release tag}"

REPOSITORY='sentenz/template-k8s'
ISSUER='https://token.actions.githubusercontent.com'
IMAGE_IDENTITY="https://github.com/${REPOSITORY}/.github/workflows/docker-sigstore.yml@refs/tags/${TAG}"
SBOM_IDENTITY="https://github.com/${REPOSITORY}/.github/workflows/trivy-sbom-sigstore.yml@refs/tags/${TAG}"

cosign version
docker buildx version
gh --version
```

Subsequent examples share these variables in the same shell.

### 4.2. Container Signature

Use the index digest returned by the publication build. A platform-specific child manifest is a different subject and is not independently signed by the workflow.

Example:

```bash
: "${IMAGE_DIGEST:?Set IMAGE_DIGEST to the approved sha256 index digest}"
[[ "${IMAGE_DIGEST}" =~ ^sha256:[a-f0-9]{64}$ ]]
IMAGE="ghcr.io/sentenz/k8s@${IMAGE_DIGEST}"

cosign verify \
  --certificate-identity "${IMAGE_IDENTITY}" \
  --certificate-oidc-issuer "${ISSUER}" \
  "${IMAGE}"
```

A zero exit status establishes successful signature verification under the specified identity and issuer constraints. Deploy the same digest reference after all required policy checks pass. Resolving a tag again at deployment time can select different content.

### 4.3. Build Attestations

After image signature verification, inspect metadata using the same digest. Docker's [imagetools inspection](https://docs.docker.com/reference/cli/docker/buildx/imagetools/inspect/) exposes provenance and SBOM data.

Example:

```bash
docker buildx imagetools inspect "${IMAGE}"

docker buildx imagetools inspect "${IMAGE}" \
  --format '{{json .Provenance}}'

docker buildx imagetools inspect "${IMAGE}" \
  --format '{{json .SBOM}}'
```

Evaluate evidence for both target platforms. Acceptance criteria should require the expected source repository and revision, approved build inputs, and the required inventory coverage. Missing or unexpected evidence fails that policy even if the image signature is valid.

These commands inspect metadata; they do not implement an automated provenance policy. The workflows' BuildKit records are not independently created Cosign attestations, so `cosign verify-attestation` is not a substitute for this verification and inspection sequence.

### 4.4. Release SBOM Signatures

Download each SBOM with its matching bundle from the selected release. Preserve the original bytes: JSON reformatting changes the signed content.

Example:

```bash
SBOM_DIR="$(mktemp -d)"

gh release download "${TAG}" \
  --repo "${REPOSITORY}" \
  --dir "${SBOM_DIR}" \
  --pattern 'sbom.cdx.json' \
  --pattern 'sbom.cdx.json.sigstore.json' \
  --pattern 'sbom.spdx.json' \
  --pattern 'sbom.spdx.json.sigstore.json'

for name in sbom.cdx.json sbom.spdx.json; do
  cosign verify-blob \
    --certificate-identity "${SBOM_IDENTITY}" \
    --certificate-oidc-issuer "${ISSUER}" \
    --bundle "${SBOM_DIR}/${name}.sigstore.json" \
    "${SBOM_DIR}/${name}"
done
```

Both verifications must succeed before inventory ingestion. A valid repository SBOM signature does not associate that file with the container digest; the workflows do not create that binding.

### 4.5. Image Bundle Retention

Preserve the image bundle alongside the release digest, source revision, tag, and workflow run identifiers when evidence must outlive Actions retention.

Example:

```bash
: "${RUN_ID:?Set RUN_ID to the successful Docker workflow run ID}"
: "${RUN_ATTEMPT:?Set RUN_ATTEMPT to that run attempt}"
BUNDLE_DIR="$(mktemp -d)"

gh run download "${RUN_ID}" \
  --repo "${REPOSITORY}" \
  --name "image-signature-${TAG}-${RUN_ATTEMPT}" \
  --dir "${BUNDLE_DIR}"

test -s "${BUNDLE_DIR}/image.sigstore.json"
```

This checks retrieval and nonempty content only. The image verification procedure above deliberately follows the action's registry-based `cosign verify` path; downloading the bundle is not itself verification, and the image bundle is not a bundle for either SBOM file.

## 5. Troubleshooting

Failures must be resolved at their source without disabling identity, issuer, or transparency verification.

| Symptom | Likely cause | Corrective action |
| --- | --- | --- |
| Certificate identity mismatch | Configured workflow filename differs from the executing filename, or the tag is wrong | Confirm the producing workflow and tag; use the dynamic input for immediate verification and an independently approved identity for consumers |
| SBOM release assets absent | Scan, signing, or immediate verification failed before publication | Inspect the selected SBOM run and resolve the failed step |
| Image exists after a failed run | Push precedes signing and verification | Require successful signature and policy checks before deployment |
| No image signature found | Wrong digest, unavailable signature data, or signing did not finish | Confirm the publication index digest and signing logs |
| SBOM signature invalid | Modified bytes, mismatched bundle, or wrong release | Download the original file and matching bundle together |
| Image bundle unavailable | Wrong run attempt, failed upload, deletion, or expired retention | Check the successful run and retention records; preserve evidence before expiry |
| Registry access denied | Package visibility or registry credentials prevent reads | Obtain authorized read access and repeat verification |
| Provenance or image SBOM absent | Wrong image, incomplete attestation publication, or unsupported inspection tooling | Confirm the digest, Buildx support, and publication settings; reject missing required evidence |

The Docker workflow's pull-request path filter includes `.github/workflows/docker-sigstore.yml` so changes to that workflow trigger its build job. This filter remains a literal path and must be updated after a future rename; the dynamic signing identity does not update event filters.

## 6. Terminology

- Attestation
  > A structured statement about an artifact, such as its build inputs or software inventory.

- Provenance
  > Build-related evidence describing how an artifact was produced.

- Digest
  > A content-derived identifier used to select the exact image index or manifest being verified.

- Sigstore Bundle
  > A container for signature and verification material associated with signed content.

- Certificate Identity
  > The signer identity checked against the explicitly permitted workflow and ref.

- SBOM
  > A software bill of materials recording discovered components within a defined scan scope.

## 7. References

- Sentenz [Docker Sigstore](../.github/workflows/docker-sigstore.yml) workflow.
- Sentenz [Trivy SBOM Sigstore](../.github/workflows/trivy-sbom-sigstore.yml) workflow.
- Sentenz [Sigstore Action at the Pinned Revision](https://github.com/sentenz/actions/blob/2f64add54257e1cb22b66ff4755a2ca9fd4454fc/sigstore/action.yml) source file.
- Sentenz [Docker Action at the Pinned Revision](https://github.com/sentenz/actions/blob/df6abdf4c93db5d926177c074f25362775658ca3/docker/action.yml) source file.
- Sentenz [Trivy Action at the Pinned Revision](https://github.com/sentenz/actions/blob/ac68a6837f8890c4570767c0d1f21bcfc133ab1a/trivy/action.yml) source file.
- GitHub [Contexts Reference](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts) documentation.
- Sigstore [Verifying Signatures](https://docs.sigstore.dev/cosign/verifying/verify/) documentation.
- Sigstore [Signing Containers](https://docs.sigstore.dev/cosign/signing/signing_with_containers/) documentation.
- Docker [Build Attestations](https://docs.docker.com/build/metadata/attestations/) documentation.
- Docker [Buildx Imagetools Inspect](https://docs.docker.com/reference/cli/docker/buildx/imagetools/inspect/) command reference.
