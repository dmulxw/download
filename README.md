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
### 一键安装nginx网站，自动加入SSL证书。只要复制后在linux系统里，右键粘贴，执行以下命令行就可以了

```sh
curl -Ls https://raw.githubusercontent.com/dmulxw/download/master/install.sh | sudo bash
```
