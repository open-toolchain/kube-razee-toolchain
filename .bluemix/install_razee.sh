#!/bin/bash
# uncomment to debug the script
# set -x
# This script checks the IBM Container Service cluster is ready, 
# checks if the Razee deployment agent is present in the cluster, 
# and may apply the Razee agent to the cluster if it is absent.

# Input env variables (can be received via a pipeline environment properties.file.
echo "KUBERNETES_SERVICE_ACCOUNT_NAME=${KUBERNETES_SERVICE_ACCOUNT_NAME}"
echo "CLUSTER_REGION=${CLUSTER_REGION}"
echo "CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE}"
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
  IP_ADDR=$( ibmcloud ks workers --cluster "${PIPELINE_KUBERNETES_CLUSTER_NAME}" | grep normal | head -n 1 | awk '{ print $2 }' )
  if [ -z "${IP_ADDR}" ]; then
    echo -e "${PIPELINE_KUBERNETES_CLUSTER_NAME} not created or workers not ready"
    exit 1
  fi
else
  IP_ADDR=${KUBERNETES_MASTER_ADDRESS}
fi

echo "=========================================================="
echo "CHECKING Razee deployment agent is installed in the cluster"
echo "Checking Razee RemoteResource api-resource type registered:"
REMOTE_RESOURCE_TYPE="remoteresources.deploy.razee.io"
#  the || true is to prevent fail on error when grep doesn't find it
FOUND_REMOTE_RESOURCE_TYPE=$(kubectl api-resources --output=name | grep "^${REMOTE_RESOURCE_TYPE}$" || true )
if [ ! -z "${FOUND_REMOTE_RESOURCE_TYPE}" ];
then
  echo "Razee RemoteResource type already registered."
else
  echo "Razee RemoteResource type does not yet exist."

  RAZEE_DEPLOY_URL="https://github.com/razee-io/razeedeploy-delta/releases/latest/download/resource.yaml"

  if [[ "${INSTALL_RAZEE}" != 'true' ]];
  then
    red="\x1b[31m"
    no_color="\x1b[0m"
    echo -e "${red}Razee deployment agent not found in the cluster${no_color}"
    echo "Install it manually with the command:"
    echo "  kubectl apply -f '${RAZEE_DEPLOY_URL}'"
    echo "or change this pipeline stage environment property INSTALL_RAZEE to true and re-run."
    echo "For details about Razee see: https://github.com/razee-io/Razee"
    exit 1
  fi

  echo "Attempt register Razee deployment agent in cluster"
  echo "kubectl apply -f '${RAZEE_DEPLOY_URL}'"
  kubectl apply -f "${RAZEE_DEPLOY_URL}"
  echo "Verify Razee resources exist"
  FOUND_DEPLOY_DELTA=""
  FOUND_DEPLOY_REMOTE_RESOURCE_CONTROLLER=""
  FOUND_POD_REMOTE_RESOURCE_CONTROLLER=""
  for ITER in {1..5}
  do
    if [ -z "${FOUND_DEPLOY_DELTA}" ];
    then
      FOUND_DEPLOY_DELTA=$(kubectl get deploy -n razee --output=name | grep "razeedeploy-delta" || true )
      if [ ! -z "${FOUND_DEPLOY_DELTA}" ];
      then
        echo "Found deploy razeedeploy-delta";
        kubectl get deploy -n razee | grep "razeedeploy-delta"
      else
        echo "Did not find deploy razeedeploy-delta";
      fi
    fi
    if [ ! -z "${FOUND_DEPLOY_DELTA}" ] && [ -z "${FOUND_DEPLOY_REMOTE_RESOURCE_CONTROLLER}" ]; 
    then
      FOUND_DEPLOY_REMOTE_RESOURCE_CONTROLLER=$(kubectl get deploy -n razee --output=name | grep "remoteresource-controller" || true )
      if [ ! -z "${FOUND_DEPLOY_REMOTE_RESOURCE_CONTROLLER}" ];
      then
        echo "Found deploy remoteresource-controller";
        kubectl get deploy -n razee | grep "remoteresource-controller"
      else
        echo "Did not find deploy remoteresource-controller";
      fi
    fi

    if [ ! -z "${FOUND_DEPLOY_DELTA}" ] && [ ! -z "${FOUND_DEPLOY_REMOTE_RESOURCE_CONTROLLER}" ] && [ -z "${FOUND_POD_REMOTE_RESOURCE_CONTROLLER}" ]; 
    then
      FOUND_POD_REMOTE_RESOURCE_CONTROLLER=$(kubectl get pod -n razee --output=name | grep "remoteresource-controller" || true )
      if [ ! -z "${FOUND_DEPLOY_REMOTE_RESOURCE_CONTROLLER}" ];
      then
        echo "Found pod remoteresource-controller";
        kubectl get pod -n razee | grep "remoteresource-controller"
        echo "Found all needed Razee resources.";
        RAZEE_KAPITAN_STATUS="OK"
        break;
      else
        echo "Did not find pod remoteresource-controller";
      fi
    fi
    echo -e "Attempt ${ITER} : Razee resources not yet available. Rechecking shortly..."
    sleep 30
  done
  [[ $RAZEE_KAPITAN_STATUS == "OK" ]] || { echo "ERROR: Could not verify Razee install succeeded ok, please check the log and try again."; exit 1; }
fi
