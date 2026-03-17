# Mattermost Windows Service Deployment Script
# Bu betik Mattermost'u Windows Server'da Windows Servisi olarak kurar.
# GEREKSINIM: Administrator yetkisiyle calistirilmali
# Run: .\deploy-windows-service.ps1
# Ozellestirilmis kurulum: .\deploy-windows-service.ps1 -InstallDir "D:\mattermost" -DbHost "dbserver"

param(
    [string]$InstallDir  = "C:\mattermost",
    [string]$ServiceName = "Mattermost",
    [string]$DisplayName = "Mattermost Server",
    [string]$DbHost      = "localhost",
    [string]$DbPort      = "5432",
    [string]$DbName      = "mattermost",
    [string]$DbUser      = "mmuser",
    [string]$DbPassword  = "",
    [string]$SiteURL     = "http://localhost:8065",
    [int]$ListenPort     = 8065,
    [switch]$Uninstall   = $false
)

$ErrorActionPreference = "Stop"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "    UYARI: $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "    HATA: $msg" -ForegroundColor Red; exit 1 }

# ---- Administrator kontrolu ----
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail "Bu betik Administrator yetkisiyle calistirilmalidir. PowerShell'i 'Yonetici olarak calistir' ile acin."
}

# ---- Servis kaldirma ----
if ($Uninstall) {
    Write-Step "Mattermost servisi kaldiriliyor..."
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq "Running") {
            Stop-Service -Name $ServiceName -Force
            Write-OK "Servis durduruldu"
        }
        sc.exe delete $ServiceName | Out-Null
        Write-OK "Servis '$ServiceName' kaldirildi"
    } else {
        Write-Warn "'$ServiceName' servisi bulunamadi"
    }
    exit 0
}

# ---- Kurulum dizini kontrol ----
Write-Step "Kurulum dizini kontrol ediliyor: $InstallDir"
if (-not (Test-Path $InstallDir)) {
    Write-Fail "Kurulum dizini bulunamadi: $InstallDir`nOnce build-windows.ps1 ile derleme yapip bu dizine acin."
}
$BinPath = Join-Path $InstallDir "bin\mattermost.exe"
if (-not (Test-Path $BinPath)) {
    Write-Fail "mattermost.exe bulunamadi: $BinPath`nDizin yapisi yanlis olmayabilir. bin\mattermost.exe olmali."
}
Write-OK "mattermost.exe bulundu"

# ---- PostgreSQL kontrolu ----
Write-Step "Veritabani baglantisi kontrol ediliyor..."
if ($DbPassword -eq "") {
    Write-Warn "DbPassword parametresi verilmedi. config.json'u elle duzenlemeniz gerekecek."
} else {
    $env:PGPASSWORD = $DbPassword
    $psqlCheck = & psql -h $DbHost -p $DbPort -U $DbUser -d $DbName -c "SELECT 1;" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Veritabani baglantisi saglanamadi. config.json'u elle duzenlemeniz gerekebilir."
        Write-Warn "Hata: $psqlCheck"
    } else {
        Write-OK "Veritabani baglantisi basarili"
    }
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}

# ---- config.json guncelle ----
Write-Step "config.json guncelleniyor..."
$ConfigPath = Join-Path $InstallDir "config\config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Fail "config.json bulunamadi: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# ServiceSettings
$config.ServiceSettings.SiteURL        = $SiteURL
$config.ServiceSettings.ListenAddress  = ":$ListenPort"

# SqlSettings (PostgreSQL)
if ($DbPassword -ne "") {
    $DataSource = "postgres://${DbUser}:${DbPassword}@${DbHost}:${DbPort}/${DbName}?sslmode=disable&connect_timeout=10"
    $config.SqlSettings.DriverName   = "postgres"
    $config.SqlSettings.DataSource   = $DataSource
}

# LogSettings
$config.LogSettings.EnableConsole    = $true
$config.LogSettings.ConsoleLevel     = "INFO"
$config.LogSettings.EnableFile       = $true
$config.LogSettings.FileLocation     = (Join-Path $InstallDir "logs\mattermost.log")

# FileSettings - yerel dosya depolama
$config.FileSettings.Directory = (Join-Path $InstallDir "data\")

$config | ConvertTo-Json -Depth 20 | Set-Content $ConfigPath -Encoding UTF8
Write-OK "config.json guncellendi"

# ---- Gerekli dizinler ----
Write-Step "Dizinler olusturuluyor..."
@("logs", "data", "plugins", "client\plugins") | ForEach-Object {
    $dir = Join-Path $InstallDir $_
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Write-OK "Olusturuldu: $dir"
    }
}

# ---- Firewall kurali ----
Write-Step "Firewall kurali ekleniyor (port $ListenPort)..."
$fwRule = Get-NetFirewallRule -DisplayName "Mattermost HTTP" -ErrorAction SilentlyContinue
if (-not $fwRule) {
    New-NetFirewallRule `
        -DisplayName "Mattermost HTTP" `
        -Direction   Inbound `
        -Protocol    TCP `
        -LocalPort   $ListenPort `
        -Action      Allow | Out-Null
    Write-OK "Firewall kurali eklendi (TCP $ListenPort)"
} else {
    Write-OK "Firewall kurali zaten mevcut"
}

# ---- Windows Servisi kur ----
Write-Step "Windows Servisi kuruluyor: '$ServiceName'..."
$existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingSvc) {
    if ($existingSvc.Status -eq "Running") {
        Stop-Service -Name $ServiceName -Force
        Write-OK "Mevcut servis durduruldu"
    }
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    Write-OK "Mevcut servis silindi"
}

# Servis olustur - sc.exe kullanarak (NSSM gerekmez)
$BinPathEscaped = "`"$BinPath`""
sc.exe create $ServiceName `
    binPath= "$BinPathEscaped --config `"$ConfigPath`"" `
    DisplayName= $DisplayName `
    start= auto | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Servis olusturulamadi. sc.exe cikti kodu: $LASTEXITCODE"
}

# Servis aciklamasi
sc.exe description $ServiceName "Mattermost is an open-source, self-hosted messaging platform." | Out-Null

# Hata durumunda otomatik yeniden baslat
sc.exe failure $ServiceName reset= 60 actions= restart/5000/restart/10000/restart/30000 | Out-Null

Write-OK "Servis olusturuldu"

# ---- Servisi baslat ----
Write-Step "Servis baslatiliyor..."
Start-Service -Name $ServiceName
Start-Sleep -Seconds 3
$svc = Get-Service -Name $ServiceName
if ($svc.Status -eq "Running") {
    Write-OK "Servis calisiyor"
} else {
    Write-Warn "Servis baslatılamadi. Durum: $($svc.Status)"
    Write-Warn "Log dosyasini kontrol edin: $(Join-Path $InstallDir 'logs\mattermost.log')"
}

# ---- Ozet ----
Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Kurulum tamamlandi!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host " Servis adi  : $ServiceName"
Write-Host " Kurulum yolu: $InstallDir"
Write-Host " Adres       : $SiteURL"
Write-Host " Log dosyasi : $(Join-Path $InstallDir 'logs\mattermost.log')"
Write-Host ""
Write-Host " Servis yonetimi:"
Write-Host "  Baslat : Start-Service $ServiceName"
Write-Host "  Durdur : Stop-Service  $ServiceName"
Write-Host "  Kaldir : .\deploy-windows-service.ps1 -Uninstall"
Write-Host ""
Write-Host " Ilk giris sonrasi sistem yoneticisi olusturmak icin:"
Write-Host "  bin\mmctl.exe user create --email admin@example.com --username admin --password Admin1234! --system-admin"
Write-Host ""
