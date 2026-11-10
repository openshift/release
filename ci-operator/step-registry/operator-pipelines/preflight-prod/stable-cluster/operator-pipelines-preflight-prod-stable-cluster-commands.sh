#!/usr/bin/env bash

export KUBECONFIG

echo "Checking cluster stability"

echo "Waiting for the cluster to remain stable for 2 minutes (timeout: 10 minutes)"

oc adm wait-for-stable-cluster --minimum-stable-period 2m --timeout 10m
oc_exit_code=$?

echo "Cluster stability check completed with exit code: ${oc_exit_code}"
exit "${oc_exit_code}"
