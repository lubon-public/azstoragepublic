#https://github.com/Azure/avdaccelerator/blob/main/workload/scripts/DSCStorageScripts/1.0.3/Script-DomainJoinStorage.ps1
# Script can be run interactively or as a scheduled task

param(
    [string]$clientId,
    [string]$subscriptionId,
    [string]$storageAccountName,
    [string]$resourceGroupName,
    [string]$storageAccountOuPath = "",
    [string]$isFslogixDeployment,
    [string]$fslogixShareName,
    [string]$fslogixADGroupName,
    [string]$ADAdmingroup = "",
    # Scheduled task registration
    [switch]$RegisterScheduledTask,
    [string]$TaskName = "DomainJoinStorage",
    [string]$domainJoinUsername = "",
    [string]$domainJoinPassword = ""
)

# Setup logging
$logDir = "C:\Logs\StorageAccountSetup"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logFile = Join-Path $logDir "Script-DomainJoinStorage_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $logFile -Append | Out-Null

function Write-LogOutput {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $output = "[$timestamp] $Message"
    Write-Host $output
}

function Register-StorageScheduledTask {
    param(
        [string]$ScriptPath = $MyInvocation.ScriptName,
        [string]$TaskName = "DomainJoinStorage",
        [string]$TaskDescription = "Setup FSLogix storage account domain join and permissions",
        [string]$domainJoinUsername = "",
        [string]$domainJoinPassword = "",
        [string]$ClientId = "",
        [string]$SubscriptionId = "",
        [string]$StorageAccountName = "",
        [string]$ResourceGroupName = "",
        [string]$StorageAccountOuPath = "",
        [string]$IsFslogixDeployment = "",
        [string]$FslogixShareName = "",
        [string]$FslogixADGroupName = "",
        [string]$ADAdmingroup = ""
    )

    if (-not (Test-Path $ScriptPath)) {
        Write-LogOutput "ERROR: Script not found at $ScriptPath"
        return $false
    }

    if ([string]::IsNullOrEmpty($domainJoinUsername) -or [string]::IsNullOrEmpty($domainJoinPassword)) {
        Write-LogOutput "ERROR: domainJoinUsername and domainJoinPassword are required (task must run as a domain user)."
        return $false
    }

    Write-LogOutput "Creating scheduled task '$TaskName'..."
    $ErrorActionPreference = "Stop"

    $scriptArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`"" +
        " -clientId `"$ClientId`"" +
        " -subscriptionId `"$SubscriptionId`"" +
        " -storageAccountName `"$StorageAccountName`"" +
        " -resourceGroupName `"$ResourceGroupName`"" +
        " -isFslogixDeployment `"$IsFslogixDeployment`"" +
        " -fslogixShareName `"$FslogixShareName`"" +
        " -fslogixADGroupName `"$FslogixADGroupName`"" +
        " -ADAdmingroup `"$ADAdmingroup`"" +
        $(if ($StorageAccountOuPath) { " -storageAccountOuPath `"$StorageAccountOuPath`"" } else { "" })

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $scriptArgs

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RunOnlyIfNetworkAvailable -StartWhenAvailable -MultipleInstances IgnoreNew

    $principal = New-ScheduledTaskPrincipal -UserId $domainJoinUsername -RunLevel Highest

    try {
        Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $action `
            -Settings $settings `
            -Description $TaskDescription `
            -User $domainJoinUsername `
            -Password $domainJoinPassword `
            -RunLevel Highest `
            -Force | Out-Null

        Write-LogOutput "Scheduled task '$TaskName' created successfully (manual trigger - run via Run Command)"
        Write-LogOutput "  Run As  : $domainJoinUsername"
        Write-LogOutput "  Script  : $ScriptPath"
        Write-LogOutput "  Logs    : C:\Logs\StorageAccountSetup\"
        return $true
    } catch {
        Write-LogOutput "ERROR: Failed to create scheduled task: $_"
        return $false
    }
}

# If -RegisterScheduledTask is specified, register the task and exit
if ($RegisterScheduledTask) {
    $scriptFullPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $PSCommandPath }
    Write-LogOutput "Script path resolved to: $scriptFullPath"
    $result = Register-StorageScheduledTask `
        -ScriptPath $scriptFullPath `
        -TaskName $TaskName `
        -domainJoinUsername $domainJoinUsername `
        -domainJoinPassword $domainJoinPassword `
        -ClientId $clientId `
        -SubscriptionId $subscriptionId `
        -StorageAccountName $storageAccountName `
        -ResourceGroupName $resourceGroupName `
        -StorageAccountOuPath $storageAccountOuPath `
        -IsFslogixDeployment $isFslogixDeployment `
        -FslogixShareName $fslogixShareName `
        -FslogixADGroupName $fslogixADGroupName `
        -ADAdmingroup $ADAdmingroup
    Stop-Transcript
    exit $(if ($result) { 0 } else { 1 })
}

# Validate required parameters
$requiredParams = @('clientId', 'subscriptionId', 'storageAccountName', 'resourceGroupName', 'isFslogixDeployment')
foreach ($param in $requiredParams) {
    if ([string]::IsNullOrEmpty((Get-Variable -Name $param).Value)) {
        Write-LogOutput "ERROR: Required parameter '$param' is not provided."
        Stop-Transcript
        exit 1
    }
}

Write-LogOutput "Script execution started"
Write-LogOutput "Parameters: StorageAccount=$storageAccountName, ResourceGroup=$resourceGroupName, FSLogix=$isFslogixDeployment"

$ErrorActionPreference = "Stop"
try {
    Write-LogOutput "Installing RSAT AD PowerShell tools..."
    Install-WindowsFeature -Name RSAT-AD-PowerShell -IncludeAllSubFeature | Out-Null

    Write-LogOutput "Installing NuGet provider..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null

    Write-LogOutput "Installing AzFilesHybrid module..."
    Install-Module -Name AzFilesHybrid -Force -AllowClobber | Out-Null

    Write-LogOutput "Importing AzFilesHybrid module..."
    Import-Module -Name AzFilesHybrid -Force

    Write-LogOutput "Connecting to Azure with managed identity..."
    Connect-AzAccount -Identity -AccountId $clientId | Out-Null

    Write-LogOutput "Selecting subscription $subscriptionId..."
    Select-AzSubscription -SubscriptionId $subscriptionId | Out-Null

    Write-LogOutput "Domain joining storage account $storageAccountName in resource group $resourceGroupName..."
    
    $joinParams = @{
        ResourceGroupName  = $resourceGroupName
        StorageAccountName = $storageAccountName
        DomainAccountType  = 'ComputerAccount'
        OverwriteExistingADObject = $true
    }
    if ($storageAccountOuPath) {
        $joinParams['OrganizationalUnitDistinguishedName'] = $storageAccountOuPath
    }
    Join-AzStorageAccount @joinParams -verbose

    Write-LogOutput "Successfully domain joined storage account $storageAccountName"
} catch {
    Write-LogOutput "ERROR: Failed to domain join storage account: $_"
    Stop-Transcript
    exit 1
}

if ($isFslogixDeployment -eq "true") {
    Write-LogOutput "Setting up FSLogix NTFS permissions on share $fslogixShareName..."
    try {
        $StorageAccountFqdn = "$storageAccountName.file.core.windows.net"
        $FileShareLocation = "\\$StorageAccountFqdn\$fslogixShareName"

        Write-LogOutput "Testing port 445 connectivity to $StorageAccountFqdn..."
        $connectTestResult = Test-NetConnection -ComputerName $StorageAccountFqdn -Port 445
        Write-LogOutput "Port 445 test result: $($connectTestResult.TcpTestSucceeded)"

        if (-not $connectTestResult.TcpTestSucceeded) {
            Write-LogOutput "ERROR: Failed to connect to $StorageAccountFqdn on port 445. Cannot proceed with FSLogix setup."
            Stop-Transcript
            exit 1
        }

        Write-LogOutput "Retrieving storage account key..."
        $StorageKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageAccountName) |
            Where-Object { $_.KeyName -eq "key1" }

        Write-LogOutput "Mounting file share as drive Y..."
        net use Y: $FileShareLocation /user:Azure\$storageAccountName $StorageKey.Value

        Write-LogOutput "Configuring root FSLogix ACLs..."
        icacls Y: /remove "BUILTIN\Administrators"
        icacls Y: /remove "BUILTIN\Users"
        icacls Y: /remove "Authenticated Users"
        icacls Y: /grant "Creator Owner:(OI)(CI)(IO)(M)"
        Write-LogOutput "Base FSLogix ACLs set"

        $domainNetBiosName = (Get-ADDomain).NetBIOSName
        Write-LogOutput "Detected NetBIOS domain name: $domainNetBiosName"

        if ($ADAdmingroup -ne "none" -and $ADAdmingroup -ne "") {
            $AdminGroup = "$domainNetBiosName\$ADAdmingroup"
            Write-LogOutput "Granting Full Control to $AdminGroup..."
            icacls Y: /grant "${AdminGroup}:(OI)(CI)(F)"
            Write-LogOutput "$ADAdmingroup Full Control ACL set"
        }

        $hostPoolFolders = @(
            "fslogix-share-main",
            "fslogix-share-dev",
            "fslogix-share-avd1",
            "fslogix-share-avd2",
            "fslogix-share-avd3",
            "fslogix-share-avd4"
        )

        foreach ($folder in $hostPoolFolders) {
            $folderPath = "Y:\$folder"
            Write-LogOutput "Creating hostpool folder: $folderPath..."
            New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
            Write-LogOutput "Created $folderPath"
        }

        if ($fslogixADGroupName -ne "none" -and $fslogixADGroupName -ne "") {
            $Group = "$domainNetBiosName\$fslogixADGroupName"

            foreach ($folder in $hostPoolFolders) {
                $folderPath = "Y:\$folder"
                Write-LogOutput "Setting Modify permissions for $Group on $folder..."
                icacls $folderPath /grant "${Group}:(M)"
                Write-LogOutput "Permissions set on $folder"
            }
        }

        Write-LogOutput "FSLogix NTFS permissions configured successfully"
    } catch {
        Write-LogOutput "ERROR: Failed to configure FSLogix permissions: $_"
        Stop-Transcript
        exit 1
    }
}

Write-LogOutput "Script execution completed successfully"
Stop-Transcript
