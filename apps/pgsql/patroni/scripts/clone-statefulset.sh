#!/bin/bash
set -Eeu
set -o pipefail

function waitUntilAllReady(){
  local NAME="$1"
  local IS_READY=0
  echo "Waiting for ${NAME} to become ready";
  while [ $IS_READY -eq 0 ]; do
      sleep 2
      oc -n $NAMESPACE get "${NAME}" -o 'custom-columns=DESIRED:.spec.replicas,READY:.status.readyReplicas' --no-headers | awk '{if ($1 == $2) exit 0; else exit 1 }'  && IS_READY=1 || true
  done
}

NAMESPACE="$1"
SOURCE_STATEFULSET="$2"
TARGET_STATEFULSET="${3:-${SOURCE_STATEFULSET}-x}"

oc -n "$NAMESPACE" get "statefulset/${SOURCE_STATEFULSET}" --export -o json | jq '.metadata.name = (.metadata.name + "-x") | .spec.selector.matchLabels."statefulset" = .metadata.name | .spec.template.metadata.labels."statefulset" = .metadata.name | ( .spec.volumeClaimTemplates[] | .metadata.name) |= "postgresql" | ( .spec.template.spec.volumes[] | .persistentVolumeClaim.claimName) |= "postgresql" | .spec.replicas = 1 | del (.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",.metadata.selfLink)' | oc -n "$NAMESPACE" create -f - --save-config=true
waitUntilAllReady "statefulset/${TARGET_STATEFULSET}"
# SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate = false;

echo "oc delete statefulset/${TARGET_STATEFULSET} --wait && oc delete pvc -l statefulset=${TARGET_STATEFULSET} --wait"
