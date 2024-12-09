#!/bin/bash
set -o nounset
set -o pipefail
set -x

#bastion=$(cat "/secret/address")

#ping -c 5 $bastion

dig +short api.vlan101.rdu3.labs.perfscale.redhat.com  || echo "Fail" 
curl -v https://api.vlan101.rdu3.labs.perfscale.redhat.com:6443/healthz -k
