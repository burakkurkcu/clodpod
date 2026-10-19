# shellcheck shell=bash
# shellcheck disable=SC2154 # globals set by config.sh and other modules
# UI commands: list, help, version, status, macOS image provenance

list_bases() {
    local result
    result="$(base_list)"
    [[ -n "$result" ]] || return 1

    echo "BASES"
    printf "%-20s %-15s %s\n" "NAME" "MACOS" "CREATED"

    local name _vm_name oci_source created_at
    while IFS='|' read -r name _vm_name oci_source created_at; do
        printf "%-20s %-15s %s\n" "$name" "$oci_source" "$created_at"
    done <<< "$result"
}

list_all() {
    local budget_mb
    budget_mb="$(get_memory_budget_mb)"
    local host_ram_mb
    host_ram_mb="$(( $(sysctl -n hw.memsize) / 1048576 ))"
    local vm_count
    vm_count="$(get_setting "vm_count" "1")"
    [[ "$vm_count" =~ ^[0-9]+$ ]] && [[ "$vm_count" -ge 1 ]] || vm_count=1
    local per_vm_mb=$((budget_mb / vm_count))
    echo "Memory budget: ${budget_mb} MB (of ${host_ram_mb} MB), ${vm_count} VM(s) x ${per_vm_mb} MB"
    echo ""

    if list_bases; then
        echo ""
    fi

    if vm_list; then
        echo ""
        echo "PROJECTS"
        list_projects
    else
        list_projects
    fi
}

show_version() {
    echo "clod version $VERSION"
    exit 0
}

show_help() {
    cat <<EOF
clodpod v${VERSION} — macOS VM sandbox for AI agents

Usage: clod [options] <command> [args...] [-- command-args...]

Commands:
  claude, cl, c     Run Claude Code in VM
  codex, co         Run OpenAI Codex in VM
  cursor, cu, ca    Run Cursor Agent in VM
  gemini, gem, g    Run Google Gemini in VM
  herdr, hd         Run herdr agent multiplexer in VM
  shell, sh, s      Open shell in VM
  create, cr        Create a named VM instance
  destroy           Delete a named VM instance
  build-base        Build or rebuild a base image
  clone-base        Clone a base into a new profile (CoW, no install.sh)
  start             Start VM without connecting
  stop              Stop VM(s)
  set               Change VM settings
  list, ls, l       List instances, bases, and projects
  status, st        Show system state
  add, a            Add a project directory
  remove, rm        Remove a project
  migrate           Move database to XDG location
  help, h           Show help for a command

VM layers (each builds on the previous):
  Layer 0 (OS)        macOS installed from Apple's restore image (IPSW)
  Layer 1 (base)      Layer 0 + brew + AI tools + service logins
  Layer 2 (instance)  Base clone + project dirs + your tool installs

Existing instances keep working after a base rebuild, but won't have
the updated packages. Recreate to pick up changes: clod destroy + create.

Global options:
  --graphics/--no-graphics      VM display mode (default: graphics)
  --forward-port PORT           Reverse-forward host port into VM (repeatable)
  --rebuild-oci                 Reinstall macOS from the IPSW (Layer 0)
  --rebuild-base                Rebuild base from Layer 0 (Layer 1, rebuilds xcode VM too)
  --allow-sudo/--no-allow-sudo  Passwordless sudo in VM
  -n, --no-select               Skip interactive project selection
  -v/-vv/-vvv                   Verbosity
  -h, --help                    Show help
  --version                     Show version

Run 'clod help <command>' for command-specific help.
EOF
}

show_help_command() {
    local usage="$1" desc="$2"
    echo "Usage: clod $usage"
    echo ""
    echo "$desc"
}

show_help_create() {
    cat <<'EOF'
Usage: clod create <name> [options]

Create a named VM instance by cloning a base image.

Options:
  --base PROFILE    Base image to clone (default: 'default')
  --ram SIZE        Fixed RAM for this instance (e.g. 8G, 4096M, 'default' for budget)
  --dir name:path   Mount host directory into VM (repeatable, first is primary)

Examples:
  clod create dev --dir project:/Users/me/src/app
  clod create dev --ram 8G --base custom --dir work:$(pwd)
  clod create worker --dir repo:$(pwd) --dir data:/Volumes/data

Project Brewfiles (./Brewfile) are applied automatically at instance
creation, and re-checked on each shell entry. See guest/home/README.md.
EOF
}

show_help_build_base() {
    cat <<'EOF'
Usage: clod build-base [options]

Build a base image from Layer 0. Installs brew packages, AI tools,
and opens an interactive SSH session for manual login (Claude, Codex, etc.).

First run downloads Apple's macOS restore image (~18 GB) and installs
macOS from it — this takes a while and asks for sudo once to set up the
admin user offline. Subsequent runs reuse the installed Layer 0. Use
--rebuild-oci to reinstall from a newer macOS release.

The base ships the Xcode Command Line Tools. For full Xcode, add it with
--install-script (e.g. 'brew install xcodes && xcodes install --latest').

To update brew packages without reinstalling macOS, just run build-base
again — it rebuilds from the existing Layer 0.

Options:
  --profile NAME          Profile name (default: 'default')
  --install-script PATH   Import custom install script into profile

Environment:
  ALLOW_SUDO=true         Enable passwordless sudo in the base
  MACOS_IPSW=latest       Restore image for Layer 0: 'latest' (default),
                          an IPSW URL, or a local .ipsw path

Layers:
  Layer 0 (OS)       macOS from IPSW + admin user. Refresh: --rebuild-oci
  Layer 1 (base)     Layer 0 + brew + tools + login. This command builds it.
  Layer 2 (instance) Base clone + your tools. Created with 'clod create'.

Note: existing instances keep working after base rebuild but won't
have updated packages. Recreate to pick up changes:
  clod destroy <name> && clod create <name> --dir ...

Examples:
  clod build-base
  clod build-base --profile ml --install-script ./setup-cuda.sh
  ALLOW_SUDO=true clod build-base
  clod --rebuild-oci build-base     # reinstall macOS from the latest IPSW
  MACOS_IPSW=~/UniversalMac_26.6.2_25G83_Restore.ipsw clod --rebuild-oci build-base
EOF
}

show_help_clone_base() {
    cat <<'EOF'
Usage: clod clone-base <src-profile> <dst-profile>

Clone an existing base profile into a new one via APFS copy-on-write.
No install.sh, no interactive logins — the new base inherits everything
the source already has, and you make whatever changes you want directly
in the new base afterwards.

Use this when the desired delta from the source is something other than
the install.sh pipeline: a checkpoint before risky modifications, a
hand-edited variant, recovery-mode tweaks (custom boot policy, security
settings), or anything else you'd rather hand-roll than re-derive. For
variants whose delta is brew packages or new service logins, use
'clod build-base --profile <name>' instead — those need install.sh to
actually run.

The source base must be stopped. The destination must not already exist
(neither in the bases registry nor as a VM).

After cloning, derive instances:
  clod create <name> --base <dst-profile> --dir ...

To boot the new base directly (to inspect it, edit files, or enter
recoveryOS):
  clodvm run clodpod-base-<dst-profile>              # normal boot
  clodvm run --recovery clodpod-base-<dst-profile>   # recoveryOS

Note on identity-bound state: clodvm applies --random-mac --random-serial
when you later create instances from a base. State that's bound to the
VM's serial number — most notably Apple Silicon LocalPolicy / boot
policy — may not survive that re-serialization. If your modification to
the new base depends on identity-bound state, you may end up needing to
redo it per instance.

Examples:
  clod clone-base default checkpoint
  clod clone-base default custom
EOF
}

show_help_set() {
    cat <<'EOF'
Usage: clod set [options] [NAME]

Change VM and workspace settings. Instance name is required for
--ram, --dir, and --dir-remove. Options can be combined freely.

Options:
  --ram SIZE            Set fixed RAM for an instance (e.g. 8G, 'default' to reset)
  --max-memory SIZE     Set workspace memory budget (e.g. 32G, 'default' for 5/8 host RAM)
  --vm-count N          Split budget across N VMs ('default' to reset to 1)
  --isolation on|off    Mount only the active project in the default 'xcode' VM
                        ('off' restores mounting all projects)
  --dir name:path       Add or replace a mount on an existing instance
  --dir-remove name     Remove a mount by name (primary mount cannot be removed)

Mount changes take effect on next VM launch.

Examples:
  clod set --ram 10G dev
  clod set --isolation on
  clod set --dir code:/Users/me/src dev
  clod set --dir code:/Users/me/src --ram 8G dev
  clod set --dir-remove code dev
  clod set --max-memory 32G
  clod set --vm-count 3
EOF
}

show_help_shell() {
    cat <<'EOF'
Usage: clod shell [NAME] [--ram SIZE] [-- command...]

Open a shell in a VM instance.

Arguments:
  NAME                  Instance name (omit to target the default 'xcode' instance)
  --ram SIZE            Override RAM for this session (e.g. 8G)
  -- command...         Run command instead of interactive shell

Examples:
  clod shell                    # connect to the default 'xcode' instance
  clod shell dev
  clod shell dev --ram 12G
  clod --forward-port 8080 shell dev
  clod shell dev -- claude --dangerously-skip-permissions
EOF
}

show_help_destroy() {
    cat <<'EOF'
Usage: clod destroy [name]
       clod destroy --all

Delete a named VM instance (stops if running, removes VM and DB records).
If only one instance exists, the name can be omitted.

Options:
  --all     Delete all named instances

Examples:
  clod destroy dev
  clod destroy           # auto-selects if one instance exists
  clod destroy --all
EOF
}

show_help_stop() {
    cat <<'EOF'
Usage: clod stop [NAME]

Stop a named VM, or all clodpod VMs if no name given.

Examples:
  clod stop dev
  clod stop
EOF
}

show_help_start() {
    cat <<'EOF'
Usage: clod start [NAME]

Start a VM instance without connecting (no SSH session). Mounts the
instance's --dir mappings so a subsequent `clod shell <name>` reconnects
without restarting. If NAME is omitted, starts the default 'xcode' instance
(building it on first run).

Use --no-graphics to start headless.

Examples:
  clod start                 # start the default 'xcode' instance
  clod start dev
  clod --no-graphics start dev
EOF
}

# Dispatch per-command help from 'clod help <command>'
dispatch_help() {
    case "${1:-}" in
        create|cr)          show_help_create ;;
        destroy)            show_help_destroy ;;
        build-base)         show_help_build_base ;;
        clone-base)         show_help_clone_base ;;
        set)                show_help_set ;;
        shell|sh|s)         show_help_shell ;;
        stop)               show_help_stop ;;
        claude|cl|c)        show_help_command "claude [PATH] [NAME] [-- args...]" "Run Claude Code in a VM. PATH adds a project directory." ;;
        codex|co)           show_help_command "codex [PATH] [NAME] [-- args...]" "Run OpenAI Codex in a VM." ;;
        cursor|cu|ca)       show_help_command "cursor [PATH] [NAME] [-- args...]" "Run Cursor Agent in a VM." ;;
        gemini|gem|g)       show_help_command "gemini [PATH] [NAME] [-- args...]" "Run Google Gemini in a VM." ;;
        herdr|hd)           show_help_command "herdr [PATH] [NAME] [-- args...]" "Run the herdr agent multiplexer in a VM, hosting many agents in panes. Args pass through, e.g. '-- --session work'." ;;
        start)              show_help_start ;;
        add|a)              show_help_command "add PATH [NAME]" "Add a project directory. NAME defaults to directory basename." ;;
        remove|rm)          show_help_command "remove <name|path>" "Remove a project by name or path." ;;
        list|ls|l)          show_help_command "list" "List memory budget, bases, instances, and projects." ;;
        status|st)          show_help_command "status" "Show sudo setting, layer states, and macOS image provenance." ;;
        migrate)            show_help_command "migrate" "Move database from legacy location to ~/.local/share/clodpod/" ;;
        help|h)             show_help ;;
        *)                  show_help ;;
    esac
}

show_status() {
    local allow_sudo="${1:-false}"
    local oci_vm_state
    local base_vm_state
    local xcode_vm_state
    local stored_image

    oci_vm_state="$(get_vm_state "$OCI_VM_NAME")"
    base_vm_state="$(get_vm_state "$BASE_VM_NAME")"
    xcode_vm_state="$(get_vm_state "clodpod-xcode")"
    stored_image="$(get_setting "oci_base_image" "")"

    [[ -n "$oci_vm_state" ]] || oci_vm_state="not created"
    [[ -n "$base_vm_state" ]] || base_vm_state="not created"
    [[ -n "$xcode_vm_state" ]] || xcode_vm_state="not created"
    [[ -n "$stored_image" ]] || stored_image="not recorded"

    echo "passwordless sudo: $allow_sudo"
    echo "layer0 vm: $oci_vm_state"
    echo "base vm: $base_vm_state"
    echo "xcode vm: $xcode_vm_state"
    echo "stored image: $stored_image"
    echo "current image: $MACOS_IMAGE"
}

check_oci_provenance() {
    local check_only="${1:-false}"

    if [[ "${REBUILD_OCI:-}" != "" ]]; then
        return 0
    fi

    local stored_image
    stored_image="$(get_setting "oci_base_image" "")"

    if [[ -z "$stored_image" ]]; then
        return 0
    fi

    if [[ "$stored_image" != "$MACOS_IMAGE" ]]; then
        if [[ "$check_only" == "true" ]]; then
            warn "Image mismatch: built from $stored_image, current is $MACOS_IMAGE. Use --rebuild-oci to rebuild."
        else
            abort "Image mismatch: built from $stored_image, current is $MACOS_IMAGE. Use --rebuild-oci to rebuild."
        fi
    fi
}

ensure_oci_base() {
    if get_vm_exists "$OCI_VM_NAME"; then
        return 0
    fi

    local ipsw_path
    ipsw_path="$(resolve_ipsw)"

    debug "Creating $OCI_VM_NAME from $ipsw_path..."
    TMP_OCI_VM_NAME="clodpod-oci-tmp-$(openssl rand -hex 4)"
    clodvm create "$TMP_OCI_VM_NAME" --from-ipsw "$ipsw_path"

    # Create the admin user and enable SSH and autologin by writing the guest disk offline
    sudo -p "Password required to set up the admin user in the macOS VM disk: " \
        "$(command -v clodvm)" provision "$TMP_OCI_VM_NAME" \
        --user admin \
        --password admin \
        --authorized-keys "$SSH_KEYFILE_PUB" \
        --passwordless-sudo

    clodvm rename "$TMP_OCI_VM_NAME" "$OCI_VM_NAME"
    set_setting "oci_base_image" "$MACOS_IMAGE"

    # Downloaded restore images are no longer needed once macOS is installed
    rm -rf "$DATA_DIR/ipsw"
    debug "$OCI_VM_NAME created"
}

# Resolve MACOS_IPSW to a local restore image, downloading it when given as
# 'latest' or a URL.
resolve_ipsw() {
    local source="$MACOS_IPSW"
    if [[ "$source" == "latest" ]]; then
        source="$(clodvm ipsw)"
    fi
    if [[ "$source" != http://* ]] && [[ "$source" != https://* ]]; then
        echo "$source"
        return 0
    fi

    local ipsw_dir="$DATA_DIR/ipsw"
    local ipsw_path
    ipsw_path="$ipsw_dir/$(basename "$source")"
    if [[ ! -f "$ipsw_path" ]]; then
        mkdir -p "$ipsw_dir"
        info "Downloading $(basename "$source")..."
        curl -fL --progress-bar -C - -o "$ipsw_path.part" "$source"
        mv "$ipsw_path.part" "$ipsw_path"
    fi
    echo "$ipsw_path"
}
