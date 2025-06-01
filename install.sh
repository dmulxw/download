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
#   4. 下载并解压最新版本的 web.zip（从 GitHub Releases 的 latest 链接）
#   5. 安装并使用 acme.sh 申请 Let’s Encrypt SSL 证书
#   6. 生成 Nginx 配置（80→443 重定向 + HTTPS 正式站点）并启用
#   7. 启动/重载 Nginx 服务
#   8. 安装并配置 cron/cronie，添加每月 1 日 01:00 自动续期 acme.sh 的 Crontab 任务
#   9. 提示用户检查防火墙（放行 80/443 端口）
#
# 使用方法：
#   保存为本地文件，例如 /root/install.sh
#   chmod +x /root/install.sh
#   sudo /root/install.sh
#

set -e

###########################
# 0. 检测当前发行版类型  #
###########################
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

echo "------------------------------------------------------"
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
echo "------------------------------------------------------"
echo

###########################
# 1. 交互式获取“域名”  #
###########################
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

###############################
# 2. 交互式获取“Email”地址  #
###############################
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

# 调用函数
get_domain
get_email

##############################################
# 3. 检查是否为 root，并安装所需依赖（分发） #
##############################################
echo "-----------------------------"
echo "  开始检查并安装必要软件包"
echo "-----------------------------"

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
    # 选用 dnf 或 yum
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

# 根据系统类别安装
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
# 检查并放行 80/443 端口（防火墙自动处理）  #
#############################################
echo "-----------------------------"
echo "  检查并放行 80/443 端口"
echo "-----------------------------"

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
            # 可选：保存规则
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
# 4. 下载并解压 最新 web.zip (GitHub release) #
####################################
echo "-----------------------------"
echo "  下载并部署最新版本 web.zip"
echo "-----------------------------"

ZIP_URL="https://github.com/dmulxw/download/releases/latest/download/web.zip"
WEB_ROOT="/var/www/${DOMAIN}/html"
mkdir -p "${WEB_ROOT}"

TMP_ZIP="/tmp/web_${DOMAIN}.zip"
echo "正在从 ${ZIP_URL} 下载最新 web.zip 到 ${TMP_ZIP} ..."
curl -fsSL "${ZIP_URL}" -o "${TMP_ZIP}" || {
    echo "⛔ 下载失败：请检查网络或 GitHub Releases URL 是否可访问。"
    exit 1
}

echo "正在解压到 ${WEB_ROOT} ..."
unzip -o "${TMP_ZIP}" -d "/var/www/${DOMAIN}/" \
    || { echo "⛔ 解压 web.zip 失败！"; exit 1; }
rm -f "${TMP_ZIP}"

# 设置网站根目录权限
if $IS_DEBIAN_FAMILY; then
    web_user="www-data"
    web_group="www-data"
else
    web_user="nginx"
    web_group="nginx"
fi
if ! id "${web_user}" &>/dev/null; then
    web_user="www-data"
    web_group="www-data"
fi

chown -R "${web_user}:${web_group}" "/var/www/${DOMAIN}/"
find "/var/www/${DOMAIN}/" -type d -exec chmod 755 {} \;
find "/var/www/${DOMAIN}/" -type f -exec chmod 644 {} \;

echo "✅ web 程序已部署到 ${WEB_ROOT}，并已设置文件权限（${web_user}:${web_group}）。"
echo

#######################################################
# 5. 安装并使用 acme.sh 申请 Let’s Encrypt SSL 证书 #
#######################################################
echo "-----------------------------"
echo "  安装 acme.sh 并申请 Let’s Encrypt 证书"
echo "-----------------------------"

SSL_DIR="/etc/ssl/${DOMAIN}"
mkdir -p "${SSL_DIR}"

if [[ ! -d "/root/.acme.sh" ]]; then
    echo "正在 Clone acme.sh 并安装到 ~/.acme.sh ..."
    git clone https://github.com/acmesh-official/acme.sh.git "/root/.acme.sh"
    cd "/root/.acme.sh"
    ./acme.sh --install --home "/root/.acme.sh" \
        --accountemail "${EMAIL}" \
        --nocron
    cd - &>/dev/null
else
    echo "检测到 /root/.acme.sh 已存在，跳过 acme.sh 安装。"
fi

export PATH="/root/.acme.sh:${PATH}"

# --- webroot 路径和 Nginx 配置一致性检测与手动测试 ---
echo "-----------------------------"
echo "  检查 .well-known/acme-challenge 路径可访问性"
echo "-----------------------------"

ACME_DIR="${WEB_ROOT}/.well-known/acme-challenge"
mkdir -p "${ACME_DIR}"

echo "DEBUG: ACME_DIR=${ACME_DIR}"
ls -ld "${ACME_DIR}"
id

# 自动生成并重载 Nginx 配置（如果不存在）
NGINX_CONF="/etc/nginx/conf.d/${DOMAIN}.conf"
if [[ ! -f "${NGINX_CONF}" ]]; then
    echo "⚠️ 未检测到 Nginx 配置文件 ${NGINX_CONF}，自动生成并重载 Nginx ..."
    cat > "${NGINX_CONF}" <<EOF
# -------------------------------------------------------------------
# Nginx 配置：${DOMAIN}
# 自动生成于 $(date +"%Y-%m-%d %H:%M:%S")
# -------------------------------------------------------------------

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN} www.${DOMAIN};
    ssl_certificate      /etc/ssl/${DOMAIN}/fullchain.pem;
    ssl_certificate_key  /etc/ssl/${DOMAIN}/privkey.pem;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    root ${WEB_ROOT};
    index index.html index.htm index.php;
    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    nginx -t && systemctl reload nginx
    echo "✅ 已自动生成并重载 Nginx 配置：${NGINX_CONF}"
fi

# 检查 Nginx 配置文件是否存在
if [[ ! -f "${NGINX_CONF}" ]]; then
    echo "⛔ Nginx 配置文件 ${NGINX_CONF} 不存在，web 目录检测无法继续。请先生成并 reload Nginx 配置。"
    exit 1
fi

# 检查 Nginx 是否已 reload 并监听 80 端口
if ! ss -ltnp | grep -q ':80'; then
    echo "⛔ Nginx 未监听 80 端口，请检查配置并确保 Nginx 已 reload。"
    nginx -t
    systemctl reload nginx
    exit 1
fi

if ! touch "${ACME_DIR}/.permtest" 2>/dev/null; then
    echo "⛔ 无法写入 ${ACME_DIR}，请检查目录权限，确保当前用户（$(id -un)）有写权限。"
    ls -ld "${ACME_DIR}"
    id
    exit 1
fi
rm -f "${ACME_DIR}/.permtest"

TEST_TOKEN="acme_test_$(date +%s)"
TEST_FILE="${ACME_DIR}/${TEST_TOKEN}"
echo "test_ok" > "${TEST_FILE}"

if [[ ! -f "${TEST_FILE}" ]]; then
    echo "⛔ 测试文件 ${TEST_FILE} 未能成功创建，请检查目录权限和磁盘空间。"
    exit 1
fi

ls -l "${TEST_FILE}"

TEST_URL="http://${DOMAIN}/.well-known/acme-challenge/${TEST_TOKEN}"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${TEST_URL}"

if [[ "${HTTP_CODE}" != "200" ]]; then
    echo "⛔ 检测失败：无法通过 HTTP 访问 ${TEST_URL}，请检查 Nginx 配置、webroot 路径和防火墙。"
    echo "建议手动访问该 URL，确认能看到 test_ok 内容。"
    rm -f "${TEST_FILE}"
    exit 1
else
    echo "✅ .well-known/acme-challenge 路径可正常访问。"
    rm -f "${TEST_FILE}"
fi
echo

echo "开始申请证书（域名：${DOMAIN}，Email：${EMAIL}）……"
~/.acme.sh/acme.sh --issue --webroot "${WEB_ROOT}" -d "${DOMAIN}" \
    --keylength ec-256 \
    --accountemail "${EMAIL}" \
    || { echo "⛔ 证书申请失败：请检查域名解析是否已生效、80 端口是否对外开放、Nginx 配置与 webroot 路径是否一致。"; exit 1; }

echo "正在将证书安装到目录：${SSL_DIR} ..."
~/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" \
    --ecc \
    --fullchain-file "${SSL_DIR}/fullchain.pem" \
    --key-file       "${SSL_DIR}/privkey.pem" \
    --reloadcmd      "systemctl reload nginx" \
    || { echo "⛔ 证书安装失败！"; exit 1; }

echo "✅ Let’s Encrypt 证书已生成并部署到 ${SSL_DIR}。"
echo

##########################################################
# 6. 生成 Nginx 配置并启用站点（80→443 重定向 + HTTPS） #
##########################################################
# 设置 NGINX_CONF_DIR 和 NGINX_CONF_D 变量（确保为绝对路径，且在所有相关代码前设置）
NGINX_CONF_DIR="/etc/nginx"
NGINX_CONF_D="${NGINX_CONF_DIR}/conf.d"

# 保证 conf.d 目录存在
if [[ ! -d "${NGINX_CONF_D}" ]]; then
    mkdir -p "${NGINX_CONF_D}"
fi

# 确保 DOMAIN 变量已赋值
if [[ -z "${DOMAIN}" ]]; then
    echo "⛔ 变量 DOMAIN 未设置，无法生成 Nginx 配置文件，请检查域名输入流程。"
    exit 1
fi

# 设置 CONF_FILE 变量（此处设置文件名，确保绝对路径）
CONF_FILE="${NGINX_CONF_D}/${DOMAIN}.conf"

# 在生成配置前输出调试信息
echo "DEBUG: NGINX_CONF_D=${NGINX_CONF_D}"
echo "DEBUG: DOMAIN=${DOMAIN}"
echo "DEBUG: CONF_FILE=${CONF_FILE}"

# 检查是否有写入权限
if ! touch "${CONF_FILE}" 2>/dev/null; then
    echo "⛔ 无法写入 ${CONF_FILE}，请确认脚本以 root 权限运行，且 ${NGINX_CONF_D} 目录存在且可写。"
    ls -ld "${NGINX_CONF_D}"
    id
    exit 1
fi

cat > "${CONF_FILE}" <<EOF
# -------------------------------------------------------------------
# Nginx 配置：${DOMAIN}
# 自动生成于 $(date +"%Y-%m-%d %H:%M:%S")
# -------------------------------------------------------------------

# 1) HTTP 监听 80，将所有请求重定向到 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    # ACME challenge
    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    return 301 https://\$host\$request_uri;
}

# 2) HTTPS 监听 443，正式站点
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN} www.${DOMAIN};

    ssl_certificate      ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key  ${SSL_DIR}/privkey.pem;

    # HSTS（仅当所有子域都已启用 HTTPS 时，可开启；否则慎用）
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    root ${WEB_ROOT};
    index index.html index.htm index.php;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

echo "✅ Nginx 虚拟主机配置已写入：${CONF_FILE}。"

echo "正在测试 Nginx 配置语法..."
nginx -t || { echo "⛔ Nginx 配置检测失败，请检查 ${CONF_FILE}。"; exit 1; }

echo "正在重载 Nginx 服务..."
if systemctl is-active nginx &>/dev/null; then
    systemctl reload nginx
else
    systemctl start nginx
fi

echo "✅ Nginx 已启动并加载新站点：${DOMAIN}"
echo

###################################################
# 7. 配置 acme.sh 续期 Crontab（每月 1 日 01:00） #
###################################################
echo "-----------------------------"
echo "  配置 acme.sh 证书续期 Crontab"
echo "-----------------------------"

CRON_JOB="0 1 1 * * root /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null 2>&1"
CRON_FILE="/etc/crontab"

# 检查 /etc/crontab 是否已存在 acme.sh 续期任务
if ! grep -q "/root/.acme.sh/acme.sh --cron" "$CRON_FILE"; then
    echo "$CRON_JOB" >> "$CRON_FILE"
    echo "✅ 已添加 acme.sh 证书续期的系统 Crontab 任务。"
else
    echo "ℹ️ 检测到系统 Crontab 已存在 acme.sh 续期任务，跳过添加。"
fi

echo "------------------------------------------------------"
echo " 安装完成！请手动检查以下内容："
echo " 1. 域名解析是否已正确指向本服务器"
echo " 2. 防火墙设置（确保 80/443 端口已放行）"
echo " 3. Nginx 日志文件（如有错误，请及时修复）"
echo " 4. SSL 证书有效性（可通过浏览器或在线工具检查）"
echo "------------------------------------------------------"
echo

# 结束
exit 0
