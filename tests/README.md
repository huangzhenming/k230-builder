# k230-builder 测试体系

分层设计：每次 commit 只跑轻量层；重量级构建在自托管 runner 上 nightly 跑，产出 Markdown 报告。

| 层 | 脚本 | 内容 | 触发 |
|---|---|---|---|
| T0 静态+单元 | `run.sh`（+ workflow 里的 shellcheck 等） | profile 映射、工具链目录三处一致性（toolchain.sh ↔ nncase ↔ entrypoint） | 每次 commit（`test.yml`） |
| T1 镜像 smoke | `smoke.sh` | 镜像内置工具、profile 解析、list-toolchains | 每次 commit（`test.yml`） |
| T2 工具链 | `t2-toolchains.sh` | 经 `k230` CLI 下载 TC1/2/3/5（sha256 校验）→ 各自交叉编译 hello.c → readelf 断言 RISC-V | nightly |
| T3 SDK 构建 | `t3-sdk.sh <linux\|rtos\|nuttx>` | `k230 make` / `k230 west build`，断言产出新 `*.img` | nightly |
| T4 nncase | `t4-nncase.sh <compiler\|kmodel\|runtime-*>` | host 编译器 → `fixtures/tiny.onnx` 编成 kmodel（功能验证）→ 三种 on-device runtime | nightly |

编排与报告：`report.sh [stage ...]`（无参数 = 全流水线）。每个 stage 记录 pass/fail/skip（退出码 77 = skip）与耗时，失败附日志末尾 30 行；报告写入 `reports/report-<ts>.md` 与 `reports/latest.md`，在 GitHub Actions 下同时写入 job summary。

## 本地 / runner 上运行

```bash
cp tests/ci.env.example tests/ci.env   # 填 K230_CI_WORKSPACE 等
bash tests/report.sh                   # 全流水线
bash tests/report.sh toolchains        # 只跑某些 stage
bash tests/report.sh image smoke sdk-nuttx
```

## 自托管 runner 准备（nightly.yml）

1. 一台 x86_64 Linux 机器，装 docker，runner 用户在 `docker` 组；磁盘建议 ≥100GB。
2. 按 GitHub 官方步骤注册 self-hosted runner，打上 `k230-builder` label（`nightly.yml` 的 `runs-on: [self-hosted, k230-builder]`）。
3. 准备 `$K230_CI_WORKSPACE`（SDK 源码 checkout + nncase-k80 仓），写好 `tests/ci.env`。
   注意 runner 的 workspace 目录在 checkout 时会被清理，`ci.env` 放在 runner 上仓库外再软链，或直接用环境变量（Actions runner 的 `.env` 文件）。
4. 首晚会下载 ~5GB 工具链进 `k230_toolchains_ci` 卷，之后增量。

上游 SDK 源码建议 pin 到固定 tag/commit：nightly 失败即可归因于 k230-builder 自身改动。另可手动 `workflow_dispatch` 跑"追上游 HEAD"来发现上游兼容性问题。

## 防 regression 约定

- 一切外部输入 pin 死（工具链 URL+sha256、shellcheck 版本、SDK commit）。
- 产物断言只看"存在 + 新于构建起点 + 尺寸下限"，不做字节比对（构建不可复现）。
- 改 `scripts/toolchain.sh` 的目录名/URL 时，T0 一致性断言会强制同步 `scripts/nncase` 与 `entrypoint.sh`。
- `fixtures/tiny.onnx` 由 `fixtures/gen_tiny_onnx.py` 确定性生成（Conv+Relu，596B），是 kmodel 编译链路的最小功能样本。
