#!/bin/bash

temp=$(mktemp -d -t ocm-XXXXX)
cd "$temp" || exit 1

echo "INFO Setting clusterpool list files"
LIST_FILE="$SHARED_DIR/$CLUSTERPOOL_LIST_FILE"
MANAGED_LIST_FILE="$SHARED_DIR/$CLUSTERPOOL_MANAGED_LIST_FILE"
echo "     LIST_FILE        : $LIST_FILE"
echo "     MANAGED_LIST_FILE: $MANAGED_LIST_FILE"

echo "INFO Copying make file"
echo "     MAKEFILE: $MAKEFILE"
cp "$MAKEFILE" ./Makefile

echo "INFO Setting location of oc and jq binaries for build harness"
OC=$(which oc)
JQ=$(which jq)
export OC
export JQ
if [[ -z "$OC" ]]; then
    echo "ERROR The oc command is not installed"
    exit 1
fi
if [[ -z "$JQ" ]]; then
    echo "ERROR The jq command is not installed"
    exit 1
fi

echo "INFO Getting list of all clusterpools in json format"
make clusterpool/list-clusterpools CLUSTERPOOL_LIST_ARGUMENTS=" -o json" > list.json
echo "INFO Saving clusterpool json file to artifact directory"
cp list.json "${ARTIFACT_DIR}/list.json"

echo "INFO Getting the names of all clusterpools"
jq -r '.items[].metadata.name' list.json > "${LIST_FILE}-all"
echo "INFO Getting the names of all clusterpools in a ready or standby state"
jq -r '.items[] | select(.status.standby + .status.ready > 0) | .metadata.name' list.json > "$LIST_FILE"
echo "INFO All clusterpools:"
cat "${LIST_FILE}-all"
echo "INFO All ready or standby clusterpools:"
cat "$LIST_FILE"
echo "     --- end ---"

cp "$LIST_FILE" "$MANAGED_LIST_FILE"
cp "${LIST_FILE}-all" "${MANAGED_LIST_FILE}-all"

echo "INFO Checking primary inclusion filter..."
if [[ -n "$CLUSTERPOOL_LIST_INCLUSION_FILTER" ]]; then
    echo "     CLUSTERPOOL_LIST_INCLUSION_FILTER: $CLUSTERPOOL_LIST_INCLUSION_FILTER"

    echo "INFO Applying primary inclusion filter"
    grep -e "$CLUSTERPOOL_LIST_INCLUSION_FILTER" "${LIST_FILE}" > "${LIST_FILE}.tmp" || true
    grep -e "$CLUSTERPOOL_LIST_INCLUSION_FILTER" "${LIST_FILE}-all" > "${LIST_FILE}-all.tmp" || true

    echo "INFO Primary clusterpool list after filtering:"
    cat "${LIST_FILE}-all.tmp"
    echo "INFO Primary clusterpool list in ready or standby after filtering:"
    cat "${LIST_FILE}.tmp"
    echo "     --- end ---"

    echo "INFO Number of primary clusterpools after inclusion filter:"
    echo "     ---$(wc -l < "${LIST_FILE}-all.tmp")---"
    echo "INFO Number of primary clusterpools in ready or standby after inclusion filter:"
    echo "     ---$(wc -l < "$LIST_FILE.tmp")---"

    echo "INFO Checking if any primary clusterpools are left..."
    if [[ $(wc -l < "${LIST_FILE}.tmp") == 0 ]]; then
        echo "WARNING No ready or standby primary clusterpools left after applying inclusion filter."
    fi
    if [[ $(wc -l < "${LIST_FILE}-all.tmp") == 0 ]]; then
        echo "ERROR No primary clusterpools left after applying inclusion filter."
        exit 1
    fi

    echo "INFO Updating list of primary clusterpools"
    mv "${LIST_FILE}-all.tmp" "${LIST_FILE}-all"
    mv "${LIST_FILE}.tmp" "$LIST_FILE"
else
    echo "     primary inclusion filter not provided"
fi

echo "INFO Checking managed inclusion filter..."
if [[ -n "$CLUSTERPOOL_MANAGED_LIST_INCLUSION_FILTER" ]]; then
    echo "     CLUSTERPOOL_MANAGED_LIST_INCLUSION_FILTER: $CLUSTERPOOL_MANAGED_LIST_INCLUSION_FILTER"

    echo "INFO Applying managed inclusion filter"
    grep -e "$CLUSTERPOOL_MANAGED_LIST_INCLUSION_FILTER" "${MANAGED_LIST_FILE}" > "${MANAGED_LIST_FILE}.tmp" || true
    grep -e "$CLUSTERPOOL_MANAGED_LIST_INCLUSION_FILTER" "${MANAGED_LIST_FILE}-all" > "${MANAGED_LIST_FILE}-all.tmp" || true

    echo "INFO Managed clusterpool list after filtering:"
    cat "${MANAGED_LIST_FILE}-all.tmp"
    echo "INFO Managed clusterpool list in ready or standby after filtering:"
    cat "${MANAGED_LIST_FILE}.tmp"
    echo "     --- end ---"

    echo "INFO Number of managed clusterpools after inclusion filter:"
    echo "     ---$(wc -l < "${MANAGED_LIST_FILE}-all.tmp")---"
    echo "INFO Number of managed clusterpools in ready or standby after inclusion filter:"
    echo "     ---$(wc -l < "$MANAGED_LIST_FILE.tmp")---"

    echo "INFO Checking if any managed clusterpools are left..."
    if [[ $(wc -l < "${MANAGED_LIST_FILE}.tmp") == 0 ]]; then
        echo "WARNING No ready or standby clusterpools left after applying inclusion filter."
    fi
    if [[ $(wc -l < "${MANAGED_LIST_FILE}-all.tmp") == 0 ]]; then
        echo "ERROR No managed clusterpools left after applying inclusion filter."
        exit 1
    fi

    echo "INFO Updating list of managed clusterpools"
    mv "${MANAGED_LIST_FILE}-all.tmp" "${MANAGED_LIST_FILE}-all"
    mv "${MANAGED_LIST_FILE}.tmp" "$MANAGED_LIST_FILE"
else
    echo "     managed inclusion filter not provided"
fi

echo "INFO Checking primary exclusion filter"
if [[ -n "$CLUSTERPOOL_LIST_EXCLUSION_FILTER" ]]; then
    echo "     CLUSTERPOOL_LIST_EXCLUSION_FILTER: $CLUSTERPOOL_LIST_EXCLUSION_FILTER"

    echo "INFO Applying primary exclusion filter"
    grep -v -e "$CLUSTERPOOL_LIST_EXCLUSION_FILTER" "${LIST_FILE}" > "${LIST_FILE}.tmp" || true
    grep -v -e "$CLUSTERPOOL_LIST_EXCLUSION_FILTER" "${LIST_FILE}-all" > "${LIST_FILE}-all.tmp" || true

    echo "INFO Primary clusterpool list after filtering:"
    cat "${LIST_FILE}-all.tmp"
    echo "INFO Primary clusterpool list in ready or standby after filtering:"
    cat "${LIST_FILE}.tmp"
    echo "     --- end ---"

    echo "INFO Number of primary clusterpools after exclusion filter:"
    echo "     ---$(wc -l < "${LIST_FILE}-all.tmp")---"
    echo "INFO Number of primary clusterpools in ready or standby after exclusion filter:"
    echo "     ---$(wc -l < "$LIST_FILE.tmp")---"

    echo "INFO Checking if any primary clusterpools are left..."
    if [[ $(wc -l < "${LIST_FILE}.tmp") == 0 ]]; then
        echo "WARNING No ready or standby primary clusterpools left after applying exclusion filter."
    fi
    if [[ $(wc -l < "${LIST_FILE}-all.tmp") == 0 ]]; then
        echo "ERROR No primary clusterpools left after applying exclusion filter."
        exit 1
    fi

    echo "INFO Updating list of primary clusterpools"
    mv "${LIST_FILE}-all.tmp" "${LIST_FILE}-all"
    mv "${LIST_FILE}.tmp" "$LIST_FILE"
else
    echo "     primaryexclusion filter not provided"
fi

echo "INFO Checking managed cluster exclusion filter"
if [[ -n "$CLUSTERPOOL_MANAGED_LIST_EXCLUSION_FILTER" ]]; then
    echo "     CLUSTERPOOL_MANAGED_LIST_EXCLUSION_FILTER: $CLUSTERPOOL_MANAGED_LIST_EXCLUSION_FILTER"

    echo "INFO Applying managed cluster exclusion filter"
    grep -v -e "$CLUSTERPOOL_MANAGED_LIST_EXCLUSION_FILTER" "${MANAGED_LIST_FILE}" > "${MANAGED_LIST_FILE}.tmp" || true
    grep -v -e "$CLUSTERPOOL_MANAGED_LIST_EXCLUSION_FILTER" "${MANAGED_LIST_FILE}-all" > "${MANAGED_LIST_FILE}-all.tmp" || true

    echo "INFO Managed clusterpool list after filtering:"
    cat "${MANAGED_LIST_FILE}-all.tmp"
    echo "INFO Managed clusterpool list in ready or standby after filtering:"
    cat "${MANAGED_LIST_FILE}.tmp"
    echo "     --- end ---"

    echo "INFO Number of managed clusterpools after exclusion filter:"
    echo "     ---$(wc -l < "${MANAGED_LIST_FILE}-all.tmp")---"
    echo "INFO Number of managed clusterpools in ready or standby after exclusion filter:"
    echo "     ---$(wc -l < "${MANAGED_LIST_FILE}.tmp")---"

    echo "INFO Checking if any managed clusterpools are left..."
    if [[ $(wc -l < "${MANAGED_LIST_FILE}.tmp") == 0 ]]; then
        echo "WARNING No ready or standby managed clusterpools left after applying exclusion filter."
    fi
    if [[ $(wc -l < "${MANAGED_LIST_FILE}-all.tmp") == 0 ]]; then
        echo "ERROR No managed clusterpools left after applying exclusion filter."
        exit 1
    fi

    echo "INFO Updating list of managed clusterpools"
    mv "${MANAGED_LIST_FILE}-all.tmp" "${MANAGED_LIST_FILE}-all"
    mv "${MANAGED_LIST_FILE}.tmp" "${MANAGED_LIST_FILE}"
else
    echo "     managed exclusion filter not provided"
fi

echo "INFO All primary clusterpool list:"
cat "${LIST_FILE}-all"
echo "INFO Ready or standby primary clusterpool list:"
cat "$LIST_FILE"
echo "     --- end ---"

echo "INFO Verifying primary ready or standby clusterpool list..."
if [[ $(wc -l < "${LIST_FILE}") == 0 ]]; then
    echo "WARNING No ready or standby primary clusterpools left. Replacing the list with the list of all clusterpools."
    mv "${LIST_FILE}-all" "${LIST_FILE}"
else
    rm "${LIST_FILE}-all"
fi

echo "INFO All managed clusterpool list:"
cat "${MANAGED_LIST_FILE}-all"
echo "INFO Ready or standby managed clusterpool list:"
cat "$MANAGED_LIST_FILE"
echo "     --- end ---"

echo "INFO Verifying managed ready or standby clusterpool list..."
if [[ $(wc -l < "${MANAGED_LIST_FILE}") == 0 ]]; then
    echo "WARNING No ready or standby managed clusterpools left. Replacing the list with the list of all clusterpools."
    mv "${MANAGED_LIST_FILE}-all" "${MANAGED_LIST_FILE}"
else
    rm "${MANAGED_LIST_FILE}-all"
fi

echo "INFO Checking if primary list needs to be reordered"
echo "     CLUSTERPOOL_LIST_ORDER: $CLUSTERPOOL_LIST_ORDER"
case "$CLUSTERPOOL_LIST_ORDER" in
    "")
        echo "     CLUSTERPOOL_LIST_ORDER is empty"
        echo "     Will not change list order"
        ;;
    sort)
        echo "INFO Sorting primary clusterpool list"
        sort "$LIST_FILE" > "$LIST_FILE.tmp"

        echo "INFO Sorted primary clusterpool list:"
        cat "$LIST_FILE.tmp"
        echo "     --- end ---"

        echo "INFO Updating list of available primary clusterpools"
        mv "$LIST_FILE.tmp" "$LIST_FILE"
        ;;
    shuffle)
        echo "INFO Shuffling primary clusterpool list"
        shuf "$LIST_FILE" > "$LIST_FILE.tmp"

        echo "INFO Shuffled primary clusterpool list:"
        cat "$LIST_FILE.tmp"
        echo "     --- end ---"

        echo "INFO Updating list of available primary clusterpools"
        mv "$LIST_FILE.tmp" "$LIST_FILE"
        ;;
    *)
        echo "     Invalid CLUSTERPOOL_LIST_ORDER"
        echo "     Ignoring"
        ;;
esac

echo "INFO Checking if managed list needs to be reordered"
echo "     MANAGED_CLUSTERPOOL_LIST_ORDER: $MANAGED_CLUSTERPOOL_LIST_ORDER"
case "$MANAGED_CLUSTERPOOL_LIST_ORDER" in
    "")
        echo "     CLUSTERPOOL_LIST_ORDER is empty"
        echo "     Will not change list order"
        ;;
    sort)
        echo "INFO Sorting managed clusterpool list"
        sort "$MANAGED_LIST_FILE" > "$MANAGED_LIST_FILE.tmp"

        echo "INFO Sorted managed clusterpool list:"
        cat "$MANAGED_LIST_FILE.tmp"
        echo "     --- end ---"

        echo "INFO Updating list of available managed clusterpools"
        mv "$MANAGED_LIST_FILE.tmp" "$MANAGED_LIST_FILE"
        ;;
    shuffle)
        echo "INFO Shuffling managed clusterpool list"
        shuf "$MANAGED_LIST_FILE" > "$MANAGED_LIST_FILE.tmp"

        echo "INFO Shuffled managed clusterpool list:"
        cat "$MANAGED_LIST_FILE.tmp"
        echo "     --- end ---"

        echo "INFO Updating list of available managed clusterpools"
        mv "$MANAGED_LIST_FILE.tmp" "$MANAGED_LIST_FILE"
        ;;
    *)
        echo "     Invalid CLUSTERPOOL_MANAGED_LIST_ORDER"
        echo "     Ignoring"
        ;;
esac

echo "INFO Final primary clusterpool list:"
cat "$LIST_FILE"
echo "     --- end ---"

echo "INFO Final managed clusterpool list:"
cat "$MANAGED_LIST_FILE"
echo "     --- end ---"
