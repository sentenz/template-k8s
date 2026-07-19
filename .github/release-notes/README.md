# Release Notes

Semantic-Release derives version changes and release notes from the final commit message on `main`.

For a breaking change, the final commit must use both the `!` marker and an explicit `BREAKING CHANGE:` footer. The marker determines the major version; the footer provides the migration information rendered in the GitHub release and `CHANGELOG.md`.

```text
refactor!: replace the local Kubernetes runtime

BREAKING CHANGE: Local development now uses Kind instead of K3s. Remove the existing K3s environment, run `make k8s-setup`, and update kubeconfig references from `examples/config/kubeconfig.yaml` to `config/kubeconfig.yaml`.
```

When squash-merging a pull request, verify that the squash commit body preserves the footer. A header-only `!` can indicate a major release without retaining enough information for actionable release notes in every parser and preset combination.

Version-specific correction sources in this directory are synchronized to their existing GitHub releases by the corresponding workflow under `.github/workflows/`.
