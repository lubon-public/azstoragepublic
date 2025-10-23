<#
Monitor and auto-scale Azure File Share quotas across all storage accounts in a resource group.

Behavior
- Enumerates all storage accounts in the given resource group
- For each file share, retrieves used GiB and current QuotaGiB
- If FreeGiB < FreeSpaceThresholdGiB, increases quota by IncreaseStepGiB
 - Supports a -DryRun switch for preview-only runs

#>


[CmdletBinding()]
param(
	# Resource group that contains the storage accounts to inspect
	[Parameter(Mandatory)]
	[ValidateNotNullOrEmpty()]
	[string]$resourceGroupName,

	# Free space threshold (GiB). If current free < this value, the share will be increased.
	[Parameter()]
	[ValidateRange(0, 102400)]
	[int]$freeSpaceThresholdGiB = 20,

	# Minimum quota increment when scaling up (GiB)
	[Parameter()]
	[ValidateRange(1, 102400)]
	[int]$increaseStepGiB = 20,

	# If set, do not perform changes; only report intended actions
	[Parameter()]
	[switch]$dryRun
)

$ErrorActionPreference = 'Stop'

# Connect to Azure and import modules
Import-Module -Name Az.Accounts, Az.Storage -ErrorAction Stop
Connect-AzAccount -Identity | Out-Null

Write-Output "Scanning resource group '$resourceGroupName' with free space threshold ${freeSpaceThresholdGiB} GiB and step ${increaseStepGiB} GiB. DryRun=$($dryRun.IsPresent)."

$summary = @()

try {
	$storageAccounts = Get-AzStorageAccount -ResourceGroupName $resourceGroupName
	if (-not $storageAccounts) {
		Write-Output "No storage accounts found in resource group '$resourceGroupName'."
		return
	}

	foreach ($sa in $storageAccounts) {
		$saName = $sa.StorageAccountName
		Write-Output "Processing storage account: $saName"

		# List all file shares and include usage stats
	$shares = Get-AzRmStorageShare -ResourceGroupName $resourceGroupName -StorageAccountName $saName -GetShareUsage
		if (-not $shares) {
			Write-Output "  No file shares found in $saName."
			continue
		}

		foreach ($share in $shares) {
			$shareName = $share.Name
			$quotaGiB = [int]$share.QuotaGiB
			$usedBytes = [int64]$share.ShareUsageBytes
			$usedGiB = [math]::Round(($usedBytes / 1GB), 2)
			$freeGiB = [math]::Round([math]::Max(0, $quotaGiB - $usedGiB), 2)

			Write-Output "  [$saName][$shareName] Used: ${usedGiB} GiB | Quota: ${quotaGiB} GiB | Free: ${freeGiB} GiB"

			$action = 'none'

			# If free space is below threshold, bump quota by the configured step
			if ($freeGiB -lt $freeSpaceThresholdGiB) {
				$newQuotaGiB = $quotaGiB + $increaseStepGiB
				$action = 'increase'
				$msg = "  [$saName][$shareName] Increasing quota from ${quotaGiB} GiB to ${newQuotaGiB} GiB"
				if ($dryRun.IsPresent) {
					Write-Output ($msg + " (dry-run)")
				}
				else {
					try {
						Update-AzRmStorageShare -ResourceGroupName $resourceGroupName -StorageAccountName $saName -Name $shareName -QuotaGiB $newQuotaGiB | Out-Null
						Write-Output ($msg + " - done")
					}
					catch {
						Write-Warning "  [$saName][$shareName] Failed to update quota: $($_.Exception.Message)"
						$action = 'failed'
					}
				}
			}
			else {
				Write-Output "  [$saName][$shareName] Free space above threshold. No change."
				# Keep NewQuotaGiB explicit in the summary for the no-change path
				$newQuotaGiB = $quotaGiB
			}

			$summary += [pscustomobject]@{
				ResourceGroup  = $resourceGroupName
				StorageAccount = $saName
				Share          = $shareName
				UsedGiB        = $usedGiB
				QuotaGiB       = $quotaGiB
				FreeGiB        = $freeGiB
				Action         = $action
				NewQuotaGiB    = $newQuotaGiB
			}
		}
	}
}
catch {
	Write-Error "Unhandled error: $($_.Exception.Message)"
}

Write-Output "\nSummary:"
$summary | Sort-Object StorageAccount, Share | Format-Table -AutoSize

# Also return the raw objects (useful for runbook output or logging)
return $summary