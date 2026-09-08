#!/usr/bin/env bash
#
# =====================================================================
#  👹 DXD LABS PREMIUM VPS DASHBOARD — SUKUNA V4.1
# =====================================================================
#  Hardened Ubuntu 22.04 QEMU/KVM VM Manager
#
#  FIXES:
#    • QEMU missing-path bug fixed
#    • Dependencies installed before binary detection
#    • Automatic VM artifact preparation
#    • Automatic base image download
#    • Automatic qcow2 disk creation
#    • Automatic cloud-init seed creation
#    • Real Direct Console using -nographic
#    • QEMU stderr logged without stealing console stdout
#    • Correct architecture-specific QEMU selection
#    • KVM + TCG fallback
#    • PID + QMP + lock management
#    • Graceful shutdown
#    • Port validation
#    • Persistent configuration
#    • SHA256 image verification
#
#  Target:
#    Ubuntu / Debian
#    Ubuntu 22.04 cloud image
#
# =====================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =====================================================================
# VERSION
# =====================================================================

readonly APP_NAME="DXD LABS PREMIUM VPS DASHBOARD — SUKUNA V4.1"
readonly VERSION="4.1.0"

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

readonly CLOUDIMG_URL_AMD64="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
readonly CLOUDIMG_URL_ARM64="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img"

readonly CLOUDIMG_SHA="https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"

# =====================================================================
# GLOBALS
# =====================================================================

SUDO_CMD=""
PKG_MANAGER=""
ARCH=""
QEMU_BIN=""
SOCAT_BIN=""

CPU_HOST=1
CPU_VM=1

RAM_HOST_MB=1024
RAM_VM_MB=512

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
    echo -e "${RED}❌ SUKUNA V4.1 ERROR${NC}"
    echo -e "${RED}============================================================${NC}"
    echo -e "${WHITE}Line:${NC} ${line_no}"
    echo -e "${WHITE}Exit:${NC} ${exit_code}"
    echo -e "${WHITE}Log :${NC} ${QEMU_LOG}"
    echo -e "${RED}============================================================${NC}"
    echo

    exit "$exit_code"
}

trap 'on_error $LINENO' ERR

cleanup_on_exit() {
    :
}

trap cleanup_on_exit EXIT

# =====================================================================
# PRIVILEGE
# =====================================================================

setup_privileges() {
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO_CMD=""
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        SUDO_CMD="sudo"
        return 0
    fi

    echo -e "${RED}❌ sudo is required when not running as root.${NC}"
    exit 1
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
    echo -e "${RED}║${NC}                 ${CYAN}SUKUNA V4.1${NC}                        ${RED}║${NC}"
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
# COMMAND CHECK
# =====================================================================

require_command() {
    local cmd="$1"

    command -v "$cmd" >/dev/null 2>&1
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
        error_msg "Unsupported package manager."
        return 1
    fi
}

# =====================================================================
# ARCHITECTURE
# =====================================================================

detect_architecture() {
    local machine

    machine="$(uname -m)"

    case "$machine" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            error_msg "Unsupported host architecture: ${machine}"
            return 1
            ;;
    esac
}

# =====================================================================
# QEMU BINARY
# =====================================================================

resolve_qemu_binary() {
    QEMU_BIN=""

    case "$ARCH" in
        amd64)
            if command -v qemu-system-x86_64 >/dev/null 2>&1; then
                QEMU_BIN="$(command -v qemu-system-x86_64)"
            fi
            ;;
        arm64)
            if command -v qemu-system-aarch64 >/dev/null 2>&1; then
                QEMU_BIN="$(command -v qemu-system-aarch64)"
            fi
            ;;
    esac

    if [[ -z "$QEMU_BIN" ]]; then
        error_msg "QEMU binary for ${ARCH} was not found."
        return 1
    fi

    success "QEMU detected: ${QEMU_BIN}"
}

# =====================================================================
# DEPENDENCIES
# =====================================================================

install_dependencies() {
    detect_package_manager
    detect_architecture

    local packages=(
        qemu-utils
        cloud-image-utils
        curl
        openssl
        util-linux
        socat
        ca-certificates
    )

    if [[ "$ARCH" == "amd64" ]]; then
        packages+=("qemu-system-x86")
    else
        packages+=("qemu-system-arm")
    fi

    echo -e "${YELLOW}📦 Checking dependencies...${NC}"

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

    echo
    echo -e "${YELLOW}Installing missing packages:${NC}"
    printf '  %s\n' "${missing[@]}"
    echo

    $SUDO_CMD "$PKG_MANAGER" update -y
    $SUDO_CMD "$PKG_MANAGER" install -y "${missing[@]}"

    success "Dependencies installed."
}

# =====================================================================
# KVM
# =====================================================================

detect_kvm() {
    KVM_AVAILABLE=false
    KVM_REASON=""

    if [[ "$ARCH" != "amd64" ]]; then
        KVM_REASON="ARM KVM path is not enabled by this VM profile."
        return 0
    fi

    if [[ ! -e /dev/kvm ]]; then
        KVM_REASON="/dev/kvm does not exist."
        return 0
    fi

    if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        KVM_REASON="/dev/kvm is not readable/writable."
        return 0
    fi

    if ! $SUDO_CMD test -r /dev/kvm 2>/dev/null; then
        KVM_REASON="Permission denied for /dev/kvm."
        return 0
    fi

    KVM_AVAILABLE=true
    KVM_REASON="Hardware acceleration available."
}

# =====================================================================
# RESOURCES
# =====================================================================

detect_resources() {
    CPU_HOST="$(nproc 2>/dev/null || echo 1)"

    if (( CPU_HOST < 1 )); then
        CPU_HOST=1
    fi

    if (( CPU_HOST <= 2 )); then
        CPU_VM=1
    else
        CPU_VM=$((CPU_HOST - 1))
    fi

    local mem_kb

    mem_kb="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo)"

    if [[ -z "$mem_kb" ]]; then
        error_msg "Unable to detect host RAM."
        return 1
    fi

    RAM_HOST_MB=$((mem_kb / 1024))

    if (( RAM_HOST_MB < 1024 )); then
        error_msg "Host RAM is too low: ${RAM_HOST_MB}MB"
        return 1
    fi

    local reserve_mb

    reserve_mb=$((RAM_HOST_MB / 5))

    if (( reserve_mb < 1024 )); then
        reserve_mb=1024
    fi

    RAM_VM_MB=$((RAM_HOST_MB - reserve_mb))

    if (( RAM_VM_MB < 512 )); then
        error_msg "Not enough RAM available for VM."
        return 1
    fi

    RAM_VM_MB=$((RAM_VM_MB / 128 * 128))

    if (( RAM_VM_MB < 512 )); then
        RAM_VM_MB=512
    fi
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

    $SUDO_CMD touch "$QEMU_LOG"
    $SUDO_CMD chmod 600 "$QEMU_LOG"
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
    validate_number "$1" 1 65535
}

validate_disk_size() {
    validate_number "$1" 5 4096
}

write_config() {
    $SUDO_CMD mkdir -p "$CONFIG_DIR"

    local tmp_config
    tmp_config="$(mktemp)"

    cat > "$tmp_config" <<EOF
VM_NAME="${VM_NAME}"
VM_HOSTNAME="${VM_HOSTNAME}"
RAM_MB="${RAM_VM_MB}"
CPU_CORES="${CPU_VM}"
DISK_SIZE_GB="${DISK_SIZE_GB}"
HOST_PORT="${HOST_PORT}"
GUEST_PORT="${GUEST_PORT}"
EOF

    $SUDO_CMD install -m 600 "$tmp_config" "$CONFIG_FILE"

    rm -f "$tmp_config"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0

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
# PORT
# =====================================================================

port_is_free() {
    local port="$1"

    validate_port "$port" || return 1

    if command -v ss >/dev/null 2>&1; then
        if ss -H -ltn 2>/dev/null |
            awk '{print $4}' |
            grep -Eq "([.:])${port}$"; then
            return 1
        fi
    fi

    return 0
}

# =====================================================================
# PASSWORD
# =====================================================================

generate_password_hash() {
    local password="$1"

    [[ -n "$password" ]] || {
        error_msg "Password cannot be empty."
        return 1
    }

    ROOT_PASSWORD_HASH="$(openssl passwd -6 "$password")"
}

# =====================================================================
# BASE IMAGE
# =====================================================================

download_base_image() {
    if [[ -f "$BASE_IMAGE" ]]; then
        success "Ubuntu base image already exists."
        return 0
    fi

    local url
    local image_name

    case "$ARCH" in
        amd64)
            url="$CLOUDIMG_URL_AMD64"
            image_name="jammy-server-cloudimg-amd64.img"
            ;;
        arm64)
            url="$CLOUDIMG_URL_ARM64"
            image_name="jammy-server-cloudimg-arm64.img"
            ;;
    esac

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
        "$CLOUDIMG_SHA" \
        -o "$checksum_file"

    local expected

    expected="$(
        awk -v file="$image_name" '
            $2 == file || $2 == "*" file {
                print $1
                exit
            }
        ' "$checksum_file"
    )"

    if [[ -z "$expected" ]]; then
        rm -f "$tmp_image"
        error_msg "Checksum for image was not found."
        return 1
    fi

    local actual

    actual="$(sha256sum "$tmp_image" | awk '{print $1}')"

    if [[ "$actual" != "$expected" ]]; then
        rm -f "$tmp_image"
        error_msg "SHA256 verification FAILED."
        return 1
    fi

    $SUDO_CMD mv "$tmp_image" "$BASE_IMAGE"
    $SUDO_CMD chmod 600 "$BASE_IMAGE"

    success "Ubuntu image downloaded and verified."
}

# =====================================================================
# VM DISK
# =====================================================================

create_vm_disk() {
    if [[ -f "$VM_IMAGE" ]]; then
        success "VM disk already exists."
        return 0
    fi

    [[ -f "$BASE_IMAGE" ]] || {
        error_msg "Base image is missing."
        return 1
    }

    echo -e "${YELLOW}💾 Creating qcow2 VM disk...${NC}"

    $SUDO_CMD qemu-img create \
        -f qcow2 \
        -F qcow2 \
        -b "$BASE_IMAGE" \
        "$VM_IMAGE" \
        "${DISK_SIZE_GB}G"

    $SUDO_CMD chmod 600 "$VM_IMAGE"

    success "VM disk created: ${VM_IMAGE}"
}

# =====================================================================
# CLOUD INIT
# =====================================================================

generate_cloud_init() {
    [[ -n "$ROOT_PASSWORD_HASH" ]] || {
        error_msg "Root password hash is missing."
        return 1
    }

    local tmp_user_data
    local tmp_meta_data

    tmp_user_data="$(mktemp)"
    tmp_meta_data="$(mktemp)"

    cat > "$tmp_user_data" <<EOF
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
  - openssh-server
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

growpart:
  mode: auto
  devices:
    - /

resize_rootfs: true

runcmd:
  - [ bash, -c, 'usermod -p "${ROOT_PASSWORD_HASH}" root' ]
  - [ systemctl, enable, ssh ]
  - [ systemctl, restart, ssh ]

final_message: "SUKUNA V4.1 VM initialization completed."
EOF

    cat > "$tmp_meta_data" <<EOF
instance-id: ${VM_NAME}-$(date +%s)
local-hostname: ${VM_HOSTNAME}
EOF

    $SUDO_CMD install -m 600 \
        "$tmp_user_data" \
        "$USER_DATA"

    $SUDO_CMD install -m 600 \
        "$tmp_meta_data" \
        "$META_DATA"

    rm -f "$tmp_user_data" "$tmp_meta_data"

    if ! command -v cloud-localds >/dev/null 2>&1; then
        error_msg "cloud-localds is missing."
        return 1
    fi

    rm -f "$SEED_IMAGE"

    $SUDO_CMD cloud-localds \
        "$SEED_IMAGE" \
        "$USER_DATA" \
        "$META_DATA"

    $SUDO_CMD chmod 600 "$SEED_IMAGE"

    success "Cloud-init seed created."
}

# =====================================================================
# VM READY CHECK
# =====================================================================

vm_artifacts_ready() {
    [[ -f "$VM_IMAGE" ]] &&
    [[ -f "$SEED_IMAGE" ]]
}

prepare_vm_artifacts() {
    prepare_workspace
    install_dependencies
    resolve_qemu_binary

    if [[ -z "$SOCAT_BIN" ]]; then
        SOCAT_BIN="$(command -v socat || true)"
    fi

    [[ -n "$SOCAT_BIN" ]] || {
        error_msg "socat was not found."
        return 1
    }

    download_base_image
    create_vm_disk

    if [[ ! -f "$SEED_IMAGE" ]]; then
        return 2
    fi

    return 0
}

# =====================================================================
# LOCK
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
        error_msg "Unable to acquire VM lock."
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

    if [[ -n "$pid" ]] &&
       vm_pid_is_valid "$pid"; then

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

    [[ -S "$QMP_SOCKET" ]] || {
        error_msg "QMP socket unavailable."
        return 1
    }

    printf '%s\n' \
        '{"execute":"qmp_capabilities"}' \
        "$command_json" |
        "$SOCAT_BIN" \
        - UNIX-CONNECT:"$QMP_SOCKET" \
        >/dev/null 2>&1
}

# =====================================================================
# STOP
# =====================================================================

graceful_shutdown() {
    if ! vm_is_running; then
        warning "VM is not running."
        return 0
    fi

    echo -e "${YELLOW}🛑 Requesting graceful shutdown...${NC}"

    qmp_command '{"execute":"system_powerdown"}' || true

    local timeout=30

    while (( timeout > 0 )); do

        if ! vm_is_running; then
            success "VM shut down gracefully."

            rm -f "$QMP_SOCKET" "$PID_FILE"
            release_vm_lock

            return 0
        fi

        sleep 1
        ((timeout--))
    done

    warning "VM did not shut down within 30 seconds."

    return 1
}

force_stop_vm() {
    if ! vm_is_running; then
        success "VM is already stopped."
        return 0
    fi

    local pid

    pid="$(cat "$PID_FILE")"

    echo -e "${YELLOW}Sending SIGTERM to QEMU PID ${pid}...${NC}"

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
        warning "QEMU still running. Sending SIGKILL..."

        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f \
        "$PID_FILE" \
        "$QMP_SOCKET"

    release_vm_lock

    success "VM process stopped."
}

stop_vm() {
    if ! vm_is_running; then
        success "VM is not running."
        release_vm_lock
        return 0
    fi

    if graceful_shutdown; then
        return 0
    fi

    echo
    echo -ne "${YELLOW}Force stop VM? [y/N]: ${NC}"
    read -r answer

    case "$answer" in
        y|Y|yes|YES)
            force_stop_vm
            ;;
        *)
            warning "VM remains running."
            ;;
    esac
}

# =====================================================================
# QEMU ARGS
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

        "-nographic"

        "-qmp"
        "unix:${QMP_SOCKET},server=on,wait=off"

        "-pidfile"
        "$PID_FILE"

        "-no-reboot"
    )
}

# =====================================================================
# BOOT
# =====================================================================

boot_vm() {
    header

    prepare_workspace

    if vm_is_running; then
        error_msg "VM is already running."
        pause_screen
        return 1
    fi

    detect_architecture
    detect_kvm
    detect_resources

    resolve_qemu_binary

    if [[ -z "$SOCAT_BIN" ]]; then
        SOCAT_BIN="$(command -v socat || true)"
    fi

    #
    # IMPORTANT:
    # Automatically prepare missing VM components.
    #
    if [[ ! -f "$BASE_IMAGE" || ! -f "$VM_IMAGE" ]]; then

        echo -e "${YELLOW}⚙ VM disk/base image is incomplete.${NC}"
        echo -e "${CYAN}SUKUNA will prepare the VM automatically.${NC}"
        echo

        prepare_vm_artifacts

        #
        # We cannot generate a seed without a password.
        #
        if [[ ! -f "$SEED_IMAGE" ]]; then

            echo
            echo -e "${YELLOW}🔐 Root password is required for first boot.${NC}"
            echo -ne "${CYAN}Set root password: ${NC}"

            read -rs root_password
            echo

            if (( ${#root_password} < 8 )); then
                error_msg "Password must contain at least 8 characters."
                unset root_password
                pause_screen
                return 1
            fi

            echo -ne "${CYAN}Confirm root password: ${NC}"
            read -rs root_password_confirm
            echo

            if [[ "$root_password" != "$root_password_confirm" ]]; then
                error_msg "Passwords do not match."
                unset root_password root_password_confirm
                pause_screen
                return 1
            fi

            generate_password_hash "$root_password"

            unset root_password root_password_confirm

            generate_cloud_init

            write_config
        fi
    fi

    #
    # Final artifact validation
    #

    if [[ ! -f "$VM_IMAGE" ]]; then
        error_msg "VM disk is still missing:"
        echo "  $VM_IMAGE"
        pause_screen
        return 1
    fi

    if [[ ! -f "$SEED_IMAGE" ]]; then
        error_msg "Cloud-init seed is still missing:"
        echo "  $SEED_IMAGE"
        echo
        echo "Run Create VM first to configure root password."
        pause_screen
        return 1
    fi

    if ! port_is_free "$HOST_PORT"; then
        error_msg "Host port ${HOST_PORT} is already in use."
        pause_screen
        return 1
    fi

    acquire_vm_lock

    build_qemu_args

    echo -e "${WHITE}VM:${NC}        ${CYAN}${VM_NAME}${NC}"
    echo -e "${WHITE}CPU:${NC}       ${CYAN}${CPU_VM}${NC}"
    echo -e "${WHITE}RAM:${NC}       ${CYAN}${RAM_VM_MB}MB${NC}"
    echo -e "${WHITE}Disk:${NC}      ${CYAN}${DISK_SIZE_GB}GB${NC}"
    echo -e "${WHITE}SSH:${NC}       ${CYAN}${HOST_PORT} -> ${GUEST_PORT}${NC}"
    echo

    if [[ "$KVM_AVAILABLE" == true ]]; then
        echo -e "${GREEN}⚡ KVM ENABLED — hardware acceleration${NC}"
    else
        echo -e "${YELLOW}🐢 KVM UNAVAILABLE — TCG FALLBACK${NC}"
        echo -e "${DIM}Reason: ${KVM_REASON}${NC}"
    fi

    echo
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${WHITE}🚀 Starting Ubuntu 22.04 VM${NC}"
    echo -e "${WHITE}🖥 Direct Console enabled${NC}"
    echo -e "${DIM}Exit QEMU: Ctrl+A then X${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo

    #
    # IMPORTANT:
    # stdout stays attached to terminal for Direct Console.
    # stderr goes to QEMU log.
    #

    set +e

    "$QEMU_BIN" \
        "${QEMU_ARGS[@]}" \
        2>>"$QEMU_LOG"

    local qemu_exit=$?

    set -e

    rm -f \
        "$PID_FILE" \
        "$QMP_SOCKET"

    release_vm_lock

    echo

    if (( qemu_exit == 0 )); then
        success "QEMU exited normally."
    else
        warning "QEMU exited with status ${qemu_exit}."
        echo -e "${DIM}Log: ${QEMU_LOG}${NC}"
    fi

    pause_screen

    return "$qemu_exit"
}

# =====================================================================
# CREATE VM
# =====================================================================

create_vm() {
    header

    if vm_is_running; then
        error_msg "VM is already running."
        pause_screen
        return 1
    fi

    detect_architecture
    prepare_workspace
    install_dependencies
    resolve_qemu_binary
    detect_kvm
    detect_resources

    echo -e "${WHITE}Detected host:${NC}"
    echo -e "  Architecture : ${CYAN}${ARCH}${NC}"
    echo -e "  CPU          : ${CYAN}${CPU_VM}${NC}"
    echo -e "  RAM          : ${CYAN}${RAM_VM_MB}MB${NC}"

    if [[ "$KVM_AVAILABLE" == true ]]; then
        echo -e "  KVM          : ${GREEN}ENABLED${NC}"
    else
        echo -e "  KVM          : ${YELLOW}TCG FALLBACK${NC}"
        echo -e "  Reason       : ${DIM}${KVM_REASON}${NC}"
    fi

    echo

    echo -ne "${CYAN}Hostname [${VM_NAME}]: ${NC}"
    read -r hostname_input

    VM_HOSTNAME="${hostname_input:-$VM_NAME}"

    if [[ ! "$VM_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]]; then
        error_msg "Invalid hostname."
        pause_screen
        return 1
    fi

    echo -ne "${CYAN}Disk size GB [20]: ${NC}"
    read -r disk_input

    DISK_SIZE_GB="${disk_input:-20}"

    if ! validate_disk_size "$DISK_SIZE_GB"; then
        error_msg "Invalid disk size."
        pause_screen
        return 1
    fi

    if [[ -f "$VM_IMAGE" ]]; then
        warning "Existing VM disk detected."
        echo "Cleaning and recreating it is NOT automatic."
        pause_screen
        return 1
    fi

    echo
    echo -e "${YELLOW}🔐 Root password must contain at least 8 characters.${NC}"
    echo -ne "${CYAN}Set root password: ${NC}"

    read -rs root_password
    echo

    if (( ${#root_password} < 8 )); then
        error_msg "Password is too short."
        unset root_password
        pause_screen
        return 1
    fi

    echo -ne "${CYAN}Confirm root password: ${NC}"
    read -rs root_password_confirm
    echo

    if [[ "$root_password" != "$root_password_confirm" ]]; then
        error_msg "Passwords do not match."
        unset root_password root_password_confirm
        pause_screen
        return 1
    fi

    generate_password_hash "$root_password"

    unset root_password root_password_confirm

    echo -ne "${CYAN}SSH host port [2222]: ${NC}"
    read -r host_port_input

    HOST_PORT="${host_port_input:-2222}"
    GUEST_PORT=22

    if ! validate_port "$HOST_PORT"; then
        error_msg "Invalid host port."
        pause_screen
        return 1
    fi

    if ! port_is_free "$HOST_PORT"; then
        error_msg "Port ${HOST_PORT} is already in use."
        pause_screen
        return 1
    fi

    echo
    echo -e "${YELLOW}🔧 Building VM...${NC}"

    download_base_image
    create_vm_disk
    generate_cloud_init
    write_config

    success "Ubuntu 22.04 VM created successfully."

    echo
    echo -e "${WHITE}VM configuration:${NC}"
    echo -e "  Name : ${CYAN}${VM_NAME}${NC}"
    echo -e "  Host : ${CYAN}${VM_HOSTNAME}${NC}"
    echo -e "  CPU  : ${CYAN}${CPU_VM}${NC}"
    echo -e "  RAM  : ${CYAN}${RAM_VM_MB}MB${NC}"
    echo -e "  Disk : ${CYAN}${DISK_SIZE_GB}GB${NC}"
    echo -e "  SSH  : ${CYAN}${HOST_PORT} -> 22${NC}"
    echo

    pause_screen
}

# =====================================================================
# STATUS
# =====================================================================

vm_status() {
    header

    detect_architecture
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

    echo

    if [[ -f "$SEED_IMAGE" ]]; then
        success "Cloud-init seed: READY"
    else
        warning "Cloud-init seed: MISSING"
    fi

    if [[ -f "$BASE_IMAGE" ]]; then
        success "Ubuntu base image: READY"
    else
        warning "Ubuntu base image: MISSING"
    fi

    pause_screen
}

# =====================================================================
# RESOURCE INFO
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

    echo

    if [[ "$KVM_AVAILABLE" == true ]]; then
        echo -e "${WHITE}KVM:${NC} ${GREEN}AVAILABLE${NC}"
    else
        echo -e "${WHITE}KVM:${NC} ${YELLOW}UNAVAILABLE${NC}"
        echo -e "${WHITE}Reason:${NC} ${DIM}${KVM_REASON}${NC}"
    fi

    echo

    if [[ -e /dev/kvm ]]; then
        ls -l /dev/kvm
    else
        warning "/dev/kvm does not exist."
    fi

    pause_screen
}

# =====================================================================
# NETWORK
# =====================================================================

network_configuration() {
    header

    echo -e "${WHITE}Current forwarding:${NC}"
    echo -e "  ${CYAN}${HOST_PORT} -> ${GUEST_PORT}${NC}"
    echo

    if vm_is_running; then
        warning "Stop VM before changing networking."
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
        error_msg "Host port already in use."
        pause_screen
        return
    fi

    echo -ne "${CYAN}Guest port [22]: ${NC}"
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

    success "Port forwarding updated."
    pause_screen
}

# =====================================================================
# DISK
# =====================================================================

inspect_disk() {
    if [[ ! -f "$VM_IMAGE" ]]; then
        error_msg "VM disk does not exist."
        return 1
    fi

    qemu-img info "$VM_IMAGE"
}

resize_vm_disk() {
    if vm_is_running; then
        error_msg "Stop VM before resizing."
        return 1
    fi

    if [[ ! -f "$VM_IMAGE" ]]; then
        error_msg "VM disk does not exist."
        return 1
    fi

    echo -ne "${CYAN}New absolute disk size in GB [5-4096]: ${NC}"
    read -r new_size

    if ! validate_disk_size "$new_size"; then
        error_msg "Invalid disk size."
        return 1
    fi

    local current_bytes

    current_bytes="$(
        qemu-img info --output=json "$VM_IMAGE" 2>/dev/null |
        grep -o '"virtual-size":[0-9]*' |
        head -n1 |
        cut -d: -f2
    )"

    if [[ -z "$current_bytes" ]]; then
        error_msg "Unable to determine current disk size."
        return 1
    fi

    local current_gb=$((current_bytes / 1024 / 1024 / 1024))

    if (( new_size < current_gb )); then
        error_msg "Disk shrinking is disabled."
        return 1
    fi

    if (( new_size == current_gb )); then
        success "Disk is already ${new_size}G."
        return 0
    fi

    $SUDO_CMD qemu-img resize \
        "$VM_IMAGE" \
        "${new_size}G"

    DISK_SIZE_GB="$new_size"

    write_config

    success "Disk resized successfully."
}

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
                inspect_disk || true
                pause_screen
                ;;
            2)
                resize_vm_disk || true
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
# CLEAN
# =====================================================================

clean_vm() {
    header

    if vm_is_running; then
        error_msg "VM is running."
        pause_screen
        return
    fi

    echo -e "${RED}⚠ WARNING${NC}"
    echo
    echo "This removes:"
    echo "  • VM disk"
    echo "  • cloud-init seed"
    echo "  • VM config"
    echo "  • cloud-init data"
    echo
    echo "The BASE IMAGE will remain."
    echo

    echo -ne "${YELLOW}Type DELETE to continue: ${NC}"
    read -r confirmation

    if [[ "$confirmation" != "DELETE" ]]; then
        warning "Cancelled."
        pause_screen
        return
    fi

    rm -f \
        "$VM_IMAGE" \
        "$SEED_IMAGE" \
        "$USER_DATA" \
        "$META_DATA" \
        "$CONFIG_FILE" \
        "$PID_FILE" \
        "$QMP_SOCKET" \
        "$LOCK_FILE"

    success "VM cleaned."
    echo -e "${DIM}Ubuntu base image preserved.${NC}"

    pause_screen
}

# =====================================================================
# RESTART
# =====================================================================

restart_vm() {
    header

    if vm_is_running; then

        echo -ne "${YELLOW}Restart running VM? [y/N]: ${NC}"
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
# INITIALIZE
# =====================================================================

initialize() {
    setup_privileges

    prepare_workspace

    detect_architecture

    #
    # FIX:
    # Install packages BEFORE resolving QEMU path.
    #
    install_dependencies

    resolve_qemu_binary

    SOCAT_BIN="$(command -v socat || true)"

    if [[ -z "$SOCAT_BIN" ]]; then
        error_msg "socat is missing."
        exit 1
    fi

    detect_kvm
    detect_resources

    load_config || true
}

# =====================================================================
# MENU
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

        echo -ne "${WHITE}👹 SUKUNA V4.1 > ${NC}"
        read -r choice

        case "$choice" in

            1)
                boot_vm || true
                ;;

            2)
                restart_vm || true
                ;;

            3)
                stop_vm || true
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
                create_vm || true
                ;;

            0)
                echo
                success "SUKUNA V4.1 shutting down dashboard."
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
# MAIN
# =====================================================================

main() {
    initialize
    show_menu
}

main "$@"
