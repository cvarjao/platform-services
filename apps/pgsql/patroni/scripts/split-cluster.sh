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

function waitPatroniClusterMemberIsUp(){
  local pod=$1
  local IS_UP=0
  echo "Waiting for ${pod} member to fully come up";
  while [ $IS_UP -eq 0 ]; do
      sleep 2
      #set -x
      oc -n $NAMESPACE rsh "${pod}" patronictl list -f json 2>/dev/null | jq -ecM ".[] | select (.Member == \"$pod\" and .\"Lag in MB\" == 0 and .State == \"running\")" >/dev/null && IS_UP=1 || true
      #{ set +x; } 2>/dev/null
  done
}

function waitReplicasEqualZero(){
  local statefulset=$1
  local IS_DOWN=0
  echo "Waiting for ${statefulset} to be down";
  while [ $IS_DOWN -eq 0 ]; do
      sleep 2
      oc -n $NAMESPACE get "statefulset/${statefulset}" -o custom-columns=replicas:.status.replicas --no-headers | awk '{if($1 == 0) exit 0; else exit 1; end}' && IS_DOWN=1 || true
  done
}

NAMESPACE="$1"
# The cluster we want to join
SOURCE_STATEFULSET="$2"

# The statefulset to join the cluster
TARGET_STATEFULSET="${3:-${SOURCE_STATEFULSET}-x}"


#SOURCE_TEMPLATE=$(oc -n $NAMESPACE get statefulset/$SOURCE_STATEFULSET -o json | jq -cM '.spec.template.spec.containers[0]')
#PATRONI_SCOPE=$(jq -rM '.env[] | select(.name == "PATRONI_SCOPE") | .value' <<< "$SOURCE_TEMPLATE")


# backup configuration
[ ! -f "${TARGET_STATEFULSET}.original.json" ] && oc -n $NAMESPACE get "statefulset/$TARGET_STATEFULSET" --export -o json > "${TARGET_STATEFULSET}.original.json"

# scale down 0
oc -n $NAMESPACE scale --replicas 0 "statefulset/$TARGET_STATEFULSET"
waitReplicasEqualZero "${TARGET_STATEFULSET}"

# retrieve original/target cluster name (a.k.a scope)
ORIGINAL_PATRONI_SCOPE=$(jq -rM '.metadata.labels."cluster-name"' "${TARGET_STATEFULSET}.original.json")
ORIGINAL_PATRONI_KUBERNETES_LABELS=$(jq -rM '.spec.template.spec.containers[0].env[] | select(.name == "PATRONI_KUBERNETES_LABELS") | .value' "${TARGET_STATEFULSET}.original.json")

# Update the service so that apps using it will be routed to the right pods in the newly joined cluster
oc -n $NAMESPACE patch "$(oc -n $NAMESPACE get service -l "cluster-name=${ORIGINAL_PATRONI_SCOPE}" -o name)" -p "{\"spec\":{\"selector\":{\"cluster-name\":\"${ORIGINAL_PATRONI_SCOPE}\"}}}"

# Remove existing leader lock
oc -n $NAMESPACE delete "ConfigMap/${ORIGINAL_PATRONI_SCOPE}-leader" --ignore-not-found=true

#//delete sso-pgsql-dev-9-leader
# ** DO NOT ** remove PVCs

# Update Environment Variables
oc -n $NAMESPACE set env --overwrite=true "statefulset/$TARGET_STATEFULSET" \
"PATRONI_SCOPE=${ORIGINAL_PATRONI_SCOPE}" \
"PATRONI_KUBERNETES_LABELS=${ORIGINAL_PATRONI_KUBERNETES_LABELS}"


# Update .spec.template.metadata.labels
ORIGINAL_TEMPLATE=$(<"${TARGET_STATEFULSET}.original.json")
oc -n $NAMESPACE patch "statefulset/$TARGET_STATEFULSET" -p "{\"spec\": {\"template\":{\"metadata\":{\"labels\":{\"cluster-name\":\"${ORIGINAL_PATRONI_SCOPE}\"}}}}}"

# Copy cluster initialization ID, so that it doesn't accidently start a new cluster
# oc -n $NAMESPACE annotate --overwrite "configmap/${TARGET_STATEFULSET}-config" "initialize=$(oc -n $NAMESPACE get "configmap/${PATRONI_SCOPE}-config" -o 'custom-columns=initialize:.metadata.annotations.initialize' --no-headers)"

# Bring cluster up
oc -n $NAMESPACE scale --replicas "$(jq -rM '.spec.replicas' "${TARGET_STATEFULSET}.original.json")" "statefulset/$TARGET_STATEFULSET"
waitPatroniClusterMemberIsUp "${TARGET_STATEFULSET}-0"



#oc patch -n devops-sso-dev service/sso-pgsql-master-dev-9 -p "{\"spec\":{\"selector\":{\"cluster-name\":\"sso-pgsql-dev-0\"}}}"

#service/sso-pgsql-master-dev-9

#oc -n devops-sso-dev get pods -l deploymentconfig=sso-dev-9 -o name | xargs -I {} oc -n devops-sso-dev rsh '{}'  /opt/eap/bin/jboss-cli.sh -c --command='/subsystem=datasources/xa-data-source=db_postgresql-DB:flush-all-connection-in-pool'
