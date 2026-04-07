#https://github.com/Azure/avdaccelerator/blob/main/workload/scripts/DSCStorageScripts/1.0.3/Script-DomainJoinStorage.ps1

param(
    [string]$clientId,
    [string]$subscriptionId,
    [string]$storageAccountName,
    [string]$resourceGroupName,
    [string]$storageAccountOuPath,
    [string]$isFslogixDeployment,
    [string]$fslogixShareName,
    [string]$fslogixADGroupName,
    [string]$ADAdmingroup,
    [string]$domainJoinUsername,
    [SecureString]$domainJoinPassword
)

$ErrorActionPreference = "Stop"
try {
    Write-Output "Installing RSAT AD PowerShell tools..."
    Install-WindowsFeature -Name RSAT-AD-PowerShell -IncludeAllSubFeature

    Write-Output "Installing NuGet provider..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force

    Write-Output "Installing AzFilesHybrid module..."
    Install-Module -Name AzFilesHybrid -Force -AllowClobber

    Write-Output "Importing AzFilesHybrid module..."
    Import-Module -Name AzFilesHybrid -Force

    Write-Output "Connecting to Azure with managed identity..."
    Connect-AzAccount -Identity -AccountId $clientId

    Write-Output "Selecting subscription $subscriptionId..."
    Select-AzSubscription -SubscriptionId $subscriptionId

    Write-Output "Domain joining storage account $storageAccountName in resource group $resourceGroupName..."
    # Invoke-Command runs the AD join as the domain user (who has permission to create AD computer objects).
    # The outer script runs as SYSTEM which lacks AD write permissions.
    $credential = New-Object System.Management.Automation.PSCredential($domainJoinUsername, $domainJoinPassword)

    Invoke-Command -ComputerName localhost -Credential $credential -ScriptBlock {
        param($rgName, $saName, $ouPath, $clientId, $subId)
        Import-Module AzFilesHybrid -Force
        Connect-AzAccount -Identity -AccountId $clientId | Out-Null
        Select-AzSubscription -SubscriptionId $subId | Out-Null
        $joinParams = @{
            ResourceGroupName  = $rgName
            StorageAccountName = $saName
            DomainAccountType  = 'ComputerAccount'
            OverwriteExistingADObject = $true
        }
        if ($ouPath) {
            $joinParams['OrganizationalUnitDistinguishedName'] = $ouPath
        }
        Join-AzStorageAccount @joinParams
    } -ArgumentList $resourceGroupName, $storageAccountName, $storageAccountOuPath, $clientId, $subscriptionId

    Write-Output "Successfully domain joined storage account $storageAccountName"
} catch {
    Write-Error "Failed to domain join storage account: $_ "
    throw
}

if ($isFslogixDeployment -eq "true") {
    Write-Output "Setting up FSLogix NTFS permissions on share $fslogixShareName..."
    try {
        $StorageAccountFqdn = "$storageAccountName.file.core.windows.net"
        $FileShareLocation = "\\$StorageAccountFqdn\$fslogixShareName"

        Write-Output "Testing port 445 connectivity to $StorageAccountFqdn..."
        $connectTestResult = Test-NetConnection -ComputerName $StorageAccountFqdn -Port 445
        Write-Output "Port 445 test result: $($connectTestResult.TcpTestSucceeded)"

        if (-not $connectTestResult.TcpTestSucceeded) {
            Write-Error "Failed to connect to $StorageAccountFqdn on port 445. Cannot proceed with FSLogix setup."
            throw
        }

        Write-Output "Retrieving storage account key..."
        $StorageKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageAccountName) |
            Where-Object { $_.KeyName -eq "key1" }

        Write-Output "Mounting file share as drive Y..."
        net use Y: $FileShareLocation /user:Azure\$storageAccountName $StorageKey.Value

        Write-Output "Configuring root FSLogix ACLs..."
        icacls Y: /remove "BUILTIN\Administrators"
        icacls Y: /remove "BUILTIN\Users"
        icacls Y: /remove "Authenticated Users"
        icacls Y: /grant "Creator Owner:(OI)(CI)(IO)(M)"
        Write-Output "Base FSLogix ACLs set"

        $domainNetBiosName = (Get-ADDomain).NetBIOSName
        Write-Output "Detected NetBIOS domain name: $domainNetBiosName"

        if ($ADAdmingroup -ne "none" -and $ADAdmingroup -ne "") {
            $AdminGroup = "$domainNetBiosName\$ADAdmingroup"
            Write-Output "Granting Full Control to $AdminGroup..."
            icacls Y: /grant "${AdminGroup}:(OI)(CI)(F)"
            Write-Output "$ADAdmingroup Full Control ACL set"
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
            Write-Output "Creating hostpool folder: $folderPath..."
            New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
            Write-Output "Created $folderPath"
        }

        if ($fslogixADGroupName -ne "none" -and $fslogixADGroupName -ne "") {
            $Group = "$domainNetBiosName\$fslogixADGroupName"

            foreach ($folder in $hostPoolFolders) {
                $folderPath = "Y:\$folder"
                Write-Output "Setting Modify permissions for $Group on $folder..."
                icacls $folderPath /grant "${Group}:(M)"
                Write-Output "Permissions set on $folder"
            }
        }

        Write-Output "FSLogix NTFS permissions configured successfully"
    } catch {
        Write-Error "Failed to configure FSLogix permissions: $_ "
        throw
    }
}
