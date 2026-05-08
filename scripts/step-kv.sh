#!/bin/bash

KV_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WRANGLER_TOML="$PROJECT_DIR/wrangler.toml"
LOG_FILE="$SCRIPT_DIR/step-kv.log"
BACKUP_DIR="$SCRIPT_DIR/backups"
MAX_RETRIES=3
RETRY_DELAY=2

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg" >&2
}

info() {
    local msg="$1"
    echo -e "\033[36m$msg\033[0m" >&2
    log "$msg"
}

success() {
    local msg="$1"
    echo -e "\033[32m$msg\033[0m" >&2
    log "$msg"
}

warn() {
    local msg="WARN: $1"
    echo -e "\033[33m$msg\033[0m" >&2
    log "$msg"
}

error() {
    local msg="ERROR: $1"
    echo -e "\033[31m$msg\033[0m" >&2
    log "$msg"
    exit 1
}

initialize_backup_dir() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        log "Created backup directory: $BACKUP_DIR"
    fi
}

backup_config_file() {
    local file_path="$1"
    initialize_backup_dir

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="wrangler_${timestamp}.toml"
    local backup_path="$BACKUP_DIR/$backup_file"

    if cp "$file_path" "$backup_path"; then
        log "Backup created: $backup_path"
        echo "$backup_path"
    else
        error "Failed to create backup, aborting to prevent config corruption"
    fi
}

retry_operation() {
    local operation_name="$1"
    local max_retries="${2:-$MAX_RETRIES}"
    local delay="${3:-$RETRY_DELAY}"
    shift 3
    local func="$@"

    local attempt=1
    local last_error=""

    while [ $attempt -le $max_retries ]; do
        log "Attempt $attempt/$max_retries for: $operation_name"

        if eval "$func"; then
            return 0
        fi

        last_error=$?
        warn "Attempt $attempt failed with exit code: $last_error"

        if [ $attempt -lt $max_retries ]; then
            log "Retrying in $delay seconds..."
            sleep $delay
            delay=$((delay * 2))
        fi

        attempt=$((attempt + 1))
    done

    error "$operation_name failed after $max_retries attempts. Last error code: $last_error"
}

test_input_parameter() {
    log "Validating input parameter: KV_NAME"

    if [ -z "$KV_NAME" ]; then
        error "KV name parameter is required but was not provided"
    fi

    if [[ ! "$KV_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "Invalid KV name format. Only alphanumeric characters, underscores, and hyphens are allowed. Provided KV name: $KV_NAME"
    fi

    success "Input parameter validation passed: $KV_NAME"
}

test_wrangler_toml_exists() {
    if [ ! -f "$WRANGLER_TOML" ]; then
        error "wrangler.toml not found at: $WRANGLER_TOML"
    fi
    log "wrangler.toml found at: $WRANGLER_TOML"
}

get_current_kv_id() {
    if [ ! -f "$WRANGLER_TOML" ]; then
        return 1
    fi

    local kv_id
    kv_id=$(awk '
        /^\[\[kv_namespaces\]\]$/ { in_kv=1; next }
        in_kv && /^[[:space:]]*id[[:space:]]*=/ {
            match($0, /"[^"]+"/)
            print substr($0, RSTART+1, RLENGTH-2)
            exit
        }
        /^\[/ { in_kv=0 }
    ' "$WRANGLER_TOML")

    if [ -n "$kv_id" ]; then
        echo "$kv_id"
        return 0
    fi
    return 1
}

get_existing_kv_id() {
    local name="$1"
    local attempt=1
    local delay=$RETRY_DELAY

    while [ $attempt -le $MAX_RETRIES ]; do
        log "Attempt $attempt/$MAX_RETRIES for: Query KV namespace"

        local output
        if output=$(npx wrangler kv namespace list 2>&1); then
            if [ -z "$output" ]; then
                log "Empty response from wrangler kv namespace list"
            else
                if echo "$output" | grep -q "\"title\": \"$name\""; then
                    local kv_id
                    kv_id=$(echo "$output" | grep -oP "\"title\": \"$name\".*?\"id\":\s*\"\K[^\"]+" | head -1)

                    if [ -z "$kv_id" ]; then
                        kv_id=$(echo "$output" | python3 -c "import sys, json; data=json.load(sys.stdin); print(next((item['id'] for item in data if item.get('title')=='$name'), ''))" 2>/dev/null)
                    fi

                    if [ -n "$kv_id" ]; then
                        log "Found existing KV: $name with ID: $kv_id"
                        echo "$kv_id"
                        return 0
                    fi
                fi

                log "KV namespace '$name' does not exist"
                return 1
            fi
        else
            warn "Attempt $attempt failed: $output"
        fi

        if [ $attempt -lt $MAX_RETRIES ]; then
            log "Retrying in $delay seconds..."
            sleep $delay
            delay=$((delay * 2))
        fi

        attempt=$((attempt + 1))
    done

    log "Failed to query KV namespace after $MAX_RETRIES attempts"
    return 1
}

create_kv() {
    local name="$1"
    local attempt=1
    local delay=$RETRY_DELAY

    while [ $attempt -le $MAX_RETRIES ]; do
        log "Attempt $attempt/$MAX_RETRIES for: Create KV namespace"

        local output
        if output=$(npx wrangler kv namespace create "$name" 2>&1); then
            log "Wrangler output: $output"

            if echo "$output" | grep -qE "Error|error|ERROR"; then
                warn "KV creation returned error: $output"
            else
                local kv_id
                kv_id=$(echo "$output" | grep -oP 'id = "\K[^"]+' | head -1)

                if [ -n "$kv_id" ]; then
                    success "KV created successfully with ID: $kv_id"
                    echo "$kv_id"
                    return 0
                fi

                warn "Failed to extract KV ID from output"
            fi
        else
            warn "Attempt $attempt failed: $output"
        fi

        if [ $attempt -lt $MAX_RETRIES ]; then
            log "Retrying in $delay seconds..."
            sleep $delay
            delay=$((delay * 2))
        fi

        attempt=$((attempt + 1))
    done

    error "Failed to create KV namespace after $MAX_RETRIES attempts"
}

update_wrangler_toml() {
    local kv_id="$1"
    log "Updating wrangler.toml with KV ID: $kv_id"

    local backup_path
    backup_path=$(backup_config_file "$WRANGLER_TOML")

    # 转换 CRLF 为 LF，确保跨平台兼容
    sed -i 's/\r$//' "$WRANGLER_TOML"

    # 找到 [[kv_namespaces]] 块后的第一行 id= 替换
    awk -v new_id="$kv_id" '
        /^\[\[kv_namespaces\]\]/ { in_kv=1; print; next }
        in_kv && /^[[:space:]]*id[[:space:]]*=/ {
            sub(/"[^"]*"/, "\"" new_id "\"")
            in_kv=0
        }
        { print }
    ' "$WRANGLER_TOML" > "$WRANGLER_TOML.tmp" && mv "$WRANGLER_TOML.tmp" "$WRANGLER_TOML"

    success "wrangler.toml updated successfully"
    return 0
}

test_config_update() {
    local expected_kv_id="$1"
    log "Verifying config update..."

    if [ ! -f "$WRANGLER_TOML" ]; then
        error "Config verification failed - wrangler.toml not found"
    fi

    local actual_id
    actual_id=$(awk '
        /^\[\[kv_namespaces\]\]/ { in_kv=1; next }
        in_kv && /^[[:space:]]*id[[:space:]]*=/ {
            match($0, /"[^"]+"/)
            print substr($0, RSTART+1, RLENGTH-2)
            exit
        }
    ' "$WRANGLER_TOML")

    if [ -z "$actual_id" ]; then
        error "Config verification failed - No KV ID found in config"
    fi

    if [ "$actual_id" = "$expected_kv_id" ]; then
        success "Config verification passed - KV ID correctly written: $actual_id"
        return 0
    else
        error "Config verification failed - Expected: $expected_kv_id, Found: $actual_id"
    fi
}

find_documentation_files() {
    local doc_extensions=("md" "txt" "json" "yaml" "yml")
    local exclude_dirs=("node_modules" ".git" "dist" "build" "coverage" "scripts" "backups")
    local find_exclude=""

    for dir in "${exclude_dirs[@]}"; do
        find_exclude="$find_exclude -not -path */$dir/*"
    done

    local docs=()
    for ext in "${doc_extensions[@]}"; do
        while IFS= read -r -d '' file; do
            docs+=("$file")
        done < <(find "$PROJECT_DIR" -maxdepth 3 -type f -name "*.$ext" $find_exclude -print0 2>/dev/null)
    done

    printf '%s\n' "${docs[@]}"
}

update_documentation_kv_id() {
    local old_kv_id="$1"
    local new_kv_id="$2"
    local kv_name="$3"

    if [ -z "$old_kv_id" ]; then
        log "No old KV ID provided, skipping documentation update"
        return
    fi

    log "Checking documentation files for KV ID updates..."

    local docs
    mapfile -t docs < <(find_documentation_files)
    local updated_count=0

    for doc in "${docs[@]}"; do
        if [ -f "$doc" ] && grep -q "$old_kv_id" "$doc" 2>/dev/null; then
            local tmp_file="$doc.tmp"
            while IFS= read -r line || [ -n "$line" ]; do
                echo "${line//$old_kv_id/$new_kv_id}"
            done < "$doc" > "$tmp_file" && mv "$tmp_file" "$doc"
            log "Updated KV ID in: $doc"
            ((updated_count++)) || true
        fi
    done

    if [ "$updated_count" -gt 0 ]; then
        success "Updated $updated_count documentation file(s)"
    else
        log "No documentation files needed updating"
    fi
}

main() {
    echo ""
    info "========== KV Namespace Management =========="
    log "Starting KV namespace management for: $KV_NAME"
    echo ""

    test_input_parameter
    test_wrangler_toml_exists

    local current_kv_id
    current_kv_id=$(get_current_kv_id) || current_kv_id=""
    if [ -n "$current_kv_id" ]; then
        log "Current KV ID in wrangler.toml: $current_kv_id"
    fi

    cd "$PROJECT_DIR"

    log "Step 1: Query KV namespace status..."
    local existing_kv_id
    existing_kv_id=$(get_existing_kv_id "$KV_NAME") || existing_kv_id=""

    local kv_id_to_use=""
    local is_new_kv=false

    if [ -n "$existing_kv_id" ]; then
        info "KV namespace '$KV_NAME' already exists with ID: $existing_kv_id"
        kv_id_to_use="$existing_kv_id"

        if [ "$existing_kv_id" = "$current_kv_id" ]; then
            info "Current wrangler.toml already uses this KV ID, no update needed"
            success "========== SUCCESS =========="
            success "Using existing KV namespace: $KV_NAME"
            success "KV ID: $kv_id_to_use"
            success "wrangler.toml: Already up to date"
            echo ""
            info "Next: npm run deploy"
            log "Done"
            return
        else
            info "Updating wrangler.toml to use existing KV ID..."
            if ! update_wrangler_toml "$kv_id_to_use"; then
                error "Failed to update wrangler.toml"
            fi
            if [ -n "$current_kv_id" ]; then
                update_documentation_kv_id "$current_kv_id" "$kv_id_to_use" "$KV_NAME"
            fi
        fi
    else
        log "Step 2: Creating new KV namespace..."
        kv_id_to_use=$(create_kv "$KV_NAME")

        if [ -z "$kv_id_to_use" ]; then
            error "Failed to create KV namespace"
        fi

        is_new_kv=true

        log "Step 3: Updating wrangler.toml..."
        if ! update_wrangler_toml "$kv_id_to_use"; then
            error "Failed to update wrangler.toml"
        fi

        if [ -n "$current_kv_id" ]; then
            update_documentation_kv_id "$current_kv_id" "$kv_id_to_use" "$KV_NAME"
        fi
    fi

    log "Step 4: Verifying configuration update..."
    if ! test_config_update "$kv_id_to_use"; then
        error "Configuration verification failed, please check the config file manually"
    fi

    echo ""
    success "========== SUCCESS =========="
    if [ "$is_new_kv" = true ]; then
        success "New KV namespace created: $KV_NAME"
    else
        success "Using existing KV namespace: $KV_NAME"
    fi
    success "KV ID: $kv_id_to_use"
    success "wrangler.toml: Updated and verified"
    echo ""
    info "Next: npm run deploy"
    log "Done - All steps completed successfully"
}

main "$@"