#!/bin/bash
# OpenCloudOS 9 专用：k3s 单节点初始化脚本（走 Rancher 中国镜像，避免 get.k3s.io 超时）
# 用法：bash k3s-init-oc9.sh
# 幂等：重复执行安全，已装的组件会自动跳过

echo "==> [1/6] 安装基础工具"
dnf install -y curl vim wget git htop net-tools bind-utils iptables tar

echo "==> [2/6] 配置 SELinux 与防火墙"
# 云厂商外层有安全组，主机防火墙关闭无风险；k3s 在 enforcing 下需额外装 k3s-selinux，学习机直接放宽
if [ -f /etc/selinux/config ]; then
    setenforce 0 2>/dev/null || true
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
fi
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true
echo "    SELinux 当前状态: $(getenforce 2>/dev/null)"

echo "==> [3/6] 设置时区"
timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
date

echo "==> [4/6] 安装 k3s"
if command -v k3s >/dev/null 2>&1; then
    echo "    k3s 已安装，跳过"
else
    curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -
fi

echo "==> [5/6] 等待 k3s 就绪"
sleep 20
systemctl is-active k3s

echo "==> [6/6] 配置 kubectl 快捷方式"
ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
mkdir -p "$HOME/.kube"
cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

echo ""
echo "=========================================="
echo " 安装完成，节点状态："
echo "=========================================="
kubectl get node
echo "--- 系统 Pod ---"
kubectl get pods -A
