<#
.SYNOPSIS
    Maps a shared folder from a VMWare VM to the PowerShell Universal repository folder.

.DESCRIPTION
    This script creates a symbolic link from a shared folder on a VMWare VM to the Powershell Universal
    repository folder. This allows you to develop on your host machine and have the
    changes reflected in the Universal Dashboard instance running on the VM once changes are copied
    to the shared folder.

    This also means that any modules installed in the test VM will be written to disk on the host
    machine.
.NOTES
    - This script must be run from the VIRTUAL MACHINE running PowerShell Universal.
    - A shared folder must be configured in VMware with the name 'Universal'.
    - The target folder cannot already exist in the repository folder.
#>
$sharedFolder = "\\vmware-host\Shared Folders\Universal"
$repositoryFolder = (Get-Content $env:ProgramData\PowerShellUniversal\appsettings.json | ConvertFrom-Json).Data.RepositoryPath
$modulesFolder = Join-Path $repositoryFolder "Modules"

Write-Host "Repository folder: $repositoryFolder"
Write-Host "Modules folder: $modulesFolder"

if (Test-Path $modulesFolder) {
    Write-Host "Target folder already exists, copying contents to the shared folder, then removing target."
    Copy-Item $modulesFolder\* $sharedFolder -Recurse -Force

    Write-Host "Removing existing modules folder."
    Remove-Item $modulesFolder -Recurse -Force
}

try {
    Write-Host "Creating symbolic link to shared folder: $sharedFolder"
    New-Item -ItemType SymbolicLink -Path $modulesFolder -Target $sharedFolder -ErrorAction Stop
    Write-Host "Successfully created symbolic link to shared folder."
    Write-Host "Update the .env file on your host machine to include the 'DEV_VM_SHARE' directive."
}
catch {
    Write-Error "Failed to create symbolic link. Ensure the shared folder is accessible, the path is correct, and the disk is formatted as NTFS."
}