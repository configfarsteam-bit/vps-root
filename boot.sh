#!/bin/bash

# Clear terminal for clean dashboard view
clear

# ==========================================
# 🌟 PREMIUM COLOR CODES & FX
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

TMUX_SESSION="daytona_vps"
VM_WINDOW="vm-console"
HOST_WINDOW="host-shell"

# FUNCTION: TYPING EFFECT ANIMATION
type_effect() {
    local text="$1"
    local delay="$2"
    for (( i=0; i<${#text}; i++ )); do
        echo -n "${text:$i:1}"
        sleep "$delay"
    done
    echo ""
}

# FUNCTION: LOADING BAR ANIMATION
loading_bar() {
    local title="$1"
    echo -ne "${YELLOW}⏳ $title ${NC}[          ]"
    sleep 0.3
    echo -ne "\b\b\b\b\b\b\b\b\b\b\b[===       ]"
    sleep 0.3
    echo -ne "\b\b\b\b\b\b\b\b\b\b\b[======     ]"
    sleep 0.3
    echo -ne "\b\b\b\b\b\b\b\b\b\b\b[=========  ]"
    sleep 0.3
    echo -ne "\b\b\b\b\b\b\b\b\b\b\b[==========]"
    echo -e " ${GREEN}DONE!${NC}"
}

# AUTOMATED ROOT/SUDO PRIVILEGE CHECK
if [ "$(id -u)" -eq 0 ]; then
    SUDO_CMD=""
else
    SUDO_CMD="sudo"
fi

# BUGFIX: pin a single working directory for ALL VM-related files
# (qcow2 image, seed.img, user-data, .vps_env). Previously these relative
# files were created in whatever directory the script happened to be
# launched from, so "Restart" or "Configure port" would silently fail to
# find them if you ran the script again from a different shell/directory.
WORKDIR="/home/daytona"
$SUDO_CMD mkdir -p "$WORKDIR" > /dev/null 2>&1
$SUDO_CMD chmod 777 "$WORKDIR" > /dev/null 2>&1
cd "$WORKDIR" || { echo -e "\033[0;31m❌ Cannot access or create $WORKDIR${NC}"; exit 1; }

# ==========================================
# MAIN INTERACTIVE LIST MENU
# ==========================================
show_menu() {
    clear
    echo -e "${RED}==========================================================${NC}"
    echo -e "${WHITE}          [👹 DXD LABS PREMIUM VPS DASHBOARD 👹]          ${NC}"
    echo -e "${RED}==========================================================${NC}"
    echo -e "${WHITE}                ┌─────────────────────────┐               ${NC}"
    echo -e "${WHITE}                │   ${RED}█▀▀█ █──█ █▄─▄█ █▀▀█${WHITE}  │  <[SUKUNA V2] ${NC}"
    echo -e "${WHITE}                │   ${RED}█▄▄█ █▄▄█ █ █ █ █▄▄█${WHITE}  │               ${NC}"
    echo -e "${WHITE}                └─────────────────────────┘               ${NC}"
    echo -e "${PURPLE}                   (█)─(█)     (█)─(█)                   ${NC}"
    echo -e "${PURPLE}                  █████████   █████████                  ${NC}"
    echo -e "${RED}                 ███████████████████████                 ${NC}"
    echo -e "${RED}==========================================================${NC}"
    echo -e "${CYAN}  ____  _____ _   _ ____     ____    _    __  __ ___ _   _  ____ ${NC}"
    echo -e "${CYAN} |  _ \| ____| | | |  _ \   / ___|  / \  |  \/  |_ _| \ | |/ ___|${NC}"
    echo -e "${CYAN} | | | |  _| | | | | |_) | | |  _  / _ \ | |\/| || ||  \| | |  _ ${NC}"
    echo -e "${CYAN} | |_| | |___| |_| |  __/  | |_| |/ ___ \| |  | || || |\  | |_| |${NC}"
    echo -e "${CYAN} |____/|_____|\___/|_|      \____/_/   \_\_|  |_|___|_| \_|\____|${NC}"
    echo -e "${RED}==========================================================${NC}"
    echo ""
    echo -e "${YELLOW}👉 SELECT AN OPTION TO PROCEED FROM LIST:${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC} Create & Boot New Ubuntu VPS Instance"
    echo -e "  ${CYAN}[2]${NC} Restart Existing VPS Instance"
    echo -e "  ${CYAN}[3]${NC} Modify TCP Port Forward Rules (Default: 2222)"
    echo -e "  ${CYAN}[4]${NC} Remove/Clean VPS Cache Files"
    echo -e "  ${CYAN}[5]${NC} Attach Locally to VM Console / Host Shell (tmux)"
    echo -e "  ${CYAN}[6]${NC} Show sshx Link Again"
    echo -e "  ${CYAN}[7]${NC} Exit Dashboard (VM keeps running in background)"
    echo ""
    echo -e "${RED}==========================================================${NC}"
    echo -ne "${WHITE}🔹 Enter Choice [1-7]: ${NC}"
    read CHOICE

    case "$CHOICE" in
        1) create_vps ;;
        2) restart_vps ;;
        3) configure_tcp ;;
        4) clean_vps ;;
        5) attach_local ;;
        6) show_sshx_link ;;
        7) exit 0 ;;
        *) echo -e "${RED}❌ Invalid Choice! Please select 1-7.${NC}"; sleep 2; show_menu ;;
    esac
}

# STEP 1: CONFIGURE STORAGE & DOWNLOAD CLOUD ARCHITECTURE
create_vps() {
    clear
    echo -e "${RED}==========================================================${NC}"
    echo -e "${WHITE}⚙️  CONFIGURE YOUR VIRTUAL MACHINE SPECIFICATIONS${NC}"
    echo -e "${RED}==========================================================${NC}"
    echo ""

    echo -ne "${BLUE}🔹 Enter RAM Size in GB (e.g., 4, 8, 16, 32): ${NC}"
    read RAM_GB
    echo -ne "${BLUE}🔹 Enter CPU Cores (e.g., 2, 4, 8): ${NC}"
    read CPU_CORES
    echo -ne "${BLUE}🔹 Enter Disk Space to ADD in GB (e.g., 10, 20): ${NC}"
    read DISK_ADD
    # BUGFIX: DISK_ADD had no default, so leaving it blank produced
    # "qemu-img resize ... +G" which is an invalid size and fails silently.
    DISK_ADD=${DISK_ADD:-10}
    echo -ne "${BLUE}🔹 Create Username (Default: ubuntu): ${NC}"
    read USER_NAME
    USER_NAME=${USER_NAME:-ubuntu}
    echo -ne "${BLUE}🔹 Create Password (leave blank to auto-generate a strong one): ${NC}"
    read -s USER_PASS
    echo ""
    if [ -z "$USER_PASS" ]; then
        USER_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
        echo -e "${YELLOW}🔐 Auto-generated password: ${CYAN}${USER_PASS}${NC}"
    fi

    # 2222 is set as the foundational port base
    TCP_HOST_PORT=${TCP_HOST_PORT:-2222}
    TCP_GUEST_PORT=22

    echo ""
    echo -e "${YELLOW}⏳ Installing core dependencies... Please wait.${NC}"
    echo ""

    $SUDO_CMD apt-get update -y > /dev/null 2>&1
    $SUDO_CMD apt-get install -y qemu-system-x86 qemu-utils wget cloud-image-utils curl tmux > /dev/null 2>&1

    if [ ! -f "/home/daytona/ubuntu22.qcow2" ]; then
        echo -e "${YELLOW}📥 Downloading Ubuntu 22.04 Cloud Image to /home/daytona/...${NC}"
        $SUDO_CMD wget -q --show-progress https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img -O /home/daytona/ubuntu22.qcow2
        $SUDO_CMD chmod 666 /home/daytona/ubuntu22.qcow2
    else
        echo -e "${GREEN}✅ Existing Ubuntu Image Cache Detected at /home/daytona/.${NC}"
    fi

    loading_bar "Generating Cloud-Init Matrix"
    cat <<EOF > user-data
#cloud-config
ssh_pwauth: True
chpasswd:
  list: |
    ${USER_NAME}:${USER_PASS}
  expire: False
EOF

    cloud-localds seed.img user-data > /dev/null 2>&1
    loading_bar "Expanding Server Hard Disk Allocation"
    $SUDO_CMD qemu-img resize /home/daytona/ubuntu22.qcow2 +${DISK_ADD}G > /dev/null 2>&1

    save_env
    boot_qemu
}

# STEP 2: NETWORK CONTROL MODIFIER
configure_tcp() {
    clear
    echo -e "${YELLOW}==========================================================${NC}"
    echo -e "${WHITE}🔄⚙️  MANAGE CUSTOM TCP PORT FORWARDING RULES ${NC}"
    echo -e "${YELLOW}==========================================================${NC}"
    echo ""
    if [ -f ".vps_env" ]; then
        source .vps_env
    fi
    echo -e "Current Target Host Port  : ${CYAN}${TCP_HOST_PORT:-2222}${NC}"
    echo -e "Current Guest VM Port     : ${CYAN}${TCP_GUEST_PORT:-22}${NC}"
    echo ""
    echo -ne "${BLUE}🔹 Enter NEW External Host Port (Default base: 2222): ${NC}"
    read NEW_HOST_PORT
    TCP_HOST_PORT=${NEW_HOST_PORT:-2222}

    echo -ne "${BLUE}🔹 Enter Internal Guest Port (Default SSH: 22): ${NC}"
    read NEW_GUEST_PORT
    TCP_GUEST_PORT=${NEW_GUEST_PORT:-22}

    save_env
    echo ""
    echo -e "${GREEN}✅ TCP Rule Updated Successfully! (Restart the VM for it to take effect)${NC}"
    sleep 2
    show_menu
}

save_env() {
    echo "RAM_GB=${RAM_GB:-32}" > .vps_env
    echo "CPU_CORES=${CPU_CORES:-4}" >> .vps_env
    echo "USER_NAME=${USER_NAME:-ubuntu}" >> .vps_env
    # No hardcoded fallback here: USER_PASS is always set by create_vps
    # (typed or auto-generated) before save_env ever runs. A hardcoded
    # fallback here would silently reintroduce a weak default password.
    echo "USER_PASS=${USER_PASS}" >> .vps_env
    echo "TCP_HOST_PORT=${TCP_HOST_PORT:-2222}" >> .vps_env
    echo "TCP_GUEST_PORT=${TCP_GUEST_PORT:-22}" >> .vps_env
    chmod 600 .vps_env
}

# Capture the sshx share link from whatever the VM-console tmux pane has printed
# BUGFIX: sshx links look like https://sshx.io/s/<ID>#<KEY> -- the security
# key after "#" is required to actually open the session. The previous regex
# used a character class that didn't include "#", so it truncated the link
# right before the key and produced a broken URL. Grabbing everything up to
# the next whitespace avoids guessing at the charset and keeps the whole
# link -- ID, "#", and KEY -- intact, regardless of format changes.
capture_sshx_link() {
    tmux capture-pane -t "${TMUX_SESSION}:${VM_WINDOW}" -p -S -300 2>/dev/null \
        | grep -Eo 'https://sshx\.io/s/[^[:space:]]+' \
        | head -n 1
}

show_sshx_link() {
    clear
    SSHX_URL=$(capture_sshx_link)
    if [ -n "$SSHX_URL" ]; then
        echo -e "${GREEN}👉 $SSHX_URL 👈${NC}"
    else
        echo -e "${RED}⚠️ No active sshx link found. It may still be starting, or the VM session isn't running.${NC}"
    fi
    echo ""
    read -p "Press Enter to return to the menu..."
    show_menu
}

# STEP 3: BOOT QEMU *INSIDE* THE SAME PTY THAT SSHX SHARES
# ------------------------------------------------------------------
# Design:
#   - A detached tmux session survives your terminal/SSH connection closing,
#     because the tmux server runs independently of your login shell.
#   - Window "vm-console" launches sshx. sshx spawns its own shared pty and
#     mirrors it to sshx.io over an outbound HTTPS/WebSocket connection.
#     Once that shared shell is live, we type the qemu boot command straight
#     into it with `tmux send-keys` -- so the sshx link shows the VM's own
#     boot console / login prompt, NOT your host shell.
#   - Because that login happens on the VM's serial console (via
#     qemu -nographic), it needs no network SSH at all. So even if the
#     sandbox/firewall blocks outbound or inbound SSH traffic, you can still
#     reach and log into the VM through the sshx web link.
#   - Window "host-shell" is a private plain shell for you to manage the
#     host. It is never exposed through the sshx link (sshx only shares the
#     pane it was launched in), so it's only reachable via a local
#     `tmux attach`.
# ------------------------------------------------------------------
boot_qemu() {
    if [ -f ".vps_env" ]; then
        source .vps_env
    fi

    TCP_HOST_PORT=${TCP_HOST_PORT:-2222}
    TCP_GUEST_PORT=${TCP_GUEST_PORT:-22}
    RAM_VALUE="${RAM_GB:-32}G"

    clear
    echo -e "${GREEN}==========================================================${NC}"
    type_effect "👹 DATA SYSTEM SYNCHRONIZED! PIPING TERMINAL CHANNELS..." 0.02
    echo -e "${GREEN}==========================================================${NC}"
    echo ""

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo -e "${YELLOW}⚠️ A VM session is already running in tmux (${TMUX_SESSION}). Killing it before restart...${NC}"
        tmux kill-session -t "$TMUX_SESSION"
    fi

    QEMU_CMD="qemu-system-x86_64 -hda /home/daytona/ubuntu22.qcow2 -m $RAM_VALUE -smp ${CPU_CORES:-4} -drive file=seed.img,format=raw -nographic -netdev user,id=net0,hostfwd=tcp::${TCP_HOST_PORT}-:${TCP_GUEST_PORT} -device e1000,netdev=net0"

    # Window 0: vm-console, running sshx (this becomes the shared VM console)
    tmux new-session -d -s "$TMUX_SESSION" -n "$VM_WINDOW" -x 220 -y 50 \
        "bash -c 'curl -sSf https://sshx.io/get | sh -s run'"

    # Window 1: host-shell, private, never shared over sshx
    tmux new-window -t "$TMUX_SESSION" -n "$HOST_WINDOW"

    echo -e "${YELLOW}⏳ Waiting for sshx tunnel to come up...${NC}"
    SSHX_URL=""
    for i in $(seq 1 25); do
        SSHX_URL=$(capture_sshx_link)
        [ -n "$SSHX_URL" ] && break
        sleep 1
    done

    if [ -n "$SSHX_URL" ]; then
        # Give sshx's inner shared shell a moment to become interactive,
        # then type the qemu boot command directly into it.
        sleep 2
        tmux send-keys -t "${TMUX_SESSION}:${VM_WINDOW}" "clear; $QEMU_CMD" C-m
    else
        echo -e "${RED}⚠️ sshx link did not appear in time. Launching qemu anyway inside the tmux window -- check option [6] shortly.${NC}"
        tmux send-keys -t "${TMUX_SESSION}:${VM_WINDOW}" "clear; $QEMU_CMD" C-m
    fi

    clear
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "🎉       DEUP GAMING & DXD LABS - VM NETWORK ACTIVE        "
    echo -e "${GREEN}==========================================================${NC}"
    echo -e "${WHITE}👤 Username : ${CYAN}${USER_NAME:-ubuntu}${NC}"
    echo -e "${WHITE}🔑 Password : ${CYAN}${USER_PASS}${NC}"
    echo -e "${WHITE}⚙️  Resources: ${CYAN}${RAM_VALUE} RAM | ${CPU_CORES:-4} Cores${NC}"
    echo -e "${WHITE}🚀 Port Rule : ${YELLOW}Host Port ${TCP_HOST_PORT} -> VM Port ${TCP_GUEST_PORT}${NC}"
    echo -e "${RED}----------------------------------------------------------${NC}"
    if [ -n "$SSHX_URL" ]; then
        echo -e "${YELLOW}🔥 VM CONSOLE LINK (works even if SSH is blocked -- log in with the${NC}"
        echo -e "${YELLOW}   username/password above, right at the console):${NC}"
        echo -e "${GREEN}👉 $SSHX_URL 👈${NC}"
    else
        echo -e "${RED}⚠️ Tunnel still starting. Use menu option [6] to check for the link again.${NC}"
    fi
    echo -e "${RED}----------------------------------------------------------${NC}"
    echo -e "${WHITE}👉 Network SSH (if unblocked) : ssh ${USER_NAME:-ubuntu}@localhost -p ${TCP_HOST_PORT}${NC}"
    echo -e "${WHITE}👉 Local console attach       : tmux attach -t ${TMUX_SESSION}${NC}"
    echo -e "${CYAN}   (Ctrl+b then w to switch windows, Ctrl+b then d to detach -- nothing stops)${NC}"
    echo -e "${GREEN}==========================================================${NC}"
    echo ""
    read -p "Press Enter to return to the menu (the VM and tunnel keep running in the background)..."
    show_menu
}

# ATTACH LOCALLY TO EITHER THE VM CONSOLE OR THE PRIVATE HOST SHELL
attach_local() {
    clear
    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo -e "${RED}❌ No running VM session found. Build one with Option 1 first.${NC}"
        sleep 2
        show_menu
        return
    fi
    echo -e "  ${CYAN}[1]${NC} VM console (same view the sshx link shows)"
    echo -e "  ${CYAN}[2]${NC} Private host shell (not exposed via sshx)"
    echo -ne "${WHITE}🔹 Choice: ${NC}"
    read ATTACH_CHOICE
    echo -e "${GREEN}(Ctrl+b then d to detach without stopping anything)${NC}"
    sleep 1
    case "$ATTACH_CHOICE" in
        2) tmux attach -t "${TMUX_SESSION}:${HOST_WINDOW}" ;;
        *) tmux attach -t "${TMUX_SESSION}:${VM_WINDOW}" ;;
    esac
    show_menu
}

# RESTART PIPELINE
restart_vps() {
    if [ -f "/home/daytona/ubuntu22.qcow2" ] && [ -f "seed.img" ]; then
        echo -e "${GREEN}🔄 Restarting existing server architecture...${NC}"
        sleep 1
        boot_qemu
    else
        echo -e "${RED}❌ No active configuration blocks found! Build module using Option 1.${NC}"
        sleep 3
        show_menu
    fi
}

# CLEAN PIPELINE
clean_vps() {
    echo -e "${RED}⚠️ Purging system storage components and configurations...${NC}"
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux kill-session -t "$TMUX_SESSION"
    fi
    $SUDO_CMD rm -rf user-data seed.img /home/daytona/ubuntu22.qcow2 .vps_env
    # BUGFIX: the running sshx client process doesn't necessarily have
    # "sshx.io" in its command line (it's a locally re-exec'd binary), so
    # the old pkill pattern usually matched nothing. tmux kill-session
    # above already reaps it as part of the pane's process tree; this is
    # just a best-effort backstop for anything left outside tmux.
    pkill -f "sshx" > /dev/null 2>&1
    sleep 1
    echo -e "${GREEN}✅ Workspace successfully wiped fresh!${NC}"
    sleep 2
    show_menu
}

# EXECUTE TRIGGER
show_menu
