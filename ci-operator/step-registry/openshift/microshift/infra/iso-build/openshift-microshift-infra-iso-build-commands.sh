#!/bin/bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  User ${HOST_USER}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

cat <<EOF > /tmp/iso.sh
#!/bin/bash
set -xeuo pipefail

chmod 0755 ~
mkdir ~/rpms
tar -xf /tmp/rpms.tar -C ~/rpms
tar -xf /tmp/microshift.tgz -C ~

cp /tmp/ssh-publickey ~/.ssh/id_rsa.pub
cp /tmp/ssh-privatekey ~/.ssh/id_rsa
chmod 0400 ~/.ssh/id_rsa*

sudo subscription-manager register \
  --org="$(cat /var/run/rhsm/subscription-manager-org)" \
  --activationkey="$(cat /var/run/rhsm/subscription-manager-act-key)"

cd ~/microshift

# Force using the new branch
sudo dnf install -y git
sudo chown -R ${HOST_USER} .
git remote add dhellmann https://github.com/dhellmann/microshift.git
git fetch dhellmann
git switch -c build-multiple-images-for-ci dhellmann/build-multiple-images-for-ci
git show
# Add my ssh key
mkdir -p ~/.ssh/
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCeOj7GqCWvoeCE4e3CC1Sc2oonw07aoOYoaXLlz9iyI99gC0OT3kqTEY8SYXO+IS8n3CudrswP6ueK0jpdMgihWXJhwni08m7+ZNEBb/4FltznSNUK2bQ0Rj9qGzUkYD3/PhP04bVODEGRRnAGo5MBrj//B5GoEYs5zUDi3E4S3S/J3A9wFGyIDKsKR4yHSDTlpynjoDbtgfJpyDOyw9gYlXGZlLQclRCgPeN74P5UV7UoK1aiE/v66N9kBn3FIUKerqY605R/RUrFxQ4jiF+TKGJrnmBlebhOnME89HAvRxobdJ6jIMy+LE0uR0AhHQF8wCtftz/pQoGAa54qxocQHO4N1MTrZLnuFXyhTOxS+4NEOSzsJ9eP/Ut7MqaYnXyRgBeDamVm2li1GmXAbmR0a8O/GukKtXHOV06haQPtoGWZp44/c6DX6LeTLWTi2bqbAI4vhQRwYAa0+opcAX944jF2E5GBDwhOUH6jZtNebHP1SDBgGviPeoBA+AmAZ6c= dhellmann@redhat.com" >> ~/.ssh/authorized_keys
chmod 444 ~/.ssh/authorized_keys

# Get firewalld and repos in place. Use scripts to get the right repos
# for each branch.
./scripts/devenv-builder/configure-vm.sh --no-build --force-firewall /tmp/pull-secret
./scripts/image-builder/configure.sh
./scripts/image-builder/build.sh -pull_secret_file /tmp/pull-secret -microshift_rpms ~/rpms -authorized_keys_file /tmp/ssh-publickey -open_firewall_ports 6443:tcp
EOF
chmod +x /tmp/iso.sh

tar czf /tmp/microshift.tgz /microshift

scp \
  /rpms.tar \
  /tmp/iso.sh \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  ${CLUSTER_PROFILE_DIR}/ssh-privatekey \
  ${CLUSTER_PROFILE_DIR}/ssh-publickey \
  /tmp/microshift.tgz \
  "${INSTANCE_PREFIX}:/tmp"

ssh "${INSTANCE_PREFIX}" "/tmp/iso.sh"
