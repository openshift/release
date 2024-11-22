#!/bin/bash

[ $(oc -n ci get pj -o yaml | yq ".items[].status.state" | grep -c "triggered") -lt 200 ] && return 0 || return 1