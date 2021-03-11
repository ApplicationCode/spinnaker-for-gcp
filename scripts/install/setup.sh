#!/usr/bin/env bash

err() {
  echo "$*" >&2;
}

[ -z "$PARENT_DIR" ] && PARENT_DIR=$(dirname $(realpath $0) | rev | cut -d '/' -f 4- | rev)

#Imports Service Utils scripts having some common functions
source $PARENT_DIR/spinnaker-for-gcp/scripts/manage/service_utils.sh

#Checks for the (git gcloud jq kubectl) binaries to be present on the system executing the scripts
check_for_required_binaries

#Checks if git is properly configured (probably for CSR)
PARENT_DIR=$PARENT_DIR $PARENT_DIR/spinnaker-for-gcp/scripts/manage/check_git_config.sh || exit 1

[ -z "$PROPERTIES_FILE" ] && PROPERTIES_FILE="$PARENT_DIR/spinnaker-for-gcp/scripts/install/properties"

#Imports the property file that has the variables for spinnaker
source "$PROPERTIES_FILE"

#Shared VPC install is not currently supported when CI is true, probably when cloud build is used to install spinnaker
check_for_shared_vpc $CI

#Checks that the project id matches the one returned by gcloud command 
PARENT_DIR=$PARENT_DIR PROPERTIES_FILE=$PROPERTIES_FILE $PARENT_DIR/spinnaker-for-gcp/scripts/manage/check_project_mismatch.sh

#Gets the user account or the main account running gcloud commands
OPERATOR_SA_EMAIL=$(gcloud config list account --format "value(core.account)" --project $PROJECT_ID)
# Generally returns 'role/owner'
SETUP_EXISTING_ROLES=$(gcloud projects get-iam-policy --filter bindings.members:$OPERATOR_SA_EMAIL $PROJECT_ID \
  --flatten bindings[].members --format="value(bindings.role)")

# if the variable created is blank then we can't proceed
if [ -z "$SETUP_EXISTING_ROLES" ]; then
  bold "Unable to verify that the service account \"$OPERATOR_SA_EMAIL\" has the required IAM roles."
  bold "\"$OPERATOR_SA_EMAIL\" requires the IAM role \"Project IAM Admin\" to proceed."
  exit 1
fi

# if variable created doesn't have a 'roles/owner' present then we need the below 'SETUP_REQUIRED_ROLES' as minimum to proceed
if [ -z "$(echo $SETUP_EXISTING_ROLES | grep roles/owner)" ]; then
  SETUP_REQUIRED_ROLES=(cloudfunctions.developer compute.networkViewer container.admin iam.serviceAccountCreator iam.serviceAccountUser pubsub.editor redis.admin serviceusage.serviceUsageAdmin source.admin storage.admin)
  
  MISSING_ROLES=""
  for r in "${SETUP_REQUIRED_ROLES[@]}"; do
    if [ -z "$(echo $SETUP_EXISTING_ROLES | grep $r)" ]; then
      if [ -z "$MISSING_ROLES" ]; then
        MISSING_ROLES="$r"
      else 
        MISSING_ROLES="$MISSING_ROLES, $r"
      fi
    fi
  done

  if [ -n "$MISSING_ROLES" ]; then 
    bold "The service account in use, \"$OPERATOR_SA_EMAIL\", is missing the following required role(s): $MISSING_ROLES."
    bold "Add the required role(s) and try re-running the script."
    exit 1
  fi
fi

#All these APIs are required to be enabled
REQUIRED_APIS="cloudbuild.googleapis.com cloudfunctions.googleapis.com container.googleapis.com endpoints.googleapis.com iap.googleapis.com monitoring.googleapis.com redis.googleapis.com sourcerepo.googleapis.com"
NUM_REQUIRED_APIS=$(wc -w <<< "$REQUIRED_APIS")
#Currently enabled APIs
NUM_ENABLED_APIS=$(gcloud services list --project $PROJECT_ID \
  --filter="config.name:($REQUIRED_APIS)" \
  --format="value(config.name)" | wc -l)

#Sort of a crude method of just comparing the count
if [ $NUM_ENABLED_APIS != $NUM_REQUIRED_APIS ]; then
  bold "Enabling required APIs ($REQUIRED_APIS) in $PROJECT_ID..."
  bold "This phase will take a few minutes (progress will not be reported during this operation)."
  bold
  bold "Once the required APIs are enabled, the remaining components will be installed and configured. The entire installation may take 10 minutes or more."

#Enable all the required APIs, works well as re-enabling an API doesn't hurt
  gcloud services --project $PROJECT_ID enable $REQUIRED_APIS
fi

#Specific check for shared VPC
if [ "$PROJECT_ID" != "$NETWORK_PROJECT" ]; then
  # Cloud Memorystore for Redis requires the Redis instance to be deployed in the Shared VPC
  # host project: https://cloud.google.com/memorystore/docs/redis/networking#limited_and_unsupported_networks
  if [ ! $(has_service_enabled $NETWORK_PROJECT redis.googleapis.com) ]; then
    bold "Enabling redis.googleapis.com in $NETWORK_PROJECT..."

    gcloud services --project $NETWORK_PROJECT enable redis.googleapis.com
  fi
fi

#this scripts has methods for checking exisiting gke clusters and their configs
source $PARENT_DIR/spinnaker-for-gcp/scripts/manage/cluster_utils.sh

#Check that the cluster is there
CLUSTER_EXISTS=$(check_for_existing_cluster)

if [ -n "$CLUSTER_EXISTS" ]; then
  # Check the location of the cluster, if its not zonal ie is Regional then error out
  check_existing_cluster_location

  bold "Retrieving credentials for GKE cluster $GKE_CLUSTER..."
  gcloud container clusters get-credentials $GKE_CLUSTER --zone $ZONE --project $PROJECT_ID

  bold "Checking for Spinnaker application in cluster $GKE_CLUSTER..."
  SPINNAKER_APPLICATION_LIST_JSON=$(kubectl get applications -n spinnaker -l app.kubernetes.io/name=spinnaker --output json)
  SPINNAKER_APPLICATION_COUNT=$(echo $SPINNAKER_APPLICATION_LIST_JSON | jq '.items | length')

  if [ -n "$SPINNAKER_APPLICATION_COUNT" ] && [ "$SPINNAKER_APPLICATION_COUNT" != "0" ]; then
    bold "The GKE cluster $GKE_CLUSTER already contains an installed Spinnaker application."

    if [ "$SPINNAKER_APPLICATION_COUNT" == "1" ]; then
      EXISTING_SPINNAKER_APPLICATION_NAME=$(echo $SPINNAKER_APPLICATION_LIST_JSON | jq -r '.items[0].metadata.name')

      #If app names match, probably the install failed mid-way so continue with the install now
      if [ "$EXISTING_SPINNAKER_APPLICATION_NAME" == "$DEPLOYMENT_NAME" ]; then
        bold "Name of existing Spinnaker application matches name specified in properties file; carrying on with installation..."
      else
        bold "Please choose another cluster."
        exit 1
      fi
    else
      # Should never be more than 1 deployment in a cluster, but protect against it just in case.
      bold "Please choose another cluster."
      exit 1
    fi
  fi
fi

#Checks for mode can be AUTO, CUSTOM or LEGACY (not supported)
NETWORK_SUBNET_MODE=$(gcloud compute networks list --project $NETWORK_PROJECT \
  --filter "name=$NETWORK" \
  --format "value(x_gcloud_subnet_mode)")

#If the specified network is not found then error out
if [ -z "$NETWORK_SUBNET_MODE" ]; then
  bold "Network $NETWORK was not found in project $NETWORK_PROJECT."
  exit 1
#If a LEGACY network is found then error out  
elif [ "$NETWORK_SUBNET_MODE" = "LEGACY" ]; then
  bold "Network $NETWORK is a legacy network. This installation requires a" \
       "non-legacy network. Please specify a non-legacy network in" \
       "$PROPERTIES_FILE and re-run this script."
  exit 1
fi

# Verify that the subnet exists in the network.
SUBNET_CHECK=$(gcloud compute networks subnets list --project=$NETWORK_PROJECT \
  --network=$NETWORK --filter "region: ($REGION) AND name: ($SUBNET)" \
  --format "value(name)")

if [ -z "$SUBNET_CHECK" ]; then
  bold "Subnet $SUBNET was not found in network $NETWORK" \
       "in project $NETWORK_PROJECT. Please specify an existing subnet in" \
       "$PROPERTIES_FILE and re-run this script. You can verify" \
       "what subnetworks exist in this network by running:"
  bold "  gcloud compute networks subnets list --project $NETWORK_PROJECT --network=$NETWORK --filter \"region: ($REGION)\""
  exit 1
fi

#Gets the email from SA name, since this is the k8s SA so this should get resolved and there shouldn't be a need to create one as below
SA_EMAIL=$(gcloud iam service-accounts --project $PROJECT_ID list \
  --filter="displayName:$SERVICE_ACCOUNT_NAME" \
  --format='value(email)')

#Most of the if-else now check for exisitence of resources before creating, this is probably to account for script failures in-between

#IF SA is not there create, shouldn't happen in existing k8s cluster
if [ -z "$SA_EMAIL" ]; then
  bold "Creating service account $SERVICE_ACCOUNT_NAME..."

  gcloud iam service-accounts --project $PROJECT_ID create \
    $SERVICE_ACCOUNT_NAME \
    --display-name $SERVICE_ACCOUNT_NAME

  #After issuing the above command, wait on 5sec loop to let it complete
  while [ -z "$SA_EMAIL" ]; do
    SA_EMAIL=$(gcloud iam service-accounts --project $PROJECT_ID list \
      --filter="displayName:$SERVICE_ACCOUNT_NAME" \
      --format='value(email)')
    sleep 5
  done
else
#this should be printed
  bold "Using existing service account $SERVICE_ACCOUNT_NAME..."
fi

bold "Assigning required roles to $SERVICE_ACCOUNT_NAME..."

#Roles required by the SA, 
K8S_REQUIRED_ROLES=(cloudbuild.builds.editor container.admin logging.logWriter monitoring.admin pubsub.admin storage.admin)
EXISTING_ROLES=$(gcloud projects get-iam-policy --filter bindings.members:$SA_EMAIL $PROJECT_ID \
  --flatten bindings[].members --format="value(bindings.role)")

#if not already assigned then assign
for r in "${K8S_REQUIRED_ROLES[@]}"; do
  if [ -z "$(echo $EXISTING_ROLES | grep $r)" ]; then
    bold "Assigning role $r..."
    gcloud projects add-iam-policy-binding $PROJECT_ID \
      --member serviceAccount:$SA_EMAIL \
      --role roles/$r \
      --format=none
  fi
done

#If redis instance is already present, like was created but then the script failed, so try to figure if the instance is there
export REDIS_INSTANCE_HOST=$(gcloud redis instances list \
  --project $NETWORK_PROJECT --region $REGION \
  --filter="name=projects/$NETWORK_PROJECT/locations/$REGION/instances/$REDIS_INSTANCE" \
  --format="value(host)")

#If the instance is not there, which will be the case for a new install
if [ -z "$REDIS_INSTANCE_HOST" ]; then
  bold "Creating redis instance $REDIS_INSTANCE in project $NETWORK_PROJECT..."

  gcloud redis instances create $REDIS_INSTANCE --project $NETWORK_PROJECT \
    --region=$REGION --zone=$ZONE --network=$NETWORK_REFERENCE \
#https://raw.githubusercontent.com/redis/redis/3.2/redis.conf 
#  K     Keyspace events, published with __keyspace@<db>__ prefix.
#  E     Keyevent events, published with __keyevent@<db>__ prefix.
#  g     Generic commands (non-type specific) like DEL, EXPIRE, RENAME, ...
#  $     String commands
#  l     List commands
#  s     Set commands
#  h     Hash commands
#  z     Sorted set commands
#  x     Expired events (events generated every time a key expires)
#  e     Evicted events (events generated when a key is evicted for maxmemory)
#  A     Alias for g$lshzxe, so that the "AKE" string means all the events.    
    --redis-config=notify-keyspace-events=gxE

  export REDIS_INSTANCE_HOST=$(gcloud redis instances list \
    --project $NETWORK_PROJECT --region $REGION \
    --filter="name=projects/$NETWORK_PROJECT/locations/$REGION/instances/$REDIS_INSTANCE" \
    --format="value(host)")
else
  bold "Using existing redis instance $REDIS_INSTANCE ($REDIS_INSTANCE_HOST)..."
fi

# TODO: Could verify ACLs here. In the meantime, error messages should suffice.
#Checks if the bucket is there
gsutil ls $BUCKET_URI

if [ $? != 0 ]; then
  bold "Creating bucket $BUCKET_URI..."

  gsutil mb -p $PROJECT_ID -l $REGION $BUCKET_URI
  #Enables versioning on the bucket not sure why
  gsutil versioning set on $BUCKET_URI
else
  bold "Using existing bucket $BUCKET_URI..."
fi

if [ -z "$CLUSTER_EXISTS" ]; then
  bold "Creating GKE cluster $GKE_CLUSTER..."

  # TODO: Move some of these config settings to properties file.
  # TODO: Should this be regional instead?
  eval gcloud beta container clusters create $GKE_CLUSTER --project $PROJECT_ID \
    --zone $ZONE --username "admin" --network $NETWORK_REFERENCE --subnetwork $SUBNET_REFERENCE \
    --cluster-version $GKE_CLUSTER_VERSION --machine-type $GKE_MACHINE_TYPE --image-type "COS" \
    --disk-type $GKE_DISK_TYPE --disk-size $GKE_DISK_SIZE --service-account $SA_EMAIL \
    --num-nodes $GKE_NUM_NODES --enable-stackdriver-kubernetes --enable-autoupgrade \
    --enable-autorepair --enable-ip-alias --addons HorizontalPodAutoscaling,HttpLoadBalancing \
    #Create VPC native cluster, add the secondary ranges for pods and services if specified in the config
    "${CLUSTER_SECONDARY_RANGE_NAME:+'--cluster-secondary-range-name' $CLUSTER_SECONDARY_RANGE_NAME}" \
    "${SERVICES_SECONDARY_RANGE_NAME:+'--services-secondary-range-name' $SERVICES_SECONDARY_RANGE_NAME}"

  # If the cluster already exists, we already retrieved credentials way up at the top of the script.
  # If this is a new cluster we get the credentials now
  bold "Retrieving credentials for GKE cluster $GKE_CLUSTER..."
  gcloud container clusters get-credentials $GKE_CLUSTER --zone $ZONE --project $PROJECT_ID
else
  bold "Using existing GKE cluster $GKE_CLUSTER..."
  #method in cluster_utils.sh to check pre-reqs of an exisiting cluster
  check_existing_cluster_prereqs
fi

#pubsub topic for GCR
GCR_PUBSUB_TOPIC_NAME=projects/$PROJECT_ID/topics/gcr
EXISTING_GCR_PUBSUB_TOPIC_NAME=$(gcloud pubsub topics list --project $PROJECT_ID \
  --filter="name=$GCR_PUBSUB_TOPIC_NAME" --format="value(name)")

#Creating a topic for GCR, this is not somthing that automatically comes when gcr api is enabled, but is being explicitly created here
#but the catch is once the topic is created GCR automatically starts pushing updates to it without any additional config
if [ -z "$EXISTING_GCR_PUBSUB_TOPIC_NAME" ]; then
  bold "Creating pubsub topic $GCR_PUBSUB_TOPIC_NAME for GCR..."
  gcloud pubsub topics create --project $PROJECT_ID $GCR_PUBSUB_TOPIC_NAME
else
  bold "Using existing pubsub topic $EXISTING_GCR_PUBSUB_TOPIC_NAME for GCR..."
fi

EXISTING_GCR_PUBSUB_SUBSCRIPTION_NAME=$(gcloud pubsub subscriptions list \
  --project $PROJECT_ID \
  --filter="name=projects/$PROJECT_ID/subscriptions/$GCR_PUBSUB_SUBSCRIPTION" \
  --format="value(name)")

#Creating a subscription to the topic created above
if [ -z "$EXISTING_GCR_PUBSUB_SUBSCRIPTION_NAME" ]; then
  bold "Creating pubsub subscription $GCR_PUBSUB_SUBSCRIPTION for GCR..."
  gcloud pubsub subscriptions create --project $PROJECT_ID $GCR_PUBSUB_SUBSCRIPTION \
    --topic=gcr
else
  bold "Using existing pubsub subscription $GCR_PUBSUB_SUBSCRIPTION for GCR..."
fi

#Creating a topic for cloud-buils, this is not somthing that automatically comes when cloudbuild api is enabled, but is being explicitly created here
#but the catch is once the topic is created cloudbuild automatically starts pushing updates to it without any additional config
GCB_PUBSUB_TOPIC_NAME=projects/$PROJECT_ID/topics/cloud-builds
EXISTING_GCB_PUBSUB_TOPIC_NAME=$(gcloud pubsub topics list --project $PROJECT_ID \
  --filter="name=$GCB_PUBSUB_TOPIC_NAME" --format="value(name)")

if [ -z "$EXISTING_GCB_PUBSUB_TOPIC_NAME" ]; then
  bold "Creating pubsub topic $GCB_PUBSUB_TOPIC_NAME for GCB..."
  gcloud pubsub topics create --project $PROJECT_ID $GCB_PUBSUB_TOPIC_NAME
else
  bold "Using existing pubsub topic $EXISTING_GCB_PUBSUB_TOPIC_NAME for GCB..."
fi

EXISTING_GCB_PUBSUB_SUBSCRIPTION_NAME=$(gcloud pubsub subscriptions list \
  --project $PROJECT_ID \
  --filter="name=projects/$PROJECT_ID/subscriptions/$GCB_PUBSUB_SUBSCRIPTION" \
  --format="value(name)")

#Creating a subscription to the topic created above
if [ -z "$EXISTING_GCB_PUBSUB_SUBSCRIPTION_NAME" ]; then
  bold "Creating pubsub subscription $GCB_PUBSUB_SUBSCRIPTION for GCB..."
  gcloud pubsub subscriptions create --project $PROJECT_ID $GCB_PUBSUB_SUBSCRIPTION \
    --topic=projects/$PROJECT_ID/topics/cloud-builds
else
  bold "Using existing pubsub subscription $GCB_PUBSUB_SUBSCRIPTION for GCB..."
fi

#Creating a topic where spinnaker will publish notifications, thus there is no subscription created after topic creation
NOTIFICATION_PUBSUB_TOPIC_NAME=projects/$PROJECT_ID/topics/$PUBSUB_NOTIFICATION_TOPIC
EXISTING_NOTIFICATION_PUBSUB_TOPIC_NAME=$(gcloud pubsub topics list --project $PROJECT_ID \
  --filter="name=$NOTIFICATION_PUBSUB_TOPIC_NAME" --format="value(name)")

if [ -z "$EXISTING_NOTIFICATION_PUBSUB_TOPIC_NAME" ]; then
  bold "Creating pubsub topic $NOTIFICATION_PUBSUB_TOPIC_NAME for notifications..."
  gcloud pubsub topics create --project $PROJECT_ID $NOTIFICATION_PUBSUB_TOPIC_NAME
else
  bold "Using existing pubsub topic $EXISTING_NOTIFICATION_PUBSUB_TOPIC_NAME for notifications..."
fi

# Serious Stuff - Actual Spinnaker Installation
#
#
#

#If a deploy job is running from previous script 
EXISTING_HAL_DEPLOY_APPLY_JOB_NAME=$(kubectl get job -n halyard \
  --field-selector metadata.name=="hal-deploy-apply" \
  -o json | jq -r .items[0].metadata.name)

#then kill it
if [ $EXISTING_HAL_DEPLOY_APPLY_JOB_NAME != 'null' ]; then
  bold "Deleting earlier job $EXISTING_HAL_DEPLOY_APPLY_JOB_NAME..."

  kubectl delete job hal-deploy-apply -n halyard
fi

bold "Provisioning Spinnaker resources..."

#Script with YAML resources for spinnaker
#Namespace: halyard
#Namespace: Spinnaker
#CRB: give the default SA for above Namespaces Cluster-Admin role
#PVC: 10Gi in Halyard NS
#SS: spin-halyard in Halyard NS mount PVC from above
#Headless Service: for above SS
#ConfigMap: to be mounted to above SS
#Job: hal-deploy-apply, the same that was killed above 
envsubst < $PARENT_DIR/spinnaker-for-gcp/scripts/install/quick-install.yml | kubectl apply -f -

#Create a wait function for the Job to complete
job_ready() {
  printf "Waiting on job $1 to complete"
  while [[ "$(kubectl get job $1 -n halyard -o \
            jsonpath="{.status.succeeded}")" != "1" ]]; do
    printf "."
    sleep 5
  done
  echo ""
}

job_ready hal-deploy-apply

# Sourced to import $IP_ADDR. this variable gets populated if you have already allocated a static IP for spinnaker
# Used at the end of setup to check if installation is exposed via a secured endpoint.
source $PARENT_DIR/spinnaker-for-gcp/scripts/manage/update_landing_page.sh

# Calling the script(deploy_application_manifest.sh) instead of sourcing it so the script get executed
# Script does the following:
# Creates a CRD and then the Spinnaker Application of that CRD
#
PARENT_DIR=$PARENT_DIR PROPERTIES_FILE=$PROPERTIES_FILE $PARENT_DIR/spinnaker-for-gcp/scripts/manage/deploy_application_manifest.sh

# Delete any existing deployment config secret.
# It will be recreated with up-to-date contents during push_config.sh.
EXISTING_DEPLOYMENT_SECRET_NAME=$(kubectl get secret -n halyard \
  --field-selector metadata.name=="spinnaker-deployment" \
  -o json | jq .items[0].metadata.name)

if [ $EXISTING_DEPLOYMENT_SECRET_NAME != 'null' ]; then
  bold "Deleting Kubernetes secret spinnaker-deployment..."
  kubectl delete secret spinnaker-deployment -n halyard
fi

#Checking if Cloud function is already present, this is for audit log, not sure if we need it
EXISTING_CLOUD_FUNCTION=$(gcloud functions list --project $PROJECT_ID \
  --format="value(name)" --filter="entryPoint=$CLOUD_FUNCTION_NAME")

#Create a JS cloud function for audit  Logs Spinnaker events to Stackdriver Logging so this is important to implement
if [ -z "$EXISTING_CLOUD_FUNCTION" ]; then
  bold "Deploying audit log cloud function $CLOUD_FUNCTION_NAME..."

  cat $PARENT_DIR/spinnaker-for-gcp/scripts/install/spinnakerAuditLog/config_json.template | envsubst > $PARENT_DIR/spinnaker-for-gcp/scripts/install/spinnakerAuditLog/config.json
  cat $PARENT_DIR/spinnaker-for-gcp/scripts/install/spinnakerAuditLog/index_js.template | envsubst > $PARENT_DIR/spinnaker-for-gcp/scripts/install/spinnakerAuditLog/index.js
  gcloud functions deploy $CLOUD_FUNCTION_NAME --source $PARENT_DIR/spinnaker-for-gcp/scripts/install/spinnakerAuditLog \
    --trigger-http --memory 2048MB --runtime nodejs8 --allow-unauthenticated --project $PROJECT_ID --region $REGION
  gcloud alpha functions add-iam-policy-binding $CLOUD_FUNCTION_NAME --project $PROJECT_ID --region $REGION --member allUsers --role roles/cloudfunctions.invoker
else
  bold "Using existing audit log cloud function $CLOUD_FUNCTION_NAME..."
fi

#This is probably the place where we go ahead and install spinnaker finally
#
if [ "$USE_CLOUD_SHELL_HAL_CONFIG" = true ]; then
  # Not passing $CI since the guard makes it clear we are running from cloud shell.
  # Probably this one is run through cloud shell tutorial therefore need to investigate in detail
  $PARENT_DIR/spinnaker-for-gcp/scripts/manage/push_and_apply.sh
else
  # We want the local hal config to match what was deployed.
  CI=$CI PARENT_DIR=$PARENT_DIR PROPERTIES_FILE=$PROPERTIES_FILE $PARENT_DIR/spinnaker-for-gcp/scripts/manage/pull_config.sh
  # We want a full backup stored in the bucket and the full deployment config stored in a secret.
  CI=$CI PARENT_DIR=$PARENT_DIR PROPERTIES_FILE=$PROPERTIES_FILE $PARENT_DIR/spinnaker-for-gcp/scripts/manage/push_config.sh
fi

#Function to wait for services to come up
deploy_ready() {
  printf "Waiting on $2 to come online"
  while [[ "$(kubectl get deploy $1 -n spinnaker -o \
            jsonpath="{.status.readyReplicas}")" != \
           "$(kubectl get deploy $1 -n spinnaker -o \
            jsonpath="{.status.replicas}")" ]]; do
    printf "."
    sleep 5
  done
  echo ""
}

#Wating on services to come up
deploy_ready spin-gate "API server"
deploy_ready spin-front50 "storage server"
deploy_ready spin-orca "orchestration engine"
deploy_ready spin-kayenta "canary analysis engine"
deploy_ready spin-deck "UI server"

if [ "$CI" != true ]; then
#here since we are running in cloud shell
bold "Calling CLI Scripts"
  $PARENT_DIR/spinnaker-for-gcp/scripts/cli/install_hal.sh --version $HALYARD_VERSION
  $PARENT_DIR/spinnaker-for-gcp/scripts/cli/install_spin.sh

  # We want a backup containing the newly-created ~/.spin/* files as well.
  # Not passing $CI since the guard already ensures it is not true.
  $PARENT_DIR/spinnaker-for-gcp/scripts/manage/push_config.sh  
fi

# Doesn't launch the configuration, just takes to the tutorial page where you can put in the next command to launch configuration
# If restoring a secured endpoint, leave the user on the documentation for iap configuration.
if [ "$USE_CLOUD_SHELL_HAL_CONFIG" = true -a -n "$IP_ADDR" -a "$CI" != true ]; then
  $PARENT_DIR/spinnaker-for-gcp/scripts/expose/launch_configure_iap.sh
fi

echo
bold "Installation complete."
echo
bold "Sign up for Spinnaker for GCP updates and announcements:"
bold "  https://groups.google.com/forum/#!forum/spinnaker-for-gcp-announce"
echo
