#!/usr/bin/env bash

bold() {
  echo ". $(tput bold)" "$*" "$(tput sgr0)";
}

#Push scripts dir to top of stack
pushd ~/cloudshell_open/spinnaker-for-gcp/scripts

#Get all properties
source ./install/properties

~/cloudshell_open/spinnaker-for-gcp/scripts/manage/check_project_mismatch.sh

#Calculate domain length
DOMAIN_NAME_LENGTH=$(echo -n $DOMAIN_NAME | wc -m)

#Check for length to be less than 63 characters, not sure why
if [ "$DOMAIN_NAME_LENGTH" -gt "63" ]; then
  echo "Domain name $DOMAIN_NAME is greater than 63 characters. Please specify a \
domain name not longer than 63 characters. The domain name is specified in the \
$HOME/cloudshell_open/spinnaker-for-gcp/scripts/install/properties file."
  exit 1
fi

#See if IP is already there
export IP_ADDR=$(gcloud compute addresses list --filter="name=$STATIC_IP_NAME" \
  --format="value(address)" --global --project $PROJECT_ID)

#If not then create IP
if [ -z "$IP_ADDR" ]; then
  bold "Creating static IP address $STATIC_IP_NAME..."

  gcloud compute addresses create $STATIC_IP_NAME --global --project $PROJECT_ID

  export IP_ADDR=$(gcloud compute addresses list --filter="name=$STATIC_IP_NAME" \
    --format="value(address)" --global --project $PROJECT_ID)
else
   bold "Using existing static IP address $STATIC_IP_NAME ($IP_ADDR)..."
fi

#Check that we are using the default domain and not some pre-owned/custom one
#Looks like we only create cloud endpoint for default domain and not the custom one
if [ $DOMAIN_NAME = "$DEPLOYMENT_NAME.endpoints.$PROJECT_ID.cloud.goog" ]; then
  EXISTING_SERVICE_NAME=$(gcloud endpoints services list \
    --filter="serviceName=$DOMAIN_NAME" --format="value(serviceName)" \
    --project $PROJECT_ID)

  if [ -z "$EXISTING_SERVICE_NAME" ]; then
    #This token is of the user - owner of the project
    gcurl() {
      curl -s -H "Authorization:Bearer $(gcloud auth print-access-token)" \
        -H "Content-Type: application/json" -H "Accept: application/json" \
        -H "X-Goog-User-Project: $PROJECT_ID" $*
    }

    bold "Creating service $DOMAIN_NAME..."

    #there's not gcloud command you need to make an api call to create the endpoint service
    gcurl -X POST -d \
      "{\"serviceName\":\"$DOMAIN_NAME\",\"producerProjectId\":\"$PROJECT_ID\"}" \
      https://servicemanagement.googleapis.com/v1/services/

    while [ -z "$SERVICE_NAME" ]; do
      SERVICE_NAME=$(gcloud endpoints services list \
        --filter="serviceName:$DOMAIN_NAME" \
        --format="value(serviceName)")
      sleep 5
     echo -n .
    done
    echo
  else
    bold "Using existing service $EXISTING_SERVICE_NAME..."
  fi

  # The service can exist without an endpoint configuration. The presence of the
  # service configuration title is sufficient to indicate that we have configured
  # the endpoint.
  EXISTING_SERVICE_CONFIGURATION_NAME=$(gcloud endpoints services list \
    --filter="serviceName=$DOMAIN_NAME" --format="value(serviceConfig.title)" \
    --project $PROJECT_ID)
  
  #
  if [ -z "$EXISTING_SERVICE_CONFIGURATION_NAME" ]; then
    bold "Deploying service endpoint configuration for $DOMAIN_NAME..."

    cat expose/openapi.yml | envsubst > expose/openapi_expanded.yml
    
    #Deploy end-point service for default domain, here we just need the openapi/ swagger file
    gcloud endpoints services deploy expose/openapi_expanded.yml --project $PROJECT_ID
  else
    bold "Using existing service endpoint configuration for $DOMAIN_NAME..."
  fi
else
  #This is the case when the domain is a custom/ owned one
  #Check which IP address is it resolving to
  CURRENT_IP_ADDR=$(dig +short $DOMAIN_NAME)

  if [ -z "$CURRENT_IP_ADDR" ]; then
    CURRENT_IP_ADDR="UNRESOLVABLE"
  fi

  bold "Using existing domain $DOMAIN_NAME ($CURRENT_IP_ADDR)..."

  #If the domain resolved to an IP different from one in gcp, implies domain should resolve to an IP in GCP only
  #For this to work, thus cloud DNS is a good place to keep this config
  if [ $CURRENT_IP_ADDR != $IP_ADDR ]; then
    bold "** This domain currently resolves to $CURRENT_IP_ADDR
   ** You must configure $DOMAIN_NAME's DNS settings such that it instead resolves to $IP_ADDR"
  fi
fi

EXISTING_MANAGED_CERT=$(gcloud beta compute ssl-certificates list \
  --filter="name=$MANAGED_CERT" --format="value(name)" --project $PROJECT_ID)

if [ -z "$EXISTING_MANAGED_CERT" ]; then
  bold "Creating managed SSL certificate $MANAGED_CERT for domain $DOMAIN_NAME..."

  #Create a google managed cert for the domain, since its a google service we can use google managed cert and be free 
  gcloud beta compute ssl-certificates create $MANAGED_CERT --domains $DOMAIN_NAME --global \
    --project $PROJECT_ID
else
  bold "Using existing managed SSL certificate $EXISTING_MANAGED_CERT..."
fi

#Launches the tutorial for cinfiguring IAP
./expose/launch_configure_iap.sh

#Pop out the dir
popd
