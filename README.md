# 🚀 k230-builder

Docker build environment for K230 Linux & RTOS SDKs — one image, four toolchains.

---

## 使用

### 安装

国内用户（推荐）：
```bash
curl -fsSL https://www.kendryte.com/misc/install.sh | bash
```

GitHub（备选）：
```bash
curl -fsSL https://raw.githubusercontent.com/huangzhenming/k230-builder/main/install.sh | bash
```

安装后执行 `source ~/.bashrc` 使 PATH 生效。如需卸载：
```bash
curl -fsSL https://www.kendryte.com/misc/install.sh | bash -s -- --uninstall
```

### 编译 SDK

```bash
cd your-k230-sdk/
k230 make CONF=k230_canmv_defconfig
```

`k230` 自动处理镜像拉取、工具链下载、用户映射。默认不下载 TC4（ILP32），如需启用：
```bash
ENABLE_TC4=1 k230 make CONF=k230_evb_defconfig
```

### 编译 NuttX SDK

NuttX SDK 用 `west`（已内置）+ 裸机工具链（TC5）。设 `K230_PROFILE=nuttx` 即只拉这一套：
```bash
cd your-k230-nuttx-sdk/          # west 工作区
export K230_PROFILE=nuttx
k230 west update                 # 同步组件仓
k230 west build                  # opensbi → nuttx → image，产出 k230-nuttx-sdcard.img
k230 west build --list-def       # 查看可选 board/config
```
容器内 `riscv-none-elf-gcc`（NuttX cmake 自动识别）与 `riscv64-unknown-elf-gcc`（OpenSBI 用，
指向前者的符号链接）都在 PATH。

**将来切 LLVM**：设 `TC6_URLS` 指向 clang 工具链（提供 `riscv64-unknown-elf-clang` /
`-llvm-*`）+ 目标 defconfig 打开 `CONFIG_ARCH_TOOLCHAIN_CLANG=y` 即可；OpenSBI 侧可用
`K230_CROSS_COMPILE` 覆盖前缀。

### 镜像选择

| 网络环境 | 行为 |
|---------|------|
| 全球 | 从 `ghcr.io/huangzhenming/k230-builder` 拉取 |
| 中国 | ghcr 不可达时自动切换 `registry.kendryte.com/k230-builder` |

手动指定版本：
```bash
K230_BUILDER_TAG=dev k230 make
K230_BUILDER_TAG=v1.0.0 k230 bash
```

### 常用命令

```bash
k230 bash                      # 进入容器交互 shell
k230 make                      # 透传任意命令到容器
k230 pull                      # 手动拉取最新镜像
k230 pull dev                  # 拉取指定版本
```

容器内：
```bash
k230 env                       # 查看工具链状态
k230 setup tc2                 # 单独下载某套工具链
k230 linux / k230 rtos         # 切换 SDK 环境
```

### Git 与 SSH

`k230` 自动挂载宿主机的 `~/.ssh` 和 `~/.gitconfig`，容器内可直接 `git clone` / `repo sync`。

如宿主机有 git 对象缓存：
```bash
export K230_GIT_MIRROR=/data/git-mirror/repos
k230 bash
repo sync --reference=/data/git-mirror/repos
```

### 工具链

| ID | 名称 | 用途 |
|----|------|------|
| TC1 | Xuantie-900 5.10.4 (glibc) | RTOS U-Boot, OpenSBI |
| TC2 | Xuantie-900 6.6.0 (glibc) | Linux SDK 全组件 |
| TC3 | Musl RT-Smart | RTOS RT-Smart, MPP, CanMV |
| TC4 | RuyiSDK ILP32 (elf) | Linux ILP32 内核 |
| TC5 | xPack riscv-none-elf GCC 13.2.0 | **NuttX SDK**（裸机；含 `riscv64-unknown-elf-*` 符号链接）|
| TC6 | LLVM / clang（预留）| NuttX SDK 将来切 LLVM（默认关，设 `TC6_URLS` 启用）|

工具链存放在 Docker Volume `k230_toolchains` 中，只下载一次。首次启动 ~10GB 磁盘，下载耗时取决于网络。

### PROFILE：按需下载工具链

`K230_PROFILE` 决定下载哪几套工具链（**显式 `ENABLE_TCx` 覆盖 profile**）：

| PROFILE | 工具链 |
|---|---|
| `nuttx` | TC5（只拉一套裸机 GCC，不下 10GB Linux 工具链）|
| `linux` | TC1 + TC2 |
| `rtos`  | TC1 + TC3 |
| `all`   | TC1 + TC2 + TC3 + TC5 |
| *未设置* | legacy：按 `ENABLE_TC*` 现状（不破坏现有 RTOS/Linux 用法）|

显式设置 profile 时，容器启动会**自动下载**对应工具链，故 `K230_PROFILE=nuttx k230 west build`
一条命令即可。未设 profile 时仍按需（`k230 download-toolchains`）。

---

## 开发

### 构建

```bash
./build.sh              # git-count + short hash 版本号
./build.sh --no-cache   # 强制完整重建
```

### 项目结构

```
├── k230                 # 宿主端 wrapper 脚本
├── build.sh             # 本地构建脚本
├── docker/Dockerfile    # 镜像定义
├── scripts/
│   ├── entrypoint.sh    # 容器入口（用户创建、SSH、工具链）
│   ├── toolchain.sh     # 工具链下载/校验/安装
│   ├── k230             # 容器内 CLI
│   └── env.sh           # 环境变量导出
└── .github/workflows/   # CI：tag push → GHCR + Release
```

### CI/CD

推送 `v*` tag 触发自动构建并发布 GitHub Release：
```bash
git tag v1.0.0 && git push origin v1.0.0
```

---

## License

MIT
