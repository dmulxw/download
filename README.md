# 一键安装 Nginx 和 SSL 证书 使用说明  
## One-Click Nginx & SSL Install Guide

---

## 中文说明

### 介绍  
本脚本可在支持 Debian/Ubuntu 或 RHEL/CentOS/AlmaLinux 的服务器上，一键完成：  
1. 安装 Nginx  
2. 下载并解压最新 release 中的 `web.zip` 到 `/var/www/你的域名/`  
3. 自动申请并安装 Let’s Encrypt SSL 证书  
4. 配置 Nginx，启用 HTTPS  
5. 设置每月自动续期证书的 Cron 任务  

> **注意：**  
> - 默认会将 `web.zip` 从本仓库的“最新 Release”中拉取。  
> - 如果想安装自己的前端代码包，请先 Fork 本仓库，将 `web.zip` 上传到你自己的 GitHub Releases，然后将命令中的 `你的用户名` 替换为你自己的用户名。  

---

### 使用步骤

1. **复制下面的命令到你的服务器终端并运行：**  
   > **（请确保替换 `你的用户名` 为你的 GitHub 用户名）**  
   ```bash
   curl -Ls https://raw.githubusercontent.com/你的用户名/download/master/install.sh | sudo bash
   ```
   - 该命令会从你的仓库中下载最新的 `install.sh` 并以 `sudo` 权限执行。  
   - 当提示输入“域名”与“Email”时，请分别输入你要绑定的域名和申请 SSL 证书的邮箱地址。  

2. **脚本执行流程**  
   1. 检测操作系统（Debian/Ubuntu 或 RHEL/CentOS/AlmaLinux），并自动安装必要依赖（包括 Nginx、curl、unzip、git、socat、cron/cronie）。  
   2. 如果系统已安装 Nginx，则跳过安装；否则先安装 Nginx 并启动。  
   3. 自动放行防火墙的 80/443 端口（支持 `ufw`、`firewalld` 或 `iptables`）。  
   4. 从你 GitHub 仓库的 **最新 Release** 下载 `web.zip` 并解压到 `/var/www/<你的域名>/`。  
   5. 安装并配置 `acme.sh`，申请 Let’s Encrypt SSL 证书，证书存放在 `/etc/nginx/ssl/<你的域名>/`。  
   6. 生成并启用 Nginx 虚拟主机配置，网站根目录指向 `/var/www/<你的域名>/`，并强制 HTTPS。  
   7. 为 `acme.sh` 添加每月自动续期的 Cron 任务（1 号凌晨 01:00 执行）。  
   8. 完成后，会在终端显示所有关键路径（Nginx 安装目录、配置文件名、SSL 证书存放位置、网站根目录）并提示检查防火墙设置。  

3. **手动替换 `web.zip`**  
   - **示例：** 如果你 Fork 了本仓库，且发布了自己的 `web.zip`，请将命令改成：  
     ```bash
     curl -Ls https://raw.githubusercontent.com/你的用户名/download/master/install.sh | sudo bash
     ```  
   - 这样脚本会从你自己仓库的 Release 中拉取最新的 `web.zip`。  

4. **后续检查**  
   - 安装完成后，可访问 `https://<你的域名>` 验证网站是否正常。  
   - 若要自定义前端源码，请替换 `/var/www/<你的域名>/` 下的文件；再次访问时，Nginx 会直接提供你的内容。  
   - SSL 证书位于：  
     ```
     /etc/nginx/ssl/<你的域名>/<你的域名>.cer  
     /etc/nginx/ssl/<你的域名>/<你的域名>.key  
     ```  
   - Nginx 配置文件位于：  
     ```text
     /etc/nginx/sites-available/<你的域名>.conf  
     /etc/nginx/sites-enabled/<你的域名>.conf  
     ```  
   - 网站根目录：  
     ```
     /var/www/<你的域名>  
     ```  

---

## English Instructions

### Overview  
This one-click script will automatically on Debian/Ubuntu or RHEL/CentOS/AlmaLinux servers:  
1. Install **Nginx**  
2. Download & extract the latest `web.zip` from this repo’s **latest Release** into `/var/www/your-domain/`  
3. Automatically issue and install a Let’s Encrypt **SSL certificate**  
4. Configure Nginx for HTTPS  
5. Set up a monthly cron job to renew the certificate  

> **Note:**  
> - By default, `web.zip` is pulled from this repository’s **Latest Release**.  
> - To use a custom `web.zip`, **Fork** this repo, upload your `web.zip` to *your* GitHub Releases, then replace `your-username` in the command below with your own GitHub username.  

---

### Steps to Use

1. **Copy & paste the following command into your server terminal and run:**  
   > **(Replace `your-username` with *your* GitHub username)**  
   ```bash
   curl -Ls https://raw.githubusercontent.com/your-username/download/master/install.sh | sudo bash
   ```
   - This fetches the latest `install.sh` from your fork and runs it with `sudo`.  
   - You will be prompted to enter your **domain** and **email** for the SSL cert.  

2. **What the script does**  
   1. Detects OS family (Debian/Ubuntu or RHEL/CentOS/AlmaLinux) and installs dependencies (`nginx`, `curl`, `unzip`, `git`, `socat`, `cron/cronie`).  
   2. If Nginx is already installed, it skips installation; otherwise, installs and starts Nginx.  
   3. Opens firewall ports 80 and 443 (`ufw`, `firewalld` or `iptables`).  
   4. Downloads `web.zip` from **your** repo’s Latest Release and extracts into `/var/www/<your-domain>/`.  
   5. Installs and configures `acme.sh` to obtain a Let’s Encrypt SSL certificate, stored at `/etc/nginx/ssl/<your-domain>/`.  
   6. Creates an Nginx vhost, points the root to `/var/www/<your-domain>/`, and forces HTTPS.  
   7. Adds a cron job for `acme.sh` to automatically renew on the 1st of every month at 01:00.  
   8. At the end, it prints all critical paths (Nginx install dir, config filename, SSL cert location, web root) and reminds you to verify firewall settings.  

3. **Using your own `web.zip`**  
   - **Example:** If you forked this repo and published your own `web.zip` in **your** Releases, run:  
     ```bash
     curl -Ls https://raw.githubusercontent.com/your-username/download/master/install.sh | sudo bash
     ```  
   - This ensures the script fetches the `web.zip` from *your* GitHub Releases.  

4. **Post-install Checks**  
   - After installation, visit `https://<your-domain>` to verify.  
   - To customize your front-end code, replace files under `/var/www/<your-domain>/`; Nginx will serve your updated content.  
   - SSL certificates are located at:  
     ```text
     /etc/nginx/ssl/<your-domain>/<your-domain>.cer  
     /etc/nginx/ssl/<your-domain>/<your-domain>.key  
     ```  
   - Nginx config files are found at:  
     ```text
     /etc/nginx/sites-available/<your-domain>.conf  
     /etc/nginx/sites-enabled/<your-domain>.conf  
     ```  
   - Web root directory:  
     ```text
     /var/www/<your-domain>  
     ```  

---

> **重要提示 / IMPORTANT**  
> - **请务必将命令中的 `your-username` 替换为您自己的 GitHub 用户名**，以确保脚本从您自己的仓库拉取 `web.zip`。  
>   **Make sure to replace `your-username` with your GitHub username** so that the script pulls `web.zip` from your own repo.  

---

感谢使用，本脚本旨在让您能快速在服务器上部署静态网站并获得 HTTPS 支持。  
Thank you for using this script, which aims to help you quickly deploy a static site with HTTPS on your server.
