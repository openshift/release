#!/bin/bash -xeu

if [ ! -e "${DOCKER_SOCKET}" ]; then
  echo "Docker socket missing at ${DOCKER_SOCKET}"
  exit 1
fi

TAG="${OUTPUT_REGISTRY}/${OUTPUT_IMAGE}"

cat << EOF > manifest.yaml
image: ${TAG}
manifests:
EOF

for arch in ${ARCHES}; do
  goarch=
  case "${arch}" in
  x86_64)
    goarch=amd64
    ;;
  aarch64)
    goarch=arm64
    ;;
  *)
    goarch="${arch}"
    ;;
  esac

  cat << EOF >> manifest.yaml
  - image: "${OUTPUT_REGISTRY}/${OUTPUT_IMAGE%%:*}:${arch}-${OUTPUT_IMAGE##*:}"
    platform:
      architecture: "${goarch}"
      os: linux
EOF
done

set +x
username=$(jq --raw-output ".\"${OUTPUT_REGISTRY}\".username" "${PUSH_DOCKERCFG_PATH}/.dockercfg")
password=$(jq --raw-output ".\"${OUTPUT_REGISTRY}\".password" "${PUSH_DOCKERCFG_PATH}/.dockercfg")
manifest-tool --debug --username=${username} --password=${password} push from-spec manifest.yaml
