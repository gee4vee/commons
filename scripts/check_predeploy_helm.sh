#!/bin/bash
# uncomment to debug the script
#set -x
# copy the script below into your app code repo (e.g. ./scripts/check_predeploy_helm.sh) and 'source' it from your pipeline job
#    source ./scripts/check_predeploy_helm.sh
# alternatively, you can source it from online script:
#    source <(curl -sSL "https://raw.githubusercontent.com/open-toolchain/commons/master/scripts/check_predeploy_helm.sh")
# ------------------
# source: https://raw.githubusercontent.com/open-toolchain/commons/master/scripts/check_predeploy_helm.sh

# This script checks the IBM Container Service cluster is ready, has a namespace configured with access to the private
# image registry (using an IBM Cloud API Key). It also configures Helm Tiller service to later perform a deploy with Helm.

# Input env variables (can be received via a pipeline environment properties.file.
echo "IMAGE_NAME=${IMAGE_NAME}"
echo "IMAGE_TAG=${IMAGE_TAG}"
echo "REGISTRY_URL=${REGISTRY_URL}"
echo "REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE}"
echo "HELM_VERSION=${HELM_VERSION}"

# View build properties
if [ -f build.properties ]; then 
  echo "build.properties:"
  cat build.properties
else 
  echo "build.properties : not found"
fi 
# also run 'env' command to find all available env variables
# or learn more about the available environment variables at:
# https://console.bluemix.net/docs/services/ContinuousDelivery/pipeline_deploy_var.html#deliverypipeline_environment

# Input env variables from pipeline job
echo "PIPELINE_KUBERNETES_CLUSTER_NAME=${PIPELINE_KUBERNETES_CLUSTER_NAME}"
echo "CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE}"

echo "=========================================================="
echo "CHECKING HELM CHART"
if [ -z "${CHART_ROOT}" ]; then CHART_ROOT="chart" ; fi
echo -e "Looking for chart under /${CHART_ROOT}/<CHART_NAME>"
if [ -d ${CHART_ROOT} ]; then
  CHART_NAME=$(find ${CHART_ROOT}/. -maxdepth 2 -type d -name '[^.]?*' -printf %f -quit)
  CHART_PATH=${CHART_ROOT}/${CHART_NAME}
fi
if [ -z "${CHART_PATH}" ]; then
    echo -e "No Helm chart found for Kubernetes deployment under ${CHART_ROOT}/<CHART_NAME>."
    exit 1
else
    echo -e "Helm chart found for Kubernetes deployment : ${CHART_PATH}"
fi
echo "Linting Helm Chart"
helm lint ${CHART_PATH}

#Check cluster availability
echo "=========================================================="
echo "CHECKING CLUSTER readiness and namespace existence"
IP_ADDR=$( bx cs workers ${PIPELINE_KUBERNETES_CLUSTER_NAME} | grep normal | awk '{ print $2 }' )
if [ -z "${IP_ADDR}" ]; then
  echo -e "${PIPELINE_KUBERNETES_CLUSTER_NAME} not created or workers not ready"
  exit 1
fi
echo "Configuring cluster namespace"
if kubectl get namespace ${CLUSTER_NAMESPACE}; then
  echo -e "Namespace ${CLUSTER_NAMESPACE} found."
else
  kubectl create namespace ${CLUSTER_NAMESPACE}
  echo -e "Namespace ${CLUSTER_NAMESPACE} created."
fi

# Grant access to private image registry from namespace $CLUSTER_NAMESPACE
# reference https://console.bluemix.net/docs/containers/cs_cluster.html#bx_registry_other
echo "=========================================================="
echo -e "CONFIGURING ACCESS to private image registry from namespace ${CLUSTER_NAMESPACE}"
IMAGE_PULL_SECRET_NAME="ibmcloud-toolchain-${PIPELINE_TOOLCHAIN_ID}-${REGISTRY_URL}"

echo -e "Checking for presence of ${IMAGE_PULL_SECRET_NAME} imagePullSecret for this toolchain"
if ! kubectl get secret ${IMAGE_PULL_SECRET_NAME} --namespace ${CLUSTER_NAMESPACE}; then
  echo -e "${IMAGE_PULL_SECRET_NAME} not found in ${CLUSTER_NAMESPACE}, creating it"
  # for Container Registry, docker username is 'token' and email does not matter
  kubectl --namespace ${CLUSTER_NAMESPACE} create secret docker-registry ${IMAGE_PULL_SECRET_NAME} --docker-server=${REGISTRY_URL} --docker-password=${PIPELINE_BLUEMIX_API_KEY} --docker-username=iamapikey --docker-email=a@b.com
else
  echo -e "Namespace ${CLUSTER_NAMESPACE} already has an imagePullSecret for this toolchain."
fi
echo "Checking ability to pass pull secret via Helm chart (see also https://console.bluemix.net/docs/containers/cs_images.html#images)"
CHART_PULL_SECRET=$( grep 'pullSecret' ${CHART_PATH}/values.yaml || : )
if [ -z "${CHART_PULL_SECRET}" ]; then
  echo "INFO: Chart is not expecting an explicit private registry imagePullSecret. Patching the cluster default serviceAccount to pass it implicitly instead."
  echo "      Learn how to inject pull secrets into the deployment chart at: https://kubernetes.io/docs/concepts/containers/images/#referring-to-an-imagepullsecrets-on-a-pod"
  echo "      or check out this chart example: https://github.com/open-toolchain/hello-helm/tree/master/chart/hello"
  SERVICE_ACCOUNT=$(kubectl get serviceaccount default  -o json --namespace ${CLUSTER_NAMESPACE} )
  if ! echo ${SERVICE_ACCOUNT} | jq -e '. | has("imagePullSecrets")' > /dev/null ; then
    kubectl patch --namespace ${CLUSTER_NAMESPACE} serviceaccount/default -p '{"imagePullSecrets":[{"name":"'"${IMAGE_PULL_SECRET_NAME}"'"}]}'
  else
    if echo ${SERVICE_ACCOUNT} | jq -e '.imagePullSecrets[] | select(.name=="'"${IMAGE_PULL_SECRET_NAME}"'")' > /dev/null ; then 
      echo -e "Pull secret already found in default serviceAccount"
    else
      echo "Inserting toolchain pull secret into default serviceAccount"
      kubectl patch --namespace ${CLUSTER_NAMESPACE} serviceaccount/default --type='json' -p='[{"op":"add","path":"/imagePullSecrets/-","value":{"name": "'"${IMAGE_PULL_SECRET_NAME}"'"}}]'
    fi
  fi
  echo "default serviceAccount:"
  kubectl get serviceaccount default --namespace ${CLUSTER_NAMESPACE} -o yaml
  echo -e "Namespace ${CLUSTER_NAMESPACE} authorizing with private image registry using patched default serviceAccount"
else
  echo -e "Namespace ${CLUSTER_NAMESPACE} authorized with private image registry using Helm chart imagePullSecret"
fi

echo "=========================================================="
echo "CHECKING HELM CLIENT VERSION"
if [ -z "${HELM_VERSION}" ]; then
  # use locally installed version of Helm
  LOCAL_VERSION=$( helm version --client | grep SemVer: | sed "s/^.*SemVer:\"v\([0-9.]*\).*/\1/" )
    echo -e "No required Helm version specified, defaulting to ${LOCAL_VERSION} found locally"
else
  LOCAL_VERSION==$( helm version --client | grep SemVer: | sed "s/^.*SemVer:\"v\([0-9.]*\).*/\1/" )
  if [ "${HELM_VERSION}" = "${LOCAL_VERSION}" ]; then
    echo -e "Required Helm version ${HELM_VERSION} already found locally"
  else
    echo -e "Installing required Helm version ${HELM_VERSION}"
    WORKING_DIR=$(pwd)
    mkdir ~/tmpbin && cd ~/tmpbin
    curl -L https://storage.googleapis.com/kubernetes-helm/helm-v${HELM_VERSION}-linux-amd64.tar.gz -o helm.tar.gz && tar -xzvf helm.tar.gz
    cd linux-amd64
    export PATH=$(pwd):$PATH
    cd $WORKING_DIR
  fi
fi
helm version --client

echo "=========================================================="
echo "CHECKING HELM SERVER VERSION (TILLER)"
TILLER_VERSION=$( helm version --server | grep SemVer: | sed "s/^.*SemVer:\"v\([0-9.]*\).*/\1/" )
if [ -z "${TILLER_VERSION}" ]; then
    echo -e "Helm Tiller not found. Installing Tiller matching client version: ${HELM_VERSION}"
    helm init --upgrade --force-upgrade
    kubectl rollout status -w deployment/tiller-deploy --namespace=kube-system
    # TODO: once helm version >=2.8.2 replace above 2 lines with
    # helm init --upgrade --force-upgrade --wait
  else
    echo -e "Helm Tiller ${TILLER_VERSION} already installed in cluster. Keeping it."
fi
helm version

echo "=========================================================="
echo -e "CHECKING HELM releases in this namespace: ${CLUSTER_NAMESPACE}"
helm list --namespace ${CLUSTER_NAMESPACE}