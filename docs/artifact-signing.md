# Keyless artifact signing

The repository uses Cosign **v3.1.4** and GitHub Actions OIDC. No private signing
key is stored. `.github/actions/sigstore` owns signing and verification;
`.github/sigstore/policy.json` owns the approved issuer, exact workflow identities,
image repository, and Sigstore deployment selection. Treat these files and all
release workflows as security-sensitive code (the repository CODEOWNERS covers
all files); require owner review and protect `main` in repository settings.

## Release gates

1. Semantic Release creates a Git tag and a **draft** GitHub release.
2. The temporary `.github/actions/docker` builds the tagged source, with no OIDC
   permission, and uploads an untagged manifest by digest to GHCR. It is adapted
   from `sentenz/actions/docker`; the shared action publishes tags too early for
   the verification gate. Remove the local adaptation once the shared action
   supports digest-only staging. The candidate is registry storage, not an
   accepted release; consumers must verify even when a digest is known. Public
   GHCR candidates can be fetched by digest before acceptance. A confidential
   deployment must use access-controlled candidate storage.
3. A separate signing job requests a GitHub Actions token through Cosign's
   `github-actions` provider with the `sigstore` audience. It signs the image
   index digest and a `release-version` annotation, uploads the OCI signature,
   retains the Sigstore bundle, and verifies the registry signature immediately.
4. A separate build job creates source `.tar.gz` and `.zip` archives, CycloneDX
   and SPDX SBOMs, and a versioned SHA-256 inventory. SBOM scans must pass. A
   dedicated job signs and verifies each file with an adjacent `.sigstore.json`
   bundle. Blob signing hashes the actual bytes; the inventory is also signed.
5. Jobs without OIDC permission reverify signatures before attaching assets to
   the draft. The final release job downloads and verifies every expected blob,
   checks the signed inventory and version, rejects missing/extra assets, and
   verifies the image's digest, identity, issuer, and release annotation.
6. Only then does the final job promote the exact digest to the version tag and
   (for stable versions) `latest`, check the version tag's digest, and publish
   the GitHub release. Failure leaves the release in draft and stops downstream
   steps. Git tags/source snapshots remain visible independently of a release;
   GitHub-generated source-download links are not the signed archive assets.

`id-token: write` is absent from build, verification, upload, and publication
jobs. Caller entries for reusable workflows delegate it because GitHub does not
allow called workflows to elevate permissions; only their signing jobs retain
it. Pull-request builds have read-only permissions and never sign or push.

Fulcio's certificate SAN identifies the **called reusable workflow** through
`job_workflow_ref`. Approved identities are exact URLs ending in
`.github/workflows/docker.yml@refs/heads/main`, `sbom.yml@refs/heads/main`, or
`firmware.yml@refs/heads/main` in `sentenz/template-k8s`. No wildcard identities
or issuer regular expressions are accepted. Signing also checks repository,
branch, event, and availability of the GitHub OIDC endpoint.

## Verification and evidence

Cosign checks the artifact signature, certificate chain, exact SAN and issuer,
certificate-transparency SCT, and Rekor evidence. Image verification also checks
signed digest claims. There are no insecure skip flags or unsigned fallbacks.
Verification does not require an OIDC token. The verifier ignores ambient
`SIGSTORE_*`, `COSIGN_*`, and `TUF_*` trust overrides.

The OCI registry retains image signatures and certificates in Sigstore bundles.
Release assets retain `image.sigstore.json`, `image-reference.txt`, the four
artifacts, the signed inventory, and each blob's bundle. Bundles contain the
signature, signing certificate, and verification evidence; separate PEM files
are not required. CI copies have 90-day retention (unsigned intermediates: seven
days); release assets and registry signatures must be retained for the full
artifact support lifetime. Exclude OCI signature referrers from registry
cleanup, and back up release assets for long-term audits. The registry signature
is the authoritative image-verification source; the exported image bundle is
also retained for audit.

Use a separately trusted checkout of the verifier and policy, never policy
files downloaded beside an untrusted artifact. Install the pinned Cosign
version on consumer hosts. For an archive or SBOM:

```bash
# Download the exact named release asset and its adjacent bundle first.
make sast-cosign-verify-blob ARTIFACT=source.tar.gz
# Run extraction/installation only after successful verification.
```

For a released image, obtain its digest from `image-reference.txt` and verify
before use. Tags are convenience pointers, not integrity identifiers:

```bash
export IMAGE="$(cat image-reference.txt)"
make sast-cosign-verify IMAGE="$IMAGE"
# A standalone deployment gate verifies first, then sets the same digest:
scripts/deploy-verified-image.sh "$IMAGE" application example app
```

`make k8s-setup` and `make k8s-teardown` verify `K8S_KIND_IMAGE` before giving it
access to the host Docker socket. **The existing pinned historical image may
be unsigned.** After the first signed release, update `K8S_KIND_IMAGE` to its
verified digest; the gate deliberately rejects unsigned historical images.
No automatic back-signing is performed.

`make k8s-deploy` and the Kind CI deployment action inspect kubectl's rendered
JSON (including init containers, ephemeral containers, and nested templates)
and verify all references to the repository-owned image before applying the
same manifest. Tag-only references to that image fail. Existing third-party
Dependency-Track, PostgreSQL, Traefik, node, and build-tool images are **not**
covered by this repository's signer policy; they need independently approved
vendor identities and trust roots. These client/CI gates are not cluster-wide
admission control: restrict direct cluster write permissions, and install an
organization-approved admission controller with equivalent digest and identity
policies before allowing deployment paths outside these gates. No live cluster
or repository protection settings are changed by this implementation.

## Firmware integration

There is no firmware toolchain or hardware target in this Kubernetes template.
The reusable `.github/workflows/firmware.yml` is ready for a trusted build
workflow on `main` to upload a same-run artifact named `firmware-unsigned`
containing a nonempty `firmware.bin`, then call the signing workflow:

```yaml
sign-firmware:
  needs: build-firmware
  permissions:
    contents: read
    id-token: write
  uses: ./.github/workflows/firmware.yml
```

The result is an attempt-specific `firmware-signed-*` artifact (returned as the
`signed-artifact-id` workflow output), containing the binary and its bundle, followed
by an independent verification job without OIDC permission. Missing inputs fail;
no placeholder binary is produced. A downstream publication/flash job must
`needs: sign-firmware`, download that artifact, and verify again at the actual
acceptance boundary. The main Kubernetes release inventory rejects additional
firmware assets until its required artifact inventory and verification steps
are explicitly extended.

```bash
scripts/install-verified-firmware.sh firmware.bin /approved/staging/firmware.bin
```

This script copies the binary and bundle into a private temporary directory,
verifies that copy, and only then installs the verified bytes at the destination.
It does not flash hardware. A device-specific updater must consume that verified
file and enforce its own hardware compatibility and anti-rollback policy.

## Public or private Sigstore

This public repository explicitly selects `deployment: public` and
`public_metadata_permitted: true`. Public Fulcio/Rekor disclose signing identity
and artifact hashes; this choice must be reviewed before using the template for
confidential artifacts. Public trust starts at the root embedded in the pinned
Cosign binary and refreshes through the official Sigstore TUF repository in a
fresh isolated cache. The resulting `trusted_root.json` is passed explicitly to
signing and verification. Failure to obtain authenticated trust metadata fails
the operation; public verification currently requires access to the TUF service.

For confidentiality, network isolation, regulation, or issuer requirements,
select an approved private deployment **before signing**:

1. Provision private Fulcio, Rekor, and CT services. Fulcio must trust GitHub
   Actions OIDC (`https://token.actions.githubusercontent.com`) with audience
   `sigstore` for this workflow integration. A deployment that does not accept
   that issuer cannot use the GitHub Actions provider and is rejected.
2. Use `cosign signing-config create` with only approved HTTPS service endpoints
   and `cosign trusted-root create` with approved Fulcio CA chains, Rekor keys,
   and CT keys. Transfer these files through an authenticated administrative
   channel. Do not derive trust roots from an artifact's certificate or bundle.
3. Set `deployment: private`, remove the public opt-in, and add these entries to
   the reviewed policy (paths are relative to the policy file):

   ```json
   {
     "trusted_root": {"path": "private/trusted-root.json", "sha256": "<approved-sha256>"},
     "signing_config": {"path": "private/signing-config.json", "sha256": "<approved-sha256>"}
   }
   ```

4. Keep the exact identity allowlists and approved issuer. The verifier requires
   all three trust components. Signing requires explicit Fulcio and Rekor
   endpoints and rejects public `sigstore.dev` endpoints. It never initializes
   public TUF in private mode. Use runners and registries reachable within the
   approved network; private blob verification can use embedded bundle evidence
   and the approved static trust root without public network access.
5. Review and commit root/config digest updates during rotation; retain historical
   verification keys with validity intervals for supported artifacts. Test new
   roots against both valid and deliberately invalid artifacts before rollout.

For a fork, review and replace the repository/image allowlists and workflow
identities in the policy and callers. The original identities intentionally fail
closed in a fork. A private deployment is supported, not provisioned here.

## Validation and recovery

`python3 -m unittest discover -s tests/sigstore -v` runs policy tests locally.
The Sigstore CI workflow additionally verifies a real, signed upstream Cosign
release and rejects altered bytes/certificates, missing transparency evidence,
and incorrect issuer/identity. The test fixture's Google identity is confined
to temporary test policy; production trusts only the configured GitHub workflows.
Set `COSIGN_TEST_BLOB` and `COSIGN_TEST_BUNDLE` to that release binary and bundle
to run these cryptographic tests locally. Changed release workflows are checked
with pinned actionlint, and consumer shell scripts receive syntax checks.

Actual GitHub OIDC signing, registry promotion, and draft-release publication
must be exercised by a trusted `main` release run; local tests do not impersonate
GitHub OIDC. No release is created just to validate this change. On failure,
inspect the original run and draft assets; do not manually publish the draft or
bypass verification. Upload steps refuse overwrites, so investigate and remove
only stale draft assets before a deliberate retry. A failure after tag creation
can leave a verified image tag alongside a draft release; publication across
GHCR and GitHub Releases is not transactional.

References: [Cosign signing](https://docs.sigstore.dev/cosign/signing/overview/),
[private trust configuration](https://docs.sigstore.dev/cosign/system_config/custom_components/),
[Fulcio GitHub identity mapping](https://github.com/sigstore/fulcio/blob/main/docs/oidc.md),
[shared Docker action](https://github.com/sentenz/actions/blob/main/docker/action.yml).
