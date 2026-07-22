# k230-builder 测试体系

分层设计：每次 commit 只跑轻量层；重量级构建在自托管 runner 上手动触发（`workflow_dispatch`），
产出 Markdown 报告。k230-builder 本身改动不频繁，没有必要每天定时跑一次全量，所以不设 cron —— 想验证
某次改动时手动跑一下即可。

| 层 | 脚本 | 内容 | 触发 |
|---|---|---|---|
| T0 静态+单元 | `run.sh`（+ workflow 里的 shellcheck 等） | 工具链别名映射（`resolve_toolchain_set`）、工具链目录三处一致性（toolchain.sh ↔ nncase ↔ entrypoint） | 每次 commit（`test.yml`） |
| T1 镜像 smoke | `smoke.sh` | 镜像内置工具、工具链别名解析、list-toolchains | 每次 commit（`test.yml`） |
| T2 工具链 | `t2-toolchains.sh` | 经 `k230` CLI 下载 TC1/2/3/5（sha256 校验）→ 各自交叉编译 hello.c → readelf 断言 RISC-V | 手动（`regression.yml`） |
| T3 SDK 构建 | `t3-sdk.sh <linux\|rtos\|nuttx>` | `k230 make` / `k230 west build`，断言产出新 `*.img` | 手动（`regression.yml`） |
| T4 nncase | `t4-nncase.sh <compiler\|kmodel\|runtime-*>` | host 编译器 → `fixtures/tiny.onnx` 编成 kmodel（功能验证）→ 三种 on-device runtime | 手动（`regression.yml`） |

编排与报告：`report.sh [stage ...]`（无参数 = 全流水线）。每个 stage 记录 pass/fail/skip（退出码 77 = skip）与耗时，失败附日志末尾 30 行；报告写入 `reports/report-<ts>.md` 与 `reports/latest.md`，在 GitHub Actions 下同时写入 job summary。

## 本地 / runner 上运行

```bash
cp tests/ci.env.example tests/ci.env   # 填 K230_CI_WORKSPACE 等
bash tests/report.sh                   # 全流水线
bash tests/report.sh toolchains        # 只跑某些 stage
bash tests/report.sh image smoke sdk-nuttx
```

## 自托管 runner 准备（regression.yml）

1. 一台 x86_64 Linux 机器，装 docker，runner 用户在 `docker` 组；磁盘建议 ≥100GB。
2. 按 GitHub 官方步骤注册 self-hosted runner，打上 `k230-builder` label（`regression.yml` 的 `runs-on: [self-hosted, k230-builder]`）。
3. 准备好 `$K230_CI_WORKSPACE`（下称 "codebase 目录"）：手工在里面 checkout 好
   `k230_linux_sdk/`、`k230_rtos_sdk/`、`k230_nuttx_sdk/`、`nncase/`、`nncase-k80/`
   （具体布局见 `ci.env.example`），T2-T4 都直接在这些目录里跑构建。这个目录必须放在
   **runner 的 repo checkout 目录之外**（例如 `$HOME/k230-ci`，即 `ci.env.example` 里的默认值），
   因为 `actions/checkout` 每次都会清空 checkout 目录里的未跟踪文件，放里面手工放的 SDK 会被冲掉。
   然后写好 `tests/ci.env`，同样放在仓库 checkout 之外——`regression.yml` 里的 "stage
   tests/ci.env" 步骤会在每次 job 一开始把 `${RUNNER_WORKSPACE}/../../ci.env`（`$RUNNER_WORKSPACE`
   是 `<runner 安装目录>/_work/<repo>`，所以 `ci.env` 实际放在 runner 安装目录本身）复制成
   `tests/ci.env`，所以每次 checkout
   把它清掉也没关系，只需要维护这一份仓库外的 `ci.env` 主副本。
4. 第一次跑会下载 ~5GB 工具链进 `k230_toolchains_ci` 卷，之后增量。

上游 SDK 源码建议 pin 到固定 tag/commit：这样回归失败就能归因于 k230-builder 自身改动，而不是上游漂移。
Linux SDK 默认全量构建较重，可以在 `ci.env` 里把 `K230_CI_LINUX_CMD` 换成该 SDK 支持的更小构建目标
（见 `ci.env.example` 里的说明），不需要改这里的脚本。
`K230_CI_<X>_CMD` 是整段透传给 `bash -c` 执行的，可以写成多条命令的 shell 序列
（如 `"make list-def && make CONF=... && make"`），不局限于单条命令。

## 防 regression 约定

- 一切外部输入 pin 死（工具链 URL+sha256、shellcheck 版本、SDK commit）。
- 产物断言只看"存在 + 新于构建起点 + 尺寸下限"，不做字节比对（构建不可复现）。
- 改 `scripts/toolchain.sh` 的目录名/URL 时，T0 一致性断言会强制同步 `scripts/nncase` 与 `entrypoint.sh`。
- `fixtures/tiny.onnx` 由 `fixtures/gen_tiny_onnx.py` 确定性生成（Conv+Relu，596B），是 kmodel 编译链路的最小功能样本。
