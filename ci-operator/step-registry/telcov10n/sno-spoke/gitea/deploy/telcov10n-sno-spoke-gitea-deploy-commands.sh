#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n Fix user IDs in a container ************"
[ -e "${HOME}/fix_uid.sh" ] && "${HOME}/fix_uid.sh" || echo "${HOME}/fix_uid.sh was not found" >&2

function set_hub_cluster_kubeconfig {
  echo "************ telcov10n Set Hub kubeconfig from \${SHARED_DIR}/hub-kubeconfig location ************"
  oc_hub="oc --kubeconfig ${SHARED_DIR}/hub-kubeconfig"
  helm_hub="helm --kubeconfig ${SHARED_DIR}/hub-kubeconfig"
}

function create_gitea_deployment {

  echo "************ telcov10n Deploy Gitea as a service into the Hub cluster ************"

  gitea_project="ztp-gitea"

  cat <<EOF | $oc_hub apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${gitea_project}
  annotations:
  labels:
    kubernetes.io/metadata.name: ${gitea_project}
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/warn: privileged
EOF

helm_gitea_values=$(mktemp --dry-run)
gitea_admin_pass="$(cat /var/run/telcov10n/ztp-left-shifting/gitea-admin-pass)"

cat <<EOF > ${helm_gitea_values}
image:
  registry: "quay.io"
  repository: ccardenosa/gitea

serviceAccount:
  name: gitea

redis-cluster:
  enabled: false
redis:
  enabled: false
postgresql:
  enabled: false
postgresql-ha:
  enabled: false

persistence:
  enabled: false

gitea:
  admin:
    username: "${GITEA_ADMIN_USERNAME}"
    password: "${gitea_admin_pass}"
  config:
    database:
      DB_TYPE: sqlite3
    session:
      PROVIDER: memory
    cache:
      ADAPTER: memory
    queue:
      TYPE: level

service:
  ssh:
    type: NodePort
    nodePort: 30022
EOF

  # cat ${helm_gitea_values}
  $oc_hub adm policy add-scc-to-user anyuid system:serviceaccount:${gitea_project}:gitea
  $oc_hub -n ${gitea_project} create serviceaccount gitea || echo
  helm repo add gitea-charts https://dl.gitea.com/charts/ || echo

  set -x
  $helm_hub status gitea -n ${gitea_project} 2> /dev/null || \
  $helm_hub install gitea gitea-charts/gitea --values ${helm_gitea_values} -n ${gitea_project} --wait
  set +x

  setup_openshift_route

}

function setup_openshift_route {

  echo "************ telcov10n Setup route to Gitea repo ************"

  cat << EOF | $oc_hub apply -f -
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: gitea
  namespace: ${gitea_project}
spec:
  to:
    kind: Service
    name: gitea-http
  port:
    targetPort: 3000
  tls:
    termination: edge
  wildcardPolicy: None
EOF

  hub_cluster_base_domain=$(oc whoami --show-console|awk -F'apps.' '{print $2}')
  echo -n "https://gitea-${gitea_project}.apps.${hub_cluster_base_domain}" > ${SHARED_DIR}/gitea-url.txt

}

function generate_gitea_ssh_keys {

  echo "************ telcov10n Generate SSH keys for Gitea repo ************"

  ssh_pri_key_file=${SHARED_DIR}/ssh-key-ztp-gitea
  ssh_pub_key_file="${ssh_pri_key_file}.pub"
  ssh-keygen -N '' -f ${ssh_pri_key_file} -C 'ztp-gitea-SSH-Public-Key'
  chmod 0600 ${ssh_pri_key_file}*
}

function upload_gitea_ssh_keys {

  echo "************ telcov10n Upload SSH Public key for Gitea repo ************"

  ssh_key_json=$(mktemp --dry-run)
  echo '{"title":"Gitea ZTP SSH Pub key", "key":"'"$(cat ${ssh_pub_key_file})"'"}' > ${ssh_key_json}
  set -x
  curl -vLk -X POST \
    -u ${GITEA_ADMIN_USERNAME}:${gitea_admin_pass} \
    -H "Content-Type: application/json" \
    -d @${ssh_key_json} \
    "$(cat ${SHARED_DIR}/gitea-url.txt)/api/v1/admin/users/${GITEA_ADMIN_USERNAME}/keys"
  set +x
}

function create_ztp_gitea_repo {

  echo "************ telcov10n Create ZTP Gitea repo ************"

  repo_name="telcov10n"
  set -x
  curl -vLk -X POST \
    -u ${GITEA_ADMIN_USERNAME}:${gitea_admin_pass} \
    -H "Content-Type: application/json" \
    -d '{"name":"'${repo_name}'"}' \
    "$(cat ${SHARED_DIR}/gitea-url.txt)/api/v1/user/repos"
  set +x
}

function generate_gitea_ssh_uri {

  echo "************ telcov10n Generate ZTP Git SSH uri ************"

  gitea_ssh_host=$(oc get node openshift-master-0.lab.eng.rdu2.redhat.com -ojsonpath='{.status.addresses[?(.type=="InternalIP")].address}')
  gitea_ssh_nodeport=$(oc -n ${gitea_project} get service gitea-ssh -ojsonpath='{.spec.ports[?(.name=="ssh")].nodePort}')

  gitea_ssh_uri="ssh://git@${gitea_ssh_host}:${gitea_ssh_nodeport}/${GITEA_ADMIN_USERNAME}/${repo_name}.git"
  echo -n "${gitea_ssh_uri}" > ${SHARED_DIR}/gitea_ssh_uri.txt
}

function create_ztp_branch {

  echo "************ telcov10n Create ZTP Git branch ************"

  ztp_repo_dir=$(mktemp -d)
  pushd .
  cd ${ztp_repo_dir}
  echo "# Telco Verification" > README.md
  echo "$(cat ${ssh_pri_key_file}.pub)" >> README.md
  git config --global user.email "ztp-gitea@telcov10n.com"
  git config --global user.name "ZTP Gitea Telco Verification"
  git config --global init.defaultBranch main
  git init
  git checkout -b main
  git add README.md
  git commit -m "First commit"
  #ssh://git@gitlab.consulting.redhat.com:2222/
  set -x
  git remote add origin ${gitea_ssh_uri}
  GIT_SSH_COMMAND="ssh -v -o StrictHostKeyChecking=no -i ${ssh_pri_key_file}" git push -u origin main
  set +x
  popd
}

function main {
  set_hub_cluster_kubeconfig
  create_gitea_deployment
  generate_gitea_ssh_keys
  upload_gitea_ssh_keys
  create_ztp_gitea_repo
  generate_gitea_ssh_uri
  create_ztp_branch
}

main
