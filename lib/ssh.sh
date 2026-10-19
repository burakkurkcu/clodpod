# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # globals set/used by config.sh and other modules
# SSH key management and guest home provisioning

ensure_ssh_key() {
    SSH_KEY_CREATED=false
    if [[ ! -f "$SSH_KEYFILE_PRIV" ]] || [[ ! -f "$SSH_KEYFILE_PUB" ]]; then
        # shellcheck disable=SC2174 # When used with -p, -m only applies to the deepest directory. # Yup, that's fine
        mkdir -m 700 -p "$SSH_DIR"
        ssh-keygen -t ed25519 \
            -f "$SSH_KEYFILE_PRIV" \
            -N "" \
            -q \
            -C "clodpod-${USER}@${HOSTNAME}"
        SSH_KEY_CREATED=true
        # Sync new key to all existing named VMs
        sync_ssh_key_to_all_instances
    fi
}

# Write the new public key into every clodpod VM (instances, bases, and the
# OS layer they are cloned from). The old key is gone, so SSH can't be used:
# running VMs are stopped and the key is written to their disks offline.
sync_ssh_key_to_all_instances() {
    local vm_names
    vm_names="$(clodvm list --quiet | grep '^clodpod-')" || true

    [[ -n "$vm_names" ]] || return 0

    local vm
    while IFS= read -r vm; do
        stop_vm "$vm"
        debug "Syncing SSH key to $vm..."
        vm_inject_key "$vm" || warn "SSH key sync failed for $vm — skipping"
    done <<< "$vm_names"
}

refresh_guest_home() {
    debug "Syncing guest directory..."
    local guest_dir="$DATA_DIR/guest"
    mkdir -p "$guest_dir"
    /usr/bin/rsync -a --delete --exclude '.gitconfig' --exclude '.ssh/' "$WORKSPACE/guest/" "$guest_dir/"

    debug "Configuring credentials..."
    local git_user_name
    local git_user_email
    git_user_name="$(git config --global --get user.name 2>/dev/null || echo "")"
    git_user_email="$(git config --global --get user.email 2>/dev/null || echo "")"
    git config -f "$guest_dir/home/.gitconfig" user.name "$git_user_name"
    git config -f "$guest_dir/home/.gitconfig" user.email "$git_user_email"

    local guest_authorized_keys="$guest_dir/home/.ssh/authorized_keys"
    # shellcheck disable=SC2174 # When used with -p, -m only applies to the deepest directory. # Yup, that's fine
    mkdir -m 700 -p "$(dirname "$guest_authorized_keys")"
    cp "$SSH_KEYFILE_PUB" "$guest_authorized_keys"
    chmod 600 "$guest_authorized_keys"

    local guest_known_hosts="$guest_dir/home/.ssh/known_hosts"
    # shellcheck disable=SC2174 # When used with -p, -m only applies to the deepest directory. # Yup, that's fine
    mkdir -m 700 -p "$(dirname "$guest_known_hosts")"
    ssh-keyscan github.com > "$guest_known_hosts"
    chmod 600 "$guest_known_hosts"

    touch "$guest_dir/.populated"
}

# Idempotent guard: refresh guest home only if it has not been fully populated.
ensure_guest_home() {
    if [[ ! -f "$DATA_DIR/guest/.populated" ]]; then
        info "Guest home incomplete at $DATA_DIR/guest, populating..."
        refresh_guest_home
    fi
}
