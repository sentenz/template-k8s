# Attestation, Signing, and Verification

Attestation records claims about software artifacts. Signing binds artifacts to a signer, and verification checks that evidence against an explicit trust policy. This repository combines Docker BuildKit attestations with [Sigstore Cosign](https://docs.sigstore.dev/cosign/verifying/verify/) signatures for container images and software bills of materials (SBOMs).

This article covers the [Docker Sigstore workflow](../.github/workflows/docker-sigstore.yml) and [Trivy SBOM Sigstore workflow](../.github/workflows/trivy-sbom-sigstore.yml). Workflow configuration describes intended behavior; successful verification establishes evidence for a particular release.

- [1. Artifact Categories](#1-artifact-categories)
- [2. Trust Model](#2-trust-model)
  - [2.1. Workflow Identity](#21-workflow-identity)
  - [2.2. Workflow Self-Verification](#22-workflow-self-verification)
  - [2.3. Independent Consumer Trust](#23-independent-consumer-trust)
  - [2.4. Verification Guarantees and Limits](#24-verification-guarantees-and-limits)
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

The workflows produce two artifact groups: a container image with build metadata, and repository SBOM files. The image SBOM describes the image; the release SBOMs describe the repository checkout. These inventories are not interchangeable.

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

### 2.2. Workflow Self-Verification

Both workflows derive their immediate verification identity from the [GitHub Actions context](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts):

| Property | Value supplied |
| --- | --- |
| `github.server_url` | GitHub server URL |
| `github.workflow_ref` | Repository, workflow file path, and full Git ref |

Combining these properties follows workflow renames without duplicating the filename.

Example: the same identity input applies to both workflows:

```yaml
identity: ${{ github.server_url }}/${{ github.workflow_ref }}
```

The action's `identity` input constrains verification; it does not change the issued certificate identity. The expression applies to these directly executed workflows. Migration to reusable workflows requires reassessing the signing identity.

### 2.3. Independent Consumer Trust

External consumers must approve the repository, workflow path, and release tag independently of the artifact and its bundle. The verification examples therefore retain explicit `-sigstore.yml` identities.

A workflow rename requires a reviewed consumer-policy update. Broad wildcard matching weakens this trust boundary.

### 2.4. Verification Guarantees and Limits

Signature verification establishes integrity and signer identity. Acceptance also requires authorization and artifact-specific policy checks.

- Artifact Integrity
  > A valid signature binds the signed content or image digest to the certificate identity. A mutable tag alone does not provide a stable deployment reference.

- Signer Authorization
  > Certificate validity and signer authorization are separate decisions. The accepted repository, workflow, and tag must come from an approved release policy.

- Attestation Policy
  > An image signature authenticates the selected index digest. Content-addressed references bind the index to its included manifests and attestation blobs, but signature verification does not evaluate provenance fields or SBOM contents.

- Security Assessment
  > A successful signature check does not establish that software is vulnerability-free, that an inventory is complete, or that build inputs satisfy organizational policy.

## 3. Attestation and Signing

Both workflows run on matching numeric release tags and support manual dispatch. Publishing requires a tag ref and excludes deleted-tag events. Recovery runs must select an existing tag that contains the intended workflow configuration.

### 3.1. Container Image

The Docker pull-request job builds without pushing. The tag publication job follows this sequence:

1. Check out `github.sha`.
2. Build and push the multi-platform image with maximum-mode provenance and an image SBOM.
3. Pass the image name and digest to `cosign sign --bundle image.sigstore.json`.
4. Run `cosign verify` against the same immutable reference.
5. Upload `image.sigstore.json` as the Actions artifact `image-signature-<tag>-<run_attempt>`, with a requested retention of 90 days.

[BuildKit attestations](https://docs.docker.com/build/metadata/attestations/) are in-toto records attached through the image index. The signature bundle is retained separately as an Actions artifact, not a release asset.

An image can remain published after signing or verification fails. Signing may also succeed before identity verification fails. Registry presence alone does not establish a successful release.

### 3.2. Release SBOMs

The pinned [Trivy action](https://github.com/sentenz/actions/blob/ac68a6837f8890c4570767c0d1f21bcfc133ab1a/trivy/action.yml) maps `sbom-generate` with target `.` to a filesystem scan. It generates CycloneDX and SPDX JSON inventories of the checked-out repository, rather than scanning the published container image.

After generation, the workflow follows this sequence:

1. Scan both SBOMs with `exit-code: "1"` and no continuation on error.
2. After both scans succeed, sign each file with `cosign sign-blob` and write its adjacent `.sigstore.json` bundle.
3. Immediately verify each file with `cosign verify-blob`.
4. Publish four release assets: the two SBOMs and their two bundles.

Signing and publication stop if an earlier step fails. These are signed blobs; neither workflow invokes `cosign attest` or publishes a separate Cosign predicate attestation. The signed SBOMs also do not constitute signed vulnerability reports.

## 4. Verification

Verification must fail closed: artifacts are accepted only after every required check succeeds. Examples use Bash and stop on command errors.

### 4.1. Prerequisites

Prepare the tools and access required for the selected procedure:

| Tool | Purpose | Requirement |
| --- | --- | --- |
| Cosign | Signature verification | Version `v3.1.4`, matching the pinned action |
| Docker with Buildx | Image metadata inspection | Read access to the registry package |
| GitHub CLI | Release asset and Actions artifact downloads | Authenticated GitHub access for Actions artifacts |

Set release inputs from approved records, not from an untrusted bundle:

| Variable | Required value | Used for |
| --- | --- | --- |
| `TAG` | Exact approved release tag | All verification examples |
| `IMAGE_DIGEST` | Published image index digest recorded for the release | Image verification |
| `RUN_ID` | Corresponding successful Docker workflow run ID | Image bundle retrieval |
| `RUN_ATTEMPT` | Attempt number from that successful run | Image bundle retrieval |

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

Run the remaining examples in this same shell so the variables and error-handling settings remain active.

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

A zero exit status confirms signature verification against the specified identity and issuer. After all policy checks pass, deploy this same digest reference. Resolving the tag again can select different content.

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

Evaluate both target platforms against the expected source repository and revision, approved build inputs, and required inventory coverage. Missing or unexpected evidence fails that policy even when the signature is valid.

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

The download and `test -s` check establish only that a nonempty bundle was retrieved. Image verification still uses the registry-based `cosign verify` procedure above. This image bundle cannot replace either SBOM's bundle.

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

The Docker pull-request filter includes `.github/workflows/docker-sigstore.yml`, so workflow changes trigger its build job. The filter remains a literal path: future renames require a filter update even though the signing identity updates automatically.

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
