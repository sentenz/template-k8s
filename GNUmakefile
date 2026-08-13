# SPDX-License-Identifier: Apache-2.0

include Makefile

K8S_HOSTNAME ?=
K8S_CERTIFICATE_DIR ?= $(K8S_CLUSTER_PATH)
K8S_CERTIFICATE_DAYS ?= 365

# Usage: make k8s-certificate-generate K8S_HOSTNAME=<hostname-or-url> [K8S_CERTIFICATE_DIR=<directory>] [K8S_CERTIFICATE_DAYS=<days>]
#
## Generate a self-signed TLS certificate for a local hostname or URL
k8s-certificate-generate:
	@raw_hostname="$(strip $(K8S_HOSTNAME))"
	if [[ -z "$$raw_hostname" ]]; then
		echo "usage: make k8s-certificate-generate K8S_HOSTNAME=<hostname-or-url> [K8S_CERTIFICATE_DIR=<directory>] [K8S_CERTIFICATE_DAYS=<days>]" >&2
		exit 1
	fi

	hostname="$$raw_hostname"
	hostname="$${hostname#*://}"
	hostname="$${hostname%%/*}"
	hostname="$${hostname%%\?*}"
	hostname="$${hostname%%\#*}"
	hostname="$${hostname%%:*}"

	if (( $${#hostname} > 253 )) || [[ ! "$$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$$ ]] || [[ "$$hostname" == *..* ]]; then
		echo "error: invalid hostname derived from '$(K8S_HOSTNAME)': $$hostname" >&2
		exit 1
	fi
	if [[ ! "$(K8S_CERTIFICATE_DAYS)" =~ ^[1-9][0-9]*$$ ]]; then
		echo "error: K8S_CERTIFICATE_DAYS must be a positive integer" >&2
		exit 1
	fi
	if ! command -v openssl >/dev/null 2>&1; then
		echo "error: openssl is required to generate a self-signed certificate" >&2
		exit 1
	fi

	output_dir="$(K8S_CERTIFICATE_DIR)"
	certificate_path="$$output_dir/$$hostname+1.pem"
	private_key_path="$$output_dir/$$hostname+1-key.pem"
	mkdir -p "$$output_dir"

	umask 077
	openssl req \
		-x509 \
		-nodes \
		-newkey rsa:2048 \
		-sha256 \
		-days "$(K8S_CERTIFICATE_DAYS)" \
		-keyout "$$private_key_path" \
		-out "$$certificate_path" \
		-subj "/CN=$$hostname" \
		-addext "subjectAltName=DNS:$$hostname"
	chmod 0644 "$$certificate_path"

	printf 'Generated self-signed certificate for %s\n  certificate: %s\n  private key: %s\n' \
		"$$hostname" "$$certificate_path" "$$private_key_path"
.PHONY: k8s-certificate-generate
