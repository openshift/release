#!/bin/bash -xeu

env | sort

if [ ! -e "${DOCKER_SOCKET}" ]; then
  echo "Docker socket missing at ${DOCKER_SOCKET}"
  exit 1
fi

arch=${ARCH:-x86_64}
namespace=$(echo "${BUILD}" | jq --raw-output '.metadata.namespace')
base_image="docker-registry.default.svc:5000/${namespace}/${BASE_IMAGE_STREAM_TAG}"
tag=$(echo "${BUILD}" | jq --raw-output '.status.outputDockerImageReference')
host_arch=$(arch)
build_dir=$(mktemp --directory)

git clone --recursive "${SOURCE_REPOSITORY}" "${build_dir}"
if [ $? != 0 ]; then
  echo "Error trying to fetch git source: ${SOURCE_REPOSITORY}"
  exit 1
fi

pushd "${build_dir}"

if [ -n "${SOURCE_REF}" ]; then
  git checkout "${SOURCE_REF}"
  if [ $? != 0 ]; then
    echo "Error trying to checkout branch: ${SOURCE_REF}"
    exit 1
  fi
fi

if [[ -n "${SOURCE_CONTEXT_DIR}" ]]; then
  pushd "${SOURCE_CONTEXT_DIR}"
fi

if [[ -n "${PULL_DOCKERCFG_PATH}" ]]; then
  cp "${PULL_DOCKERCFG_PATH}/.dockercfg" "${HOME}/.dockercfg"
fi

docker pull "${base_image}"

if [[ "${host_arch}" != "${arch}" ]]; then
  imagebuilder --mount /usr/bin/qemu-${arch}-static:/usr/bin/qemu-${arch}-static --from "${base_image}" -t "${tag}" .
else
  imagebuilder --from "${base_image}" -t "${tag}" .
fi

if [[ -n "${PUSH_DOCKERCFG_PATH}" ]]; then
  cp "${PUSH_DOCKERCFG_PATH}/.dockercfg" "${HOME}/.dockercfg"
fi

if [[ "${OUTPUT_REGISTRY}" == 'docker-registry.default.svc:5000' ]]; then
  docker push ${tag}
else
  skopeo copy docker-daemon:${tag} docker://${tag}
fi
