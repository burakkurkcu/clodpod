# shellcheck shell=bash
# Configuration: validation, version, names, paths

# Resolve database location: new XDG path, legacy install path, or fresh install
resolve_db_file() {
    if [[ -f "$DATA_DIR/clodpod.sqlite" ]]; then
        printf '%s' "$DATA_DIR/clodpod.sqlite"
    elif [[ -f "$OLD_DB_FILE" ]]; then
        info "Database found at $OLD_DB_FILE"
        info "Run 'clod migrate' to move it to $DATA_DIR/"
        info "If you have multiple clodpod checkouts, migrate from only one."
        printf '%s' "$OLD_DB_FILE"
    else
        mkdir -p "$DATA_DIR"
        printf '%s' "$DATA_DIR/clodpod.sqlite"
    fi
}

validate_platform() {
    if [[ $OSTYPE != 'darwin'* ]]; then
        abort "ERROR: this script is for Mac OSX"
    fi
}

validate_config() {
    case "$MACOS_IPSW" in
        latest|http://*|https://*)
            ;;
        *)
            MACOS_IPSW="$(resolve_physical_path "$MACOS_IPSW" 2>/dev/null || true)"
            [[ -f "$MACOS_IPSW" ]] || abort "MACOS_IPSW must be 'latest', an IPSW URL, or a path to an IPSW file"
            ;;
    esac
}

# shellcheck disable=SC2034,SC2154 # variables used/set by clod and other modules
init_config() {
    VERSION="1.0.30"
    OCI_VM_NAME="clodpod-oci-macos"
    BASE_VM_NAME="clodpod-base-default"
    DATA_DIR="$HOME/.local/share/clodpod"
    OLD_DB_FILE="$WORKSPACE/.clodpod.sqlite"
    DB_FILE="$(resolve_db_file)"
    SSH_DIR="$HOME/.ssh"
    SSH_KEYFILE_PRIV="$SSH_DIR/id_ed25519_clodpod"
    SSH_KEYFILE_PUB="$SSH_KEYFILE_PRIV.pub"
    SSH_KEY_CREATED=false
    MACOS_IMAGE="$MACOS_IPSW"
    debug "MacOS image: $MACOS_IMAGE"
}
