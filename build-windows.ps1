# Mattermost Windows Build Script
# Bu betik Mattermost'u Windows ortaminda derler ve paketler.
# Run: .\build-windows.ps1
# Optional: .\build-windows.ps1 -SkipWebapp  (webapp build atlanir, onceden derlenmisse)

param(
    [switch]$SkipWebapp = $false,
    [string]$BuildNumber = "dev"
)

$ErrorActionPreference = "Stop"

# ---- Renkli cikti yardimcilari ----
function Write-Step  { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK    { param($msg) Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Fail  { param($msg) Write-Host "    HATA: $msg" -ForegroundColor Red; exit 1 }

# ---- Kok dizin ----
$RepoRoot  = $PSScriptRoot
$ServerDir = Join-Path $RepoRoot "server"
$WebappDir = Join-Path $RepoRoot "webapp"
$DistDir   = Join-Path $ServerDir "dist\windows\mattermost"

# ---- Gereksinim kontrolleri ----
Write-Step "Gereksinimler kontrol ediliyor..."

# Go
try {
    $goVer = (go version) -replace "go version go",""
    $goParts = $goVer.Split(".")
    if ([int]$goParts[0] -lt 1 -or ([int]$goParts[0] -eq 1 -and [int]$goParts[1] -lt 22)) {
        Write-Fail "Go 1.22+ gerekli. Kurulu surum: $goVer"
    }
    Write-OK "Go $goVer"
} catch {
    Write-Fail "Go bulunamadi. https://go.dev/dl/ adresinden yukleyin."
}

# Node.js (webapp icin)
if (-not $SkipWebapp) {
    try {
        $nodeVer = (node --version).TrimStart("v")
        $nodeMajor = [int]($nodeVer.Split(".")[0])
        if ($nodeMajor -lt 20) {
            Write-Fail "Node.js 20+ gerekli (onerilir: 24). Kurulu: $nodeVer"
        }
        Write-OK "Node.js $nodeVer"
    } catch {
        Write-Fail "Node.js bulunamadi. https://nodejs.org adresinden yukleyin."
    }

    try {
        $npmVer = (npm --version)
        Write-OK "npm $npmVer"
    } catch {
        Write-Fail "npm bulunamadi."
    }
}

# ---- Webapp derle ----
if (-not $SkipWebapp) {
    Write-Step "Webapp derleniyor ($WebappDir)..."
    Push-Location $WebappDir
    try {
        npm install --legacy-peer-deps
        if ($LASTEXITCODE -ne 0) { Write-Fail "npm install basarisiz" }

        npm run build
        if ($LASTEXITCODE -ne 0) { Write-Fail "npm run build basarisiz" }
    } finally {
        Pop-Location
    }
    Write-OK "Webapp derlendi"
}

# ---- Go work dosyasi olustur ----
Write-Step "Go workspace ayarlaniyor..."
Push-Location $ServerDir
try {
    if (Test-Path "go.work") { Remove-Item "go.work" -Force }
    if (Test-Path "go.work.sum") { Remove-Item "go.work.sum" -Force }
    go work init
    go work use .
    go work use ./public
    if ($LASTEXITCODE -ne 0) { Write-Fail "go work use basarisiz" }
} finally {
    Pop-Location
}
Write-OK "Go workspace hazir"

# ---- Build degiskenleri ----
$BuildDate = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
$BuildHash = try { git -C $RepoRoot rev-parse HEAD } catch { "unknown" }

$LdFlags = @(
    "-X `"github.com/mattermost/mattermost/server/public/model.BuildNumber=$BuildNumber`"",
    "-X `"github.com/mattermost/mattermost/server/public/model.BuildDate=$BuildDate`"",
    "-X `"github.com/mattermost/mattermost/server/public/model.BuildHash=$BuildHash`"",
    "-X `"github.com/mattermost/mattermost/server/public/model.BuildHashEnterprise=none`"",
    "-X `"github.com/mattermost/mattermost/server/public/model.BuildEnterpriseReady=false`""
) -join " "

# ---- Go server'i Windows icin derle ----
Write-Step "Go sunucu binary'si derleniyor (Windows amd64)..."
Push-Location $ServerDir
try {
    $BinDir = Join-Path $ServerDir "bin\windows_amd64"
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

    $env:GOOS    = "windows"
    $env:GOARCH  = "amd64"
    $env:CGO_ENABLED = "0"

    go build -trimpath `
        -tags "production sourceavailable" `
        -ldflags $LdFlags `
        -o "$BinDir\mattermost.exe" `
        ./cmd/mattermost

    if ($LASTEXITCODE -ne 0) { Write-Fail "mattermost.exe derleme basarisiz" }
    Write-OK "mattermost.exe -> $BinDir\mattermost.exe"

    go build -trimpath `
        -ldflags $LdFlags `
        -o "$BinDir\mmctl.exe" `
        ./cmd/mmctl

    if ($LASTEXITCODE -ne 0) { Write-Fail "mmctl.exe derleme basarisiz" }
    Write-OK "mmctl.exe    -> $BinDir\mmctl.exe"
} finally {
    Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    Pop-Location
}

# ---- Paket dizini olustur ----
Write-Step "Paket dizini olusturuluyor: $DistDir"
if (Test-Path $DistDir) { Remove-Item $DistDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $DistDir "bin")   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DistDir "logs")  | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DistDir "data")  | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DistDir "config") | Out-Null

# Binary'leri kopyala
$BinDir = Join-Path $ServerDir "bin\windows_amd64"
Copy-Item "$BinDir\mattermost.exe" (Join-Path $DistDir "bin")
Copy-Item "$BinDir\mmctl.exe"      (Join-Path $DistDir "bin")

# Kaynak dosyalari kopyala
Copy-Item (Join-Path $ServerDir "fonts")     (Join-Path $DistDir "fonts")     -Recurse
Copy-Item (Join-Path $ServerDir "templates") (Join-Path $DistDir "templates") -Recurse
Copy-Item (Join-Path $ServerDir "i18n")      (Join-Path $DistDir "i18n")      -Recurse

# Webapp istemcisini kopyala
$WebappDist = Join-Path $WebappDir "channels\dist"
if (Test-Path $WebappDist) {
    New-Item -ItemType Directory -Force -Path (Join-Path $DistDir "client") | Out-Null
    Copy-Item "$WebappDist\*" (Join-Path $DistDir "client") -Recurse
    Write-OK "Webapp istemcisi kopyalandi"
} else {
    Write-Host "    UYARI: Webapp dist bulunamadi ($WebappDist). -SkipWebapp kullandiysan onceden derlenip kopyalanmasi gerekir." -ForegroundColor Yellow
}

# Varsayilan config olustur
Write-Step "Varsayilan config olusturuluyor..."
Push-Location $ServerDir
try {
    $env:OUTPUT_CONFIG = Join-Path $DistDir "config\config.json"
    go run ./scripts/config_generator
    if ($LASTEXITCODE -ne 0) { Write-Fail "config_generator basarisiz" }
    Remove-Item Env:OUTPUT_CONFIG -ErrorAction SilentlyContinue
} finally {
    Pop-Location
}

# Lisans dosyasi
Copy-Item (Join-Path $RepoRoot "NOTICE.txt") $DistDir -ErrorAction SilentlyContinue
Copy-Item (Join-Path $RepoRoot "README.md")  $DistDir -ErrorAction SilentlyContinue

# Deployment betiklerini kopyala
$DeployScript = Join-Path $RepoRoot "deploy-windows-service.ps1"
if (Test-Path $DeployScript) {
    Copy-Item $DeployScript $DistDir
}

# ---- ZIP olustur ----
Write-Step "ZIP paketi olusturuluyor..."
$ZipPath = Join-Path $ServerDir "dist\mattermost-windows-amd64.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Compress-Archive -Path (Join-Path $DistDir "..\..\windows\mattermost") -DestinationPath $ZipPath -CompressionLevel Optimal
Write-OK "Paket olusturuldu: $ZipPath"

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Derleme tamamlandi!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host " Dagitim paketi : $ZipPath"
Write-Host " Dagitim dizini : $DistDir"
Write-Host ""
Write-Host " Sonraki adimlar:"
Write-Host "  1. ZIP'i Windows Server'a kopyala"
Write-Host "  2. Bir dizine ac (ornek: C:\mattermost)"
Write-Host "  3. PostgreSQL kur ve veritabani olustur"
Write-Host "  4. config\config.json dosyasini duzenle"
Write-Host "  5. .\deploy-windows-service.ps1 calistir (Administrator olarak)"
Write-Host ""
