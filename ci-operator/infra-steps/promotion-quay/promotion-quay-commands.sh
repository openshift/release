#!/usr/bin/env bash
set -o pipefail

QCI_REPO="quay-proxy.ci.openshift.org/openshift/ci"

resolve_qci_pullspec() {
	local src="$1"
	if [[ "$src" == "${QCI_REPO}@sha256:"* ]]; then
		echo "$src"
		return 0
	fi
	if [[ "$src" == *"@sha256:"* ]]; then
		echo "${QCI_REPO}@${src#*@}"
		return 0
	fi
	local dig
	dig=$(oc image info "$src" --registry-config="$REGISTRY_CONFIG" -o jsonpath='{.digest}' 2>/dev/null)
	if [[ -z "$dig" ]]; then
		dig=$(oc image info "$src" --registry-config="$REGISTRY_CONFIG" -o jsonpath='{.list[0].digest}' 2>/dev/null)
	fi
	if [[ -z "$dig" ]]; then
		echo "quay promotion: failed to resolve digest for: $src" >&2
		return 1
	fi
	echo "${QCI_REPO}@${dig}"
}

if [[ -n "$PRUNE_IMAGES" ]]; then
	# shellcheck disable=SC2086
	oc image mirror --loglevel=2 --keep-manifest-list \
		--registry-config="$REGISTRY_CONFIG" --max-per-registry=10 \
		$PRUNE_IMAGES || true
fi

if [[ -n "$MIRROR_IMAGES" ]]; then
	for r in {1..5}; do
		echo "Mirror attempt $r"
		# shellcheck disable=SC2086
		oc image mirror --loglevel=2 --keep-manifest-list \
			--registry-config="$REGISTRY_CONFIG" --max-per-registry=10 \
			$MIRROR_IMAGES && break
		backoff=$(($RANDOM % 120))s
		echo "Sleeping randomized $backoff before retry"
		sleep "$backoff"
	done
fi

if [[ -n "$TAG_SPECS" ]]; then
	set +e

	all_args=""
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		src="${line%% *}"
		dst="${line#* }"
		resolved=$(resolve_qci_pullspec "$src") || continue
		all_args="${all_args} ${resolved} ${dst}"
	done <<< "$TAG_SPECS"

	if [[ -n "$all_args" ]]; then
		for r in {1..2}; do
			echo "Tag attempt $r (all together)"
			# shellcheck disable=SC2086
			oc tag --source=docker --loglevel=2 \
				--reference-policy='source' --import-mode='PreserveOriginal' \
				--reference $all_args && break
			:
		done
	fi

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		src="${line%% *}"
		dst="${line#* }"
		for r in {1..3}; do
			echo "Tag attempt $r (individual)"
			resolved=$(resolve_qci_pullspec "$src") || break
			oc tag --source=docker --loglevel=2 \
				--reference-policy='source' --import-mode='PreserveOriginal' \
				--reference "$resolved" "$dst" && break
			backoff=$(($RANDOM % 120))s
			echo "Sleeping randomized $backoff before retry"
			sleep "$backoff"
		done
	done <<< "$TAG_SPECS"

	set -e
fi
