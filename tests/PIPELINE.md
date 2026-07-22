# report.sh 与回归测试流水线详解

本文补充 `tests/README.md` 的总览表格，逐行讲清楚 `report.sh` 以及它调用的
`t2-toolchains.sh` / `t3-sdk.sh` / `t4-nncase.sh` 到底在做什么、接受什么参数、
配置从哪里读。目标读者：想看懂这套脚本、而不只是想跑一下的人。

## 1. 整体链路

```
tests/report.sh                 <- 唯一入口，编排 + 生成报告
  ├─ docker build ...            (stage: image)
  ├─ tests/smoke.sh              (stage: smoke)
  ├─ tests/run.sh                (stage: unit)
  ├─ tests/t2-toolchains.sh      (stage: toolchains)
  ├─ tests/t3-sdk.sh <linux|rtos|nuttx>   (stage: sdk-*)
  └─ tests/t4-nncase.sh <compiler|kmodel|runtime-*>  (stage: nncase-*)
```

`t2/t3/t4` 都不直接跑 docker，而是调用仓库根目录的 `./k230` 这个 wrapper
脚本（跟你手动敲 `k230 make ...` 是同一个东西）。`k230` 再去 `docker run`
拉起 `k230-builder` 镜像，把仓库工作区挂载进容器、把一批 `K230_*` 环境变量
透传进去。所以理解 t2/t3/t4，本质上是理解它们各自拼出了哪条 `k230 ...`
命令。

## 2. report.sh：编排器 + 报告生成器

### 2.1 调用方式

```bash
./tests/report.sh                       # 不带参数 = 跑全部 12 个 stage
./tests/report.sh toolchains            # 只跑一个 stage
./tests/report.sh image smoke sdk-nuttx # 跑指定几个 stage（顺序即你写的顺序）
```

`$@`（命令行参数）直接就是要跑的 stage 列表；不传参数时默认跑
`ALL_STAGES`（report.sh:31-35）：

```
image smoke unit toolchains
sdk-linux sdk-rtos sdk-nuttx
nncase-compiler nncase-kmodel
nncase-runtime-rtos nncase-runtime-linux nncase-runtime-nuttx
```

这个顺序是有依赖关系的（脚本注释里写了，但不会强制检查）：
- `sdk-*` 要在 `image` 之后（需要镜像存在）。
- `nncase-runtime-rtos` / `nncase-runtime-linux` 复用 `sdk-rtos` /
  `sdk-linux` 建出来的 SDK 目录，所以要排在对应 sdk stage 之后。
- `nncase-kmodel` 需要 `nncase-compiler` 先把编译器编出来。

如果你手动挑 stage 跑（比如只跑 `nncase-runtime-rtos`），report.sh
**不会**帮你自动跑前置 stage，前置产物（SDK 目录、编译器 dll）必须已经在
workspace 里，否则该 stage 会 FAIL 或 SKIP（见下文各脚本的判断逻辑）。

### 2.2 配置从哪里读

`report.sh` 开头（第 24-29 行）：

```bash
if [ -f "$HERE/ci.env" ]; then
    set -a; source "$HERE/ci.env"; set +a
fi
export K230_CI_IMAGE="${K230_CI_IMAGE:-k230-builder:regression}"
export K230_CI_VOLUME="${K230_CI_VOLUME:-k230_toolchains_ci}"
```

- 配置文件是 `tests/ci.env`（**不在仓库里，`.gitignore` 掉了**）。你需要
  `cp tests/ci.env.example tests/ci.env` 后自己改。`ci.env.example` 里每一
  行都标了默认值，通常只有 `K230_CI_WORKSPACE` 是必填的（见 2.3）。
- `set -a; source ...; set +a` 的作用是：把 `ci.env` 里定义的所有变量自动
  `export` 出去，这样子进程（`t2/t3/t4` 脚本以及它们再调用的 `k230`）都能
  看到这些变量，不用一个个手动 `export`。
- 之后所有 stage 都通过环境变量（不是命令行参数）拿到配置——这也是为什么
  `t2-toolchains.sh` 之类脚本里到处是 `${K230_CI_XXX:-default}` 这种写法。

`report.sh` 里真正 export 出去、影响子脚本的两个变量：

| 变量 | 默认值 | 含义 |
|---|---|---|
| `K230_CI_IMAGE` | `k230-builder:regression` | 本地构建/测试用的镜像 tag（跟你日常用的 `k230-builder:latest` 分开，避免互相污染） |
| `K230_CI_VOLUME` | `k230_toolchains_ci` | 存工具链下载缓存的 docker volume（跟日常用的 `k230_toolchains` 分开） |

`ci.env` 里其余的 `K230_CI_*` 变量不经过 report.sh 处理，是直接被
t3/t4 读取的（见 2.3、3.2、3.3）。

### 2.3 tests/ci.env.example 里的字段一览

```
K230_CI_WORKSPACE=$HOME/k230-ci      # 必填：SDK/nncase checkout 的根目录
K230_CI_IMAGE / K230_CI_VOLUME       # 同上，可选覆盖默认值
K230_CI_LINUX_SDK / _CMD / _ART      # sdk-linux + nncase-runtime-linux 用
K230_CI_RTOS_SDK  / _CMD / _ART      # sdk-rtos  + nncase-runtime-rtos  用
K230_CI_NUTTX_SDK / _CMD / _ART      # sdk-nuttx 用
K230_CI_NUTTX_EXPORT                 # nncase-runtime-nuttx 用（不设则该 stage 跳过）
K230_CI_REPORT_DIR                   # 报告/日志输出目录，默认 <repo>/reports
```

`K230_CI_WORKSPACE` 要求的目录布局（README 里也画了）：

```
$K230_CI_WORKSPACE/
├── k230_linux_sdk/   sdk-linux 构建，nncase-runtime-linux 复用
├── k230_rtos_sdk/    sdk-rtos  构建，nncase-runtime-rtos  复用
├── k230_nuttx_sdk/   sdk-nuttx 构建（west workspace）
├── nncase/           nncase 基础仓库（缺失时 scripts/nncase 会自动 clone）
└── nncase-k80/       nncase 插件仓库（nncase-* stage 必需，不会自动 clone）
```

这个目录必须放在 git 仓库 checkout 目录**之外**——因为 CI 场景下
`actions/checkout` 每次都会把 checkout 目录里的未跟踪文件清空，手工放进去
的 SDK checkout 会被冲掉。

### 2.4 单个 stage 怎么跑、怎么判定结果

`run_stage()`（report.sh:43-53）把 stage 名字映射到具体命令：

```bash
image)      docker build -f "$REPO/docker/Dockerfile" -t "$K230_CI_IMAGE" "$REPO" ;;
smoke)      "$HERE/smoke.sh" "$K230_CI_IMAGE" ;;
unit)       "$HERE/run.sh" ;;
toolchains) "$HERE/t2-toolchains.sh" ;;
sdk-*)      "$HERE/t3-sdk.sh" "${1#sdk-}" ;;      # 例如 sdk-nuttx -> t3-sdk.sh nuttx
nncase-*)   "$HERE/t4-nncase.sh" "${1#nncase-}" ;; # 例如 nncase-kmodel -> t4-nncase.sh kmodel
```

主循环（第 61-78 行）对每个 stage：

1. 记录开始时间 `start=$SECONDS`。
2. 跑 `run_stage "$st" 2>&1 | tee "$LOG_DIR/$st.log"`，同时输出到终端和落盘日志。
3. 用 `${PIPESTATUS[0]}` 取**命令本身**的退出码（不是 `tee` 的，避免被
   `tee` 恒为 0 的退出码掩盖）。
4. 退出码含义：
   - `0` → ✅ pass
   - `77` → ⏭️ skip（约定的"跳过"退出码，t3/t4 在前置条件缺失时用它，见
     3.2/3.3 里的 `skip()` 函数）
   - 其他 → ❌ **FAIL**，并记入 `failed_stages`，整体 `overall=1`
5. `note` 取该 stage 日志最后一条非空行（截断到 100 字符）作为报告里的
   "备注"列，帮你不用点开日志就能看到 PASS/FAIL 的那句话。

### 2.5 报告输出

跑完全部 stage 后拼一个 Markdown（第 85-106 行），包含：
- 时间、主机名、git 分支/commit、镜像 tag 及其 image ID、工具链卷名
- 一张 Stage / 结果 / 耗时 / 备注 的表格
- 如果有失败 stage，额外一节"失败详情"，每个失败 stage 附日志末尾 30 行

落盘位置（`K230_CI_REPORT_DIR`，默认 `<repo>/reports`，已 gitignore）：

```
reports/report-<TS>.md      本次报告（TS = 时间戳 YYYYmmdd-HHMMSS）
reports/logs-<TS>/<stage>.log   每个 stage 的完整日志
reports/latest.md            指向本次报告的稳定副本（CI artifact 用这个名字上传）
reports/latest-logs/         指向本次日志目录的稳定副本
```

如果在 GitHub Actions 里跑（`$GITHUB_STEP_SUMMARY` 存在），报告内容还会
追加到 job summary，直接在 Actions 页面上就能看到表格。

最终 `exit "$overall"`：只要有一个 stage FAIL，整个 `report.sh` 就非 0
退出；SKIP 不算失败。

## 3. 各阶段脚本详解

### 3.1 image / smoke（unit 见 t0）

- **image**：就是普通的 `docker build`，没有额外逻辑。
- **smoke.sh**（T1）：`./tests/smoke.sh [image]`，默认镜像
  `k230-builder:latest`。只检查"镜像本身烘焙的东西"，**不下载任何工具链**
  （工具链是运行时下载到 volume 里的，见 T2），所以跑得很快：
  1. 容器里必须有 `west/cmake/ninja/dtc/genromfs/gperf/xxd` 和几个 python
     模块（`kconfiglib/Crypto/gmssl`）。
  2. `source /usr/local/bin/toolchain.sh` 后 `resolve_toolchain_set nuttx`
     必须解析成 `tc5`。
  3. `list-toolchains` 输出里必须包含 `TC5`。
- **run.sh**（T0，`unit` stage）：纯 shell 单元测试，不碰 docker。
  1. `source scripts/toolchain.sh` 后逐条断言 `resolve_toolchain_set`
     的别名映射（`tc1`→`tc1`、`linux`→`tc1 tc2`、`rtos`/`rt-smart`→
     `tc1 tc3`、`nuttx`→`tc5`、`llvm`→`tc6`、`all`→`tc1 tc2 tc3 tc5`，未知
     输入应报错）。
  2. 三处目录名一致性检查：`scripts/toolchain.sh` 里 `TCx_DIR` 的默认值,
     必须分别出现在 `scripts/nncase`（`TC_LINUX`/`TC_RTOS`/`TC_NUTTX`
     常量）和 `scripts/entrypoint.sh`（PATH 里的对应目录）里，防止改了
     `toolchain.sh` 里的目录名却忘记同步这两处，导致 nncase 或 PATH
     悄悄失效。

### 3.2 t2-toolchains.sh（stage: `toolchains`）

```bash
K230_CI_IMAGE=k230-builder:regression ./tests/t2-toolchains.sh
```

不接受位置参数；读 `K230_CI_IMAGE`（默认 `k230-builder:latest`）和
`K230_CI_VOLUME`（默认 `k230_toolchains_ci`）。

流程：
1. 先 `docker image inspect` 确认镜像已存在本地（不存在直接 FAIL，提示先
   跑 `image` stage）。
2. 生成一个临时目录，写入 `hello.c`（`int main(void){return 42;}`）和一个
   `check.sh`。
3. 执行 `"$REPO/k230" download-toolchains all`——也就是走真实的 `k230`
   CLI，在容器里 `source toolchain.sh` 后依次跑 `download_tc1/tc2/tc3/tc5`
   （`all` 展开成 `tc1 tc2 tc3 tc5`，见 `resolve_toolchain_set`）。每个
   `download_tcN` 会：查 volume 里是否已装好且版本匹配（`.installed` +
   `.version` 文件）→ 没有就下载（`download_with_fallback`，多个镜像源轮流
   试、优先非 kendryte 源）→ sha256 校验 → 解压改名 → 写版本戳。第一次跑要
   下载约 5GB，之后因为装在持久 volume 里，是增量/near-free 的。
4. 再执行 `"$REPO/k230" bash check.sh`，在容器里对每个工具链跑
   `check()`：确认对应 gcc 存在、`--version` 正常、能编译（TC1/2/3 是
   link，TC5 是裸机只 `-c` 编译 object）、产物用 `readelf -h` 确认是
   `RISC-V` ELF。TC5 额外确认存在 `riscv64-unknown-elf-gcc` 这个别名
   symlink（OpenSBI 构建要用）。
5. 全过则打印 `[t2] PASS`，`set -euo pipefail` 保证任何一步出错都会让脚本
   非 0 退出。

这一步的意义：把"工具链 URL/sha256 失效"或"解压后的目录结构变了"这种问题
提前到几分钟内暴露，而不是让它在一小时后的 SDK 构建中间才报错。

### 3.3 t3-sdk.sh（stage: `sdk-linux` / `sdk-rtos` / `sdk-nuttx`）

```bash
./tests/t3-sdk.sh <linux|rtos|nuttx>
```

唯一位置参数是目标名（`report.sh` 传入时是从 `sdk-nuttx` 里剥掉
`sdk-` 前缀得到的 `nuttx`）。

先根据目标名取三个配置（每个都可被 `ci.env` 覆盖，默认值见下表）：

| target | SDK 目录变量（默认目录名） | 构建命令变量（默认值） | 产物 glob 变量（默认值） |
|---|---|---|---|
| linux | `K230_CI_LINUX_SDK`（`k230_linux_sdk`） | `K230_CI_LINUX_CMD`（`make CONF=k230_canmv_defconfig`） | `K230_CI_LINUX_ART`（`*.img`） |
| rtos  | `K230_CI_RTOS_SDK`（`k230_rtos_sdk`）   | `K230_CI_RTOS_CMD`（同上） | `K230_CI_RTOS_ART`（`*.img`） |
| nuttx | `K230_CI_NUTTX_SDK`（`k230_nuttx_sdk`） | `K230_CI_NUTTX_CMD`（`west build`） | `K230_CI_NUTTX_ART`（`*.img`） |

流程：
1. SDK 目录若是绝对路径直接用；否则要求 `K230_CI_WORKSPACE` 已设置，拼成
   `$K230_CI_WORKSPACE/$sdk`。目录不存在 → `exit 77`（SKIP，不是失败）。
2. 确认镜像存在（同 t2）。
3. `cd` 进 SDK 目录，先 `"$REPO/k230" download-toolchains "$target"`
   把这条 SDK 线要用到的工具链准备好（`linux`→TC1+TC2，`rtos`→TC1+TC3，
   `nuttx`→TC5）。
4. 记录一个 `mktemp` 出来的空文件 `marker`（只用它的 mtime 做时间基准）。
5. 把 `$cmd` 整串交给 `"$REPO/k230" bash -c "$cmd"` 执行——走的是真正的
   shell，而不是按空格拆词后直接 exec argv。所以 `K230_CI_<X>_CMD` 可以是
   一整段 shell 序列（`"make list-def && make CONF=... && make"`、
   `"a; b; c"` 等），不必只是单条命令；单条命令原样兼容。
6. 构建完，`find . -name "$art" -newer "$marker" -size +1M` 找"比构建起点
   新、且大于 1MB"的匹配文件。一个都没有就 FAIL。**故意不做字节级比对**
   （SDK 构建本来就不可复现），只断言"确实产出了新的、够大的东西"。

这解释了为什么 Linux SDK 默认命令很重（全量内核+rootfs+应用）：如果你的
`k230_linux_sdk` checkout 支持更小的构建目标（比如只 `make uboot`/
`make linux`），可以在 `ci.env` 里把 `K230_CI_LINUX_CMD` 换成那个更窄的
命令，同时把 `K230_CI_LINUX_ART` 收紧到匹配那个产物的 glob——不需要改
`t3-sdk.sh` 本身。

### 3.4 t4-nncase.sh（stage: `nncase-compiler` / `nncase-kmodel` / `nncase-runtime-*`）

```bash
./tests/t4-nncase.sh <compiler|kmodel|runtime-rtos|runtime-linux|runtime-nuttx>
```

前置检查（对所有子命令都一样）：
- `K230_CI_WORKSPACE` 必须设置且存在，否则 SKIP。
- `has_plugin()`：workspace 下必须能找到一个含
  `modules/Nncase.Modules.K230` 的目录——要么是
  `$NNCASE_PLUGIN_DIR`（如果设置了），要么扫 workspace 的一级子目录。找不到
  就 SKIP（这是 nncase-k80 插件仓库，前面 2.3 提到过，**不会自动 clone**，
  必须手工 checkout 到 workspace 里）。
- 镜像必须存在（同 t2/t3）。

内部有个 `run_k230()` 帮助函数：接受一串 `ENV=VAL` 再跟 `--` 再跟真正的
`k230` 参数，`cd` 到 `$WS`（workspace）后拼出
`env ENV=VAL... K230_BUILDER_IMAGE=$IMAGE K230_BUILDER_VOLUME=$VOLUME
"$REPO/k230" <args>` 来执行——所有 nncase 相关操作都是在 workspace 目录里
跑 `k230 nncase ...`（对应容器内的 `scripts/nncase` 脚本）。

各子命令：

- **compiler**：`run_k230 -- nncase compiler`。这会在容器里依次
  `conan install/cmake build` 基础 nncase 仓库（native，x86）、
  再建 K230 插件的 native 模拟器、最后 `dotnet build` C# 编译器。
  完成后断言
  `$WS/$BASE/src/Nncase.Compiler/bin/Release/net7.0/Nncase.Compiler.dll`
  存在（`$BASE` 默认 `nncase`，可用 `NNCASE_BASE_DIR` 覆盖）。这一步只需要
  host 编译器，不需要任何 RISC-V 工具链。

- **kmodel**：把 `tests/fixtures/tiny.onnx`（596B，一个 Conv+Relu 的
  确定性小模型，由 `fixtures/gen_tiny_onnx.py` 生成）拷进 workspace，
  跑 `run_k230 -- nncase kmodel .ci-tiny.onnx .ci-tiny.kmodel`，即用刚才
  编出的 `Nncase.Compiler.dll` 通过 Python 绑定把 onnx 编成 kmodel。断言
  产物存在且 ≥1024 字节。**这是整条编译器链路唯一的"功能性"验证**——不只是
  编译器能编出来，而是它编出的东西看起来是合理的 kmodel。要求 `compiler`
  stage 已经先跑过。

- **runtime-rtos / runtime-linux**：分别要求
  `$WS/$sdk`（`K230_CI_RTOS_SDK`/`K230_CI_LINUX_SDK`，默认
  `k230_rtos_sdk`/`k230_linux_sdk`）已经被 `sdk-rtos`/`sdk-linux` stage
  构建出来，否则 SKIP。先 `download-toolchains rtos|linux` 确保对应
  工具链就绪，再
  `run_k230 K230_RTOS_SDK_DIR=$sdk -- nncase runtime rtos`（linux 同理，
  变量是 `K230_LINUX_SDK_DIR`）。这一步在容器里用 SDK 提供的 `link.lds`
  + libmmz 去 conan/cmake 建 nncase 的设备端 runtime（RISC-V 静态库）。
  完成后 `assert_static_libs`：确认
  `$WS/nncase_rtt_runtime`（或 `nncase_linux_runtime`）目录下有
  `*.a` 文件。

- **runtime-nuttx**：额外要求 `K230_CI_NUTTX_EXPORT`
  （workspace 下的一个目录名）已设置，且该目录下有 `include/`（说明是一个
  合法的 NuttX *export sysroot*，不是随便一个目录）。没设置就直接 SKIP——
  意味着这个 stage 默认是关闭的，得显式配置。跑
  `download-toolchains nuttx` 后
  `run_k230 K230_NUTTX_EXPORT_DIR=$exp -- nncase runtime nuttx`，断言
  `$WS/nncase_nuttx_runtime` 下有 `*.a`。跟 rtos/linux 不同，nuttx 这条
  线没有 SDK 构建产出的 linker script 可用——它只产出静态库，交给 NuttX
  自己的构建系统去链接进最终镜像。

## 4. 一次典型的本地运行

```bash
cd k230-builder
cp tests/ci.env.example tests/ci.env
$EDITOR tests/ci.env          # 至少填 K230_CI_WORKSPACE，按需覆盖 SDK/构建命令

# 先准备 $K230_CI_WORKSPACE 下的四个 checkout（README 第 3 步）：
#   k230_linux_sdk/ k230_rtos_sdk/ k230_nuttx_sdk/ nncase-k80/

bash tests/report.sh                 # 全流水线（很重，首次 ~5GB 下载 + 多个 SDK 全量构建）
bash tests/report.sh toolchains      # 只验证工具链下载/交叉编译（几分钟级别）
bash tests/report.sh image smoke sdk-nuttx nncase-runtime-nuttx
```

跑完后看：
```bash
cat reports/latest.md              # 汇总表格
ls reports/latest-logs/            # 每个 stage 的完整日志（<stage>.log）
```

某个 stage 显示 `⏭️ skip` 时，去对应日志找 `SKIP: <原因>` 那一行——通常是
`ci.env` 里少配了一个目录，或者对应的 SDK/插件仓库还没在 workspace 里
checkout 出来。

## 5. 与 `k230` CLI 的关系（为什么 t2/t3/t4 里看不到 docker run）

`t2/t3/t4` 全程不直接调 `docker`，而是设置 `K230_BUILDER_IMAGE` /
`K230_BUILDER_VOLUME` 环境变量后调用仓库根的 `./k230`。`k230` 负责：
1. 解析要用哪个镜像（`K230_BUILDER_IMAGE` 优先，否则
   `ghcr.io/.../k230-builder:$K230_BUILDER_TAG`），必要时 ghcr→kendryte
   镜像源自动 fallback 拉取。
2. 把当前目录（对 t3/t4 来说就是那个 SDK/workspace 目录）挂载为容器内的
   `/workspace`，把宿主机 SSH key、`.gitconfig`、docker socket（`nncase
   wheel` 需要）一并挂进去。
3. 透传一批白名单环境变量进容器（`K230_RTOS_SDK_DIR` /
   `K230_LINUX_SDK_DIR` / `K230_NUTTX_EXPORT_DIR` / `NNCASE_*` 等）——这就是
   t4 里 `run_k230 K230_RTOS_SDK_DIR=$sdk -- ...` 那个变量最终怎么传进容器
   的。
4. 把 `download-toolchains` / `nncase` / `make` / `west` /
   `bash <script>` 这些子命令原样作为容器的启动命令执行——容器内对应的
   实现分别是 `scripts/download-toolchains`（调用 `toolchain.sh` 里的
   `resolve_toolchain_set` + `download_tcN`）和 `scripts/nncase`
   （`cmd_compiler` / `cmd_runtime` / `cmd_kmodel`，即 3.4 节描述的那些
   conan/cmake/dotnet 步骤）。

也就是说：**t2/t3/t4 本身很薄**，它们只是拼 `k230` 命令行、检查前置条件、
断言产物；真正的下载/编译逻辑都在容器镜像里的 `scripts/*`（尤其是
`toolchain.sh` 和 `nncase`）。想改"下载哪个 URL""怎么编译 runtime"，要去
改那些脚本，而不是 `tests/` 下的这几个测试脚本。
