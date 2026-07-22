# 🚀 k230-builder

Docker build environment for K230 Linux & RTOS SDKs — one image, four toolchains.

---

## 首次安装

### 1. 安装 `k230` 命令

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

### 2. 拉取镜像

```bash
k230 pull                      # 拉取最新镜像
```

### 3. 下载工具链

```bash
k230 download-toolchains < linux | rtos | rt-smart | nuttx | all | TC1..TC6 > [...]
```

download-toolchains 会根据 SDK 类型参数，自动下载相应的编译工具链.
下载完成的工具链存放在 Docker 数据卷 `k230_toolchains` 中，只下载一次，首次启动 ~10GB 磁盘，下载耗时取决于网络。

| 名字 | 工具链 |
|---|---|
| `linux` | 下载 K230 Linux SDK 所需要的工具链 |
| `rtos`、`rt-smart`（同义词） | 下载 K230 RT-Smart SDK 所需要的工具链 |
| `nuttx` | 下载 K230 nuttx SDK 所需要的工具链 |
| `all` |  下载全部工具链（数十 GB， 非必要请勿使用此参数）|
| `TCx` | 手动指定要下载的工具链|

---

## 编译 SDK

### 编译 RT-Smart SDK

```bash
cd your-k230-rtos-sdk/
k230 download-toolchains rtos
k230 make CONF=k230_canmv_defconfig
```

### 编译 Linux SDK

```bash
cd your-k230-linux-sdk/
k230 download-toolchains linux
k230 make CONF=k230_canmv_defconfig
```

### 编译 NuttX SDK

NuttX SDK 用 `west`（已内置）+ 裸机工具链（TC5）：

```bash
cd your-k230-nuttx-sdk/          # west 工作区
k230 download-toolchains nuttx
k230 west update                 # 同步组件仓
k230 west build                  # opensbi → nuttx → image，产出 k230-nuttx-sdcard.img
k230 west build --list-def       # 查看可选 board/config
```

容器内 `riscv-none-elf-gcc`（NuttX cmake 自动识别）与 `riscv64-unknown-elf-gcc`（OpenSBI 用，
指向前者的符号链接）都在 PATH。

---

## 常用命令

```bash
k230 bash                      # 进入容器交互 shell
k230 make                      # 透传任意命令到容器
k230 pull                      # 手动拉取最新镜像
k230 pull dev                  # 拉取指定版本
```

### Git 与 SSH

`k230` 自动挂载宿主机的 `~/.ssh` 和 `~/.gitconfig`，容器内可直接 `git clone` / `repo sync`。

如宿主机有 git 对象缓存：

```bash
export K230_GIT_MIRROR=/data/git-mirror/repos
k230 bash
repo sync --reference=/data/git-mirror/repos
```

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
│   ├── entrypoint.sh    # 容器入口（用户创建、SSH、工具链、构建缓存）
│   ├── toolchain.sh     # 工具链下载/校验/安装
│   └── nncase           # 容器内 nncase 构建 CLI（compiler / runtime / kmodel，内部使用）
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
