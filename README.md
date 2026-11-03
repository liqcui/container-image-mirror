# container-image-mirror

Centralized automation for mirroring and synchronizing third-party container
images to Suanova Harbor registries.

本仓库**只**负责第三方镜像的复制、版本固定与同步。它不构建软件，不部署
Kubernetes，也不管理自研镜像（`suanova/`、`suanova-private/`）。新增一个需要
同步的镜像只需要改 YAML，不需要改 workflow。

## 设计要点

| 决策 | 原因 |
| --- | --- |
| Skopeo 直接 registry→registry 复制 | 不依赖 Docker daemon，原样保留 manifest list |
| 仅固定版本（pinned） | 生产环境拉到的字节必须可预测；升级是一次可评审的 PR |
| 复制后比对 manifest digest | 不看 `skopeo copy` 的退出码，看目标仓库里的实际字节 |
| 目标路径包含源 Registry 主机名 | 从 pull 地址就能看出镜像来源，且不同 Registry 同名仓库不会冲突 |
| `platforms` 是断言而非过滤器 | `skopeo copy --all` 复制整个 manifest list；声明的架构缺失即失败 |
| 只断言 `linux/amd64` | 集群只有 amd64 节点；不裁剪 manifest list，digest 仍与上游一致 |
| 单次运行只写一个 authfile | 兼容旧版 skopeo，凭据不落盘到仓库 |

## 目录结构

```
images/                 要同步的镜像，按领域分文件（唯一需要日常维护的地方）
config/registries.yaml  源/目标 Registry 声明
config/policies.yaml    全局策略：平台、重试、签名、扫描
scripts/                validate / sync / verify / scan / report
docs/                   新增镜像、路径映射、安全说明
.github/workflows/      PR 校验、手动同步、定时兜底、每周扫描
```

## 清单来源

`images/*.yaml` 与 Harbor `mirrors/` 项目里的实际内容一一对应。每个仓库的
tag、digest 取自 `suanova/cubestack-operator` 的 `[cve-report]` issue——每月
扫描会在 issue 正文里附一张 Artifact 表，列出 tag、digest 和推送时间。

清单里钉的 digest 是上游 manifest list（index）digest。Harbor 中绝大多数仓库
保存的本来就是 index，同 tag 的 digest 与上游一致，首次运行会命中
“Already up to date”——清单的作用是把现状固化成可校验、可评审的声明。

有 12 个仓库（`cloudnative-pg`、`opstree/*`、`perses*`、`prometheus-operator`
等）当初是单架构复制进去的，Harbor 里的 digest 是 amd64 子 manifest digest。
清单按上游 index digest 固定，所以首次同步会把这些 tag 重推成完整 manifest
list；amd64 子 manifest 的字节和 digest 都不变，生产拉取不受影响。

例外：`docker.io/nicolaka/netshoot` 只有浮动的 `latest`，按“仅固定版本”策略
不纳入本仓库管理。

## 快速开始

1. 在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 中创建
   `MIRROR_CREDENTIALS_JSON`，内容形如：

   ```json
   {
     "harbor.isuanova.com": {
       "username": "robot$mirrors+pusher",
       "password": "…"
     }
   }
   ```

   只有声明了 `auth: credentials` 的 Registry 才需要出现；公开源不填即可。

2. 确认 Harbor 上存在 `mirrors` 项目，且 Robot Account 拥有该项目的
   `push` + `pull` 权限（见 [docs/security.md](docs/security.md)）。

3. 本地预览本次会做什么（不写任何仓库、不需要凭据）：

   ```bash
   make dry-run
   make check-sources   # 需要网络，只读：确认 tag 存在、架构齐全
   ```

4. 触发同步：**Actions → Sync images → Run workflow**，`category` 选 `all` 或
   单个文件。合并 `images/**` 的 PR 到 `main` 也会自动触发。

## Manifest 格式

```yaml
apiVersion: mirror.suanova.io/v1alpha1
kind: ImageMirrorList
metadata:
  name: networking            # 必须与文件名一致

spec:
  defaults:
    platforms: [linux/amd64]

  images:
    - name: nginx
      source: docker.io/library/nginx
      target: harbor.isuanova.com/mirrors/docker.io/library/nginx
      versions:
        - tag: "1.31.8"
          # 可选：钉死 digest 后，上游 tag 被重新指向会直接失败
          # digest: sha256:…
      # 可选：覆盖 defaults（例如上游只发布单架构时）
      # platforms: [linux/amd64]
      # signature:
      #   verify: true
      #   keyless:
      #     issuer: https://token.actions.githubusercontent.com
      #     subjectRegExp: https://github.com/org/repo/.+
```

字段约束由 `scripts/validate.jq` 执行，常见的几条：

- `source` / `target` 必须写全 Registry 主机名，且**不能**带 tag 或 digest；
  版本只能写在 `versions[]`。
- `target` 必须是 `<destination>/<project>/<source-host>/<path>`，
  且 `<source-host>` 必须与 `source` 的主机名一致。
- `latest` 默认被拒绝（`config/policies.yaml` 的 `allowLatest`）。
- 同一 `source:tag` 或 `target:tag` 不允许在多个文件里重复出现。

## 同步语义

对 `versions[]` 中的每一项：

1. 解析源 manifest，得到 `sha256:…`（对原始 manifest 字节做哈希）。
2. 如果清单里写了 `digest:` 且与上游不一致 → **drift，拒绝复制**，任务失败。
3. 断言声明的 `platforms` 都存在于源 manifest list 中。
4. 若目标仓库该 tag 已是同一 digest → **skipped**（幂等，可反复执行）。
5. 若目标 tag 已存在但 digest 不同：
   - 清单钉了 `digest` → 视为修复，覆盖为目标应有的字节；
   - 未钉 `digest` → **drift，拒绝覆盖**。此时无法区分"上游移动了 tag"和
     "目标被别的东西占用了"，默认选择不冒险；可用
     `verify.allowDigestReplace: true` 显式放行。
6. `skopeo copy --all`，失败按指数退避重试。
7. 重新读取目标 manifest digest，与源比对；不一致即失败。
8. 可选：Trivy 扫描刚推上去的 digest，并生成 CycloneDX SBOM。

整体退出码：任一版本 `failed` / `drift` / `scan-failed` 即为非零，且会在
Actions Summary 里生成带 digest 的表格（`scripts/generate-report.sh`）。

## 工作流

| Workflow | 触发 | 行为 |
| --- | --- | --- |
| `validate.yaml` | PR、main push | YAML lint、shellcheck、静态校验；无凭据、无网络 |
| `sync-images.yaml` | 手动、`images/**` 合入 main | 按文件矩阵并发同步，可选扫描，产出报告 |
| `scheduled-sync.yaml` | 每天 03:17 | 重新断言固定版本：补缺失、报漂移；**不会**升级版本 |
| `security-scan.yaml` | 每周一 04:41、手动 | 对 Harbor 中现有 digest 做漏洞扫描 + SBOM |

`sync` 与 `security-scan` 都挂在内置的 `production` environment 上，可以在
仓库设置里为它加 required reviewers，让写入 Harbor 变成需要审批的动作。

## 本地使用

需要 `yq` (v4)、`jq`、`skopeo`；扫描需要 `trivy`，签名校验需要 `cosign`。

```bash
make validate                  # 静态校验
make dry-run                   # 只打印计划
make check-sources             # 只读探测源仓库
make sync ARGS="--category observability --tag v3.15.1"
make scan
```

macOS 自带的 bash 3.2 可用；脚本刻意没有使用 `mapfile` 等 bash 4 特性。

## 非目标

- **不跟踪上游新版本。** 本仓库只做固定版本同步。跟进上游是一次 PR，评审者
  能看到版本变化和 digest 变化。
- **不构建镜像。** 自研镜像仍走各自的构建流水线，不应出现在本仓库。
- **不修改 Harbor 项目配置。** `mirrors` 项目与 Robot Account 由 Harbor 管理
  员维护。

更多细节：[新增镜像](docs/adding-images.md) ·
[路径映射](docs/registry-mapping.md) · [安全模型](docs/security.md)
