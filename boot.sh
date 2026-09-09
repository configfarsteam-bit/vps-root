#!/usr/bin/env bash
# ============================================================================
# DXD LABS - SUKUNA V7 BOOT EDITION
# One-command Ubuntu 22.04 QEMU/KVM server launcher.
#
# Run:
#   sudo bash SUKUNA_V7_BOOT.sh
#
# The script intentionally has NO management menu. It bootstraps dependencies,
# downloads/verifies the Ubuntu cloud image, creates a fresh guest disk and
# cloud-init seed, starts QEMU/KVM, waits for SSH, and prints connection data.
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C.UTF-8

readonly VERSION='7.1.0-BOOT'
readonly HOST_SSH_PORT="${SUKUNA_SSH_PORT:-2222}"
readonly GUEST_SSH_PORT=22
readonly VM_NAME="${SUKUNA_VM_NAME:-sukuna-server}"
readonly VM_USER="${SUKUNA_VM_USER:-sukuna}"
readonly VM_RAM_MIB="${SUKUNA_RAM_MIB:-0}"     # 0 = auto
readonly VM_CPUS="${SUKUNA_CPUS:-0}"            # 0 = auto
readonly VM_DISK_GIB="${SUKUNA_DISK_GIB:-20}"
readonly BOOT_TIMEOUT="${SUKUNA_BOOT_TIMEOUT:-180}"
readonly SSH_TIMEOUT="${SUKUNA_SSH_TIMEOUT:-180}"
readonly HOME_BASE="${SUKUNA_HOME:-/var/lib/sukuna}"
readonly DATA_DIR="$HOME_BASE/data"
readonly BASE_DIR="$DATA_DIR/base"
readonly VM_DIR="$DATA_DIR/vm"
readonly RUN_DIR="$DATA_DIR/run"
readonly LOG_DIR="$DATA_DIR/log"
readonly SEED_DIR="$DATA_DIR/seed"
readonly BASE_IMG="$BASE_DIR/jammy-server-cloudimg-amd64.img"
readonly BASE_SHA="$BASE_DIR/jammy-server-cloudimg-amd64.img.sha256"
readonly DISK_IMG="$VM_DIR/$VM_NAME.qcow2"
readonly SEED_ISO="$VM_DIR/$VM_NAME-seed.iso"
readonly PID_FILE="$RUN_DIR/qemu.pid"
readonly QMP_SOCK="$RUN_DIR/qmp.sock"
readonly QEMU_LOG="$LOG_DIR/qemu.log"
readonly CONSOLE_LOG="$LOG_DIR/console.log"
readonly META_FILE="$SEED_DIR/meta-data"
readonly USERDATA_FILE="$SEED_DIR/user-data"
readonly VENDOR_FILE="$SEED_DIR/vendor-data"
readonly QEMU_PATH="${SUKUNA_QEMU:-/usr/bin/qemu-system-x86_64}"
readonly QEMU_IMG_PATH="${SUKUNA_QEMU_IMG:-/usr/bin/qemu-img}"
readonly PYTHON_BIN="${SUKUNA_PYTHON:-python3}"
readonly CLOUDA_LOCALDS="$(command -v cloud-localds 2>/dev/null || true)"
readonly OVMF_CODE_CANDIDATES=(
  /usr/share/OVMF/OVMF_CODE_4M.fd
  /usr/share/OVMF/OVMF_CODE.fd
  /usr/share/edk2/ovmf/x64/OVMF_CODE.fd
)
readonly OVMF_VARS_CANDIDATES=(
  /usr/share/OVMF/OVMF_VARS_4M.fd
  /usr/share/OVMF/OVMF_VARS.fd
  /usr/share/edk2/ovmf/vars/OVMF_VARS.fd
)
readonly UBUNTU_URL='https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img'
readonly UBUNTU_SUMS_URL='https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS'

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'; RESET=$'\033[0m'

log(){ printf '%b[%s]%b %s\n' "$BLUE" 'INFO' "$RESET" "$*"; }
ok(){ printf '%b[%s]%b %s\n' "$GREEN" ' OK ' "$RESET" "$*"; }
warn(){ printf '%b[%s]%b %s\n' "$YELLOW" 'WARN' "$RESET" "$*" >&2; }
die(){ printf '%b[ERR ]%b %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

cleanup_on_error(){
  local rc=$?
  if (( rc != 0 )); then
    warn "Boot failed (exit $rc). See: $QEMU_LOG"
    if [[ -s "$PID_FILE" ]]; then
      local pid
      pid=$(cat "$PID_FILE" 2>/dev/null || true)
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        warn "QEMU process $pid is still running. It was not blindly killed."
      fi
    fi
  fi
  exit "$rc"
}
trap cleanup_on_error EXIT
trap 'exit 130' INT TERM

require_root(){
  [[ "$(id -u)" -eq 0 ]] || die 'Run as root: sudo bash SUKUNA_V7_BOOT.sh'
}

apt_install(){
  local apt_get
  apt_get=$(command -v apt-get || true)
  [[ -n "$apt_get" ]] || die 'This automatic bootstrap currently supports Debian/Ubuntu systems with apt-get.'
  export DEBIAN_FRONTEND=noninteractive
  "$apt_get" update -y
  "$apt_get" install -y --no-install-recommends \
    ca-certificates curl coreutils procps iproute2 openssh-client openssl \
    qemu-system-x86 qemu-utils cloud-image-utils xorriso ovmf python3
}

have(){ command -v "$1" >/dev/null 2>&1; }

ensure_dependencies(){
  local missing=0 c
  for c in curl sha256sum awk sed grep find flock ss openssl python3; do
    have "$c" || missing=1
  done
  [[ -x "$QEMU_IMG_PATH" ]] || missing=1
  [[ -x "$QEMU_PATH" ]] || missing=1
  if ! have cloud-localds && ! have xorriso && ! have genisoimage; then missing=1; fi
  if (( missing == 0 )); then
    ok 'Required host dependencies are already installed.'
    return
  fi
  warn 'Required packages are missing. Installing automatically...'
  apt_install
  [[ -x "$QEMU_IMG_PATH" ]] || die "QEMU binary missing after package installation: $QEMU_IMG_PATH"
  [[ -x "$QEMU_PATH" ]] || die "QEMU binary missing after package installation: $QEMU_PATH"
  have curl || die 'curl is still missing after package installation.'
  ok 'Host dependencies installed.'
}

safe_dirs(){
  mkdir -p "$BASE_DIR" "$VM_DIR" "$RUN_DIR" "$LOG_DIR" "$SEED_DIR"
  chmod 700 "$HOME_BASE" "$DATA_DIR" "$BASE_DIR" "$VM_DIR" "$RUN_DIR" "$LOG_DIR" "$SEED_DIR"
}

validate_inputs(){
  [[ "$HOST_SSH_PORT" =~ ^[0-9]+$ ]] && (( HOST_SSH_PORT >= 1024 && HOST_SSH_PORT <= 65535 )) || die 'SUKUNA_SSH_PORT must be 1024..65535.'
  [[ "$VM_RAM_MIB" =~ ^[0-9]+$ ]] || die 'SUKUNA_RAM_MIB must be numeric.'
  [[ "$VM_CPUS" =~ ^[0-9]+$ ]] || die 'SUKUNA_CPUS must be numeric.'
  [[ "$VM_DISK_GIB" =~ ^[0-9]+$ ]] && (( VM_DISK_GIB >= 4 && VM_DISK_GIB <= 2048 )) || die 'SUKUNA_DISK_GIB must be 4..2048.'
  [[ "$VM_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid SUKUNA_VM_USER.'
}

lock_instance(){
  exec 9>"$RUN_DIR/boot.lock"
  flock -n 9 || die 'Another SUKUNA boot is already running.'
}

pid_running(){
  local pid=''
  [[ -s "$PID_FILE" ]] || return 1
  pid=$(cat "$PID_FILE" 2>/dev/null || true)
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -r "/proc/$pid/status" ]] || return 1
  local state exe
  state=$(awk '/^State:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)
  [[ "$state" != Z ]] || return 1
  exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
  [[ "$exe" == "$QEMU_PATH" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

port_free(){
  ! ss -ltnH "sport = :$HOST_SSH_PORT" 2>/dev/null | grep -q .
}

calc_resources(){
  local mem_kib cpus quota period avail_mib safe_mib
  mem_kib=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo)
  [[ "$mem_kib" =~ ^[0-9]+$ ]] || mem_kib=$((2048*1024))
  avail_mib=$((mem_kib/1024))

  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    local maxmem
    maxmem=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
    if [[ "$maxmem" =~ ^[0-9]+$ ]] && (( maxmem > 0 )); then
      local cg_mib=$((maxmem/1024/1024))
      (( cg_mib < avail_mib )) && avail_mib=$cg_mib
    fi
  fi

  safe_mib=$((avail_mib - 768))
  (( safe_mib < 512 )) && safe_mib=512
  local ram="$VM_RAM_MIB"
  if (( ram == 0 )); then
    ram=$((safe_mib * 75 / 100))
    (( ram < 512 )) && ram=512
    (( ram > 8192 )) && ram=8192
  fi
  (( ram > safe_mib )) && die "Requested RAM ${ram} MiB exceeds safe host allowance ${safe_mib} MiB."

  cpus=$(nproc 2>/dev/null || echo 1)
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r quota period < /sys/fs/cgroup/cpu.max || true
    if [[ "$quota" =~ ^[0-9]+$ ]] && [[ "$period" =~ ^[0-9]+$ ]] && (( period > 0 )); then
      local cg_cpu=$((quota/period))
      (( cg_cpu < 1 )) && cg_cpu=1
      (( cg_cpu < cpus )) && cpus=$cg_cpu
    fi
  fi
  local guest_cpus="$VM_CPUS"
  if (( guest_cpus == 0 )); then
    guest_cpus=$cpus
    (( guest_cpus > 8 )) && guest_cpus=8
  fi
  (( guest_cpus < 1 )) && guest_cpus=1
  (( guest_cpus > cpus )) && die "Requested vCPU count $guest_cpus exceeds host allowance $cpus."

  printf '%s\t%s\n' "$ram" "$guest_cpus"
}

kvm_ok(){
  [[ -r /dev/kvm && -w /dev/kvm ]] || return 1
  "$PYTHON_BIN" - <<'PY' 2>/dev/null
import fcntl, os, struct
fd=os.open('/dev/kvm', os.O_RDWR|os.O_CLOEXEC)
try:
    ver=fcntl.ioctl(fd, 0xAE00)
    if ver != 12:
        raise SystemExit(1)
finally:
    os.close(fd)
PY
}

ensure_python(){
  have python3 || { apt_install; have python3 || die 'python3 is required.'; }
}

# SHA256SUMS contains the exact image filename and checksum; verify the image
# itself, never a converted qcow2 derivative.
prepare_base_image(){
  mkdir -p "$BASE_DIR"
  local sums tmp_sum expected actual
  if [[ -f "$BASE_IMG" && -s "$BASE_IMG" && -s "$BASE_SHA" ]]; then
    expected=$(awk -v f="$(basename "$BASE_IMG")" '$2 == f || $2 == "*"f {print $1; exit}' "$BASE_SHA" 2>/dev/null || true)
    if [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
      actual=$(sha256sum "$BASE_IMG" | awk '{print $1}')
      if [[ "$actual" == "$expected" ]]; then
        ok 'Ubuntu cloud image cache verified.'
        return
      fi
    fi
    warn 'Cached Ubuntu image failed checksum verification; replacing it.'
    rm -f -- "$BASE_IMG" "$BASE_SHA"
  fi

  log 'Downloading Ubuntu 22.04 cloud image checksum list...'
  sums="$BASE_DIR/SHA256SUMS.download"
  curl --fail --silent --show-error --location --retry 5 --retry-delay 2 \
    --connect-timeout 15 --max-time 120 -o "$sums" "$UBUNTU_SUMS_URL"
  expected=$(awk -v f="$(basename "$BASE_IMG")" '$2 == f || $2 == "*"f {print $1; exit}' "$sums" || true)
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die 'Could not extract Ubuntu cloud-image SHA256.'

  log 'Downloading Ubuntu 22.04 cloud image...'
  local tmp_img="$BASE_IMG.part"
  rm -f -- "$tmp_img"
  curl --fail --silent --show-error --location --retry 5 --retry-delay 2 \
    --connect-timeout 15 --max-time 1800 -o "$tmp_img" "$UBUNTU_URL"
  actual=$(sha256sum "$tmp_img" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || { rm -f -- "$tmp_img"; die 'Ubuntu image SHA256 verification failed.'; }
  mv -f -- "$tmp_img" "$BASE_IMG"
  printf '%s  %s\n' "$expected" "$(basename "$BASE_IMG")" > "$BASE_SHA"
  chmod 600 "$BASE_IMG" "$BASE_SHA"
  rm -f -- "$sums"
  ok 'Ubuntu cloud image downloaded and verified.'
}

prepare_guest_disk(){
  if [[ -f "$DISK_IMG" ]]; then
    local virtual actual
    virtual=$($QEMU_IMG_PATH info --output=json -- "$DISK_IMG" 2>/dev/null | awk -F: '/"virtual-size"/{gsub(/[, ]/,"",$2); print $2; exit}' || true)
    actual=$((virtual / 1024 / 1024 / 1024))
    if [[ "$actual" =~ ^[0-9]+$ ]] && (( actual >= VM_DISK_GIB )); then
      ok "Guest disk exists: ${actual} GiB."
      return
    fi
    die "Existing guest disk is smaller than requested ${VM_DISK_GIB} GiB. Remove $DISK_IMG manually to recreate it."
  fi
  log "Creating ${VM_DISK_GIB} GiB guest disk..."
  "$QEMU_IMG_PATH" create -f qcow2 -o lazy_refcounts=on,compression_type=zstd "$DISK_IMG" "${VM_DISK_GIB}G" >/dev/null
  "$QEMU_IMG_PATH" check --quiet -- "$DISK_IMG" >/dev/null
  chmod 600 "$DISK_IMG"
  ok 'Guest disk created and checked.'
}

generate_credentials(){
  local cred_file="$RUN_DIR/credentials.txt"
  if [[ -s "$cred_file" ]]; then return; fi
  local password
  password=$(tr -dc 'A-Za-z0-9@#%+=_' </dev/urandom | head -c 20 || true)
  [[ ${#password} -ge 16 ]] || password="$(date +%s)-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  printf 'SUKUNA_VM_USER=%s\nSUKUNA_VM_PASSWORD=%s\n' "$VM_USER" "$password" > "$cred_file"
  chmod 600 "$cred_file"
}

prepare_cloud_init(){
  local password
  password=$(awk -F= '/^SUKUNA_VM_PASSWORD=/{print substr($0,index($0,$2)); exit}' "$RUN_DIR/credentials.txt")
  local ssh_pub=''
  if [[ -f /root/.ssh/authorized_keys ]]; then
    ssh_pub=$(head -n1 /root/.ssh/authorized_keys | tr -d '\r')
  fi

  cat > "$META_FILE" <<EOF_META
instance-id: $VM_NAME-$(date +%s)
local-hostname: $VM_NAME
EOF_META

  cat > "$USERDATA_FILE" <<EOF_USER
#cloud-config
preserve_hostname: false
hostname: $VM_NAME
manage_etc_hosts: true
ssh_pwauth: true
users:
  - default
  - name: $VM_USER
    gecos: SUKUNA Server User
    groups: [adm, sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    lock_passwd: false
    passwd: $(openssl passwd -6 "$password")
EOF_USER

  if [[ -n "$ssh_pub" && "$ssh_pub" =~ ^(ssh-|ecdsa-|sk-) ]]; then
    printf '    ssh_authorized_keys:\n      - %s\n' "$ssh_pub" >> "$USERDATA_FILE"
  fi

  cat >> "$USERDATA_FILE" <<'EOF_USER2'
package_update: true
packages:
  - openssh-server
  - ca-certificates
  - curl
  - sudo
  - qemu-guest-agent
runcmd:
  - systemctl enable --now ssh || systemctl enable --now ssh.service || true
  - systemctl enable --now qemu-guest-agent || true
  - mkdir -p /etc/ssh/sshd_config.d
  - printf '%s\n' 'PasswordAuthentication yes' 'PubkeyAuthentication yes' 'PermitRootLogin no' > /etc/ssh/sshd_config.d/90-sukuna.conf
  - systemctl restart ssh || systemctl restart ssh.service || true
EOF_USER2

  printf '#cloud-config\n' > "$VENDOR_FILE"
  chmod 600 "$META_FILE" "$USERDATA_FILE" "$VENDOR_FILE"
}

create_seed_iso(){
  if [[ -f "$SEED_ISO" && -s "$SEED_ISO" ]]; then
    "$QEMU_IMG_PATH" info "$SEED_ISO" >/dev/null 2>&1 || true
  fi
  rm -f -- "$SEED_ISO.part"

  if have cloud-localds; then
    cloud-localds "$SEED_ISO.part" "$USERDATA_FILE" "$META_FILE" >/dev/null
  elif have xorriso; then
    xorriso -as mkisofs -quiet -volid cidata -joliet -rock \
      -output "$SEED_ISO.part" "$USERDATA_FILE" "$META_FILE" >/dev/null 2>&1
  elif have genisoimage; then
    genisoimage -quiet -output "$SEED_ISO.part" -volid cidata -joliet -rock "$USERDATA_FILE" "$META_FILE" >/dev/null
  else
    die 'No cloud-init seed ISO tool available (cloud-localds/xorriso/genisoimage).'
  fi
  [[ -s "$SEED_ISO.part" ]] || die 'Failed to create cloud-init seed ISO.'
  mv -f -- "$SEED_ISO.part" "$SEED_ISO"
  chmod 600 "$SEED_ISO"
  ok 'Cloud-init seed created.'
}

find_uefi(){
  local i
  for i in "${!OVMF_CODE_CANDIDATES[@]}"; do
    if [[ -f "${OVMF_CODE_CANDIDATES[$i]}" && -f "${OVMF_VARS_CANDIDATES[$i]}" ]]; then
      printf '%s|%s\n' "${OVMF_CODE_CANDIDATES[$i]}" "${OVMF_VARS_CANDIDATES[$i]}"
      return 0
    fi
  done
  return 1
}

prepare_uefi(){
  local pair code vars
  pair=$(find_uefi || true)
  [[ -n "$pair" ]] || return 1
  code=${pair%%|*}; vars=${pair#*|}
  if [[ ! -f "$VM_DIR/OVMF_VARS.fd" ]]; then
    cp -- "$vars" "$VM_DIR/OVMF_VARS.fd"
    chmod 600 "$VM_DIR/OVMF_VARS.fd"
  fi
  printf '%s\n' "$code"
}

build_qemu_cmd(){
  local ram="$1" cpus="$2" kvm_flag="$3" cpu_model
  if [[ -n "${SUKUNA_QEMU_CPU_MODEL:-}" ]]; then
    cpu_model="$SUKUNA_QEMU_CPU_MODEL"
  elif [[ "$kvm_flag" == kvm ]]; then
    cpu_model=host
  else
    cpu_model=max
  fi
  local -a qemu=(
    "$QEMU_PATH"
    -name "$VM_NAME"
    -machine "q35,accel=${kvm_flag}"
    -cpu "$cpu_model"
    -smp "$cpus"
    -m "${ram}M"
    -nodefaults
    -no-user-config
    -display none
    -serial "file:$CONSOLE_LOG"
    -monitor none
    -device virtio-rng-pci
    -drive "if=virtio,format=qcow2,file=$DISK_IMG,cache=none,aio=threads"
    -drive "if=virtio,format=raw,readonly=on,file=$SEED_ISO"
    -netdev "user,id=n1,hostfwd=tcp:0.0.0.0:${HOST_SSH_PORT}-:22"
    -device virtio-net-pci,netdev=n1
    -qmp "unix:$QMP_SOCK,server=on,wait=off"
    -pidfile "$PID_FILE"
  )

  local uefi
  uefi=$(prepare_uefi || true)
  if [[ -n "$uefi" ]]; then
    qemu+=( -drive "if=pflash,format=raw,readonly=on,file=$uefi" \
            -drive "if=pflash,format=raw,file=$VM_DIR/OVMF_VARS.fd" )
  fi

  printf '%q ' "${qemu[@]}"
}

start_vm(){
  local ram="$1" cpus="$2" accel="$3"
  : > "$QEMU_LOG"
  : > "$CONSOLE_LOG"
  rm -f -- "$PID_FILE" "$QMP_SOCK"

  if ! port_free; then
    die "Host TCP port $HOST_SSH_PORT is already in use. Set SUKUNA_SSH_PORT=<free-port>."
  fi

  local cmd
  cmd=$(build_qemu_cmd "$ram" "$cpus" "$accel")
  log "Starting QEMU with $ram MiB RAM / $cpus vCPU / accel=$accel ..."
  bash -c "exec $cmd" >>"$QEMU_LOG" 2>&1 &
  local launcher_pid=$!
  disown "$launcher_pid" 2>/dev/null || true

  local elapsed=0
  while (( elapsed < BOOT_TIMEOUT )); do
    if pid_running; then
      ok 'QEMU process started and identity verified.'
      return
    fi
    if ! kill -0 "$launcher_pid" 2>/dev/null && [[ ! -s "$PID_FILE" ]]; then
      tail -n 40 "$QEMU_LOG" >&2 || true
      die 'QEMU exited before its PID could be verified.'
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  tail -n 60 "$QEMU_LOG" >&2 || true
  die "QEMU did not become ready within ${BOOT_TIMEOUT}s."
}

wait_for_ssh(){
  local elapsed=0
  log "Waiting for guest SSH on port $HOST_SSH_PORT ..."
  while (( elapsed < SSH_TIMEOUT )); do
    if ! pid_running; then
      tail -n 80 "$QEMU_LOG" >&2 || true
      die 'QEMU stopped while waiting for guest SSH.'
    fi
    if bash -c "</dev/tcp/127.0.0.1/$HOST_SSH_PORT" >/dev/null 2>&1; then
      ok "Guest SSH port is accepting TCP connections."
      return
    fi
    sleep 2
    ((elapsed+=2))
  done
  warn 'QEMU is running, but guest SSH did not open before timeout.'
  warn 'Cloud-init may still be provisioning. Check console log: '
  warn "$CONSOLE_LOG"
}

print_result(){
  local password
  password=$(awk -F= '/^SUKUNA_VM_PASSWORD=/{print $2; exit}' "$RUN_DIR/credentials.txt")
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -n "$ip" ]] || ip='YOUR_SERVER_IP'

  printf '\n%b============================================================%b\n' "$CYAN" "$RESET"
  printf '%b  SUKUNA V7 SERVER IS BOOTING / RUNNING%b\n' "$GREEN" "$RESET"
  printf '%b============================================================%b\n' "$CYAN" "$RESET"
  printf 'Host IP      : %s\n' "$ip"
  printf 'SSH command  : ssh -p %s %s@%s\n' "$HOST_SSH_PORT" "$VM_USER" "$ip"
  printf 'Password     : %s\n' "$password"
  printf 'VM name      : %s\n' "$VM_NAME"
  printf 'PID file     : %s\n' "$PID_FILE"
  printf 'QEMU log     : %s\n' "$QEMU_LOG"
  printf 'Console log  : %s\n' "$CONSOLE_LOG"
  printf '\n%bImportant:%b the guest is reached through host port %s. Keep that port open in your VPS firewall/security group.\n' "$YELLOW" "$RESET" "$HOST_SSH_PORT"
  printf '%b============================================================%b\n' "$CYAN" "$RESET"
}

main(){
  printf '%bDXD LABS SUKUNA V7 BOOT EDITION%b\n' "$MAGENTA" "$RESET"
  printf 'One-command Ubuntu 22.04 QEMU/KVM server bootstrap.\n\n'
  require_root
  validate_inputs
  ensure_dependencies
  ensure_python
  safe_dirs
  lock_instance
  generate_credentials
  prepare_base_image
  prepare_guest_disk
  prepare_cloud_init
  create_seed_iso

  read -r ram cpus < <(calc_resources)
  local accel='tcg'
  if kvm_ok; then
    accel='kvm'
    ok 'Hardware KVM is available.'
  else
    warn 'Hardware KVM is unavailable; falling back to QEMU TCG.'
  fi

  if pid_running; then
    ok 'SUKUNA VM is already running.'
  else
    start_vm "$ram" "$cpus" "$accel"
  fi
  wait_for_ssh
  print_result
  trap - EXIT
}

main "$@"
