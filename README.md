# angelpay-env — 天使支付环境仓库（GitOps）

## 概述

此仓库是天使支付项目的 **环境仓库**（GitOps source of truth），由 Argo CD 监控并自动同步到 Kubernetes。

**核心原则：发布 = 修改此仓库；回滚 = 回退此仓库的 commit。**

---

## 1. 从 commit 到上线的流程

```
angelpay-app 代码提交
        ↓
GitHub Actions (check → build → trivy → push GHCR)
        ↓
Actions 自动修改本仓库 overlays/prod/kustomization.yaml 中的 newTag
        ↓
Argo CD 检测到本仓库变更
        ↓
Argo CD 自动同步 → K8s Rolling Update → 新版上线
        ↓
Post-sync Hook 自动执行烟雾测试（/health + /ready）
```

### 手动发布（紧急情况）

```bash
# 1. 修改镜像 tag
cd overlays/prod
sed -i 's/newTag: .*/newTag: <new-sha>/' kustomization.yaml

# 2. 提交并推送
git add . && git commit -m "release: update to <new-sha>" && git push
# Argo CD 会自动同步
```

---

## 2. 回滚步骤

### 方式一：Git revert（推荐）

```bash
# 1. 查看最近的镜像 tag 变更
git log --oneline -5

# 2. 回退到上一个版本
git revert HEAD --no-edit
git push

# 3. 预期现象
# - Argo CD 在 3 分钟内检测到变更
# - 自动触发同步，K8s 回滚到上一个镜像
# - /health 返回上一个版本的 commit sha
```

### 方式二：Git reset（强制回滚）

```bash
# 1. 找到要回退到的 commit
git log --oneline -10

# 2. 强制回退
git reset --hard <target-commit>
git push --force

# 3. 验证
curl https://<domain>/health
# 确认 version 字段为目标 commit sha
```

### 方式三：Argo CD UI 回滚

1. 打开 Argo CD Dashboard
2. 找到 `angelpay-prod` Application
3. 点击 **History and Rollback**
4. 选择目标版本 → **Rollback**

---

## 3. 密钥/权限管理

### Secret 存放位置

| Secret | 存放位置 | 谁能看到明文 |
|--------|----------|-------------|
| DB_USER / DB_PASS | K8s Secret `angelpay-secret`（通过 `kubectl create secret` 创建） | 集群管理员 |
| GHCR Pull Secret | K8s Secret `ghcr-pull-secret`（imagePullSecrets） | 集群管理员 |
| ENV_REPO_TOKEN | GitHub Repo Secrets（angelpay-app） | 仓库管理员 |
| GITHUB_TOKEN | GitHub 自动提供 | Actions 运行时 |

### 密钥创建方式（手动，不落地到 Git）

```bash
# 创建 namespace
kubectl create namespace angelpay-prod

# 创建数据库密钥
kubectl -n angelpay-prod create secret generic angelpay-secret \
  --from-literal=DB_USER='<数据库用户名>' \
  --from-literal=DB_PASS='<数据库密码>'

# 创建 GHCR 拉取密钥
kubectl -n angelpay-prod create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username='<github用户名>' \
  --docker-password='<github-pat>'
```

### Sealed Secrets（加密密钥方案）

当需要将密钥纳入 Git 管理时，使用 Bitnami Sealed Secrets：

```bash
# 1. 安装 Sealed Secrets Controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# 2. 安装 kubeseal CLI
brew install kubeseal  # macOS
# 或下载二进制: https://github.com/bitnami-labs/sealed-secrets/releases

# 3. 加密密钥
echo -n 'mydbuser' | kubeseal --raw --namespace angelpay-prod --name angelpay-secret --from-file=/dev/stdin
echo -n 'mydbpass' | kubeseal --raw --namespace angelpay-prod --name angelpay-secret --from-file=/dev/stdin

# 4. 将加密值填入 base/sealed-secret.yaml，取消 kustomization.yaml 中的注释
# 5. 提交到 Git —— 加密后的值即使泄露也无法解密
```

配置文件：`base/sealed-secret.yaml`（已提供模板）

### 安全规则

- **Git 仓库中禁止出现明文密码**，`base/secret.yaml` 只是占位模板
- 真实值通过 `kubectl create secret` 直接注入集群，或使用 Sealed Secrets 加密后提交
- GitHub Actions 的敏感变量只放在 **Repo Secrets** 中
- 镜像 tag 使用 git sha，禁止 `latest`

---

## 4. 漂移（Drift）策略

Argo CD 配置了 `selfHeal: true`：
- 如果有人通过 `kubectl` 手动修改了资源，Argo CD 会**自动恢复**到 Git 中定义的状态
- 这确保了 Git 始终是唯一的真实来源（Single Source of Truth）

---

## 5. 目录结构

```
angelpay-env/
├── argocd/
│   ├── application.yaml          # Argo CD Application 定义（单环境）
│   ├── applicationset.yaml       # ApplicationSet 定义（多环境: dev+prod）
│   ├── appproject.yaml           # AppProject + RBAC 权限控制
│   └── notifications-cm.yaml     # Argo CD Notifications 通知配置
├── base/                          # K8s 基础资源
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── configmap.yaml
│   ├── configmap-dbconfig.yaml   # PHP config.php（从环境变量读取DB）
│   ├── secret.yaml               # 占位模板，真实值用 kubectl 注入
│   ├── hpa.yaml                  # 自动伸缩（2-10 replicas）
│   ├── networkpolicy.yaml        # 网络策略（入80/出3306,53,443）
│   ├── post-sync-hook.yaml       # 部署后自动烟雾测试
│   ├── servicemonitor.yaml       # Prometheus 指标采集（需 Prometheus Operator）
│   ├── rollout.yaml              # Argo Rollouts Canary 配置（需 Rollouts Controller）
│   └── sealed-secret.yaml        # Sealed Secrets 加密密钥（需 Sealed Secrets Controller）
├── overlays/
│   ├── dev/                       # 开发环境覆盖
│   │   ├── kustomization.yaml
│   │   └── deployment-patch.yaml
│   └── prod/                      # 生产环境覆盖
│       ├── kustomization.yaml    # ← CI/CD 自动更新 newTag
│       ├── deployment-patch.yaml
│       └── ingress-patch.yaml
└── README.md
```

---

## 6. Argo CD 安装与配置

### 安装 Argo CD（如尚未安装）

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 获取初始密码
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# 端口转发访问 UI
kubectl port-forward svc/argocd-server -n argocd 8443:443
# 访问 https://localhost:8443
```

### 创建 Application（方式一：单环境）

```bash
kubectl apply -f argocd/appproject.yaml      # 先创建 AppProject
kubectl apply -f argocd/application.yaml     # 再创建 Application
```

### 创建 Application（方式二：ApplicationSet 多环境）

```bash
kubectl apply -f argocd/appproject.yaml      # 先创建 AppProject
kubectl apply -f argocd/applicationset.yaml  # 自动创建 dev + prod 两个 Application
# 会生成: angelpay-dev (→ overlays/dev) + angelpay-prod (→ overlays/prod)
```

### 启用通知（可选）

```bash
# 安装 Argo CD Notifications
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-notifications/release-1.0/manifests/install.yaml

# 创建 Slack token secret
kubectl -n argocd create secret generic argocd-notifications-secret \
  --from-literal=slack-token='<your-slack-bot-token>'

# 应用通知配置
kubectl apply -f argocd/notifications-cm.yaml

# 为 Application 添加通知注解
kubectl -n argocd annotate app angelpay-prod \
  notifications.argoproj.io/subscribe.on-sync-succeeded.slack="<channel>" \
  notifications.argoproj.io/subscribe.on-sync-failed.slack="<channel>" \
  notifications.argoproj.io/subscribe.on-health-degraded.slack="<channel>"
```

### 验证同步

```bash
# 查看同步状态
argocd app get angelpay-prod

# 手动触发同步（如果关闭了自动同步）
argocd app sync angelpay-prod
```

---

## 7. 加分功能说明

### 7.1 HPA 自动伸缩

配置文件：`base/hpa.yaml`
- 最小 2 / 最大 10 replicas
- CPU 平均利用率 > 70% 触发扩容
- 内存平均利用率 > 80% 触发扩容

### 7.2 NetworkPolicy 网络隔离

配置文件：`base/networkpolicy.yaml`
- **入站**：仅允许 TCP 80（HTTP）
- **出站**：仅允许 TCP 3306（MySQL）、TCP/UDP 53（DNS）、TCP 443（HTTPS）

### 7.3 Kustomize 多环境 Overlay

```
base/           → 基础资源定义
overlays/dev/   → 开发环境：1 replica, 低资源限制, latest tag
overlays/prod/  → 生产环境：2 replicas, 高资源限制, git sha tag
```

### 7.4 ApplicationSet（多环境自动管理）

配置文件：`argocd/applicationset.yaml`
- 通过 List Generator 自动创建 dev + prod 两个 Application
- 每个环境指向对应的 `overlays/<env>` 目录
- 统一同步策略，一处定义多处生效

### 7.5 AppProject + RBAC（权限控制）

配置文件：`argocd/appproject.yaml`
- 限制只能部署到 `angelpay-prod` 和 `angelpay-dev` namespace
- 限制只能使用 `angelpay-env` 仓库作为源
- 白名单控制可部署的资源类型
- 定义 `developer`（只读+同步）和 `admin`（完全控制）角色

### 7.6 Argo CD Notifications（部署通知）

配置文件：`argocd/notifications-cm.yaml`
- 同步成功时发送通知
- 同步失败时发送告警
- 健康状态降级时发送告警
- 支持 Slack（可扩展到邮件、Webhook 等）

### 7.7 Post-sync Hook（部署后自动验证）

配置文件：`base/post-sync-hook.yaml`
- 每次 Argo CD 同步完成后自动执行
- 使用 curl 测试 `/health` 和 `/ready` 端点
- 测试失败会标记同步为失败状态
- Job 在 300 秒后自动清理

### 7.8 /metrics 端点 + ServiceMonitor

应用端点：`metrics.php`（已添加到 angelpay-app）
配置文件：`base/servicemonitor.yaml`

暴露的 Prometheus 指标：
- `php_info` — PHP 版本
- `php_memory_usage_bytes` — 内存使用
- `php_opcache_hit_rate` — OPcache 命中率
- `app_database_up` — 数据库连接状态
- `app_database_latency_seconds` — 数据库查询延迟
- `app_build_info` — 应用版本信息

启用 ServiceMonitor（需要 Prometheus Operator）：
```bash
# 取消 base/kustomization.yaml 中的注释
# - servicemonitor.yaml
```

### 7.9 Argo Rollouts Canary（渐进式发布）

配置文件：`base/rollout.yaml`

金丝雀发布策略：
1. 20% 流量 → 新版本，暂停 60 秒观察
2. 50% 流量 → 新版本，暂停 60 秒观察
3. 80% 流量 → 新版本，暂停 30 秒观察
4. 100% 流量 → 全量切换

启用方式（需要 Argo Rollouts Controller）：
```bash
# 1. 安装 Argo Rollouts
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# 2. 在 base/kustomization.yaml 中：
#    注释掉 deployment.yaml，取消 rollout.yaml 的注释
```

### 7.10 Sealed Secrets（密钥加密存储）

配置文件：`base/sealed-secret.yaml`

见上方 §3 密钥管理章节的使用说明。

---

## 8. 验收检查

```bash
# 1. 健康检查
curl https://<domain>/health
# 期望: {"status":"ok","version":"<sha>"}

# 2. 就绪检查
curl https://<domain>/ready
# 期望: {"status":"ready","checks":{...}}

# 3. Prometheus 指标
curl https://<domain>/metrics
# 期望: Prometheus 格式的指标数据

# 4. 首页
curl https://<domain>/
# 期望: 返回页面内容

# 5. Argo CD 状态
argocd app get angelpay-prod
# 期望: Status: Synced, Health: Healthy
```
