#!/bin/sh 

# Used on periodic-image-mirroring-*
 
set -o errexit 
 
if [ -z "${MAPPING_FILE_PREFIX}" ]; then >&2 echo "MAPPING_FILE_PREFIX is unset or empty" && exit 1; else echo "MAPPING_FILE_PREFIX is set to $MAPPING_FILE_PREFIX"; fi
 
dry_run="${dry_run:-true}" 

config_dir="$(mktemp -d)" || { echo "ERROR: Failed to create registry config directory"; exit 1; }
trap 'rm -rf "${config_dir}"' 0
config_file="${config_dir}/config.json"

if [ -f /tmp/user/.docker/config.json ]; then
    cp /tmp/user/.docker/config.json "${config_file}"
else
    echo "WARN: /tmp/user/.docker/config.json has not been provided"
fi

oc registry login --to "${config_file}"

if [ -d /etc/qci-robot-credentials ]; then
  cred="$(cat /etc/qci-robot-credentials/username):$(cat /etc/qci-robot-credentials/password)"
  oc registry login --auth-basic="$cred" --to="${config_file}" --registry=quay.io/openshift/ci
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
		echo "ERROR: missing Quay OAuth token for QCI expansion" >&2
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
		echo "ERROR: Quay tag list exceeded page limit (has_additional still true after page 50)" >&2
		rm -f "${_out}" "${_curl_cfg}"
		return 1
	fi
	if [ "${_found}" -eq 0 ]; then
		echo "ERROR: no QCI tags matched the requested prefix" >&2
		rm -f "${_out}" "${_curl_cfg}"
		return 1
	fi
	cat "${_out}"
	rm -f "${_out}" "${_curl_cfg}"
	return 0
}

prepare_mapping() {
	_src="$1"
	_mapping_id="$2"
	if ! grep -qE '(quay\.io/openshift/ci|quay-proxy\.ci\.openshift\.org/openshift/ci):[^[:space:]]+_\*' "${_src}"; then
		echo "${_src}"
		return 0
	fi
	_dst="$(mktemp)"
	_expand_failed=0
	_entry=0
	while IFS= read -r _line || [ -n "${_line}" ]; do
		case "${_line}" in
		''|'#'*) continue ;;
		esac
		_entry=$((_entry + 1))
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
		echo "Expanding QCI mapping ${_mapping_id}, entry ${_entry}" >&2
		expand_qci_prefix_line "${_from}" "${_to}" >>"${_dst}" || {
			echo "ERROR: Failed to expand QCI mapping ${_mapping_id}, entry ${_entry}" >&2
			_expand_failed=1
		}
	done <"${_src}"
	echo "${_dst}"
	[ "${_expand_failed}" -eq 0 ] || return 2
}

mirror_mapping_file() {
	mirror_file="$1"
	mapping_id="$2"
	if [ ! -r "${mirror_file}" ]; then
		echo "ERROR: Prepared mapping ${mapping_id} is not readable"
		return 1
	fi
	echo "Running batch mirror for mapping ${mapping_id}"
	if oc image mirror --dry-run="${dry_run}" --keep-manifest-list -a "${config_file}" -f="${mirror_file}" --skip-multiple-scopes; then
		return 0
	fi
	echo "WARNING: Batch mirror for mapping ${mapping_id} failed; retrying each source separately"
	processed_sources="$(mktemp)" || {
		echo "ERROR: Failed to create source tracking file for mapping ${mapping_id}"
		return 1
	}
	source_mapping="$(mktemp)" || {
		echo "ERROR: Failed to create source mapping file for mapping ${mapping_id}"
		rm -f "${processed_sources}"
		return 1
	}
	mapping_failures=0
	source_count=0

	# source_mapping is a separate mktemp-created file, never mirror_file.
	# shellcheck disable=SC2094
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in
		''|'#'*) continue ;;
		esac
		source="$(printf '%s\n' "${line}" | awk '{print $1}')"
		[ -n "${source}" ] || continue
		if grep -Fqx "${source}" "${processed_sources}"; then
			continue
		fi
		source_count=$((source_count + 1))
		if ! printf '%s\n' "${source}" >>"${processed_sources}"; then
			echo "ERROR: Failed to track source group ${source_count} for mapping ${mapping_id}"
			mapping_failures=1
			continue
		fi
		if ! awk -v source="${source}" '$1 == source { print }' "${mirror_file}" >"${source_mapping}"; then
			echo "ERROR: Failed to prepare source group ${source_count} for mapping ${mapping_id}"
			mapping_failures=1
			continue
		fi
		if ! destination_count="$(awk 'END { print NR + 0 }' "${source_mapping}")"; then
			echo "ERROR: Failed to count destinations for source group ${source_count} in mapping ${mapping_id}"
			mapping_failures=1
			continue
		fi
		echo "Running source group ${source_count} for mapping ${mapping_id} (${destination_count} destinations)"
		if ! oc image mirror --dry-run="${dry_run}" --keep-manifest-list -a "${config_file}" -f="${source_mapping}" --skip-multiple-scopes; then
			echo "ERROR: Failed to mirror source group ${source_count} for mapping ${mapping_id} (${destination_count} destinations)"
			mapping_failures=1
		fi
	done <"${mirror_file}"

	rm -f "${processed_sources}" "${source_mapping}"
	return "${mapping_failures}"
}

failures=0 
mapping_count=0
for mapping in "/etc/imagemirror/${MAPPING_FILE_PREFIX}"*; do
  mapping_count=$((mapping_count + 1))
  if mirror_file="$(prepare_mapping "${mapping}" "${mapping_count}")"; then
    prepare_status=0
  else
    prepare_status=$?
  fi
  case "${prepare_status}" in
  0) ;;
  2)
    echo "ERROR: Mapping ${mapping_count} has QCI expansion failures; mirroring valid entries"
    failures=$((failures+1))
    if [ ! -s "${mirror_file}" ]; then
      echo "ERROR: No valid mappings remain after expansion failures in mapping ${mapping_count}"
      rm -f "${mirror_file}"
      continue
    fi
    ;;
  *)
    echo "ERROR: Failed to prepare mapping ${mapping_count}"
    failures=$((failures+1))
    continue
    ;;
  esac
  if ! mirror_mapping_file "${mirror_file}" "${mapping_count}"; then
    echo "ERROR: Failed to mirror one or more source groups for mapping ${mapping_count}"
    failures=$((failures+1)) 
  fi 
  if [ "${mirror_file}" != "${mapping}" ]; then
    rm -f "${mirror_file}"
  fi
done 
 
echo "finished" 
exit $failures
