#!/usr/bin/env bash

bold() {
  echo ". $(tput bold)" "$*" "$(tput sgr0)";
}

pushd ~/cloudshell_open/spinnaker-for-gcp/scripts

source ./install/properties

~/cloudshell_open/spinnaker-for-gcp/scripts/manage/check_project_mismatch.sh

#This will be something like $DEPLOYMENT_NAME-oauth-client-secret which won't be there after a fresh install
EXISTING_SECRET_NAME=$(kubectl get secret -n spinnaker \
  --field-selector metadata.name=="$SECRET_NAME" \
  -o json | jq .items[0].metadata.name)

if [ $EXISTING_SECRET_NAME == 'null' ]; then
  bold "Creating Kubernetes secret $SECRET_NAME..."

  read -p 'Enter your OAuth credentials Client ID: ' CLIENT_ID
  read -p 'Enter your OAuth credentials Client secret: ' CLIENT_SECRET

#Not sure why we are creating this config file, nd getting the key for SA probably something to do with IAP config
  cat >~/.spin/config <<EOL
gate:
  endpoint: https://$DOMAIN_NAME/gate

auth:
  enabled: true
  iap:
    # check detailed config in https://cloud.google.com/iap/docs/authentication-howto#authenticating_from_a_desktop_app
    iapClientId: $CLIENT_ID
    serviceAccountKeyPath: "$HOME/.spin/key.json"
EOL
  #This is the same GKE node SA that is used to install spinnaker too
  SA_EMAIL=$(gcloud iam service-accounts --project $PROJECT_ID list \
    --filter="displayName:$SERVICE_ACCOUNT_NAME" \
    --format='value(email)')

  #Create key for SA (check if there is a way around this) 
  gcloud iam service-accounts keys create ~/.spin/key.json \
    --iam-account $SA_EMAIL \
    --project $PROJECT_ID

  #Create secret with client-id and client-secret not with the key.json file
  kubectl create secret generic $SECRET_NAME -n spinnaker --from-literal=client_id=$CLIENT_ID \
    --from-literal=client_secret=$CLIENT_SECRET
else
  bold "Using existing Kubernetes secret $SECRET_NAME..."
fi

#BackendConfig is google CRD https://cloud.google.com/kubernetes-engine/docs/how-to/ingress-features#associating_backendconfig_with_your_ingress
envsubst < expose/backend-config.yml | kubectl apply -f -

# Associate deck service with backend config.
# Annotating the service, name of the backend-config is 'config-default'
kubectl patch svc -n spinnaker spin-deck --patch \
  "[{'op': 'add', 'path': '/metadata/annotations/beta.cloud.google.com~1backend-config', \
  'value':'{\"default\": \"config-default\"}'}]" --type json

# Change spin-deck service to NodePort:
# Nodeport is required for Ingress I think to work
DECK_SERVICE_TYPE=$(kubectl get service -n spinnaker spin-deck \
  --output=jsonpath={.spec.type})

if [ $DECK_SERVICE_TYPE != 'NodePort' ]; then
  bold "Patching spin-deck service to be NodePort instead of $DECK_SERVICE_TYPE..."

  kubectl patch service -n spinnaker spin-deck --patch \
    "[{'op': 'replace', 'path': '/spec/type', \
    'value':'NodePort'}]" --type json
else
  bold "Service spin-deck is already NodePort..."
fi

# Create ingress: https://cloud.google.com/iap/docs/enabling-kubernetes-howto
bold $(envsubst < expose/deck-ingress.yml | kubectl apply -f -)

#we are sourcing this file, this file creates some env variables that are needed later
#CLIENT_ID - Client ID from above
#CLIENT_SECRET - Client Secret from above
#PROJECT_NUMBER
#BACKEND_SERVICE_ID - https://cloud.google.com/load-balancing/docs/backend-service
#Basically this backend service would have been created when we created the ingress we are now trying to fetch it
#AUD_CLAIM - URL composed of both PROJECT_NUMBER & BACKEND_SERVICE_ID
source expose/set_iap_properties.sh

gcurl() {
  curl -s -H "Authorization:Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -H "X-Goog-User-Project: $PROJECT_ID" $*
}

#Get the current policy etag
export IAP_IAM_POLICY_ETAG=$(gcurl -X POST -d "{"options":{"requested_policy_version":3}}" \
  https://iap.googleapis.com/v1beta1/projects/$PROJECT_NUMBER/iap_web/compute/services/$BACKEND_SERVICE_ID:getIamPolicy | jq .etag)

#Substitute the etag and update the policy to add roles to members who can access the endpoint
cat expose/iap_policy.json | envsubst | gcurl -X POST -d @- \
  https://iap.googleapis.com/v1beta1/projects/$PROJECT_NUMBER/iap_web/compute/services/$BACKEND_SERVICE_ID:setIamPolicy

bold "Configuring Spinnaker security settings..."

#Update these changes to hal and execute, this causes hal to reapply changes to services
cat expose/configure_hal_security.sh | envsubst | bash

#Updates the next pages in tutorial
~/cloudshell_open/spinnaker-for-gcp/scripts/manage/update_landing_page.sh

#Major work: 
~/cloudshell_open/spinnaker-for-gcp/scripts/manage/push_and_apply.sh

#This you can do at the time of creating the creds as the redirect uri is generic
bold "ACTION REQUIRED:"
bold "  - Navigate to: https://console.developers.google.com/apis/credentials/oauthclient/$CLIENT_ID?project=$PROJECT_ID"
bold "  - Add https://iap.googleapis.com/v1/oauth/clientIds/$CLIENT_ID:handleRedirect to your Web client ID as an Authorized redirect URI."

# # What about CORS?

# # Wait for services to come online again (steal logic from setup.sh):

popd
