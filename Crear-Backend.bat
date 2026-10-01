@echo off
setlocal
set "PREPARACION_BAT=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$source = [System.IO.File]::ReadAllText($env:PREPARACION_BAT); $parts = [regex]::Split($source, '(?m)^# === POWERSHELL ===\r?$'); & ([scriptblock]::Create($parts[1]))"
set "resultado=%errorlevel%"
echo.
if /I not "%~1"=="--sin-pausa" pause
exit /b %resultado%

# === POWERSHELL ===
$ErrorActionPreference = 'Stop'

function Read-Answer {
    param([string]$Label, [string]$Default, [string]$Color = 'Cyan')
    Write-Host "$Label [$Default]: " -ForegroundColor $Color -NoNewline
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Read-Name {
    param([string]$Label, [string]$Default, [string]$Color = 'Cyan', [string[]]$Used = @())
    while ($true) {
        $value = Read-Answer $Label $Default $Color
        $valid = $value.Length -le 60 -and $value -match '^[A-Za-z][A-Za-z0-9_]*$'
        $reserved = $value -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$'
        if ($valid -and -not $reserved -and $Used -notcontains $value) { return $value }
        Write-Host 'Usa un nombre distinto, sin puntos ni espacios; empieza con letra.' -ForegroundColor Yellow
    }
}

function Invoke-Dotnet {
    param([string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& dotnet @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) {
        $details = ($output | Select-Object -Last 8 | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw ("dotnet " + ($Arguments -join ' ') + [Environment]::NewLine + $details)
    }
    return $output
}

try {
    Write-Host ''
    Write-Host '  PREPARAR BACKEND' -ForegroundColor Cyan
    Write-Host ''
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw 'No tienes dotnet disponible. Instala el SDK de .NET y vuelve a abrir la consola.'
    }
    $sdkLines = @(Invoke-Dotnet -Arguments @('--list-sdks'))
    $sdks = @(foreach ($line in $sdkLines) {
        if ([string]$line -match '^(\d+\.\d+\.\d+)\s+\[') { [version]$Matches[1] }
    })
    $sdks = @($sdks | Where-Object { $_.Major -ge 8 } | Sort-Object -Descending)
    if ($sdks.Count -eq 0) { throw 'No tienes un SDK estable de .NET 8 o superior instalado.' }

    $projectName = Read-Name 'Nombre del proyecto' 'Identidad'
    $destination = Join-Path (Split-Path -Parent $env:PREPARACION_BAT) $projectName
    if (Test-Path -LiteralPath $destination) {
        throw "La carpeta ya existe: $destination. Elige otro nombre de proyecto."
    }

    Write-Host ''
    Write-Host '  VERSIONES INSTALADAS' -ForegroundColor Yellow
    for ($index = 0; $index -lt $sdks.Count; $index++) {
        Write-Host "  $($index + 1)) .NET $($sdks[$index].Major) - SDK $($sdks[$index])" -ForegroundColor White
    }
    while ($true) {
        $choiceText = Read-Answer 'Selecciona una opcion' '1' 'Yellow'
        $choice = 0
        if ([int]::TryParse($choiceText, [ref]$choice) -and $choice -ge 1 -and $choice -le $sdks.Count) { break }
        Write-Host 'Selecciona un numero de la lista.' -ForegroundColor Yellow
    }
    $sdk = $sdks[$choice - 1]
    $framework = "net$($sdk.Major).0"

    Write-Host ''
    $domainSuffix = Read-Name 'Entidades y reglas. Nombrala' 'Domain' 'Magenta'
    $applicationSuffix = Read-Name 'Casos de uso y DTOs. Nombrala' 'Application' 'Cyan' @($domainSuffix)
    $infrastructureSuffix = Read-Name 'Base de datos y servicios externos. Nombrala' 'Infrastructure' 'Yellow' @($domainSuffix, $applicationSuffix)
    $apiSuffix = Read-Name 'API ejecutable. Nombrala' 'Api' 'Green' @($domainSuffix, $applicationSuffix, $infrastructureSuffix)
    $domain = "$projectName.$domainSuffix"
    $application = "$projectName.$applicationSuffix"
    $infrastructure = "$projectName.$infrastructureSuffix"
    $api = "$projectName.$apiSuffix"
    $projectNames = @($domain, $application, $infrastructure, $api)
    $referencePlan = @(
        @{ Source = $application; Targets = @($domain) },
        @{ Source = $infrastructure; Targets = @($application, $domain) },
        @{ Source = $api; Targets = @($application, $infrastructure) }
    )

    Write-Host ''
    Write-Host "Creando $projectName ($framework)..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $destination | Out-Null
    Push-Location -LiteralPath $destination
    try {
        Invoke-Dotnet -Arguments @('new', 'globaljson', '--sdk-version', [string]$sdk, '--roll-forward', 'latestPatch') | Out-Null
        foreach ($template in @('classlib', 'webapi')) {
            $helpText = (Invoke-Dotnet -Arguments @('new', $template, '--help')) -join [Environment]::NewLine
            if ($helpText -notmatch [regex]::Escape($framework)) {
                throw "El SDK $sdk no admite $framework en la plantilla $template."
            }
        }
        $solutionArguments = @('new', 'sln', '--name', $projectName)
        if ($sdk.Major -ge 10) { $solutionArguments += @('--format', 'sln') }
        Invoke-Dotnet -Arguments $solutionArguments | Out-Null

        $relativePaths = @{}
        foreach ($name in $projectNames) {
            $folder = "$projectName/$name"
            $template = if ($name -eq $api) { 'webapi' } else { 'classlib' }
            $createArguments = @('new', $template, '--name', $name, '--output', $folder, '--framework', $framework, '--no-restore')
            if ($template -eq 'webapi') { $createArguments += @('--use-controllers', '--no-openapi') }
            Invoke-Dotnet -Arguments $createArguments | Out-Null
            $relativePaths[$name] = "$folder/$name.csproj"
            Write-Host "  OK  $name" -ForegroundColor Green
        }
        $addArguments = @('sln', "$projectName.sln", 'add')
        foreach ($name in @($api, $domain, $application, $infrastructure)) { $addArguments += $relativePaths[$name] }
        Invoke-Dotnet -Arguments $addArguments | Out-Null

        foreach ($reference in $referencePlan) {
            $referenceArguments = @('add', $relativePaths[$reference.Source], 'reference')
            foreach ($target in $reference.Targets) { $referenceArguments += $relativePaths[$target] }
            Invoke-Dotnet -Arguments $referenceArguments | Out-Null
        }
        Write-Host '  OK  Dependencias configuradas' -ForegroundColor Green

        Write-Host '  Instalando Swagger...' -ForegroundColor Cyan
        Invoke-Dotnet -Arguments @('add', $relativePaths[$api], 'package', 'Swashbuckle.AspNetCore', '--version', '10.2.3', '--no-restore') | Out-Null
        $apiFolder = Split-Path -Parent (Join-Path $destination $relativePaths[$api])
        $program = @'
using Microsoft.OpenApi;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers();
builder.Services.AddSwaggerGen(options =>
{
    options.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "__PROJECT_NAME__ API",
        Version = "v1"
    });
});

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();
app.UseAuthorization();
app.MapControllers();

app.Run();
'@
        $program.Replace('__PROJECT_NAME__', $projectName) | Set-Content -LiteralPath (Join-Path $apiFolder 'Program.cs') -Encoding UTF8
        $launchPath = Join-Path $apiFolder 'Properties/launchSettings.json'
        $launchSettings = Get-Content -LiteralPath $launchPath -Raw | ConvertFrom-Json
        foreach ($profile in $launchSettings.profiles.PSObject.Properties) {
            $profile.Value | Add-Member -NotePropertyName 'launchBrowser' -NotePropertyValue $true -Force
            $profile.Value | Add-Member -NotePropertyName 'launchUrl' -NotePropertyValue 'swagger' -Force
        }
        $launchSettings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $launchPath -Encoding UTF8

        $apiRelativePath = $relativePaths[$api]
        $runnerUrl = $launchSettings.profiles.http.applicationUrl.Split(';')[0].TrimEnd('/')
        $windowsRunner = @'
@echo off
setlocal
set "RUNAPI_BAT=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$source = [IO.File]::ReadAllText($env:RUNAPI_BAT); $parts = [regex]::Split($source, '(?m)^# === RUNAPI POWERSHELL ===\r?$'); & ([scriptblock]::Create($parts[1]))"
set "resultado=%errorlevel%"
if not "%resultado%"=="0" pause
exit /b %resultado%

# === RUNAPI POWERSHELL ===
$ErrorActionPreference = 'Stop'
$browserJob = $null
try {
    Set-Location -LiteralPath (Split-Path -Parent $env:RUNAPI_BAT)
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'Instala el SDK de .NET para ejecutar la API.' }
    & dotnet --version
    if ($LASTEXITCODE -ne 0) { throw 'No esta disponible el SDK indicado en global.json.' }
    $project = '__API_PATH__'
    if (-not (Test-Path -LiteralPath $project)) { throw "No se encontro la API: $project" }
    $baseUrl = '__BASE_URL__'
    $env:ASPNETCORE_ENVIRONMENT = 'Development'
    $env:DOTNET_WATCH_SUPPRESS_LAUNCH_BROWSER = '1'
    $browserJob = Start-Job -ArgumentList $baseUrl, $env:RUNAPI_NO_BROWSER -ScriptBlock {
        param($baseUrl, $noBrowser)
        for ($attempt = 0; $attempt -lt 120; $attempt++) {
            $status = 0
            try {
                $response = Invoke-WebRequest -Uri "$baseUrl/swagger/index.html" -UseBasicParsing -TimeoutSec 1
                $status = [int]$response.StatusCode
            } catch {
                if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            }
            if ($status -gt 0) {
                $url = if ($status -ge 200 -and $status -lt 300) { "$baseUrl/swagger/index.html" } else { $baseUrl }
                Write-Output "Abrir: $url"
                if ($noBrowser -ne '1') {
                    try { Start-Process $url } catch { Write-Output "Abre manualmente: $url" }
                }
                return
            }
            Start-Sleep -Milliseconds 500
        }
        Write-Output "La API no respondio a tiempo. Revisa la consola; URL: $baseUrl"
    }
    Write-Host "API: $baseUrl | Ctrl+C para detener" -ForegroundColor Cyan
    $ErrorActionPreference = 'Continue'
    & dotnet watch --project $project run --no-launch-profile -- --urls $baseUrl
    $result = $LASTEXITCODE
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $result = 1
} finally {
    if ($browserJob) {
        Stop-Job $browserJob
        Receive-Job $browserJob
        Remove-Job $browserJob
    }
}
exit $result
'@
        $linuxRunner = @'
#!/usr/bin/env bash
set -e
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
command -v dotnet >/dev/null || { echo "Instala el SDK de .NET para ejecutar la API."; exit 1; }
dotnet --version || { echo "No esta disponible el SDK indicado en global.json."; exit 1; }
project="__API_PATH__"
[[ -f "$project" ]] || { echo "No se encontro la API: $project"; exit 1; }
base_url="__BASE_URL__"
export ASPNETCORE_ENVIRONMENT=Development
export DOTNET_WATCH_SUPPRESS_LAUNCH_BROWSER=1
open_browser() {
    if ! command -v curl >/dev/null; then
        echo "Instala curl para detectar Swagger. API: $base_url"
        return
    fi
    for ((attempt=0; attempt<120; attempt++)); do
        status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "$base_url/swagger/index.html") || status=000
        if [[ "$status" != 000 ]]; then
            url="$base_url"
            [[ "$status" == 2?? ]] && url="$base_url/swagger/index.html"
            echo "Abrir: $url"
            if [[ "${RUNAPI_NO_BROWSER:-0}" != 1 ]]; then
                if command -v xdg-open >/dev/null; then
                    xdg-open "$url" >/dev/null 2>&1 || echo "Abre manualmente: $url"
                elif command -v gio >/dev/null; then
                    gio open "$url" >/dev/null 2>&1 || echo "Abre manualmente: $url"
                else
                    echo "Abre manualmente: $url"
                fi
            fi
            return
        fi
        sleep 0.5
    done
    echo "La API no respondio a tiempo. Revisa la consola; URL: $base_url"
}
open_browser &
browser_pid=$!
cleanup() {
    if jobs -pr | grep -qx "$browser_pid"; then kill "$browser_pid" 2>/dev/null || true; fi
    wait "$browser_pid" 2>/dev/null || true
}
trap cleanup EXIT
echo "API: $base_url | Ctrl+C para detener"
dotnet watch --project "$project" run --no-launch-profile -- --urls "$base_url"
'@
        $windowsRunner = $windowsRunner.Replace('__API_PATH__', $apiRelativePath.Replace('/', '\')).Replace('__BASE_URL__', $runnerUrl)
        $linuxRunner = $linuxRunner.Replace('__API_PATH__', $apiRelativePath).Replace('__BASE_URL__', $runnerUrl)
        [System.IO.File]::WriteAllText((Join-Path $destination 'runAPI.bat'), (($windowsRunner -replace '\r?\n', "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
        [System.IO.File]::WriteAllText((Join-Path $destination 'runAPI.sh'), (($linuxRunner -replace '\r?\n', "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))

        Write-Host '  Compilando...' -ForegroundColor Cyan
        Invoke-Dotnet -Arguments @('build', "$projectName.sln", '--nologo') | Out-Null
        Write-Host '  OK  Swagger y compilacion' -ForegroundColor Green

        Write-Host ''
        Write-Host "Listo: $destination\$projectName.sln" -ForegroundColor Green
    } finally { Pop-Location }
    exit 0
} catch {
    Write-Host ''
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
