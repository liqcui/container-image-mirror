# 安全模型

## 凭据

### 存哪里

所有 Registry 凭据放在**一个** GitHub Actions secret 里：

```
MIRROR_CREDENTIALS_JSON
```

```json
{
  "harbor.isuanova.com": {
    "username": "robot$mirrors+pusher",
    "password": "…"
  },
  "quay.io": {
    "username": "…",
    "password": "…"
  }
}
```

- 只出现在 workflow 的 `env:` 中，由脚本在 `$RUNNER_TEMP` 里生成临时
  authfile（权限 `600`），进程退出时删除。
- 仓库里不出现任何凭据，`config/registries.yaml` 只声明"这个主机需要认证"。
- 新增源 Registry 只需要改 secret 内容，不需要改 workflow。

### 用 Robot Account

Harbor 侧使用专职 Robot Account，不要用个人账号：

| 项目 | 权限 | 说明 |
| --- | --- | --- |
| `mirrors` | push + pull | 同步写入 |

最小化的做法是给 Robot Account 只授予 `mirrors` 项目的 push/pull，不要给
系统管理员或 `library` 之类的额外权限。源 Registry 的凭据按需配置——绝大多数
公开源（Docker Hub、Quay、GHCR、registry.k8s.io、MCR）匿名即可拉取。

## PR 与凭据隔离

- `validate.yaml` 在 PR 上运行，**没有**任何 Registry 凭据，也不访问 Registry。
  它只做静态校验 + YAML lint + shellcheck。
- 写入 Harbor 只发生在 `main` 分支的 push、手动触发和定时任务中。
- PR 被 fork 时也拿不到 secrets（GitHub 默认行为），不要用
  `pull_request_target` 来绕过这一点。
- `permissions:` 显式声明为 `contents: read`，不给默认的写权限。

## 审批闸门

`sync` 与 `security-scan` 作业挂在 `production` environment 上。建议在
**Settings → Environments → production** 配置：

- Required reviewers（合并后的同步需要人工批准）
- 限制可部署分支为 `main`

这样即使有人改坏了清单，也不能在未审批的情况下把镜像推进生产 Registry。

## 供应链校验

### Digest 校验（默认开启）

每次复制后重新读取目标 manifest，与源 digest 比对，不一致即失败。这是本仓库
最重要的完整性检查，且不依赖 `skopeo` 的退出码。

清单里写 `digest:` 会进一步把上游 tag 也变成断言：上游 tag 若被重新指向，同步
报告 `drift` 并拒绝覆盖目标。

### 不静默覆盖已有 tag

目标 tag 已存在、但 digest 与源不同时：

- 清单钉了 `digest` → 允许覆盖（这是把目标修复成清单声明的状态）。
- 未钉 `digest` → 报 `drift` 并停止。未钉 digest 时无法判断哪一边才是"对的"，
  默认不覆盖，避免上游悄悄移动 tag 就改写生产环境拉取的字节。

需要放行时，在 `config/policies.yaml` 里设置
`verify.allowDigestReplace: true`，并在 PR 中说明理由。

### 签名验证（按镜像开启）

`config/policies.yaml` 里 `signature.enabled` 只是总开关的语义说明，真正生效的
是每个镜像的 `signature.verify`。绝大多数上游项目尚未签名，因此默认关闭。

```yaml
      signature:
        verify: true
        keyless:
          issuer: https://token.actions.githubusercontent.com
          subjectRegExp: https://github.com/org/repo/.+
```

签名验证在复制**之前**对源镜像的 digest 执行。校验失败时按
`signature.onMissing` 处理：`warn` 记录并继续，`fail` 中止该镜像。

### 漏洞扫描（默认开启）

`security-scan.yaml` 每周对 Harbor 中现有 digest 扫描一次，产出 JSON 报告和
CycloneDX SBOM，作为 Actions artifact 保留 90 天。

- 同步时也可以顺带扫描（workflow 的 `scan` 输入，默认开）。
- `scan.failOnFindings` 默认 `false`：先积累基线，再决定是否让高危直接阻断。
- 扫描对象是 `target@<digest>`，不是 tag，避免 tag 变动让报告失真。

## 审计

`scripts/generate-report.sh` 生成的报告包含每个镜像的 `target` 与
`targetDigest`，写入 Actions Summary。需要长期留存时，把 workflow 的报告步骤
接一个 artifact 或外部日志系统即可。

## 已知边界

- `skopeo copy --all` 会复制 manifest list 里的**全部**平台，`platforms` 只做
  断言。想裁剪平台需要重写 manifest list，会改变 digest，本仓库不做这件事。
- 上游直接发布单架构 manifest（没有 manifest list）时，平台断言改为读取镜像
  config 的 `os` / `architecture`，结论一样，只是不再经过 manifest list。
- Harbor 的 tag 不可变策略与"上游 tag 漂移"冲突时，同步会失败并等待人工处理，
  这是刻意选择：宁可停下来，也不静默覆盖已发布的内容。
- 凭据以明文 JSON 形式存在于 secret 与临时 authfile 中；runner 是 GitHub 托管的
  一次性实例，authfile 在作业结束后随实例销毁。
