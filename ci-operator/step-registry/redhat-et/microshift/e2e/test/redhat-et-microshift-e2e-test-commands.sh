#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GOOGLE_COMPUTE_REGION="${LEASED_RESOURCE}"
GOOGLE_COMPUTE_ZONE="$(< ${SHARED_DIR}/openshift_gcp_compute_zone)"
if [[ -z "${GOOGLE_COMPUTE_ZONE}" ]]; then
  echo "Expected \${SHARED_DIR}/openshift_gcp_compute_zone to contain the GCP zone"
  exit 1
fi

mkdir -p "${HOME}"/.ssh

mock-nss.sh

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub
echo 'ServerAliveInterval 30' | tee -a "${HOME}"/.ssh/config
echo 'ServerAliveCountMax 1200' | tee -a "${HOME}"/.ssh/config
chmod 0600 "${HOME}"/.ssh/config

# Copy pull secret to user home
cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/pull-secret

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

# Setup Test Env
# TODO (copejon) hacky workaround to setup the env.  Once merged, drop the systemctl and rm commands and add
#   curl -sfL https://raw.githubusercontent.com/redhat-et/microshift/main/scripts/setup-env.sh | sh -
cat > "${HOME}"/microshift-service <<EOF
[Unit]
Description=Microshift
[Service]
WorkingDirectory=/usr/local/bin/
ExecStart=microshift run
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

cat > "${HOME}"/configure-e2e-host.sh <<'EOF'
#! /bin/bash
set -euxo pipefail

VERSION=$(curl -s https://api.github.com/repos/redhat-et/microshift/releases | grep tag_name | head -n 1 | cut -d '"' -f 4)

# Function to get Linux distribution
get_distro() {
    DISTRO=$(egrep '^(ID)=' /etc/os-release| sed 's/"//g' | cut -f2 -d"=")
    if [[ $DISTRO != @(rhel|fedora|centos) ]]
    then
      echo "This Linux distro is not supported by the install script"
      exit 1
    fi

}

# Function to get system architecture
get_arch() {
    ARCH=$(uname -m)
}

# If RHEL, use subscription-manager to register
register_subs() {
    set +e +o pipefail
    REPO="rhocp-4.7-for-rhel-8-x86_64-rpms"
    # Check subscription status and register if not
    STATUS=$(sudo subscription-manager status | awk '/Overall Status/ { print $3 }')
    if [[ $STATUS != "Current" ]]
    then
        sudo subscription-manager register --auto-attach < /dev/tty
        POOL=$(sudo subscription-manager list --available --matches '*OpenShift' | grep Pool | head -n1 | awk -F: '{print $2}' | tr -d ' ')
	sudo subscription-manager attach --pool $POOL
        sudo subscription-manager config --rhsm.manage_repos=1
    fi
    set -e -o pipefail
    # Check if already subscribed to the proper repository
    if ! sudo subscription-manager repos --list-enabled | grep -q ${REPO}
    then
        sudo subscription-manager repos --enable=${REPO}
    fi
}

# Apply SElinux policies
apply_selinux_policy() {
    # sudo semanage fcontext -a -t container_runtime_exec_t /usr/local/bin/microshift ||
    #   sudo semanage fcontext -m -t container_runtime_exec_t /usr/local/bin/microshift
    # sudo mkdir -p /var/lib/kubelet/
    # sudo chcon -R -t container_file_t /var/lib/kubelet/
    # sudo chcon -R system_u:object_r:bin_t:s0 /usr/local/bin/microshift
    sudo setenforce 0
    sudo sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
}
# Install dependencies
install_dependencies() {
    sudo dnf install -y \
    policycoreutils-python-utils \
    conntrack \
    firewalld 
}

# Establish Iptables rules
establish_firewall () {
sudo systemctl enable firewalld --now
sudo firewall-cmd --zone=public --permanent --add-port=6443/tcp
sudo firewall-cmd --zone=public --permanent --add-port=30000-32767/tcp
sudo firewall-cmd --zone=public --permanent --add-port=2379-2380/tcp
sudo firewall-cmd --zone=public --add-masquerade --permanent
sudo firewall-cmd --zone=public --add-port=10250/tcp --permanent
sudo firewall-cmd --zone=public --add-port=10251/tcp --permanent
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
sudo firewall-cmd --reload
}


# Install CRI-O depending on the distro
install_crio() {
    case $DISTRO in
      "fedora")
        sudo dnf module -y enable cri-o:1.20
        sudo dnf install -y cri-o cri-tools
      ;;
      "rhel")
        sudo dnf install cri-o cri-tools -y
      ;;
      "centos")
        CRIOVERSION=1.20
        OS=CentOS_8_Stream
        sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/devel:kubic:libcontainers:stable.repo
        sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable:cri-o:$CRIOVERSION.repo https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:$CRIOVERSION/$OS/devel:kubic:libcontainers:stable:cri-o:$CRIOVERSION.repo
        sudo dnf install -y cri-o cri-tools
      ;;
    esac
}


# CRI-O config to match Microshift networking values
crio_conf() {
    sudo sed -i 's/10.85.0.0\/16/10.42.0.0\/24/' /etc/cni/net.d/100-crio-bridge.conf
    sudo sed -i 's/0.3.1/0.4.0/' /etc/cni/net.d/100-crio-bridge.conf

     if [ "$DISTRO" == "rhel" ]; then
        sudo sed -i 's|/usr/libexec/crio/conmon|/usr/bin/conmon|' /etc/crio/crio.conf 
     fi
}

# Start CRI-O
verify_crio() {
    sudo systemctl enable crio
    sudo systemctl restart crio

}

# Download and install kubectl
get_kubectl() {
    curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo chmod +x ./kubectl
    sudo mv ./kubectl /usr/local/bin/kubectl

}

# Download and install microshift
get_microshift() {
    if [ $ARCH = "x86_64" ]; then
        curl -L https://github.com/redhat-et/microshift/releases/download/$VERSION/microshift-linux-amd64 -o microshift
        curl -L https://github.com/redhat-et/microshift/releases/download/$VERSION/release.sha256 -o release.sha256
    fi

    SHA=$(sha256sum microshift | awk '{print $1}')
    if [[ $SHA != $(cat release.sha256 | awk '{print $1}') ]]; then echo "SHA256 checksum failed" && exit 1; fi

    sudo chmod +x microshift
    sudo mv microshift /usr/local/bin/

    apply_selinux_policy

    sudo systemctl enable microshift.service --now

}

# Locate kubeadmin configuration to default kubeconfig location
prepare_kubeconfig() {
    mkdir -p $HOME/.kube
    if [ -f $HOME/.kube/config ]; then
        mv $HOME/.kube/config $HOME/.kube/config.orig
    fi
    sudo KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig:$HOME/.kube/config.orig  /usr/local/bin/kubectl config view --flatten > $HOME/.kube/config
}

# validation checks for deployment 
validation_check(){
    echo $HOSTNAME | grep -P '(?=^.{1,254}$)(^(?>(?!\d+\.)[a-zA-Z0-9_\-]{1,63}\.?)+(?:[a-zA-Z]{2,})$)' && echo "Correct"
    if [ $? != 0 ];
    then
        echo "The hostname $HOSTNAME is incompatible with this installation please update your hostname and try again. "
        echo "Example: 'sudo hostnamectl set-hostname $HOSTNAME.example.com'"
        exit 1
    else
        echo "$HOSTNAME is a valid machine name continuing installation"
    fi
}

# Script execution
get_distro
get_arch
if [ $DISTRO = "rhel" ]; then
    register_subs
fi
# let's see what happens if disable validation check
#validation_check
install_dependencies
establish_firewall
install_crio
crio_conf
verify_crio
get_kubectl
get_microshift

until sudo test -f /var/lib/microshift/resources/kubeadmin/kubeconfig
do
     sleep 2
done
prepare_kubeconfig

sudo systemctl disable --now microshift.service
sudo rm -rf /var/lib/microshift
sudo rm -f /usr/local/bin/microshift
EOF
chmod +x "${HOME}"/configure-e2e-host.sh

# smoke-tests script to scp to gcp instance
# TODO: edit this file to launch microshift and run tests
cat  > "${HOME}"/run-smoke-tests.sh << 'EOF'
#!/bin/bash
set -euxo pipefail

# Tests execution
echo ### Running microshift smoke-tests
echo ### Start /usr/bin/microshift run and run commands to perform smoke-tests

microshift version
microshift run
EOF
chmod +x "${HOME}"/run-smoke-tests.sh

set -x
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/microshift-service rhel8user@"${INSTANCE_PREFIX}":~/microshift-service

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo mv microshift-service /usr/lib/systemd/system/microshift.service'

# scp and install microshift binary and smoke-tests script
LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /bin/microshift rhel8user@"${INSTANCE_PREFIX}":~/microshift

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/configure-e2e-host.sh rhel8user@"${INSTANCE_PREFIX}":~/configure-e2e-host.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/run-smoke-tests.sh rhel8user@"${INSTANCE_PREFIX}":~/run-smoke-tests.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/pull-secret rhel8user@"${INSTANCE_PREFIX}":~/pull-secret

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command './configure-e2e-host.sh'

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command 'sudo mv microshift /usr/bin/microshift'

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  rhel8user@"${INSTANCE_PREFIX}" \
  --command './run-smoke-tests.sh'
