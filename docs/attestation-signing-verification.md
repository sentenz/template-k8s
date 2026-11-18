# Attestation, Signing, and Verification

An attestation records a claim about a software artifact. A signature binds content to a signer. Verification checks that binding against an expected identity and issuer.

The [Docker workflow](../.github/workflows/docker-sigstore.yml) signs a container image index that includes build provenance and a software bill of materials (SBOM). The [Trivy workflow](../.github/workflows/trivy-sbom-sigstore.yml) signs SBOM files for the repository checkout. Both workflows check their own signatures with [Sigstore Cosign](https://docs.sigstore.dev/cosign/verifying/verify/). Consumers independently decide which signers and releases to accept.

- [1. Release Artifacts](#1-release-artifacts)
- [2. Trust Model](#2-trust-model)
  - [2.1. Workflow Self-Verification](#21-workflow-self-verification)
  - [2.2. Independent Consumer Trust](#22-independent-consumer-trust)
  - [2.3. Verification Guarantees and Limits](#23-verification-guarantees-and-limits)
- [3. Release Workflows](#3-release-workflows)
  - [3.1. Container Image Publication](#31-container-image-publication)
  - [3.2. Release SBOM Publication](#32-release-sbom-publication)
- [4. Consumer Verification](#4-consumer-verification)
  - [4.1. Tools and Approved Release Inputs](#41-tools-and-approved-release-inputs)
  - [4.2. Verify the Image Index Signature](#42-verify-the-image-index-signature)
  - [4.3. Evaluate Build Provenance and Image Inventory](#43-evaluate-build-provenance-and-image-inventory)
  - [4.4. Verify Both Release SBOMs](#44-verify-both-release-sboms)
  - [4.5. Retain the Image Signature Bundle](#45-retain-the-image-signature-bundle)
- [5. Troubleshooting](#5-troubleshooting)
- [6. Terminology](#6-terminology)
- [7. References](#7-references)

## 1. Release Artifacts

The signed subject determines which evidence to retrieve and which verification command to run. The image SBOM inventories the image. The release SBOMs inventory the checked-out repository.

| Artifact | Location | Verification or inspection |
| --- | --- | --- |
| Multi-platform image | `ghcr.io/sentenz/k8s:<tag>` | Verify the published index digest with `cosign verify`. |
| Build provenance | BuildKit attestation in the image index | Verify the index, then evaluate the build record. |
| Image SBOM | BuildKit attestation in the image index | Verify the index, then inspect the image inventory. |
| Image signature bundle | `image.sigstore.json` in a GitHub Actions artifact | Retain as signing evidence. The workflow verifies the image through the registry. |
| CycloneDX release SBOM | Release assets `sbom.cdx.json` and `sbom.cdx.json.sigstore.json` | Verify the file with its bundle using `cosign verify-blob`. |
| SPDX release SBOM | Release assets `sbom.spdx.json` and `sbom.spdx.json.sigstore.json` | Verify the file with its bundle using `cosign verify-blob`. |

## 2. Trust Model

Each signing job grants `id-token: write`. The pinned [Sigstore action](https://github.com/sentenz/actions/blob/2f64add54257e1cb22b66ff4755a2ca9fd4454fc/sigstore/action.yml) installs Cosign `v3.1.4` and authenticates through GitHub Actions OpenID Connect (OIDC) with `--oidc-provider github-actions --oidc-client-id sigstore`.

Verification requires an exact certificate identity and the issuer `https://token.actions.githubusercontent.com`. The action defaults to the public Sigstore deployment and uses its trust material. An artifact cannot supply a custom trust root.

### 2.1. Workflow Self-Verification

Each directly executed workflow derives its expected signer from the [GitHub Actions context](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts). The server URL supplies the host. The workflow ref supplies the repository, workflow path, and full Git ref.

```yaml
identity: ${{ github.server_url }}/${{ github.workflow_ref }}
```

The `identity` input constrains the verification check. Certificate issuance is independent of this input. The expression follows workflow renames automatically. A migration to reusable workflows requires reassessing the signing identity.

### 2.2. Independent Consumer Trust

Consumers must approve the repository, workflow path, and exact release tag independently of the artifact and its bundle. The examples use the following certificate identities, with `<tag>` replaced by the approved tag exactly as spelled.

| Signed subject | Required certificate identity |
| --- | --- |
| Image index | `https://github.com/sentenz/template-k8s/.github/workflows/docker-sigstore.yml@refs/tags/<tag>` |
| Release SBOM | `https://github.com/sentenz/template-k8s/.github/workflows/trivy-sbom-sigstore.yml@refs/tags/<tag>` |

A workflow rename requires a reviewed consumer-policy change. A broad wildcard would authorize additional identities.

### 2.3. Verification Guarantees and Limits

A valid signature binds the exact file bytes or image digest to the certificate identity. Release acceptance also requires signer authorization under the approved release policy.

For an image, content-addressed references bind the signed index to its manifests and attestation blobs. Consumers must evaluate the provenance fields, build inputs, and inventory coverage separately. A signature alone establishes neither the absence of vulnerabilities nor the completeness of an inventory.

## 3. Release Workflows

Both workflows run on pushes of matching numeric release tags and support manual dispatch. Publication requires a tag ref and excludes tag deletions. For manual recovery, select an existing tag that contains the intended workflow configuration.

### 3.1. Container Image Publication

On pull requests, Docker builds without pushing. Its path filter includes the literal filename `.github/workflows/docker-sigstore.yml` so changes to the workflow trigger a build. A rename requires updating that filter.

On a release tag, the publication job runs these steps in order.

1. Check out `github.sha` and build `container/k8s/Dockerfile` for `linux/amd64` and `linux/arm64`.
2. Push the image with `provenance: mode=max` and `sbom: true`. The [Docker action](https://github.com/sentenz/actions/blob/df6abdf4c93db5d926177c074f25362775658ca3/docker/action.yml) derives `ghcr.io/sentenz/k8s` from owner `sentenz` and `image-name: k8s`. Publication of `latest` is disabled.
3. Sign the image name and index digest with `cosign sign --bundle image.sigstore.json`. Run `cosign verify` against the same immutable reference.
4. Upload `image.sigstore.json` as the Actions artifact `image-signature-<tag>-<run_attempt>`, requesting 90 days of retention.

[BuildKit attestations](https://docs.docker.com/build/metadata/attestations/) are in-toto records attached through the image index. The signature bundle is stored separately in Actions. Because the push precedes signing, an image can remain in the registry after signing fails. Signing can also succeed before identity verification fails. Registry presence alone is insufficient evidence of a successful release.

### 3.2. Release SBOM Publication

The pinned [Trivy action](https://github.com/sentenz/actions/blob/ac68a6837f8890c4570767c0d1f21bcfc133ab1a/trivy/action.yml) maps `sbom-generate` with target `.` to a filesystem scan of the checkout.

1. Generate CycloneDX and SPDX JSON inventories.
2. Scan both files with `exit-code: "1"` and continuation on error disabled. Both scans must pass before signing.
3. Sign each file with `cosign sign-blob`, write its adjacent `.sigstore.json` bundle, and verify each file with `cosign verify-blob`.
4. Publish both SBOMs and both bundles as four release assets after verification succeeds.

The signatures cover the inventory files only. The vulnerability scan produces no signed vulnerability report. Neither workflow invokes `cosign attest` or publishes a separate Cosign predicate attestation.

## 4. Consumer Verification

Accept an artifact only after every required signature and policy check succeeds. Workflow configuration describes intended behavior. Verification supplies evidence for the selected release.

### 4.1. Tools and Approved Release Inputs

Use Cosign `v3.1.4` to match the pinned action. Image inspection requires Docker with Buildx and registry read access. Release and Actions downloads use the GitHub CLI (`gh`). Actions artifact downloads require authenticated GitHub access.

| Variable | Value from approved release records | Required for |
| --- | --- | --- |
| `TAG` | Exact release tag | All procedures |
| `IMAGE_DIGEST` | Published image index digest | Image verification and inspection |
| `RUN_ID` | Successful Docker workflow run ID | Image bundle retrieval |
| `RUN_ATTEMPT` | Attempt number for that successful run | Image bundle retrieval |

Set the inputs independently of the downloaded evidence. Run the setup and subsequent commands in the same Bash shell so the identities and stop-on-error settings remain in effect.

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

### 4.2. Verify the Image Index Signature

Use the index digest returned by the publication build. A platform-specific child manifest has a different digest and receives no independent workflow signature.

```bash
: "${IMAGE_DIGEST:?Set IMAGE_DIGEST to the approved sha256 index digest}"
[[ "${IMAGE_DIGEST}" =~ ^sha256:[a-f0-9]{64}$ ]]
IMAGE="ghcr.io/sentenz/k8s@${IMAGE_DIGEST}"

cosign verify \
  --certificate-identity "${IMAGE_IDENTITY}" \
  --certificate-oidc-issuer "${ISSUER}" \
  "${IMAGE}"
```

A zero exit status confirms the signature against the specified identity and issuer. Use the same digest for inspection and, after policy checks pass, deployment. Resolving a mutable tag again can select different content.

### 4.3. Evaluate Build Provenance and Image Inventory

After signature verification, inspect the same index with [Buildx imagetools inspect](https://docs.docker.com/reference/cli/docker/buildx/imagetools/inspect/).

```bash
docker buildx imagetools inspect "${IMAGE}"

docker buildx imagetools inspect "${IMAGE}" \
  --format '{{json .Provenance}}'

docker buildx imagetools inspect "${IMAGE}" \
  --format '{{json .SBOM}}'
```

For **each target platform**, check the source repository and revision, approved build inputs, and required inventory coverage. Reject missing or unexpected evidence even if the index signature is valid.

These commands display the metadata. Policy evaluation is a separate step. The BuildKit records rely on their inclusion in the signed index, so `cosign verify-attestation` cannot replace this sequence.

### 4.4. Verify Both Release SBOMs

Download each file and its matching bundle from the approved release. Preserve the original bytes. Reformatting JSON changes the signed content.

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

Both checks must succeed before inventory ingestion. The workflows create no binding between the signed repository SBOMs and the container digest.

### 4.5. Retain the Image Signature Bundle

When evidence must outlive Actions retention, archive the image bundle with the release digest, source revision, tag, workflow run ID, and attempt number.

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

A successful download and `test -s` establish only that the bundle exists and is nonempty. Use [registry signature verification](#42-verify-the-image-index-signature) to authenticate the image. Each release SBOM still requires its own bundle.

## 5. Troubleshooting

Keep identity, issuer, and transparency verification enabled while correcting failures.

| Symptom | Likely cause | Corrective action |
| --- | --- | --- |
| Certificate identity mismatch | Workflow filename or tag differs from the expected identity | Confirm the workflow and tag. Use the runtime identity for self-verification and the independently approved identity for consumer checks. |
| SBOM release assets absent | Scan, signing, or immediate verification failed | Inspect the selected SBOM run and resolve the failed step. |
| Image exists after a failed run | Push completed before signing or verification failed | Require successful signature and policy checks before deployment. |
| Image signature missing | Wrong digest, unavailable signature data, or incomplete signing | Confirm the publication index digest and inspect the signing logs. |
| SBOM signature invalid | Modified bytes, mismatched bundle, or wrong release | Download the original file and matching bundle from the approved release. |
| Image bundle unavailable | Wrong attempt, failed upload, deletion, or expired retention | Check the successful run and retention records. Archive evidence before expiry. |
| Registry access denied | Package visibility or credentials prevent reads | Obtain authorized read access and repeat verification. |
| Provenance or image SBOM absent | Wrong image, incomplete publication, or unsupported inspection tooling | Confirm the digest, Buildx support, and publication settings. Reject missing required evidence. |

## 6. Terminology

| Term | Meaning |
| --- | --- |
| Attestation | A structured claim about an artifact, such as its build inputs or inventory. |
| Certificate identity | The signer identity checked against the approved workflow and Git ref. |
| Digest | A content-derived identifier for an exact image index or manifest. |
| Provenance | Evidence describing how an artifact was built. |
| SBOM | An inventory of components discovered within a defined scan scope. |
| Sigstore bundle | Signature and verification material associated with signed content. |

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
