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
#
set -e

# ANSI 颜色定义
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
CYAN='\e[36m'
BLUE='\e[34m'
RESET='\e[0m'

###########################################
# 0. 检测当前发行版类型                    #
###########################################
OS_ID=""
OS_FAMILY=""

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_ID="$ID"
    OS_FAMILY="$ID_LIKE"
else
    echo -e "${RED}⛔ 找不到 /etc/os-release，无法检测发行版类型，请手动确认系统类型后再运行脚本。${RESET}"
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
echo "  检测到发行版信息："
echo "   ID=${OS_ID}"
echo "   ID_LIKE=${OS_FAMILY}"
if $IS_DEBIAN_FAMILY; then
    echo "   → 归为：Debian/Ubuntu 系列"
elif $IS_RHEL_FAMILY; then
    echo "   → 归为：RHEL/CentOS/AlmaLinux/Rocky 系列"
else
    echo -e "   → 未知发行版系列，本脚本仅支持 Debian/Ubuntu 与 RHEL/CentOS/AlmaLinux"
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
    exec 3<&0
    exec < /dev/tty
    for ((i=1; i<=MAX_TRIES; i++)); do
        # 使用 printf 输出彩色提示，避免 read -rp 无法正确解析转义
        printf "${CYAN}请输入要绑定的域名(Your Domain):${RESET} "
        read input_domain
        if [[ -n "$input_domain" && "$input_domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
            DOMAIN="$input_domain"
            echo -e "${GREEN}✅ 已确认域名：${DOMAIN}${RESET}"
            echo
            break
        else
            echo -e "${RED}❌ 域名格式不合法，请重新输入（只能包含字母/数字/点/横杠）。${RESET}"
        fi
        if [[ $i -eq $MAX_TRIES ]]; then
            echo -e "${RED}⛔ 3 次输入均不合法，安装程序退出。${RESET}"
            exec 0<&3
            exit 1
        fi
    done
    exec 0<&3
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
        printf "${CYAN}请输入用于申请 SSL 证书的 Email$：{RESET} "
        read input_email
        if [[ -n "$input_email" && "$input_email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            EMAIL="$input_email"
            echo -e "${GREEN}✅ 已确认 Email：${EMAIL}${RESET}"
            echo
            break
        else
            echo -e "${RED}❌ Email 格式不合法，请重新输入。${RESET}"
        fi
        if [[ $i -eq $MAX_TRIES ]]; then
            echo -e "${RED}⛔ 3 次输入均不合法，安装程序退出。${RESET}"
            exec 0<&3
            exit 1
        fi
    done
    exec 0<&3
}

get_domain
get_email

##############################################
# 3. 检查是否为 root，并安装所需依赖（分发） #
##############################################
echo "######################################################"
echo "  开始检查并安装必要软件包"
echo "######################################################"

if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}⛔ 请使用 root 用户或通过 sudo 运行本脚本！${RESET}"
    exit 1
fi

NGINX_EXIST=false
if command -v nginx &>/dev/null; then
    NGINX_EXIST=true
    echo -e "${YELLOW}ℹ️ 检测到系统已安装 Nginx，将仅新增站点，不重新安装 Nginx。${RESET}"
else
    echo -e "${YELLOW}ℹ️ 系统未检测到 Nginx，后续将先安装 Nginx。${RESET}"
fi

install_deps_debian() {
    echo ">>> Debian/Ubuntu 系列：安装或更新依赖 ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    if ! $NGINX_EXIST; then
        apt-get install -y nginx
        echo -e "${GREEN}✅ 已安装 Nginx。${RESET}"
    fi
    apt-get install -y curl unzip git socat cron
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
    if ! $NGINX_EXIST; then
        if [[ "$pkg_manager" == "dnf" ]]; then
            dnf install -y nginx
        else
            yum install -y nginx
        fi
        echo -e "${GREEN}✅ 已安装 Nginx。${RESET}"
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
    echo -e "${RED}⛔ 未知系统系列，无法自动安装依赖。${RESET}"
    exit 1
fi

if ! command -v nginx &>/dev/null; then
    echo -e "${RED}⛔ Nginx 安装或启动失败，请检查网络或包源配置。${RESET}"
    exit 1
fi

echo -e "${GREEN}✅ 依赖安装与基础服务启动完成。${RESET}"
echo

#############################################
# 4. 检查并放行 80/443 端口（支持防火墙）   #
#############################################
echo "######################################################"
echo "  检查并放行 80/443 端口"
echo "######################################################"

open_ports() {
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
    if ! command -v ufw &>/dev/null && ! command -v firewall-cmd &>/dev/null; then
        if command -v iptables &>/dev/null; then
            echo "检测到 iptables，正在放行 80/443 端口..."
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

echo -e "${GREEN}✅ 已尝试自动放行 80/443 端口，请手动确认防火墙规则。${RESET}"
echo

####################################
# 5. 下载并解压 最新 web.zip       #
####################################
echo "######################################################"
echo "  下载并部署最新版本 web.zip"
echo "######################################################"

ZIP_URL="https://github.com/dmulxw/download/releases/latest/download/web.zip"
WEB_ROOT="/var/www/${DOMAIN}"
mkdir -p "${WEB_ROOT}"

TMP_ZIP="/tmp/web_${DOMAIN}.zip"
echo -e "${CYAN}正在从 ${ZIP_URL} 下载最新 web.zip 到 ${TMP_ZIP} ...${RESET}"
curl -fsSL "${ZIP_URL}" -o "${TMP_ZIP}" || {
    echo -e "${RED}⛔ 下载失败：请检查网络或 GitHub Releases URL 是否可访问。${RESET}"
    exit 1
}

echo -e "${CYAN}正在解压到 ${BLUE}${WEB_ROOT}${RESET} ...${RESET}"
unzip -o "${TMP_ZIP}" -d "${WEB_ROOT}" \
    || { echo -e "${RED}⛔ 解压 web.zip 失败！${RESET}"; exit 1; }
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

echo -e "${GREEN}✅ web 程序已部署到 ${BLUE}${WEB_ROOT}${RESET}，并已设置文件权限（${web_user}:${web_group}）。${RESET}"
echo

##############################################
# 6. 安装并配置 acme.sh 申请 SSL 证书      #
##############################################
echo "######################################################"
echo "  安装并配置 acme.sh 申请 SSL 证书"
echo "######################################################"

ACME_INSTALL_DIR="/root/.acme.sh"
if [ -d "$ACME_INSTALL_DIR" ]; then
    echo -e "${YELLOW}ℹ️ 检测到 acme.sh 已安装，将跳过安装步骤。${RESET}"
else
    echo -e "${CYAN}正在安装 acme.sh ...${RESET}"
    curl https://get.acme.sh | sh
    echo -e "${GREEN}✅ acme.sh 安装完成。${RESET}"
fi

ACME_BIN="/root/.acme.sh/acme.sh"
if [ ! -f "$ACME_BIN" ]; then
    echo -e "${RED}⛔ 未找到 acme.sh 可执行文件，请检查安装是否成功。${RESET}"
    exit 1
fi

# 检测现有证书及其生成时间
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
        echo -e "${YELLOW}ℹ️ 检测到 ${DOMAIN} 的证书在 $(date -d @"$crt_mtime" +"%Y-%m-%d") 生成，距今仅 ${CERT_AGE_DAYS} 天，将先使用现有证书配置。${RESET}"
    fi
fi

# 如果没有现有“足够新”证书，则生成新证书
if ! $USE_EXISTING_CERT; then
    echo "######################################################"
    echo "  生成临时 Nginx 配置：仅监听 80 并支持 ACME challenge"
    echo "######################################################"

    NGINX_CONF_D="/etc/nginx/conf.d"
    TEMP_CONF="${NGINX_CONF_D}/${DOMAIN}.conf"
    mkdir -p "${NGINX_CONF_D}"

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

    location / {
        return 404;
    }
}
EOF

    echo -e "${GREEN}✅ 临时配置已写入：${BLUE}${TEMP_CONF}${RESET}"
    echo -e "${CYAN}正在测试 Nginx 配置语法...${RESET}"
    nginx -t || { echo -e "${RED}⛔ 临时 Nginx 配置检测失败，请检查 ${TEMP_CONF}。${RESET}"; exit 1; }

    echo -e "${CYAN}正在重载 Nginx 服务...${RESET}"
    systemctl reload nginx

    echo -e "${GREEN}✅ 临时 Nginx 已启动（80 端口监听 ACME challenge）。${RESET}"
    echo

    echo "######################################################"
    echo "  检查 .well-known/acme-challenge 路径可访问性"
    echo "######################################################"

    ACME_DIR="${WEB_ROOT}/.well-known/acme-challenge"
    mkdir -p "${ACME_DIR}"

    if ! touch "${ACME_DIR}/.permtest" 2>/dev/null; then
        echo -e "${RED}⛔ 无法写入 ${ACME_DIR}，请检查目录权限，确保 Nginx 运行用户有写权限。${RESET}"
        exit 1
    fi
    rm -f "${ACME_DIR}/.permtest"

    TEST_TOKEN="acme_test_$(date +%s)"
    TEST_FILE="${ACME_DIR}/${TEST_TOKEN}"
    echo "test_ok" > "${TEST_FILE}"
    chmod 644 "${TEST_FILE}"

    if ! ss -ltnp | grep -q ':80'; then
        echo -e "${RED}⛔ Nginx 未监听 80 端口，请检查并确保 Nginx 已 reload。${RESET}"
        nginx -t
        systemctl reload nginx
        exit 1
    fi

    TEST_URL="http://${DOMAIN}/.well-known/acme-challenge/${TEST_TOKEN}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TEST_URL")

    if [[ "$HTTP_CODE" != "200" ]]; then
        echo -e "${RED}⛔ 检测失败：无法通过 HTTP 访问 ${TEST_URL} （状态码 ${HTTP_CODE}），请检查 Nginx 配置与防火墙。${RESET}"
        rm -f "${TEST_FILE}"
        exit 1
    else
        echo -e "${GREEN}✅ .well-known/acme-challenge 路径可正常访问。${RESET}"
        rm -f "${TEST_FILE}"
    fi
    echo

    echo -e "${CYAN}开始申请 Let’s Encrypt 证书（域名：${DOMAIN}，Email：${EMAIL}）……${RESET}"

    SSL_DIR="/etc/nginx/ssl/${DOMAIN}"
    mkdir -p "${SSL_DIR}"

    "$ACME_BIN" --issue --webroot "${WEB_ROOT}" -d "${DOMAIN}" -d "www.${DOMAIN}" \
        --keylength ec-256 \
        --accountemail "${EMAIL}" \
        || { echo -e "${RED}⛔ 证书申请失败：请检查域名解析是否已生效、80 端口是否对外开放、Nginx challenge 配置是否生效。${RESET}"; exit 1; }

    echo -e "${CYAN}正在将证书安装到 ${BLUE}${SSL_DIR}${RESET} ...${RESET}"
    "$ACME_BIN" --install-cert -d "${DOMAIN}" \
        --key-file   "${SSL_DIR}/${DOMAIN}.key" \
        --fullchain-file "${SSL_DIR}/${DOMAIN}.cer" \
        --reloadcmd  "systemctl reload nginx" \
        || { echo -e "${RED}⛔ 证书安装失败！${RESET}"; exit 1; }

    echo -e "${GREEN}✅ Let’s Encrypt 证书已生成并部署到 ${BLUE}${SSL_DIR}${RESET}。${RESET}"
    echo
else
    echo -e "${YELLOW}ℹ️ 使用已有证书，无需重新申请。${RESET}"
    SSL_DIR="/etc/nginx/ssl/${DOMAIN}"
fi

##############################################
# 7. 生成 Nginx 正式配置并启用站点         #
#    —— 采用 /var/www/${DOMAIN} 作为 root    #
##############################################
echo "######################################################"
echo "  生成 Nginx 正式配置并启用站点"
echo "######################################################"

NGINX_CONF_AVAILABLE="/etc/nginx/sites-available"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled"
mkdir -p "${NGINX_CONF_AVAILABLE}" "${NGINX_CONF_ENABLED}"
NGINX_CONF_FILE="${NGINX_CONF_AVAILABLE}/${DOMAIN}.conf"

# 始终覆盖旧配置，确保路径指向 /var/www/${DOMAIN}
echo -e "${CYAN}正在写入 Nginx 配置文件：${BLUE}${NGINX_CONF_FILE}${RESET} ..."
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
echo -e "${GREEN}✅ Nginx 配置文件已写入：${BLUE}${NGINX_CONF_FILE}${RESET}"

# 启用站点配置
if [ -L "${NGINX_CONF_ENABLED}/${DOMAIN}.conf" ]; then
    echo -e "${YELLOW}ℹ️ 站点配置软链接已存在，先移除旧链接再重新创建。${RESET}"
    rm -f "${NGINX_CONF_ENABLED}/${DOMAIN}.conf"
fi
ln -s "${NGINX_CONF_FILE}" "${NGINX_CONF_ENABLED}/${DOMAIN}.conf"
echo -e "${GREEN}✅ 站点配置已启用：${BLUE}${NGINX_CONF_ENABLED}/${DOMAIN}.conf${RESET}"

echo -e "${CYAN}正在测试 Nginx 配置 ...${RESET}"
if nginx -t; then
    echo -e "${CYAN}Nginx 配置测试通过，正在重载服务 ...${RESET}"
    systemctl reload nginx
    echo -e "${GREEN}✅ Nginx 服务已重载。${RESET}"
else
    echo -e "${RED}⛔ Nginx 配置测试失败，请检查配置文件语法。${RESET}"
    exit 1
fi

echo

##############################################
# 8. 安装并配置 cron 任务自动续期证书        #
##############################################
echo "######################################################"
echo "  安装并配置 cron 任务自动续期证书"
echo "######################################################"

CRON_JOB="0 1 1 * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null 2>&1"
if grep -q "/root/.acme.sh/acme.sh --cron" /etc/crontab; then
    echo -e "${YELLOW}ℹ️ 系统 Crontab 中已存在 acme.sh 续期任务，跳过添加。${RESET}"
else
    echo "${CRON_JOB}" >> /etc/crontab
    echo -e "${GREEN}✅ 已添加 acme.sh 证书续期的系统 Crontab 任务。${RESET}"
fi

echo

##############################################
# 9. 在末尾提示是否重新生成证书（不阻塞主流程） #
##############################################
if $USE_EXISTING_CERT; then
    echo "######################################################"
    echo -e "${YELLOW}  检测到已有证书距今不足 3 天${RESET}"
    echo -e "${YELLOW}  旧证书生成日期：$(date -d @"$CERT_MTIME" +'%Y-%m-%d')，已过去 ${CERT_AGE_DAYS} 天。${RESET}"
    echo -e "${CYAN}  若要强制重新生成，请在 60 秒内输入 ${GREEN}Y${CYAN}，或等待超时跳过。${RESET}"
    # 切换到 /dev/tty 读取，避免管道导致直接跳过
    exec 3<&0
    exec < /dev/tty
    if read -t 60 -rn1 yn; then
        echo
        if [[ "$yn" =~ [Yy] ]]; then
            echo -e "${GREEN}✅ 用户选择强制重新生成证书，开始执行……${RESET}"
            echo "######################################################"
            echo -e "${CYAN}  再次申请 Let’s Encrypt 证书（域名：${DOMAIN}，Email：${EMAIL}）……${RESET}"
            "$ACME_BIN" --issue --force --webroot "${WEB_ROOT}" -d "${DOMAIN}" -d "www.${DOMAIN}" \
                --keylength ec-256 \
                --accountemail "${EMAIL}" \
                || { echo -e "${RED}⛔ 证书申请失败：请检查域名解析是否已生效、80 端口是否对外开放、Nginx challenge 配置是否生效。${RESET}"; exit 1; }

            echo -e "${CYAN}正在将新证书安装到 ${BLUE}${SSL_DIR}${RESET} …${RESET}"
            "$ACME_BIN" --install-cert -d "${DOMAIN}" \
                --key-file   "${SSL_DIR}/${DOMAIN}.key" \
                --fullchain-file "${SSL_DIR}/${DOMAIN}.cer" \
                --reloadcmd  "systemctl reload nginx" \
                --force \
                || { echo -e "${RED}⛔ 新证书安装失败！${RESET}"; exit 1; }

            echo -e "${GREEN}✅ 新 Let’s Encrypt 证书已生成并部署到 ${BLUE}${SSL_DIR}${RESET}。${RESET}"
            echo -e "${GREEN}✅ 已完成强制重新生成并自动重载 Nginx。${RESET}"
        else
            echo -e "${YELLOW}ℹ️ 跳过证书重新生成，保留现有证书。${RESET}"
        fi
    else
        echo
        echo -e "${YELLOW}ℹ️ 未在 60 秒内输入，跳过证书重新生成。${RESET}"
    fi
    exec 0<&3
fi

echo

##############################################
# 10. 提示用户检查防火墙                      #
##############################################
echo "######################################################"
echo "  安装完成！请检查防火墙设置"
echo "######################################################"

if command -v ufw &>/dev/null; then
    if ufw status | grep -qw active; then
        echo -e "${GREEN}✅ UFW 防火墙已启用，80/443 端口已放行。${RESET}"
    else
        echo -e "${YELLOW}⚠️ UFW 防火墙已安装但未启用，请手动启用或检查设置。${RESET}"
    fi
fi

if command -v firewall-cmd &>/dev/null; then
    if systemctl is-active firewalld &>/dev/null; then
        echo -e "${GREEN}✅ firewalld 防火墙已启用，80/443 端口已放行。${RESET}"
    else
        echo -e "${YELLOW}⚠️ firewalld 防火墙已安装但未启用，请手动启用或检查设置。${RESET}"
    fi
fi

if command -v iptables &>/dev/null; then
    iptables -L -n | grep -E "tcp dpt:80|tcp dpt:443" &>/dev/null
    if [ "$?" -eq 0 ]; then
        echo -e "${GREEN}✅ iptables 已放行 80/443 端口。${RESET}"
    else
        echo -e "${YELLOW}⚠️ iptables 未放行 80/443 端口，请手动检查设置。${RESET}"
    fi
fi

echo
echo -e "${GREEN}🎉 所有步骤已成功完成！请访问 https://${DOMAIN} 检查站点是否正常。${RESET}"
echo -e "📅 请记得定期检查 SSL 证书有效期，确保自动续期任务正常运行。"
echo -e "如需帮助，请查阅相关文档或联系支持。"
echo "######################################################"
echo

exit 0
