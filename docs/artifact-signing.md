# Keyless artifact signing

The release pipeline uses Cosign **v3.0.2** with GitHub Actions' built-in
`github-actions` identity provider and the **sigstore** audience. Ephemeral keys
exist only during signing; no signing key or OIDC token is stored as a secret,
artifact, or log entry. `id-token: write` is confined to signing jobs and the
reusable-workflow calls that delegate to them. Verification needs no OIDC grant.

## Release contract

1. Semantic Release creates a tag and **draft** release. It does not publish the
   release page. GitHub's automatic source links are not signed release assets.
2. The Docker workflow pushes an untagged manifest, signs its Buildx SHA-256
   digest, verifies the registry signature with the approved issuer and exact
   workload identity, then creates version/latest tags pointing to that digest.
   Registry upload is necessary before OCI signing; untagged candidates are not
   accepted releases. Consumers must verify digest references, never trust tags.
3. The SBOM workflow scans both formats, creates a reproducible `source.tar.gz`
   (`git archive` plus `gzip -n`), signs all three files, verifies them, and attaches
   each file with its adjacent `.sigstore.json` bundle to the draft release.
4. A separate job with **no OIDC permission** downloads all assets, requires the
   archive and both SBOMs, verifies every payload and the image digest again, and
   only then publishes the release. Any failed dependency prevents publication.

Cosign hashes file bytes; signatures bind immutable digests, not filenames.
Bundles retain signatures, certificates and transparency evidence. OCI bundles
are retained with the image in GHCR: registry retention must preserve referrers
and signatures as long as the image remains installable. Release bundles remain
release assets, independent of Actions log retention. Record the release tag,
commit, image digest and workflow run in audit records. SBOMs are signed files,
not claims that the source SBOM describes every package inside the image.

## Reviewed trust policy

`security/sigstore/policy.json` is the trust boundary. The initial identity is
exactly the **calling** `semantic-release.yml` workflow on `refs/heads/main` in
`sentenz/template-k8s`; reusable workflows inherit this certificate identity.
Forks, pull requests, other workflows and other refs are not authorized.
Changing a repository name or release branch requires an explicit policy review.
Protect `main`, release tags, policy files, workflows and these scripts through
CODEOWNERS review and branch/ruleset enforcement. GitHub administrators must
configure those repository settings; source files cannot enforce them alone.

The checked-in profile selects public Sigstore for this public template and
explicitly records permission to disclose metadata. Public Fulcio/Rekor metadata
includes workflow/repository identity and artifact digests. Public trust roots
come from Cosign's embedded TUF root and authenticated TUF updates, not from an
artifact-supplied certificate. Cosign verifies the chain, exact issuer/identity,
artifact digest, and required log/CT evidence without insecure bypass flags.

Before using confidential artifacts, incompatible OIDC issuers, regulated or
isolated environments, select `deployment: private`. Provision the approved
operator's `security/sigstore/trusted-root.json` (Sigstore TrustedRoot format)
and `security/sigstore/signing-config.json` (SigningConfig format) through a
reviewed change, and change issuer/identities to the approved values. Both files
are mandatory; there is no public fallback. The private deployment must support
GitHub Actions OIDC with audience `sigstore`, Fulcio, certificate transparency,
and Rekor evidence compatible with Cosign v3. Otherwise this GitHub integration
must not be used. Configure reachable services/self-hosted runners for isolated
networks. Review endpoints, roots, validity periods and rotation out of band;
never download trust roots from the artifact location. Custom environments that
require skipping log or certificate verification are deliberately unsupported.

## Consumption and installation

Install the pinned Cosign version through a trusted distribution and Python 3;
for manifest verification also install the hash-pinned dependencies:

```sh
python3 -m pip install --require-hashes -r security/sigstore/requirements.txt
python3 scripts/artifact-security.py verify-image 'ghcr.io/sentenz/k8s@sha256:<64-hex-digest>'
python3 scripts/artifact-security.py verify-file downloads/source.tar.gz
python3 scripts/artifact-security.py verify-file downloads/sbom.spdx.json
python3 scripts/install-artifact.py downloads/firmware.bin /opt/firmware/firmware.bin
```

File verification requires the adjacent `<filename>.sigstore.json`. Installation
copies the file and bundle into a private temporary directory, verifies that
snapshot, and atomically replaces the destination with the verified bytes. A
failure preserves the previous installation. Firmware flashing/bootloader trust
and rollback protection require device-specific integration beyond this file
installation gate. Extract archives only after successful verification.

`make k8s-deploy` and the Kind CI action verify every rendered container,
init-container and ephemeral-container image before applying the same manifest.
Image references must include SHA-256 digests and their repository must have an
explicit exact issuer/identity mapping in policy. The current upstream charts
are **blocked** until their images are digest-pinned and their publisher's
signing identities have been independently approved. Unsigned dependencies need
a separately reviewed rebuild/signing pipeline; do not add an allow-unsigned
exception. Bootstrap/control-plane and build-tool images are outside the
application-manifest gate. The repository-owned Kind tools image used by
`make k8s-setup` and `make k8s-teardown` is also verified before execution; its
historical default digest must be replaced with a newly signed release.

These gates cover repository-managed deployment paths. Direct `kubectl`, GitOps
controllers, later Pod injection and other cluster writers require an enforcing
admission controller (for example Sigstore policy-controller) configured with
the same approved trust, fail-closed webhook behavior and coverage for all
application namespaces. Restrict RBAC to prevent bypass. This change does not
install or claim an active cluster-wide admission controller.

## Firmware producers and other files

There is no firmware compiler or device installer in this repository. A firmware
producer added to the approved release workflow must finish building first,
then invoke the same signing entry point in a job with `contents: read` and
`id-token: write`:

```sh
python3 scripts/artifact-security.py sign-file dist/firmware.bin
```

This signs and immediately verifies the file. Transfer both `firmware.bin` and
`firmware.bin.sigstore.json` together, and attach them to the draft release.
The final publication gate rejects any extra unsigned payload, including
firmware. Do not accept arbitrary external workflow artifacts for signing;
bind producer output to the same trusted release run and commit. New producer
workflows require separately approved exact workload identities.

## Validation and rollout

Run `python3 -m unittest discover -s tests/signing -v`. Tests cover identity and
issuer arguments, OIDC provider/audience, missing bundles, mutable and unknown
images, failed verifications, private configuration, PodSpec image enumeration,
and installation failure/byte-preservation. With Cosign installed, a real public
release bundle is verified, then tampered bytes, missing log evidence, a wrong
issuer and an unauthorized identity are rejected. They do not mint GitHub OIDC tokens.
A real release run is required to validate Fulcio, Rekor, GHCR and GitHub draft
publication end to end. No historical release or image is implicitly trusted;
produce a new signed release and update deployment digest pins before rollout.

References: [Sigstore CI](https://docs.sigstore.dev/quickstart/quickstart-ci/),
[blob bundles](https://docs.sigstore.dev/cosign/signing/signing_with_blobs/),
[private components](https://docs.sigstore.dev/cosign/system_config/custom_components/).

If a release fails after tag creation, rerun the failed jobs in the original
workflow run after resolving the cause. A fresh Semantic Release run may see
the existing tag and produce no new release. Never publish the draft manually
to bypass verification. No deployment or release was executed while preparing
this implementation.
