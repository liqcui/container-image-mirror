# Registry 与路径映射

## Harbor 项目划分

| 项目 | 用途 | 谁维护 |
| --- | --- | --- |
| `suanova/` | 自研镜像（CubeStack、CubeRouter 等） | 各自构建流水线 |
| `suanova-private/` | 私有镜像 | 各自构建流水线 |
| `mirrors/` | 第三方镜像 | **本仓库** |

本仓库只写 `mirrors/`。`config/registries.yaml` 里 `destinations[].project` 与
`validate.sh` 的校验共同保证这一点：`target` 不落在声明的项目下会直接校验失败。

`images/*.yaml` 里的 tag 与 digest 来自 `suanova/cubestack-operator` 的
`[cve-report]` issue（Artifact 表），与 `mirrors/` 中的实际内容一一对应。

## 映射规则

```
<源 Registry>/<仓库路径>:<tag>
        │
        ▼
<Harbor>/<project>/<源 Registry>/<仓库路径>:<tag>
```

| 源 | 镜像后 |
| --- | --- |
| `docker.io/library/nginx:1.30.1-alpine` | `harbor.isuanova.com/mirrors/docker.io/library/nginx:1.30.1-alpine` |
| `quay.io/prometheus/alertmanager:v0.34.0` | `harbor.isuanova.com/mirrors/quay.io/prometheus/alertmanager:v0.34.0` |
| `ghcr.io/kube-vip/kube-vip:v1.0.3` | `harbor.isuanova.com/mirrors/ghcr.io/kube-vip/kube-vip:v1.0.3` |
| `registry.k8s.io/pause:3.10.1` | `harbor.isuanova.com/mirrors/registry.k8s.io/pause:3.10.1` |

### 为什么保留源 Registry 主机名

1. **不冲突。** `docker.io/library/redis` 和 `quay.io/redis/redis` 是不同项目，
   去掉主机名后会撞到同一个仓库路径。
2. **可追溯。** 只看到 `harbor.isuanova.com/mirrors/quay.io/prometheus/prometheus`
   就知道上游是谁，排查和审计不用再翻清单。
3. **迁移便宜。** 集群里把 `quay.io/...` 前缀替换成
   `harbor.isuanova.com/mirrors/quay.io/...` 即可，其余路径不变。

`validate.sh` 会强制 `target` 的第三段与 `source` 的主机名一致；如果想放宽，
把 `config/policies.yaml` 的 `requireSourceHostInTarget` 改成 `false`，但请先在
团队内确认，因为这是本仓库最重要的可追溯性约束。

## 新增源 Registry

1. 在 `config/registries.yaml` 的 `sources` 下加一条：

   ```yaml
     - host: registry.example.com
       auth: credentials        # 公开源写 anonymous
       tlsVerify: true
   ```

2. 如果该主机需要认证，把它的凭据加进 `MIRROR_USERNAME` / `MIRROR_PASSWORD`
   （GitHub Actions 里是 `vars.CI_BOT_NAME` 和 `secrets.CI_BOT_PASSWORD`，
   见 [security.md](security.md)）。目前只支持一套凭据用于所有
   `auth: credentials` 的主机。**不需要**改 workflow。

3. `tlsVerify: false` 仅用于内网自签证书仓库，且应在 PR 里说明原因。

## Harbor 侧的前置条件

- `mirrors` 项目必须已存在。本仓库不会自动创建项目。
- Robot Account 只需要 `mirrors` 项目的 push/pull 权限。
- 如果 Harbor 配置了 tag 不可变（immutable tags），重推同一 tag 会被拒绝——
  这与本仓库"digest 必须一致"的语义是相容的，但意味着上游 tag 漂移时只能人工
  处理，不能靠重推覆盖。
