#!/bin/sh 

# Used on periodic-image-mirroring-*
 
set -o errexit 
 
if [ -z ${MAPPING_FILE_PREFIX} ]; then >&2 echo "MAPPING_FILE_PREFIX is unset or empty" && exit 1; else echo "MAPPING_FILE_PREFIX is set to $MAPPING_FILE_PREFIX"; fi 
 
dry_run="${dry_run:-true}" 

if [ -f /tmp/user/.docker/config.json ]; then
    cp /tmp/user/.docker/config.json /tmp/config.json
else
    echo "WARN: /tmp/user/.docker/config.json has not been provided"
fi

oc registry login --to /tmp/config.json 

if [ -d /etc/qci-robot-credentials ]; then
  cred="$(cat /etc/qci-robot-credentials/username):$(cat /etc/qci-robot-credentials/password)"
  oc registry login --auth-basic="$cred" --to=/tmp/config.json --registry=quay.io/openshift/ci
else
  echo "WARN: /etc/qci-robot-credentials has not been provided"
fi

expand_qci_prefix_line() {
	_from="$1"
	_to="$2"
	_repo="${_from%%:*}"
	_tagpat="${_from#*:}"
	_prefix="${_tagpat%_*}"
	_p="${_prefix}_"
	_token_file="${QUAY_OAUTH_TOKEN_FILE:-}"
	if [ -z "${_token_file}" ]; then
		if [ -f /etc/qci-tag-list-credentials/token ]; then
			_token_file=/etc/qci-tag-list-credentials/token
		else
			_token_file=/etc/qci-pruner-credentials/token
		fi
	fi
	if [ ! -f "${_token_file}" ]; then
		echo "ERROR: missing Quay OAuth token to expand ${_prefix}_*" >&2
		return 1
	fi
	_page=1
	_found=0
	_has_additional=false
	_out="$(mktemp)"
	_curl_cfg="$(mktemp)"
	chmod 600 "${_curl_cfg}"
	{
		printf 'header = "Authorization: Bearer '
		tr -d '\n\r' <"${_token_file}"
		printf '"\nheader = "Accept: application/json"\n'
	} >"${_curl_cfg}"
	while [ "${_page}" -le 50 ]; do
		_url="https://quay.io/api/v1/repository/openshift/ci/tag/?onlyActiveTags=true&filter_tag_name=like:${_prefix}_&limit=100&page=${_page}"
		_body="$(curl -sS -f --connect-timeout 10 --max-time 60 -K "${_curl_cfg}" "${_url}")" || { rm -f "${_out}" "${_curl_cfg}"; return 1; }
		_has_additional="$(printf '%s' "${_body}" | grep -oE '"has_additional"[[:space:]]*:[[:space:]]*(true|false)' | head -1 | grep -oE 'true|false' || true)"
		[ -n "${_has_additional}" ] || _has_additional=false
		_names="$(printf '%s' "${_body}" | grep -oE '"name":[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' || true)"
		[ -n "${_names}" ] || break
		while IFS= read -r _full; do
			[ -n "${_full}" ] || continue
			case "${_full}" in
			"${_p}"*)
				_suf="${_full#"${_p}"}"
				case "${_suf}" in
				""|incoming|*_incoming|*_incoming_*|_pre|*__pre|_post1|*__post1) ;;
				*)
					printf '%s:%s_%s %s:%s\n' "${_repo}" "${_prefix}" "${_suf}" "${_to}" "${_suf}" >>"${_out}"
					_found=$((_found + 1))
					;;
				esac
				;;
			esac
		done <<EOF
${_names}
EOF
		[ "${_has_additional}" = "true" ] || break
		_page=$((_page + 1))
	done
	if [ "${_has_additional}" = "true" ]; then
		echo "ERROR: Quay tag list for ${_prefix}_* exceeded page limit (has_additional still true after page 50)" >&2
		rm -f "${_out}" "${_curl_cfg}"
		return 1
	fi
	if [ "${_found}" -eq 0 ]; then
		echo "ERROR: no QCI tags matched ${_prefix}_*" >&2
		rm -f "${_out}" "${_curl_cfg}"
		return 1
	fi
	cat "${_out}"
	rm -f "${_out}" "${_curl_cfg}"
	return 0
}

prepare_mapping() {
	_src="$1"
	if ! grep -qE '(quay\.io/openshift/ci|quay-proxy\.ci\.openshift\.org/openshift/ci):[^[:space:]]+_\*' "${_src}"; then
		echo "${_src}"
		return 0
	fi
	_dst="$(mktemp)"
	while IFS= read -r _line || [ -n "${_line}" ]; do
		case "${_line}" in
		''|'#'*) continue ;;
		esac
		_from="$(echo "${_line}" | awk '{print $1}')"
		_to="$(echo "${_line}" | awk '{print $2}')"
		_repo="${_from%%:*}"
		_tagpat="${_from#*:}"
		case "${_repo}" in
		quay.io/openshift/ci|quay-proxy.ci.openshift.org/openshift/ci) ;;
		*) echo "${_line}" >>"${_dst}"; continue ;;
		esac
		case "${_tagpat}" in
		*_*)
			_star="${_tagpat##*_}"
			_prefix="${_tagpat%_*}"
			if [ "${_star}" != "*" ] || [ -z "${_prefix}" ]; then
				echo "${_line}" >>"${_dst}"
				continue
			fi
			;;
		*) echo "${_line}" >>"${_dst}"; continue ;;
		esac
		echo "Expanding QCI ${_prefix}_* -> ${_to}:<tag>" >&2
		expand_qci_prefix_line "${_from}" "${_to}" >>"${_dst}" || { rm -f "${_dst}"; return 1; }
	done <"${_src}"
	echo "${_dst}"
}

failures=0 
for mapping in /etc/imagemirror/${MAPPING_FILE_PREFIX}*; do 
  mirror_file="$(prepare_mapping "${mapping}")" || { echo "ERROR: Failed to expand mapping $mapping"; failures=$((failures+1)); continue; }
  echo "Running: oc image mirror --dry-run=${dry_run} --keep-manifest-list -f=$mirror_file --skip-multiple-scopes" 
  if ! oc image mirror --dry-run=${dry_run} --keep-manifest-list -a /tmp/config.json -f="$mirror_file" --skip-multiple-scopes; then 
    echo "ERROR: Failed to mirror images from $mapping" 
    failures=$((failures+1)) 
  fi 
  if [ "${mirror_file}" != "${mapping}" ]; then
    rm -f "${mirror_file}"
  fi
done 
 
echo "finished" 
exit $failures
