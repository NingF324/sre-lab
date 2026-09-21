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
kubectl apply -f 06-gitops/root-app.yaml
```

### 目录分工：演进过程 vs 最终状态

`00` ~ `05` 是**逐步演进**的过程，适合照着学。但同一份资源在演进中会被后面的文件
反复覆盖（比如 `prometheus-config` 在 01/02/03 里各有一份，`promtail-config` 在
05 里两份），**直接交给 ArgoCD 会造成同一资源被多处管理** —— 两个控制器互相覆盖，
比 HPA 与 GitOps 打架还严重。

所以收敛出一份最终状态供 GitOps 消费：

```
04-demo-app/   业务服务（Deployment + Service + HPA + Ingress）
10-platform/   监控/告警/日志的最终状态，每个资源只保留最后一次修改的版本
06-gitops/
  ├── root-app.yaml         根 Application，只管下面这些 Application
  └── apps/
      ├── platform-app.yaml   → 指向 10-platform
      └── demo-app.yaml       → 指向 04-demo-app
```

**从零重建整套环境只要三步**（k3s 装好之后）：

```shell
kubectl create namespace argocd
kubectl apply --server-side=true --force-conflicts -n argocd -f argocd-install.yaml
kubectl apply -f 06-gitops/root-app.yaml
```

根 Application 会自动创建 `platform` 和 `demo-app` 两个子 Application，
它们再各自同步自己负责的目录 —— 这就是 **App-of-Apps 模式**。
新增组件只需往 `apps/` 里加一个文件，根应用自动发现。

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
- **kube-state-metrics 当前只采集四类对象**：Deployment / ReplicaSet / Pod / Node。
  StatefulSet、Job 等对象暂未启用，需要时同步扩展 `--resources` 和 RBAC。
- **Promtail 用静态采集**：见踩坑 9。
- **单机**：没有多节点调度、亲和性、网络策略的练手条件。

---

## 后续路线

- [x] ~~日志告警（Loki Ruler：ERROR 日志速率超阈值告警）~~（已完成：触发、通知、诊断卡片及恢复均已验证）
- [x] ~~持久化改造（PVC 替代 emptyDir）~~（已完成：Prometheus / Loki / Grafana / Alertmanager / enricher 全部 PVC）
- [x] ~~kube-state-metrics（补齐 Deployment 维度指标）~~（已完成：Deployment / ReplicaSet / Pod / Node）
- [x] ~~Webhook 改造（ArgoCD 秒级同步）~~（`webhook-relay` NodePort **30096**，见 README 第 25 条）
- [ ] App-of-Apps 模式（用一个根 Application 管理全部子 Application）
- [x] ~~ArgoCD GitOps~~（已完成：demo-app 已由 Git 自动同步）
- [x] ~~凭据加固：Grafana 的 admin123 改为从 Secret 注入~~（已完成，见 README 第 28 条）
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

<!-- webhook verified 2026-09-11T10:56:43 -->
