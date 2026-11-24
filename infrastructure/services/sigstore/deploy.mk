# Private Sigstore development inputs and admission ordering for k8s-deploy.
SIGSTORE_DIR := infrastructure/services/sigstore
SIGSTORE_STATE ?= .local/sigstore/$(KIND_CLUSTER_NAME)
SIGSTORE_TUF_REPO ?= $(SIGSTORE_STATE)/tuf
SIGSTORE_SUBMAKE = $(MAKE)
SIGSTORE_KUBECTL = kubectl --kubeconfig "$(K8S_KUBECONFIG)" --context "kind-$(KIND_CLUSTER_NAME)"

# Runtime secrets are created once and remain outside the rendered manifests.
k8s-sigstore-inputs:
	@umask 077
	state="$(SIGSTORE_STATE)"
	mkdir -p "$$state"
	exec 9>"$$state/deploy.lock"
	flock -n 9 || { echo "Another Sigstore input update is running." >&2; exit 1; }
	ca="$$(mkcert -CAROOT)/rootCA.pem"
	if [[ ! -s "$$ca" ]]; then echo 'Initialize the workstation CA with mkcert -install.' >&2; exit 1; fi
	uid="$$($(SIGSTORE_KUBECTL) get namespace kube-system -o jsonpath='{.metadata.uid}')"
	if [[ -f "$$state/cluster-id" && "$$(cat "$$state/cluster-id")" != "$$uid" ]]; then
		echo 'The Sigstore state directory belongs to another cluster.' >&2; exit 1
	fi
	for release in sigstore-system/kind-sigstore sigstore-policy/kind-policy; do
		ns="$${release%/*}"; name="$${release#*/}"
		if [[ -n "$$($(SIGSTORE_KUBECTL) -n "$$ns" get secret --ignore-not-found -l "owner=helm,name=$$name" -o name 2>/dev/null)" ]]; then
			echo "Existing Helm release $$release requires an ownership migration." >&2; exit 1
		fi
	done
	issuer="$$($(SIGSTORE_KUBECTL) get --raw /.well-known/openid-configuration | jq -er .issuer)"
	case "$$issuer" in
		https://kubernetes.default.svc|https://kubernetes.default.svc.cluster.local) ;;
		*) echo "Unsupported kind service account issuer: $$issuer" >&2; exit 1 ;;
	esac
	for ns in $$(sed -n 's/^  name: //p' "$(SIGSTORE_DIR)/base/namespaces.yaml"); do
		current="$$($(SIGSTORE_KUBECTL) get namespace "$$ns" --ignore-not-found -o json)"
		if [[ -n "$$current" ]] && ! jq -e '.metadata.labels["sigstore.local/owner"]=="template-k8s"' <<< "$$current" >/dev/null; then
			echo "Namespace already in use: $$ns" >&2; exit 1
		fi
	done
	printf '%s\n' "$$uid" > "$$state/cluster-id"
	$(SIGSTORE_KUBECTL) apply --server-side --field-manager=template-k8s-sigstore -k "$(SIGSTORE_DIR)/base"
	secret_missing() {
		local existing
		existing="$$($(SIGSTORE_KUBECTL) -n "$$1" get secret "$$2" --ignore-not-found -o name)" || exit 1
		[[ -z "$$existing" ]]
	}
	if secret_missing fulcio-system fulcio-server-secret; then
		if [[ -n "$$($(SIGSTORE_KUBECTL) -n ctlog-system get secret ctlog-secret --ignore-not-found -o name)" ]]; then
			echo 'Restore the original Fulcio signing Secret before redeploying.' >&2; exit 1
		fi
		openssl rand -hex 32 | tr -d '\n' > "$$state/fulcio.pass"
		openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -aes-256-cbc \
			-pass "file:$$state/fulcio.pass" -out "$$state/fulcio.key"
		openssl req -new -x509 -days 365 -subj '/O=kind/CN=Local Fulcio signing CA' \
			-addext 'basicConstraints=critical,CA:TRUE,pathlen:0' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
			-key "$$state/fulcio.key" -passin "file:$$state/fulcio.pass" -out "$$state/fulcio.crt"
		$(SIGSTORE_KUBECTL) -n fulcio-system create secret generic fulcio-server-secret \
			--from-file=private="$$state/fulcio.key" --from-file=cert="$$state/fulcio.crt" --from-file=password="$$state/fulcio.pass"
	fi
	if secret_missing rekor-system rekor-signer; then
		if [[ -n "$$($(SIGSTORE_KUBECTL) -n rekor-system get configmap rekor-config --ignore-not-found -o jsonpath='{.data.treeID}')" ]]; then
			echo 'Restore the original Rekor signing Secret before redeploying.' >&2; exit 1
		fi
		openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$$state/rekor.key"
		$(SIGSTORE_KUBECTL) -n rekor-system create secret generic rekor-signer --from-file=key.pem="$$state/rekor.key"
	fi
	if secret_missing ctlog-system ct-key-password; then
		openssl rand -hex 32 | tr -d '\n' | $(SIGSTORE_KUBECTL) -n ctlog-system create secret generic ct-key-password --from-file=password=/dev/stdin
	fi
	if secret_missing trillian-system trillian-mysql; then
		printf trillian > "$$state/mysql-database"
		printf trillian > "$$state/mysql-user"
		openssl rand -hex 32 | tr -d '\n' > "$$state/mysql-password"
		openssl rand -hex 32 | tr -d '\n' > "$$state/mysql-root-password"
		$(SIGSTORE_KUBECTL) -n trillian-system create secret generic trillian-mysql \
			--from-file="$$state/mysql-database" --from-file="$$state/mysql-user" \
			--from-file="$$state/mysql-password" --from-file="$$state/mysql-root-password"
	fi
	for entry in fulcio-system=fulcio.sigstore.local rekor-system=rekor.sigstore.local tuf-system=tuf.sigstore.local sigstore-registry=registry.local; do
		ns="$${entry%=*}"; host="$${entry#*=}"
		if ! openssl verify -CAfile "$$ca" -verify_hostname "$$host" "$$state/$$host.crt" >/dev/null 2>&1 ||
			! openssl x509 -checkend 86400 -noout -in "$$state/$$host.crt" >/dev/null; then
			mkcert -cert-file "$$state/$$host.crt" -key-file "$$state/$$host.key" "$$host"
		fi
		$(SIGSTORE_KUBECTL) -n "$$ns" create secret tls endpoint-tls \
			--cert="$$state/$$host.crt" --key="$$state/$$host.key" --dry-run=client -o yaml |
			$(SIGSTORE_KUBECTL) apply --server-side --field-manager=template-k8s-sigstore -f -
	done
	$(SIGSTORE_KUBECTL) -n sigstore-policy create configmap endpoint-ca --from-file=ca.crt="$$ca" --dry-run=client -o yaml |
		$(SIGSTORE_KUBECTL) apply --server-side --field-manager=template-k8s-sigstore -f -
	if secret_missing sigstore-registry registry-auth; then
		[[ -s "$$state/registry.password" ]] || openssl rand -hex 24 | tr -d '\n' > "$$state/registry.password"
		htpasswd -niB publisher < "$$state/registry.password" |
			$(SIGSTORE_KUBECTL) -n sigstore-registry create secret generic registry-auth --from-file=htpasswd=/dev/stdin
	fi
.PHONY: k8s-sigstore-inputs

# CRDs must be established and their webhooks ready before applying trust and policies.
k8s-sigstore-admission:
	@repo="$(SIGSTORE_TUF_REPO)"
	if [[ ! -s "$$repo/metadata/1.root.json" ]]; then
		echo "Sigstore resources applied. Publish the signed private TUF repository and rerun make k8s-deploy to enable admission."
		exit 0
	fi
	for target in trusted_root.json signing_config.v0.2.json; do
		compgen -G "$$repo/targets/*$$target" >/dev/null
	done
	for role in timestamp snapshot targets; do
		compgen -G "$$repo/metadata/*$$role.json" >/dev/null
	done
	$(SIGSTORE_KUBECTL) wait --for=condition=Established crd/trustroots.policy.sigstore.dev crd/clusterimagepolicies.policy.sigstore.dev --timeout=3m
	existing="$$($(SIGSTORE_KUBECTL) get trustroot/sigstore-kind --ignore-not-found -o json)"
	if [[ -n "$$existing" ]]; then
		jq -er '.spec.remote.root' <<< "$$existing" | base64 -d | cmp - "$$repo/metadata/1.root.json"
	fi
	$(SIGSTORE_KUBECTL) -n tuf-system create configmap tuf-targets --from-file="$$repo/targets" --dry-run=client -o yaml |
		$(SIGSTORE_KUBECTL) apply --server-side --field-manager=template-k8s-sigstore -f -
	$(SIGSTORE_KUBECTL) -n tuf-system create configmap tuf-metadata --from-file="$$repo/metadata" --dry-run=client -o yaml |
		$(SIGSTORE_KUBECTL) apply --server-side --field-manager=template-k8s-sigstore -f -
	$(SIGSTORE_KUBECTL) -n tuf-system rollout status deployment/tuf --timeout=3m
	published=false
	for attempt in {1..30}; do
		if $(SIGSTORE_KUBECTL) get --raw '/api/v1/namespaces/tuf-system/services/http:tuf:http/proxy/timestamp.json' |
			cmp -s - "$$repo/metadata/timestamp.json"; then published=true; break; fi
		sleep 5
	done
	if ! $$published; then echo "TUF mirror did not publish the requested timestamp." >&2; exit 1; fi
	$(SIGSTORE_KUBECTL) -n sigstore-policy rollout status deployment/kind-policy-policy-controller-webhook --timeout=3m
	jq -en --rawfile root "$$repo/metadata/1.root.json" \
		'{apiVersion:"policy.sigstore.dev/v1alpha1",kind:"TrustRoot",metadata:{name:"sigstore-kind"},
		spec:{remote:{mirror:"https://tuf.sigstore.local",root:($$root|@base64)}}}' |
		$(SIGSTORE_KUBECTL) apply -f -
	$(SIGSTORE_KUBECTL) wait --for=condition=Ready trustroot/sigstore-kind --timeout=3m
	issuer="$$($(SIGSTORE_KUBECTL) get --raw /.well-known/openid-configuration | jq -er .issuer)"
	sed "s|KUBE_ISSUER|$$issuer|" "$(SIGSTORE_DIR)/overlays/dev/policy.yaml" | $(SIGSTORE_KUBECTL) apply -f -
	$(SIGSTORE_KUBECTL) wait --for=condition=Ready clusterimagepolicy/sigstore-kind-signer --timeout=3m
.PHONY: k8s-sigstore-admission

## Verify private Sigstore endpoints, trust and admission readiness
k8s-sigstore-status:
	@$(SIGSTORE_KUBECTL) get --raw /readyz
	$(SIGSTORE_KUBECTL) get trustroot/sigstore-kind clusterimagepolicy/sigstore-kind-signer
	ca="$$(mkcert -CAROOT)/rootCA.pem"
	curl -fsS --cacert "$$ca" https://fulcio.sigstore.local/healthz
	curl -fsS --cacert "$$ca" https://rekor.sigstore.local/api/v1/log | jq -e '.treeSize'
	curl -fsS --cacert "$$ca" https://tuf.sigstore.local/timestamp.json | jq -er '.signed.expires'
	$(SIGSTORE_KUBECTL) get --raw '/api/v1/namespaces/ctlog-system/services/http:ctlog:6962-tcp/proxy/sigstorescaffolding/ct/v1/get-sth' |
		jq -e 'select(.tree_head_signature != null) | .tree_size'
.PHONY: k8s-sigstore-status

## Verify a signed image, a blob bundle and unsigned image rejection
k8s-sigstore-test:
	@umask 077
	: "$${SIGNED_IMAGE:?Set SIGNED_IMAGE to a signed digest}" "$${UNSIGNED_IMAGE:?Set UNSIGNED_IMAGE to an unsigned digest}"
	: "$${ARTIFACT:?Set ARTIFACT to the original blob}" "$${ARTIFACT_BUNDLE:?Set ARTIFACT_BUNDLE to its Sigstore bundle}"
	for reference in "$$SIGNED_IMAGE" "$$UNSIGNED_IMAGE"; do
		[[ "$$reference" =~ @sha256:[0-9a-f]{64}$$ ]]
	done
	[[ "$$SIGNED_IMAGE" != "$$UNSIGNED_IMAGE" ]]
	export TUF_ROOT="$$(mktemp -d)"
	trap 'rm -rf "$$TUF_ROOT"' EXIT
	export SSL_CERT_FILE="$${SSL_CERT_FILE:-$$(mkcert -CAROOT)/rootCA.pem}"
	cosign initialize --mirror https://tuf.sigstore.local --root "$(SIGSTORE_TUF_REPO)/metadata/1.root.json"
	trusted="$$(find "$$TUF_ROOT" -type f -path '*/targets/trusted_root.json')"
	test -s "$$trusted"
	issuer="$$($(SIGSTORE_KUBECTL) get --raw /.well-known/openid-configuration | jq -er .issuer)"
	verify=(--trusted-root "$$trusted" --certificate-oidc-issuer "$$issuer"
		--certificate-identity https://kubernetes.io/namespaces/sigstore-ci/serviceaccounts/release)
	cosign verify "$${verify[@]}" "$$SIGNED_IMAGE" >/dev/null
	cosign verify-blob "$${verify[@]}" --bundle "$$ARTIFACT_BUNDLE" "$$ARTIFACT"
	cp "$$ARTIFACT" "$$TUF_ROOT/modified"
	printf '\nmodified\n' >> "$$TUF_ROOT/modified"
	if cosign verify-blob "$${verify[@]}" --bundle "$$ARTIFACT_BUNDLE" "$$TUF_ROOT/modified"; then exit 1; fi
	pull='{"spec":{"imagePullSecrets":[{"name":"registry-pull"}]}}'
	$(SIGSTORE_KUBECTL) -n sigstore-test run sigstore-check --image="$$SIGNED_IMAGE" --overrides="$$pull" --restart=Never --dry-run=server
	if $(SIGSTORE_KUBECTL) -n sigstore-test run sigstore-check --image="$$UNSIGNED_IMAGE" --overrides="$$pull" --restart=Never --dry-run=server > "$$TUF_ROOT/denial" 2>&1; then
		echo 'Unsigned image passed admission.' >&2; exit 1
	fi
	grep -E 'admission webhook.*denied' "$$TUF_ROOT/denial"
	grep -F sigstore-kind-signer "$$TUF_ROOT/denial"
.PHONY: k8s-sigstore-test
