#!/usr/bin/env bash

set -o pipefail

set +o nounset
set -x

function test(){
        ls -lrt 
	cp /tmp/non-exist .
        comp_rc=$?
        echo "hi"
}

test

if [[ $comp_rc -gt 0 ]]; then
	echo "failed, $comp_rc !!!"
	
fi
