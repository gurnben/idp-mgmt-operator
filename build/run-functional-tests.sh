#!/bin/bash
###############################################################################
# Copyright (c) Red Hat, Inc.
# Copyright Red Hat
###############################################################################

set -e
# set -x

CURR_FOLDER_PATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
KIND_KUBECONFIG="${CURR_FOLDER_PATH}/../kind_kubeconfig.yaml"
KIND_KUBECONFIG_INTERNAL="${CURR_FOLDER_PATH}/../kind_kubeconfig_internal.yaml"
KIND_MANAGED_KUBECONFIG="${CURR_FOLDER_PATH}/../kind_kubeconfig_mc.yaml"
KIND_MANAGED_KUBECONFIG_INTERNAL="${CURR_FOLDER_PATH}/../kind_kubeconfig_internal_mc.yaml"
CLUSTER_NAME=$PROJECT_NAME-functional-test

export KUBECONFIG=${KIND_KUBECONFIG}
export DOCKER_IMAGE_AND_TAG=${1}

export FUNCT_TEST_TMPDIR="${CURR_FOLDER_PATH}/../test/functional/tmp"
export FUNCT_TEST_COVERAGE="${CURR_FOLDER_PATH}/../test/functional/coverage"
export FUNCT_TEST_OPERATOR_COVERAGE="${CURR_FOLDER_PATH}/../test/functional/coverage/operator"
export FUNCT_TEST_INSTALLER_COVERAGE="${CURR_FOLDER_PATH}/../test/functional/coverage/installer"

if ! which kubectl > /dev/null; then
    echo "installing kubectl"
    curl -LO https://storage.googleapis.com/kubernetes-release/release/v1.21.1/bin/linux/amd64/kubectl && chmod +x kubectl && sudo mv kubectl /usr/local/bin/
fi
if ! which kind > /dev/null; then
    echo "installing kind"
    curl -Lo ./kind https://github.com/kubernetes-sigs/kind/releases/download/v0.11.1/kind-$(uname)-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
fi
if ! which ginkgo > /dev/null; then
    echo "Installing ginkgo ..."
    pushd $(mktemp -d)
    GOSUMDB=off go get github.com/onsi/ginkgo/ginkgo
    GOSUMDB=off go get github.com/onsi/gomega/...
    popd
fi
if ! which gocovmerge > /dev/null; then
  echo "Installing gocovmerge..."
  pushd $(mktemp -d)
  GOSUMDB=off go get -u github.com/wadey/gocovmerge
  popd
fi

echo "setting up test tmp folder"
[ -d "$FUNCT_TEST_TMPDIR" ] && rm -r "$FUNCT_TEST_TMPDIR"
mkdir -p "$FUNCT_TEST_TMPDIR"
mkdir -p "$FUNCT_TEST_TMPDIR/kind-config"
mkdir -p "$FUNCT_TEST_TMPDIR/CR"

echo "setting up test coverage folders"
[ -d "$FUNCT_TEST_COVERAGE" ] && rm -r "$FUNCT_TEST_COVERAGE"
mkdir -p "${FUNCT_TEST_COVERAGE}"
[ -d "$FUNCT_TEST_OPERATOR_COVERAGE" ] && rm -r "$FUNCT_TEST_OPERATOR_COVERAGE"
mkdir -p "${FUNCT_TEST_OPERATOR_COVERAGE}"
[ -d "$FUNCT_TEST_INSTALLER_COVERAGE" ] && rm -r "$FUNCT_TEST_INSTALLER_COVERAGE"
mkdir -p "${FUNCT_TEST_INSTALLER_COVERAGE}"

echo "generating kind configfile"
cat << EOF > "${FUNCT_TEST_TMPDIR}/kind-config/kind-config.yaml"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration #for worker use JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        system-reserved: memory=2Gi
  extraMounts:
  - hostPath: "${FUNCT_TEST_OPERATOR_COVERAGE}"
    containerPath: /tmp/coverage-operator
  - hostPath: "${FUNCT_TEST_INSTALLER_COVERAGE}"
    containerPath: /tmp/coverage-installer
EOF

echo "creating hub cluster"
kind create cluster --name ${CLUSTER_NAME} --config "${FUNCT_TEST_TMPDIR}/kind-config/kind-config.yaml"

# setup kubeconfig
kind get kubeconfig --name ${CLUSTER_NAME} > ${KIND_KUBECONFIG}
kind get kubeconfig --name ${CLUSTER_NAME} --internal > ${KIND_KUBECONFIG_INTERNAL}
API_SERVER_URL=$(cat ${KIND_KUBECONFIG_INTERNAL}| grep "server:" |cut -d ":" -f2 -f3 -f4 | sed 's/^ //')

# load image if possible
kind load docker-image ${DOCKER_IMAGE_AND_TAG} --name=${CLUSTER_NAME} -v 99 || echo "failed to load image locally, will use imagePullSecret"

echo "install cluster"
make functional-test-crds
make deploy-coverage
echo "Wait deployment stabilize"
sleep 15
echo "Launch functional-test"
make functional-test
# exit 1
echo "Wait 15 sec to let coverage to flush"
sleep 15

echo "remove deployment"
make undeploy-coverage

echo "Wait 10 sec for copy to AWS"
sleep 10

make functional-test-full-clean

if [ `find $FUNCT_TEST_OPERATOR_COVERAGE -prune -empty 2>/dev/null` ]; then
  echo "no operator coverage files found. skipping"
else
  gocovmerge "${FUNCT_TEST_OPERATOR_COVERAGE}/"* >> "${FUNCT_TEST_COVERAGE}/cover-functional.out"
fi

if [ `find $FUNCT_TEST_INSTALLER_COVERAGE -prune -empty 2>/dev/null` ]; then
  echo "no installer coverage files found. skipping"
else
  gocovmerge "${FUNCT_TEST_INSTALLER_COVERAGE}/"* >> "${FUNCT_TEST_COVERAGE}/cover-functional.out"
fi

if [ `find $FUNCT_TEST_OPERATOR_COVERAGE -prune -empty 2>/dev/null` ] &&
   [ `find $FUNCT_TEST_INSTALLER_COVERAGE -prune -empty 2>/dev/null` ]; then
  echo "no coverage files found. skipping"
else

  echo "merging coverage files"

  COVERAGE=$(go tool cover -func="${FUNCT_TEST_COVERAGE}/cover-functional.out" | grep "total:" | awk '{ print $3 }' | sed 's/[][()><%]/ /g')
  echo "-------------------------------------------------------------------------"
  echo "THIS INACCURATE AND NEED TO BE FIXED LATER"
  echo "TOTAL COVERAGE IS ${COVERAGE}%"
  echo "-------------------------------------------------------------------------"

  go tool cover -html "${FUNCT_TEST_COVERAGE}/cover-functional.out" -o ${PROJECT_DIR}/test/functional/coverage/cover-functional.html
fi
