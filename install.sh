```bash
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

# 调用交互函数
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

###########################################################
# 6. 生成临时 Nginx 配置，仅用于 ACME challenge（80） #
###########################################################
echo "-----------------------------"
echo "  生成临时 Nginx 配置：仅监听 80 并支持 ACME challenge"
echo "-----------------------------"

NGINX_CONF_D="/etc/nginx/conf.d"
TEMP_CONF="${NGINX_CONF_D}/${DOMAIN}.conf"

# 确保 conf.d 目录存在
if [[ ! -d "${NGINX_CONF_D}" ]]; then
    mkdir -p "${NGINX_CONF_D}"
fi

# 写入临时配置（仅允许 challenge 路径，其他一律 404）
cat > "${TEMP_CONF}" <<EOF
# 临时配置：仅监听 80，供 acme.sh 进行 HTTP 验证
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    # 其余请求返回 404 （可避免干扰）
    location / {
        return 404;
    }
}
EOF

echo "✅ 临时配置已写入：${TEMP_CONF}"
echo "正在测试 Nginx 配置语法..."
nginx -t || { echo "⛔ 临时 Nginx 配置检测失败，请检查 ${TEMP_CONF}。"; exit 1; }

echo "正在重载 Nginx 服务..."
systemctl reload nginx

echo "✅ 临时 Nginx 已启动（80 端口监听 ACME challenge）。"
echo

#############################################
# 7. 检查 challenge 路径可访问性并申请证书 #
#############################################
echo "-----------------------------"
echo "  检查 .well-known/acme-challenge 路径可访问性"
echo "-----------------------------"

ACME_DIR="${WEB_ROOT}/.well-known/acme-challenge"
mkdir -p "${ACME_DIR}"

# 权限校验
if ! touch "${ACME_DIR}/.permtest" 2>/dev/null; then
    echo "⛔ 无法写入 ${ACME_DIR}，请检查目录权限，确保 Nginx 运行用户有写权限。"
    ls -ld "${ACME_DIR}"
    id
    exit 1
fi
rm -f "${ACME_DIR}/.permtest"

# 写入测试文件并验证 HTTP 可访问
TEST_TOKEN="acme_test_$(date +%s)"
TEST_FILE="${ACME_DIR}/${TEST_TOKEN}"
echo "test_ok" > "${TEST_FILE}"
chmod 644 "${TEST_FILE}"

# 确保 Nginx 已监听 80
if ! ss -ltnp | grep -q ':80'; then
    echo "⛔ Nginx 未监听 80 端口，请检查并确保 Nginx 已 reload。"
    nginx -t
    systemctl reload nginx
    exit 1
fi

# 访问测试
TEST_URL="http://${DOMAIN}/.well-known/acme-challenge/${TEST_TOKEN}"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TEST_URL")

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "⛔ 检测失败：无法通过 HTTP 访问 $TEST_URL （状态码 $HTTP_CODE），请检查 Nginx 配置与防火墙。"
    rm -f "${TEST_FILE}"
    exit 1
else
    echo "✅ .well-known/acme-challenge 路径可正常访问。"
    rm -f "${TEST_FILE}"
fi
echo

echo "开始申请 Let’s Encrypt 证书（域名：${DOMAIN}，Email：${EMAIL}）……"

SSL_DIR="/etc/ssl/${DOMAIN}"
mkdir -p "${SSL_DIR}"

# 安装 acme.sh（如未安装）
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

~/.acme.sh/acme.sh --issue --webroot "${WEB_ROOT}" -d "${DOMAIN}" \
    --keylength ec-256 \
    --accountemail "${EMAIL}" \
    || { echo "⛔ 证书申请失败：请检查域名解析是否已生效、80 端口是否对外开放、Nginx challenge 配置是否生效。"; exit 1; }

echo "正在将证书安装到目录：${SSL_DIR} ..."
~/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" \
    --ecc \
    --fullchain-file "${SSL_DIR}/fullchain.pem" \
    --key-file       "${SSL_DIR}/privkey.pem" \
    --reloadcmd      "systemctl reload nginx" \
    || { echo "⛔ 证书安装失败！"; exit 1; }

echo "✅ Let’s Encrypt 证书已生成并部署到 ${SSL_DIR}。"
echo

#################################################
# 8. 生成正式 Nginx 配置并启用站点（80→443）  #
#################################################
echo "-----------------------------"
echo "  生成正式 Nginx 配置（HTTP→HTTPS + HTTPS）"
echo "-----------------------------"

# 重写同一文件：/etc/nginx/conf.d/${DOMAIN}.conf
cat > "${TEMP_CONF}" <<EOF
# 正式配置：监听 80 重定向到 HTTPS；443 提供 HTTPS 服务
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    # 仅让 .well-known/acme-challenge/ 可访问，其他请求重定向
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

    ssl_certificate      ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key  ${SSL_DIR}/privkey.pem;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    root ${WEB_ROOT};
    index index.html index.htm index.php;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }
}
EOF

echo "✅ 正式配置已写入：${TEMP_CONF}"

echo "正在测试 Nginx 配置语法..."
nginx -t || { echo "⛔ 正式 Nginx 配置检测失败，请检查 ${TEMP_CONF}。"; exit 1; }

echo "正在重载 Nginx 服务..."
systemctl reload nginx

echo "✅ Nginx 已启动并加载新站点：${DOMAIN}"
echo

###################################################
# 9. 配置 acme.sh 续期 Crontab（每月 1 日 01:00） #
###################################################
echo "-----------------------------"
echo "  配置 acme.sh 证书续期 Crontab"
echo "-----------------------------"

CRON_JOB="0 1 1 * * root /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null 2>&1"
CRON_FILE="/etc/crontab"

# 如果 /etc/crontab 中不存在，则追加
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

exit 0
```
