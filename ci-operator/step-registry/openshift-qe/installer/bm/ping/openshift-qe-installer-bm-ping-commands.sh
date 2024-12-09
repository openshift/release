#!/bin/bash
set -o nounset
set -o pipefail
set -x

#bastion=$(cat "/secret/address")

#ping -c 5 $bastion

echo "Pinging api.vlan101.rdu3.labs.perfscale.redhat.com"
dig +short api.vlan101.rdu3.labs.perfscale.redhat.com  || echo "Fail" 

echo "Pinging wiki.rdu3.labs.perfscale.redhat.com"
dig +short wiki.rdu3.labs.perfscale.redhat.com  || echo "Fail"

echo "Pinging kk.apps.vlan101.rdu3.labs.perfscale.redhat.com"
dig +short kk.apps.vlan101.rdu3.labs.perfscale.redhat.com  || echo "Fail"

echo "Pinging wiki.rdu2.scalelab.redhat.com"
dig +short wiki.rdu2.scalelab.redhat.com   || echo "Fail"

echo "Pinging api.vlan603.rdu2.scalelab.redhat.com"
dig +short api.vlan603.rdu2.scalelab.redhat.com   || echo "Fail"

echo "Pinging kk.apps.vlan603.rdu2.scalelab.redhat.com"
dig +short kk.apps.vlan603.rdu2.scalelab.redhat.com   || echo "Fail"
