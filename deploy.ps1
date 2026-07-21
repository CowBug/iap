# deploy.ps1 — 一键注入 IAPCrack.dylib 到 IPA 并签名
# 用法: .\deploy.ps1 [-Dylib <path>] [-Cert <p12>] [-Pass <password>] [-Prov <mobileprovision>]

param(
    [string]$Dylib = ".\IAPCrack.dylib",
    [string]$IPA = "..\com.gigass.maxpodApp_1.8.7_und3fined.ipa",
    [string]$Cert = "",
    [string]$Pass = "",
    [string]$Prov = "",
    [string]$Output = "..\UltraPod_1.8.7_cracked.ipa"
)

$ZSign = ".\zsign\zsign.exe"
$ErrorActionPreference = "Stop"

# — Check prerequisites —
if (-not (Test-Path $ZSign)) {
    Write-Host "[!] zsign.exe 未找到，请先解压 zsign-windows-x64.zip 到 .\zsign\" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $Dylib)) {
    Write-Host "[!] IAPCrack.dylib 未找到" -ForegroundColor Red
    Write-Host ""
    Write-Host "构建 dylib 的三种方式:"
    Write-Host "  1. GitHub Actions: 将 IAPCrack/ 目录 push 到 GitHub，Actions 会自动编译"
    Write-Host "     Workflow 文件: IAPCrack\build.yml"
    Write-Host "  2. macOS: cd IAPCrack && make"
    Write-Host "  3. 使用预编译的 Satella Jailed dylib (搜索 'SatellaJailed dylib')"
    Write-Host ""
    exit 1
}
if (-not (Test-Path $IPA)) {
    Write-Host "[!] IPA 文件未找到: $IPA" -ForegroundColor Red
    exit 1
}

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  UltraPod IAP Crack Injector" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# — Inject dylib + sign —
$args = @("-o", $Output)

if ($Cert -and $Pass -and $Prov) {
    # 使用开发者证书签名
    Write-Host "[*] 模式: 证书签名" -ForegroundColor Yellow
    $args += @("-k", $Cert, "-p", $Pass, "-m", $Prov)
} else {
    # Ad-hoc 签名
    Write-Host "[*] 模式: Ad-hoc 签名 (适合 LiveContainer/TrollStore)" -ForegroundColor Yellow
    $args += "-a"
}

# 注入 dylib
$args += @("-l", $Dylib)

# 输入文件
$args += $IPA

Write-Host "[*] 正在注入 dylib 并签名..."
Write-Host "    zsign $($args -join ' ')" -ForegroundColor DarkGray

& $ZSign $args

if ($LASTEXITCODE -ne 0) {
    Write-Host "[✗] 签名失败" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "  ✓ 破解完成" -ForegroundColor Green
Write-Host "  Output: $Output" -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "安装方式:"
Write-Host "  1. 将 $Output 传到 iOS 设备"
Write-Host "  2. 用 LiveContainer 打开安装"
Write-Host ""
Write-Host "破解内容:"
Write-Host "  - Pro Lifetime (com.maxpod.pro_lifetime)"
Write-Host "  - Ultimate Lifetime (com.maxpod.ultimate_lifetime)"
Write-Host "  - Ultimate Upgrade (com.maxpod.ultimate_upgrade_from_pro)"
Write-Host ""
Write-Host "如果购买未生效，在 App 内进入 Settings > Purchases > Restore Purchases" -ForegroundColor Yellow
