#!/bin/bash
# ContainerNetwork AutoFix (CNAF)
# Automatically recreates dependent containers when master container restarts
# https://github.com/buxxdev/containernetwork-autofix

# ============ ENVIRONMENT VARIABLES (with defaults) ============
MASTER_CONTAINER="${MASTER_CONTAINER:-GluetunVPN}"
RESTART_WAIT_TIME="${RESTART_WAIT_TIME:-15}"
LOG_FILE="${LOG_FILE:-/var/log/containernetwork-autofix.log}"
MAX_LOG_LINES="${MAX_LOG_LINES:-1000}"
MAX_RETRIES="${MAX_RETRIES:-10}"
RETRY_DELAY="${RETRY_DELAY:-10}"
# ================================================================

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" | tee -a ${LOG_FILE}
}

rotate_log() {
    if [ -f "${LOG_FILE}" ]; then
        local lines=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)
        if [ $lines -gt ${MAX_LOG_LINES} ]; then
            tail -n ${MAX_LOG_LINES} "${LOG_FILE}" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "${LOG_FILE}"
        fi
    fi
}

get_container_id() {
    docker inspect $1 --format "{{.Id}}" 2>/dev/null
}

get_dependent_containers() {
    local master_id=$1
    local dependents=()
    
    for container in $(docker ps -a --format "{{.Names}}"); do
        if [ "$container" != "$MASTER_CONTAINER" ]; then
            network_mode=$(docker inspect $container --format "{{.HostConfig.NetworkMode}}" 2>/dev/null)
            if [[ $network_mode == container:$master_id* ]]; then
                dependents+=("$container")
            fi
        fi
    done
    
    echo "${dependents[@]}"
}

log_message "ContainerNetwork AutoFix (CNAF) starting..."
log_message "Master Container: ${MASTER_CONTAINER}"
log_message "Restart Wait Time: ${RESTART_WAIT_TIME}s"
log_message "Max Retries: ${MAX_RETRIES}"
rotate_log

# Wait for master container to be ready with retry logic
RETRY_COUNT=0
log_message "Waiting for ${MASTER_CONTAINER} to be ready..."

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    CURRENT_MASTER_ID=$(get_container_id ${MASTER_CONTAINER})
    
    if [ -n "$CURRENT_MASTER_ID" ]; then
        log_message "✓ ${MASTER_CONTAINER} found! ID: ${CURRENT_MASTER_ID:0:12}..."
        break
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    log_message "Waiting for ${MASTER_CONTAINER}... (attempt ${RETRY_COUNT}/${MAX_RETRIES})"
    sleep ${RETRY_DELAY}
done

if [ -z "$CURRENT_MASTER_ID" ]; then
    log_message "✗ ERROR: ${MASTER_CONTAINER} not found after ${MAX_RETRIES} attempts. Exiting."
    exit 1
fi

# Find initial dependent containers
INITIAL_DEPENDENTS=$(get_dependent_containers ${CURRENT_MASTER_ID})
if [ -n "$INITIAL_DEPENDENTS" ]; then
    log_message "Found dependent containers: ${INITIAL_DEPENDENTS}"
else
    log_message "No dependent containers found (yet)"
fi

docker events --filter "container=${MASTER_CONTAINER}" --filter 'event=start' | while read event
do
    log_message "${MASTER_CONTAINER} restarted, waiting ${RESTART_WAIT_TIME} seconds for VPN to establish..."
    sleep ${RESTART_WAIT_TIME}
    
    NEW_MASTER_ID=$(get_container_id ${MASTER_CONTAINER})
    log_message "New ${MASTER_CONTAINER} ID: ${NEW_MASTER_ID:0:12}..."
    
    BROKEN_CONTAINERS=$(get_dependent_containers ${CURRENT_MASTER_ID})
    
    if [ -z "$BROKEN_CONTAINERS" ]; then
        log_message "No broken containers found. All dependent containers may have auto-reconnected."
    else
        log_message "Found broken containers: ${BROKEN_CONTAINERS}"
        
        for CONTAINER in ${BROKEN_CONTAINERS}; do
            log_message "Processing ${CONTAINER}..."
            
            CONTAINER_STATE=$(docker inspect ${CONTAINER} --format "{{.State.Status}}" 2>/dev/null)
            WAS_RUNNING=false
            if [ "$CONTAINER_STATE" == "running" ]; then
                WAS_RUNNING=true
                log_message "${CONTAINER} was running, will restart after rebuild"
            else
                log_message "${CONTAINER} was stopped, will remain stopped after rebuild"
            fi
            
            docker stop ${CONTAINER} 2>/dev/null
            docker rm ${CONTAINER} 2>/dev/null
            
            TEMPLATE="/templates/my-${CONTAINER}.xml"
            
            if [ -f "${TEMPLATE}" ]; then
                log_message "Recreating ${CONTAINER} from template..."
                
                /scripts/rebuild_container ${CONTAINER}
                
                if [ $? -eq 0 ]; then
                    log_message "✓ ${CONTAINER} recreated successfully!"
                    
                    if [ "$WAS_RUNNING" = false ]; then
                        docker stop ${CONTAINER} 2>/dev/null
                        log_message "${CONTAINER} stopped (preserving original state)"
                    fi
                else
                    log_message "✗ ERROR: Failed to recreate ${CONTAINER}"
                fi
            else
                log_message "✗ ERROR: Template not found: ${TEMPLATE}"
            fi
        done
    fi
    
    CURRENT_MASTER_ID=${NEW_MASTER_ID}
    log_message "All dependent containers processed."
    rotate_log
done
