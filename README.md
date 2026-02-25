# angelpay-env — 天使支付环境仓库（GitOps）

此仓库是天使支付项目的 **环境仓库**（GitOps source of truth），由 Argo CD 监控并自动同步到 Kubernetes。

---

## 1. 多环境目录结构与发布方式

采用 `base` + `overlays` 结构管理多环境差异：

```
angelpay-env/
├── base/                          # 通用资源清单 (Deployment, Service, ConfigMap, RBAC, NetworkPolicy)
├── overlays/
│   ├── staging/                   # 测试环境 (Namespace: angelpay-staging)
│   │   ├── kustomization.yaml     # 引用 base + patches
│   │   ├── deployment-patch.yaml  # 副本数 1, 资源限制较小
│   │   └── ingress-patch.yaml     # Host: staging.angelpay.local
│   └── prod/                      # 生产环境 (Namespace: angelpay-prod)
│       ├── kustomization.yaml     # 引用 base + patches (CI/CD 自动更新此处的 tag)
│       ├── deployment-patch.yaml  # 副本数 2, 资源限制较大
│       └── ingress-patch.yaml     # Host: prod.angelpay.local
└── scripts/                       # 运维脚本 (备份/恢复)
```

**发布方式**：
1. **Staging**: 开发分支合并到 main 后，手动或自动更新 `overlays/staging/kustomization.yaml` 中的镜像 tag。
2. **Prod**: Staging 验证通过后，通过 Pull Request 将 `overlays/prod/kustomization.yaml` 中的 tag 更新为经过验证的版本。

---

## 2. 发布后自动验证

在 `base/post-sync-hook.yaml` 中定义了一个 Argo CD PostSync Hook Job：
- **触发时机**：每次 Argo CD 同步（部署）完成后自动执行。
- **验证逻辑**：
  - `curl http://angelpay:80/health`: 检查应用是否存活 (期望 200 OK)。
  - `curl http://angelpay:80/ready`: 检查数据库连接是否正常 (期望 200 OK)。
- **失败表现**：
  - 如果 `/health` 或 `/ready` 返回非 200，Job 失败 (`exit 1`)。
  - Argo CD 界面上 Application 状态会显示为 **Degraded** 或同步失败，并提示 Hook 执行失败。
  - 触发 Argo CD Notifications 发送告警。

---

## 3. 权限边界（RBAC）

我们在 `argocd/appproject.yaml` 和 `base/rbac.yaml` 中定义了严格的权限控制：

- **Argo CD Project (`angelpay`)**:
  - 限制只能部署到 `angelpay-staging` 和 `angelpay-prod` 命名空间。
  - 限制只能使用 `angelpay-env` 仓库。
  - 白名单限制可部署的资源类型 (Deployment, Service, ConfigMap, Secret, PVC, Ingress, NetworkPolicy 等)。

- **Kubernetes RBAC**:
  - **Role: angelpay-readonly**: 仅允许 `get`, `list`, `watch` 资源。(绑定组: `angelpay-readers`)
  - **Role: angelpay-publisher**: 允许 `create`, `update`, `patch`, `delete` 资源。(绑定组: `angelpay-publishers`)
  - **禁止使用 default admin**: 操作必须通过上述 Role 进行，遵循最小权限原则。

---

## 4. 告警规则与触发方式

- **监控指标**: `angelpay-app` 提供 `/metrics` (Prometheus格式)。
- **告警触发**:
  - **健康检查失败**: PostSync Hook 失败触发 Argo CD 告警。
  - **同步失败**: Argo CD Sync Failed 触发告警。
  - **状态降级**: Application Health Degraded 触发告警。
- **通知渠道**: Slack (配置在 `argocd/notifications-cm.yaml`)。

**验证方式**:
1. 修改 `overlays/staging/deployment-patch.yaml` 中的环境变量（如数据库密码）为错误值。
2. 提交并同步。
3. PostSync Hook 检测 `/ready` 失败 -> Job Failed -> Argo CD 告警推送到 Slack。

---

## 5. 备份策略与恢复步骤

**备份对象**: MySQL 数据库 (因应用无持久化上传文件，仅需备份 DB)。

**备份脚本**: `scripts/backup.sh`
**恢复脚本**: `scripts/restore.sh`

### 演练记录 (Staging 环境)

1. **备份**:
   ```bash
   # 备份 staging 环境数据库
   ./scripts/backup.sh angelpay-staging
   # 输出: Backup completed successfully! Saved to backups/db_angelpay-staging_20260225_160000.sql
   ```

2. **模拟故障**:
   ```bash
   kubectl -n angelpay-staging delete pod -l app=mysql
   # (或者手动 drop table)
   ```

3. **恢复**:
   ```bash
   # 恢复数据库
   ./scripts/restore.sh angelpay-staging backups/db_angelpay-staging_20260225_160000.sql
   # 输出: Restore completed successfully!
   ```

4. **验证**:
   访问 `http://staging.angelpay.local/ready` 确认返回 200 OK。

---

## 6. NetworkPolicy 策略说明

应用了最小化网络隔离策略：

1. **Default Deny / Whitelist** (`base/networkpolicy.yaml`):
   - **Ingress**: 仅允许从 Ingress Controller 或同命名空间访问 TCP 80 端口。
   - **Egress**: 限制外发流量仅能访问：
     - DNS (TCP/UDP 53)
     - MySQL (TCP 3306)
     - HTTPS (TCP 443, 用于外部 API 调用)

2. **Database Isolation** (`base/db-networkpolicy.yaml`):
   - MySQL Pod 仅允许来自带有 `app: angelpay` 标签的 Pod (即应用 Pod) 的 TCP 3306 访问。
   - 禁止即便在同一命名空间下的其他非授权 Pod 访问数据库。

**验证拦截**:
启动一个临时 Pod (非 angelpay) 尝试访问数据库：
```bash
kubectl run -it --rm test --image=busybox -n angelpay-staging -- sh
# telnet angelpay-mysql 3306
# 结果: Connection timed out (通过 NetworkPolicy 拦截)
```
