#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RENDER + QEMU + SSHX
# ============================================================

WORKDIR="/opt/render/project/src/vm"
IMAGE="$WORKDIR/ubuntu22.qcow2"
SEED="$WORKDIR/seed.img"
USER_DATA="$WORKDIR/user-data"
SSHX_LOG="$WORKDIR/sshx.log"
QEMU_LOG="$WORKDIR/qemu.log"

PORT="${PORT:-10000}"

RAM_GB="${RAM_GB:-2}"
CPU_CORES="${CPU_CORES:-2}"

VM_USER="${VM_USER:-ubuntu}"
VM_PASSWORD="${VM_PASSWORD:-ubuntu123456}"

GUEST_SSH_PORT=22

mkdir -p "$WORKDIR"

echo
echo "============================================================"
echo "        RENDER QEMU + SSHX VM"
echo "============================================================"
echo
echo "[+] PORT       : $PORT"
echo "[+] RAM        : ${RAM_GB}G"
echo "[+] CPU        : ${CPU_CORES}"
echo "[+] VM USER    : $VM_USER"
echo

# ============================================================
# 1. Minimal HTTP server for Render health/proxy
# ============================================================

cat > "$WORKDIR/health.py" <<'PY'
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.environ.get("PORT", "10000"))

class Handler(BaseHTTPRequestHandler):

    def do_GET(self):
        if self.path == "/health":
            body = b"OK\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        body = b"Render VM service is running.\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

server = HTTPServer(("0.0.0.0", PORT), Handler)
print(f"HTTP health server listening on 0.0.0.0:{PORT}", flush=True)
server.serve_forever()
PY

python3 "$WORKDIR/health.py" \
    > "$WORKDIR/health.log" 2>&1 &

HEALTH_PID=$!

cleanup() {
    echo
    echo "[!] Shutting down..."

    kill "$HEALTH_PID" 2>/dev/null || true
    kill "$SSHX_PID" 2>/dev/null || true
    kill "$QEMU_PID" 2>/dev/null || true

    exit 0
}

trap cleanup SIGTERM SIGINT EXIT

# ============================================================
# 2. Download Ubuntu Cloud Image
# ============================================================

if [ ! -f "$IMAGE" ]; then

    echo "[+] Downloading Ubuntu 22.04 cloud image..."

    wget -q --show-progress \
        "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img" \
        -O "$IMAGE"

else

    echo "[+] Ubuntu image already exists."

fi

# ============================================================
# 3. Resize image
# ============================================================

echo "[+] Preparing disk..."

qemu-img info "$IMAGE" >/dev/null 2>&1 || {
    echo "[!] Invalid QEMU image."
    exit 1
}

# Add 8GB by default only if image is still small.
qemu-img resize "$IMAGE" +8G >/dev/null 2>&1 || true

# ============================================================
# 4. Cloud-init
# ============================================================

cat > "$USER_DATA" <<EOF
#cloud-config

users:
  - name: ${VM_USER}
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

ssh_pwauth: true

chpasswd:
  expire: false
  list:
    - ${VM_USER}:${VM_PASSWORD}

package_update: false
package_upgrade: false

runcmd:
  - systemctl enable ssh
  - systemctl start ssh
EOF

echo "[+] Creating cloud-init seed..."

cloud-localds "$SEED" "$USER_DATA"

# ============================================================
# 5. Start QEMU
# ============================================================

echo
echo "============================================================"
echo "[+] Starting QEMU..."
echo "============================================================"
echo

# Render does NOT provide a public arbitrary TCP port like:
#
#     2222 -> 22
#
# Therefore SSH is accessed through sshx/console here.
#
# QEMU networking is NAT only.

qemu-system-x86_64 \
    -machine accel=tcg \
    -cpu max \
    -m "${RAM_GB}G" \
    -smp "$CPU_CORES" \
    -drive "file=$IMAGE,format=qcow2" \
    -drive "file=$SEED,format=raw" \
    -nic user,model=e1000 \
    -nographic \
    > "$QEMU_LOG" 2>&1 &

QEMU_PID=$!

echo "[+] QEMU PID: $QEMU_PID"

# ============================================================
# 6. Wait for QEMU
# ============================================================

sleep 5

if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    echo
    echo "[!] QEMU failed to start."
    echo
    cat "$QEMU_LOG"
    exit 1
fi

# ============================================================
# 7. Start SSHX
# ============================================================

echo
echo "============================================================"
echo "[+] Starting SSHX..."
echo "============================================================"
echo

(
    curl -sSf https://sshx.io/get | sh
) >/dev/null 2>&1 || true

# sshx binary location can differ depending on installer.
SSHX_BIN=""

for candidate in \
    "$HOME/.local/bin/sshx" \
    "$HOME/.cargo/bin/sshx" \
    "/usr/local/bin/sshx" \
    "/usr/bin/sshx"
do
    if [ -x "$candidate" ]; then
        SSHX_BIN="$candidate"
        break
    fi
done

if [ -z "$SSHX_BIN" ]; then
    SSHX_BIN="$(command -v sshx 2>/dev/null || true)"
fi

if [ -z "$SSHX_BIN" ]; then
    echo "[!] sshx binary not found."
    exit 1
fi

echo "[+] SSHX binary:"
echo "    $SSHX_BIN"

# ============================================================
# 8. Start SSHX with QEMU console
# ============================================================

"$SSHX_BIN" run \
    > "$SSHX_LOG" 2>&1 &

SSHX_PID=$!

echo "[+] SSHX PID: $SSHX_PID"

# ============================================================
# 9. Find FULL SSHX URL
# ============================================================

echo
echo "[+] Waiting for SSHX URL..."
echo

SSHX_URL=""

for i in $(seq 1 60); do

    if [ -f "$SSHX_LOG" ]; then

        SSHX_URL=$(
            grep -Eo \
            'https://sshx\.io/s/[A-Za-z0-9._~:/?#\[\]@!$&'\''()*+,;=%-]+' \
            "$SSHX_LOG" \
            | head -n 1 \
            | tr -d '\r\n'
        )

    fi

    if [[ "$SSHX_URL" == https://sshx.io/s/* ]]; then
        break
    fi

    sleep 1
done

# ============================================================
# 10. Show URL
# ============================================================

echo
echo "============================================================"
echo "                 SSHX CONNECTION"
echo "============================================================"
echo

if [[ "$SSHX_URL" == https://sshx.io/s/* ]]; then

    echo
    echo "$SSHX_URL"
    echo

    # Save EXACT URL.
    # Do not use basename/cut/sed that could remove '#KEY'.
    printf '%s\n' "$SSHX_URL" > "$WORKDIR/sshx-url.txt"

    echo "============================================================"
    echo "IMPORTANT"
    echo "============================================================"
    echo
    echo "Copy the COMPLETE URL."
    echo "The part after # is part of the E2E access key."
    echo

else

    echo "[!] SSHX URL was not detected."
    echo
    echo "SSHX log:"
    cat "$SSHX_LOG" || true

fi

# ============================================================
# 11. Keep Render Web Service alive
# ============================================================

echo
echo "============================================================"
echo "Render service is running."
echo "Health endpoint:"
echo "/health"
echo "============================================================"
echo

wait "$QEMU_PID"
