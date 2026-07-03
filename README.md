# notrace — Server Trace Cleaner

清除服务器上的访问痕迹。单脚本，双模式。

## 快速使用

```bash
# 模式一：只清除你自己的访问记录（默认）
curl -fsSL https://raw.githubusercontent.com/你的用户名/notrace/main/notrace.sh | sudo bash

# 模式二：全盘无痕（清除所有记录 + 阻断源头）
curl -fsSL https://raw.githubusercontent.com/你的用户名/notrace/main/notrace.sh | sudo bash -s -- --all
```

## 参数

| 参数 | 说明 |
|------|------|
| `--self` | 只清除你自己的访问记录（默认，可省略）。自动从 `$SSH_CLIENT` 获取你的 IP |
| `--all` | 全盘清除：所有日志 + 安装记录 + 历史 + 造伪 + 阻断源头 |
| `--help` | 帮助信息 |

## --self 模式做什么

- 自动获取你的 SSH 来源 IP
- 从 auth.log/secure、nginx/apache、OpenVPN/WireGuard 等日志中删除含你 IP 的行
- 过滤 wtmp/btmp/lastlog 中你的登录记录
- 清空你的 bash history 及应用操作历史
- 其他人的记录**完整保留**

## --all 模式做什么

- 清空所有系统日志（syslog、auth、nginx、apache、VPN、docker、journald、audit 等）
- 删除包管理器安装记录（apt、yum、dnf、pacman、zypper）
- 清空所有用户的历史记录（bash、mysql、python、vim 等）
- 时间戳造伪（日志文件看起来像被正常 logrotate 轮转过的）
- 阻止未来产生记录（SSH LogLevel QUIET、rsyslog 过滤、HISTSIZE=0）

## 不做什么

- ❌ 不卸载任何软件
- ❌ 不停止/禁用任何服务
- ❌ 不删除程序配置文件
- ❌ 不影响业务运行
