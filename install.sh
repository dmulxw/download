#!/usr/bin/env bash
# -*- coding: utf-8 -*-
#
# install.sh - 兼容 Ubuntu/Debian、CentOS/AlmaLinux/RHEL 等的自动安装脚本
#              扩展：
#                1. 将网站内容解压到 /var/www/${DOMAIN}/，Nginx 根目录指向该路径
#                2. 如果已有相同证书且距今不足 3 天，先使用现有证书；末尾提示是否重新生成
#                   —— 强制重新生成时使用 --force 参数
#                3. 用户重新生成证书的等待时间延长至 60 秒，并使用彩色提示
#                4. 交互式提示和关键输出使用颜色：域名/邮箱输入、网站目录、证书文件路径 等
#                5. Nginx 安装目录、配置文件名、SSL 证书名、网站所在位置 均用绿色高亮
#                6. 所有提示以中英文方式显示
#
set -e

# ANSI 颜色定义
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
CYAN='\e[36m'
RESET='\e[0m'

###########################################
# 0. 检测当前发行版类型 (Detect OS)        #
###########################################
OS_ID=""
OS_FAMILY=""

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_ID="$ID"
    OS_FAMILY="$ID_LIKE"
else
    echo -e "${RED}⛔ 找不到 /etc/os-release，无法检测发行版类型 / Cannot find /etc/os-release, cannot detect OS type${RESET}"
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
echo "  检测到发行版信息 / Detected OS Info："
echo "   ID=${OS_ID}"
echo "   ID_LIKE=${OS_FAMILY}"
if $IS_DEBIAN_FAMILY; then
    echo "   → 归为：Debian/Ubuntu 系列 / Classified as: Debian/Ubuntu family"
elif $IS_RHEL_FAMILY; then
    echo "   → 归为：RHEL/CentOS/AlmaLinux 系列 / Classified as: RHEL/CentOS/AlmaLinux family"
else
    echo -e "   → 未知发行版系列，本脚本仅支持 Debian/Ubuntu 与 RHEL/CentOS/AlmaLinux / Unknown OS family, script supports only Debian/Ubuntu or RHEL/CentOS/AlmaLinux"
    exit 1
fi
echo "######################################################"
echo

###########################################
# 1. 交互式获取“域名” (Input Domain)        #
###########################################
get_domain() {
    MAX_TRIES=3
    DOMAIN=""
    exec 3<&0
    exec < /dev/tty
    for ((i=1; i<=MAX_TRIES; i++)); do
        printf "${CYAN}请输入要绑定的域名 (Enter the domain name) – 第 ${i} 次 / attempt ${i} of ${MAX_TRIES}:${RESET} "
        read input_domain
        if [[ -n "$input_domain" && "$input_domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
            DOMAIN="$input_domain"
            echo -e "${GREEN}✅ 已确认域名 / Domain confirmed: ${DOMAIN}${RESET}"
            echo
            break
        else
            echo -e "${RED}❌ 域名格式不合法，请重新输入 Domain format invalid, please re-enter${RESET}"
        fi
        if [[ $i -eq $MAX_TRIES ]]; then
            echo -e "${RED}⛔ 三次输入均不合法，安装程序退出 / Three invalid attempts, exiting installer${RESET}"
            exec 0<&3
            exit 1
        fi
    done
    exec 0<&3
}

###########################################
# 2. 交互式获取“Email”地址 (Input Email)     #
###########################################
get_email() {
    MAX_TRIES=3
    EMAIL=""
    exec 3<&0
    exec < /dev/tty
    for ((i=1; i<=MAX_TRIES; i++)); do
        printf "${CYAN}请输入用于申请 SSL 证书的 Email (Enter email for SSL certificate) – 第 ${i} 次 / attempt ${i} of ${MAX_TRIES}:${RESET} "
        read input_email
        if [[ -n "$input_email" && "$input_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            EMAIL="$input_email"
            echo -e "${GREEN}✅ 已确认 Email / Email confirmed: ${EMAIL}${RESET}"
            echo
            break
        else
            echo -e "${RED}❌ Email 格式不合法，请重新输入 Email format invalid, please re-enter${RESET}"
        fi
        if [[ $i -eq $MAX_TRIES ]]; then
            echo -e "${RED}⛔ 三次输入均不合法，安装程序退出 / Three invalid attempts, exiting installer${RESET}"
            exec 0<&3
            exit 1
        fi
    done
    exec 0<&3
}

get_domain
get_email

##############################################
# 3. 检查是否为 root，并安装所需依赖(Install Dependencies) #
##############################################
echo "######################################################"
echo "  开始检查并安装必要软件包 / Checking & Installing dependencies"
echo "######################################################"

if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}⛔ 请使用 root 用户或 sudo 运行脚本 / Please run as root or via sudo${RESET}"
    exit 1
fi

NGINX_EXIST=false
if command -v nginx &>/dev/null; then
    NGINX_EXIST=true
    echo -e "${YELLOW}ℹ️ 检测到已安装 Nginx，将仅新增站点 / Nginx already installed, will only add site${RESET}"
else
    echo -e "${YELLOW}ℹ️ 未检测到 Nginx，后续将安装 Nginx / Nginx not found, will install${RESET}"
fi

install_deps_debian() {
    echo ">>> Debian/Ubuntu 系列：安装或更新依赖 / Installing/updating dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    if ! $NGINX_EXIST; then
        apt-get install -y nginx
        echo -e "${GREEN}✅ Nginx 已安装 (Nginx installed at ${GREEN}/etc/nginx/${RESET})${RESET}"
    fi
    apt-get install -y curl unzip git socat cron
    systemctl enable nginx
    systemctl start nginx
    systemctl enable cron
    systemctl start cron
}

install_deps_rhel() {
    echo ">>> RHEL/CentOS/AlmaLinux 系列：安装或更新依赖 / Installing/updating dependencies..."
    if command -v dnf &>/dev/null; then
        pkg_manager="dnf"
    else
        pkg_manager="yum"
    fi
    echo "安装 EPEL 源 (Installing EPEL repository)..."
    if [[ "$pkg_manager" == "dnf" ]]; then
        dnf install -y epel-release
        dnf makecache
    else
        yum install -y epel-release
        yum makecache
    fi
    if ! $NGINX_EXIST; then
        if [[ "$pkg_manager" == "dnf" ]]; then
            dnf install -y nginx
        else
            yum install -y nginx
        fi
        echo -e "${GREEN}✅ Nginx 已安装 (Nginx installed at ${GREEN}/etc/nginx/${RESET})${RESET}"
    fi
    if [[ "$pkg_manager" == "dnf" ]]; then
        dnf install -y curl unzip git socat cronie
    else
        yum install -y curl unzip git socat cronie
    fi
    systemctl enable nginx
    systemctl start nginx
    systemctl enable crond
    systemctl start crond
}

if $IS_DEBIAN_FAMILY; then
    install_deps_debian
elif $IS_RHEL_FAMILY; then
    install_deps_rhel
else
    echo -e "${RED}⛔ 未知系统系列，无法自动安装依赖 / Unknown OS family, cannot install dependencies${RESET}"
    exit 1
fi

if ! command -v nginx &>/dev/null; then
    echo -e "${RED}⛔ Nginx 安装或启动失败，请检查 / Nginx installation or startup failed, please check${RESET}"
    exit 1
fi

echo -e "${GREEN}✅ 依赖安装与基础服务启动完成 / Dependencies installed and basic services started${RESET}"
echo

#############################################
# 4. 检查并放行 80/443 端口 (Open Firewall)    #
#############################################
echo "######################################################"
echo "  检查并放行 80/443 端口 / Checking & opening ports 80/443"
echo "######################################################"

open_ports() {
    if command -v ufw &>/dev/null; then
        if ufw status | grep -qw active; then
            echo "检测到 ufw，正在放行 80/443 端口 / UFW detected, allowing 80/443..."
            ufw allow 80/tcp || true
            ufw allow 443/tcp || true
            ufw reload || true
        fi
    fi
    if command -v firewall-cmd &>/dev/null; then
        if systemctl is-active firewalld &>/dev/null; then
            echo "检测到 firewalld，正在放行 80/443 端口 / firewalld detected, allowing 80/443..."
            firewall-cmd --permanent --add-service=http || true
            firewall-cmd --permanent --add-service=https || true
            firewall-cmd --reload || true
        fi
    fi
    if ! command -v ufw &>/dev/null && ! command -v firewall-cmd &>/dev/null; then
        if command -v iptables &>/dev/null; then
            echo "检测到 iptables，正在放行 80/443 端口 / iptables detected, allowing 80/443..."
            iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
            iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save
            elif command -v service &>/dev/null && service iptables save &>/dev/null; then
                service iptables save
            fi
        fi
    fi
}

open_ports

echo -e "${GREEN}✅ 防火墙端口检查并放行完成 / Firewall port check and opening completed${RESET}"
echo

####################################
# 5. 下载并解压 最新 web.zip (Deploy Site) #
####################################
echo "######################################################"
echo "  下载并部署最新版本 web.zip / Downloading & deploying latest web.zip"
echo "######################################################"

ZIP_URL="https://github.com/dmulxw/download/releases/latest/download/web.zip"
WEB_ROOT="/var/www/${DOMAIN}"
mkdir -p "${WEB_ROOT}"

TMP_ZIP="/tmp/web_${DOMAIN}.zip"
echo -e "${CYAN}正在从 ${ZIP_URL} 下载最新 web.zip 到 ${TMP_ZIP} / Downloading web.zip to ${TMP_ZIP}...${RESET}"
curl -fsSL "${ZIP_URL}" -o "${TMP_ZIP}" || {
    echo -e "${RED}⛔ 下载失败：请检查网络或 URL / Download failed: please check network or URL${RESET}"
    exit 1
}

echo -e "${CYAN}正在解压到 ${GREEN}${WEB_ROOT}${RESET} / Extracting to ${WEB_ROOT}...${RESET}"
unzip -o "${TMP_ZIP}" -d "${WEB_ROOT}" \
    || { echo -e "${RED}⛔ 解压失败 / Extraction failed!${RESET}"; exit 1; }
rm -f "${TMP_ZIP}"

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

chown -R "${web_user}:${web_group}" "${WEB_ROOT}"
find "${WEB_ROOT}" -type d -exec chmod 755 {} \;
find "${WEB_ROOT}" -type f -exec chmod 644 {} \;

echo -e "${GREEN}✅ 网站已部署至 / Website deployed at ${GREEN}${WEB_ROOT}${RESET} 并已设置文件权限 / and permissions set.${RESET}"
echo

##############################################
# 6. 安装并配置 acme.sh 申请 SSL 证书 (SSL)  #
##############################################
echo "######################################################"
echo "  安装并配置 acme.sh 申请 SSL 证书 / Installing & configuring acme.sh for SSL"
echo "######################################################"

ACME_INSTALL_DIR="/root/.acme.sh"
if [ -d "$ACME_INSTALL_DIR" ]; then
    echo -e "${YELLOW}ℹ️ 检测到 acme.sh 已安装 / acme.sh already installed, skipping installation.${RESET}"
else
    echo -e "${CYAN}正在安装 acme.sh / Installing acme.sh...${RESET}"
    curl https://get.acme.sh | sh
    echo -e "${GREEN}✅ acme.sh 安装完成 / acme.sh installation completed.${RESET}"
fi

ACME_BIN="/root/.acme.sh/acme.sh"
if [ ! -f "$ACME_BIN" ]; then
    echo -e "${RED}⛔ 未找到 acme.sh 可执行文件 / acme.sh executable not found${RESET}"
    exit 1
fi

# 检测现有证书及其生成时间 (Check existing certificate age)
CERT_DIR="${ACME_INSTALL_DIR}/${DOMAIN}_ecc"
EXIST_CRT="${CERT_DIR}/fullchain.cer"
USE_EXISTING_CERT=false
CERT_MTIME=0
CERT_AGE_DAYS=0

if [ -f "$EXIST_CRT" ]; then
    crt_mtime=$(stat -c %Y "$EXIST_CRT")
    now_ts=$(date +%s)
    diff_sec=$(( now_ts - crt_mtime ))
    CERT_AGE_DAYS=$(( diff_sec / 86400 ))
    CERT_MTIME="$crt_mtime"
    if [ "$CERT_AGE_DAYS" -lt 3 ]; then
        USE_EXISTING_CERT=true
        echo -e "${YELLOW}ℹ️ 检测到证书已于 $(date -d @"$crt_mtime" +"%Y-%m-%d") 生成，距今仅 ${CERT_AGE_DAYS} 天 / Certificate generated on $(date -d @"$crt_mtime" +"%Y-%m-%d"), only ${CERT_AGE_DAYS} days ago.${RESET}"
    fi
fi

# 如果没有现有“足够新”证书，则生成新证书 (Issue new certificate if none recent)
if ! $USE_EXISTING_CERT; then
    echo "######################################################"
    echo "  生成临时 Nginx 配置：仅监听 80 并支持 ACME challenge / Creating temporary Nginx config for ACME challenge"
    echo "######################################################"

    NGINX_CONF_D="/etc/nginx/conf.d"
    TEMP_CONF="${NGINX_CONF_D}/${DOMAIN}.conf"
    mkdir -p "${NGINX_CONF_D}"

    cat > "${TEMP_CONF}" <<EOF
# 临时配置，仅监听 80 供 acme.sh 进行 HTTP 验证 / Temporary config listens on 80 for acme.sh HTTP validation
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF

    echo -e "${GREEN}✅ 临时 Nginx 配置已写入 (Temporary config written to) ${GREEN}${TEMP_CONF}${RESET}"
    echo -e "${CYAN}正在测试 Nginx 配置语法 / Testing Nginx config syntax...${RESET}"
    nginx -t || { echo -e "${RED}⛔ 临时 Nginx 配置检测失败 / Temporary Nginx config test failed at ${TEMP_CONF}${RESET}"; exit 1; }

    echo -e "${CYAN}正在重载 Nginx 服务 / Reloading Nginx...${RESET}"
    systemctl reload nginx

    echo -e "${GREEN}✅ 临时 Nginx 已启动 (Temporary Nginx running) - 80 端口 / port 80.${RESET}"
    echo

    echo "######################################################"
    echo "  检查 .well-known/acme-challenge 路径可访问性 / Checking .well-known/acme-challenge accessibility"
    echo "######################################################"

    ACME_DIR="${WEB_ROOT}/.well-known/acme-challenge"
    mkdir -p "${ACME_DIR}"

    if ! touch "${ACME_DIR}/.permtest" 2>/dev/null; then
        echo -e "${RED}⛔ 无法写入 ${ACME_DIR}，请检查权限 / Cannot write to ${ACME_DIR}, check permissions.${RESET}"
        exit 1
    fi
    rm -f "${ACME_DIR}/.permtest"

    TEST_TOKEN="acme_test_$(date +%s)"
    TEST_FILE="${ACME_DIR}/${TEST_TOKEN}"
    echo "test_ok" > "${TEST_FILE}"
    chmod 644 "${TEST_FILE}"

    if ! ss -ltnp | grep -q ':80'; then
        echo -e "${RED}⛔ Nginx 未监听 80 端口 / Nginx not listening on port 80${RESET}"
        nginx -t
        systemctl reload nginx
        exit 1
    fi

    TEST_URL="http://${DOMAIN}/.well-known/acme-challenge/${TEST_TOKEN}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TEST_URL")

    if [[ "$HTTP_CODE" != "200" ]]; then
        echo -e "${RED}⛔ 测试失败：无法通过 HTTP 访问 ${TEST_URL}（状态 ${HTTP_CODE}）/ Test failed: cannot access ${TEST_URL} (status ${HTTP_CODE})${RESET}"
        rm -f "${TEST_FILE}"
        exit 1
    else
        echo -e "${GREEN}✅ .well-known/acme-challenge 可正常访问 / .well-known/acme-challenge is accessible.${RESET}"
        rm -f "${TEST_FILE}"
    fi
    echo

    echo -e "${CYAN}开始申请 Let’s Encrypt 证书 (Issuing Let’s Encrypt certificate for) ${CYAN}${DOMAIN}${RESET} ..."

    SSL_DIR="/etc/nginx/ssl/${DOMAIN}"
    mkdir -p "${SSL_DIR}"

    "$ACME_BIN" --issue --webroot "${WEB_ROOT}" -d "${DOMAIN}" -d "www.${DOMAIN}" \
        --keylength ec-256 \
        --accountemail "${EMAIL}" \
        || { echo -e "${RED}⛔ 证书申请失败：请检查域名解析、80 端口、防火墙、Nginx 配置 / Certificate issuance failed: check DNS, port 80, firewall, Nginx config.${RESET}"; exit 1; }

    echo -e "${CYAN}正在将证书安装到 (Installing certificate to) ${GREEN}${SSL_DIR}${RESET} ...${RESET}"
    "$ACME_BIN" --install-cert -d "${DOMAIN}" \
        --key-file   "${SSL_DIR}/${DOMAIN}.key" \
        --fullchain-file "${SSL_DIR}/${DOMAIN}.cer" \
        --reloadcmd  "systemctl reload nginx" \
        || { echo -e "${RED}⛔ 证书安装失败 / Certificate installation failed!${RESET}"; exit 1; }

    echo -e "${GREEN}✅ Let’s Encrypt 证书已生成并部署到 / Certificate deployed at ${GREEN}${SSL_DIR}${RESET}${RESET}"
    echo
else
    echo -e "${YELLOW}ℹ️ 使用已有证书，无需重新申请 / Using existing certificate, no need to issue new one.${RESET}"
    SSL_DIR="/etc/nginx/ssl/${DOMAIN}"
fi

##############################################
# 7. 生成 Nginx 正式配置并启用站点 (Deploy Site)#
##############################################
echo "######################################################"
echo "  生成 Nginx 正式配置并启用站点 / Creating final Nginx config and enabling site"
echo "######################################################"

NGINX_CONF_AVAILABLE="/etc/nginx/sites-available"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled"
mkdir -p "${NGINX_CONF_AVAILABLE}" "${NGINX_CONF_ENABLED}"
NGINX_CONF_FILE="${NGINX_CONF_AVAILABLE}/${DOMAIN}.conf"

# 输出 Nginx 配置文件路径为绿色提示
echo -e "${CYAN}正在写入 Nginx 配置文件 (Writing Nginx config to): ${GREEN}${NGINX_CONF_FILE}${RESET} ..."
cat > "${NGINX_CONF_FILE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN} www.${DOMAIN};

    ssl_certificate     /etc/nginx/ssl/${DOMAIN}/${DOMAIN}.cer;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}/${DOMAIN}.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    root /var/www/${DOMAIN};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/${DOMAIN};
        default_type "text/plain";
        try_files \$uri =404;
    }
}
EOF
echo -e "${GREEN}✅ Nginx 配置文件已写入 / Nginx config written: ${GREEN}${NGINX_CONF_FILE}${RESET}"

# 启用站点配置
if [ -L "${NGINX_CONF_ENABLED}/${DOMAIN}.conf" ]; then
    echo -e "${YELLOW}ℹ️ 站点配置软链接已存在，先移除旧链接 / Symlink exists, removing old link${RESET}"
    rm -f "${NGINX_CONF_ENABLED}/${DOMAIN}.conf"
fi
ln -s "${NGINX_CONF_FILE}" "${NGINX_CONF_ENABLED}/${DOMAIN}.conf"
echo -e "${GREEN}✅ 站点配置已启用 / Site enabled via symlink: ${GREEN}${NGINX_CONF_ENABLED}/${DOMAIN}.conf${RESET}"

echo -e "${CYAN}正在测试 Nginx 配置 / Testing Nginx config...${RESET}"
if nginx -t; then
    echo -e "${CYAN}Nginx 配置测试通过 / Nginx config OK, reloading...${RESET}"
    systemctl reload nginx
    echo -e "${GREEN}✅ Nginx 服务已重载 / Nginx reloaded.${RESET}"
else
    echo -e "${RED}⛔ Nginx 配置测试失败 / Nginx config test failed, please check syntax.${RESET}"
    exit 1
fi

echo

##############################################
# 8. 安装并配置 cron 任务自动续期证书 (Cron)   #
##############################################
echo "######################################################"
echo "  安装并配置 cron 任务自动续期证书 / Adding cron job for certificate auto-renewal"
echo "######################################################"

CRON_JOB="0 1 1 * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null 2>&1"
if grep -q "/root/.acme.sh/acme.sh --cron" /etc/crontab; then
    echo -e "${YELLOW}ℹ️ Crontab 已存在 acme.sh 续期任务 / Cronjob exists, skipping addition${RESET}"
else
    echo "${CRON_JOB}" >> /etc/crontab
    echo -e "${GREEN}✅ 已添加证书续期 Crontab 任务 / Cronjob added for certificate renewal${RESET}"
fi

echo

##############################################
# 9. 重新生成证书提示 (Optional Renew Prompt) #
##############################################
if $USE_EXISTING_CERT; then
    echo "######################################################"
    echo -e "${YELLOW}  检测到已有证书距今不足 3 天 / Existing certificate is less than 3 days old{RESET}"
    echo -e "${YELLOW}  旧证书生成日期 / Certificate date: $(date -d @"$CERT_MTIME" +'%Y-%m-%d')，已过去 ${CERT_AGE_DAYS} 天 / ${CERT_AGE_DAYS} days old${RESET}"
    echo -e "${CYAN}  若要强制重新生成，请在 60 秒内输入 ${GREEN}Y${CYAN} / Press Y within 60s to force renewal, otherwise skip.${RESET}"
    exec 3<&0
    exec < /dev/tty
    if read -t 60 -rn1 yn; then
        echo
        if [[ "$yn" =~ [Yy] ]]; then
            echo -e "${GREEN}✅ 用户选择强制重新生成证书，开始执行 / Forcing certificate renewal...${RESET}"
            echo "######################################################"
            echo -e "${CYAN}  再次申请证书 / Re-issuing certificate for ${DOMAIN}...${RESET}"
            "$ACME_BIN" --issue --force --webroot "${WEB_ROOT}" -d "${DOMAIN}" -d "www.${DOMAIN}" \
                --keylength ec-256 \
                --accountemail "${EMAIL}" \
                || { echo -e "${RED}⛔ 证书申请失败 / Certificate issuance failed!${RESET}"; exit 1; }

            echo -e "${CYAN}正在将新证书安装到 / Installing new certificate to ${GREEN}${SSL_DIR}${RESET} ...${RESET}"
            "$ACME_BIN" --install-cert -d "${DOMAIN}" \
                --key-file   "${SSL_DIR}/${DOMAIN}.key" \
                --fullchain-file "${SSL_DIR}/${DOMAIN}.cer" \
                --reloadcmd  "systemctl reload nginx" \
                --force \
                || { echo -e "${RED}⛔ 新证书安装失败 / New certificate installation failed!${RESET}"; exit 1; }

            echo -e "${GREEN}✅ 新证书已部署 / New certificate deployed at ${GREEN}${SSL_DIR}${RESET}${RESET}"
            echo -e "${GREEN}✅ 强制重新生成并重载 Nginx 完成 / Forced renewal and Nginx reload complete.${RESET}"
        else
            echo -e "${YELLOW}ℹ️ 跳过强制重新生成，保留现有证书 / Skipping forced renewal, keeping existing certificate.${RESET}"
        fi
    else
        echo
        echo -e "${YELLOW}ℹ️ 60 秒超时，跳过重新生成 / Timeout, skipping renewal.${RESET}"
    fi
    exec 0<&3
fi

echo

##############################################
# 10. 提示用户检查防火墙 (Final Reminder)      #
##############################################
echo "######################################################"
echo "  安装完成！请检查防火墙设置 / Installation complete! Please verify firewall settings"
echo "######################################################"

if command -v ufw &>/dev/null; then
    if ufw status | grep -qw active; then
        echo -e "${GREEN}✅ UFW 防火墙已启用，80/443 端口已放行 / UFW active, ports 80/443 allowed.${RESET}"
    else
        echo -e "${YELLOW}⚠️ UFW 已安装但未启用，请手动启用 / UFW installed but not active, please enable manually.${RESET}"
    fi
fi

if command -v firewall-cmd &>/dev/null; then
    if systemctl is-active firewalld &>/dev/null; then
        echo -e "${GREEN}✅ firewalld 已启用，80/443 端口已放行 / firewalld active, ports 80/443 allowed.${RESET}"
    else
        echo -e "${YELLOW}⚠️ firewalld 已安装但未启用，请手动启用 / firewalld installed but not active, please enable manually.${RESET}"
    fi
fi

if command -v iptables &>/dev/null; then
    iptables -L -n | grep -E "tcp dpt:80|tcp dpt:443" &>/dev/null
    if [ "$?" -eq 0 ]; then
        echo -e "${GREEN}✅ iptables 已放行 80/443 端口 / iptables allows ports 80/443.${RESET}"
    else
        echo -e "${YELLOW}⚠️ iptables 未放行 80/443 端口，请检查 / iptables not allowing ports 80/443, please check${RESET}"
    fi
fi

echo
echo -e "${GREEN}🎉 所有步骤已完成！请访问 https://${DOMAIN} 检查站点是否正常 / All done! Visit https://${DOMAIN} to verify.${RESET}"
echo -e "📅 请定期检查 SSL 证书有效期 / Remember to periodically check SSL certificate validity."
echo -e "如需帮助，请查阅相关文档或联系支持 / For help, consult documentation or contact support."
echo "######################################################"
echo

exit 0
