# Copyright (c) Microsoft. All rights reserved.

$ErrorActionPreference = "Stop"
$script:ScriptFailedCommands = @()
$script:ScriptFailed = $false

#
# Git Branch
#
$TPB_BRANCH = "LOCALBRANCH"
$TPB_COMMIT = "LOCALBUILD"

try {
    $TPB_BRANCH = $env:BUILD_SOURCEBRANCH -replace "^refs/heads/"  
    if ([string]::IsNullOrWhiteSpace($TPB_BRANCH)) { 
        $TPB_BRANCH = git -C "." rev-parse --abbrev-ref HEAD
    }
}
catch { }

try {
    $TPB_COMMIT = $env:BUILD_SOURCEVERSION
    if ([string]::IsNullOrWhiteSpace($TPB_COMMIT)) { 
        $TPB_COMMIT = git -C "." rev-parse HEAD
    }
}
catch { }

#
# Variables
#
Write-Verbose "Setup environment variables."
$CurrentScriptDir = (Get-Item (Split-Path $MyInvocation.MyCommand.Path))
$env:TP_ROOT_DIR = $CurrentScriptDir.Parent.FullName
$env:TP_TOOLS_DIR = Join-Path $env:TP_ROOT_DIR "tools"
$env:TP_PACKAGES_DIR = Join-Path $env:TP_ROOT_DIR "packages"
$env:TP_OUT_DIR = Join-Path $env:TP_ROOT_DIR "artifacts"
$env:TP_TESTARTIFACTS = Join-Path $env:TP_OUT_DIR "testArtifacts"
$env:TP_PACKAGE_PROJ_DIR = Join-Path $env:TP_ROOT_DIR "src\package"
$GlobalJson = Get-Content -Raw -Path (Join-Path $env:TP_ROOT_DIR 'global.json') | ConvertFrom-Json

#
# Dotnet configuration
#
# Disable first run since we want to control all package sources 
Write-Verbose "Setup dotnet configuration."
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = 1 
# Dotnet build doesn't support --packages yet. See https://github.com/dotnet/cli/issues/2712
$env:NUGET_PACKAGES = $env:TP_PACKAGES_DIR
$env:NUGET_EXE_Version = "5.8.1"
$env:DOTNET_CLI_VERSION = $GlobalJson.tools.dotnet
# $env:DOTNET_RUNTIME_VERSION = "LATEST"
$env:VSWHERE_VERSION = "2.0.2"
$env:MSBUILD_VERSION = "15.0"

function Write-Log {
    param (
        [string] $message,
        [ValidateSet("Success", "Error")]
        [string]
        $Level = "Success"
    )
    
    $currentColor = $Host.UI.RawUI.ForegroundColor
    try {
        $Host.UI.RawUI.ForegroundColor = if ("Success" -eq $Level) { "Green" } else { "Red" }
        if ($message)
        {
            Write-Output "... $message"
        }
    }
    finally {
        $Host.UI.RawUI.ForegroundColor = $currentColor
    }
}

function Write-VerboseLog([string] $message)
{
    Write-Verbose $message
}

function Remove-Tools
{
}

function Install-DotNetCli
{
    $timer = Start-Timer
    Write-Log "Install-DotNetCli: Get dotnet-install.ps1 script..."
    $dotnetInstallRemoteScript = "https://raw.githubusercontent.com/dotnet/install-scripts/main/src/dotnet-install.ps1"
    $dotnetInstallScript = Join-Path $env:TP_TOOLS_DIR "dotnet-install.ps1"
    if (-not (Test-Path $env:TP_TOOLS_DIR)) {
        New-Item $env:TP_TOOLS_DIR -Type Directory | Out-Null
    }

    $dotnet_dir= Join-Path $env:TP_TOOLS_DIR "dotnet"

    if (-not (Test-Path $dotnet_dir)) {
        New-Item $dotnet_dir -Type Directory | Out-Null
    }

    (New-Object System.Net.WebClient).DownloadFile($dotnetInstallRemoteScript, $dotnetInstallScript)

    if (-not (Test-Path $dotnetInstallScript)) {
        Write-Error "Failed to download dotnet install script."
    }

    Unblock-File $dotnetInstallScript

    Write-Log "Install-DotNetCli: Get the latest dotnet cli toolset..."
    $dotnetInstallPath = Join-Path $env:TP_TOOLS_DIR "dotnet"
    New-Item -ItemType directory -Path $dotnetInstallPath -Force | Out-Null
    & $dotnetInstallScript -Channel 6.0 -Quality Preview -InstallDir $dotnetInstallPath -Version $env:DOTNET_CLI_VERSION
    
    & $dotnetInstallScript -InstallDir "$dotnetInstallPath" -Runtime 'dotnet' -Version '2.1.30' -Channel '2.1' -Architecture x64 -NoPath
    $env:DOTNET_ROOT= $dotnetInstallPath

    & $dotnetInstallScript -InstallDir "${dotnetInstallPath}_x86" -Runtime 'dotnet' -Version '2.1.30' -Channel '2.1' -Architecture x86 -NoPath
    ${env:DOTNET_ROOT(x86)} = "${dotnetInstallPath}_x86"
    
    & $dotnetInstallScript -InstallDir "$dotnetInstallPath" -Runtime 'dotnet' -Version '3.1.22' -Channel '3.1' -Architecture x64 -NoPath
    $env:DOTNET_ROOT= $dotnetInstallPath

    & $dotnetInstallScript -InstallDir "${dotnetInstallPath}_x86" -Runtime 'dotnet' -Version '3.1.22' -Channel '3.1' -Architecture x86 -NoPath
    ${env:DOTNET_ROOT(x86)} = "${dotnetInstallPath}_x86"

    & $dotnetInstallScript -InstallDir "$dotnetInstallPath" -Runtime 'dotnet' -Version '5.0.10' -Channel '5.0' -Architecture x64 -NoPath
    $env:DOTNET_ROOT= $dotnetInstallPath

    & $dotnetInstallScript -InstallDir "${dotnetInstallPath}_x86" -Runtime 'dotnet' -Version '5.0.10' -Channel '5.0' -Architecture x86 -NoPath
    ${env:DOTNET_ROOT(x86)} = "${dotnetInstallPath}_x86"

    $env:DOTNET_MULTILEVEL_LOOKUP=0

    "---- dotnet environment variables"
    Get-ChildItem "Env:\dotnet_*"
    
    "`n`n---- x64 dotnet"
    Invoke-Exe "$env:DOTNET_ROOT\dotnet.exe" "--info"

    "`n`n---- x86 dotnet"
    # avoid erroring out because we don't have the sdk for x86 that global.json requires
    try {
        Invoke-Exe "${env:DOTNET_ROOT(x86)}\dotnet.exe" "--info" 2> $null
    } catch {}
    Write-Log "Install-DotNetCli: Complete. {$(Get-ElapsedTime($timer))}"
}

function Clear-Package {
    # find all microsoft packages that have the same version as we specified
    # this is cache-busting the nuget packages, so we don't reuse them from cache 
    # after we built new ones
    if (Test-Path $env:TP_PACKAGES_DIR) {
        $devPackages = Get-ChildItem $env:TP_PACKAGES_DIR/microsoft.*/$TPB_Version | Select-Object -ExpandProperty FullName 
        $devPackages | Remove-Item -Force -Recurse -Confirm:$false
    }
}

function Restore-Package
{
    $timer = Start-Timer
    Write-Log "Restore-Package: Start restoring packages to $env:TP_PACKAGES_DIR."
    $dotnetExe = Get-DotNetPath

    Write-Log ".. .. Restore-Package: Source: $env:TP_ROOT_DIR\src\package\external\external.csproj"
    Invoke-Exe $dotnetExe "restore $env:TP_ROOT_DIR\src\package\external\external.csproj --packages $env:TP_PACKAGES_DIR -v:minimal -warnaserror -p:Version=$TPB_Version -bl:""$env:TP_OUT_DIR\log\$Configuration\external.binlog"""
    Write-Log ".. .. Restore-Package: Complete."
    Write-Log "Restore-Package: Complete. {$(Get-ElapsedTime($timer))}"
}

function Copy-Bulk {
    param (
        [string]$root,
        [hashtable]$files
    )
    
    $files.GetEnumerator() | ForEach-Object {
        $from = Join-Path $root $_.Name
        $to = $_.Value
          
        New-Item -ItemType directory -Path "$to\" -Force | Out-Null
        Copy-Item "$from\*" $to -Force -Recurse
    }
}
function Start-Timer
{
    return [System.Diagnostics.Stopwatch]::StartNew()
}

function Get-ElapsedTime([System.Diagnostics.Stopwatch] $timer)
{
    $timer.Stop()
    return $timer.Elapsed
}

function Set-ScriptFailedOnError
{
    param ($Command, $Arguments)
    if ($lastExitCode -eq 0) {
        return
    }

    if ($FailFast -eq $true) {
        Write-Error "Build failed. Stopping as fail fast is set.`nFailed command: $Command $Arguments`nExit code: $LASTEXITCODE"
    }

    $script:ScriptFailedCommands += "$Command $Arguments"
    $Script:ScriptFailed = $true
}

function PrintAndExit-OnError([System.String] $output)
{
    if ($? -eq $false){
        Write-Error $output
        Exit 1
    }
}

function Invoke-Exe {
    param (
        [Parameter(Mandatory)]
        [string] $Command,
        [string] $Arguments,
        [int[]] $IgnoreExitCode
    )
    Write-Verbose "Invoking: $Command $Arguments"
    & $Command ($Arguments -split ' ')
    if ($IgnoreExitCode -notcontains $LASTEXITCODE) {
        Set-ScriptFailedOnError -Command $Command -Arguments $Arguments
    }
}