# PigeonBox OpenWrt / iStoreOS

[![CI](https://github.com/pigeonbox/openwrt/actions/workflows/ci.yml/badge.svg)](https://github.com/pigeonbox/openwrt/actions/workflows/ci.yml)
[![Release](https://github.com/pigeonbox/openwrt/actions/workflows/release.yml/badge.svg)](https://github.com/pigeonbox/openwrt/releases)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)

PigeonBox（文件快递柜，匿名口令分享文本/文件）的 **OpenWrt / iStoreOS 原生包**：单进程 Go 二进制 + 内置 Web 界面，procd 托管、开机自启，以 ipk 一键安装。

- 单端口 `12345` 同时服务 Web 界面与 API（前端 dist 内置于包中）
- 取件码映射持久化由内置 Redis 承担（`redis-server` 包自动安装；core 单机内存模式列车后，UCI 关闭 redis 仍可全功能运行——进程内 KV、重启丢失未取件映射）
- JWT 密钥自动生成并持久化，开箱即用、重启不失效
- 配置走 UCI（`/etc/config/pigeonbox`），高级项支持 drop-in `config.yaml`
- 双架构：`x86_64`（iStoreOS 主流）/ `aarch64_generic`（ARM SBC）
- 设备直传：ipk/apk **随包 p2pc 与 p2pcweb 两个二进制**（`/usr/bin/p2pc`、`/usr/bin/p2pcweb`，DEPS.env `P2PC_REF` 钉版+sha256 校验，`make p2pc` 可单独拉取；包内文件清单由 `scripts/assert-pkg-contents.sh` 与 CI 冒烟双重断言）；admin「系统配置→P2P」分区热启停联邦与设备直传（standalone 部署专属）

> 内存建议 ≥512MB（Go 服务 + Redis）。纯软路由小内存设备不适用。

## 安装

**按系统代际选包**：

| 系统代际 | 包管理器 | 选哪个包 |
|---|---|---|
| OpenWrt/iStoreOS 22.03、23.05（现行 iStoreOS） | opkg | `pigeonbox_<ver>-1_<arch>.ipk` |
| OpenWrt 25.12+（apk3 新代） | apk | `pigeonbox_<ver>-r0_<arch>.apk` |

### iStore（iStoreOS）

iStore → 手动安装 → 粘贴 ipk 下载 URL（本仓 [Releases](https://github.com/pigeonbox/openwrt/releases) 对应架构资产），或上传本地 ipk 文件。

### opkg（OpenWrt/iStoreOS 22.03/23.05）

```sh
# x86_64 设备
wget -O /tmp/pigeonbox.ipk https://github.com/pigeonbox/openwrt/releases/download/v3.3.2/pigeonbox_3.3.2-1_x86_64.ipk
opkg install /tmp/pigeonbox.ipk
```

（aarch64 设备换 `aarch64_generic` 包。）安装即自动启用并启动，浏览器访问 `http://<路由器IP>:12345`。

### apk（OpenWrt 25.12+）

```sh
# 1) 预置签名公钥(一次性;否则 apk add 需加 --allow-untrusted)
wget -O /etc/apk/keys/pigeonbox.pem https://github.com/pigeonbox/openwrt/raw/main/keys/pigeonbox.pem
# 2) 安装(依赖 redis-server 自动拉取,装后自动启用并启动)
wget -O /tmp/pigeonbox.apk https://github.com/pigeonbox/openwrt/releases/download/v3.3.2/pigeonbox-3.3.2-r0_x86_64.apk
apk add /tmp/pigeonbox.apk
```

- 管理员口令：未设置时首次启动走 **`/setup` 向导**创建管理员（生产门禁拒绝默认 `admin123`）；UCI `main.admin_password` 非空时口令以该项为准（已存在则就地更新并吊销旧会话），也可登录后在网页修改
- 彻底卸载：opkg 系 `opkg remove pigeonbox`；apk 系 `apk del pigeonbox`（数据保留在 `/etc/pigeonbox/`，确认无用后手动删除）

### LuCI 菜单入口（装完即有）

安装后 LuCI 左侧 **服务 → PigeonBox 文件快递柜**：procd 实时服务状态、**可视化配置表单**（端口/监听地址/数据目录/匿名上传/管理员密码/对外 URL/Redis，保存并应用后自动重启服务生效）、**启动/停止/重启按钮**、一键**新窗口打开**网页界面。

> 说明：入口页不做 iframe 内嵌——core 安全基线对全部响应下发 `X-Frame-Options: SAMEORIGIN`（防点击劫持），LuCI（:80）内嵌业务端口（:12345）属跨源会被浏览器拦截，故采用状态页 + 新窗口打开形态。安装/升级会重启 rpcd 使 ACL 生效，**重新登录 LuCI** 即可看到菜单。

## 配置

`/etc/config/pigeonbox`（UCI），改完执行 `/etc/init.d/pigeonbox reload`：

| 选项 | 默认 | 说明 |
|---|---|---|
| `main.enabled` | `1` | 服务总开关 |
| `main.port` | `12345` | 监听端口 |
| `main.host` | `0.0.0.0` | 监听地址 |
| `main.data_dir` | `/etc/pigeonbox/data` | SQLite+上传文件+JWT 密钥；**大量文件建议指到数据盘**（如 `/mnt/sda1/pigeonbox`） |
| `main.open_upload` | `1` | 允许匿名上传 |
| `main.admin_password` | 空 | 管理员密码（留空=不改动，首次启动走 `/setup` 向导；非空=口令以本项为准，保存应用后自动重启生效并吊销旧会话） |
| `main.base_url` | 空 | 站点对外 URL（直链下载/presign 需要，局域网直访可留空） |
| `redis.enabled` | `1` | 关闭后服务仍可用；自 core v0.14.0 单机内存模式起=进程内 KV（匿名取件可用、重启丢失映射），当前钉版 core v0.20.0 |
| `redis.host` / `redis.port` | `127.0.0.1:6379` | Redis 地址（`redis-server` 包默认值） |
| `redis.password` | 空 | Redis 密码 |

UCI 之外的配置项（S3/OIDC/联邦/mcp 等）：把 [configs/config.yaml](./configs/config.yaml) 复制为 `/etc/pigeonbox/config.yaml` 修改后重启服务即可（UCI 注入的环境变量优先级更高）。完整配置说明见 [server 仓](https://github.com/pigeonbox/server) `configs/` 与 [hub 仓](https://github.com/pigeonbox/pigeonbox) `docs/ENVIRONMENT_VARIABLES.md`。

服务管理：

```sh
/etc/init.d/pigeonbox start|stop|restart|reload|enable|disable
logread | grep pigeonbox   # 日志(procd stdout→syslog)
```

## 从源码构建

```sh
go build -o dist/pigeonbox ./cmd/pigeonbox   # CGO_ENABLED=0,纯 Go sqlite
./scripts/build-frontend.sh                        # 前端 dist → dist/www
./scripts/build-ipk.sh x86_64 0.4.0                # → dist/pigeonbox_0.4.0-1_x86_64.ipk
APK_SIGN_KEY=<私钥路径> ./scripts/build-apk.sh x86_64 0.4.0   # → 签名 apk(不设=未签名)
```

CI 每次推送在两个 OpenWrt rootfs 容器内真装冒烟:`x86-64-23.05.6`(opkg/ipk,对齐 iStoreOS 基线)与 `x86-64-25.12.5`(apk3 新代),均为 opkg install / apk add → 服务启动 → `/ping` 探活 → Redis 初始化断言。

## 架构

```
/etc/init.d/pigeonbox   procd init:UCI→PB_* env 注入
/usr/bin/pigeonbox      BootstrapWithOptions(WithStaticDir) 单进程业务+UI
/usr/share/pigeonbox/www 内置前端(Vite 构建产物)
/etc/config/pigeonbox   UCI 配置(conffile)
/etc/pigeonbox/         数据目录(SQLite/上传文件/.jwt_secret)
```

依赖 `github.com/pigeonbox/core`（正式 tag 钉版）。工作区内开发经 hub `go.work` 联编本地 core，`GOWORK=off` 强制钉版构建。

## 生态

[pigeonbox](https://github.com/pigeonbox/pigeonbox)（装配仓）· [core](https://github.com/pigeonbox/core)（业务核心）· [server](https://github.com/pigeonbox/server)（独立部署壳）· [frontend](https://github.com/pigeonbox/frontend) · [fnos](https://github.com/pigeonbox/fnos)（飞牛 fnOS 适配）· [desktop](https://github.com/pigeonbox/desktop)（桌面端）· [charts](https://github.com/pigeonbox/charts)（Helm）

## License

[Apache-2.0](./LICENSE) — Copyright 2026 PigeonBox
