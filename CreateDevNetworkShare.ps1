<#
.SYNOPSIS
    Creates a network share for the Universal repository folder.

.DESCRIPTION
    This script creates a network share for the Universal repository folder. The share is then
    accessible from the host machine. This allows you to develop on your host machine and have the
    changes reflected in the Universal Dashboard instance running on the VM once changes are copied
    to the shared folder.

.NOTES
    - This script must be run from the VIRTUAL MACHINE running PowerShell Universal.
#>
$repositoryFolder = (Get-Content $env:ProgramData\PowerShellUniversal\appsettings.json | ConvertFrom-Json).Data.RepositoryPath
$sharedFolder = Join-Path $repositoryFolder "Modules"

Write-Host "Repository folder: $repositoryFolder"
Write-Host "Shared folder: $sharedFolder"

try {
    if (-not (Test-Path $sharedFolder)) {
        Write-Host "Creating shared folder: $sharedFolder"
        New-Item -ItemType Directory -Path $sharedFolder -ErrorAction Stop
    }

    New-SmbShare -Name "Modules" -Path $sharedFolder -FullAccess "Everyone" -ErrorAction Stop
    Write-Host "Successfully created shared folder."
    Write-Host "Update the .env file on your host machine to include the 'DEV_NETWORK_SHARE' directive."
}
catch {
    Write-Error "Failed to create shared folder. Ensure the path is correct."
}