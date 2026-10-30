# GTools

面向 **ImmortalWrt 25.12** 的核心更新 LuCI 应用。

上游（例如 [daeuniverse/honk](https://github.com/daeuniverse/honk)）发版较快，而固件/软件源里的包往往滞后。GTools 直接从 GitHub Releases 下载最新核心，校验后替换本机文件，并保留旧版本以便回滚。

目前内置 **honk** 核心，代码按“核心注册表”设计，后续可以继续加入 mihomo、sing-box、Xray 等核心。

> 本项目只替换核心二进制文件，不修改 honk 的配置、内核模块或依赖。升级前请确保设备满足 honk 的运行要求（Linux 6.12+、BTF、bpffs 等）。

---

## 功能

- 从 GitHub Releases 检查并安装最新核心
- 自动识别设备架构（honk 支持 `x86_64` / `aarch64`）
- 支持 honk 的 `full`、`clash-api`、`native-api` 三种变体
- 支持 `mimalloc` / `stock` 两种内存分配器
- 更新通道：`auto`、`stable`、`beta`、`debug`
- 下载后校验上游 `SHA256SUMS`（上游未提供时跳过并提示）
- 替换前自动备份，默认保留最近 3 份
- 原子替换核心文件，按需重启服务
- 升级后服务未能启动时自动回滚
- 支持 GitHub 下载/API 加速地址和可选 Token
- 后台任务 + 实时日志，不阻塞 LuCI
- 核心注册表式设计，方便以后增加其它核心

---

## 支持的核心

| 核心 | 二进制 | 服务 | 架构 | 说明 |
| --- | --- | --- | --- | --- |
| honk | `/usr/bin/honk-core` | `/etc/init.d/honk` | `x86_64`、`aarch64` | 使用上游 musl 静态构建 |

honk 上游目前只发布 `x86_64` 和 `aarch64` 的 musl/gnu 构建。OpenWrt 使用 musl，因此 GTools 固定选择 musl 包；`armv7`、`mips` 等架构会提示“不支持的架构”。

---

## 安装

### 方式一：命令行

从 [Releases](../../releases) 下载 `luci-app-gtools-*.apk`，上传到路由器后执行：

```sh
apk add --allow-untrusted /tmp/luci-app-gtools-*.apk
```

如果路由器已配置可信签名密钥，可以去掉 `--allow-untrusted`。

安装完成后刷新 LuCI，在 **服务 → GTools** 打开页面。

### 方式二：LuCI 软件包页面

在“系统 → 软件包”中上传 `.apk` 安装。若提示 `UNTRUSTED signature`，请在 SSH 中用上面的 `--allow-untrusted` 命令安装。

> 本项目按 ImmortalWrt 25.12（apk 包管理器）构建。24.10 及更早版本使用 opkg，不适用此包。
>
> 运行依赖 LuCI 自带的 `ucode`、`ucode-mod-fs`、`ucode-mod-uci`，以及 `uclient-fetch`、`ca-bundle`；ImmortalWrt 25.12 默认已包含这些组件。

---

## 使用

1. 打开 **服务 → GTools**。
2. 首次打开会自动检查一次更新；也可以点“检查更新”。
3. 在“全局设置”中按需填写 GitHub 加速地址。
4. 在“honk 设置”中选择更新通道、核心变体和内存分配器，点“保存并应用”。
5. 状态表中出现新版本后，点“升级”。
6. 升级过程会显示实时日志；完成后服务会自动重启。
7. 如需撤销，点“回滚”，选择要恢复的备份。

### 更新通道

| 通道 | 含义 |
| --- | --- |
| `auto` | 最新正式版或测试版（排除 `debug.*`），推荐 |
| `stable` | 仅正式版（非 pre-release） |
| `beta` | 仅测试版（alpha/beta/rc） |
| `debug` | 最新的滚动调试版 `debug.*` |

honk 目前只有 beta 版本，因此默认 `auto` 会选中最新的 beta。等上游发布正式版后，`stable` 才可用。`debug` 通道的上游构建可能没有 `full` 资源，GTools 会按 `-full` → 无后缀的顺序自动回退；这类构建也可能不提供 `SHA256SUMS`，此时会跳过校验并记录提示。

### 核心变体

| 变体 | 内容 |
| --- | --- |
| `full` | Clash API + 原生 API + 内置 doona 面板 |
| `clash-api` | 仅 Clash API，无原生 API 和面板 |
| `native-api` | 仅原生 API，无 Clash API 和面板 |

### 内存分配器

| 分配器 | 特点 |
| --- | --- |
| `mimalloc` | 吞吐优先，默认 |
| `stock` | 使用系统分配器，内存峰值更低，适合小内存设备 |

---

## 全局设置

| 选项 | 说明 |
| --- | --- |
| 下载加速地址 | 可选。会拼在 GitHub 下载地址前，例如 `https://ghfast.top` → `https://ghfast.top/https://github.com/...` |
| API 加速地址 | 可选。仅用于 `api.github.com`；部分加速服务不支持 API，留空直连即可 |
| GitHub Token | 可选。用于提高 GitHub API 限额（未认证 60 次/小时）。Token 只保存在 `/etc/config/gtools` |
| 清除 Token | 勾选后保存会删除已保存的 Token |
| 保留备份数量 | 每次升级前备份当前核心，保留最近 1–10 份 |
| SHA256 校验 | 下载后校验上游 `SHA256SUMS`；上游未提供校验文件时跳过 |
| 自动回滚 | 升级后服务在 20 秒内未启动时，自动恢复上一个核心 |
| 打开页面时自动检查 | 上次检查超过 10 分钟时自动检查一次 |

> 使用第三方加速服务时，Token 可能会经过该服务。对安全敏感的场景请留空加速地址或使用自建代理。

> 修改任何设置后，请点击页面下方的 **保存并应用**。GTools 会直接写入
> `/etc/config/gtools` 并立即生效，不需要再使用 LuCI 底部的全局“未保存的更改 / 应用”按钮。

---

## 工作流程

1. 读取 `/usr/share/gtools/cores.json` 中注册的核心。
2. 请求 `https://api.github.com/repos/<repo>/releases?per_page=100`。
   API 不可用（限流、被墙）时自动改用 `releases.atom` 和
   `releases/expanded_assets/<tag>` 页面，不消耗 API 限额。
3. 按更新通道挑选最新 release。
4. 根据架构、变体、分配器拼出资源名，并与 release 的 assets 列表核对。
5. 下载资源到 `/tmp/gtools/`。
6. 下载 `SHA256SUMS` 并校验（若存在）。
7. 解压、执行 `--version` 做基本可用性检查。
8. 备份当前核心到 `/usr/share/gtools/backups/<core>/`。
9. 写入 `*.gtools.new` 后 `mv` 原子替换。
10. 如果服务已启用或正在运行，重启并等待进程出现。
11. 启动失败且开启自动回滚时，恢复备份并再次重启。

任务状态和日志：

- `/tmp/gtools/job.state`：`running` / `ok` / `fail`
- `/tmp/gtools/job.log`：任务日志
- `/tmp/gtools/latest.<core>.tsv`：最近一次检查结果缓存

---

## 添加其它核心

GTools 的核心列表在：

```
/usr/share/gtools/cores.json
```

每个核心是一个对象。以 honk 为例：

```json
{
  "honk": {
    "title": "honk",
    "description": "eBPF transparent proxy engine (honk-core)",
    "repo": "daeuniverse/honk",
    "binary": "/usr/bin/honk-core",
    "service": "honk",
    "service_config": "honk",
    "service_section": "config",
    "service_enabled": "enabled",
    "channels": ["auto", "stable", "beta", "debug"],
    "defaults": {
      "enabled": true,
      "channel": "auto",
      "variant": "full",
      "allocator": "mimalloc"
    },
    "asset": {
      "archive": "tar.gz",
      "binary_name": "honk-core",
      "pattern": "honk-core-{tag}-{arch}-unknown-linux-{libc}{alloc}{variant}.tar.gz",
      "debug_pattern": "honk-core-debug-{arch}-unknown-linux-{libc}{alloc}{variant}.tar.gz",
      "debug_prefix": "debug.",
      "libc": "musl",
      "arch": { "x86_64": "x86_64", "aarch64": "aarch64" },
      "variants": {
        "full": ["-full", ""],
        "clash-api": ["-clash-api"],
        "native-api": ["-native-api"]
      },
      "allocators": { "mimalloc": [""], "stock": ["-stock"] }
    }
  }
}
```

字段说明：

| 字段 | 说明 |
| --- | --- |
| `repo` | GitHub 仓库，`owner/name` |
| `binary` | 本机核心路径 |
| `service` | init 脚本名，对应 `/etc/init.d/<service>` |
| `service_config` / `service_section` / `service_enabled` | 读取服务是否启用的 UCI 配置 |
| `channels` | 界面中显示的通道 |
| `defaults` | 新核心的默认设置 |
| `asset.archive` | `tar.gz`、`gz` 或 `none` |
| `asset.binary_name` | 压缩包内二进制文件名 |
| `asset.pattern` | 资源名模板，支持 `{tag}`、`{version}`、`{arch}`、`{libc}`、`{variant}`、`{alloc}` |
| `asset.debug_pattern` | debug 通道使用的模板（可选） |
| `asset.debug_prefix` | debug tag 前缀，默认 `debug.` |
| `asset.arch` | 设备架构 → 上游架构名映射 |
| `asset.variants` | 变体 → 后缀候选列表，按顺序尝试 |
| `asset.allocators` | 分配器 → 后缀候选列表 |

`variants` / `allocators` 的值是**数组**，GTools 会按顺序尝试，并检查该资源是否真的存在于 release 的 assets 中。这样既能兼容 honk debug 构建缺少 `-full` 后缀的情况，也方便以后适配命名不统一的项目。

例如加入 mihomo（仅作示例，实际使用前请核对上游命名）：

```json
"mihomo": {
  "title": "mihomo",
  "description": "Mihomo proxy core",
  "repo": "MetaCubeX/mihomo",
  "binary": "/usr/bin/mihomo",
  "service": "mihomo",
  "channels": ["auto", "stable", "beta"],
  "defaults": { "enabled": true, "channel": "auto", "variant": "default", "allocator": "default" },
  "asset": {
    "archive": "gz",
    "binary_name": "mihomo",
    "pattern": "mihomo-linux-{arch}-{tag}.gz",
    "arch": { "x86_64": "amd64", "aarch64": "arm64" },
    "variants": { "default": [""] },
    "allocators": { "default": [""] }
  }
}
```

保存后：

- 重启路由器，或手动执行 `/etc/uci-defaults/90-gtools`，为新核心创建 UCI 配置节；
- 也可以直接打开 GTools 页面，脚本会自动补齐缺失的 UCI 节；
- 如果资源命名规则更特殊，修改 `/usr/share/gtools/select.uc` 中的模板逻辑即可。

> 如果你的 honk 不是安装在 `/usr/bin/honk-core`、服务名不是 `honk`，请同时修改 `cores.json` 里的 `binary`、`service`、`service_config`、`service_section` 和 `service_enabled` 字段。

---

## 构建

### GitHub Actions

仓库自带工作流 [`.github/workflows/build.yml`](.github/workflows/build.yml)：

- 推送到 `main` / `master` 或发起 PR：构建并上传 `.apk` artifact；
- 推送 `v*` 标签：构建并自动创建 GitHub Release，附带 `.apk`；
- 手动运行：可指定 ImmortalWrt 版本，默认 `25.12.1`。

发布新版本：

```sh
git tag v1.0.0
git push origin v1.0.0
```

工作流会下载对应的 ImmortalWrt SDK，在 x86_64 主机上交叉编译。由于 LuCI 应用是架构无关的（`PKGARCH:=all`），同一个 `.apk` 可以安装在所有目标设备上。

### 本地 SDK 构建

```sh
# 下载并解压 ImmortalWrt 25.12 SDK（文件名以实际下载页为准）
wget https://downloads.immortalwrt.org/releases/25.12.1/targets/x86/64/immortalwrt-sdk-25.12.1-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
tar --zstd -xf immortalwrt-sdk-25.12.1-*.tar.zst
cd immortalwrt-sdk-25.12.1-*

./scripts/feeds update -a
./scripts/feeds install luci-base

cp -r /path/to/openwrt-gtools/luci-app-gtools package/
make defconfig
make package/luci-app-gtools/compile V=s -j$(nproc)
```

产物位置（具体子目录取决于包来源，`luci` / `gtools` / `base` 等）：

```sh
find bin/packages -name 'luci-app-gtools-*.apk'
```

> 如果本地构建遇到 `base` feed 源 404 或 `csstidy` 哈希不匹配，可参考
> [`.github/workflows/build.yml`](.github/workflows/build.yml) 中的 `Prepare feeds`
> 和 `make defconfig` 步骤：移除 SDK 的 `base` feed，并关闭
> `LUCI_CSSTIDY` / `LUCI_JSMIN` / `LUCI_SRCDIET` / `LUCI_UTMIN`
> 这几个 host 压缩工具（本包只包含文本文件，不需要它们）。

### 作为 feed 使用

在 OpenWrt/ImmortalWrt 源码根目录的 `feeds.conf.default` 中加入：

```conf
src-git gtools https://github.com/580132/openwrt-gtools.git
```

然后：

```sh
./scripts/feeds update gtools
./scripts/feeds install -p gtools luci-app-gtools
make menuconfig   # LuCI → Applications → luci-app-gtools
```

---

## 目录结构

```
openwrt-gtools/
├── .github/workflows/build.yml          # GitHub Actions 构建
├── luci-app-gtools/
│   ├── Makefile                         # OpenWrt/LuCI 包定义
│   ├── htdocs/luci-static/resources/view/gtools/main.js
│   ├── root/etc/config/gtools           # 默认 UCI 配置
│   ├── root/etc/uci-defaults/90-gtools  # 为新核心补 UCI 节
│   ├── root/usr/share/gtools/
│   │   ├── cores.json                   # 核心注册表
│   │   ├── gtools.sh                    # 后台任务与安装逻辑
│   │   ├── meta.uc                      # 读取注册表字段
│   │   ├── select.uc                    # 选择 release 资源
│   │   └── status.uc                    # 生成状态 JSON
│   ├── root/usr/share/luci/menu.d/      # LuCI 菜单
│   └── root/usr/share/rpcd/acl.d/       # LuCI 权限
└── README.md
```

---

## 注意事项 / FAQ

### 提示 `UNTRUSTED signature`

GitHub Actions 构建的包没有 ImmortalWrt 官方签名。使用：

```sh
apk add --allow-untrusted ./luci-app-gtools-*.apk
```

### 升级后包管理器又把核心覆盖了

GTools 直接替换 `/usr/bin/honk-core`。如果之后执行 `apk upgrade` 升级了 `honk` 包，包管理器可能把核心恢复成旧版本。重新在 GTools 里点一次“升级/重新安装”即可。

### 提示“不支持的架构”

honk 上游只提供 `x86_64` 和 `aarch64`。其它架构请使用固件自带包或等待上游支持。

### 无法访问 GitHub API

- 在“全局设置”里填写下载/API 加速地址；
- 或配置 GitHub Token；
- 检查路由器的 DNS、时间和代理设置。

未认证的 GitHub API 限额是每小时 60 次（按出口 IP 计算）。GTools 在 API
返回 403/限流时会自动改用 Releases 页面（`releases.atom` +
`releases/expanded_assets`）继续检查，因此即使限额耗尽也能看到最新版本；
配置 Token 可以让检查更快、更稳定。

### 升级后服务未启动

- 查看页面底部日志；
- 确认内核 ≥ 6.12、存在 `/sys/kernel/btf/vmlinux`（或安装 `vmlinux-btf`）、`/sys/fs/bpf` 已挂载；
- 确认 `/etc/honk/config.dae` 配置有效；
- 若开启了“自动回滚”，GTools 会恢复上一个核心并再次尝试启动；
- 仍失败时，可在“回滚”里手动选择更早的备份。

### 为什么版本没变，按钮却显示“重新安装”

当版本相同但切换了变体或分配器时，需要重新下载对应二进制。按钮会显示“重新安装”，行为与升级一致。

### 空间占用

- 下载和解压使用 `/tmp`（内存盘），大约需要核心大小的 2 倍空间；
- 备份保存在 `/usr/share/gtools/backups/<core>/`，每份约 15–30 MB（honk full 构建）；
- 默认保留 3 份。小闪存设备建议在设置里改成 1 份，或定期清理旧备份。

### 菜单里看不到 GTools

安装后刷新页面，或执行：

```sh
/etc/init.d/rpcd reload
rm -rf /tmp/luci-indexcache.* /tmp/luci-modulecache/
```

然后重新登录 LuCI。

---

## 安全说明

- GTools 以 root 身份运行，会下载并执行上游二进制。请只使用可信的加速服务和 Token。
- `SHA256SUMS` 与二进制来自同一个 release，能防止下载损坏或中间人替换，但不能防止上游本身被入侵。
- 建议保留“自动回滚”和至少 1 份备份。

---

## License

GPL-3.0-or-later。见 [LICENSE](LICENSE)。
