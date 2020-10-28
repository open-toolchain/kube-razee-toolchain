#!/bin/bash
# uncomment to debug the script
# set -x
# This file is a modified version of the following script:
# source: https://raw.githubusercontent.com/open-toolchain/commons/master/scripts/check_and_deploy_kubectl.sh
# based on the version:
#    commit 68f76cdcd4dc6fe467bfd26f9da1a7a5b1d8daeb
#    committed: 2019-08-26 13:06:47 UTC
# which is unchanged in the master committed change at date 2019-08-28 13:23:34 UTC.

# This script checks the IBM Container Service cluster is ready, 
# has a namespace configured with access to the private
# image registry (using an IBM Cloud API Key).
# It aims to install a Razee remoteresource.yml file with a remote reference
# to a deploy.yml file in a configuration repo, so that pods will be deployed
# as defined in that deploy.yml file. 
# Also the remoteresource.yml will reference a config.xml in the config repo, 
# and a Razee agent in the cluster will poll that file to detect changes, 
# re-applying the relevant deploy.yml if the configuration changes.

# Input env variables (can be received via a pipeline environment properties.file.
echo "IMAGE_NAME=${IMAGE_NAME}"
echo "REGISTRY_URL=${REGISTRY_URL}"
echo "REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE}"
echo "DEPLOYMENT_FILE=${DEPLOYMENT_FILE}"
echo "USE_ISTIO_GATEWAY=${USE_ISTIO_GATEWAY}"
echo "KUBERNETES_SERVICE_ACCOUNT_NAME=${KUBERNETES_SERVICE_ACCOUNT_NAME}"
echo "CONFIG_REPO_NAME=${CONFIG_REPO_NAME}"
echo "CONFIG_REPO_URL=${CONFIG_REPO_URL}"
echo "CLUSTER_REGION=${CLUSTER_REGION}"
echo "CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE}"
#  metadata.name from the config repo config.yml file, from a previous job
echo "CONFIG_NAME=${CONFIG_NAME}"
echo "INSTALL_RAZEE=${INSTALL_RAZEE}"

echo "Use for custom Kubernetes cluster target:"
echo "KUBERNETES_MASTER_ADDRESS=${KUBERNETES_MASTER_ADDRESS}"
echo "KUBERNETES_MASTER_PORT=${KUBERNETES_MASTER_PORT}"
echo "KUBERNETES_SERVICE_ACCOUNT_TOKEN=${KUBERNETES_SERVICE_ACCOUNT_TOKEN}"

# View build properties
# if [ -f build.properties ]; then 
#   echo "build.properties:"
#   cat build.properties | grep -v -i password
# else 
#   echo "build.properties : not found"
# fi 
# # also run 'env' command to find all available env variables
# # or learn more about the available environment variables at:
# # https://cloud.ibm.com/docs/services/ContinuousDelivery/pipeline_deploy_var.html#deliverypipeline_environment
# echo "env values:"
# echo "---"
# env
# echo "---"
# echo "_toolchain.json:"
# echo "---"
# cat _toolchain.json | jq -r '.'
# echo "---"


# Input env variables from pipeline job
echo "PIPELINE_KUBERNETES_CLUSTER_NAME=${PIPELINE_KUBERNETES_CLUSTER_NAME}"
echo "CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE}"

# If custom cluster credentials available, connect to this cluster instead
if [ ! -z "${KUBERNETES_MASTER_ADDRESS}" ]; then
  kubectl config set-cluster custom-cluster --server=https://${KUBERNETES_MASTER_ADDRESS}:${KUBERNETES_MASTER_PORT} --insecure-skip-tls-verify=true
  kubectl config set-credentials sa-user --token="${KUBERNETES_SERVICE_ACCOUNT_TOKEN}"
  kubectl config set-context custom-context --cluster=custom-cluster --user=sa-user --namespace="${CLUSTER_NAMESPACE}"
  kubectl config use-context custom-context
fi
kubectl cluster-info
if [ "$?" != "0" ]; then
  red="\x1b[31m"
  no_color="\x1b[0m"
  echo -e "${red}Kubernetes cluster seems not reachable${no_color}"
  exit 1
fi

#Check cluster availability
echo "=========================================================="
echo "CHECKING CLUSTER readiness and namespace existence"
if [ -z "${KUBERNETES_MASTER_ADDRESS}" ]; then
  IP_ADDR=$( ibmcloud ks workers --cluster ${PIPELINE_KUBERNETES_CLUSTER_NAME} | grep normal | head -n 1 | awk '{ print $2 }' )
  if [ -z "${IP_ADDR}" ]; then
    echo -e "${PIPELINE_KUBERNETES_CLUSTER_NAME} not created or workers not ready"
    exit 1
  fi
else
  IP_ADDR=${KUBERNETES_MASTER_ADDRESS}
fi
echo "Configuring cluster namespace"
if kubectl get namespace ${CLUSTER_NAMESPACE}; then
  echo -e "Namespace ${CLUSTER_NAMESPACE} found."
else
  kubectl create namespace ${CLUSTER_NAMESPACE}
  echo -e "Namespace ${CLUSTER_NAMESPACE} created."
fi

# Grant access to private image registry from namespace $CLUSTER_NAMESPACE
# reference https://cloud.ibm.com/docs/containers?topic=containers-images#other_registry_accounts
echo "=========================================================="
echo -e "CONFIGURING ACCESS to private image registry from namespace ${CLUSTER_NAMESPACE}"
IMAGE_PULL_SECRET_NAME="ibmcloud-toolchain-${PIPELINE_TOOLCHAIN_ID}-${REGISTRY_URL}"

echo -e "Checking for presence of ${IMAGE_PULL_SECRET_NAME} imagePullSecret for this toolchain"
if ! kubectl get secret ${IMAGE_PULL_SECRET_NAME} --namespace ${CLUSTER_NAMESPACE}; then
  echo -e "${IMAGE_PULL_SECRET_NAME} not found in ${CLUSTER_NAMESPACE}, creating it"
  # for Container Registry, docker username is 'token' and email does not matter
  if [ -z "${PIPELINE_BLUEMIX_API_KEY}" ]; then PIPELINE_BLUEMIX_API_KEY=${IBM_CLOUD_API_KEY}; fi #when used outside build-in kube job
  kubectl --namespace ${CLUSTER_NAMESPACE} create secret docker-registry ${IMAGE_PULL_SECRET_NAME} --docker-server=${REGISTRY_URL} --docker-password=${PIPELINE_BLUEMIX_API_KEY} --docker-username=iamapikey --docker-email=a@b.com
else
  echo -e "Namespace ${CLUSTER_NAMESPACE} already has an imagePullSecret for this toolchain."
fi
if [ -z "${KUBERNETES_SERVICE_ACCOUNT_NAME}" ]; then KUBERNETES_SERVICE_ACCOUNT_NAME="default" ; fi
SERVICE_ACCOUNT=$(kubectl get serviceaccount ${KUBERNETES_SERVICE_ACCOUNT_NAME}  -o json --namespace ${CLUSTER_NAMESPACE} )
if ! echo ${SERVICE_ACCOUNT} | jq -e '. | has("imagePullSecrets")' > /dev/null ; then
  kubectl patch --namespace ${CLUSTER_NAMESPACE} serviceaccount/${KUBERNETES_SERVICE_ACCOUNT_NAME} -p '{"imagePullSecrets":[{"name":"'"${IMAGE_PULL_SECRET_NAME}"'"}]}'
else
  if echo ${SERVICE_ACCOUNT} | jq -e '.imagePullSecrets[] | select(.name=="'"${IMAGE_PULL_SECRET_NAME}"'")' > /dev/null ; then 
    echo -e "Pull secret already found in ${KUBERNETES_SERVICE_ACCOUNT_NAME} serviceAccount"
  else
    echo "Inserting toolchain pull secret into ${KUBERNETES_SERVICE_ACCOUNT_NAME} serviceAccount"
    kubectl patch --namespace ${CLUSTER_NAMESPACE} serviceaccount/${KUBERNETES_SERVICE_ACCOUNT_NAME} --type='json' -p='[{"op":"add","path":"/imagePullSecrets/-","value":{"name": "'"${IMAGE_PULL_SECRET_NAME}"'"}}]'
  fi
fi
echo "default serviceAccount:"
kubectl get serviceaccount ${KUBERNETES_SERVICE_ACCOUNT_NAME} --namespace ${CLUSTER_NAMESPACE} -o yaml
echo -e "Namespace ${CLUSTER_NAMESPACE} authorizing with private image registry using patched default serviceAccount"

#Update deployment.yml with image name
echo "=========================================================="
echo "CHECKING DEPLOYMENT.YML manifest exists"
if [ -z "${DEPLOYMENT_FILE}" ]; then DEPLOYMENT_FILE=deployment.yml ; fi
if [ ! -f ${DEPLOYMENT_FILE} ]; then
  red="\x1b[31m"
  no_color="\x1b[0m"
  echo -e "${red}Kubernetes deployment file '${DEPLOYMENT_FILE}' not found${no_color}"
  exit 1
fi

echo "=========================================================="
echo "UPDATING manifest, extract service.yml, update with app name, service name, etc"
# if app repo ends in - and a 17 digit timestamp, append that suffix to all kube resources, else empty "" suffix
DEPLOYMENT_DOC_INDEX=$(yq read --doc "*" --tojson $DEPLOYMENT_FILE | jq -r 'to_entries | .[] | select(.value.kind | ascii_downcase=="deployment") | .key')
if [ -z "$DEPLOYMENT_DOC_INDEX" ]; then
  echo "No Kubernetes Deployment definition found in $DEPLOYMENT_FILE. Assuming deployment is YAML document with index 0"
  DEPLOYMENT_DOC_INDEX=0
fi
RESOURCE_SUFFIX=$(echo "${IMAGE_NAME}" | sed -E "s/^.*(-[0-9]{17})$/\1/" | sed -E "/^-[0-9]{17}$/ ! s/.*//")
if [ -z "$RESOURCE_SUFFIX" ]; then
  # No RESOURCE_SUFFIX to append to the deployment name
  DEPLOYMENT_NAME=$( cat $DEPLOYMENT_FILE | yq read --doc $DEPLOYMENT_DOC_INDEX - "metadata.name" )
else 
  # Append RESOURCE_SUFFIX to the deployment name
  DEPLOYMENT_NAME=$( cat $DEPLOYMENT_FILE | yq read --doc $DEPLOYMENT_DOC_INDEX - "metadata.name" | sed "s/${RESOURCE_SUFFIX}//" | sed -E "s/(.+)/\1${RESOURCE_SUFFIX}/" )
fi
# assuming deployment.yml has an initial kind: Deployment, then ---, then a kind: Service for the port
SERVICE_DOC_INDEX=$(yq read --doc "*" --tojson $DEPLOYMENT_FILE | jq -r 'to_entries | .[] | select( (.value.kind | ascii_downcase=="service") and .value.spec.type=="NodePort" ) | .key'  | head -n 1 )
if [ -z "$SERVICE_DOC_INDEX" ]; then
  # fall back to non-NodePort service
  SERVICE_DOC_INDEX=$(yq read --doc "*" --tojson $DEPLOYMENT_FILE | jq -r 'to_entries | .[] | select(.value.kind | ascii_downcase=="service") | .key' | head -n 1 )
fi
if [ -z "$SERVICE_DOC_INDEX" ]; then
  echo "No Kubernetes Service definition found in $DEPLOYMENT_FILE. Assuming service is YAML document with index 1"
  SERVICE_DOC_INDEX=1
fi
SERVICE_FILE="service.yml"
yq read --doc $SERVICE_DOC_INDEX $DEPLOYMENT_FILE > "${SERVICE_FILE}"

if [ -z "$RESOURCE_SUFFIX" ]; then
  # No RESOURCE_SUFFIX to append to the deployment name
  SERVICE_NAME=$( cat $SERVICE_FILE | yq read - "metadata.name")
else
  # Append RESOURCE_SUFFIX to the deployment name
  SERVICE_NAME=$( cat $SERVICE_FILE | yq read - "metadata.name" | sed "s/${RESOURCE_SUFFIX}//" | sed -E "s/(.+)/\1${RESOURCE_SUFFIX}/" )
fi
cp $SERVICE_FILE "${SERVICE_FILE}.bak"
cat "${SERVICE_FILE}.bak" \
  | yq write - "metadata.name" "${SERVICE_NAME}" \
  | yq write - "metadata.labels.app" "${DEPLOYMENT_NAME}" \
  | yq write - "spec.selector.app" "${DEPLOYMENT_NAME}" \
  > "${SERVICE_FILE}"
rm "${SERVICE_FILE}.bak"

cat "${SERVICE_FILE}"

echo "=========================================================="
echo "APPLYING port service using manifest"
echo "kubectl apply --namespace ${CLUSTER_NAMESPACE} -f ${SERVICE_FILE}"
kubectl apply --namespace "${CLUSTER_NAMESPACE}" -f "${SERVICE_FILE}" 

echo "=========================================================="
echo "CHECKING hello-config-repo-secret is installed in the cluster"

if [ -z "${CONFIG_REPO_SECRET_FILE}" ]; then CONFIG_REPO_SECRET_FILE="config-repo-secret.yml" ; fi
if [ ! -f ${CONFIG_REPO_SECRET_FILE} ]; then
  echo "Secret file ${CONFIG_REPO_SECRET_FILE} does not exist, creating."

  cat > "${CONFIG_REPO_SECRET_FILE}" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: hello-config-repo-secret${RESOURCE_SUFFIX}
  labels:
    app: hello-app${RESOURCE_SUFFIX}
type: kubernetes.io/basic-auth
data:
  password: 
EOF
else
  echo "Secret file ${CONFIG_REPO_SECRET_FILE} found, using existing file."
  # Note, the user-provided config-repo-secret.yml should not contain a 
  # hard-coded password/access-code; it'll be overwritten here anyway.
fi

CONFIG_REPO_SECRET_NAME=$(cat $CONFIG_REPO_SECRET_FILE | yq read - "metadata.name" | sed "s/${RESOURCE_SUFFIX}$//" | sed -E "s/(.+)/\1${RESOURCE_SUFFIX}/")

echo "Check secret exists: ${CONFIG_REPO_SECRET_NAME}"
FOUND_SECRET=$(kubectl get secret -o name -n "${CLUSTER_NAMESPACE}" --output=yaml | grep "^secret/${CONFIG_REPO_SECRET_NAME}$" || true )
if [ ! -z "${FOUND_SECRET}" ];
then
  echo "Secret ${CONFIG_REPO_SECRET_NAME} exists in cluster."
else
  echo "Secret ${CONFIG_REPO_SECRET_NAME} not found in cluster, creating."
  echo "Updating Secret file:"

  CONFIG_TOOL_INTEGRATION_ID=$( cat _toolchain.json | jq -r '.services[] | select (.parameters.repo_name=="'"${CONFIG_REPO_NAME}"'") | .service_id ')
  CONFIG_SECRET_RAW_VALUE=""
  if [[ "${CONFIG_TOOL_INTEGRATION_ID}" == "hostedgit" || "${CONFIG_TOOL_INTEGRATION_ID}" == "gitlab" ]]; then
    CONFIG_SECRET_RAW_VALUE="${GIT_PASSWORD}"
  else # githubconsolidated or old pre-consolidation names
    # Note, not yet handling bitbucket.
    CONFIG_SECRET_RAW_VALUE="token ${GIT_PASSWORD}"
  fi
  CONFIG_SECRET_BASE64=$( echo -n "${CONFIG_SECRET_RAW_VALUE}" | base64 )
  
  # DEPLOYMENT_NAME is computed above
  cp "${CONFIG_REPO_SECRET_FILE}" "${CONFIG_REPO_SECRET_FILE}.bak"
  cat "${CONFIG_REPO_SECRET_FILE}.bak" \
    | yq write - "metadata.name" "${CONFIG_REPO_SECRET_NAME}" \
    | yq write - "metadata.labels.app" "${DEPLOYMENT_NAME}" \
    | yq write - "data.password" "${CONFIG_SECRET_BASE64}" \
    > "${CONFIG_REPO_SECRET_FILE}"
  rm "${CONFIG_REPO_SECRET_FILE}.bak"
  # Show the config repo secret file content w/o the password value
  cat ${CONFIG_REPO_SECRET_FILE} | yq write - "data.password" "***"

  echo "kubectl apply -f '${CONFIG_REPO_SECRET_FILE}' --namespace ${CLUSTER_NAMESPACE}"
  kubectl apply -f "${CONFIG_REPO_SECRET_FILE}" --namespace "${CLUSTER_NAMESPACE}"
fi

echo "=========================================================="
echo "APPLYING RemoteResource reference to config repo ${DEPLOY_FILE}"

if [ -z "${REMOTERESOURCE_FILE}" ]; then REMOTERESOURCE_FILE="remoteresource.yml" ; fi
if [ ! -f ${REMOTERESOURCE_FILE} ]; then
  echo "RemoteResource file ${REMOTERESOURCE_FILE} does not exist, creating."

  DEPLOY_FILE="deploy.yml"
  if [ -z "${CONFIG_REPO_BRANCH}" ]; then CONFIG_REPO_BRANCH="master" ; fi
  CONFIG_REPO_HOST=$(echo "${CONFIG_REPO_URL}" | sed -E "s~^https://([^/]+)/.+$~\1~")
  CONFIG_TOOL_INTEGRATION_ID=$( cat _toolchain.json | jq -r '.services[] | select (.parameters.repo_name=="'"${CONFIG_REPO_NAME}"'") | .service_id ')
  # Note the toolchain.yml processing replaces mustache expressions, so need \{\{ escaping
  ACCESS_TOKEN_NAME="config-repo-access-token"
  ACCESS_TOKEN_MUSTACHE=$( echo -n "${ACCESS_TOKEN_NAME}" | sed -E 's/^(.+)$/\{\{\1\}\}/')
  COMMIT_ID_RAW="commit-id"
  COMMIT_ID_MUSTACHE=$(echo -n "${COMMIT_ID_RAW}" | sed -E 's/^(.+)$/\{\{\1\}\}/')
  ARTIFACTS_FOLDER_NAME="artifacts"
  ARTIFACTS_DEPLOY_COMMIT_PATH="${ARTIFACTS_FOLDER_NAME}/${DEPLOYMENT_NAME}_${COMMIT_ID_MUSTACHE}_${DEPLOY_FILE}"
  # Url encode the path except for the \{\{\}\} part
  ARTIFACTS_DEPLOY_COMMIT_PATH=$(echo "${ARTIFACTS_DEPLOY_COMMIT_PATH}" | jq -rR @uri | sed -E "s/(.+)%7B%7B(${COMMIT_ID_RAW})%7D%7D(.+)/\1\{\{\2\}\}\3/g" )

  REGION=$(echo "${CLUSTER_REGION}" | sed -E 's/.+:([^:]+)/\1/')
  COMMIT_KEY="${IMAGE_NAME}_${CLUSTER_NAMESPACE}_${REGION}"
  if [ -z "${CONFIG_FILE}" ]; then CONFIG_FILE="config.yml" ; fi
  # Note, previous stage would have read CONFIG_NAME from config.yml & written it to build.properties
  if [ -z "${CONFIG_NAME}" ]; then CONFIG_NAME="hello-configmap${RESOURCE_SUFFIX}" ; fi

  # Note anonymous access can use /raw/ urls for both github & GRIT,
  # but instead we're assuming private repo and using access tokens
  # so need different urls & headers for GitHub vs hostedgit
  CONFIG_FILE_URL=""
  CONFIG_COMMIT_DEPLOY_URL=""
  CONFIG_DEPLOY_AUTH_HEADER_NAME=""
  CONFIG_DEPLOY_EXTRA_HEADERS=""
  if [[ "${CONFIG_TOOL_INTEGRATION_ID}" == "hostedgit" || "${CONFIG_TOOL_INTEGRATION_ID}" == "gitlab" ]]; then
    CONFIG_REPO_USER_AND_REPO=$(echo "${CONFIG_REPO_URL}" | sed -E "s~^https://[^/]+/(.+)$~\1~" | jq -rR @uri )
    CONFIG_FILE_URL="https://${CONFIG_REPO_HOST}/api/v4/projects/${CONFIG_REPO_USER_AND_REPO}/repository/files/${CONFIG_FILE}/raw?ref=${CONFIG_REPO_BRANCH}"
    CONFIG_COMMIT_DEPLOY_URL="https://${CONFIG_REPO_HOST}/api/v4/projects/${CONFIG_REPO_USER_AND_REPO}/repository/files/${ARTIFACTS_DEPLOY_COMMIT_PATH}/raw?ref=${CONFIG_REPO_BRANCH}"
    CONFIG_DEPLOY_AUTH_HEADER_NAME="PRIVATE-TOKEN"
    CONFIG_DEPLOY_EXTRA_HEADERS=""
  else # githubconsolidated or old pre-consolidation names
    # Note, not yet handling bitbucket.
    CONFIG_REPO_USER=$(echo "${CONFIG_REPO_URL}" | sed -E "s~^https://[^/]+/([^/]+)/.+$~\1~" | jq -rR @uri )
    CONFIG_REPO_REPO=$(echo "${CONFIG_REPO_URL}" | sed -E "s~^https://[^/]+/[^/]+/(.+$)~\1~" | jq -rR @uri )
    CONFIG_FILE_URL="https://api.${CONFIG_REPO_HOST}/repos/${CONFIG_REPO_USER}/${CONFIG_REPO_REPO}/contents/${CONFIG_FILE}?ref=${CONFIG_REPO_BRANCH}"
    CONFIG_COMMIT_DEPLOY_URL="https://api.${CONFIG_REPO_HOST}/repos/${CONFIG_REPO_USER}/${CONFIG_REPO_REPO}/contents/${ARTIFACTS_DEPLOY_COMMIT_PATH}?ref=${CONFIG_REPO_BRANCH}"
    CONFIG_DEPLOY_AUTH_HEADER_NAME="Authorization"
    CONFIG_DEPLOY_EXTRA_HEADERS="Accept: \"application/vnd.github.VERSION.raw\",User-Agent: \"cluster-remoteresource-yml-github-agent\""
    CONFIG_DEPLOY_EXTRA_HEADERS=$(echo ",${CONFIG_DEPLOY_EXTRA_HEADERS}" | tr ',' "\n" | sed -E "s/^(.+)/            \1/g")
  fi

  # note, inserted access token will be in plain text in the RemoteResource
  # would be better to have RemoteResource headers secretKeyRef, 
  # but that mechanism doesn't exist yet.
  cat > "${REMOTERESOURCE_FILE}" << EOF
apiVersion: "deploy.razee.io/v1alpha1"
kind: MustacheTemplate
metadata:
  name: hello-mustachetemplate${RESOURCE_SUFFIX}
  labels:
    app: hello-app${RESOURCE_SUFFIX}
spec:
  env:
  - name: ${ACCESS_TOKEN_NAME}
    valueFrom:
      secretKeyRef:
        name: ${CONFIG_REPO_SECRET_NAME}
        key: password
  - name: commit-id
    # optional because won't be present initially until first RemoteResource has been read
    optional: true
    valueFrom:
      configMapKeyRef:
        name: ${CONFIG_NAME}
        key: "${COMMIT_KEY}"
  templates:
  - apiVersion: deploy.razee.io/v1alpha1
    kind: RemoteResource
    metadata:
      name: hello-config-remote${RESOURCE_SUFFIX}
      labels:
        app: hello-app${RESOURCE_SUFFIX}
    spec:
      requests:
      - options:
          url: "${CONFIG_FILE_URL}"
          headers:
            ${CONFIG_DEPLOY_AUTH_HEADER_NAME}: "${ACCESS_TOKEN_MUSTACHE}"${CONFIG_DEPLOY_EXTRA_HEADERS}
  - apiVersion: deploy.razee.io/v1alpha1
    kind: RemoteResource
    metadata:
      name: hello-deploy-remote${RESOURCE_SUFFIX}
      labels:
        app: hello-app${RESOURCE_SUFFIX}
    spec:
      requests:
      - options:
          url: "${CONFIG_COMMIT_DEPLOY_URL}"
          headers:
            ${CONFIG_DEPLOY_AUTH_HEADER_NAME}: "${ACCESS_TOKEN_MUSTACHE}"${CONFIG_DEPLOY_EXTRA_HEADERS}
EOF
else
  echo "RemoteResource file ${REMOTERESOURCE_FILE} found, using existing file."
fi
echo "RemoteResource file contents:"
cat ${REMOTERESOURCE_FILE} 

echo "kubectl apply -f '${REMOTERESOURCE_FILE}' --namespace ${CLUSTER_NAMESPACE}"
kubectl apply -f "${REMOTERESOURCE_FILE}"  --namespace "${CLUSTER_NAMESPACE}"

echo "=========================================================="
echo "VERIFY RemoteResource deployment changes were applied"
# Note DEPLOYMENT_NAME is set above
DEPLOY_CHANGED_IMAGE_YQPATH="spec.template.spec.containers[0].image"
IMAGE_REPOSITORY="${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}"
DEPLOY_IMAGE_EXPECTED_VALUE="${IMAGE_REPOSITORY}"
# check for 7.5minutes
for ITER in {1..15}
do
  echo "Check deployment exists: ${DEPLOYMENT_NAME}"
  FOUND_DEPLOY=$(kubectl get deploy -n "${CLUSTER_NAMESPACE}" --output=yaml | yq r - "items[*].metadata.name" | grep "^- ${DEPLOYMENT_NAME}$" || true )
  if [ ! -z "${FOUND_DEPLOY}" ];
  then
    echo "Deployment ${DEPLOYMENT_NAME} exists."
    DEPLOY_LABEL_ACTUAL_VALUE=$(kubectl get deploy "${DEPLOYMENT_NAME}" -o yaml -n "${CLUSTER_NAMESPACE}" | yq r - "${DEPLOY_CHANGED_IMAGE_YQPATH}")
    # If deployed image contains @sha, only compare the value before the @, else unchanged
    DEPLOY_LABEL_ACTUAL_VALUE=$( echo "${DEPLOY_LABEL_ACTUAL_VALUE}" | sed -E "/@/ s/(.+)@.+/\1/" )
    #remove the image tag
    DEPLOY_LABEL_ACTUAL_VALUE=$( echo "${DEPLOY_LABEL_ACTUAL_VALUE}" | sed 's/:.*//')
    if [ "${DEPLOY_LABEL_ACTUAL_VALUE}" == "${DEPLOY_IMAGE_EXPECTED_VALUE}" ];
    then
      echo "Deployment image is: ${DEPLOY_LABEL_ACTUAL_VALUE}"
      echo "Deployment ${DEPLOYMENT_NAME} has been successfully updated."
      echo "Razee deployment succeeded."
      RAZEE_DEPLOY_STATUS="OK"
      break
    else
      echo "Deployment expected image is: ${DEPLOY_IMAGE_EXPECTED_VALUE}"
      echo "Deployment actual image is: ${DEPLOY_LABEL_ACTUAL_VALUE}"
      echo "Deployment ${DEPLOYMENT_NAME} not yet updated."
    fi
  else
    echo "Deployment ${DEPLOYMENT_NAME} not found"
  fi
  echo -e "Attempt ${ITER} : Deployment not yet updated. Rechecking shortly..."
  sleep 30
done

if [ "$RAZEE_DEPLOY_STATUS" == "OK" ]; then
  STATUS="pass"
else
  echo "ERROR: Could not verify Razee deploy succeeded ok, please check the log and try again."
  STATUS="fail"
fi

# Record deploy information
if jq -e '.services[] | select(.service_id=="draservicebroker")' _toolchain.json; then
  if [ -z "${KUBERNETES_MASTER_ADDRESS}" ]; then
    DEPLOYMENT_ENVIRONMENT="${PIPELINE_KUBERNETES_CLUSTER_NAME}:${CLUSTER_NAMESPACE}"
  else 
    DEPLOYMENT_ENVIRONMENT="${KUBERNETES_MASTER_ADDRESS}:${CLUSTER_NAMESPACE}"
  fi
  ibmcloud doi publishdeployrecord --env $DEPLOYMENT_ENVIRONMENT \
    --buildnumber ${SOURCE_BUILD_NUMBER} --logicalappname ${IMAGE_NAME} --status ${STATUS}
fi
if [ "$STATUS" == "fail" ]; then
  echo "DEPLOYMENT FAILED"
  exit 1
fi
# Extract app name from actual Kube pod 
# Ensure that the image match the repository, image name and tag without the @ sha id part to handle
# case when image is sha-suffixed or not - ie:
# us.icr.io/sample/hello-containers-20190823092122682:1-master-a15bd262-20190823100927
# or
# us.icr.io/sample/hello-containers-20190823092122682:1-master-a15bd262-20190823100927@sha256:9b56a4cee384fa0e9939eee5c6c0d9912e52d63f44fa74d1f93f3496db773b2e
echo "=========================================================="
#APP_NAME=$(kubectl get pods --namespace ${CLUSTER_NAMESPACE} -o json | jq -r '[ .items[] | select(.spec.containers[]?.image | test("'"${IMAGE_REPOSITORY}"'(@.+|$)")) | .metadata.labels.app] [0]')
APP_NAME=${DEPLOYMENT_NAME}
echo -e "APP: ${APP_NAME}"
echo "DEPLOYED PODS:"
# can use "describe" for detailed output or "get" for short output:
# kubectl describe pods --selector app=${APP_NAME} --namespace ${CLUSTER_NAMESPACE}
kubectl get pods --selector app=${APP_NAME} --namespace ${CLUSTER_NAMESPACE}

# lookup service for current release
APP_SERVICE=$(kubectl get services --namespace ${CLUSTER_NAMESPACE} -o json | jq -r ' .items[] | select (.spec.selector.release=="'"${RELEASE_NAME}"'") | .metadata.name ')
if [ -z "${APP_SERVICE}" ]; then
  # lookup service for current app
  APP_SERVICE=$(kubectl get services --namespace ${CLUSTER_NAMESPACE} -o json | jq -r ' .items[] | select (.spec.selector.app=="'"${APP_NAME}"'") | .metadata.name ')
fi
if [ ! -z "${APP_SERVICE}" ]; then
  echo -e "SERVICE: ${APP_SERVICE}"
  echo "DEPLOYED SERVICES:"
  # can use "describe" for detailed output or "get" for short output:
  # kubectl describe services ${APP_SERVICE} --namespace ${CLUSTER_NAMESPACE}
  kubectl get services ${APP_SERVICE} --namespace ${CLUSTER_NAMESPACE}
fi

echo "DEPLOYED MustacheTemplates:"
# can use "describe" for detailed output or "get" for short output:
# kubectl describe MustacheTemplate ${REMOTE_NAME} --namespace ${CLUSTER_NAMESPACE}
kubectl get MustacheTemplate --selector "app=${APP_NAME}" --namespace "${CLUSTER_NAMESPACE}"

echo "DEPLOYED RemoteResources:"
# can use "describe" for detailed output or "get" for short output:
# kubectl describe RemoteResource ${REMOTE_NAME} --namespace ${CLUSTER_NAMESPACE}
kubectl get RemoteResource --selector "app=${APP_NAME}" --namespace "${CLUSTER_NAMESPACE}"


echo "=========================================================="
echo "DEPLOYMENT SUCCEEDED"
if [ ! -z "${APP_SERVICE}" ]; then
  echo ""
  echo ""
  if [ -z "${KUBERNETES_MASTER_ADDRESS}" ]; then
    IP_ADDR=$( ibmcloud ks workers --cluster ${PIPELINE_KUBERNETES_CLUSTER_NAME} | grep normal | head -n 1 | awk '{ print $2 }' )
    if [ -z "${IP_ADDR}" ]; then
      echo -e "${PIPELINE_KUBERNETES_CLUSTER_NAME} not created or workers not ready"
      exit 1
    fi
  else
    IP_ADDR=${KUBERNETES_MASTER_ADDRESS}
  fi  
  if [ "${USE_ISTIO_GATEWAY}" = true ]; then
    PORT=$( kubectl get svc istio-ingressgateway -n istio-system -o json | jq -r '.spec.ports[] | select (.name=="http2") | .nodePort ' )
    echo -e "*** istio gateway enabled ***"
  else
    PORT=$( kubectl get services --namespace ${CLUSTER_NAMESPACE} | grep ${APP_SERVICE} | sed 's/.*:\([0-9]*\).*/\1/g' )
  fi
  export APP_URL=http://${IP_ADDR}:${PORT} # using 'export', the env var gets passed to next job in stage
  echo "VIEW THE APPLICATION AT: ${APP_URL}"
fi

