#!/usr/bin/env bash
#
# =====================================================================
#  👹 DXD LABS PREMIUM VPS DASHBOARD — SUKUNA V4
# =====================================================================
#  Production-oriented Ubuntu 22.04 QEMU/KVM VM manager
#
#  Features:
#    • Real KVM detection + automatic TCG fallback
#    • Direct QEMU VM console (-nographic)
#    • Base cloud image + independent qcow2 overlay
#    • Automatic CPU/RAM/resource detection
#    • Persistent secure configuration
#    • PID + lock based VM state management
#    • QMP based graceful shutdown
#    • Safe TCP host -> guest forwarding
#    • Cloud-init provisioning
#    • Dedicated VM logs
#    • Disk management
#    • Input validation
#    • Error handling
#
#  Target:
#    Ubuntu / Debian based hosts
#    Ubuntu 22.04 cloud image
#
# =====================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =====================================================================
# VERSION
# =====================================================================

readonly APP_NAME="DXD LABS PREMIUM VPS DASHBOARD — SUKUNA V4"
readonly VERSION="4.0.0"

# =====================================================================
# COLORS
# =====================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# =====================================================================
# PATHS
# =====================================================================

readonly WORKDIR="/home/daytona"
readonly VM_NAME="dxd-ubuntu22"

readonly BASE_DIR="${WORKDIR}/base"
readonly VM_DIR="${WORKDIR}/vm"
readonly CONFIG_DIR="${WORKDIR}/config"
readonly LOG_DIR="${WORKDIR}/logs"
readonly RUN_DIR="${WORKDIR}/run"

readonly BASE_IMAGE="${BASE_DIR}/ubuntu22-base.img"
readonly VM_IMAGE="${VM_DIR}/${VM_NAME}.qcow2"

readonly USER_DATA="${VM_DIR}/user-data"
readonly META_DATA="${VM_DIR}/meta-data"
readonly SEED_IMAGE="${VM_DIR}/seed.img"

readonly CONFIG_FILE="${CONFIG_DIR}/vm.conf"
readonly PID_FILE="${RUN_DIR}/${VM_NAME}.pid"
readonly QMP_SOCKET="${RUN_DIR}/${VM_NAME}.qmp"
readonly LOCK_FILE="${RUN_DIR}/${VM_NAME}.lock"

readonly QEMU_LOG="${LOG_DIR}/qemu.log"
readonly CLOUD_INIT_LOG="${LOG_DIR}/cloud-init.log"

readonly CLOUDIMG_URL_AMD64="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
readonly CLOUDIMG_SHA_AMD64="https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"

readonly CLOUDIMG_URL_ARM64="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img"
readonly CLOUDIMG_SHA_ARM64="https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"

# =====================================================================
# GLOBALS
# =====================================================================

SUDO_CMD=""
PKG_MANAGER=""
ARCH=""
QEMU_BIN=""
CLOUD_LOCALDS_BIN=""
SOCAT_BIN=""

CPU_HOST=0
CPU_VM=0

RAM_HOST_MB=0
RAM_VM_MB=0

DISK_SIZE_GB=20

HOST_PORT=2222
GUEST_PORT=22

VM_HOSTNAME="${VM_NAME}"

KVM_AVAILABLE=false
KVM_REASON=""

VM_RUNNING=false

ROOT_PASSWORD_HASH=""

# =====================================================================
# ERROR HANDLING
# =====================================================================

on_error() {
    local exit_code=$?
    local line_no="${1:-unknown}"

    echo
    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}❌ SUKUNA V4 ERROR${NC}"
    echo -e "${RED}============================================================${NC}"
    echo -e "${WHITE}Line:${NC} ${line_no}"
    echo -e "${WHITE}Exit:${NC} ${exit_code}"
    echo -e "${WHITE}Log :${NC} ${QEMU_LOG}"
    echo -e "${RED}============================================================${NC}"

    exit "$exit_code"
}

trap 'on_error $LINENO' ERR

cleanup_on_exit() {
    # Do not kill the VM automatically.
    # The dashboard may exit while QEMU is still running.
    :
}

trap cleanup_on_exit EXIT

# =====================================================================
# PRIVILEGE
# =====================================================================

setup_privileges() {
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO_CMD=""
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        SUDO_CMD="sudo"
    else
        echo -e "${RED}❌ sudo is required when not running as root.${NC}"
        exit 1
    fi
}

# =====================================================================
# UI
# =====================================================================

pause_screen() {
    echo
    read -r -p "Press Enter to continue..." _
}

header() {
    clear

    echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC}        ${WHITE}👹 DXD LABS PREMIUM VPS DASHBOARD${NC}          ${RED}║${NC}"
    echo -e "${RED}║${NC}                  ${CYAN}SUKUNA V4${NC}                          ${RED}║${NC}"
    echo -e "${RED}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║${NC} ${DIM}QEMU/KVM • Ubuntu 22.04 • VM Manager • Direct Console${NC} ${RED}║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
}

info() {
    echo -e "${CYAN}ℹ${NC} $*"
}

success() {
    echo -e "${GREEN}✔${NC} $*"
}

warning() {
    echo -e "${YELLOW}⚠${NC} $*"
}

error_msg() {
    echo -e "${RED}✖${NC} $*"
}

# =====================================================================
# COMMAND CHECKS
# =====================================================================

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        error_msg "Required command not found: $cmd"
        return 1
    fi
}

# =====================================================================
# PACKAGE MANAGER
# =====================================================================

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt-get"
    elif command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    else
        error_msg "No supported Debian/Ubuntu package manager found."
        return 1
    fi
}

install_dependencies() {
    detect_package_manager

    local packages=(
        qemu-system-x86
        qemu-utils
        cloud-image-utils
        curl
        wget
        openssl
        util-linux
        socat
    )

    echo -e "${YELLOW}📦 Checking required packages...${NC}"

    local missing=()

    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | \
            grep -q "install ok installed"; then
            missing+=("$pkg")
        fi
    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        success "All required packages are installed."
        return 0
    fi

    echo -e "${YELLOW}Installing:${NC} ${missing[*]}"

    $SUDO_CMD "$PKG_MANAGER" update -y
    $SUDO_CMD "$PKG_MANAGER" install -y "${missing[@]}"
}

# =====================================================================
# ARCHITECTURE
# =====================================================================

detect_architecture() {
    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64|amd64)
            ARCH="amd64"
            QEMU_BIN="$(command -v qemu-system-x86_64)"
            ;;
        aarch64|arm64)
            ARCH="arm64"

            if command -v qemu-system-aarch64 >/dev/null 2>&1; then
                QEMU_BIN="$(command -v qemu-system-aarch64)"
            else
                error_msg "qemu-system-aarch64 is not installed."
                return 1
            fi
            ;;
        *)
            error_msg "Unsupported host architecture: $ARCH"
            return 1
            ;;
    esac
}

# =====================================================================
# KVM DETECTION
# =====================================================================

detect_kvm() {
    KVM_AVAILABLE=false
    KVM_REASON=""

    if [[ ! -e /dev/kvm ]]; then
        KVM_REASON="/dev/kvm does not exist"
        return 0
    fi

    if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        KVM_REASON="/dev/kvm exists but is not readable/writable"
        return 0
    fi

    if [[ "$ARCH" != "amd64" ]]; then
        KVM_REASON="ARM KVM requires architecture-specific QEMU configuration"
        return 0
    fi

    if ! "$SUDO_CMD" test -r /dev/kvm; then
        KVM_REASON="Permission denied for /dev/kvm"
        return 0
    fi

    KVM_AVAILABLE=true
    KVM_REASON="Hardware acceleration available"
}

# =====================================================================
# RESOURCE DETECTION
# =====================================================================

detect_resources() {
    CPU_HOST="$(nproc 2>/dev/null || true)"

    if [[ "$CPU_HOST" -lt 1 ]]; then
        CPU_HOST=1
    fi

    # Keep at least one host CPU.
    if [[ "$CPU_HOST" -le 2 ]]; then
        CPU_VM=1
    else
        CPU_VM=$((CPU_HOST - 1))
    fi

    # Prevent unreasonable allocations.
    if [[ "$CPU_VM" -lt 1 ]]; then
        CPU_VM=1
    fi

    local mem_kb
    mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"

    RAM_HOST_MB=$((mem_kb / 1024))

    if [[ "$RAM_HOST_MB" -lt 1024 ]]; then
        error_msg "Host RAM is too low: ${RAM_HOST_MB}MB"
        return 1
    fi

    # Reserve at least 1GB or ~20%, whichever is larger.
    local reserve_mb
    reserve_mb=$((RAM_HOST_MB / 5))

    if [[ "$reserve_mb" -lt 1024 ]]; then
        reserve_mb=1024
    fi

    RAM_VM_MB=$((RAM_HOST_MB - reserve_mb))

    # Never allocate less than 512MB.
    if [[ "$RAM_VM_MB" -lt 512 ]]; then
        error_msg "Not enough RAM available for a VM."
        return 1
    fi

    # Round down to 128MB.
    RAM_VM_MB=$((RAM_VM_MB / 128 * 128))

    # Disk space.
    local free_kb
    free_kb="$(df -Pk "$WORKDIR" 2>/dev/null | awk 'NR==2 {print $4}')"

    if [[ -z "$free_kb" ]]; then
        free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
    fi

    local free_gb=$((free_kb / 1024 / 1024))

    if [[ "$free_gb" -lt 5 ]]; then
        warning "Less than 5GB free disk space detected."
    fi
}

# =====================================================================
# CONFIG
# =====================================================================

validate_number() {
    local value="$1"
    local min="$2"
    local max="$3"

    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    (( value >= min && value <= max ))
}

validate_port() {
    local port="$1"
    validate_number "$port" 1 65535
}

validate_disk_size() {
    local size="$1"
    validate_number "$size" 5 4096
}

write_config() {
    $SUDO_CMD mkdir -p "$CONFIG_DIR"

    cat > /tmp/sukuna_v4_config.$$ <<EOF
# SUKUNA V4 persistent configuration
VM_NAME="${VM_NAME}"
VM_HOSTNAME="${VM_HOSTNAME}"
RAM_MB="${RAM_VM_MB}"
CPU_CORES="${CPU_VM}"
DISK_SIZE_GB="${DISK_SIZE_GB}"
HOST_PORT="${HOST_PORT}"
GUEST_PORT="${GUEST_PORT}"
BASE_IMAGE="${BASE_IMAGE}"
VM_IMAGE="${VM_IMAGE}"
EOF

    $SUDO_CMD install -m 600 \
        /tmp/sukuna_v4_config.$$ \
        "$CONFIG_FILE"

    rm -f /tmp/sukuna_v4_config.$$
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    CPU_VM="${CPU_CORES:-$CPU_VM}"
    RAM_VM_MB="${RAM_MB:-$RAM_VM_MB}"
    DISK_SIZE_GB="${DISK_SIZE_GB:-20}"
    HOST_PORT="${HOST_PORT:-2222}"
    GUEST_PORT="${GUEST_PORT:-22}"
    VM_HOSTNAME="${VM_HOSTNAME:-$VM_NAME}"
}

# =====================================================================
# PASSWORD
# =====================================================================

generate_password_hash() {
    local password="$1"

    if [[ -z "$password" ]]; then
        error_msg "Password cannot be empty."
        return 1
    fi

    ROOT_PASSWORD_HASH="$(openssl passwd -6 "$password")"
}

# =====================================================================
# PORT CHECK
# =====================================================================

port_is_free() {
    local port="$1"

    if ! validate_port "$port"; then
        return 1
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -H -ltn 2>/dev/null | awk '{print $4}' | \
            grep -Eq "(^|:)$port$"; then
            return 1
        fi
    fi

    return 0
}

# =====================================================================
# WORKSPACE
# =====================================================================

prepare_workspace() {
    $SUDO_CMD mkdir -p \
        "$WORKDIR" \
        "$BASE_DIR" \
        "$VM_DIR" \
        "$CONFIG_DIR" \
        "$LOG_DIR" \
        "$RUN_DIR"

    $SUDO_CMD chmod 700 \
        "$WORKDIR" \
        "$BASE_DIR" \
        "$VM_DIR" \
        "$CONFIG_DIR" \
        "$LOG_DIR" \
        "$RUN_DIR"
}

# =====================================================================
# CLOUD IMAGE
# =====================================================================

download_base_image() {
    if [[ -f "$BASE_IMAGE" ]]; then
        success "Ubuntu base image already exists."
        return 0
    fi

    local url
    local checksum_url
    local image_name

    if [[ "$ARCH" == "amd64" ]]; then
        url="$CLOUDIMG_URL_AMD64"
        checksum_url="$CLOUDIMG_SHA_AMD64"
        image_name="jammy-server-cloudimg-amd64.img"
    else
        url="$CLOUDIMG_URL_ARM64"
        checksum_url="$CLOUDIMG_SHA_ARM64"
        image_name="jammy-server-cloudimg-arm64.img"
    fi

    local tmp_image="${BASE_IMAGE}.download"
    local checksum_file="${BASE_DIR}/SHA256SUMS"

    echo -e "${YELLOW}📥 Downloading Ubuntu 22.04 cloud image...${NC}"

    rm -f "$tmp_image"

    curl -fL \
        --retry 5 \
        --retry-delay 2 \
        --connect-timeout 15 \
        "$url" \
        -o "$tmp_image"

    curl -fL \
        --retry 5 \
        --retry-delay 2 \
        --connect-timeout 15 \
        "$checksum_url" \
        -o "$checksum_file"

    local expected
    expected="$(awk -v file="$image_name" '$2 == file || $2 == "*" file {print $1}' "$checksum_file" | head -n1)"

    if [[ -z "$expected" ]]; then
        rm -f "$tmp_image"
        error_msg "Could not find checksum for downloaded image."
        return 1
    fi

    local actual
    actual="$(sha256sum "$tmp_image" | awk '{print $1}')"

    if [[ "$actual" != "$expected" ]]; then
        rm -f "$tmp_image"
        error_msg "Ubuntu image checksum verification FAILED."
        return 1
    fi

    $SUDO_CMD mv "$tmp_image" "$BASE_IMAGE"
    $SUDO_CMD chmod 600 "$BASE_IMAGE"

    success "Ubuntu cloud image verified and stored."
}

# =====================================================================
# VM DISK
# =====================================================================

create_vm_disk() {
    if [[ -f "$VM_IMAGE" ]]; then
        success "VM disk already exists."
        return 0
    fi

    if [[ ! -f "$BASE_IMAGE" ]]; then
        error_msg "Base image is missing."
        return 1
    fi

    echo -e "${YELLOW}💾 Creating independent qcow2 VM disk...${NC}"

    $SUDO_CMD qemu-img create \
        -f qcow2 \
        -F qcow2 \
        -b "$BASE_IMAGE" \
        "$VM_IMAGE" \
        "$DISK_SIZE_GB"G

    $SUDO_CMD chmod 600 "$VM_IMAGE"

    success "VM disk created."
}

inspect_disk() {
    if [[ ! -f "$VM_IMAGE" ]]; then
        error_msg "VM disk does not exist."
        return 1
    fi

    echo
    $SUDO_CMD qemu-img info "$VM_IMAGE"
    echo
}

resize_vm_disk() {
    if vm_is_running; then
        error_msg "Stop the VM before resizing the disk."
        return 1
    fi

    if [[ ! -f "$VM_IMAGE" ]]; then
        error_msg "VM disk does not exist."
        return 1
    fi

    inspect_disk

    echo -ne "${CYAN}New absolute disk size in GB [5-4096]: ${NC}"
    read -r new_size

    if ! validate_disk_size "$new_size"; then
        error_msg "Invalid disk size."
        return 1
    fi

    local current_bytes
    current_bytes="$(
        qemu-img info --output=json "$VM_IMAGE" |
            awk -F: '/"virtual-size"/ {gsub(/[, ]/,"",$2); print $2; exit}'
    )"

    if [[ -z "$current_bytes" ]]; then
        error_msg "Unable to determine current disk size."
        return 1
    fi

    local current_gb=$((current_bytes / 1024 / 1024 / 1024))

    if (( new_size < current_gb )); then
        error_msg "Shrinking qcow2 disks is intentionally disabled."
        echo "Current: ${current_gb}G"
        echo "Requested: ${new_size}G"
        return 1
    fi

    if (( new_size == current_gb )); then
        success "Disk is already ${new_size}G."
        return 0
    fi

    echo -e "${YELLOW}Resizing disk: ${current_gb}G -> ${new_size}G${NC}"

    $SUDO_CMD qemu-img resize \
        "$VM_IMAGE" \
        "${new_size}G"

    DISK_SIZE_GB="$new_size"

    write_config

    success "Disk resized successfully."
}

# =====================================================================
# CLOUD-INIT
# =====================================================================

generate_cloud_init() {
    if [[ -z "$ROOT_PASSWORD_HASH" ]]; then
        error_msg "Root password hash is not configured."
        return 1
    fi

    cat > /tmp/sukuna_user_data.$$ <<EOF
#cloud-config

hostname: ${VM_HOSTNAME}
manage_etc_hosts: true

users:
  - name: root
    lock_passwd: false
    shell: /bin/bash

disable_root: false

ssh_pwauth: true

chpasswd:
  expire: false

write_files:
  - path: /etc/ssh/sshd_config.d/99-sukuna.conf
    permissions: '0600'
    owner: root:root
    content: |
      PermitRootLogin yes
      PasswordAuthentication yes
      KbdInteractiveAuthentication no

package_update: true

packages:
  - curl
  - wget
  - git
  - nano
  - htop
  - unzip
  - ca-certificates
  - sudo
  - net-tools
  - iproute2
  - openssh-server

growpart:
  mode: auto
  devices:
    - /

resize_rootfs: true

runcmd:
  - [ bash, -c, 'usermod -p "${ROOT_PASSWORD_HASH}" root' ]
  - [ systemctl, enable, ssh ]
  - [ systemctl, restart, ssh ]

final_message: "SUKUNA V4 Ubuntu VM initialization completed."
EOF

    $SUDO_CMD install -m 600 \
        /tmp/sukuna_user_data.$$ \
        "$USER_DATA"

    rm -f /tmp/sukuna_user_data.$$

    cat > /tmp/sukuna_meta_data.$$ <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_HOSTNAME}
EOF

    $SUDO_CMD install -m 600 \
        /tmp/sukuna_meta_data.$$ \
        "$META_DATA"

    rm -f /tmp/sukuna_meta_data.$$

    if ! command -v cloud-localds >/dev/null 2>&1; then
        error_msg "cloud-localds is not installed."
        return 1
    fi

    rm -f "$SEED_IMAGE"

    $SUDO_CMD cloud-localds \
        "$SEED_IMAGE" \
        "$USER_DATA" \
        "$META_DATA"

    $SUDO_CMD chmod 600 "$SEED_IMAGE"

    success "Cloud-init seed generated."
}

# =====================================================================
# VM LOCK
# =====================================================================

acquire_vm_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        if vm_is_running; then
            error_msg "VM is already running."
            return 1
        fi

        rm -f "$LOCK_FILE"
    fi

    (
        set -o noclobber
        echo "$$" > "$LOCK_FILE"
    ) 2>/dev/null || {
        error_msg "Could not acquire VM lock."
        return 1
    }

    $SUDO_CMD chmod 600 "$LOCK_FILE"
}

release_vm_lock() {
    rm -f "$LOCK_FILE"
}

# =====================================================================
# VM STATE
# =====================================================================

vm_pid_is_valid() {
    local pid="$1"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

vm_is_running() {
    if [[ ! -f "$PID_FILE" ]]; then
        VM_RUNNING=false
        return 1
    fi

    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"

    if [[ -n "$pid" ]] && vm_pid_is_valid "$pid"; then
        if [[ -r "/proc/$pid/cmdline" ]] &&
            tr '\0' ' ' < "/proc/$pid/cmdline" |
            grep -q "qemu-system"; then
            VM_RUNNING=true
            return 0
        fi
    fi

    rm -f "$PID_FILE"
    VM_RUNNING=false

    return 1
}

# =====================================================================
# QMP
# =====================================================================

qmp_command() {
    local command_json="$1"

    if [[ ! -S "$QMP_SOCKET" ]]; then
        error_msg "QMP socket is unavailable."
        return 1
    fi

    printf '%s\n' \
        '{"execute":"qmp_capabilities"}' \
        "$command_json" |
        "$SOCAT_BIN" \
        - UNIX-CONNECT:"$QMP_SOCKET" \
        >/dev/null 2>&1
}

graceful_shutdown() {
    if ! vm_is_running; then
        warning "VM is not running."
        return 0
    fi

    echo -e "${YELLOW}🛑 Requesting graceful VM shutdown...${NC}"

    if ! qmp_command '{"execute":"system_powerdown"}'; then
        warning "QMP shutdown request failed."
    fi

    local timeout=30

    while (( timeout > 0 )); do
        if ! vm_is_running; then
            success "VM shut down gracefully."
            rm -f "$QMP_SOCKET"
            return 0
        fi

        sleep 1
        ((timeout--))
    done

    warning "VM did not shut down within ${30}s."
    return 1
}

force_stop_vm() {
    if ! vm_is_running; then
        success "VM is already stopped."
        return 0
    fi

    local pid
    pid="$(cat "$PID_FILE")"

    warning "Sending SIGTERM to QEMU PID ${pid}..."

    kill -TERM "$pid" 2>/dev/null || true

    local timeout=10

    while (( timeout > 0 )); do
        if ! vm_pid_is_valid "$pid"; then
            break
        fi

        sleep 1
        ((timeout--))
    done

    if vm_pid_is_valid "$pid"; then
        warning "QEMU did not exit after SIGTERM."
        echo -e "${YELLOW}Sending SIGKILL to QEMU PID ${pid}...${NC}"

        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE" "$QMP_SOCKET"

    success "VM process stopped."
}

stop_vm() {
    if ! vm_is_running; then
        success "VM is not running."
        return 0
    fi

    if graceful_shutdown; then
        release_vm_lock
        return 0
    fi

    echo
    echo -ne "${YELLOW}Force stop VM? [y/N]: ${NC}"
    read -r answer

    case "$answer" in
        y|Y|yes|YES)
            force_stop_vm
            release_vm_lock
            ;;
        *)
            warning "VM remains running."
            ;;
    esac
}

# =====================================================================
# QEMU COMMAND
# =====================================================================

build_qemu_args() {
    QEMU_ARGS=()

    if [[ "$ARCH" == "amd64" ]]; then
        if [[ "$KVM_AVAILABLE" == true ]]; then
            QEMU_ARGS+=(
                "-enable-kvm"
                "-cpu"
                "host"
            )
        else
            QEMU_ARGS+=(
                "-accel"
                "tcg"
                "-cpu"
                "max"
            )
        fi

        QEMU_ARGS+=(
            "-machine"
            "q35"
        )
    else
        QEMU_ARGS+=(
            "-machine"
            "virt"
            "-cpu"
            "max"
        )
    fi

    QEMU_ARGS+=(
        "-name"
        "$VM_NAME"

        "-smp"
        "$CPU_VM"

        "-m"
        "${RAM_VM_MB}M"

        "-drive"
        "file=${VM_IMAGE},format=qcow2,if=virtio,cache=none,aio=threads"

        "-drive"
        "file=${SEED_IMAGE},format=raw,if=virtio,readonly=on"

        "-netdev"
        "user,id=net0,hostfwd=tcp::${HOST_PORT}-:${GUEST_PORT}"

        "-device"
        "virtio-net-pci,netdev=net0"

        "-display"
        "none"

        "-serial"
        "stdio"

        "-qmp"
        "unix:${QMP_SOCKET},server=on,wait=off"

        "-pidfile"
        "$PID_FILE"

        "-no-reboot"
    )
}

# =====================================================================
# BOOT VM
# =====================================================================

boot_vm() {
    header

    if vm_is_running; then
        error_msg "VM is already running."
        pause_screen
        return
    fi

    if [[ ! -f "$VM_IMAGE" ]]; then
        error_msg "VM disk does not exist."
        pause_screen
        return
    fi

    if [[ ! -f "$SEED_IMAGE" ]]; then
        error_msg "Cloud-init seed is missing."
        pause_screen
        return
    fi

    if ! port_is_free "$HOST_PORT"; then
        error_msg "Host TCP port ${HOST_PORT} is already in use."
        pause_screen
        return
    fi

    acquire_vm_lock

    detect_kvm

    build_qemu_args

    echo -e "${WHITE}VM:${NC}        ${CYAN}${VM_NAME}${NC}"
    echo -e "${WHITE}CPU:${NC}       ${CYAN}${CPU_VM}${NC}"
    echo -e "${WHITE}RAM:${NC}       ${CYAN}${RAM_VM_MB}MB${NC}"
    echo -e "${WHITE}Disk:${NC}      ${CYAN}${DISK_SIZE_GB}GB${NC}"
    echo -e "${WHITE}Network:${NC}   ${CYAN}${HOST_PORT} -> ${GUEST_PORT}${NC}"
    echo

    if [[ "$KVM_AVAILABLE" == true ]]; then
        echo -e "${GREEN}⚡ KVM ENABLED — hardware acceleration${NC}"
    else
        echo -e "${YELLOW}🐢 KVM UNAVAILABLE — TCG FALLBACK${NC}"
        echo -e "${DIM}Reason: ${KVM_REASON}${NC}"
    fi

    echo
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${WHITE}🚀 Starting real Ubuntu VM console...${NC}"
    echo -e "${DIM}QEMU exit: Ctrl+A then X${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo

    # QEMU owns the terminal from this point.
    # No fake shell / dashboard is inserted between the user and VM.
    set +e

    "$QEMU_BIN" \
        "${QEMU_ARGS[@]}" \
        >>"$QEMU_LOG" \
        2>&1

    local qemu_exit=$?

    set -e

    rm -f "$PID_FILE" "$QMP_SOCKET"
    release_vm_lock

    echo

    if [[ "$qemu_exit" -eq 0 ]]; then
        success "QEMU exited normally."
    else
        warning "QEMU exited with status ${qemu_exit}."
        echo -e "${DIM}Check log: ${QEMU_LOG}${NC}"
    fi

    pause_screen
}

# =====================================================================
# RESTART
# =====================================================================

restart_vm() {
    header

    if vm_is_running; then
        echo -e "${YELLOW}VM is currently running.${NC}"
        echo
        echo -ne "Restart it now? [y/N]: "
        read -r answer

        case "$answer" in
            y|Y|yes|YES)
                if ! stop_vm; then
                    return 1
                fi
                ;;
            *)
                return 0
                ;;
        esac
    fi

    boot_vm
}

# =====================================================================
# VM STATUS
# =====================================================================

vm_status() {
    header

    detect_kvm
    detect_resources

    echo -e "${WHITE}VM Name       :${NC} ${CYAN}${VM_NAME}${NC}"

    if vm_is_running; then
        local pid
        pid="$(cat "$PID_FILE")"

        echo -e "${WHITE}Status        :${NC} ${GREEN}RUNNING${NC}"
        echo -e "${WHITE}PID           :${NC} ${CYAN}${pid}${NC}"
    else
        echo -e "${WHITE}Status        :${NC} ${DIM}STOPPED${NC}"
    fi

    echo -e "${WHITE}Architecture  :${NC} ${CYAN}${ARCH}${NC}"

    if [[ "$KVM_AVAILABLE" == true ]]; then
        echo -e "${WHITE}Acceleration  :${NC} ${GREEN}KVM ENABLED${NC}"
    else
        echo -e "${WHITE}Acceleration  :${NC} ${YELLOW}TCG FALLBACK${NC}"
        echo -e "${WHITE}Reason        :${NC} ${DIM}${KVM_REASON}${NC}"
    fi

    echo -e "${WHITE}CPU           :${NC} ${CYAN}${CPU_VM}/${CPU_HOST}${NC}"
    echo -e "${WHITE}RAM           :${NC} ${CYAN}${RAM_VM_MB}MB / ${RAM_HOST_MB}MB${NC}"
    echo -e "${WHITE}SSH Forward   :${NC} ${CYAN}${HOST_PORT} -> ${GUEST_PORT}${NC}"

    echo

    if [[ -f "$VM_IMAGE" ]]; then
        echo -e "${WHITE}Disk:${NC}"
        qemu-img info "$VM_IMAGE" 2>/dev/null || true
    else
        warning "VM disk does not exist."
    fi

    pause_screen
}

# =====================================================================
# RESOURCE INFORMATION
# =====================================================================

resource_information() {
    header

    detect_architecture
    detect_kvm
    detect_resources

    local free_space
    free_space="$(df -h "$WORKDIR" 2>/dev/null | awk 'NR==2 {print $4}')"

    echo -e "${WHITE}Host Architecture :${NC} ${CYAN}${ARCH}${NC}"
    echo -e "${WHITE}Host CPU Cores    :${NC} ${CYAN}${CPU_HOST}${NC}"
    echo -e "${WHITE}VM CPU Cores      :${NC} ${CYAN}${CPU_VM}${NC}"
    echo -e "${WHITE}Host RAM          :${NC} ${CYAN}${RAM_HOST_MB}MB${NC}"
    echo -e "${WHITE}VM RAM            :${NC} ${CYAN}${RAM_VM_MB}MB${NC}"
    echo -e "${WHITE}Free Disk Space   :${NC} ${CYAN}${free_space}${NC}"

    if [[ "$KVM_AVAILABLE" == true ]]; then
        echo -e "${WHITE}KVM               :${NC} ${GREEN}ENABLED${NC}"
    else
        echo -e "${WHITE}KVM               :${NC} ${YELLOW}UNAVAILABLE${NC}"
        echo -e "${WHITE}Reason            :${NC} ${DIM}${KVM_REASON}${NC}"
    fi

    echo

    if [[ -e /dev/kvm ]]; then
        echo -e "${WHITE}/dev/kvm:${NC}"
        ls -l /dev/kvm
    else
        warning "/dev/kvm does not exist."
    fi

    pause_screen
}

# =====================================================================
# NETWORK CONFIG
# =====================================================================

network_configuration() {
    header

    echo -e "${WHITE}Current forwarding:${NC}"
    echo -e "  ${CYAN}HOST ${HOST_PORT}${NC} -> ${CYAN}GUEST ${GUEST_PORT}${NC}"
    echo

    if vm_is_running; then
        warning "Stop the VM before changing forwarding."
        pause_screen
        return
    fi

    echo -ne "${CYAN}Host port [1-65535]: ${NC}"
    read -r new_host

    if ! validate_port "$new_host"; then
        error_msg "Invalid host port."
        pause_screen
        return
    fi

    if ! port_is_free "$new_host"; then
        error_msg "Host port ${new_host} is already in use."
        pause_screen
        return
    fi

    echo -ne "${CYAN}Guest port [1-65535] (default 22): ${NC}"
    read -r new_guest

    new_guest="${new_guest:-22}"

    if ! validate_port "$new_guest"; then
        error_msg "Invalid guest port."
        pause_screen
        return
    fi

    HOST_PORT="$new_host"
    GUEST_PORT="$new_guest"

    write_config

    success "Port forwarding updated:"
    echo -e "${CYAN}${HOST_PORT} -> ${GUEST_PORT}${NC}"

    pause_screen
}

# =====================================================================
# CREATE VM
# =====================================================================

create_vm() {
    header

    if [[ -f "$VM_IMAGE" ]]; then
        warning "VM already exists."
        echo
        echo "Use Boot VM from the dashboard."
        pause_screen
        return
    fi

    detect_architecture
    detect_kvm
    detect_resources

    echo -e "${WHITE}Detected resources:${NC}"
    echo -e "  CPU: ${CYAN}${CPU_VM}${NC} cores"
    echo -e "  RAM: ${CYAN}${RAM_VM_MB}MB${NC}"
    echo -e "  Arch: ${CYAN}${ARCH}${NC}"

    if [[ "$KVM_AVAILABLE" == true ]]; then
        echo -e "  Acceleration: ${GREEN}KVM ENABLED${NC}"
    else
        echo -e "  Acceleration: ${YELLOW}TCG FALLBACK${NC}"
    fi

    echo

    echo -ne "${CYAN}Hostname [${VM_NAME}]: ${NC}"
    read -r hostname_input

    VM_HOSTNAME="${hostname_input:-$VM_NAME}"

    if [[ ! "$VM_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]]; then
        error_msg "Invalid hostname."
        pause_screen
        return
    fi

    echo -ne "${CYAN}Disk size GB [20]: ${NC}"
    read -r disk_input

    DISK_SIZE_GB="${disk_input:-20}"

    if ! validate_disk_size "$DISK_SIZE_GB"; then
        error_msg "Invalid disk size."
        pause_screen
        return
    fi

    echo
    echo -e "${YELLOW}Root password will NOT be displayed.${NC}"
    echo -ne "${CYAN}Set root password: ${NC}"

    read -rs root_password
    echo

    if [[ "${#root_password}" -lt 8 ]]; then
        error_msg "Password must contain at least 8 characters."
        unset root_password
        pause_screen
        return
    fi

    echo -ne "${CYAN}Confirm root password: ${NC}"
    read -rs root_password_confirm
    echo

    if [[ "$root_password" != "$root_password_confirm" ]]; then
        error_msg "Passwords do not match."
        unset root_password root_password_confirm
        pause_screen
        return
    fi

    generate_password_hash "$root_password"

    unset root_password root_password_confirm

    echo -ne "${CYAN}SSH host port [2222]: ${NC}"
    read -r host_port_input

    HOST_PORT="${host_port_input:-2222}"

    if ! validate_port "$HOST_PORT"; then
        error_msg "Invalid host port."
        pause_screen
        return
    fi

    if ! port_is_free "$HOST_PORT"; then
        error_msg "Port ${HOST_PORT} is already occupied."
        pause_screen
        return
    fi

    GUEST_PORT=22

    prepare_workspace
    install_dependencies

    # Re-detect binaries after package installation.
    detect_architecture

    QEMU_BIN="$(command -v qemu-system-x86_64 || command -v qemu-system-aarch64 || true)"
    SOCAT_BIN="$(command -v socat || true)"

    if [[ -z "$QEMU_BIN" ]]; then
        error_msg "QEMU binary was not found."
        return 1
    fi

    if [[ -z "$SOCAT_BIN" ]]; then
        error_msg "socat is required for QMP shutdown."
        return 1
    fi

    download_base_image
    create_vm_disk
    generate_cloud_init

    write_config

    success "Ubuntu VM created successfully."

    echo
    echo -e "${WHITE}VM configuration:${NC}"
    echo -e "  Name : ${CYAN}${VM_NAME}${NC}"
    echo -e "  Host : ${CYAN}${VM_HOSTNAME}${NC}"
    echo -e "  CPU  : ${CYAN}${CPU_VM}${NC}"
    echo -e "  RAM  : ${CYAN}${RAM_VM_MB}MB${NC}"
    echo -e "  Disk : ${CYAN}${DISK_SIZE_GB}GB${NC}"
    echo -e "  SSH  : ${CYAN}${HOST_PORT} -> 22${NC}"

    pause_screen

    boot_vm
}

# =====================================================================
# DISK MANAGEMENT
# =====================================================================

disk_management() {
    while true; do
        header

        echo -e "${CYAN}[1]${NC} Disk Information"
        echo -e "${CYAN}[2]${NC} Resize Disk"
        echo -e "${CYAN}[3]${NC} Back"
        echo

        echo -ne "${WHITE}Choice: ${NC}"
        read -r choice

        case "$choice" in
            1)
                header
                inspect_disk
                pause_screen
                ;;
            2)
                resize_vm_disk
                pause_screen
                ;;
            3)
                return
                ;;
            *)
                error_msg "Invalid choice."
                sleep 1
                ;;
        esac
    done
}

# =====================================================================
# CLEAN VM
# =====================================================================

clean_vm() {
    header

    if vm_is_running; then
        error_msg "VM is running."
        echo "Stop it before cleaning."
        pause_screen
        return
    fi

    echo -e "${RED}⚠ WARNING${NC}"
    echo
    echo "This will remove the VM disk, seed, cloud-init data and config."
    echo "The Ubuntu BASE IMAGE will be preserved."
    echo

    echo -ne "${YELLOW}Type DELETE to continue: ${NC}"
    read -r confirmation

    if [[ "$confirmation" != "DELETE" ]]; then
        warning "Operation cancelled."
        pause_screen
        return
    fi

    # Explicitly validated paths only.
    rm -f \
        "$VM_IMAGE" \
        "$SEED_IMAGE" \
        "$USER_DATA" \
        "$META_DATA" \
        "$CONFIG_FILE" \
        "$PID_FILE" \
        "$QMP_SOCKET" \
        "$LOCK_FILE"

    success "VM cleaned successfully."
    echo -e "${DIM}Base Ubuntu image was preserved.${NC}"

    pause_screen
}

# =====================================================================
# INITIALIZATION
# =====================================================================

initialize() {
    setup_privileges

    prepare_workspace

    detect_architecture
    detect_kvm
    detect_resources

    if command -v qemu-system-x86_64 >/dev/null 2>&1; then
        QEMU_BIN="$(command -v qemu-system-x86_64)"
    elif command -v qemu-system-aarch64 >/dev/null 2>&1; then
        QEMU_BIN="$(command -v qemu-system-aarch64)"
    fi

    SOCAT_BIN="$(command -v socat || true)"

    load_config || true
}

# =====================================================================
# MAIN MENU
# =====================================================================

show_menu() {
    while true; do
        header

        detect_kvm

        if vm_is_running; then
            VM_STATE="${GREEN}RUNNING${NC}"
        else
            VM_STATE="${DIM}STOPPED${NC}"
        fi

        echo -e "${WHITE}VM Status:${NC} $VM_STATE"

        if [[ "$KVM_AVAILABLE" == true ]]; then
            echo -e "${WHITE}Acceleration:${NC} ${GREEN}KVM ENABLED${NC}"
        else
            echo -e "${WHITE}Acceleration:${NC} ${YELLOW}TCG FALLBACK${NC}"
        fi

        echo
        echo -e "${RED}────────────────────────────────────────────────────────────${NC}"

        echo -e "  ${CYAN}[1]${NC} 🚀 Boot VM"
        echo -e "  ${CYAN}[2]${NC} 🔄 Restart VM"
        echo -e "  ${CYAN}[3]${NC} 🛑 Stop VM"
        echo -e "  ${CYAN}[4]${NC} 📊 VM Status"
        echo -e "  ${CYAN}[5]${NC} ⚙️  Resource Information"
        echo -e "  ${CYAN}[6]${NC} 🌐 Network / Port Forwarding"
        echo -e "  ${CYAN}[7]${NC} 💾 Disk Management"
        echo -e "  ${CYAN}[8]${NC} 🧹 Clean VM"
        echo -e "  ${CYAN}[9]${NC} 🏗️  Create VM"
        echo -e "  ${CYAN}[0]${NC} 🚪 Exit"

        echo -e "${RED}────────────────────────────────────────────────────────────${NC}"
        echo

        echo -ne "${WHITE}👹 SUKUNA V4 > ${NC}"
        read -r choice

        case "$choice" in
            1)
                boot_vm
                ;;
            2)
                restart_vm
                ;;
            3)
                stop_vm
                pause_screen
                ;;
            4)
                vm_status
                ;;
            5)
                resource_information
                ;;
            6)
                network_configuration
                ;;
            7)
                disk_management
                ;;
            8)
                clean_vm
                ;;
            9)
                create_vm
                ;;
            0)
                echo
                success "SUKUNA V4 shutting down dashboard."
                exit 0
                ;;
            *)
                error_msg "Invalid choice."
                sleep 1
                ;;
        esac
    done
}

# =====================================================================
# ENTRY POINT
# =====================================================================

main() {
    initialize
    show_menu
}

main "$@"
