#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
[[ "${GITHUB_REF_TYPE}" == tag ]] || { echo '::error::Select a release tag'; exit 1; }
[[ "${RELEASE_VERSION}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo '::error::Expected a stable SemVer tag without a v prefix'; exit 1;
}
[[ "${GITHUB_REF}" == "refs/tags/${RELEASE_VERSION}" ]] || {
  echo '::error::Version must match the workflow tag'; exit 1;
}
# Fetch into dedicated refs; never switch the checked-out event commit.
git fetch --no-tags origin "+refs/heads/main:refs/remotes/origin/main" \
  "+refs/tags/${RELEASE_VERSION}:refs/release-validation/tag"
if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
  git fetch --unshallow --no-tags origin main
fi
commit="$(git rev-parse HEAD)"
[[ "$commit" == "$(git rev-parse "${GITHUB_SHA}^{commit}")" ]]
[[ "$commit" == "$(git rev-parse 'refs/release-validation/tag^{commit}')" ]] || {
  echo '::error::Release tag moved after this run started'; exit 1;
}
git merge-base --is-ancestor "$commit" refs/remotes/origin/main || {
  echo '::error::Release commit must be reachable from main'; exit 1;
}
