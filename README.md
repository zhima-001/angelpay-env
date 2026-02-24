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

### 安全规则

- **Git 仓库中禁止出现明文密码**，`base/secret.yaml` 只是占位模板
- 真实值通过 `kubectl create secret` 直接注入集群
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
│   └── application.yaml          # Argo CD Application 定义
├── base/                          # K8s 基础资源
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── configmap.yaml
│   ├── secret.yaml               # 占位模板，真实值用 kubectl 注入
│   ├── hpa.yaml                  # 自动伸缩
│   └── networkpolicy.yaml        # 网络策略
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

### 创建 Application

```bash
kubectl apply -f argocd/application.yaml
```

### 验证同步

```bash
# 查看同步状态
argocd app get angelpay-prod

# 手动触发同步（如果关闭了自动同步）
argocd app sync angelpay-prod
```

---

## 7. 验收检查

```bash
# 1. 健康检查
curl https://<domain>/health
# 期望: {"status":"ok","version":"<sha>"}

# 2. 就绪检查
curl https://<domain>/ready
# 期望: {"status":"ready","checks":{...}}

# 3. 首页
curl https://<domain>/
# 期望: 返回页面内容

# 4. Argo CD 状态
argocd app get angelpay-prod
# 期望: Status: Synced, Health: Healthy
```
