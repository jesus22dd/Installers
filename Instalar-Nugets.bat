@echo off
setlocal
set "INSTALAR_NUGETS_BAT=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$source = [IO.File]::ReadAllText($env:INSTALAR_NUGETS_BAT); $parts = [regex]::Split($source, '(?m)^# === POWERSHELL ===\r?$'); & ([scriptblock]::Create($parts[1]))"
set "resultado=%errorlevel%"
echo.
if /I not "%~1"=="--sin-pausa" pause
exit /b %resultado%

# === POWERSHELL ===
$ErrorActionPreference = 'Stop'
$nugetSource = 'https://api.nuget.org/v3/index.json'
$packageCache = @{}
$backups = @{}
$probeFolder = $null
$pushedLocation = $false
$changed = $false
$logPath = $null

function Read-Answer {
    param([string]$Label, [string]$Default, [string]$Color = 'Cyan')
    Write-Host "$Label [$Default]: " -ForegroundColor $Color -NoNewline
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim().Trim('"')
}

function Invoke-Dotnet {
    param([string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& dotnet @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($logPath) {
        ("dotnet " + ($Arguments -join ' ')) | Add-Content -LiteralPath $logPath -Encoding UTF8
        $output | ForEach-Object { [string]$_ } | Add-Content -LiteralPath $logPath -Encoding UTF8
    }
    if ($code -ne 0) {
        $details = ($output | Select-Object -Last 8 | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw ("Fallo dotnet " + ($Arguments -join ' ') + [Environment]::NewLine + $details)
    }
    return $output
}

function Find-Files {
    param([string]$Root, [string[]]$Extensions)
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory) {
            if ($item.PSIsContainer) {
                if ($item.Name -notin @('bin', 'obj', 'node_modules', 'packages', '.git', '.vs', '.next', '.config') -and
                    -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pending.Push($item.FullName) }
            } elseif ($item.Extension -in $Extensions) { $item }
        }
    }
}

function Select-Number {
    param([string]$Label, [int]$Count, [int]$Default = 1, [int[]]$Excluded = @(), [string]$Color = 'Cyan')
    while ($true) {
        $answer = Read-Answer $Label ([string]$Default) $Color
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Count -and $Excluded -notcontains $number) { return $number }
        Write-Host 'Elige un numero de la lista que no hayas usado para otra capa.' -ForegroundColor Yellow
    }
}

function Get-ProjectInfo {
    param([string]$Path)
    [xml]$xml = Get-Content -LiteralPath $Path -Raw
    $frameworks = @($xml.SelectNodes('/Project/PropertyGroup/TargetFramework') | ForEach-Object { $_.InnerText.Trim() } | Sort-Object -Unique)
    if ($xml.SelectNodes('/Project/PropertyGroup/TargetFrameworks').Count -gt 0 -or $frameworks.Count -ne 1) {
        throw "Este instalador necesita un solo TargetFramework explicito: $Path"
    }
    return [pscustomobject]@{
        Path = $Path
        Name = [IO.Path]::GetFileNameWithoutExtension($Path)
        Framework = $frameworks[0]
        Web = [string]$xml.Project.Sdk -match 'Microsoft.NET.Sdk.Web'
        Xml = $xml
    }
}

function Get-PackageVersions {
    param([string]$Id)
    $key = $Id.ToLowerInvariant()
    if (-not $packageCache.ContainsKey($key)) {
        try {
            $response = Invoke-RestMethod -Uri "https://api.nuget.org/v3-flatcontainer/$key/index.json" -TimeoutSec 30
            $packageCache[$key] = @($response.versions | Where-Object { $_ -match '^\d+\.\d+\.\d+$' })
        } catch { throw "No se pudo consultar $Id en NuGet.org. Revisa Internet. $($_.Exception.Message)" }
    }
    return $packageCache[$key]
}

function Read-PackageVersion {
    param([string]$Label, [string[]]$Allowed)
    if ($Allowed.Count -eq 0) { throw "No hay versiones estables disponibles para $Label." }
    $latest = [string]($Allowed | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
    $answer = Read-Answer $Label $latest 'Yellow'
    if ($Allowed -notcontains $answer) { throw "Version no disponible o incompatible para $Label`: $answer. Recomendacion: $latest" }
    return $answer
}

function Save-Backup {
    param([string]$Path)
    if (-not $backups.ContainsKey($Path)) {
        $backups[$Path] = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllBytes($Path) } else { $null }
    }
}

function Get-LatestVersion {
    param([string]$Id, [int]$Major = 0)
    $versions = @(Get-PackageVersions $Id)
    if ($Major -gt 0) { $versions = @($versions | Where-Object { $_ -match "^$Major\." }) }
    if ($versions.Count -eq 0) { throw "No hay version estable disponible para $Id (linea $Major)." }
    return [string]($versions | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
}

function Set-ReferenceMetadata {
    param([string]$ProjectPath, [string]$Id, [string]$PrivateAssets, [string]$ExcludeAssets)
    [xml]$xml = Get-Content -LiteralPath $ProjectPath -Raw
    $reference = $xml.SelectSingleNode('/Project/ItemGroup/PackageReference[@Include="' + $Id + '"]')
    foreach ($setting in @(@{ Name = 'PrivateAssets'; Value = $PrivateAssets }, @{ Name = 'ExcludeAssets'; Value = $ExcludeAssets })) {
        if (-not $setting.Value) { continue }
        if ($reference.HasAttribute($setting.Name)) { $reference.SetAttribute($setting.Name, $setting.Value) }
        else {
            $node = $reference.SelectSingleNode($setting.Name)
            if (-not $node) { $node = $xml.CreateElement($setting.Name); $null = $reference.AppendChild($node) }
            $node.InnerText = $setting.Value
        }
    }
    $xml.Save($ProjectPath)
}

try {
    Write-Host ''
    Write-Host '  NUGETS - BACKEND COMPLETO' -ForegroundColor Cyan
    Write-Host ''
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'Instala el SDK de .NET y vuelve a abrir la consola.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $inputPath = Read-Answer 'Carpeta o solucion (.sln / .slnx)' (Split-Path -Parent $env:INSTALAR_NUGETS_BAT)
    $item = Get-Item -LiteralPath $inputPath
    $solution = $null
    if ($item.PSIsContainer) {
        $root = $item.FullName
        $solutions = @(Find-Files $root @('.sln', '.slnx') | Sort-Object FullName)
        if ($solutions.Count -gt 0) {
            Write-Host ''
            Write-Host '  SOLUCIONES' -ForegroundColor Yellow
            for ($index = 0; $index -lt $solutions.Count; $index++) { Write-Host "  $($index + 1)) $($solutions[$index].FullName)" }
            $solutionIndex = Select-Number 'Solucion' $solutions.Count
            $solution = $solutions[$solutionIndex - 1].FullName
            $root = Split-Path -Parent $solution
        }
    } elseif ($item.Extension -in @('.sln', '.slnx')) {
        $solution = $item.FullName
        $root = $item.DirectoryName
    } else { throw 'Introduce una carpeta que contenga tus proyectos, o un archivo .sln / .slnx.' }

    Push-Location -LiteralPath $root
    $pushedLocation = $true
    $sdkText = (Invoke-Dotnet -Arguments @('--version') | Select-Object -Last 1).ToString().Trim()
    if ($sdkText -notmatch '^\d+\.\d+\.\d+') { throw 'No se pudo determinar el SDK seleccionado.' }
    $sdkMajor = [int]($sdkText.Split('.')[0])

    if ($solution) {
        $lines = @(Invoke-Dotnet -Arguments @('sln', $solution, 'list'))
        $projectPaths = @($lines | ForEach-Object {
            $relative = ([string]$_).Trim()
            if ($relative -match '\.csproj$') { [IO.Path]::GetFullPath((Join-Path $root $relative)) }
        })
    } else { $projectPaths = @(Find-Files $root @('.csproj') | Sort-Object FullName | ForEach-Object { $_.FullName }) }
    if ($projectPaths.Count -lt 3) { throw 'Necesitas los tres proyectos separados: API, infraestructura y aplicacion. Selecciona su carpeta comun o su solucion.' }
    $projects = @($projectPaths | ForEach-Object { Get-ProjectInfo $_ })
    Write-Host ''
    Write-Host '  PROYECTOS' -ForegroundColor Cyan
    for ($index = 0; $index -lt $projects.Count; $index++) { Write-Host "  $($index + 1)) $($projects[$index].Name) - $($projects[$index].Framework)" }

    $apiDefault = 1
    for ($index = 0; $index -lt $projects.Count; $index++) { if ($projects[$index].Web) { $apiDefault = $index + 1; break } }
    $apiIndex = Select-Number 'API ejecutable' $projects.Count $apiDefault @() 'Green'
    $infraDefault = (1..$projects.Count | Where-Object { $_ -ne $apiIndex } | Select-Object -First 1)
    for ($index = 0; $index -lt $projects.Count; $index++) { if ($index + 1 -ne $apiIndex -and $projects[$index].Name -match '(?i)\.(infra|infrastructure|infraestructura)$') { $infraDefault = $index + 1; break } }
    $infraIndex = Select-Number 'Base de datos / infraestructura' $projects.Count $infraDefault @($apiIndex) 'Yellow'
    $appDefault = (1..$projects.Count | Where-Object { $_ -notin @($apiIndex, $infraIndex) } | Select-Object -First 1)
    for ($index = 0; $index -lt $projects.Count; $index++) { if ($index + 1 -notin @($apiIndex, $infraIndex) -and $projects[$index].Name -match '(?i)\.(application|aplicacion)$') { $appDefault = $index + 1; break } }
    $appIndex = Select-Number 'Casos de uso / aplicacion' $projects.Count $appDefault @($apiIndex, $infraIndex) 'Cyan'
    $api = $projects[$apiIndex - 1]
    $infra = $projects[$infraIndex - 1]
    $app = $projects[$appIndex - 1]
    if (-not $api.Web) { throw 'La API seleccionada debe utilizar Microsoft.NET.Sdk.Web.' }
    if ($api.Framework -notmatch '^net(8|9|10)\.0$') { throw 'Este instalador admite proyectos net8.0, net9.0 y net10.0.' }
    $detectedMajor = [int]$Matches[1]
    $majorText = Read-Answer 'Version .NET del proyecto' ([string]$detectedMajor) 'Yellow'
    if ($majorText -notin @('8', '9', '10') -or [int]$majorText -ne $detectedMajor) { throw "La API utiliza $($api.Framework). La version indicada no coincide; no se cambia el framework." }
    $major = [int]$majorText
    $framework = "net$major.0"
    foreach ($project in @($api, $infra, $app)) {
        if ($project.Framework -ne $framework) { throw "Las tres capas deben usar $framework. $($project.Name) utiliza $($project.Framework)." }
        $ancestor = Split-Path -Parent $project.Path
        while ($ancestor) {
            if (Test-Path -LiteralPath (Join-Path $ancestor 'Directory.Packages.props')) { throw 'Este instalador utiliza PackageReference por proyecto. Detecto Directory.Packages.props; la gestion centralizada necesita su propio flujo.' }
            $parent = Split-Path -Parent $ancestor
            if ($parent -eq $ancestor) { break }
            $ancestor = $parent
        }
    }
    if ($sdkMajor -lt $major) { throw "El SDK seleccionado ($sdkText) no puede compilar $framework. Revisa global.json y tus SDK instalados." }
    $runtimes = @(Invoke-Dotnet -Arguments @('--list-runtimes'))
    foreach ($runtime in @('Microsoft.NETCore.App', 'Microsoft.AspNetCore.App')) {
        $runtimePattern = '^' + [regex]::Escape($runtime) + " $major\.0\."
        if (-not ($runtimes | Where-Object { [string]$_ -match $runtimePattern })) { throw "Falta el runtime $runtime $major. Instala el SDK completo de .NET $major antes de continuar." }
    }

    Write-Host ''
    Write-Host 'Consultando versiones estables en NuGet.org...' -ForegroundColor Cyan
    $microsoftIds = @('Microsoft.AspNetCore.Identity.EntityFrameworkCore', 'Microsoft.EntityFrameworkCore.SqlServer', 'Microsoft.EntityFrameworkCore.Design', 'Microsoft.AspNetCore.Authentication.JwtBearer', 'dotnet-ef', 'Microsoft.EntityFrameworkCore.Tools', 'Microsoft.AspNetCore.DataProtection')
    $commonVersions = @(Get-PackageVersions $microsoftIds[0] | Where-Object { $_ -match "^$major\." })
    foreach ($id in $microsoftIds | Select-Object -Skip 1) {
        $available = @(Get-PackageVersions $id)
        $commonVersions = @($commonVersions | Where-Object { $available -contains $_ })
    }
    $microsoftVersion = Read-PackageVersion "Identity / EF / JWT (.NET $major)" $commonVersions
    $postgresVersion = Read-PackageVersion "PostgreSQL / Supabase (EF $major)" @(Get-PackageVersions 'Npgsql.EntityFrameworkCore.PostgreSQL' | Where-Object { $_ -match "^$major\." })
    $fluentVersions = @(Get-PackageVersions 'FluentValidation' | Where-Object { $_ -match '^12\.' })
    $fluentDiVersions = @(Get-PackageVersions 'FluentValidation.DependencyInjectionExtensions')
    $fluentVersion = Read-PackageVersion 'FluentValidation' @($fluentVersions | Where-Object { $fluentDiVersions -contains $_ })

    $plan = @(
        @{ Project = $infra; Id = $microsoftIds[0]; Version = $microsoftVersion },
        @{ Project = $infra; Id = $microsoftIds[1]; Version = $microsoftVersion },
        @{ Project = $infra; Id = 'Npgsql.EntityFrameworkCore.PostgreSQL'; Version = $postgresVersion },
        @{ Project = $app; Id = 'FluentValidation'; Version = $fluentVersion },
        @{ Project = $api; Id = 'FluentValidation.DependencyInjectionExtensions'; Version = $fluentVersion },
        @{ Project = $api; Id = $microsoftIds[2]; Version = $microsoftVersion },
        @{ Project = $api; Id = $microsoftIds[3]; Version = $microsoftVersion },
        @{ Project = $api; Id = 'Microsoft.EntityFrameworkCore.Tools'; Version = $microsoftVersion; PrivateAssets = 'all' },
        @{ Project = $infra; Id = 'Microsoft.AspNetCore.DataProtection'; Version = $microsoftVersion }
    )
    $extraPackages = @(
        @{ Project = $app; Id = 'AutoMapper' },
        @{ Project = $app; Id = 'Riok.Mapperly'; PrivateAssets = 'all'; ExcludeAssets = 'runtime' },
        @{ Project = $infra; Id = 'Microsoft.Extensions.Caching.Hybrid'; Major = 10 },
        @{ Project = $infra; Id = 'Microsoft.Extensions.Caching.StackExchangeRedis'; Major = 10 },
        @{ Project = $infra; Id = 'Azure.Storage.Blobs' },
        @{ Project = $infra; Id = 'Supabase' },
        @{ Project = $infra; Id = 'Konscious.Security.Cryptography.Argon2' },
        @{ Project = $infra; Id = 'System.IdentityModel.Tokens.Jwt' },
        @{ Project = $api; Id = 'OpenTelemetry.Extensions.Hosting' },
        @{ Project = $api; Id = 'OpenTelemetry.Instrumentation.AspNetCore' },
        @{ Project = $api; Id = 'OpenTelemetry.Instrumentation.Http' },
        @{ Project = $api; Id = 'OpenTelemetry.Exporter.OpenTelemetryProtocol' }
    )
    $manualExtras = Read-Answer 'Versiones adicionales: 1 automaticas, 2 manuales' '1' 'Yellow'
    if ($manualExtras -notin @('1', '2')) { throw 'Elige 1 o 2 para las versiones adicionales.' }
    foreach ($entry in $extraPackages) {
        $version = Get-LatestVersion $entry.Id ([int]$entry.Major)
        if ($manualExtras -eq '2') {
            $allowed = @(Get-PackageVersions $entry.Id)
            if ($entry.Major) { $allowed = @($allowed | Where-Object { $_ -match ('^' + $entry.Major + '\.') }) }
            $version = Read-PackageVersion $entry.Id $allowed
        }
        $entry.Version = $version
        $plan += $entry
    }
    $existingSwagger = $api.Xml.SelectSingleNode('/Project/ItemGroup/PackageReference[@Include="Swashbuckle.AspNetCore"]')
    if (-not $existingSwagger) {
        $swaggerVersion = Read-PackageVersion 'Swagger' @(Get-PackageVersions 'Swashbuckle.AspNetCore' | Where-Object { $_ -match '^10\.' })
        $plan += @{ Project = $api; Id = 'Swashbuckle.AspNetCore'; Version = $swaggerVersion }
    }

    $logPath = Join-Path $root 'Instalar-Nugets.log'
    "SDK $sdkText | $framework" | Set-Content -LiteralPath $logPath -Encoding UTF8
    Write-Host ''
    Write-Host '  PAQUETES' -ForegroundColor Yellow
    foreach ($entry in $plan) { Write-Host "  $($entry.Project.Name): $($entry.Id) $($entry.Version)" }
    if ($existingSwagger) { Write-Host '  Swagger ya instalado: se conserva.' -ForegroundColor Green }
    Write-Host "  Herramienta local: dotnet-ef $microsoftVersion"
    Write-Host '  Bases de datos: SQL Server y PostgreSQL (Supabase).' -ForegroundColor Cyan
    Write-Host '  AES-GCM, SHA y HMAC: incluidos en .NET, sin otro NuGet.' -ForegroundColor Cyan
    Write-Host '  AutoMapper: revisar la licencia al configurarlo.' -ForegroundColor Yellow

    Write-Host ''
    Write-Host 'Validando compatibilidad antes de modificar proyectos...' -ForegroundColor Cyan
    $probeFolder = Join-Path ([IO.Path]::GetTempPath()) ('InstalarNugets-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probeFolder | Out-Null
    foreach ($roleProject in @($infra, $app, $api)) {
        $roleFolder = Join-Path $probeFolder $roleProject.Name
        New-Item -ItemType Directory -Path $roleFolder | Out-Null
        $probeReferences = ($plan | Where-Object { $_.Project.Path -eq $roleProject.Path } | ForEach-Object { '<PackageReference Include="' + $_.Id + '" Version="' + $_.Version + '" />' }) -join [Environment]::NewLine
        $probeProject = '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>' + $framework + '</TargetFramework></PropertyGroup><ItemGroup>' + $probeReferences + '</ItemGroup></Project>'
        $probePath = Join-Path $roleFolder 'Compatibilidad.csproj'
        [IO.File]::WriteAllText($probePath, $probeProject, [Text.UTF8Encoding]::new($false))
        Invoke-Dotnet -Arguments @('restore', $probePath, '--source', $nugetSource, '--verbosity', 'quiet') | Out-Null
        if ($roleProject.Path -eq $app.Path) {
            $mapperProbe = 'public class Source { public int Id { get; set; } } public class Destination { public int Id { get; set; } } [Riok.Mapperly.Abstractions.Mapper] public partial class CompatibilityMapper { public partial Destination Map(Source source); }'
            [IO.File]::WriteAllText((Join-Path $roleFolder 'MapperProbe.cs'), $mapperProbe, [Text.UTF8Encoding]::new($false))
            Invoke-Dotnet -Arguments @('build', $probePath, '--no-restore', '--nologo', '--verbosity', 'quiet', '-warnaserror:CS9057') | Out-Null
        }
    }

    foreach ($project in @($api, $infra, $app)) { Save-Backup $project.Path }
    $rootManifestPath = Join-Path $root 'dotnet-tools.json'
    $configManifestPath = Join-Path $root '.config/dotnet-tools.json'
    if ((Test-Path -LiteralPath $rootManifestPath) -and (Test-Path -LiteralPath $configManifestPath)) { throw 'Hay dos manifiestos locales de herramientas en esta carpeta. Conserva uno antes de continuar.' }
    $manifestPath = if (Test-Path -LiteralPath $rootManifestPath) { $rootManifestPath } else { $configManifestPath }
    Save-Backup $manifestPath
    $changed = $true
    foreach ($entry in $plan) {
        [xml]$current = Get-Content -LiteralPath $entry.Project.Path -Raw
        $reference = $current.SelectSingleNode('/Project/ItemGroup/PackageReference[@Include="' + $entry.Id + '"]')
        $installedVersion = if ($reference) { [string]$reference.GetAttribute('Version') } else { '' }
        if ($installedVersion -ne $entry.Version) {
            Invoke-Dotnet -Arguments @('add', $entry.Project.Path, 'package', $entry.Id, '--version', $entry.Version, '--no-restore') | Out-Null
        }
        if ($entry.Id -eq 'Microsoft.EntityFrameworkCore.Design') { $entry.PrivateAssets = 'all' }
        if ($entry.PrivateAssets -or $entry.ExcludeAssets) { Set-ReferenceMetadata $entry.Project.Path $entry.Id $entry.PrivateAssets $entry.ExcludeAssets }
        Write-Host "  OK  $($entry.Id)" -ForegroundColor Green
    }

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        $manifestFolder = Split-Path -Parent $manifestPath
        if (-not (Test-Path -LiteralPath $manifestFolder)) { New-Item -ItemType Directory -Path $manifestFolder | Out-Null }
        [IO.File]::WriteAllText($manifestPath, '{"version":1,"isRoot":true,"tools":{}}', [Text.UTF8Encoding]::new($false))
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $existingTool = $manifest.tools.PSObject.Properties['dotnet-ef']
    if ($existingTool -and $existingTool.Value.version -eq $microsoftVersion) {
        Invoke-Dotnet -Arguments @('tool', 'restore', '--tool-manifest', $manifestPath) | Out-Null
    } else {
        if ($existingTool) { Invoke-Dotnet -Arguments @('tool', 'uninstall', 'dotnet-ef', '--tool-manifest', $manifestPath) | Out-Null }
        Invoke-Dotnet -Arguments @('tool', 'install', 'dotnet-ef', '--tool-manifest', $manifestPath, '--version', $microsoftVersion, '--add-source', $nugetSource) | Out-Null
    }
    Write-Host '  OK  dotnet-ef local' -ForegroundColor Green

    Write-Host 'Restaurando y compilando...' -ForegroundColor Cyan
    $buildTargets = if ($solution) { @($solution) } else { @($api.Path, $infra.Path, $app.Path) }
    foreach ($target in $buildTargets) {
        Invoke-Dotnet -Arguments @('restore', $target, '--verbosity', 'quiet') | Out-Null
        Invoke-Dotnet -Arguments @('build', $target, '--no-restore', '--nologo', '--verbosity', 'quiet') | Out-Null
    }
    Invoke-Dotnet -Arguments @('tool', 'run', 'dotnet-ef', '--', '--version') | Out-Null
    $changed = $false
    Write-Host ''
    Write-Host 'Listo: paquetes instalados y compilacion correcta.' -ForegroundColor Green
} catch {
    if ($changed) {
        foreach ($path in $backups.Keys) {
            if ($null -eq $backups[$path]) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
            } else { [IO.File]::WriteAllBytes($path, $backups[$path]) }
        }
        Write-Host 'Se restauraron proyectos y manifiesto anteriores.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    if ($logPath) { Write-Host "Detalle: $logPath" -ForegroundColor Yellow }
    $failed = $true
} finally {
    if ($pushedLocation) { Pop-Location }
    if ($probeFolder -and (Test-Path -LiteralPath $probeFolder)) {
        $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $resolvedProbe = (Resolve-Path -LiteralPath $probeFolder).Path
        if ((Split-Path -Parent $resolvedProbe).TrimEnd('\') -eq $expectedParent -and (Split-Path -Leaf $resolvedProbe) -match '^InstalarNugets-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $resolvedProbe -Recurse -Force
        }
    }
}
if ($failed) { exit 1 }
exit 0
