#!/bin/bash

set -x

for x in $(seq 200) ; do
    for name in api.equinix.com google.com ; do
        nslookup $name || true
        sleep .1
    done
done

for x in $(seq 200) ; do
    for name in api.equinix.com google.com ; do
        ping -c 1 $name || true
        sleep .1
    done
done

exit 1
