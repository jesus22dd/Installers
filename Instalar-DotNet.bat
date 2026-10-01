@echo off
setlocal
set "INSTALADOR_DOTNET_BAT=%~f0"
set "DOTNET_CHECK_ONLY=0"
if /I "%~1"=="--comprobar" set "DOTNET_CHECK_ONLY=1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$source = [System.IO.File]::ReadAllText($env:INSTALADOR_DOTNET_BAT); $parts = [regex]::Split($source, '(?m)^# === POWERSHELL ===\r?$'); & ([scriptblock]::Create($parts[1]))"
set "resultado=%errorlevel%"
echo.
if /I not "%~1"=="--comprobar" if /I not "%~1"=="--sin-pausa" pause
exit /b %resultado%

# === POWERSHELL ===
$ErrorActionPreference = 'Stop'
$checkOnly = $env:DOTNET_CHECK_ONLY -eq '1'

function Get-DotnetExecutable {
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = Join-Path $env:ProgramFiles 'dotnet/dotnet.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Get-DotnetLines {
    param([string]$Option)
    $executable = Get-DotnetExecutable
    if (-not $executable) { return @() }
    $lines = @(& $executable $Option)
    if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar dotnet $Option." }
    return $lines
}

function Test-DotnetComponent {
    param([int]$Major, [string]$Runtime)
    if ($Runtime) {
        $pattern = '^' + [regex]::Escape($Runtime) + '\s+' + $Major + '\.0\.\d+\s+\['
        $lines = @(Get-DotnetLines '--list-runtimes')
    } else {
        $pattern = '^' + $Major + '\.0\.\d+\s+\['
        $lines = @(Get-DotnetLines '--list-sdks')
    }
    return @($lines | Where-Object { $_ -match $pattern }).Count -gt 0
}

function Install-Component {
    param([int]$Major, [string]$Label, [string]$PackageId, [string]$Runtime)
    if (Test-DotnetComponent -Major $Major -Runtime $Runtime) {
        Write-Host "  OK  $Label" -ForegroundColor Green
        return
    }
    if ($checkOnly) { throw "Falta $Label. Ejecuta el BAT como administrador para instalarlo." }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'No tienes WinGet. Instala o actualiza App Installer de Microsoft y vuelve a ejecutar el BAT.'
    }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Cierra esta ventana. Clic derecho en el BAT > Ejecutar como administrador.'
    }
    Write-Host "  Instalando $Label..." -ForegroundColor Cyan
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& winget install --id $PackageId --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1)
        $installCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($installCode -in @(1641, 3010, -1978334967, -1978334966)) {
        throw "La instalacion de $Label solicita reiniciar Windows. Reinicia y vuelve a ejecutar este BAT."
    }
    if (-not (Test-DotnetComponent -Major $Major -Runtime $Runtime)) {
        $details = ($output | Select-Object -Last 6 | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw ("No se pudo verificar $Label (codigo $installCode)." + [Environment]::NewLine + $details)
    }
    Write-Host "  OK  $Label" -ForegroundColor Green
}

try {
    Write-Host ''
    Write-Host '  INSTALAR .NET 8, 9 Y 10' -ForegroundColor Cyan
    Write-Host '  SDK + runtimes. Omite componentes ya instalados.' -ForegroundColor DarkGray
    foreach ($major in @(8, 9, 10)) {
        Write-Host ''
        Write-Host "  .NET $major" -ForegroundColor Yellow
        Install-Component -Major $major -Label 'SDK' -PackageId "Microsoft.DotNet.SDK.$major"
        # El SDK incluye estos runtimes; instalar aparte solo si falta alguno.
        Install-Component -Major $major -Label 'Runtime .NET' -PackageId "Microsoft.DotNet.Runtime.$major" -Runtime 'Microsoft.NETCore.App'
        Install-Component -Major $major -Label 'Runtime ASP.NET Core' -PackageId "Microsoft.DotNet.AspNetCore.$major" -Runtime 'Microsoft.AspNetCore.App'
        Install-Component -Major $major -Label 'Runtime Desktop' -PackageId "Microsoft.DotNet.DesktopRuntime.$major" -Runtime 'Microsoft.WindowsDesktop.App'
    }
    Write-Host ''
    Write-Host 'Listo: SDK y runtimes 8, 9 y 10 verificados.' -ForegroundColor Green
    exit 0
} catch {
    Write-Host ''
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
