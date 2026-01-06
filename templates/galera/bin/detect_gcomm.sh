#!/bin/bash

# NOTE(dciabrin) we might use downward API to populate those in the future
PODNAME=$HOSTNAME
CR=${PODNAME/-galera-[0-9]*/}

# API server config
APISERVER=https://kubernetes.default.svc
SERVICEACCOUNT=/var/run/secrets/kubernetes.io/serviceaccount
NAMESPACE=$(cat ${SERVICEACCOUNT}/namespace)
TOKEN=$(cat ${SERVICEACCOUNT}/token)
CACERT=${SERVICEACCOUNT}/ca.crt

# OSPRH-17604: use default timeout and retry parameters for fast failover
# default parameters for curl calls to the API server
: ${WSREP_NOTIFY_CURL_CONNECT_TIMEOUT:=5}
: ${WSREP_NOTIFY_CURL_MAX_TIME:=30}
CURL="curl --connect-timeout ${WSREP_NOTIFY_CURL_CONNECT_TIMEOUT} --max-time ${WSREP_NOTIFY_CURL_MAX_TIME}"
# defaults parameters for retry on error
: ${WSREP_NOTIFY_RETRIES:=30}
: ${WSREP_NOTIFY_RETRY_WAIT:=1}


##
## Utilities functions
##
## NOTE: mysql diverts this script's stdout, but stderr is logged to the
## configured log-error file (e.g. /var/log/mariadb/mariadb.log)
function log() {
    echo "$(date +%F_%H_%M_%S) `basename $0` $*" >&2
}

function log_error() {
    echo "$(date +%F_%H_%M_%S) `basename $0` ERROR: $*" >&2
}

# retrieve data from a JSON structure
# (parse JSON with python3 as we don't have jq in the container image)
function parse_output {
    local key=$1
    python3 -c 'import json,sys;s=json.load(sys.stdin);print(s'${key}')'
    [ $? == 0 ] || log_error "Could not parse json endpoint (rc=$?)"
}


# REST API call to the k8s API server
function api_server {
    local request=$1
    local resource=$2
    # NOTE: a PUT request to the API server is basically a conditional write,
    # it only succeeds if no other write have been done on the CR in the mean time,
    # (i.e. if the timestamp of the JSON that is being sent to the API server matches
    # the timestamp of the service CR in the cluster)
    if [ "$request" = "PUT" ]; then
        request="$request -d @-"
    fi
    local output
    output=$(${CURL} -s --cacert ${CACERT} --header "Content-Type:application/json" --header "Authorization: Bearer ${TOKEN}" --request $request $resource)

    local rc=$?
    if [ $rc != 0 ]; then
        log_error "call to API server failed for resource `basename ${resource}` (rc=$rc)"
        return 1
    fi
    if echo "${output}" | grep -q '"status": "Failure"'; then
        message=$(echo "${output}" | parse_output '["message"]')
        code=$(echo "${output}" | parse_output '["code"]')
        if [ "${code}" = 401 ]; then
            # Unauthorized means the token is no longer valid as the galera
            # resource is in the process of being deleted.
            return 2
        fi
        log_error "API server returned an error for resource `basename ${resource}`: ${message} (code=${code})"
        return 1
    fi
    echo "${output}"
    return 0
}

# Generic retry logic for an action function
function retry {
    local action=$1
    local retries=$WSREP_NOTIFY_RETRIES
    local wait=$WSREP_NOTIFY_RETRY_WAIT
    local rc=1

    $action
    rc=$?
    while [ $rc -ne 0 -a $retries -gt 0 ]; do
        # if API call are unauthorized, the resource is being deleted
        # exit now as there is nothing more to do
        if [ $rc -eq 2 ]; then
            log "galera resource is being deleted, exit now."
            return 0
        fi
        log_error "previous action failed, retrying."
        sleep $wait
        $action
        rc=$?
        retries=$((retries - 1))
    done
    if [ $rc -ne 0 ]; then
        log_error "Could not run action after ${WSREP_NOTIFY_RETRIES} tries. Stop retrying."
    fi
    return $rc
}


## Change the Active endpoint from the service
function save_extracted_state {
    local galera_cr
    galera_cr=$(curl -s --cacert ${CACERT} --header "Content-Type:application/json" --header "Authorization: Bearer ${TOKEN}" --request GET ${APISERVER}/apis/mariadb.openstack.org/v1beta1/namespaces/${NAMESPACE}/galeras/${CR}/status)

    local new_galera_cr
    new_galera_cr=$(echo "$galera_cr" | python3 -c "import json, sys; g=json.load(sys.stdin); detected=json.loads('${detected}'); attr=g['status'].get('attributes',{}); attr['${PODNAME}']=detected;g['status']['attributes']=attr;print(json.dumps(g,indent=2))")

    local result
    local rc
    result=$(echo "$new_galera_cr" | api_server PUT "${APISERVER}/apis/mariadb.openstack.org/v1beta1/namespaces/${NAMESPACE}/galeras/${CR}/status")
    rc=$?
    echo $rc
    [ $rc == 0 ]
}

log "Retrieving the current container ID"
while [ "$container_id" = "" ]; do
    pod=$(api_server GET "${APISERVER}/api/v1/namespaces/openstack/pods/${PODNAME}")
    container_id=$(echo "$pod" | python3 -c "import json, sys; g=json.load(sys.stdin); print(g['status']['containerStatuses'][0]['containerID'])")
    if [ "$container_id" = "" ]; then
        sleep 2
        echo "retry"
    fi
done

log "Extracting the Galera state from the local mariadb database on ${PODNAME}"
seqno_data=$(bash /var/lib/operator-scripts/detect_last_commit.sh)
detected=$(echo "${seqno_data}{\"containerID\":\"${container_id}\"}" | sed 's/}{/,/g')

log "Saving the extracted Galera state into the status of Galera CR ${CR} - ${detected}"
retry "save_extracted_state"
echo $?

# container_id=$(curl -s --cacert ${CACERT} --header "Content-Type:application/json" --header "Authorization: Bearer ${TOKEN}" --request GET ${APISERVER}/api/v1/namespaces/openstack/pods/${PODNAME} | grep containerID | tail -1 | awk -F'"' '{printf "{\"containerID\":\"%s\"}\n",$4}')
