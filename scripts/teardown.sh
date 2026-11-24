#!/bin/bash
#
# Remove development artifacts and restore the host to its pre-setup state.

# -x: print a trace (debug)
# -u: treat unset variables
# -o pipefail: return value of a pipeline
set -uo pipefail

# Include Scripts

source ./../scripts/shell/pkg.sh

# Constant Variables

readonly -A GO_PACKAGES=(
  [""]=""
)

# Control Flow Logic

function teardown() {
  # NOTE Use reversed order of `bootstrap.sh` and `setup.sh` scripts for tearing down the environment

  local -i retval=0

  pkg_go_uninstall_list GO_PACKAGES
  ((retval |= $?))

  pkg_go_clean
  ((retval |= $?))

  return "${retval}"
}

teardown
exit "${?}"
