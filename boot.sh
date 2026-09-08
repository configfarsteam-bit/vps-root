#!/usr/bin/env bash
# ============================================================================
# 👹 DXD LABS PREMIUM VPS DASHBOARD — SUKUNA V6 ULTIMATE
# Hardened Ubuntu 22.04 amd64 QEMU/KVM VM manager
#
# Highlights:
#   - strict Bash + private data tree + JSON schema validation
#   - cgroup/affinity-aware RAM & CPU ceilings
#   - real KVM_CREATE_VM capability test with safe TCG fallback
#   - pidfd-based process signalling + executable/argv identity checks
#   - QMP peer verification (SO_PEERCRED) + monitoring helpers
#   - atomic config/state writes + flock lifecycle locks
#   - HTTPS Ubuntu cloud-image download + SHA256SUMS verification
#   - standalone qcow2 guest disk (no base backing dependency)
#   - cloud-init SSH-key/password provisioning, optional root SSH
#   - optional QEMU Guest Agent (virtio-serial)
#   - optional UEFI/OVMF when host firmware files are available
#   - user networking with optional passt backend (auto/user fallback)
#   - snapshots, offline backup/export, restore, disk checks/repair
#   - health checks, stale runtime recovery, log rotation
#   - optional user-level systemd autostart
#   - real serial console in foreground mode
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C.UTF-8

readonly SCRIPT_VERSION="6.0.0"
readonly SCHEMA_VERSION=6
readonly GUEST_SSH_PORT=22
readonly UBUNTU_SERIES="jammy"
readonly UBUNTU_CLOUD_URL_DEFAULT="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
readonly UBUNTU_SUMS_URL_DEFAULT="https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"
readonly QEMU_BIN="/usr/bin/qemu-system-x86_64"
readonly QEMU_IMG="/usr/bin/qemu-img"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly SHUTDOWN_TIMEOUT="${SUKUNA_SHUTDOWN_TIMEOUT:-90}"

DXD_HOME="${DXD_HOME:-${XDG_DATA_HOME:-${HOME:?HOME is required}/.local/share}/dxd-sukuna-v6}"
DXD_HOME="${DXD_HOME%/}"
readonly DXD_HOME
readonly BASE_DIR="$DXD_HOME/base"
readonly VM_DIR="$DXD_HOME/vm"
readonly RUN_DIR="$DXD_HOME/run"
readonly LOG_DIR="$DXD_HOME/log"
readonly TMP_DIR="$DXD_HOME/tmp"
readonly BACKUP_DIR="$DXD_HOME/backups"
readonly SNAPSHOT_DIR="$DXD_HOME/snapshots"
readonly CONFIG_FILE="$DXD_HOME/config.json"
readonly STATE_FILE="$RUN_DIR/state.json"
readonly LOCK_FILE="$DXD_HOME/manager.lock"
readonly VM_LOCK_FILE="$RUN_DIR/vm.lock"
readonly PID_FILE="$RUN_DIR/qemu.pid"
readonly QMP_SOCKET="$RUN_DIR/qmp.sock"
readonly GA_SOCKET="$RUN_DIR/ga.sock"
readonly CONSOLE_LOG="$LOG_DIR/console.log"
readonly QEMU_LOG="$LOG_DIR/qemu.log"
readonly BASE_IMAGE="$BASE_DIR/ubuntu-jammy-current.qcow2"
readonly BASE_SHA="$BASE_DIR/ubuntu-jammy-current.sha256"
readonly DISK_IMAGE="$VM_DIR/sukuna.qcow2"
readonly SEED_ISO="$VM_DIR/sukuna-seed.iso"
readonly OVMF_VARS="$VM_DIR/OVMF_VARS.fd"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'; RESET=$'\033[0m'

log(){ printf '%b[%s]%b %s\n' "$BLUE" "INFO" "$RESET" "$*"; }
ok(){ printf '%b[%s]%b %s\n' "$GREEN" " OK " "$RESET" "$*"; }
warn(){ printf '%b[%s]%b %s\n' "$YELLOW" "WARN" "$RESET" "$*" >&2; }
err(){ printf '%b[%s]%b %s\n' "$RED" "ERR " "$RESET" "$*" >&2; }
die(){ err "$*"; exit 1; }
trap 'rc=$?; err "Unexpected failure at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND} (rc=$rc)"; exit "$rc"' ERR
trap 'printf "\nInterrupted. Use status/stop from another terminal if QEMU is running.\n" >&2; exit 130' INT

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

secure_path(){
  local p="$1" cur="/" piece mode uid
  [[ "$p" = /* ]] || die "DXD_HOME must be absolute"
  [[ "$p" != / && "$p" != *$'\n'* && "$p" != *$'\r'* && "$p" != *$'\t'* ]] || die "Unsafe DXD_HOME"
  [[ "$p" != *"/../"* && "$p" != */.. ]] || die "Path traversal is not allowed"
  IFS='/' read -r -a _parts <<< "${p#/}"
  for piece in "${_parts[@]}"; do
    [[ -n "$piece" ]] || continue
    cur="${cur%/}/$piece"
    [[ ! -L "$cur" ]] || die "Symlink path component refused: $cur"
    if [[ -e "$cur" ]]; then
      [[ -d "$cur" ]] || die "Non-directory path component: $cur"
      uid=$(stat -c '%u' -- "$cur")
      mode=$(stat -c '%a' -- "$cur")
      [[ "$uid" == "$(id -u)" || "$uid" == "0" ]] || die "Untrusted path owner: $cur"
      (( 10#$mode % 10 < 8 && (10#$mode/10)%10 < 8 )) || die "Group/world writable path component: $cur"
    fi
  done
}

ensure_dirs(){
  local d
  for d in "$DXD_HOME" "$BASE_DIR" "$VM_DIR" "$RUN_DIR" "$LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$SNAPSHOT_DIR"; do
    mkdir -p -- "$d"; chmod 700 -- "$d"
  done
  secure_path "$DXD_HOME"
}

secure_file(){
  local f="$1" uid links
  [[ -e "$f" ]] || return 0
  [[ ! -L "$f" ]] || die "Symlink refused: $f"
  [[ -f "$f" || -S "$f" ]] || die "Unexpected file type: $f"
  uid=$(stat -c '%u' -- "$f")
  links=$(stat -c '%h' -- "$f")
  [[ "$uid" == "$(id -u)" || "$uid" == "0" ]] || die "Unsafe owner: $f"
  if [[ -f "$f" ]]; then (( links == 1 )) || die "Hard-linked file refused: $f"; chmod 600 -- "$f"; fi
}

json_atomic(){
  local target="$1" payload="$2" dir tmp
  dir=$(dirname -- "$target")
  mkdir -p -- "$dir"; chmod 700 -- "$dir"
  tmp=$(mktemp "$dir/.atomic.XXXXXX")
  chmod 600 -- "$tmp"
  printf '%s\n' "$payload" >"$tmp"
  sync -f "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$target"
  secure_file "$target"
}

cfg_get(){
  local key="$1"
  "$PYTHON_BIN" - "$CONFIG_FILE" "$key" <<'PY'
import json,sys
p,k=sys.argv[1:]
with open(p,encoding='utf-8') as f:d=json.load(f)
v=d
for part in k.split('.'):
    v=v[part]
if isinstance(v,bool): print('true' if v else 'false')
elif isinstance(v,(dict,list)): print(json.dumps(v,separators=(',',':')))
elif v is None: print('')
else: print(v)
PY
}

config_write(){
  local key="$1" value="$2" type="$3"
  "$PYTHON_BIN" - "$CONFIG_FILE" "$key" "$value" "$type" <<'PY'
import json,sys,tempfile,os
p,k,v,t=sys.argv[1:]
with open(p,encoding='utf-8') as f:d=json.load(f)
if t=='int': d[k]=int(v)
elif t=='bool': d[k]=(v=='true')
else: d[k]=v
fd,tmp=tempfile.mkstemp(prefix='.cfg.',dir=os.path.dirname(p),text=True); os.fchmod(fd,0o600)
with os.fdopen(fd,'w',encoding='utf-8') as f:
    json.dump(d,f,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(tmp,p)
PY
  secure_file "$CONFIG_FILE"
}

write_default_config(){
  [[ -e "$CONFIG_FILE" ]] && return 0
  "$PYTHON_BIN" - "$CONFIG_FILE" "$UBUNTU_CLOUD_URL_DEFAULT" "$UBUNTU_SUMS_URL_DEFAULT" <<'PY'
import json,sys,os,tempfile
p,url,sums=sys.argv[1:]
d={"version":6,"vm_name":"dxd-ubuntu22","hostname":"dxd-vm","guest_user":"dxd","memory_mb":2048,"vcpus":2,"disk_gb":20,"ssh_host_port":2222,"ssh_bind":"127.0.0.1","ssh_key":"","password_hash":"","root_ssh":False,"guest_agent":True,"uefi":False,"network_backend":"auto","cloud_url":url,"sums_url":sums}
os.makedirs(os.path.dirname(p),exist_ok=True)
fd,tmp=tempfile.mkstemp(prefix='.cfg.',dir=os.path.dirname(p),text=True); os.fchmod(fd,0o600)
with os.fdopen(fd,'w',encoding='utf-8') as f:
 json.dump(d,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
os.replace(tmp,p)
PY
  secure_file "$CONFIG_FILE"
}

validate_config(){
  "$PYTHON_BIN" - "$CONFIG_FILE" <<'PY'
import json,sys,re,ipaddress,urllib.parse
p=sys.argv[1]
with open(p,encoding='utf-8') as f:d=json.load(f)
req={
'version':int,'vm_name':str,'hostname':str,'guest_user':str,'memory_mb':int,'vcpus':int,'disk_gb':int,
'ssh_host_port':int,'ssh_bind':str,'ssh_key':str,'password_hash':str,'root_ssh':bool,'guest_agent':bool,'uefi':bool,
'network_backend':str,'cloud_url':str,'sums_url':str}
if set(d)!=set(req): raise SystemExit('config schema mismatch')
for k,t in req.items():
    if type(d[k]) is not t: raise SystemExit(f'{k}: invalid type')
if d['version']!=6: raise SystemExit('unsupported config version')
for k,pat in [('vm_name',r'[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}'),('hostname',r'[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}'),('guest_user',r'[a-z_][a-z0-9_-]{0,31}')]:
    if not re.fullmatch(pat,d[k]): raise SystemExit(f'invalid {k}')
if d['guest_user']=='root': raise SystemExit('guest_user cannot be root')
if not 256<=d['memory_mb']<=1048576: raise SystemExit('memory_mb out of range')
if not 1<=d['vcpus']<=256: raise SystemExit('vcpus out of range')
if not 4<=d['disk_gb']<=65536: raise SystemExit('disk_gb out of range')
if not 1024<=d['ssh_host_port']<=65535: raise SystemExit('ssh_host_port out of range')
try: ipaddress.ip_address(d['ssh_bind'])
except ValueError: raise SystemExit('ssh_bind must be a valid IPv4/IPv6 address')
if d['ssh_bind'] not in ('127.0.0.1','0.0.0.0','::1','::'): raise SystemExit('ssh_bind must be loopback or wildcard')
if '\n' in d['ssh_key'] or '\r' in d['ssh_key']: raise SystemExit('ssh_key contains newline')
if d['ssh_key'] and not re.match(r'^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)|sk-[^ ]+) ',d['ssh_key']): raise SystemExit('invalid OpenSSH public key')
if d['password_hash'] and not re.fullmatch(r'\$(?:6|y)\$[^\n]{1,200}',d['password_hash']): raise SystemExit('invalid password hash')
if d['network_backend'] not in ('auto','passthrough','user','passthrough-only'): raise SystemExit('invalid network_backend')
for k in ('cloud_url','sums_url'):
    u=urllib.parse.urlparse(d[k])
    if u.scheme!='https' or not u.netloc: raise SystemExit(f'{k} must use HTTPS')
PY
}

write_state(){
  local state="$1" pid="${2:-}" detail="${3:-}"
  json_atomic "$STATE_FILE" "$(printf '{\n  \"state\": %s,\n  \"pid\": %s,\n  \"updated\": %s,\n  \"detail\": %s\n}\n' \
    "$(printf '%s' "$state" | "$PYTHON_BIN" -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "${pid:-null}" "$(date +%s)" "$(printf '%s' "$detail" | "$PYTHON_BIN" -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")"
}

with_manager_lock(){
  exec {MFD}>"$LOCK_FILE"; chmod 600 -- "$LOCK_FILE"; flock -x "$MFD"; "$@"
}
with_vm_lock(){
  exec {VFD}>"$VM_LOCK_FILE"; chmod 600 -- "$VM_LOCK_FILE"; flock -x "$VFD"; "$@"
}

host_mem_kb(){ awk '/^MemTotal:/ {print $2;exit}' /proc/meminfo; }
cgroup_mem_limit_bytes(){
  local v
  if [[ -r /sys/fs/cgroup/memory.max ]]; then v=$(cat /sys/fs/cgroup/memory.max); [[ "$v" != max && "$v" =~ ^[0-9]+$ ]] && { echo "$v"; return; }; fi
  if [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then v=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes); [[ "$v" =~ ^[0-9]+$ && "$v" -lt 9223372036854771712 ]] && { echo "$v"; return; }; fi
  echo 0
}
cpu_quota(){
  local q p
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then read -r q p < /sys/fs/cgroup/cpu.max || true; [[ "$q" =~ ^[0-9]+$ && "$p" =~ ^[0-9]+$ && "$p" -gt 0 ]] && { awk -v q="$q" -v p="$p" 'BEGIN{printf "%.3f",q/p}'; return; }; fi
  if [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]]; then q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us); p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us); [[ "$q" =~ ^[0-9]+$ && "$p" =~ ^[0-9]+$ && "$q" -gt 0 && "$p" -gt 0 ]] && { awk -v q="$q" -v p="$p" 'BEGIN{printf "%.3f",q/p}'; return; }; fi
  echo 0
}
affinity_cpus(){
  if command -v taskset >/dev/null 2>&1; then
    taskset -pc $$ 2>/dev/null | awk -F': ' '{print $2}' | tr ',' '\n' | awk -F'-' '{n+=($2==""?1:$2-$1+1)} END{print n+0}' || nproc
  else nproc; fi
}
available_resources(){
  local kb lim quota aff safe_mem safe_cpu
  kb=$(host_mem_kb); lim=$(cgroup_mem_limit_bytes)
  if (( lim>0 && lim/1024<kb )); then kb=$((lim/1024)); fi
  safe_mem=$((kb*80/100)); (( safe_mem>1048576 )) && safe_mem=$((safe_mem-1048576)); (( safe_mem<262144 )) && safe_mem=262144
  quota=$(cpu_quota); aff=$(affinity_cpus)
  if awk -v q="$quota" 'BEGIN{exit !(q>0)}'; then safe_cpu=$(awk -v q="$quota" -v a="$aff" 'BEGIN{x=int(q);if(x<1)x=1;if(x>a)x=a;print x}'); else safe_cpu="$aff"; fi
  printf '%s\t%s\n' "$safe_mem" "$safe_cpu"
}

human_bytes(){ "$PYTHON_BIN" - "$1" <<'PY'
import sys
x=float(sys.argv[1]);u=['B','KiB','MiB','GiB','TiB'];i=0
while x>=1024 and i<len(u)-1:x/=1024;i+=1
print(f'{x:.1f} {u[i]}')
PY
}

kvm_available(){
  [[ -r /dev/kvm && -w /dev/kvm ]] || return 1
  "$PYTHON_BIN" <<'PY'
import os,fcntl
fd=-1;vm=-1
try:
 fd=os.open('/dev/kvm',os.O_RDWR|os.O_CLOEXEC)
 if fcntl.ioctl(fd,0xAE00,0)!=12: raise OSError()
 vm=fcntl.ioctl(fd,0xAE01,0)
except Exception: raise SystemExit(1)
finally:
 if vm>=0:
  try: os.close(vm)
  except OSError: pass
 if fd>=0:
  try: os.close(fd)
  except OSError: pass
PY
}

pid_identity(){
  local pid="$1"; [[ "$pid" =~ ^[0-9]+$ && -d "/proc/$pid" ]] || return 1
  "$PYTHON_BIN" - "$pid" "$DXD_HOME" "$(cfg_get vm_name)" <<'PY'
import os,sys
pid=int(sys.argv[1]);root=sys.argv[2];vm=sys.argv[3]
try:
 if os.path.realpath(f'/proc/{pid}/exe')!='/usr/bin/qemu-system-x86_64': raise SystemExit(1)
 if os.stat(f'/proc/{pid}').st_uid != os.geteuid(): raise SystemExit(1)
 a=[x.decode('utf-8','replace') for x in open(f'/proc/{pid}/cmdline','rb').read().split(b'\0') if x]
 if '-name' not in a or vm not in a: raise SystemExit(1)
 if '-qmp' not in a or f'unix:{root}/run/qmp.sock,server=on,wait=off' not in a[a.index('-qmp')+1]: raise SystemExit(1)
 if '-drive' not in a or not any(root+'/vm/sukuna.qcow2' in x for x in a if x.startswith('file=')): raise SystemExit(1)
except Exception: raise SystemExit(1)
raise SystemExit(0)
PY
}

qemu_running(){
  [[ -s "$PID_FILE" ]] || return 1
  local p; p=$(cat -- "$PID_FILE" 2>/dev/null || true)
  [[ "$p" =~ ^[1-9][0-9]*$ ]] || return 1
  pid_identity "$p"
}

clear_stale_runtime(){
  if [[ -e "$PID_FILE" ]] && ! qemu_running; then rm -f -- "$PID_FILE"; fi
  if [[ -e "$QMP_SOCKET" ]] && ! qemu_running; then rm -f -- "$QMP_SOCKET"; fi
  if [[ -e "$GA_SOCKET" ]] && ! qemu_running; then rm -f -- "$GA_SOCKET"; fi
}

qmp_cmd(){
  local method="$1" args='{}'; shift || true
  [[ -S "$QMP_SOCKET" && -s "$PID_FILE" ]] || die "QMP unavailable"
  local pid; pid=$(cat "$PID_FILE")
  [[ "$pid" =~ ^[0-9]+$ ]] || die "Invalid PID file"
  "$PYTHON_BIN" - "$QMP_SOCKET" "$pid" "$method" "${1:-$args}" <<'PY'
import json,os,socket,struct,sys,time
path,pid_s,method,arg=sys.argv[1:];expected=int(pid_s)
def line(s,timeout=5):
 s.settimeout(timeout);b=b''
 while b'\n' not in b:
  x=s.recv(4096)
  if not x: raise RuntimeError('QMP disconnected')
  b+=x
 x=b.split(b'\n',1)[0];return json.loads(x)
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.settimeout(5);s.connect(path)
cp=s.getsockopt(socket.SOL_SOCKET,socket.SO_PEERCRED,12);peer,uid,gid=struct.unpack('3i',cp)
if peer!=expected or uid!=os.geteuid(): raise SystemExit('QMP peer identity mismatch')
g=line(s)
if 'QMP' not in g: raise SystemExit('invalid QMP greeting')
s.sendall(b'{"execute":"qmp_capabilities"}\n');line(s)
obj={'execute':method}
if arg: obj['arguments']=json.loads(arg)
s.sendall((json.dumps(obj,separators=(',',':'))+'\n').encode())
dead=time.monotonic()+10
while time.monotonic()<dead:
 r=line(s)
 if 'return' in r or 'error' in r:
  print(json.dumps(r,separators=(',',':')));break
else: raise SystemExit('QMP timeout')
s.close()
PY
}

probe_net_backend(){
  local requested qhelp
  requested=$(cfg_get network_backend)
  if [[ "$requested" == user ]]; then echo user; return; fi
  qhelp="$($QEMU_BIN -netdev help 2>/dev/null || true)"
  if grep -qE '(^|[[:space:]])passt([[:space:]]|$)' <<<"$qhelp" && command -v passt >/dev/null 2>&1; then
    [[ "$requested" != passthrough-only ]] || { echo passt; return; }
    echo passt
  else
    [[ "$requested" == passthrough-only ]] && die 'passthrough-only requested but this QEMU does not advertise passt'
    echo user
  fi
}

ensure_base(){
  mkdir -p -- "$BASE_DIR"; chmod 700 -- "$BASE_DIR"
  if [[ -f "$BASE_IMAGE" && -f "$BASE_SHA" ]]; then
    (cd "$BASE_DIR" && sha256sum --check --status "$(basename "$BASE_SHA")") || die 'Cached base SHA256 verification failed'
    "$QEMU_IMG" info --output=json -- "$BASE_IMAGE" >/dev/null || die 'Cached base image invalid'
    "$QEMU_IMG" check --quiet -- "$BASE_IMAGE" >/dev/null || die 'Cached base image failed qemu-img check'
    return
  fi
  rm -f -- "$BASE_IMAGE" "$BASE_SHA"
  local img_tmp sum_tmp expected
  img_tmp=$(mktemp "$BASE_DIR/.img.XXXXXX"); sum_tmp=$(mktemp "$BASE_DIR/.sums.XXXXXX")
  trap 'rm -f -- "$img_tmp" "$sum_tmp"' RETURN
  local url sums
  url=$(cfg_get cloud_url); sums=$(cfg_get sums_url)
  log "Downloading Ubuntu $UBUNTU_SERIES cloud image and SHA256SUMS"
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 5 --connect-timeout 20 --max-time 3600 -o "$sum_tmp" "$sums"
  expected=$(awk -v n="$(basename "$url")" '$0 ~ "[ ]\\*?"n"$" && $1 ~ /^[A-Fa-f0-9]{64}$/ {print tolower($1)}' "$sum_tmp" | head -n1)
  [[ -n "$expected" ]] || die 'Could not find exact image checksum in SHA256SUMS'
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 5 --connect-timeout 20 --max-time 3600 -o "$img_tmp" "$url"
  printf '%s  %s\n' "$expected" "$img_tmp" | sha256sum --check --status || die 'Ubuntu image SHA256 mismatch'
  "$QEMU_IMG" info --output=json -- "$img_tmp" >/dev/null || die 'Downloaded file is not a valid QEMU image'
  "$QEMU_IMG" check --quiet -- "$img_tmp" >/dev/null || die 'Downloaded image failed qemu-img check'
  "$QEMU_IMG" convert -p -O qcow2 -o compression_type=zstd -- "$img_tmp" "$BASE_IMAGE.tmp"
  mv -f -- "$BASE_IMAGE.tmp" "$BASE_IMAGE"
  printf '%s  %s\n' "$expected" "$(basename "$BASE_IMAGE")" >"$BASE_SHA"
  chmod 600 -- "$BASE_IMAGE" "$BASE_SHA"
  rm -f -- "$img_tmp" "$sum_tmp"; trap - RETURN
  ok 'Verified Ubuntu base cache is ready'
}

ensure_disk(){
  ensure_base
  if [[ -f "$DISK_IMAGE" ]]; then
    "$QEMU_IMG" check --quiet -- "$DISK_IMAGE" >/dev/null || die 'VM disk failed qemu-img check'; return
  fi
  local disk_gb tmp
  disk_gb=$(cfg_get disk_gb); tmp="$DISK_IMAGE.tmp.$$"
  rm -f -- "$tmp"
  "$QEMU_IMG" convert -p -O qcow2 -S 4k -- "$BASE_IMAGE" "$tmp"
  "$QEMU_IMG" resize -- "$tmp" "${disk_gb}G" >/dev/null
  "$QEMU_IMG" check --quiet -- "$tmp" >/dev/null
  mv -f -- "$tmp" "$DISK_IMAGE"; secure_file "$DISK_IMAGE"
  ok "Created standalone $disk_gb GiB VM disk"
}

make_password_hash(){
  local p1 p2
  read -r -s -p 'New Ubuntu password (12+ chars): ' p1; printf '\n'
  (( ${#p1} >= 12 && ${#p1} <= 1024 )) || die 'Password must be 12–1024 characters'
  read -r -s -p 'Repeat password: ' p2; printf '\n'
  [[ "$p1" == "$p2" ]] || die 'Passwords do not match'
  printf '%s\n' "$p1" | openssl passwd -6 -stdin
  unset p1 p2
}

ensure_seed(){
  local user key pwh rootssh ga
  user=$(cfg_get guest_user); key=$(cfg_get ssh_key); pwh=$(cfg_get password_hash); rootssh=$(cfg_get root_ssh); ga=$(cfg_get guest_agent)
  local td ud md nd
  td=$(mktemp -d "$TMP_DIR/seed.XXXXXX"); chmod 700 -- "$td"; ud="$td/user-data"; md="$td/meta-data"; nd="$td/network-config"
  "$PYTHON_BIN" - "$ud" "$md" "$nd" "$user" "$key" "$pwh" "$rootssh" "$ga" "$(cfg_get hostname)" <<'PY'
import json,sys
ud,md,nd,user,key,pwh,rootssh,ga,hostname=sys.argv[1:]
rootssh=rootssh=='true'; ga=ga=='true'
users=['default',{'name':user,'groups':['sudo'],'shell':'/bin/bash','sudo':['ALL=(ALL) NOPASSWD:ALL'],'lock_passwd':not bool(pwh)}]
if key: users[1]['ssh_authorized_keys']=[key]
if pwh: users[1]['passwd']=pwh
if rootssh:
 root={'name':'root','lock_passwd':not bool(pwh)}
 if key: root['ssh_authorized_keys']=[key]
 if pwh: root['passwd']=pwh
 users.append(root)
extra={
 'hostname':hostname,'manage_etc_hosts':True,'users':users,'ssh_pwauth':bool(pwh),'disable_root':not rootssh,
 'ssh_deletekeys':True,'package_update':True,'packages':['qemu-guest-agent','curl','ca-certificates','sudo','nano','git','htop','unzip'],
 'write_files':[{'path':'/etc/ssh/sshd_config.d/00-sukuna.conf','permissions':'0600','owner':'root:root','content':('PermitRootLogin '+('yes' if rootssh else 'no')+'\nPasswordAuthentication '+('yes' if pwh else 'no')+'\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\n')}],
 'runcmd':[
   ['bash','-lc','systemctl enable --now ssh || true'],
   ['bash','-lc','systemctl enable --now qemu-guest-agent || true' if ga else 'true'],
   ['bash','-lc','sshd -t && systemctl restart ssh || true'],
   ['bash','-lc','printf "SUKUNA_CLOUD_INIT_OK\\n" > /var/log/sukuna-cloud-init-ok']
 ],
 'final_message':'SUKUNA cloud-init finished after $UPTIME seconds.'
}
with open(ud,'w',encoding='utf-8') as f:f.write('#cloud-config\n'+json.dumps(extra,indent=2)+'\n')
with open(md,'w',encoding='utf-8') as f:json.dump({'instance-id':'sukuna-v6','local-hostname':hostname},f);f.write('\n')
with open(nd,'w',encoding='utf-8') as f:f.write('version: 2\nethernets:\n  ens3:\n    dhcp4: true\n    dhcp6: false\n')
PY
  rm -f -- "$SEED_ISO"
  if command -v cloud-localds >/dev/null 2>&1; then cloud-localds --network-config="$nd" "$SEED_ISO" "$ud" "$md"
  elif command -v genisoimage >/dev/null 2>&1; then genisoimage -quiet -volid CIDATA -joliet -rock -output "$SEED_ISO" "$ud" "$md" "$nd"
  else rm -rf -- "$td"; die 'cloud-localds or genisoimage is required'; fi
  rm -rf -- "$td"; secure_file "$SEED_ISO"
}

uefi_available(){
  [[ "$(cfg_get uefi)" == true ]] || return 1
  local code
  for code in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/x64/OVMF_CODE.fd; do [[ -r "$code" ]] && { echo "$code"; return 0; }; done
  return 1
}

prepare_uefi_vars(){
  local code; code=$(uefi_available) || return 1
  [[ -f "$OVMF_VARS" ]] && return 0
  local vars
  for vars in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/x64/OVMF_VARS.fd; do
    if [[ -f "$vars" ]]; then cp --reflink=auto -- "$vars" "$OVMF_VARS"; chmod 600 -- "$OVMF_VARS"; return 0; fi
  done
  warn "UEFI requested but OVMF_VARS template is missing; falling back to BIOS"
  return 1
}

build_qemu_args(){
  local mem cpu hp bind backend code
  mem=$(cfg_get memory_mb); cpu=$(cfg_get vcpus); hp=$(cfg_get ssh_host_port); bind=$(cfg_get ssh_bind); backend=$(probe_net_backend)
  QEMU_ARGS=(-name "$(cfg_get vm_name)" -uuid "$(vm_uuid)" -machine q35 -smp "$cpu" -m "$mem" -nodefaults -display none -monitor none -boot order=c)
  if kvm_available; then QEMU_ARGS+=(-enable-kvm -cpu host); else QEMU_ARGS+=(-accel tcg,thread=multi -cpu max); fi
  QEMU_ARGS+=(-drive "file=$DISK_IMAGE,if=virtio,format=qcow2,cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap")
  QEMU_ARGS+=(-drive "file=$SEED_ISO,media=cdrom,if=virtio,readonly=on,format=raw")
  if [[ "$backend" == passt ]]; then
    QEMU_ARGS+=(-netdev "passt,id=net0,hostfwd=tcp:${bind}:${hp}-:${GUEST_SSH_PORT}" -device virtio-net-pci,netdev=net0)
  else
    QEMU_ARGS+=(-netdev "user,id=net0,hostfwd=tcp:${bind}:${hp}-:${GUEST_SSH_PORT}" -device virtio-net-pci,netdev=net0)
  fi
  QEMU_ARGS+=(-device virtio-rng-pci)
  if [[ "$(cfg_get guest_agent)" == true ]]; then QEMU_ARGS+=(-chardev "socket,id=qga,path=$GA_SOCKET,server=on,wait=off" -device virtio-serial-pci -device virtserialport,chardev=qga,name=org.qemu.guest_agent.0); fi
  if code=$(uefi_available) && prepare_uefi_vars; then QEMU_ARGS+=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$OVMF_VARS"); fi
  QEMU_ARGS+=(-qmp "unix:$QMP_SOCKET,server=on,wait=off" -pidfile "$PID_FILE" -nographic -chardev "stdio,id=con,mux=on,signal=off,logfile=$CONSOLE_LOG,logappend=on" -serial chardev:con -D "$QEMU_LOG" -no-reboot)
}

vm_uuid(){ "$PYTHON_BIN" - "$CONFIG_FILE" <<'PY'
import json,sys,hashlib,uuid
with open(sys.argv[1],encoding='utf-8') as f:d=json.load(f)
print(str(uuid.UUID(bytes=hashlib.sha256(d['vm_name'].encode()).digest()[:16])))
PY
}

check_port(){
  local bind="$1" port="$2"
  "$PYTHON_BIN" - "$bind" "$port" <<'PY'
import socket,sys
b=sys.argv[1];p=int(sys.argv[2]);fam=socket.AF_INET6 if ':' in b else socket.AF_INET
s=socket.socket(fam,socket.SOCK_STREAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
try:s.bind((b,p))
except OSError as e: raise SystemExit(str(e))
s.close()
PY
}

boot_internal(){
  ensure_dirs; validate_config; need_cmd "$QEMU_BIN"; need_cmd "$QEMU_IMG"; need_cmd curl; need_cmd openssl
  clear_stale_runtime; ! qemu_running || die 'VM is already running'
  ensure_base; ensure_disk; ensure_seed
  local maxmem maxcpu mem cpu bind port
  read -r maxmem maxcpu < <(available_resources); mem=$(cfg_get memory_mb); cpu=$(cfg_get vcpus); bind=$(cfg_get ssh_bind); port=$(cfg_get ssh_host_port)
  (( mem*1024<=maxmem )) || die "Configured RAM ${mem} MiB exceeds safe ceiling $((maxmem/1024)) MiB"
  (( cpu<=maxcpu )) || die "Configured vCPUs $cpu exceeds safe ceiling $maxcpu"
  check_port "$bind" "$port" || die "Host TCP port $port is unavailable on $bind"
  if [[ "$bind" != 127.0.0.1 && "$bind" != ::1 ]]; then warn "SSH forward is externally reachable on $bind:$port"; fi
  exec {VM_RUN_FD}>"$VM_LOCK_FILE"; chmod 600 -- "$VM_LOCK_FILE"; flock -x "$VM_RUN_FD"
  build_qemu_args; write_state starting null 'QEMU launch in progress'; rm -f -- "$QMP_SOCKET" "$GA_SOCKET" "$PID_FILE"
  log "Starting $(cfg_get vm_name): ${cpu} vCPU / ${mem} MiB / SSH ${bind}:${port}"
  "${QEMU_BIN}" "${QEMU_ARGS[@]}" &
  local child=$! pid
  for _ in {1..150}; do [[ -s "$PID_FILE" ]] && qemu_running && break; sleep 0.1; done
  if ! qemu_running; then
    kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; clear_stale_runtime; die "QEMU failed to start; inspect $QEMU_LOG"
  fi
  pid=$(cat "$PID_FILE"); write_state running "$pid" 'QEMU verified alive'
  ok "VM running | PID $pid | KVM=$(kvm_available && echo yes || echo no) | network=$(probe_net_backend)"
  printf '%bREAL Ubuntu serial console attached.%b\n' "$CYAN" "$RESET"
  flock -u "$VM_RUN_FD" || true; exec {VM_RUN_FD}>&- || true
  printf '%bSafe exit: sudo poweroff inside guest. Emergency QEMU exit: Ctrl-a x.%b\n' "$YELLOW" "$RESET"
  printf '%bSSH: ssh -p %s %s@%s%b\n' "$MAGENTA" "$port" "$(cfg_get guest_user)" "$([[ "$bind" == 0.0.0.0 ]] && echo '<HOST_IP>' || echo "$bind")" "$RESET"
  wait "$child" || true
  if qemu_running; then warn 'QEMU child returned while verified process remains alive'; else clear_stale_runtime; write_state stopped null 'QEMU exited'; fi
}

stop_internal(){
  local force="${1:-false}"
  if ! qemu_running; then clear_stale_runtime; write_state stopped null 'already stopped'; ok 'VM is not running'; return 0; fi
  log 'Sending ACPI shutdown via QMP'
  qmp_cmd system_powerdown >/dev/null 2>&1 || warn 'QMP ACPI request failed'
  local i
  for ((i=0;i<SHUTDOWN_TIMEOUT;i++)); do qemu_running || { clear_stale_runtime; write_state stopped null 'graceful shutdown'; ok 'VM stopped gracefully'; return 0; }; sleep 1; done
  [[ "$force" == true ]] || die "Graceful stop timed out after ${SHUTDOWN_TIMEOUT}s. Use stop --force."
  local pid; pid=$(cat "$PID_FILE")
  "$PYTHON_BIN" - "$pid" TERM <<'PY'
import os,signal,sys
fd=os.pidfd_open(int(sys.argv[1])); os.pidfd_send_signal(fd,signal.SIGTERM); os.close(fd)
PY
  for _ in {1..15}; do qemu_running || break; sleep 1; done
  if qemu_running; then
    "$PYTHON_BIN" - "$pid" KILL <<'PY'
import os,signal,sys
fd=os.pidfd_open(int(sys.argv[1])); os.pidfd_send_signal(fd,getattr(signal,'SIG'+sys.argv[2])); os.close(fd)
PY
  fi
  for _ in {1..10}; do qemu_running || break; sleep 1; done
  qemu_running && die 'QEMU survived SIGKILL; inspect kernel/storage state'
  clear_stale_runtime; write_state stopped null 'forced shutdown'; ok 'VM force-stopped'
}

status_internal(){
  validate_config
  echo "══════════════════════════════════════════════════════════════"
  echo " 👹 SUKUNA V$SCRIPT_VERSION — STATUS"
  echo " VM:       $(cfg_get vm_name)"
  echo " Hostname: $(cfg_get hostname)"
  if qemu_running; then
    local pid; pid=$(cat "$PID_FILE")
    echo " State:    RUNNING (PID $pid)"
    qmp_cmd query-status || true
    echo " KVM:      $(kvm_available && echo ENABLED || echo DISABLED/TCG)"
    echo " Network:  $(probe_net_backend)"
    qmp_cmd query-kvm 2>/dev/null || true
    echo " CPU info: $(qmp_cmd query-cpus-fast 2>/dev/null || true)"
    echo " Block:    $(qmp_cmd query-block 2>/dev/null || true)"
  else
    echo " State:    STOPPED"
  fi
  [[ -f "$STATE_FILE" ]] && { echo " State file:"; cat "$STATE_FILE"; }
  echo " SSH:      $(cfg_get ssh_bind):$(cfg_get ssh_host_port) -> guest:22"
  echo " Root SSH: $(cfg_get root_ssh)"
  echo " UEFI:     $(cfg_get uefi)"
  echo " Agent:    $(cfg_get guest_agent)"
}

resources_internal(){
  local maxmem maxcpu quota lim host
  read -r maxmem maxcpu < <(available_resources)
  host=$(( $(host_mem_kb)/1024 )); lim=$(cgroup_mem_limit_bytes); quota=$(cpu_quota)
  echo "Host visible RAM:      ${host} MiB"
  [[ "$lim" == 0 ]] && echo 'cgroup RAM limit:      unlimited' || echo "cgroup RAM limit:      $(human_bytes "$lim")"
  echo "Safe RAM ceiling:      $((maxmem/1024)) MiB"
  echo "Safe vCPU ceiling:     $maxcpu"
  echo "CPU quota:             ${quota} cores"
  if qemu_running; then echo "Configured RAM/vCPU:    $(cfg_get memory_mb) MiB / $(cfg_get vcpus)"; fi
}

network_internal(){
  echo "Backend requested:     $(cfg_get network_backend)"
  echo "Backend selected:      $(probe_net_backend 2>/dev/null || echo unavailable)"
  echo "Bind address:          $(cfg_get ssh_bind)"
  echo "Host port:             $(cfg_get ssh_host_port)"
  echo "Forward:               tcp:$(cfg_get ssh_bind):$(cfg_get ssh_host_port) -> guest:22"
  echo 'Note: this manager intentionally forwards only the explicit SSH port.'
}

disk_internal(){
  [[ -f "$DISK_IMAGE" ]] || { echo 'Disk: not created'; return; }
  "$QEMU_IMG" info --output=json -- "$DISK_IMAGE"
  if "$QEMU_IMG" check --quiet -- "$DISK_IMAGE" >/dev/null; then ok 'qemu-img check: clean'; else warn 'qemu-img check reported issues'; fi
}

configure_internal(){
  ensure_dirs; write_default_config; validate_config
  [[ -t 0 ]] || die 'configure needs an interactive terminal'
  local maxmem maxcpu x keypath key
  read -r maxmem maxcpu < <(available_resources)
  printf 'RAM MiB [%s] (max %s): ' "$(cfg_get memory_mb)" "$((maxmem/1024))"; read -r x; x=${x:-$(cfg_get memory_mb)}; [[ "$x" =~ ^[0-9]+$ ]] && ((x*1024<=maxmem && x>=256)) || die 'Invalid RAM'; config_write memory_mb "$x" int
  printf 'vCPU [%s] (max %s): ' "$(cfg_get vcpus)" "$maxcpu"; read -r x; x=${x:-$(cfg_get vcpus)}; [[ "$x" =~ ^[0-9]+$ ]] && ((x>=1 && x<=maxcpu)) || die 'Invalid vCPU'; config_write vcpus "$x" int
  printf 'Disk GiB [%s]: ' "$(cfg_get disk_gb)"; read -r x; x=${x:-$(cfg_get disk_gb)}; [[ "$x" =~ ^[0-9]+$ ]] && ((x>=4 && x<=65536)) || die 'Invalid disk'; config_write disk_gb "$x" int
  printf 'SSH host port [%s]: ' "$(cfg_get ssh_host_port)"; read -r x; x=${x:-$(cfg_get ssh_host_port)}; [[ "$x" =~ ^[0-9]+$ ]] && ((x>=1024 && x<=65535)) || die 'Invalid port'; config_write ssh_host_port "$x" int
  printf 'SSH bind [%s]: ' "$(cfg_get ssh_bind)"; read -r x; x=${x:-$(cfg_get ssh_bind)}; [[ "$x" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$|^::1$|^::$ ]] || die 'Invalid bind address'; config_write ssh_bind "$x" str
  printf 'OpenSSH public key file (blank keeps current): '; read -r keypath
  if [[ -n "$keypath" ]]; then
    key=$(ssh-keygen -lf "$keypath" >/dev/null 2>&1 && tr -d '\n\r' <"$keypath" || true); [[ -n "$key" ]] || die 'Invalid public key file'; config_write ssh_key "$key" str
  fi
  validate_config; ok 'Configuration updated. Credential/UEFI/agent settings are separate commands.'
}

credentials_internal(){
  [[ -t 0 ]] || die 'credentials needs an interactive terminal'; validate_config
  local ans hash
  echo "Current root SSH: $(cfg_get root_ssh)"
  read -r -p 'Enable root SSH? [y/N]: ' ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then config_write root_ssh true bool; else config_write root_ssh false bool; fi
  read -r -p 'Set/update Ubuntu password? [y/N]: ' ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then hash=$(make_password_hash); config_write password_hash "$hash" str; fi
  echo "SSH key is controlled by configure."
  [[ ! -f "$SEED_ISO" ]] || { rm -f -- "$SEED_ISO"; warn 'Seed was invalidated; next boot will regenerate credentials.'; }
  ok 'Credential policy saved. This changes cloud-init for the next seed/boot, not an already-initialized guest unless cloud-init is rerun.'
}

agent_internal(){
  local v="$(cfg_get guest_agent)"; [[ -t 0 ]] || die 'agent needs an interactive terminal'
  if [[ "$v" == true ]]; then config_write guest_agent false bool; else config_write guest_agent true bool; fi
  rm -f -- "$SEED_ISO"; ok "Guest Agent setting is now $(cfg_get guest_agent)."
}

uefi_internal(){
  [[ -t 0 ]] || die 'uefi needs an interactive terminal'
  local v="$(cfg_get uefi)"
  if [[ "$v" == true ]]; then config_write uefi false bool; else config_write uefi true bool; fi
  rm -f -- "$SEED_ISO"; ok "UEFI setting is now $(cfg_get uefi). It applies on next boot."
}

network_config_internal(){
  [[ -t 0 ]] || die 'network-config needs an interactive terminal'
  local v
  echo 'Available backends: auto, user, passthrough, passthrough-only'
  printf 'Backend [%s]: ' "$(cfg_get network_backend)"; read -r v; v=${v:-$(cfg_get network_backend)}
  [[ "$v" =~ ^(auto|user|passthrough|passthrough-only)$ ]] || die 'Invalid backend'
  [[ "$v" == passthrough-only ]] && { command -v "$QEMU_BIN" >/dev/null 2>&1 || die 'QEMU missing'; probe_net_backend >/dev/null || true; [[ "$(probe_net_backend)" == passt ]] || die 'passthrough-only requested, but passt is unavailable'; }
  config_write network_backend "$v" str; ok 'Network backend saved.'
}

resize_disk_internal(){
  [[ -t 0 ]] || die 'disk-resize needs an interactive terminal'; [[ -f "$DISK_IMAGE" ]] || die 'VM disk does not exist'; ! qemu_running || die 'Stop VM before resizing';
  local cur target bytes x
  cur=$(( $("$QEMU_IMG" info --output=json -- "$DISK_IMAGE" | "$PYTHON_BIN" -c 'import json,sys;print(json.load(sys.stdin)["virtual-size"])') / 1073741824 ))
  printf 'New ABSOLUTE disk size GiB [%s]: ' "$cur"; read -r x; x=${x:-$cur}; [[ "$x" =~ ^[0-9]+$ ]] && ((x>=cur && x<=65536)) || die 'Only expansion is supported'
  target=$((x*1073741824)); ((target>cur*1073741824)) || { ok 'No change'; return; }
  "$QEMU_IMG" check --quiet -- "$DISK_IMAGE" >/dev/null || die 'Disk check failed before resize'
  "$QEMU_IMG" resize -f qcow2 -- "$DISK_IMAGE" "$target" >/dev/null
  config_write disk_gb "$x" int; ok "Disk capacity expanded to ${x} GiB (guest filesystem may need growpart/resize2fs/xfs_growfs)."
}

snapshot_internal(){
  [[ -t 0 ]] || die 'snapshot needs an interactive terminal'; ! qemu_running || die 'Stop VM before internal snapshot operations'; [[ -f "$DISK_IMAGE" ]] || die 'Disk does not exist';
  local action name
  action="${1:-list}"
  case "$action" in
    create)
      name="${2:-sukuna-$(date -u +%Y%m%dT%H%M%SZ)}"; [[ "$name" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die 'Invalid snapshot name';
      "$QEMU_IMG" snapshot -c "$name" "$DISK_IMAGE"; ok "Snapshot created: $name";;
    list) "$QEMU_IMG" snapshot -l "$DISK_IMAGE";;
    delete) name="${2:-}"; [[ -n "$name" ]] || die 'snapshot delete NAME'; "$QEMU_IMG" snapshot -d "$name" "$DISK_IMAGE"; ok "Snapshot deleted: $name";;
    *) die 'snapshot create NAME | list | delete NAME';;
  esac
}

backup_internal(){
  [[ -t 0 ]] || die 'backup needs an interactive terminal'; ! qemu_running || die 'Stop VM before offline backup'; [[ -f "$DISK_IMAGE" ]] || die 'Disk does not exist';
  local out="${1:-$BACKUP_DIR/sukuna-$(date -u +%Y%m%dT%H%M%SZ).qcow2}"
  [[ "$out" = /* ]] || out="$BACKUP_DIR/$out"
  [[ "$out" != *$'\n'* && "$out" != *$'\r'* ]] || die 'Invalid backup path'
  mkdir -p -- "$(dirname -- "$out")"; chmod 700 -- "$(dirname -- "$out")"
  "$QEMU_IMG" check --quiet -- "$DISK_IMAGE" >/dev/null || die 'Disk check failed before backup'
  "$QEMU_IMG" convert -p -O qcow2 -- "$DISK_IMAGE" "$out"
  "$QEMU_IMG" check --quiet -- "$out" >/dev/null
  sha256sum -- "$out" >"$out.sha256"; chmod 600 -- "$out" "$out.sha256"
  ok "Backup created: $out"; echo "SHA256: $out.sha256"
}

restore_internal(){
  [[ -t 0 ]] || die 'restore needs an interactive terminal'; ! qemu_running || die 'Stop VM before restore';
  local src="${1:-}" tmp
  [[ -f "$src" ]] || die 'restore BACKUP.qcow2';
  tmp="$DISK_IMAGE.restore.$$"
  "$QEMU_IMG" info --output=json -- "$src" >/dev/null || die 'Backup is not a valid QEMU image'
  "$QEMU_IMG" convert -p -O qcow2 -- "$src" "$tmp"
  "$QEMU_IMG" check --quiet -- "$tmp" >/dev/null
  mv -f -- "$tmp" "$DISK_IMAGE"; secure_file "$DISK_IMAGE"; ok 'VM disk restored from backup'
}

check_disk_internal(){
  [[ -f "$DISK_IMAGE" ]] || die 'Disk does not exist'; "$QEMU_IMG" check --repair -- "$DISK_IMAGE"; ok 'Disk check/repair completed';
}

health_internal(){
  validate_config; ensure_dirs
  echo "SUKUNA health check"
  echo "[config]  OK"
  command -v "$PYTHON_BIN" >/dev/null 2>&1 && echo '[python]  OK' || echo '[python]  MISSING'
  command -v curl >/dev/null 2>&1 && echo '[curl]    OK' || echo '[curl]    MISSING'
  [[ -x "$QEMU_BIN" ]] && echo '[qemu]    OK' || echo '[qemu]    MISSING'
  [[ -x "$QEMU_IMG" ]] && echo '[qemu-img] OK' || echo '[qemu-img] MISSING'
  if [[ -f "$BASE_IMAGE" ]]; then (cd "$BASE_DIR" && sha256sum --check --status "$(basename "$BASE_SHA")") && echo '[base]    SHA256 OK' || echo '[base]    SHA256 FAIL'; else echo '[base]    not cached'; fi
  [[ -f "$DISK_IMAGE" ]] && "$QEMU_IMG" check --quiet -- "$DISK_IMAGE" >/dev/null && echo '[disk]    OK' || echo '[disk]    not present/needs repair'
  kvm_available && echo '[kvm]     AVAILABLE' || echo '[kvm]     unavailable (TCG may be used)'
  clear_stale_runtime
  qemu_running && echo '[runtime] RUNNING' || echo '[runtime] STOPPED'
  ok 'Health check complete'
}

repair_internal(){
  ensure_dirs; validate_config; clear_stale_runtime
  [[ -S "$QMP_SOCKET" ]] && ! qemu_running && rm -f -- "$QMP_SOCKET"
  [[ -S "$GA_SOCKET" ]] && ! qemu_running && rm -f -- "$GA_SOCKET"
  [[ -s "$PID_FILE" ]] && ! qemu_running && rm -f -- "$PID_FILE"
  ok 'Stale runtime state repaired safely'
}

logs_rotate_internal(){
  local max_bytes=$((10*1024*1024)) f tmp stamp
  [[ -d "$LOG_DIR" ]] || return 0
  for f in "$LOG_DIR"/*.log; do
    [[ -f "$f" ]] || continue
    if (( $(stat -c '%s' -- "$f") > max_bytes )); then
      stamp=$(date -u +%Y%m%dT%H%M%SZ); tmp="$f.$stamp"
      cp --reflink=auto -- "$f" "$tmp"; : >"$f"; chmod 600 -- "$tmp" "$f"
    fi
  done
  find "$LOG_DIR" -maxdepth 1 -type f -name '*.log.*' -mtime +7 -delete
  ok 'Log rotation/cleanup completed'
}

service_install_internal(){
  command -v systemctl >/dev/null 2>&1 || die 'systemd is unavailable'
  local unit="$HOME/.config/systemd/user/sukuna-v6.service"; mkdir -p -- "$(dirname "$unit")"; chmod 700 -- "$(dirname "$unit")"
  cat >"$unit" <<EOF
[Unit]
Description=DXD LABS SUKUNA V6 VM
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DXD_HOME
ExecStart=$SCRIPT_PATH boot --headless
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  chmod 600 -- "$unit"
  systemctl --user daemon-reload
  systemctl --user enable sukuna-v6.service
  ok "Installed user systemd service: $unit"
  echo 'Start with: systemctl --user start sukuna-v6.service'
}
service_remove_internal(){
  command -v systemctl >/dev/null 2>&1 || die 'systemd is unavailable'; local unit="$HOME/.config/systemd/user/sukuna-v6.service"
  systemctl --user disable --now sukuna-v6.service 2>/dev/null || true; rm -f -- "$unit"; systemctl --user daemon-reload; ok 'User systemd service removed';
}

preflight_internal(){
  ensure_dirs; write_default_config; validate_config
  echo "👹 SUKUNA V$SCRIPT_VERSION PREFLIGHT"
  echo "QEMU:       $(command -v qemu-system-x86_64 || echo MISSING)"
  echo "qemu-img:   $(command -v qemu-img || echo MISSING)"
  echo "cloud-localds: $(command -v cloud-localds || echo MISSING)"
  echo "Python:     $($PYTHON_BIN --version 2>&1)"
  echo "KVM:        $(kvm_available && echo AVAILABLE || echo UNAVAILABLE/TCG)"
  echo "passth:     $(command -v passt || echo not-installed)"
  echo "Safe RAM:   $(( $(available_resources | cut -f1) / 1024 )) MiB"
  echo "Safe CPU:   $(available_resources | cut -f2) vCPU"
  echo "UEFI file:  $(uefi_available 2>/dev/null || echo unavailable)"
  echo "Guest Agent:$(cfg_get guest_agent)"
  echo "Autostart:  $([[ -f "$HOME/.config/systemd/user/sukuna-v6.service" ]] && echo installed || echo not-installed)"
  ok 'Preflight finished'
}

clean_internal(){
  ! qemu_running || die 'Stop VM before clean';
  echo "This removes the VM disk, seed and runtime state under: $DXD_HOME"
  [[ -t 0 ]] || die 'clean needs an interactive terminal'; local x; read -r -p 'Type DELETE to confirm: ' x; [[ "$x" == DELETE ]] || { echo 'Cancelled'; return; }
  rm -rf -- "$VM_DIR" "$RUN_DIR" "$TMP_DIR"; mkdir -p -- "$VM_DIR" "$RUN_DIR" "$TMP_DIR"; chmod 700 -- "$VM_DIR" "$RUN_DIR" "$TMP_DIR"; ok 'VM data cleaned; base cache/backups/snapshots/logs retained'
}

menu(){
  while :; do
    clear || true
    echo '====================================================================='
    echo " 👹 DXD LABS — SUKUNA V$SCRIPT_VERSION"
    echo ' Ubuntu 22.04 amd64 • QEMU/KVM • hardened VM manager'
    echo '====================================================================='
    echo '1) Boot / Serial Console'
    echo '2) Stop gracefully'
    echo '3) Force stop'
    echo '4) Restart'
    echo '5) Status / QMP monitor'
    echo '6) Resources'
    echo '7) Network'
    echo '8) Disk information'
    echo '9) Configure VM'
    echo '10) Credentials / Root SSH'
    echo '11) Guest Agent toggle'
    echo '12) UEFI toggle'
    echo '13) Network backend'
    echo '14) Snapshot'
    echo '15) Backup'
    echo '16) Restore'
    echo '17) Health check'
    echo '18) Repair runtime'
    echo '19) Rotate logs'
    echo '20) Install systemd autostart'
    echo '21) Remove systemd autostart'
    echo '22) Disk resize'
    echo '23) Disk check/repair'
    echo '24) Preflight'
    echo '25) Clean VM'
    echo '0) Exit'
    read -rp $'\nSelect: ' n
    case "$n" in
      1) with_vm_lock boot_internal;; 2) with_vm_lock stop_internal false;; 3) with_vm_lock stop_internal true;; 4) with_vm_lock stop_internal false; with_vm_lock boot_internal;;
      5) status_internal;; 6) resources_internal;; 7) network_internal;; 8) disk_internal;; 9) with_manager_lock configure_internal;;
      10) with_manager_lock credentials_internal;; 11) with_manager_lock agent_internal;; 12) with_manager_lock uefi_internal;; 13) with_manager_lock network_config_internal;;
      14) with_manager_lock snapshot_internal list;; 15) with_manager_lock backup_internal;; 16) with_manager_lock restore_internal;; 17) health_internal;;
      18) with_manager_lock repair_internal;; 19) with_manager_lock logs_rotate_internal;; 20) with_manager_lock service_install_internal;; 21) with_manager_lock service_remove_internal;;
      22) with_manager_lock resize_disk_internal;; 23) with_manager_lock check_disk_internal;; 24) preflight_internal;; 25) with_manager_lock clean_internal;; 0) return;;
      *) warn 'Invalid selection';;
    esac
    read -rp $'\nPress Enter to continue...' _ || true
  done
}

usage(){ cat <<EOF
$SCRIPT_VERSION

Usage:
  $0 menu
  $0 install-deps
  $0 preflight
  $0 boot [--headless]
  $0 stop [--force]
  $0 restart [--force]
  $0 status | resources | network | disk
  $0 configure | credentials | agent | uefi | network-config
  $0 snapshot create NAME | snapshot list | snapshot delete NAME
  $0 backup [PATH]
  $0 restore BACKUP.qcow2
  $0 disk-resize | disk-check
  $0 health | repair | rotate-logs
  $0 service-install | service-remove
  $0 clean | help

Environment:
  DXD_HOME=/absolute/private/path
  SUKUNA_SHUTDOWN_TIMEOUT=90

Notes:
  - Run the launcher consistently as the same user; do not alternate sudo/non-sudo.
  - Root SSH is disabled by default.
  - Boot normally attaches the real QEMU serial console to the terminal.
  - --headless is intended for systemd/autostart and does not provide an interactive console.
  - --force only acts after graceful shutdown timeout and uses pidfd signalling on a verified QEMU PID.
EOF
}

install_deps(){
  [[ "$(id -u)" -eq 0 ]] || die 'install-deps requires root'
  need_cmd apt-get; apt-get update
  apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils openssl curl ca-certificates python3 openssh-client util-linux coreutils genisoimage
  ok 'Dependencies installed'
}

boot_command(){
  if [[ "${1:-}" == --headless ]]; then
    shift
    ensure_dirs; validate_config; need_cmd "$QEMU_BIN"; need_cmd "$QEMU_IMG"; clear_stale_runtime; ! qemu_running || die 'VM already running'
    ensure_base; ensure_disk; ensure_seed
    local maxmem maxcpu mem cpu bind port
    read -r maxmem maxcpu < <(available_resources); mem=$(cfg_get memory_mb); cpu=$(cfg_get vcpus); bind=$(cfg_get ssh_bind); port=$(cfg_get ssh_host_port)
    ((mem*1024<=maxmem && cpu<=maxcpu)) || die 'Configured resources exceed safe host limits'
    check_port "$bind" "$port" || die 'Host SSH port unavailable'
    exec {VM_RUN_FD}>"$VM_LOCK_FILE"; chmod 600 -- "$VM_LOCK_FILE"; flock -x "$VM_RUN_FD"; build_qemu_args; write_state starting null 'headless startup'; rm -f -- "$QMP_SOCKET" "$GA_SOCKET" "$PID_FILE"; log 'Starting headless VM'
    "$QEMU_BIN" "${QEMU_ARGS[@]}" &
    local child=$! pid
    for _ in {1..150}; do [[ -s "$PID_FILE" ]] && qemu_running && break; sleep 0.1; done
    qemu_running || { kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; clear_stale_runtime; die 'Headless QEMU failed to start'; }
    pid=$(cat "$PID_FILE"); write_state running "$pid" 'headless VM running'
    flock -u "$VM_RUN_FD" || true; exec {VM_RUN_FD}>&- || true
    wait "$child"; rc=$?; qemu_running || { clear_stale_runtime; write_state stopped null 'headless QEMU exited'; }; exit "$rc"
  fi
  [[ -t 0 && -t 1 ]] || die 'Interactive boot requires a terminal; use boot --headless for background mode'
  boot_internal
}

main(){
  ensure_dirs; write_default_config
  local cmd="${1:-menu}"; SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
  case "$cmd" in
    help|-h|--help) usage;;
    menu) menu;;
    install-deps) with_manager_lock install_deps;;
    preflight) preflight_internal;;
    boot) boot_command "${2:-}";;
    stop) case "${2:-}" in --force) with_vm_lock stop_internal true;; '') with_vm_lock stop_internal false;; *) die 'stop [--force]';; esac;;
    restart) if [[ "${2:-}" == --force ]]; then with_vm_lock stop_internal true; else with_vm_lock stop_internal false; fi; with_vm_lock boot_internal;;
    status) status_internal;; resources) resources_internal;; network) network_internal;; disk) disk_internal;;
    configure) with_manager_lock configure_internal;; credentials) with_manager_lock credentials_internal;; agent) with_manager_lock agent_internal;; uefi) with_manager_lock uefi_internal;; network-config) with_manager_lock network_config_internal;;
    snapshot) with_manager_lock snapshot_internal "${2:-list}" "${3:-}";;
    backup) with_manager_lock backup_internal "${2:-}";;
    restore) with_manager_lock restore_internal "${2:-}";;
    disk-resize) with_manager_lock resize_disk_internal;;
    disk-check) with_manager_lock check_disk_internal;;
    health) health_internal;; repair) with_manager_lock repair_internal;; rotate-logs) with_manager_lock logs_rotate_internal;;
    service-install) with_manager_lock service_install_internal;; service-remove) with_manager_lock service_remove_internal;; clean) with_manager_lock clean_internal;;
    *) usage; exit 2;;
  esac
}

main "$@"