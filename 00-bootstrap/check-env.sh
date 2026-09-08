#!/bin/bash
# 服务器安装情况体检脚本 - 陈墨
# 用法：bash check-env.sh
# 作用：一次性看清 Docker / k3s / 监控栈 / 资源 / 端口 的当前状态

echo "=========================================="
echo " 1. 系统与运行时间"
echo "=========================================="
grep PRETTY_NAME /etc/os-release 2>/dev/null
echo "内核     : $(uname -r)"
echo "运行时长 : $(uptime -p 2>/dev/null)"
echo "CPU 核数 : $(nproc)"

echo ""
echo "=========================================="
echo " 2. 资源占用（重点看磁盘剩余）"
echo "=========================================="
free -h
echo "---"
df -h / | tail -1

echo ""
echo "=========================================="
echo " 3. Docker 状态"
echo "=========================================="
if command -v docker >/dev/null 2>&1; then
    echo "[OK] 已安装：$(docker --version)"
    if systemctl is-active docker >/dev/null 2>&1; then
        echo "[OK] Docker 正在运行"
    else
        echo "[!!] Docker 已安装但未运行 → 执行：systemctl start docker"
    fi
    echo "--- 运行中容器（$(docker ps -q 2>/dev/null | wc -l）个）---"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
else
    echo "[XX] Docker 未安装"
fi

echo "--- Docker Compose ---"
if docker compose version >/dev/null 2>&1; then
    echo "[OK] $(docker compose version --short)"
elif command -v docker-compose >/dev/null 2>&1; then
    echo "[OK] $(docker-compose --version)"
else
    echo "[XX] Compose 未安装"
fi

echo ""
echo "=========================================="
echo " 4. k3s / Kubernetes 状态"
echo "=========================================="
if command -v k3s >/dev/null 2>&1; then
    echo "[OK] 已安装：$(k3s --version 2>/dev/null | head -1)"
    if systemctl is-active k3s >/dev/null 2>&1; then
        echo "[OK] k3s 正在运行"
    else
        echo "[!!] k3s 已安装但未运行 → 执行：systemctl start k3s"
    fi
    if command -v kubectl >/dev/null 2>&1; then
        KUBECTL="kubectl"
    else
        KUBECTL="k3s kubectl"
    fi
    echo "--- 节点 ---"
    $KUBECTL get node 2>&1
    echo "--- 系统 Pod ---"
    $KUBECTL get pods -A 2>&1
else
    echo "[XX] k3s 未安装"
fi

echo ""
echo "=========================================="
echo " 5. 端口监听（看服务是否对外可用）"
echo "=========================================="
if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | head -25
else
    netstat -tlnp 2>/dev/null | head -25
fi

echo ""
echo "=========================================="
echo " 6. 磁盘大头（40G 系统盘重点盯这几个）"
echo "=========================================="
du -sh /var/lib/docker /var/lib/rancher /var/log 2>/dev/null

echo ""
echo "=========================================="
echo " 体检结束"
echo "=========================================="
echo "对照说明："
echo "  [OK] = 已装且正常   [!!] = 装了但没跑起来   [XX] = 没装"
echo "  常见端口：3000=Grafana  9090=Prometheus  9100=NodeExporter  6443=k8s API"
