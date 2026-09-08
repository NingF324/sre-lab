# sre-lab —— 单节点 SRE 可观测性实验环境

一套跑在 **4 核 4G** 云服务器上的完整 SRE 练手环境：
**可观测性三件套（指标 / 告警 / 日志）+ HPA 自动扩缩容 + GitOps 自动同步**。
所有组件从零手写 YAML 部署，不用 Helm Chart，目的是**把每个组件的行为和取舍都摸清楚**。

> 硬件：腾讯云轻量 4C4G / 40G / OpenCloudOS 9.6（RHEL 系，对齐生产栈）
> 集群：k3s v1.36.4+k3s1，单节点
> 仓库：<https://github.com/NingF324/sre-lab>

---

## 架构

```
                    ┌──────────────────────────────────────┐
   浏览器 ──────────▶│ Grafana :30030  指标 / 日志 统一入口  │
                    └────────┬─────────────────┬───────────┘
                             │                 │
                    ┌────────▼──────┐   ┌──────▼──────┐
                    │ Prometheus    │   │ Loki :3100  │
                    │ :30090        │   │ 只索引标签   │
                    └───┬───────┬───┘   └──────▲──────┘
                        │       │              │
              ┌─────────▼──┐  ┌─▼──────────┐  ┌┴──────────┐
              │Alertmanager│  │node-exporter│ │ Promtail   │
              │  :30093    │  │ + cAdvisor  │ │ DaemonSet  │
              └────────────┘  └─────────────┘ │ 读 /var/log/pods
                                               └────────────┘
                        ▲
                        │ 被监控
              ┌─────────┴─────────┐
              │ demo 命名空间      │
              │ php-apache + HPA  │
              └───────────────────┘
```

**三条数据链路**：

| 链路 | 路径 | 解决的问题 |
|---|---|---|
| 指标 | cAdvisor / node-exporter → Prometheus → Grafana | 现在发生了什么 |
| 告警 | Prometheus 规则 → Alertmanager → （钉钉/企微） | 什么时候需要人介入 |
| 日志 | 容器 stdout → Promtail → Loki → Grafana | 为什么会发生 |

三者凑齐才是完整的可观测性。只有指标能发现故障，只有日志能定位原因。

### GitOps 层

```
开发者 ──git push──▶ GitHub/Gitee 仓库
                          │
                          │ ArgoCD 每 3 分钟轮询（或 webhook 推送）
                          ▼
                   ArgoCD 对比 Git 声明 vs 集群实际状态
                          │
                          ├─ 有差异 → 自动同步（selfHeal）
                          └─ 一致   → 什么都不做
                          │
                          ▼
                  k8s 集群（Deployment / Service / HPA / Ingress）
```

**Git 是唯一事实来源。** 任何对集群的直接修改都会被 controller 按 Git 的声明改回去 ——
这条机制在本次实践中以一次真实事故的形式验证过（见踩坑 13）。

---

## 部署顺序

前置：k3s 已装好，`kubectl get node` 为 Ready。

```shell
# 0. 环境体检（可选）
bash 00-bootstrap/check-env.sh

# 1. 基础监控栈
kubectl apply -f 01-monitoring/monitoring.yaml

# 2. Grafana 声明式数据源
kubectl apply -f 01-monitoring/grafana-datasource.yaml

# 3. Kubernetes 服务发现（让 Prometheus 看见 Pod）
kubectl apply -f 02-discovery/prometheus-k8s-sd.yaml

# 4. 告警体系
kubectl apply -f 03-alerting/alerting.yaml

# 5. 练手业务 + HPA
kubectl apply -f 04-demo-app/demo-hpa.yaml

# 6. 日志栈
kubectl apply -f 05-logging/loki-stack.yaml
kubectl apply -f 05-logging/promtail-fix.yaml
kubectl rollout restart daemonset/promtail -n monitoring

# 7. ArgoCD（GitOps）
kubectl create namespace argocd
kubectl apply --server-side=true --force-conflicts -n argocd -f argocd-install.yaml
kubectl apply -f 06-gitops/demo-app.yaml
```

### ArgoCD 说明

- 安装清单不在这里维护，从官方仓库取：
  `https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`
- **`--server-side=true` 是必需的**，原因见踩坑 14
- 4C4G 机器上建议关掉不需要的组件：
  ```shell
  kubectl scale deploy argocd-dex-server argocd-notifications-controller \
    argocd-applicationset-controller -n argocd --replicas=0
  ```
- 取初始密码：
  ```shell
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d
  ```
- 暴露 UI：`kubectl patch svc argocd-server -n argocd --type=json \
  -p='[{"op":"replace","path":"/spec/type","value":"NodePort"}]'`

> Grafana 数据源用 ConfigMap provisioning 注入，改完必须重启：
> `kubectl rollout restart deployment/grafana -n monitoring`

### 端口

| 服务 | NodePort | 用途 |
|---|---|---|
| Grafana | 30030 | 指标 + 日志查询 |
| Prometheus | 30090 | 规则、Targets |
| Alertmanager | 30093 | 告警查看与静默 |

> 安全提醒：NodePort 直接暴露公网有风险，防火墙规则应**限制来源 IP**，Grafana 默认密码 `admin123` 首次登录后立即修改。

---

## 验证清单

```shell
# 集群与组件
kubectl get pods -A | grep -v Completed

# Prometheus 抓取目标（应有 5 个 job 全 UP）
# 浏览器打开 http://<节点IP>:30090/targets

# HPA 能读到指标
kubectl get hpa -n demo
kubectl top pod -n demo

# ArgoCD 同步状态
kubectl get application -n argocd
kubectl describe application demo-app -n argocd | tail -30
```

> `describe` 的 Events 是排查同步问题最有效的手段，它记录了每一次
> `Synced → OutOfSync → Unknown` 的完整时间线。

### 亲手把告警打响

```shell
# 起 4 个死循环 Pod 吃满 CPU（单节点 4 核，3 个只到 78%，不够）
for i in 1 2 3 4; do
  kubectl run burner-$i --image=busybox:1.36 --restart=Never \
    -- /bin/sh -c 'while true; do :; done'
done

# 观察
kubectl top node
```

`NodeCPUHigh`（idle < 20% 持续 5 分钟）会走完 `inactive → Pending → FIRING`，
随后出现在 Alertmanager。用完记得清理：

```shell
kubectl delete pod burner-1 burner-2 burner-3 burner-4 --force
```

---

## 踩坑记录（这部分比 YAML 值钱）

### 1. k3s 安装

- 国内必须走 Rancher 中国镜像，且**必须 `nohup` 后台跑**：
  ```shell
  INSTALL_K3S_SKIP_SELINUX_RPM=true INSTALL_K3S_MIRROR=cn \
    nohup bash /root/k3s-install.sh > /root/k3s-install.log 2>&1 &
  ```
  前台跑被 SSH 踢断的后果是：二进制装好了、systemd 单元没创建，`systemctl status k3s` 报 Unit not found。
- OpenCloudOS 9 源里缺 `container-selinux`，不加 `INSTALL_K3S_SKIP_SELINUX_RPM=true` 会直接中止安装。

### 2. helm-install-traefik 报 Error / CrashLoopBackOff

**正常行为**。k3s 用 Helm Job 装 traefik，CRD Job 没好或镜像没到位时会失败重试，
重试到成功即 `Completed`。判据是**最终 Completed 而不是持续 CrashLoop**。

### 3. 国内拉不到 k8s 官方示例镜像

`registry.cn-hangzhou.aliyuncs.com/google_containers/hpa-example` 不存在（**2 秒就 ErrImagePull = 镜像不存在，不是网络慢**）。
可用的是 Docker Hub 上的 `mirrorgooglecontainers/hpa-example:latest`。

### 4. `kubectl set image` 返回 updated ≠ 镜像能拉到

它只改了 etcd 里的期望状态。改完**必须** `kubectl get pods -w` 看实际结果。
生产里滚动更新时镜像名打错一个字母，返回照样是 updated。

### 5. `kubectl annotate deployment/xxx` 改不到 Pod 模板

它改的是 Deployment 自己的 `metadata.annotations`，而抓取注解长在 `spec.template.metadata.annotations`。
要改 Pod 模板必须用 JSON Patch，且 `/` 要转义成 `~1`：

```shell
kubectl patch deployment php-apache -n demo --type=json -p='[
 {"op":"remove","path":"/spec/template/metadata/annotations/prometheus.io~1scrape"},
 {"op":"remove","path":"/spec/template/metadata/annotations/prometheus.io~1port"}]'
```

**判据：Pod 名字里的 ReplicaSet hash 变没变**（没变 = 没触发滚动更新）。

### 6. 给没有 /metrics 的应用加 scrape 注解 → TargetDown 误告警

`prometheus.io/scrape: "true"` 只对**有指标端点的应用**有意义。
给 php-apache 加注解后，Prometheus 去抓 `/metrics` 得 404 → `up == 0` → 告警 FIRING。
**假告警要修配置，不要加静默压下去** —— 静默是给"临时不想看"用的。

### 7. HPA 打到 maxReplicas 仍不达目标 = 容量不足

不是配置错误。实测 4 副本时 CPU 仍在 72%，按 `requests: 200m` 反推需要 5.76 个副本才降到 50%。
生产解法三条：调高 maxReplicas / 优化应用 / 加节点。

### 8. polinux/stress 在本环境起不来（StartError）

替代方案：busybox 死循环 Pod。
教训：**练手时别为第三方工具死磕，先用最土的办法把主线走通**。

### 9. 日志链路静默失败 —— 最难查的一类

Promtail 全绿、无报错、宿主机日志正常写入、挂载也正常，但 Loki 一条数据都没有。
真实根因是 `kubernetes_sd_configs: role: pod` **返回 0 个目标且静默失败**。

**排查顺序（记牢）**：

```
Pod Running?
  → agent 日志有无 error?
    → 存储侧有没有数据?（Loki: /loki/api/v1/labels）
      → agent 发现了哪些目标?（Promtail: :9080/targets）
        → 查询语法对不对?
```

大多数人一上来怀疑查询语法，其实应该**从存储侧往前推**。

最终解法：改用静态路径采集（`__path__: /var/log/pods/*/*/*.log`）+ 正则从路径反解标签，
不依赖服务发现。代价是拿不到 Pod 自身的 label，生产正经做法仍是 SD。

### 10. Promtail 只收启动之后的新日志

默认 `read_from_head: false`。安静的 Pod（coredns、traefik）不产日志，
Loki 空是正常的 —— **排查前先起个打日志的 Pod 制造输入**，别一上来就怀疑组件。

### 11. Grafana 改了 ConfigMap 不生效

Prometheus 和 Grafana 都不会自动监听配置文件变化。
Prometheus 加了 `--web.enable-lifecycle`，可热加载：

```shell
kubectl exec -n monitoring deploy/prometheus -- \
  sh -c 'curl -s -X POST http://localhost:9090/-/reload'
```

### 12. 精简镜像里没有排障工具

`grafana/promtail` 里没有 `wget`/`curl`，exec 进去做不了网络调试。
要查它的 `/targets`，得从集群内另一个 busybox Pod 访问它的 Pod IP。

### 13. GitOps 接管后，集群上的手工修复会被抹掉（配置漂移）

**本次实践中真实踩过的一次事故**：

| 时间 | 动作 | 集群 | Git |
|---|---|---|---|
| Day N | 阿里云镜像源拉不动，`kubectl set image` 换成可用源 | 正确镜像 | **仍是坏镜像** |
| Day N+4 | ArgoCD 接管，`selfHeal: true` 开始工作 | — | — |
| Day N+4 | push 一次改动，ArgoCD 同步整个目录 | **被改回坏镜像 → ImagePullBackOff** | 仍是坏镜像 |

**你在集群上改的任何东西，只要没写回 Git，都会被 controller 按 Git 的声明改回去 ——
哪怕错的是 Git 自己。** 修复办法只有一个：把正确的状态写进 Git。

这也是生产上"禁止直接 kubectl 操作生产环境、一切变更走 PR"的技术根源。

配套的另一个必要设计：

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    name: php-apache
    jsonPointers: [ /spec/replicas ]
```

副本数由 HPA 控制，不忽略的话 ArgoCD 会认为集群"偏离"Git 并反复改回去，
**两个控制器打架，副本数疯狂抖动**。这是 GitOps 与自动扩缩容共存的标准解法。

### 14. ArgoCD 大 CRD 装不上：`annotations: Too long`

```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

根因：`kubectl apply` 会把整份资源原文塞进 `kubectl.kubernetes.io/last-applied-configuration`
注解，这个 CRD 超过 K8s 256KB 的注解上限。

解法是 **Server-Side Apply**，它把字段归属记在服务端的 `managedFields`，不写那个注解：

```shell
kubectl apply --server-side=true -n argocd -f argocd-install.yaml
```

如果之前已经用客户端 apply 过，会报字段所有权冲突（`conflict with "kubectl-client-side-apply"`），
加 `--force-conflicts` 强制接管即可。

### 15. ArgoCD 同步有延迟：默认 3 分钟轮询

未配 webhook 时，push 之后最长要等 3 分钟才同步。
生产环境必须给仓库配 webhook 指向 `/api/webhook`，实现 push 即触发的秒级同步。

### 16. `SYNC STATUS = Unknown`：repo-server 缓存卡死

表象：仓库可达（`git ls-remote` 通）、内存正常、Pod 无重启，但 ArgoCD 算不出同步状态。

排查链：

```
网络断了？     → ls-remote 通，排除
资源不够？     → 全家只用 223Mi 零重启，排除
进程崩了？     → AGE 稳定无重启，排除
剩下就是仓库缓存/解析 ← 确认
```

解法：`kubectl rollout restart deploy/argocd-repo-server -n argocd` 清空缓存即恢复。

---

## 已知限制

- **存储全用 emptyDir**：Pod 重启数据清零。学习环境够用，生产需换 PVC。
  要练持久化，把 `emptyDir: {}` 换成 PVC + local-path-provisioner（k3s 自带）。
- **没有 kube-state-metrics**：Deployment/ReplicaSet 维度的指标拿不到，
  Pod 重启告警改用 `changes(container_start_time_seconds[10m]) > 2` 从 cAdvisor 侧实现。
- **Promtail 用静态采集**：见踩坑 9。
- **单机**：没有多节点调度、亲和性、网络策略的练手条件。

---

## 后续路线

- [ ] 日志告警（Loki Ruler：ERROR 日志速率超阈值告警）
- [ ] 持久化改造（PVC 替代 emptyDir）
- [ ] kube-state-metrics（补齐 Deployment 维度指标）
- [ ] Webhook 改造（ArgoCD 秒级同步）
- [ ] App-of-Apps 模式（用一个根 Application 管理全部子 Application）
- [x] ~~ArgoCD GitOps~~（已完成：demo-app 已由 Git 自动同步）
- [ ] Istio 灰度发布
- [ ] ArgoCD GitOps（本仓库直接作为 ArgoCD 的源）
- [ ] AIOps：aiops-anomaly 异常检测 / sre-ai-agent 告警自动分析

---

## 关于环境

所有 YAML 已在 4C4G 单节点上实跑验证，资源限制均按小内存调优：

| 组件 | requests | limits |
|---|---|---|
| Prometheus | 256Mi | 768Mi |
| Grafana | 128Mi | 384Mi |
| Alertmanager | 64Mi | 256Mi |
| Loki | 128Mi | 512Mi |
| Promtail | 32Mi | 128Mi |
| node-exporter | 32Mi | 128Mi |
