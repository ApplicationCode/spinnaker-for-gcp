#!/usr/bin/env bash

HALYARD_POD=spin-halyard-0

# TODO(duftler): Use --wait-for-completion?
# Get into the halyard pod and run the command, we already copied all the necessary config in the previous step in push+config.sh
kubectl exec $HALYARD_POD -n halyard -- bash -c 'hal deploy apply'

#this is called again it seems, it was called once in the setup.sh, probably now with changed config
~/cloudshell_open/spinnaker-for-gcp/scripts/manage/deploy_application_manifest.sh
