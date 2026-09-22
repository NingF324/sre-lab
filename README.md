# sre-lab —— 单节点 SRE 可观测性实验环境

一套跑在 **4 核 4G** 云服务器上的完整 SRE 练手环境：
**可观测性三件套（指标 / 告警 / 日志）+ 告警富化与 AIOps 异常检测 + HPA 自动扩缩容 + GitOps 自动同步**。
所有组件从零手写 YAML 部署，不用 Helm Chart，目的是**把每个组件的行为和取舍都摸清楚**。

> 硬件：腾讯云轻量 4C4G / 40G / OpenCloudOS 9.6（RHEL 系，对齐生产栈）
> 集群：k3s v1.36.4+k3s1，单节点
> 仓库：<https://github.com/NingF324/sre-lab>
> 公网暴露面：**只有 30096（webhook relay）和 22（SSH）**，其余全部走 SSH 隧道

---

## 架构

```
                      ┌───────────────────────────────────────┐
   浏览器 ─隧道──────▶│ Grafana  指标 / 日志 / 元监控 统一入口  │
                      └────┬─────────────────┬────────────────┘
                           │                 │
                 ┌─────────▼────────┐  ┌─────▼─────────┐
                 │ Prometheus       │  │ Loki :3100    │
                 │ 指标 + 规则求值   │  │ 只索引标签     │
                 │ + 动态基线        │  │ + Ruler 日志告警│
                 └──┬────────┬──────┘  └──────▲────────┘
                    │        │                │
        ┌───────────▼─┐  ┌───▼──────────────┐ │
        │ Alertmanager│  │ node-exporter    │ │
        │ (Silence)   │  │ cAdvisor         │ │
        └──────┬──────┘  │ kube-state-metrics│ │
               │         └──────────────────┘ │
               ▼                    ┌─────────┴──┐
        ┌──────────────┐            │ Promtail   │
        │alert-enricher│            │ DaemonSet  │
        │ 补指标+日志+  │            │ 读 /var/log/pods
        │ LLM 诊断卡片  │            └────────────┘
        └──────┬───────┘
               ▲ 被监控
        ┌──────┴──────────┐
        │ demo 命名空间    │
        │ php-apache + HPA│
        └─────────────────┘
```

**四条数据链路**：

| 链路 | 路径 | 解决的问题 |
|---|---|---|
| 指标 | cAdvisor / node-exporter / kube-state-metrics → Prometheus → Grafana | 现在发生了什么 |
| 告警 | Prometheus 规则 + Loki Ruler → Alertmanager → alert-enricher | 什么时候需要人介入 |
| 日志 | 容器 stdout → Promtail → Loki → Grafana | 为什么会发生 |
| 诊断 | Alertmanager webhook → alert-enricher（查指标 + 查日志 + LLM）→ 诊断卡片 | 这条告警该怎么处理 |

前三条是可观测性的基础，第四条是 AIOps 的入口 ——
**告警不该只告诉人"出事了"，还应该带上"大概什么原因、先看哪里"。**

### GitOps 层

```
开发者 ──git push──▶ GitHub（镜像仓库 + webhook 来源）
                          │
                          │  push 事件
                          ▼
                   webhook-relay :30096
                   （改写成 Gitee 坐标的 GitHub 格式 payload）
                          │
                          ▼
                   ArgoCD /api/webhook
                          │
                          ▼
              按 payload 里的 repoURL 匹配 Application
                          │
                          ├─ 有差异 → 自动同步（selfHeal）
                          └─ 一致   → 什么都不做
                          │
                          ▼
                  k8s 集群（Deployment / Service / HPA / PVC）

     拉取源：Gitee（GitHub 的 git 协议跨境不稳定，见踩坑 24）
```

**Git 是唯一事实来源。** 任何对集群的直接操作都会被 controller 按 Git 的声明改回去 ——
这条机制在本次实践中以**两次真实事故**的形式验证过（见踩坑 13 与 25）。

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
kubectl apply -f 06-gitops/root-app.yaml
```

### 目录分工：演进过程 vs 最终状态

`00` ~ `05` 是**逐步演进**的过程，适合照着学。但同一份资源在演进中会被后面的文件
反复覆盖（比如 `prometheus-config` 在 01/02/03 里各有一份，`promtail-config` 在
05 里两份），**直接交给 ArgoCD 会造成同一资源被多处管理** —— 两个控制器互相覆盖，
比 HPA 与 GitOps 打架还严重。

所以收敛出一份最终状态供 GitOps 消费：

```
04-demo-app/    业务服务（Deployment + Service + HPA）
07-argocd/      ArgoCD 自身的配件（webhook relay）
10-platform/    监控/告警/日志的最终状态，每个资源只保留最后一次修改的版本
20-aiops/       告警富化服务（alert-enricher）
06-gitops/
  ├── root-app.yaml            根 Application，只管下面这些 Application
  └── apps/
      ├── platform-app.yaml   → 10-platform
      ├── demo-app.yaml       → 04-demo-app
      ├── aiops-app.yaml      → 20-aiops
      └── argocd-app.yaml     → 07-argocd
```

**从零重建整套环境只要三步**（k3s 装好之后）：

```shell
kubectl create namespace argocd
kubectl apply --server-side=true --force-conflicts -n argocd -f argocd-install.yaml
kubectl apply -f 06-gitops/root-app.yaml
```

根 Application 会自动创建 `platform` / `demo-app` / `aiops` / `argocd-extras`
四个子 Application，它们再各自同步自己负责的目录 —— 这就是 **App-of-Apps 模式**。
新增组件只需往 `apps/` 里加一个文件，根应用自动发现。

> ⚠️ **"三步重建"之外还有两个 bootstrap 步骤**（都在 Git 之外，见踩坑 30）：
>
> 1. 安装 sealed-secrets 控制器：`kubectl apply -f controller.yaml`
> 2. **恢复主密钥**：`kubectl apply -f sealed-secrets-master-key.yaml`
>    —— **不做这一步，Git 里所有密文都解不开**
>
> 做完这两步，三个 Secret 就会由 ArgoCD 从 Git 自动恢复出来。

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
- **不要把 UI 暴露到公网**：`argocd-server` 保持默认类型，用 SSH 隧道访问（见踩坑 27）。
- 若要经 HTTP 访问（例如需要收 webhook），得设
  `argocd-cmd-params-cm` 的 `server.insecure: "true"` ——
  否则 HTTP 请求会 307 跳 HTTPS，而 **GitHub 的 webhook 不跟随重定向**（见踩坑 25）。

> Grafana 数据源用 ConfigMap provisioning 注入，改完必须重启：
> `kubectl rollout restart deployment/grafana -n monitoring`

### 访问方式：SSH 隧道（没有公网端口）

监控栈全部是 `ClusterIP`，**公网只剩 30096（webhook relay）和 22（SSH）**。

本地 `~/.ssh/config` 里配好 `Host lab`（含 5 条 `LocalForward`），一条命令建好全部隧道：

```shell
ssh -N lab
```

| 本地地址 | 打开什么 |
|---|---|
| `http://localhost:3000` | Grafana |
| `http://localhost:9090` | Prometheus |
| `http://localhost:9093` | Alertmanager |
| `http://localhost:8080` | 告警诊断卡片 |
| `http://localhost:8081` | ArgoCD（注意是 **http**，那个端口只有明文 HTTP） |

⚠️ 隧道目标是 **ClusterIP**，Service 重建后会重新分配，需要同步改 config。

> 为什么不用 NodePort：`NodePort` 的语义是"在每个节点的所有网卡上开一个端口"，
> 只要防火墙放行就是公网可达。管理界面没有理由挂到公网上 —— 见踩坑 27。

---

## 验证清单

```shell
# 集群与组件
kubectl get pods -A | grep -v Completed
kubectl get pvc -n monitoring

# Prometheus 抓取目标：所有 job 都应为 UP
#   隧道打开后访问 http://localhost:9090/targets

# 告警链路四段（排查方法见踩坑 18）
kubectl exec -n monitoring deploy/prometheus   -- wget -qO- http://localhost:9090/api/v1/alertmanagers
kubectl exec -n monitoring deploy/alertmanager -- wget -qO- 'http://localhost:9093/api/v2/alerts?active=true'
kubectl logs -n monitoring deploy/alert-enricher --tail=5

# HPA 能读到指标
kubectl get hpa -n demo
kubectl top pod -n demo

# GitOps 同步状态与当前 revision
kubectl get application -n argocd
kubectl get app platform -n argocd -o jsonpath='{.status.sync.revision}{"\n"}'

# webhook 链路是否在转发
kubectl logs -n argocd -l app=webhook-relay --tail=3
```

> `describe application` 的 Events 是排查同步问题最有效的手段，它记录了每一次
> `Synced → OutOfSync → Unknown` 的完整时间线。

### 亲手把告警打响

**① 固定阈值告警**（`NodeCPUHigh`，idle < 20% 持续 5 分钟）

```shell
# 单节点 4 核，要 4 个死循环 Pod 才能压过 80%
for i in 1 2 3 4; do
  kubectl run burner-$i --image=busybox:1.36 --restart=Never \
    -- /bin/sh -c 'while true; do :; done'
done
kubectl top node
```

**② 动态基线告警**（`NodeCPUDeviationHigh`，偏离基线 > 3σ 持续 2 分钟）——
**只要 2 个 burner**，CPU 约 55%，**远低于 80% 的固定阈值**：

```shell
for i in 1 2; do
  kubectl run burner-$i --image=busybox:1.36 --restart=Never \
    -- /bin/sh -c 'while true; do :; done'
done

sleep 180          # ← 必须等够时间，否则永远看不到 firing
kubectl exec -n monitoring deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules?type=alert' | tr ',' '\n' | grep -A1 Deviation
kubectl exec -n monitoring deploy/alert-enricher -- sh -c \
  'grep -c NodeCPUDeviationHigh /data/alerts.jsonl'
```

清理：

```shell
kubectl delete pod burner-1 burner-2 burner-3 burner-4 --force
```

> 用完给基线留一段"洗白期"——这次负载的样本会在窗口里停留约 1 小时，
> 抬高下一次实验的阈值（见踩坑 29）。

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

**本环境已解决**（2026-09-11）：GitHub push → `webhook-relay` → ArgoCD `/api/webhook`，实测秒级生效。
但过程中撞到两件事，详见踩坑 23（ArgoCD 不支持 Gitee webhook）与
踩坑 25（自建转发层 + 公网只留一条缝）。

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

### 17. `--web.enable-lifecycle` 是 Prometheus 专属参数，Alertmanager 加了会启动失败

最隐蔽的一类事故：**配置看着全对，服务其实根本没起来。**

```yaml
args:
  - --config.file=/etc/alertmanager/alertmanager.yml
  - --storage.path=/alertmanager
  - --web.enable-lifecycle   # ← 错！Alertmanager 不认这个参数
```

报错：`alertmanager: error: unknown long flag '--web.enable-lifecycle', try --help`

为什么难查——三层假象叠在一起：

| 你看到的现象 | 真实含义 |
|---|---|
| Prometheus `/api/v1/alertmanagers` 返回 9093 `active` | 只说明**服务发现到了**，不代表连通健康 |
| Prometheus `/alerts` 里 NodeCPUHigh 正常 FIRING | 只说明**规则求值通过**，不代表通知已发出 |
| `kubectl exec` 报 `container not found` | 容器压根没起来，不是"容器里没这个命令" |

正确认知：Alertmanager **天生监听配置文件变化自动重载**，不需要任何开关；
只有 Prometheus 需要 `--web.enable-lifecycle` 才支持 `POST /-/reload`。

### 18. 告警链路四段论：排查必须逐段二分

告警从产生到人看见，是四段**互相独立**的链路，任一段断了现象完全一样（"页面没告警"）：

```
1 规则求值 → 2 通知推送 → 3 分组路由 → 4 富化落库
Prometheus    → Alertmanager  → webhook   → 你的页面
```

对应的验证手段：

| 段 | 怎么证明它通没通 |
|---|---|
| 1 | `wget -qO- http://localhost:9090/api/v1/rules` 看 state |
| 2 | `wget -qO- http://localhost:9090/api/v1/alertmanagers` 看 activeAlertmanagers |
| 3 | `wget -qO- 'http://localhost:9093/api/v2/alerts?active=true'` 看 AM 收到没 |
| 4 | 接收端自己的接入日志（`[webhook] N alert(s)`） |

生产上还要给每段配可观测证据：`prometheus_notifications_errors_total`、
`alertmanager_notifications_failed_total`、接收端埋点。否则故障时只能靠
"告警怎么还没来"这种被动感知，MTTR 会非常难看。

另外两个反直觉的点：

- **`group_wait` / `repeat_interval` 只决定"什么时候发"，不决定"发不发"**。
  第一通知一定会发，所以"页面没有"不能用"还在 repeat 冷却"来解释。
- **Watchdog 恒真告警的价值是端到端心跳**，不是报警。
  建议把它的 `repeat_interval` 单独调短，专门当链路探针用。

### 19. `emptyDir` 的生命周期 = Pod 的生命周期

`kubectl rollout restart` 看着只是"重启一下"，实际会：重建 Pod → emptyDir 清空 → 内存态丢失。

```bash
kubectl -n monitoring create secret generic deepseek-api --from-literal=api-key='sk-xxx'
kubectl rollout restart deploy/alert-enricher -n monitoring
# 结果：30095 页面空了。不是服务挂了，是历史卡片全没了。
```

**判断一个服务能不能随便重启，先看它是不是无状态的。** 有状态的部分
（TSDB、日志 chunk、告警存档）必须 PVC 或外部对象存储。

生产上 Prometheus 配 PVC + Thanos/Mimir 远程存储，就是同一个道理。

### 20. `ReadWriteOnce` 的 PVC 别配默认的 RollingUpdate

RWO 卷同一时刻只允许挂载到一个节点。默认 `RollingUpdate` 在单副本下是
"先起新的、再杀旧的"，新 Pod 会卡在等旧 Pod 释放卷。

单副本 + RWO 的正确姿势是 `strategy: type: Recreate`（先停后起），
代价是几秒中断——对内部工具完全可以接受。

### 21. 非 root 容器挂 PVC 要配 `fsGroup`，否则写不进去

`emptyDir` 默认权限宽松，很多容器"刚好能跑"；换成 PVC 后属主变成卷的属主，
非 root 容器就会 `Permission denied` 起不来。

| 镜像 | 运行 uid | 需要的 `securityContext` |
|---|---|---|
| prom/prometheus | 65534 (nobody) | `fsGroup: 65534` |
| prom/alertmanager | 65534 (nobody) | `fsGroup: 65534` |
| grafana/loki | 10001 | `fsGroup: 10001` |
| grafana/grafana | 472 | `fsGroup: 472` |

`fsGroup` 的作用是让 kubelet 把卷的属组改成指定 GID 并开组写权限——
**这是有状态服务上 PVC 的标准动作，不是可选项。**

### 22. Promtail 的位置文件不能放 `/tmp`

`positions.filename` 记录"每个日志文件读到第几行"。放 `/tmp` 的话
Promtail 一重启就失忆：要么从末尾开始（**漏采**），要么从头开始（**重复采**）。

DaemonSet 每个节点一份，天然适合用 `hostPath`：

```yaml
positions:
  filename: /var/lib/promtail/positions.yaml
volumes:
  - name: positions
    hostPath:
      path: /var/lib/promtail
      type: DirectoryOrCreate   # 目录不存在时自动建，避免首次部署起不来
```

### 23. ArgoCD 不支持 Gitee webhook —— 以及"改 `/etc/hosts`"为什么对 Pod 无效

ArgoCD 原生支持的 Git webhook 只有：**GitHub、GitLab、Bitbucket、Bitbucket Server、
Azure DevOps、Gogs**。Gitee 不在列表里，把 Gitee 的 push 事件直接打到
`/api/webhook` 会被判为 `Unknown webhook event` 返回 400。

网上常见的偏方是：**定时用境外 DNS 解析 GitHub 域名，写进宿主机 `/etc/hosts`**。
这个思路对"自己 SSH 上服务器手动 clone"有帮助，但对 ArgoCD **有两处硬伤**：

| 硬伤 | 说明 |
|---|---|
| 管不到 Pod | 容器里的 `/etc/hosts` 是 kubelet 单独生成并挂载的（`/var/lib/kubelet/pods/&lt;uid&gt;/etc-hosts`），**宿主机改了 Pod 感知不到**。而拉仓库的是 `argocd-repo-server` 这个 Pod |
| 治标不治本 | 只修 DNS，修不了链路层丢包；IP 硬编码 + cron 更新，GitHub 一换 IP 就黑洞到下次定时 |

**正确的排查顺序（分级处理）：**

1. **先测 Pod 内连通性**——很多"不通"其实是想当然：
   ```bash
   kubectl run nettest --image=busybox:1.36 --restart=Never -- sh -c \
     'timeout 20 wget -qO- https://api.github.com >/dev/null 2>&1 && echo OK || echo FAIL'
   ```
2. 若 DNS 解析到错 IP → **改 CoreDNS 的上游转发**（`forward . 1.1.1.1 8.8.8.8`）。
   这才是那个偏方的正确版本：集群级生效、一处修改、无 cron、不会 IP 过期。
3. 确实不通 → 才考虑 Gitee 拉代码 + 自建 webhook 转发层。

**本次结论**：宿主机 GitHub 200（1.37s）、Pod 内 DNS 解析正常且 HTTPS 通 →
直接切回 GitHub，白捡原生 webhook，一行转发代码都不用写。

#### 逃生舱：Git 不可达时怎么救

root Application 的源指向 GitHub。万一跨境网络又抽风，ArgoCD 拉不到 Git，
而"修好它"本身又要读 Git —— 死循环。

所以 **root-app 是唯一手工 apply 的 Application，它天然是恢复入口**：

```bash
kubectl apply -f 00-bootstrap/root-app-gitee-fallback.yaml   # 切回 Gitee
```

这个 fallback 文件独立于主链路，不需要 ArgoCD 能工作。
**任何 GitOps 系统都应该保留一条不依赖自身的恢复路径**——这是设计纪律。

### 24. 连通性测试必须测"真实会走的那条路径"

这是 2026-09-10 判断失误换来的教训，值得单独记一条。

当时我测的是 `https://api.github.com`（一个小 HTTPS 请求，1.37s 就回来了），
据此判定"服务器能直连 GitHub"，把 ArgoCD 的源切了过去。

**第二天打脸**：`failed to list refs: Get "https://github.com/NingF324/sre-lab.git/info/refs?service=git-upload-pack": net/http: TLS handshake timeout`

两次请求的区别：

| | 我测的 | 实际走的 |
|---|---|---|
| 域名 | `api.github.com` | `github.com` |
| 路径 | `/` | `/<repo>.git/info/refs?service=git-upload-pack` |
| 数据量 | 几百字节 | 几十 KB+ |
| 耗时 | 1.37s | 常超 30s |

**跨境链路的问题往往只在"大流量 / 长连接"上暴露，小请求探测不出来。**

正确的测试方法：

```bash
kubectl run nettest --image=busybox:1.36 --restart=Never -- sh -c '
timeout 30 wget -qO- "https://github.com/NingF324/sre-lab.git/info/refs?service=git-upload-pack" >/dev/null 2>&1 \
  && echo "GitHub git OK" || echo "GitHub git FAIL"
timeout 20 wget -qO- "https://gitee.com/ningf321/sre-lab.git/info/refs?service=git-upload-pack" >/dev/null 2>&1 \
  && echo "Gitee  git OK" || echo "Gitee  git FAIL"
'
```

**并且要重复跑几次、不同时段跑**——单次成功不能作为"稳定"的证据。
一次观测叫"碰巧"，多次观测才叫"结论"。

结论：本环境（腾讯云上海）访问 GitHub 的 git 协议不稳定，
**ArgoCD 的拉取源用 Gitee，GitHub 只作镜像和 webhook 来源**。

### 25. 公网只留一条"窄缝"：为什么最后加了一层 relay

**起因**：为了收 GitHub 的 webhook，我们把整个 `argocd-server` 暴露在了 NodePort 30080 上。
虽然靠防火墙白名单兜住了，但架构上是错的——

> **"给 webhook 开一个口"和"把管理界面放到公网"是两件事，而 NodePort 区分不了。**
> Service 只能转发端口，不能按 URL 路径过滤。

同时 GitHub 拉取不稳定（第 24 条），拉取源必须留在 Gitee，
而 Gitee 又不在 ArgoCD 原生 webhook 支持列表里（第 23 条）。

两个问题一个解法：**在中间加一层只做一件事的转发器**。

```
GitHub push
    │  HTTP（防火墙只放行 GitHub 的 IP 段）
    ▼
webhook-relay  :30096          ← 公网唯一的入口，只认 /hook/<token>
    │  改成 Gitee 坐标的 GitHub 格式 payload
    ▼
argocd-server  /api/webhook    ← 集群内，不再暴露公网
    │  按 payload 里的 repoURL 匹配 Application
    ▼
刷新（秒级）
```

**收益**：

| 之前 | 之后 |
|---|---|
| 30080 暴露整个 ArgoCD（UI + API + 登录页） | 只暴露 relay，只认一个路径 + 一个令牌 |
| UI 靠防火墙白名单挡着 | **30080 可以直接撤掉**，UI 永久留在隧道后面 |
| Gitee 源收不到 webhook | 秒级同步可用，且拉取源稳定 |

**顺带把"转发器怎么写对"这件事讲清楚**，这几条生产里踩过才知道：

1. **对上游永远回 200**。ArgoCD 返回非 200 时，relay 照样回 GitHub 200——
   否则 GitHub 会判定投递失败并**反复重试**，制造重复投递风暴。
   转发失败是 relay 的内部问题，不该让上游承担。
2. **令牌放 URL 路径，不放请求头**。GitHub 的 webhook 配置**不允许自定义请求头**，
   所以只能用 `/hook/<随机串>` 这种形式。
3. **缺令牌时 fail-closed**。Secret 不存在就拒绝所有请求并打日志，
   而不是"没配就当没这回事"放行——**安全配置缺失必须表现为不可用，不能表现为静默降级**。
4. **投递记录不落盘**。这是排障用的临时视图，重启丢失可以接受；
   真要审计就该落库，不该往文件里堆。

**2026-09-11 实测收口**：relay 打通后执行了 `kubectl delete svc argocd-webhook`，
并从 Git 移除 `07-argocd/argocd-webhook.yaml`。公网入口只剩 30096。

> ⚠️ **删集群资源时必须同时删 Git 里的声明。**
> `argocd-extras` 是 `selfHeal: true`，只要声明还在 Git 里，
> ArgoCD 下一轮就会把删掉的 Service **原样重建**出来 —— 手工删 = 白删。
> 这是踩坑 13（配置漂移）的另一面：**GitOps 下集群状态永远向 Git 收敛，
> 所以"删除"这个动作必须发生在 Git 里，而不是在集群里。**

### 26. 声明了 ConfigMap ≠ 挂载了 ConfigMap

写 `webhook-relay` 时犯的低级错误，但症状很有迷惑性：

```yaml
containers:
  - name: relay
    command: ["python", "/app/app.py"]   # 引用了 /app/app.py
    # ← 忘了写 volumeMounts，也没写 volumes
```

**Pod 能正常调度、镜像能拉、容器能启动**，然后立刻崩：

```
python: can't open file '/app/app.py': [Errno 2] No such file or directory
```

原因是 `command` 只是**约定**要读这个路径，并没有保证它存在。
`ConfigMap` 对象存在 ≠ 它被挂进容器了 —— 中间必须有 `volumes` + `volumeMounts` 两处声明。

**排查要点**：看到"文件不存在"但 ConfigMap 明明存在时，先看 Pod 的卷有没有挂上：

```bash
kubectl get pod <pod> -o jsonpath='{.spec.volumes[*].name}{"\n"}'
kubectl get pod <pod> -o jsonpath='{.spec.containers[0].volumeMounts[*].mountPath}{"\n"}'
kubectl exec <pod> -- ls -la /app
```

**更通用的教训**：这类"声明与挂载分离"的设计在 K8s 里到处都是
（ConfigMap、Secret、PVC、ServiceAccount、hostPath），
**对象存在只是必要条件，不是充分条件**。凡是"资源建了但用不上"，先查引用链有没有断。

### 27. 管理界面不该暴露在公网 —— Service 类型是安全边界

搭环境时图省事，四个管理界面全用了 `NodePort`：

| 端口 | 组件 | 密码 |
|---|---|---|
| 30030 | Grafana | **admin123** |
| 30090 | Prometheus UI | 无认证 |
| 30093 | Alertmanager UI | 无认证 |
| 30095 | 告警诊断卡片 | 无认证 |

**`NodePort` 的语义是"在每个节点的所有网卡上开一个端口"**——
只要防火墙放行，它就是公网可达的。等于把四个管理界面挂在互联网上，
其中一个还是弱口令。这是新手搭环境最常见的疏忽。

**三种 Service 类型的语义要分清：**

| 类型 | 可达范围 | 什么时候用 |
|---|---|---|
| `ClusterIP` | 只有集群内部 | **默认选它**。管理界面、内部 API |
| `NodePort` | 每个节点的 30000-32767 端口 | 必须被外部主动访问，且没有 Ingress |
| `LoadBalancer` | 云厂商给的公网/内网 LB | 生产对外服务 |

**判断口诀：这个流量是"别人来敲我"还是"我自己去敲它"？**

- **别人来敲我**（GitHub 推 webhook、用户访问网站）→ 必须暴露，但要收窄
- **我自己去敲它**（我打开 Grafana 看图表）→ 用隧道，永远不要暴露

**改法**：四个 Service 全部改成 `ClusterIP`，防火墙对应端口一并关掉。

**访问方式**（ClusterIP 从节点宿主机上是可达的，
因为 kube-proxy 的转发规则写在 host network namespace 里）：

```bash
# 先拿到 ClusterIP
kubectl get svc -n monitoring
```

**本地 PowerShell，一条命令开四个隧道：**

```powershell
ssh -N -L 3000:10.43.x.x:3000 -L 9090:10.43.x.x:9090 -L 9093:10.43.x.x:9093 -L 8080:10.43.x.x:8080 root@<你的公网IP>
```

浏览器分别开 `http://localhost:3000`（Grafana）、`:9090`（Prometheus）、
`:9093`（Alertmanager）、`:8080`（诊断卡片）。

> 好处是**流量全程走 SSH 加密**，而且这四个端口从公网**完全不可达**——
> 不是"靠防火墙挡着"，是 Kubernetes 层面就没有对外端口。

**什么时候真的需要 NodePort**：`webhook-relay` 的 30096。
因为那条流量是 **GitHub 主动敲我们**，隧道做不到（对方不是我们）。

### 28. 改了 Grafana 的环境变量，密码却没变 —— 配置源 ≠ 运行态

原来密码是硬编码的：

```yaml
env:
  - name: GF_SECURITY_ADMIN_PASSWORD
    value: "admin123"        # 两个问题：弱口令 + 密码进了 public 仓库
```

改成 Secret 注入后，**第一次尝试会发现密码根本没变**。原因：

> **Grafana 首次启动时会把管理密码写进 `grafana.db`**（在 PVC 里）。
> 之后启动只读数据库，`GF_SECURITY_ADMIN_PASSWORD` 被忽略。
> 这个环境变量只对**全新的数据库**起作用。

存量实例必须用 CLI 重置：

```bash
kubectl exec -n monitoring deploy/grafana -- grafana cli admin reset-admin-password '<新密码>'
```

**这是一类问题的又一个实例**，和踩坑 24（ConfigMap 改了进程不重载）本质相同：

| 组件 | 配置变更后是否需要额外动作 |
|---|---|
| Prometheus | 需要 `POST /-/reload` |
| Alertmanager | 自动监听文件变化重载 |
| Grafana | 环境变量只影响首次初始化，之后改数据库 |
| Loki | `schema_config` 只对新数据生效，老数据不变 |

**通用判断方法**：问一句"这个配置是启动时读一次，还是每次运行都读？它的状态存在哪？"
—— 答案决定了改完之后要不要额外推一把。

#### 密码管理的三级演进（面试常问）

| 级别 | 做法 | 问题 |
|---|---|---|
| 1 | 明文写进 YAML | public 仓库 = 全世界可见（就是踩的这个） |
| 2 | K8s Secret 注入 | 密码不进 Git。但 **Secret 只是 base64 编码，不是加密** —— 能读 Secret 的人就能拿到密码 |
| 3 | SealedSecrets / External Secrets / Vault | Secret 密文可以进 Git，真加密、可审计、能轮转 |

**级别 2 的补充**：生产还要给 etcd 配静态加密（`EncryptionConfiguration`），
否则 Secret 在 etcd 里就是明文；同时用 RBAC 把 `get secret` 权限收到最小。

```yaml
env:
  - name: GF_SECURITY_ADMIN_PASSWORD
    valueFrom:
      secretKeyRef:
        name: grafana-admin
        key: password
        # 不用 optional：凭据缺失必须让 Pod 起不来（fail loudly），
        # 而不是悄悄退回 Grafana 的默认口令 admin/admin
        optional: false
```

### 29. 动态基线的第一道坎：分母趋零

固定阈值告警天生两难：定高了漏报、定低了误报，而且指标有周期性
（白天高夜里低），一条水平线必然有一半时间是错的。

换思路：用指标**自己的近期分布**定义"正常"，衡量当前值偏离了多少个标准差
（统计学叫 z-score）：

```
偏离度 = (当前值 - 近 1 小时均值) / 近 1 小时标准差
```

**但直接这么写，第一版一定会在低负载机器上疯狂误报。**

原因：基线平稳时标准差趋近于 0。一台 CPU 常年 1% 的机器，
标准差可能是 0.001 —— 那么 CPU 从 1% 涨到 2%，算出来就是
**"偏离 10 个标准差"**，看起来极其异常，实则毫无意义。
**分母趋零，把噪声放大成了异常。**

修法是给标准差设下限（下面配置里的 `clamp_min`）：

```yaml
- record: node:cpu_busy:deviation_sigma
  expr: >
    (node:cpu_busy:ratio5m - node:cpu_busy:avg1h)
    / clamp_min(node:cpu_busy:stddev1h, 0.02)
```

`clamp_min(x, 0.02)` 的含义是"标准差至少按 2% 算"——
等于给检测器设了一个**最小灵敏度**：变化幅度小于 2% 的波动，无论多"违和"都不算异常。

**这是所有基于标准差的异常检测都要处理的第一个问题**，
不是 Prometheus 特有的（监控、风控、A/B 实验全都一样）。

**第二道坎：基线会把异常"吸收"掉（基线漂移 / concept drift）**

实测数据 —— 起 2 个 burner 后，偏离度的实际走势：

| 时刻 | 偏离度 σ |
|---|---|
| +0 min | 3.67 |
| +1 min | **6.07** |
| +3 min | 4.55 |
| +5 min | 3.20 |
| +6 min | 2.15 |
| +7 min | 0.63 |

**异常正在发生，偏离度却自己掉回正常区间了。** 原因是负载一起来，
`avg1h` 往上走、`stddev1h` 也变大 —— **分子减小、分母增大**，
基线把异常"吸收"成了新的正常。

**工程含义**：动态基线的异常可检出窗口是**有限的**。
所以 `for` 必须短于这个窗口 —— 本例中超过 3σ 的窗口只有约 5 分钟，
`for: 5m` 会**刚好卡在边界上永远进不了 firing**。最终设成 `for: 2m`。

这也是为什么动态基线**不能替代**固定阈值：持续型异常最终会被基线吃掉，
只有固定阈值能一直守住"绝对值红线"。两者必须并存。

另外三个必须知道的点：

1. **数据预热窗口**：`avg_over_time[1h]` / `stddev_over_time[1h]` 需要攒够 1 小时数据，
   Prometheus 重启后这段时间内规则不出值。**不是坏了，是还没数据。**
2. **recording rule 的 group 顺序**：Prometheus 按文件中的顺序评估 group，
   基线 group 必须放在使用它的告警 group **前面**。
3. **和固定阈值是互补，不是替代**：
   - 固定阈值回答"现在是不是很忙"（绝对值）
   - 动态基线回答"现在是不是反常"（相对值）

   低负载机器上固定阈值几乎永不触发，而"平时 2% 跳到 15%"这种
   业务上的真实异常，只有动态基线能覆盖。

### 30. SealedSecrets：把"密钥存哪"转移了，但没有消灭它

**要解决的问题**：Secret 不能明文进 Git，但重建环境又必须能从 Git 恢复。
两者矛盾，所以需要一个"密文可以公开、只有集群能解开"的机制。

**做法**：控制器持有一对 RSA 密钥。
`kubeseal` 用公钥加密 → 密文提交 Git → 控制器用私钥解密成真正的 Secret。

```
明文 Secret ──kubeseal+公钥──▶ SealedSecret(密文) ──git push──▶ 仓库
                                                                  │
                                                          ArgoCD 同步
                                                                  ▼
                            集群内 Secret ◀──控制器用私钥解密── SealedSecret(密文)
```

**但有个关键前提：主密钥必须自己备份。**

> SealedSecrets 把"3 个 Secret 要存哪"变成了"1 把主密钥要存哪" ——
> **问题规模小了，但没有消失。**
> 主密钥一丢，Git 里所有密文都变成永远解不开的垃圾。

备份（**绝不进 Git**，存密码管理器）：

```shell
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > sealed-secrets-master-key.yaml
```

**重建环境的正确顺序**（顺序错了密文就解不开）：

1. 装控制器 `kubectl apply -f controller.yaml`
2. **先恢复主密钥**，再删掉控制器自动生成的那把：
   ```shell
   kubectl apply -f sealed-secrets-master-key.yaml
   kubectl -n kube-system rollout restart deploy sealed-secrets-controller
   ```
3. 最后让 ArgoCD 同步 SealedSecret 文件

#### 安装时踩的三个坑

| 坑 | 现象 | 解法 |
|---|---|---|
| 镜像不在 quay.io 了 | `quay.io/bitnami/sealed-secrets-controller` 返回 **401**（能连通但仓库不可用） | 官方 `controller.yaml` 已改用 `docker.io/bitnami/sealed-secrets-controller:0.40.0`，**Docker Hub 反而有加速** |
| 别被 `hub.docker.com` 超时误导 | 网站 API 返回 000 | 那只是网页 API，**不影响 registry 拉取** |
| kubeseal 二进制下载被截断 | 5.3MB（正常几十 MB），解压报 `unexpected end of file`，跑起来 `Bus error` | 换国内 GitHub 代理（本例 `ghfast.top` 可用）；**判据用 `tar -tzf` 验证，比看文件大小可靠** |

#### 两个必须知道的边界

1. **命名空间绑定**：SealedSecret 默认 strict scope，密文只在加密时指定的
   namespace 里能解开 —— 防的是"拿到密文换个地方用"。
   **换 namespace 就必须重新加密**（改 `openssl`/`yq` 拼密文没用）。
2. **它防的是"仓库泄露"，不防"集群被入侵"**：
   任何能在集群里读 Secret 的人，照样能拿到明文。
   SealedSecrets 解决的是**分发**问题，不是**运行时保护**问题。

---

## 已知限制

- **存储已全面持久化**（PVC + k3s 自带 local-path provisioner）：

  | 组件 | 卷 | 大小 | 存的是什么，丢了会怎样 |
  |---|---|---|---|
  | Prometheus | `prometheus-data` | 8Gi | TSDB。丢了历史曲线全没，压测复盘无从谈起 |
  | Loki | `loki-data` | 5Gi | 日志 chunk + 索引。丢了查不到任何历史日志 |
  | Grafana | `grafana-data` | 1Gi | 手建仪表盘、用户、API Key。丢了要重新导入 |
  | Alertmanager | `alertmanager-data` | 1Gi | **Silence**。丢了静默失效，告警重新开始轰炸 |
  | alert-enricher | `enricher-data` | 1Gi | 诊断卡片（审计溯源）。丢了等于事故没发生过 |
  | Promtail | hostPath `/var/lib/promtail` | — | 读取位置。丢了要么漏采、要么重复采 |

  ⚠️ **local-path 默认 `allowVolumeExpansion=false`，卷不能在线扩容**，
  初次申请要留足余量，真满了只能重建 PVC 再导数据。生产应换云盘 CSI 并开启扩容。
- ~~**Secret 仍需手工创建**~~ → **已解决**：三个 Secret 已用 SealedSecrets 加密后进 Git
  （`10-platform/sealed-*.yaml`、`07-argocd/sealed-*.yaml`）。见踩坑 30。
- **主密钥需要人工备份，仍是重建的必经人工步骤**：SealedSecrets 把问题从
  "3 个 Secret"缩小到"1 把主密钥"，但它仍然不在 Git 里（也不该在）。
  重建时必须先手动恢复主密钥，否则 Git 里的密文解不开。
- **kube-state-metrics 当前只采集四类对象**：Deployment / ReplicaSet / Pod / Node。
  StatefulSet、Job 等对象暂未启用，需要时同步扩展 `--resources` 和 RBAC。
- **Promtail 用静态采集**：见踩坑 9。
- **ClusterIP 写死在 SSH 配置里**：Service 重建后地址会变，隧道要同步改。
- **镜像仓库跨境不稳定**：`registry.k8s.io` 已实测出现连接重置，
  相关镜像已换国内来源，但后续新增组件还会遇到同样问题。
- **单机**：没有多节点调度、亲和性、网络策略的练手条件；
  节点故障即整套不可用，local-path 的数据也与节点绑定，不等于灾备。
- **动态基线只做了 CPU**：内存、磁盘的基线尚未接入，做法可复用但需各自调参。

---

## 后续路线

### 已完成

- [x] **可观测性三件套** —— 指标 / 告警 / 日志三条链路打通
- [x] **GitOps（App-of-Apps）** —— 根 Application 管理 4 个子应用，本仓库即 ArgoCD 的拉取源
- [x] **ArgoCD 秒级同步** —— webhook-relay 把 GitHub push 转成 Gitee 坐标（踩坑 25）
- [x] **持久化改造** —— Prometheus / Loki / Grafana / Alertmanager / enricher 全 PVC（踩坑 19–22）
- [x] **管理界面撤出公网** —— 四个 Service 改 ClusterIP + SSH 隧道（踩坑 27）
- [x] **凭据加固（第一级）** —— Grafana 密码从 Secret 注入，不再进 Git（踩坑 28）
- [x] **Loki Ruler 日志告警** —— `DemoErrorLogsHigh`，触发 / 通知 / 卡片 / 恢复均已验证
- [x] **kube-state-metrics** —— Deployment / ReplicaSet / Pod / Node 四类对象
- [x] **元监控** —— Prometheus 抓 ArgoCD / Grafana / Loki / relay 自身，
      新增 `MonitoringComponentDown` 与"监控系统自身"仪表盘
- [x] **AIOps 异常检测第一版** —— CPU 动态基线 + 偏离度告警（踩坑 29）

### 待做（按推荐顺序）

- [ ] **文档与仓库口径统一** —— 本文件与进度文档互相对齐（进行中）
- [x] ~~**凭据管理升级到第二级** —— SealedSecrets~~（三个 Secret 已加密进 Git，见踩坑 30）
- [ ] **环境重建演练** —— 从 k3s 裸环境恢复整套系统，必须留完整记录
- [ ] **动态基线推广到内存 / 磁盘**
- [ ] **CI 与供应链** —— GitHub Actions 构建镜像 + 漏洞扫描 + 不可变 tag/digest
- [ ] **Istio 灰度发布** —— 先查内存余量，只装 istiod + 只给 demo 命名空间注入
- [ ] 告警接入企业微信 / 钉钉（当前只有 webhook 到自建服务）

### 长期方向

- [ ] 三节点集群：调度、亲和性、NetworkPolicy
- [ ] Loki 接对象存储（腾讯云 COS）
- [ ] Prometheus 接 Thanos / Mimir —— **PVC 解决可用性，对象存储才解决持久性**

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
| kube-state-metrics | 64Mi | 192Mi |
| alert-enricher | 48Mi | 192Mi |
| webhook-relay | 32Mi | 96Mi |

**内存是最硬的约束**：4G 总内存，上面这些 limits 加起来已经接近 2.7G，
再算上 k3s 自身和 ArgoCD（另一大块），剩下的余量不多 ——
所以加新组件前必须先 `kubectl top node` 看余量（Istio 尤其要小心）。
