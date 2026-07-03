# notrace — Server Trace Cleaner

单脚本，兼容 POSIX sh，支持所有主流 Linux 发行版。

## 快速使用

```bash
# 清除你自己的访问记录（默认模式）
curl -fsSL https://raw.githubusercontent.com/evaworks/notrace/main/notrace.sh | sudo sh

# 全盘无痕（清除所有 + 阻断源头）
curl -fsSL https://raw.githubusercontent.com/evaworks/notrace/main/notrace.sh | sudo sh -s -- --all
```

## 参数

| 参数 | 说明 |
|------|------|
| `--self` | 只清除你自己的访问记录（默认，可省略）。自动从 `$SSH_CLIENT` 获取你的 IP |
| `--all` | 全盘清除：所有日志 + 安装记录 + 历史 + 造伪 + 阻断源头 |
| `--help` | 帮助信息 |

## 兼容性

| 发行版 | 状态 |
|--------|------|
| Ubuntu / Debian / Kali / Mint / Pop | 完整支持 |
| CentOS / RHEL / Rocky / Alma / Fedora | 完整支持 |
| Arch / Manjaro / EndeavourOS | 完整支持 |
| openSUSE / SLES | 完整支持 |
| Alpine Linux | 完整支持 (ash, busybox) |
| Gentoo / Funtoo | 完整支持 |
| Void Linux | 完整支持 |
| Slackware | 基础支持 |

## 覆盖的日志类型

**系统:** auth.log / secure / syslog / messages / kern.log / debug / dmesg / boot.log / lastlog / wtmp / btmp / faillog / journald

**Web:** Nginx / Apache / Caddy / Traefik / h2o

**VPN:** OpenVPN / WireGuard / StrongSwan / IPSec / ocserv (OpenConnect)

**数据库:** MySQL / MariaDB / PostgreSQL / MongoDB / Redis

**文件共享:** Samba / FTP (vsftpd / proftpd / pure-ftpd)

**云厂商:** Alibaba Cloud / AWS / Azure / GCP / Tencent Cloud / Oracle Cloud

**包管理器:** APT / dpkg / YUM / DNF / Pacman / Zypper / APK (Alpine) / Portage (Gentoo)

**容器:** Docker (all container logs)

## 不做什么

- 不卸载任何软件
- 不停止/禁用任何服务
- 不删除程序配置文件
- 不影响业务运行
