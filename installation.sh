#!/bin/bash
#
# exit immediately when a command fails
set -e
# only exit with zero if all commands of the pipeline exit successfully
set -o pipefail
# error on unset variables
set -u

command -v kubectl >/dev/null 2>&1 || { echo "kubectl is not installed. Aborting."; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "oc cli is not installed. Aborting."; exit 1; }

# tr is not working by default in MacOs. Exporting LC_CTYPE=C seems like solve the problem
case "$(uname -s)" in
    Darwin*)    export LC_CTYPE=C;;
    Linux*)     echo -e "Running on Linux system";;
    *)          echo -e "UNKNOWN System."
esac

export ROOT_E2E="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"/..
export WORKSPACE=${WORKSPACE:-${ROOT_E2E}}
export MY_GIT_FORK_REMOTE="qe"
export MY_GITHUB_ORG="redhat-appstudio-qe"
export MY_GITHUB_TOKEN="$GITHUB_TOKEN"
export WORKSPACE_ID=$(tr -dc a-z0-9 </dev/urandom | head -c 5 ; echo '')
export TEST_BRANCH_ID="$(date +%s)"
export JOB_TYPE=${JOB_TYPE:-"presubmit"}
export REPO_NAME=${REPO_NAME:-"e2e-tests"}
export RUN_E2E="false"

# KCP related environments
export KCP_CONTEXT=
export KCP_KUBECONFIG=
export CLUSTER_KUBECONFIG=
export ROOT_WORKSPACE=
export IS_STABLE="false"
export APPSTUDIO_WORKSPACE="redhat-appstudio-${WORKSPACE_ID}"
export HACBS_WORKSPACE="redhat-hacbs-${WORKSPACE_ID}"
export USER_APPSTUDIO_WORKSPACE="appstudio-${WORKSPACE_ID}"
export PIPELINE_SERVICE_SP_WORKSPACE="root:redhat-pipeline-service-compute"
export PIPELINE_SERVICE_IDENTITY_HASH="72b2990e51b1931e9fee86e67091b721a8c32f407d762fc847d9d2316a988b52"
export CI=${CI:-"false"}

# Display help information about this script bash
function helpUsage() {
    echo -e "Deploy Red Hat App Studio in preview mode for testing purposes\n"
    echo -e "Options:"
    echo -e "   -h,  --help                   Get more information about available flags to install Red Hat App Studio in preview mode."
    echo -e "   -kc, --kcp-context            The name of the kubeconfig context to use."
    echo -e "   -kk, --kcp-kubeconfig         A valid kcp kubeconfig path."
    echo -e "   -ck, --cluster-kubeconfig     A valid kubeconfig pointing to a physical openshift cluster."
    echo -e "   -s, --stable                  Flag to determinate if the kcp cluster is stable or not. In case if this flag is missing by default will install Red Hat App Studio in unstable kcp version."
    echo -e "   --e2e                         If this is used then will start to run the e2e tests.\n"
    echo -e "Examples:\n"
    echo -e "   # Deploy Red Hat App Studio in kcp stable version"
    echo -e "   /bin/bash <E2E_DIR>/scripts/install-appstudio-kcp.sh -kc kcp-stable-root -kk <path-to-kcp-kubeconfig> -ck <path-to-openshift-cluster-kubeconfig> -s\n"
    echo -e "   # Deploy Red Hat App Studio in kcp unstable version"
    echo -e "   /bin/bash <E2E_DIR>/scripts/install-appstudio-kcp.sh -kc kcp-unstable-root -kk <path-to-kcp-kubeconfig> -ck <path-to-openshift-cluster-kubeconfig>\n"
    echo -e "To authenticate against a KCP instance using Red Hat SSO before starting you need to get an offline token from https://console.redhat.com/openshift/token\n"
    echo -e "   export OFFLINE_TOKEN=<token_goes_here>"
}

while [[ $# -gt 0 ]]
do
    case "$1" in
        -h|--help)
            helpUsage
            exit 0
            ;;
        -kc|--kcp-context)
            export KCP_CONTEXT=$2
            ;;
        -kk|--kcp-kubeconfig)
            export KCP_KUBECONFIG=$2
            echo $2
            
            ;;
        -ck|--cluster-kubeconfig)
            export CLUSTER_KUBECONFIG=$2
            ;;
        -s|--stable)
            export IS_STABLE="true"
            ;;
        --e2e)
            export RUN_E2E="true"
            ;;
        *)
            ;;
    esac
    shift
done

if [[ -z "$KCP_CONTEXT" ]]; then
    echo "[ERROR] Not KCP context defined in the script. Please use flag '-kc' or '--kcp-context' to define the kcp context." 
    helpUsage & exit 1
fi

if [[ -z "$KCP_KUBECONFIG" ]]; then
    echo "[ERROR] KCP kubeconfig not defined. Please use flag '-kk' or '--kcp-kubeconfig' to define the kcp kubeconfig." 
    helpUsage & exit 1
fi

if [[ -z "$CLUSTER_KUBECONFIG" ]]; then
    echo "[ERROR] Not cluster kubeconfig defined. Please use flag '-ck' or '--cluster-kubeconfig' to define the kcp physical cluster target kubeconfig." 
    helpUsage & exit 1
fi

if [[ -z "$OFFLINE_TOKEN" ]]; then
    echo "[ERROR] OFFLINE_TOKEN environment is not set. You can obtain one from cloud.redhat.com." 
    helpUsage & exit 1
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
    echo "[ERROR] GITHUB_TOKEN environment is not set." 
    helpUsage & exit 1
fi

# Export kcp kubeconfig to start working against KCP
export KUBECONFIG="$KCP_KUBECONFIG"
kubectl config use-context "$KCP_CONTEXT"

# Installing oidc-login plugin for kubectl. More information about oidc-login plugin can be found here: https://github.com/int128/kubelogin.
# oidc-login will be used to authenticate using SSO against KCP
function installKubectlOIDCLoginPlugin() {
    echo -e "[INFO] Installing krew for oidc-login plugin installation."
    (
        set -x; cd "$(mktemp -d)" &&
        OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
        ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
        KREW="krew-${OS}_${ARCH}" &&
        curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
        tar zxvf "${KREW}.tar.gz" &&
        ./"${KREW}" install krew
    )
    export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
    kubectl krew install oidc-login
}

# Will install all kcp plugins used by Red Hat App Studio installation script
function installKubectlKcpPlugins() {
    local kcp_clone_branch="main"

    if [[ "$IS_STABLE" == "true" ]]; then
        kcp_clone_branch=$(kubectl version -o yaml --kubeconfig ${KCP_KUBECONFIG} 2>/dev/null | yq '.serverVersion.gitVersion' | sed 's/.*kcp-\(v[[:digit:]]*\.[[:digit:]]*\.[[:digit:]]*\).*/\1/')
        echo -e "[INFO] Cloning kcp-dev/kcp repo from '$kcp_clone_branch' branch to install kubectl kcp plugins."
    else
        echo -e "[INFO] Cloning kcp-dev/kcp repo from '$kcp_clone_branch' branch to install kubectl kcp plugins."
    fi

    if [ -d "$WORKSPACE"/tmp/kcp ] 
    then
        echo -e "[WARN] tmp/kcp already exists. Deleting..." 
        rm -rf "$WORKSPACE""/tmp/kcp"
    fi

    git clone https://github.com/kcp-dev/kcp -b "$kcp_clone_branch" "$WORKSPACE"/tmp/kcp
    cd "$WORKSPACE"/tmp/kcp

    go mod vendor
    make install

    if ! kubectl kcp --version; then
        echo "[ERROR] kubectl kcp plugins not installed successfully. Make sure that HOME/go/bin is in your PATH"
    fi

    cd $WORKSPACE
}

# Will obtain from an offline token the access_token and the refresh_token. Will be used to authenticate against Red Hat SSO
function redHatSSOAuthentication() {
    local sso_token_request=$(
        curl \
        --silent \
        --header "Accept: application/json" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=refresh_token" \
        --data-urlencode "client_id=cloud-services" \
        --data-urlencode "refresh_token=${OFFLINE_TOKEN}" \
        "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" \
        | \
        jq --raw-output "."
    )

    local access_token=$(echo $sso_token_request | jq .access_token)
    local refresh_token=$(echo $sso_token_request | jq .refresh_token)

    cat <<EOF > de0b44c30948a686e739661da92d5a6bf9c6b1fb85ce4c37589e089ba03d0ec6
    {"id_token":${access_token},"refresh_token":${refresh_token}}
EOF
    mkdir -p ~/.kube/cache/oidc-login/ && cp -f de0b44c30948a686e739661da92d5a6bf9c6b1fb85ce4c37589e089ba03d0ec6 ~/.kube/cache/oidc-login/
    rm -rf de0b44c30948a686e739661da92d5a6bf9c6b1fb85ce4c37589e089ba03d0ec6
    echo "[INFO] Success to update cache for kubectl oidc-login"

}

# Create the Red Hat App Studio Root Workspace
function createAppStudioRootWorkspace() {
    kubectl kcp workspace use '~'
    export APPSTUDIO_ROOT="$(kubectl ws . --short)"
}

# Download gitops repository to install AppStudio in e2e mode.
function cloneInfraDeployments() {
    if [ -d "$WORKSPACE""/tmp/infra-deployments" ] 
    then
        echo -e "[INFO] tmp/infra-deployments already exists. Deleting..." 
        rm -rf "$WORKSPACE""/tmp/infra-deployments"
    fi

    # If we are in infra-deployments jobs we don't need to clone infra-deployments. Openshift CI clones automatically
    if [[ "$JOB_TYPE" != "periodic" ]] || [[ "$REPO_NAME" != "infra-deployments" ]]
    then
        echo -e "[INFO] Cloning https://github.com/redhat-appstudio/infra-deployments from main branch"
        git clone https://github.com/redhat-appstudio/infra-deployments "$WORKSPACE"/tmp/infra-deployments
    fi
}

# Create preview.env file for App Studio installation. More info about this can be found in the redhat-appstudio/infra-deployments repo
function createPreviewEnvFile() {
    cat > "$WORKSPACE"/tmp/infra-deployments/hack/preview.env << EOF
export CLUSTER_KUBECONFIG="$CLUSTER_KUBECONFIG"
export KCP_KUBECONFIG="$KCP_KUBECONFIG"
export ROOT_WORKSPACE="$APPSTUDIO_ROOT"
export APPSTUDIO_WORKSPACE="redhat-appstudio-${WORKSPACE_ID}"
export HACBS_WORKSPACE="redhat-hacbs-${WORKSPACE_ID}"
export USER_APPSTUDIO_WORKSPACE="appstudio-${WORKSPACE_ID}"
export COMPUTE_WORKSPACE="compute-${WORKSPACE_ID}"
export USER_HACBS_WORKSPACE="appstudio-${WORKSPACE_ID}"
EOF
}

# Add a custom remote for infra-deployments repo and start the installation
function startRedHatAppStudioInstallation() {
    # If we are in infra-deployments jobs we don't need to clone infra-deployments. Openshift CI clones automatically
    if [[ "$JOB_TYPE" == "periodic" ]] || [[ "$REPO_NAME" == "infra-deployments" ]]
    then
        git remote add "${MY_GIT_FORK_REMOTE}" https://github.com/"${MY_GITHUB_ORG}"/infra-deployments.git
        "$WORKSPACE"/hack/bootstrap.sh -m preview
    else
        cd "$WORKSPACE"/tmp/infra-deployments
        git remote add "${MY_GIT_FORK_REMOTE}" https://github.com/"${MY_GITHUB_ORG}"/infra-deployments.git
        "$WORKSPACE"/tmp/infra-deployments/hack/bootstrap.sh -m preview
    fi
}

# Start to run the tests
function runE2Etests() {
    # If we are in infra-deployments jobs we don't need to clone infra-deployments. Openshift CI clones automatically
    if [[ "$REPO_NAME" == "e2e-tests" ]]
    then
        make local/cluster/prepare
        make local/test/e2e
    else
        if [ -d "$WORKSPACE"/tmp/e2e-tests ] 
        then
            echo -e "[WARN] tmp/e2e-tests already exists. Deleting..." 
            rm -rf "$WORKSPACE""tmp/e2e-tests"
        fi
        git clone -b kcp_scr https://github.com/flacatus/e2e-tests.git "$WORKSPACE""tmp/e2e-tests"
        cd "$WORKSPACE""tmp/e2e-tests"

        make local/cluster/prepare
        make local/test/e2e
        cd "$WORKSPACE"
    fi
}

function runAuthenticationInBackground() {
    export -f redHatSSOAuthentication
    timeout --kill-after=110m --foreground 100m bash -c -- 'while [ true ]; do redHatSSOAuthentication; sleep 60s; done'
}

# Run the authentication SSO only if we are in Openshift CI.
if [[ $CI == "true" ]]
then
    runAuthenticationInBackground &
fi

installKubectlOIDCLoginPlugin
installKubectlKcpPlugins
cloneInfraDeployments
createAppStudioRootWorkspace
createPreviewEnvFile
startRedHatAppStudioInstallation

# Switch to user workspace
kubectl ws "${USER_APPSTUDIO_WORKSPACE}"

if [[ $RUN_E2E == "true" ]]
    runE2Etests
then
fi
