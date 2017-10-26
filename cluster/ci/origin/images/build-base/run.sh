#!/bin/bash
if [[ -n "${UMASK}" ]]; then
	umask "${UMASK}" && "$@"
else
	"$@"
fi
