#!/usr/bin/env bash
# -*- coding: utf-8 -*-
#
# install.sh - 兼容 Ubuntu/Debian、CentOS/AlmaLinux/RHEL 等的自动安装脚本
#              若已安装 Nginx，仅新增站点；否则先安装 Nginx，再新增站点
#              并自动配置 Let’s Encrypt 证书续期（每月 1 日 01:00 执行）
#
# 功能：
#   1. 交互式获取“域名”与“Email”（各最多允许 3 次输入错误）
#   2. 自动检测 Linux 发行版（Ubuntu/Debian vs CentOS/AlmaLinux/RHEL）
#   3. 检查是否已安装 Nginx：
#        - 已安装：跳过 Nginx 安装，直接配置新域名站点
#        - 未安装：先安装 Nginx，再配置新域名站点
#      同时安装 curl、unzip、git、socat、cron/cronie 等依赖
#   4. 检查并放行 80/443 端口（支持 UFW、firewalld、iptables）
#   5. 下载并解压最新版本的 web.zip（从 GitHub Releases 的 latest 链接）
#   6. 安装并使用 acme.sh 申请 Let’s Encrypt SSL 证书
#      （先生成“仅 HTTP+challenge”临时配置，再申请，再生成“HTTPS”正式配置）
#   7. 生成 Nginx 正式配置（80→443 重定向 + HTTPS 正式站点）并启用
#   8. 启动/重载 Nginx 服务
#   9. 安装并配置 cron/cronie，添加每月 1 日 01:00 自动续期 acme.sh 的 Crontab 任务
#  10. 提示用户检查防火墙（放行 80/443 端口）
#
# 使用方法：
#   curl -Ls https://raw.githubusercontent.com/dmulxw/download/master/install.sh | sudo bash
#   （脚本内部通过 /dev/tty 读取输入，能够在管道执行时正确等待用户交互）
#

set -e

###########################################
# 0. 检测当前发行版类型                    #
###########################################
OS_ID=""
OS_FAMILY=""

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="$ID"
    OS_FAMILY="$ID_LIKE"
else
    echo "⛔ 找不到 /etc/os-release，无法检测发行版类型，请手动确认系统类型后再运行脚本。"
    exit 1
fi

IS_DEBIAN_FAMILY=false
IS_RHEL_FAMILY=false

if [[ "$OS_ID" =~ (debian|ubuntu|raspbian) ]] || [[ "$OS_FAMILY" =~ (debian) ]]; then
    IS_DEBIAN_FAMILY=true
fi
if [[ "$OS_ID" =~ (centos|rhel|almalinux|rocky) ]] || [[ "$OS_FAMILY" =~ (rhel|fedora) ]]; then
    IS_RHEL_FAMILY=true
fi

echo
echo "######################################################"
echo " 检测到发行版信息："
echo "   ID=${OS_ID}"
echo "   ID_LIKE=${OS_FAMILY}"
if $IS_DEBIAN_FAMILY; then
    echo "   → 归为：Debian/Ubuntu 系列"
elif $IS_RHEL_FAMILY; then
    echo "   → 归为：RHEL/CentOS/AlmaLinux/Rocky 系列"
else
    echo "   → 未知发行版系列，本脚本仅支持 Debian/Ubuntu 与 RHEL/CentOS/AlmaLinux"
    exit 1
fi
echo "######################################################"
echo

###########################################
# 1. 交互式获取“域名”                     #
###########################################
get_domain() {
    MAX_TRIES=3
    DOMAIN=""
    exec 3<&0  # 备份标准输入
    exec < /dev/tty
    for ((i=1; i<=MAX_TRIES; i++)); do
        read -rp "请输入要绑定的域名（第 ${i} 次，共 ${MAX_TRIES} 次机会）： " input_domain
        if [[ -n "$input_domain" && "$input_domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
            DOMAIN="$input_domain"
            break
        else
            echo "❌ 域名格式不合法，请重新输入（只能包含字母/数字/点/横杠）。"
        fi
        if [[ $i -eq $MAX_TRIES ]]; then
            echo "⛔ 3 次输入均不合法，安装程序退出。"
            exec 0<&3  # 恢复标准输入
            exit 1
        fi
    done
    exec 0<&3  # 恢复标准输入
    echo "✅ 已确认域名：${DOMAIN}"
    echo
}

###########################################
# 2. 交互式获取“Email”地址                #
###########################################
get_email() {
    MAX_TRIES=3
    EMAIL=""
    exec 3<&0
    exec < /dev/tty
    for ((i=1; i<=MAX_TRIES; i++)); do
        read -rp "请输入用于申请 SSL 证书的 Email（第 ${i} 次，共 ${MAX_TRIES} 次机会）： " input_email
        if [[ -n "$input_email" && "$input_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            EMAIL="$input_email"
            break
        else
            echo "❌ Email 格式不合法，请重新输入。"
        fi
        if [[ $i -eq $MAX_TRIES ]]; then
            echo "⛔ 3 次输入均不合法，安装程序退出。"
            exec 0<&3
            exit 1
        fi
    done
    exec 0<&3
    echo "✅ 已确认 Email：${EMAIL}"
    echo
}

# 调用交互函数
get_domain
get_email

##############################################
# 3. 检查是否为 root，并安装所需依赖（分发） #
##############################################
echo "######################################################"
echo "  开始检查并安装必要软件包"
echo "######################################################"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "⛔ 请使用 root 用户或通过 sudo 运行本脚本！"
    exit 1
fi

# 检查是否已安装 nginx
NGINX_EXIST=false
if command -v nginx &>/dev/null; then
    NGINX_EXIST=true
    echo "ℹ️ 检测到系统已安装 Nginx，将仅新增站点，不重新安装 Nginx。"
else
    echo "ℹ️ 系统未检测到 Nginx，后续将先安装 Nginx。"
fi

install_deps_debian() {
    echo ">>> Debian/Ubuntu 系列：安装或更新依赖 ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y

    # 如果未安装 nginx，则安装 nginx
    if ! $NGINX_EXIST; then
        apt-get install -y nginx
        echo "✅ 已安装 Nginx。"
    fi

    # 安装其他依赖：curl、unzip、git、socat、cron
    apt-get install -y curl unzip git socat cron

    # 启用并启动 nginx 和 cron 服务
    systemctl enable nginx
    systemctl start nginx

    systemctl enable cron
    systemctl start cron
}

install_deps_rhel() {
    echo ">>> RHEL/CentOS/AlmaLinux 系列：安装或更新依赖 ..."
    if command -v dnf &>/dev/null; then
        pkg_manager="dnf"
    else
        pkg_manager="yum"
    fi

    echo "安装 EPEL 源（如未安装）..."
    if [[ "$pkg_manager" == "dnf" ]]; then
        dnf install -y epel-release
        dnf makecache
    else
        yum install -y epel-release
        yum makecache
    fi

    # 如果未安装 nginx，则安装 nginx
    if ! $NGINX_EXIST; then
        if [[ "$pkg_manager" == "dnf" ]]; then
            dnf install -y nginx
        else
            yum install -y nginx
        fi
        echo "✅ 已安装 Nginx。"
    fi

    # 安装其他依赖：curl、unzip、git、socat、cronie
    if [[ "$pkg_manager" == "dnf" ]]; then
        dnf install -y curl unzip git socat cronie
    else
        yum install -y curl unzip git socat cronie
    fi

    # 启用并启动 nginx、crond 服务
    systemctl enable nginx
    systemctl start nginx

    systemctl enable crond
    systemctl start crond
}

# 根据系统类别安装依赖
if $IS_DEBIAN_FAMILY; then
    install_deps_debian
elif $IS_RHEL_FAMILY; then
    install_deps_rhel
else
    echo "⛔ 未知系统系列，无法自动安装依赖。"
    exit 1
fi

# 最终检查 nginx 是否成功安装或已存在
if ! command -v nginx &>/dev/null; then
    echo "⛔ Nginx 安装或启动失败，请检查网络或包源配置。"
    exit 1
fi

echo "✅ 依赖安装与基础服务启动完成。"
echo

#############################################
# 4. 检查并放行 80/443 端口（防火墙自动处理） #
#############################################
echo "######################################################"
echo "  检查并放行 80/443 端口"
echo "######################################################"

open_ports() {
    # 检查并放行 80/443 端口，支持 ufw、firewalld、iptables
    if command -v ufw &>/dev/null; then
        if ufw status | grep -qw active; then
            echo "检测到 ufw，正在放行 80/443 端口..."
            ufw allow 80/tcp || true
            ufw allow 443/tcp || true
            ufw reload || true
        fi
    fi

    if command -v firewall-cmd &>/dev/null; then
        if systemctl is-active firewalld &>/dev/null; then
            echo "检测到 firewalld，正在放行 80/443 端口..."
            firewall-cmd --permanent --add-service=http || true
            firewall-cmd --permanent --add-service=https || true
            firewall-cmd --reload || true
        fi
    fi

    # 仅在未检测到 ufw/firewalld 时尝试 iptables
    if ! command -v ufw &>/dev/null && ! command -v firewall-cmd &>/dev/null; then
        if command -v iptables &>/dev/null; then
            echo "检测到 iptables，正在放行 80/443 端口..."
            iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
            iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT
            # 保存规则（如果安装了 netfilter-persistent 或 service iptables save）
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save
            elif command -v service &>/dev/null && service iptables save &>/dev/null; then
                service iptables save
            fi
        fi
    fi
}

open_ports

echo "✅ 已尝试自动放行 80/443 端口，请手动确认防火墙规则。"
echo

####################################
# 5. 下载并解压 最新 web.zip (GitHub release) #
####################################
echo "######################################################"
echo "  下载并部署最新版本 web.zip"
echo "######################################################"

ZIP_URL="https://github.com/dmulxw/download/releases/latest/download/web.zip"
WEB_ROOT="/var/www/${DOMAIN}/html"
mkdir -p "${WEB_ROOT}"

TMP_ZIP="/tmp/web_${DOMAIN}.zip"
echo "正在从 ${ZIP_URL} 下载最新 web.zip 到 ${TMP_ZIP} ...
