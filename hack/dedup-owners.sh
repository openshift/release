#!/bin/sh
#
# usage: dedup-owners.sh DIR...

for DIR in "${@}"
do
	find "${DIR}" -type f -name OWNERS | while read CHILD
	do
		CHILD_HASH="$(sha1sum < "${CHILD}")"
		PARENT="$(dirname "$(dirname "${CHILD}")")/OWNERS"
		if test ! -f "${PARENT}"
		then
			continue
		fi
		PARENT_HASH="$(sha1sum < "${PARENT}")"
		if test "${CHILD_HASH}" = "${PARENT_HASH}"
		then
			echo "Link ${CHILD} to matching parent"
			ln -fs ../OWNERS "${CHILD}"
		fi
	done
done
