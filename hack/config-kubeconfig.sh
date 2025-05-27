#!/bin/bash

if ! command -v ocp-sso-token &> /dev/null
then
    echo "The ocp-sso-token command was not found in your PATH. See https://gitlab.com/cki-project/ocp-sso-token/ for installation steps."
    exit 1
fi
echo "Make sure you have a valid kerberos ticket(check with klist), then run this script"

log_file=$(mktemp --dry-run --tmpdir=/tmp $(basename $0).$(date +%s).XXX)
declare -A CONFIGS=(
    # cluster id : identity provider ; namespace ; API url
    [app.ci]=' RedHat_Internal_SSO ; default ; https://api.ci.l2s4.p1.openshiftapps.com:6443'
    [build01]='RedHat_Internal_SSO ; default ; https://api.build01.ci.devcluster.openshift.com:6443'
    [build02]='RedHat_Internal_SSO ; default ; https://api.build02.gcp.ci.openshift.org:6443'
    [build05]='RedHat_Internal_SSO ; default ; https://api.build05.l9oh.p1.openshiftapps.com:6443'
    [build06]='RedHat_Internal_SSO ; default ; https://api.build06.ci.devcluster.openshift.com:6443'
    [build07]='RedHat_Internal_SSO ; default ; https://api.build07.ci.devcluster.openshift.com:6443'
    [build10]='RedHat_Internal_SSO ; default ; https://api.build10.ci.devcluster.openshift.com:6443'
    [build11]='RedHat_Internal_SSO ; default ; https://api.build11.ci.devcluster.openshift.com:6443'
    [vsphere02]='RedHat_Internal_SSO ; default ; https://api.build02.vmc.ci.openshift.org:6443'
    [hosted-mgmt]='RedHat_Internal_SSO ; default ; https://api.hosted-mgmt.ci.devcluster.openshift.com:6443'
)

function get_token() {
    cluster="$1"
    config="$2"
    clean_config="$(tr -d '[:space:]' <<< "$config")"
    IFS=';' read idp namespace api placeholder <<< "$clean_config"
    echo -n -e "Get token via idp:'$idp' for cluster:'$cluster'('$api')\t"
    ocp-sso-token "$api" --context "$cluster" --identity-providers "$idp" --namespace "$namespace" &>>"$log_file" && echo -e 'Done' || echo -e "Failed. Check log $log_file"
}

if [[ $# -eq 0 ]] ; then
    for config in "${!CONFIGS[@]}" ; do
        get_token "$config" "${CONFIGS[$config]}"
    done
else
    for cluster in $@ ; do
        case $cluster in
            app.ci|build01|build02|build05|build06|build07|build10|build11|vsphere02|hosted-mgmt)
                get_token "$cluster" "${CONFIGS[$cluster]}"
                ;;
            *)
                echo "Can not find CONFIGS for '$cluster'"
                ;;
        esac
    done
fi
