#!/usr/bin/env bash

#Calls Push and Apply configs
#Pushes the config backup to CSR
~/cloudshell_open/spinnaker-for-gcp/scripts/manage/push_config.sh || exit 1

#Runs Hal deploy apply to make the configuration changes to services
~/cloudshell_open/spinnaker-for-gcp/scripts/manage/apply_config.sh
