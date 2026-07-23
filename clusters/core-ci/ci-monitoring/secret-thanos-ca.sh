#!/bin/bash

# This script generates the CA's key and certificate that Thanos uses to authenticate clients.

ca_key="$(openssl genrsa -out - 4096)"
ca_crt="$(openssl req -x509 -new -nodes -key <(echo "$ca_key") -sha256 -days 3650 -subj "/CN=ci-monitoring-thanos-ca" -out -)"
oc --context=core-ci create secret generic thanos-ca \
  --from-file=ca.key=<(echo "$ca_key") --from-file=ca.crt=<(echo "$ca_crt")

