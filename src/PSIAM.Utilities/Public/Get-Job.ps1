function Get-Job {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$JobId
    )

    $job = Get-PSIAMJob -JobId $JobId
    if ($job -eq $null) {
        Write-Error "Job with ID $JobId not found"
        return
    }

    $job
}