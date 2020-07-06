#!/bin/bash
# uncomment to debug the script
# set -x

# Input env variables (can be received via a pipeline environment properties.file.
echo "IMAGE_NAME=${IMAGE_NAME}"
echo "IMAGE_TAG=${IMAGE_TAG}"
echo "REGISTRY_URL=${REGISTRY_URL}"
echo "REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE}"
echo "DEPLOYMENT_FILE=${DEPLOYMENT_FILE}"

# # View build properties
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

#Update deployment.yml with image name
echo "=========================================================="
echo "CHECKING DEPLOYMENT.YML manifest exists"
if [ -z "${DEPLOYMENT_FILE}" ]; then DEPLOYMENT_FILE="deployment.yml" ; fi
if [ ! -f ${DEPLOYMENT_FILE} ]; then
  red="\x1b[31m"
  no_color="\x1b[0m"
  echo -e "${red}Kubernetes deployment file '${DEPLOYMENT_FILE}' not found${no_color}"
  exit 1
fi


echo "=========================================================="
echo "UPDATING manifest with image information, namespace, labels & extract deploy.yml"
DEPLOYMENT_DOC_INDEX=$(yq read --doc "*" --tojson $DEPLOYMENT_FILE | jq -r 'to_entries | .[] | select(.value.kind | ascii_downcase=="deployment") | .key')
if [ -z "$DEPLOYMENT_DOC_INDEX" ]; then
  echo "No Kubernetes Deployment definition found in $DEPLOYMENT_FILE. Assuming deployment is YAML document with index 0"
  DEPLOYMENT_DOC_INDEX=0
fi
DEPLOY_FILE="deploy.yml"
yq read --doc $DEPLOYMENT_DOC_INDEX $DEPLOYMENT_FILE > "${DEPLOY_FILE}"

echo "Updating ${DEPLOY_FILE} with image: ${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}:${IMAGE_TAG}"
# if app repo ends in - and a 17 digit timestamp, append that suffix to all kube resources, else empty "" suffix
RESOURCE_SUFFIX=$(echo "${IMAGE_NAME}" | sed -E "s/^.*(-[0-9]{17})$/\1/" | sed -E "/^-[0-9]{17}$/ ! s/.*//")
if [ -z "$RESOURCE_SUFFIX" ]; then
  # No RESOURCE_SUFFIX to append to the deployment name
  DEPLOYMENT_NAME=$( cat $DEPLOY_FILE | yq read - "metadata.name")
else 
  # Append RESOURCE_SUFFIX to the deployment name
  DEPLOYMENT_NAME=$( cat $DEPLOY_FILE | yq read - "metadata.name" | sed "s/${RESOURCE_SUFFIX}//" | sed -E "s/(.+)/\1${RESOURCE_SUFFIX}/")
fi
cp $DEPLOY_FILE "${DEPLOY_FILE}.bak"
cat "${DEPLOY_FILE}.bak" \
  | yq write - "spec.template.spec.containers[0].image" "${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}:${IMAGE_TAG}" \
  | yq write - "metadata.labels.app" "${DEPLOYMENT_NAME}" \
  | yq write - "metadata.name" "${DEPLOYMENT_NAME}" \
  | yq write - "spec.selector.matchLabels.app" "${DEPLOYMENT_NAME}" \
  | yq write - "spec.template.metadata.labels.app" "${DEPLOYMENT_NAME}" \
  | yq write - "spec.template.spec.containers[0].name" "${DEPLOYMENT_NAME}" \
  > ${DEPLOY_FILE}
rm "${DEPLOY_FILE}.bak"
# note, when namespace is absent in deploy.yml, so it'll use the namespace 
# of the RemoteResource that imports the deploy.yml

echo "deploy.yml:"
cat "${DEPLOY_FILE}"
echo "Artifact deploy file name:"
ARTIFACTS_FOLDER_NAME="artifacts"
ARTIFACTS_DEPLOY_FILE_NAME="${DEPLOYMENT_NAME}_${GIT_COMMIT}_${DEPLOY_FILE}"
echo "${ARTIFACTS_FOLDER_NAME}/${ARTIFACTS_DEPLOY_FILE_NAME}"

echo "=========================================================="
echo "UPDATING config repo with ${ARTIFACTS_FOLDER_NAME}/...${DEPLOY_FILE}"
echo -e "Locating target config repo using _toolchain.json file contents"
ls -al _toolchain.json
# find the other repo that is not the main app repo
CONFIG_REPO_DETAILS=$(cat _toolchain.json | jq -r '.services[] | select (.parameters.repo_url and .parameters.repo_url!="'"${GIT_URL}"'" and (.parameters.repo_url | contains("tekton-catalog") | not)  and (.parameters.repo_url | contains("kube-razee") | not))')
CONFIG_REPO_NAME=$( echo "${CONFIG_REPO_DETAILS}" | jq -r 'select (.parameters.repo_name | contains("config")) | .parameters.repo_name')
CONFIG_REPO_URL=$( echo "${CONFIG_REPO_DETAILS}" | jq -r 'select (.parameters.repo_name | contains("config")) | .parameters.repo_url') 
CONFIG_REPO_URL=${CONFIG_REPO_URL%".git"} #remove trailing .git if present
# Note this won't work if the config repo and the app repo are in different regions or git hosts - would have the wrong GIT_PASSWORD
CONFIG_REPO_HOST=$(echo "${CONFIG_REPO_URL}" | sed -E "s~^https://([^/]+)/.+$~\1~")
APP_REPO_HOST=$(echo "${GIT_URL}" | sed -E "s~^https://([^/]+)/.+$~\1~" )
if [ "${CONFIG_REPO_HOST}" != "${APP_REPO_HOST}" ];
then
    echo "${CONFIG_REPO_HOST} != ${APP_REPO_HOST}"
    yellow="\x1b[33m"
    no_color="\x1b[0m"
    echo -e "${yellow}WARNING${no_color}: Configuration repository is on a different server to the application repository; won't be able to reuse credentials."
fi
# Augment URL with git user & password
CONFIG_ACCESS_REPO_URL="${CONFIG_REPO_URL:0:8}${GIT_USER}:${GIT_PASSWORD}@${CONFIG_REPO_URL:8}"
REDACTED_PASSWORD=$(echo "${GIT_PASSWORD}" | sed -E 's/.+/*****/g')
echo -e "Located config repo: ${CONFIG_REPO_URL}, with access token: ${GIT_USER}:${REDACTED_PASSWORD}"

git config --global user.email "autobuild@not-an-email.example.com"
git config --global user.name "Automatic Build: ibmcloud-toolchain-${PIPELINE_TOOLCHAIN_ID}"
git config --global push.default simple

echo "Fetching config repo"
git clone "${CONFIG_ACCESS_REPO_URL}"

cd "${CONFIG_REPO_NAME}"
echo "copy deploy file to ${ARTIFACTS_FOLDER_NAME}/${ARTIFACTS_DEPLOY_FILE_NAME}"
mkdir -p "${ARTIFACTS_FOLDER_NAME}"
cp "../${DEPLOY_FILE}" "${ARTIFACTS_FOLDER_NAME}/${ARTIFACTS_DEPLOY_FILE_NAME}"
ls -al "${ARTIFACTS_FOLDER_NAME}/${ARTIFACTS_DEPLOY_FILE_NAME}"
echo "Add commit:"
git add .
git status

# note for initial empty repo, no branches will be found
BRANCHES_FOUND=$(git branch)
CHANGED_FILES=""
if [ ! -z "${BRANCHES_FOUND}" ]; then 
  CHANGED_FILES=$(git diff-index HEAD --name-only)
else
  CHANGED_FILES="initial"
fi
if [ ! -z "${CHANGED_FILES}" ] ; then
  # Note, git commit gives an error if no changed files.
  git commit -m "Published ${ARTIFACTS_FOLDER_NAME}/...${DEPLOY_FILE} file."
  echo "Push commits:"
  if git push 2>&1 | sed -E "s/$GIT_PASSWORD/*****/g" ; then
    echo "Successfully created deploy file in config repo at: ${CONFIG_REPO_URL}"
    echo ""
    cd ..
  else
    red="\x1b[31m"
    no_color="\x1b[0m"
    { echo -e "${red}ERROR: Unable to commit the deploy file, please check the log and try again.${no_color}"; exit 1; }
  fi
else
  echo "No files changed, no changes in git, nothing to do."
  echo ""
  cd ..
fi

# export so the variables are available in the next job:
export CONFIG_REPO_NAME="${CONFIG_REPO_NAME}"
export CONFIG_REPO_URL="${CONFIG_REPO_URL}"