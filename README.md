# sre-lab —— 单节点 SRE 可观测性实验环境

一套跑在 **4 核 4G** 云服务器上的完整 SRE 练手环境：k3s + Prometheus + Grafana + Alertmanager + HPA + Loki。
所有组件从零手写 YAML 部署，不用 Helm Chart，目的是**把每个组件的行为和取舍都摸清楚**。

> 硬件：腾讯云轻量 4C4G / 40G / OpenCloudOS 9.6（RHEL 系，对齐生产栈）
> 集群：k3s v1.36.4+k3s1，单节点

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
```

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

# Loki 收到日志没有（关键！返回 data 数组才算通）
kubectl exec -n monitoring deploy/loki -- \
  sh -c 'wget -qO- http://localhost:3100/loki/api/v1/labels'
```

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
