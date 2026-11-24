#!/bin/bash
#
# Install and configure all dependencies essential for development.

# -x: print a trace (debug)
# -u: treat unset variables
# -o pipefail: return value of a pipeline
set -uo pipefail

# Include Scripts

source ./../scripts/shell/pkg.sh

# Constant Variables

readonly -A NPM_PACKAGES=(
  ["lefthook"]="2.1.6"
)

# Control Flow Logic

function setup() {
  local -i retval=0

  pkg_npm_install_list NPM_PACKAGES
  ((retval |= $?))

  pkg_npm_clean
  ((retval |= $?))

  return "${retval}"
}

setup
exit "${?}"
