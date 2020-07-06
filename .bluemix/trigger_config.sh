#!/bin/bash
# uncomment to debug the script
# set -x

# Input env variables (can be received via a pipeline environment properties.file.
echo "CONFIG_REPO_NAME=${CONFIG_REPO_NAME}"
echo "CONFIG_REPO_URL=${CONFIG_REPO_URL}"
echo "IMAGE_NAME=${IMAGE_NAME}"
echo "CLUSTER_REGION=${CLUSTER_REGION}"
echo "CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE}"

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

echo "=========================================================="
echo "UPDATING config repo config.yml"
# Note CONFIG_REPO_NAME, CONFIG_REPO_URL coming from previous stage output
# Augment URL with git user & password

# Augment URL with git user & password
CONFIG_ACCESS_REPO_URL="${CONFIG_REPO_URL:0:8}${GIT_USER}:${GIT_PASSWORD}@${CONFIG_REPO_URL:8}"
REDACTED_PASSWORD=$(echo "${GIT_PASSWORD}" | sed -E 's/.+/*****/g')
echo "Using config repo: ${CONFIG_REPO_URL}, with access token: ${GIT_USER}:${REDACTED_PASSWORD}"

git config --global user.email "autobuild@not-an-email.example.com"
git config --global user.name "Automatic Build: ibmcloud-toolchain-${PIPELINE_TOOLCHAIN_ID}"
git config --global push.default simple

echo "Fetching config repo"
rm -rf "${CONFIG_REPO_NAME}"
git clone "${CONFIG_ACCESS_REPO_URL}"
cd "${CONFIG_REPO_NAME}"

echo "=========================================================="
echo "UPDATING config.yml file"
# extract region from ibm:yp:us-south as us-south
REGION=$(echo "${CLUSTER_REGION}" | sed -E 's/.+:([^:]+)/\1/')
COMMIT_KEY="${IMAGE_NAME}_${CLUSTER_NAMESPACE}_${REGION}"
NEW_VALUE="${GIT_COMMIT}"
echo "New data value: ${COMMIT_KEY}: ${NEW_VALUE}"

if [ -z "${CONFIG_FILE}" ]; then CONFIG_FILE="config.yml" ; fi
if [ ! -f ${CONFIG_FILE} ]; then
  echo "Config file ${CONFIG_FILE} does not exist, creating."

  # Note config file doesn't have app label
  # Also note, name resource suffix is added if new config file, but not if existing file
  # if app repo ends in - and a 17 digit timestamp, append that suffix to all kube resources, else empty "" suffix
  RESOURCE_SUFFIX=$(echo "${IMAGE_NAME}" | sed -E "s/^.*(-[0-9]{17})$/\1/" | sed -E "/^-[0-9]{17}$/ ! s/.*//")

  cat > "${CONFIG_FILE}" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: hello-configmap${RESOURCE_SUFFIX}
data:
  ${COMMIT_KEY}: ${NEW_VALUE}
EOF
else
  echo "Config file ${CONFIG_FILE} found, using existing file."
fi

echo "Updating config file:"
OLD_CONFIG_FILE="${CONFIG_FILE}.bak"
cp "${CONFIG_FILE}" "${OLD_CONFIG_FILE}"
cat "${OLD_CONFIG_FILE}" \
  | yq write - "data.${COMMIT_KEY}" "${NEW_VALUE}" \
  > ${CONFIG_FILE}
rm "${OLD_CONFIG_FILE}"
cat ${CONFIG_FILE}

echo "=========================================================="
echo "UPDATING config repo with ${CONFIG_FILE}"
ls -al "${CONFIG_FILE}"
echo "Add commit:"
git add .
git status
CHANGED_FILES=$(git diff-index HEAD --name-only)
if [ ! -z "${CHANGED_FILES}" ] ; then
  # Note, git commit gives an error if no changed files.
  git commit -m "Published ${CONFIG_FILE} file."
  echo "Push commit:"
  if git push 2>&1 | sed -E "s/$GIT_PASSWORD/*****/g" ; then
    echo "Successfully updated ${CONFIG_FILE} file in config repo at: ${CONFIG_REPO_URL}"
    echo ""
    cd ..
  else
    red="\x1b[31m"
    no_color="\x1b[0m"
    { echo -e "${red}ERROR: Unable to commit the config file, please check the log and try again.${no_color}"; exit 1; }
  fi
else
  echo "No files changed, no changes in git, nothing to do."
  echo ""
  cd ..
fi

# Record config repo info
CONFIG_NAME=$( cat "${CONFIG_REPO_NAME}/${CONFIG_FILE}" | yq read - "metadata.name")
echo "CONFIG_NAME=${CONFIG_NAME}" >> build.properties
echo "CONFIG_REPO_NAME=${CONFIG_REPO_NAME}" >> build.properties
echo "CONFIG_REPO_URL=${CONFIG_REPO_URL}" >> build.properties
echo "Updated build.properties"
cat build.properties | sed -E 's/(.+PASSWORD.*)=.+/\1=****/'