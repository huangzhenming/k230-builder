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

### 编译 nncase（K230 神经网络编译器 / 运行时）

nncase 有**两个产物**：**host 编译器**（跑在 x86，把 ONNX/TFLite 编译成 `.kmodel`）和 **on-device 运行时**（跑在 K230，加载并执行 `.kmodel`）。所需工具已全部烤进镜像、运行时零安装：conan 2.6.0、.NET SDK 7.0.302、CMake 3.31（`/opt/cmake`，供 nncase 用；SDK 构建仍用默认 apt cmake 3.22）、ninja、`python3-dev`、`numpy`、`uuid-dev`，以及 RISC-V TC2/TC3 工具链。

> nncase-k80 插件仓库**不自包含**，需要同级的基础 `nncase` 主仓（`kendryte/nncase`）。因为 `k230` 只挂载当前目录，请在**同时包含两个仓库的父目录**下运行：

```bash
work/
├── nncase          # 基础主仓 (kendryte/nncase, 缺失时 nncase 脚本会自动 clone v2.11.0)
└── nncase-k80      # 插件仓 (本项目, 自动探测)
```

```bash
cd work/

# 产物①：host 编译器（x86，不需要 RISC-V 工具链）
k230 nncase compiler

# 用编译器把模型编成 kmodel
k230 nncase kmodel nncase-k80/model.onnx model.kmodel

# 产物②：on-device 运行时（需对应工具链 + 已构建的 K230 SDK）
# rtos 用 musl/TC3，linux 用 Xuantie/TC2；K230_PROFILE 会自动下载工具链
K230_PROFILE=rtos  K230_RTOS_SDK_DIR=k230_rtos_sdk   k230 nncase runtime rtos
K230_PROFILE=linux K230_LINUX_SDK_DIR=k230_linux_sdk k230 nncase runtime linux
```

> **运行时构建必须提供已构建的 K230 SDK 目录**（`K230_RTOS_SDK_DIR` / `K230_LINUX_SDK_DIR`）：
> 插件的交叉工具链会把 SDK 的链接脚本 `link.lds` 注入链接参数、并链接 `libmmz`，
> 缺失会导致连编译器自检都过不了。请先用 `k230 make` / `k230 west` 把对应 SDK 构建好，
> 再把其目录（工作区内相对路径或绝对路径）传给上面的变量。

#### 打 wheel（与 CI 一致的可分发产物）

三个 wheel，和 nncase CI 的 artifacts 对应：

```bash
cd work/
k230 nncase wheel base       # 基础 'nncase' wheel        (cibuildwheel/manylinux2014)
k230 nncase wheel kpu        # 'nncase-kpu' 插件 wheel     (cibuildwheel/manylinux2014)
K230_LINUX_SDK_DIR=k230_linux_sdk k230 nncase wheel runtime   # 'nncaseruntime_k230' 板上 wheel (python -m build)
```

产物落在工作区：`wheelhouse-nncase/`、`k230-wheelhouse-linux/`、`nncase_k230_runtime_wheel_linux/`。

> **base / kpu wheel 用 cibuildwheel**，它会再启动 manylinux 容器来编（多 CPython 版本 cp39–cp313）。
> 这需要**宿主 docker socket**（`k230` 已自动挂载），且 `nncase wheel` 命令会自动改用**同路径挂载**
> （宿主 cwd 挂到容器内相同路径），以便嵌套的 manylinux 容器能正确 bind-mount 工程目录。
> 首次会拉取 `sunnycase/manylinux2014_x86_64:1.2` 镜像。
> 想快速冒烟只编单个 python 版本：`NNCASE_WHEEL_BUILD='cp310-*' k230 nncase wheel kpu`。
> `runtime` wheel 用 `python -m build`，不涉及 cibuildwheel，但需要已构建的 Linux SDK。

可调环境变量：`NNCASE_BASE_DIR`（基础主仓目录名，默认 `nncase`）、`NNCASE_PLUGIN_DIR`（插件仓目录名，默认自动探测）、`NNCASE_TAG`（基础主仓 clone 的 tag，默认 `v2.11.0`）、`K230_RTOS_SDK_DIR`/`K230_LINUX_SDK_DIR`。conan/NuGet 依赖缓存落在持久卷 `k230_toolchains` 内，只下载一次。

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
│   ├── entrypoint.sh    # 容器入口（用户创建、SSH、工具链、构建缓存）
│   ├── toolchain.sh     # 工具链下载/校验/安装
│   ├── nncase           # 容器内 nncase 构建 CLI（compiler / runtime / kmodel）
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
