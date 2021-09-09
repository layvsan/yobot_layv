﻿# this file should be saved as "UTF-8 with BOM"
$ErrorActionPreference = "Stop"

function Expand-ZIPFile($file, $destination) {
  $file = (Resolve-Path -Path $file).Path
  $destination = (Resolve-Path -Path $destination).Path
  $shell = new-object -com shell.application
  $zip = $shell.NameSpace($file)
  foreach ($item in $zip.items()) {
    $shell.Namespace($destination).copyhere($item)
		}
}

# 检查运行环境
if ($Host.Version.Major -lt 3) {
  Write-Output 'powershell 版本过低，无法一键安装'
  exit
}
if ((Get-ChildItem -Path Env:OS).Value -ine 'Windows_NT') {
  Write-Output '当前操作系统不支持一键安装'
  exit
}
if (![Environment]::Is64BitProcess) {
  $OStype = 'windows-amd64'
}
else {
  $OStype = 'windows-386'
}
if (Test-Path .\qqbot) {
  Write-Output '发现重复，是否删除旧文件并重新安装？'
  $reinstall = Read-Host '请输入 y 或 n (y/n)'
  Switch ($reinstall) {
    Y { Remove-Item .\qqbot -Recurse -Force }
    N { exit }
    Default { exit }
  }
}

# 用户输入
$qqid = Read-Host '请输入作为机器人的QQ号：'
$qqpassword = Read-Host -AsSecureString '请输入作为机器人的QQ密码：'

$port = Read-Host '请输入端口（范围8000到65535，直接回车则随机）：'
if (!$port) {
  $port = Get-Random -Minimum 8000 -Maximum 65535
}

Write-Output '是否部署 caddy 网络服务器（如果你打算部署其他网络服务器如 nginx 等，建议选否）：'
$userinput = Read-Host '请输入 y 或 n (y/n)'
Switch ($userinput) {
  Y { $use_caddy = $true }
  N { $use_caddy = $false }
  Default { $use_caddy = $false }
}

Write-Output '是否使用域名？'
Write-Output '（如果服务器在国内，则必须是备案域名）'
Write-Output '（请提前将域名指向此服务器）'
$domain = Read-Host '请输入域名（不使用则直接回车）：'

# 创建运行目录
New-Item -Path .\qqbot -ItemType Directory
Set-Location qqbot
New-Item -ItemType Directory -Path .\yobot, .\yobot\yobot_data, .\mirai

# 下载程序
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$releases = ConvertFrom-Json(Invoke-WebRequest https://api.github.com/repos/Mrs4s/go-cqhttp/releases)
$exeDownloadUrl = ''
foreach ($assetsFile in $releases[0].assets) {
  if ($assetsFile.name.EndsWith("${OStype}.zip")) {
    $exeDownloadUrl = $assetsFile.browser_download_url
    break
  }
}
$exeDownloadUrl = $exeDownloadUrl -replace "https://github.com", "https://download.fastgit.org"
Invoke-WebRequest $exeDownloadUrl -O .\go-cqhttp-latest-windows-amd64.zip
Expand-ZIPFile go-cqhttp-latest-windows-amd64.zip -Destination .\mirai\
Remove-Item go-cqhttp-latest-windows-amd64.zip

Invoke-WebRequest https://down.yu.al/others/qqbot/yobot/yobot-latest.zip -O .\yobot.zip

Expand-ZIPFile yobot.zip -Destination .\yobot\
Remove-Item yobot.zip

if ($use_caddy) {  
  Invoke-WebRequest https://download.fastgit.org/caddyserver/caddy/releases/download/v2.2.1/caddy_2.2.1_windows_amd64.zip -O .\caddy_2.2.1_windows_amd64.zip
  New-Item -ItemType Directory -Path caddy
  Expand-ZIPFile caddy_2.2.1_windows_amd64.zip -Destination .\caddy\
  Remove-Item caddy_2.2.1_windows_amd64.zip
  $listen = '127.0.0.1'
}
else {
  $listen = '0.0.0.0'
}

if ($domain) {
  if (use_caddy) {
    $public_address = "https://${domain}"
  }
  else {
    $public_address = "http://${domain}:${port}"
  }
}
else {
  $ip = (Invoke-WebRequest api.ipify.org).content
  if (use_caddy) {
    $public_address = "http://${ip}"
  }
  else {
    $public_address = "http://${ip}:${port}"
  }
}

# 生成随机 access_token
$token = -join ((65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })

# 写入 go-cqhttp 配置文件
$realpassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($qqpassword))
New-Item -Path .\mirai\config.json -ItemType File -Value @"
{
  "uin": ${qqid},
  "password": "${realpassword}",
  "encrypt_password": false,
  "password_encrypted": `"`",
  "enable_db": false,
  "access_token": "${token}",
  "relogin": {
    "enabled": true,
    "relogin_delay": 3,
    "max_relogin_times": 0
  },
  "_rate_limit": {
    "enabled": false,
    "frequency": 1,
    "bucket_size": 1
  },
  "post_message_format": "string",
  "ignore_invalid_cqcode": false,
  "force_fragmented": true,
  "heartbeat_interval": 5,
  "http_config": {
    "enabled": false
  },
  "ws_config": {
    "enabled": false
  },
  "ws_reverse_servers": [
    {
      "enabled": true,
      "reverse_url": "ws://localhost:${port}/ws/",
      "reverse_reconnect_interval": 3000
    }
  ],
  "web_ui": {
    "enabled": false
  }
}
"@

# 写入 yobot 配置文件
New-Item -Path .\yobot\yobot_data\yobot_config.json -ItemType File -Value @"
{
    "host": "${listen}",
    "port": "${port}",
    "public_address": "${public_address}",
    "public_basepath": "/",
    "access_token": "${token}"
}
"@

if ($use_caddy) {
  # 写入 caddy 配置文件
  if (!$domain) {
    $domain = ':80'
  }
  New-Item -Path .\caddy\Caddyfile -ItemType File -Value @"
${domain}
respond /ws/* "Forbidden" 403 {
  close
}
reverse_proxy / http://127.0.0.1:${port} {
  header_up X-Real-IP {remote}
}
"@
}

# 启动程序
Start-Process -FilePath .\yobot\yobot.exe -WorkingDirectory .\yobot
Start-Process -FilePath cmd.exe -WorkingDirectory .\mirai -ArgumentList "/C `"go-cqhttp & pause`""
if ($use_caddy) {
  Start-Process -FilePath cmd.exe -WorkingDirectory .\caddy -ArgumentList "/C `"caddy run & pause`""
}

# 创建快捷方式
$desktop = [Environment]::GetFolderPath("Desktop")

$WshShell = New-Object -comObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("${desktop}\mirai-go.lnk")
$Shortcut.TargetPath = "${pwd}\mirai\go-cqhttp.exe"
$Shortcut.WorkingDirectory = "${pwd}\mirai\"
$Shortcut.Save()

$WshShell = New-Object -comObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("${desktop}\yobot.lnk")
$Shortcut.TargetPath = "${pwd}\yobot\yobot.exe"
$Shortcut.WorkingDirectory = "${pwd}\yobot\"
$Shortcut.Save()
