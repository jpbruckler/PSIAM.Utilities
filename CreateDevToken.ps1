<#
.SYNOPSIS
    Create a credential file for use with PushtoDev.ps1 script.
.EXTERNALHELP
    https://dtmcyberstg.z19.web.core.windows.net/projects/PSIAM.Universal/developer/scripts/token.xml/
#>

$hdr = @"
This script will create a credential file for use with the PushtoDev.ps1 script. The file
will be saved as token.xml in the current directory. The token.xml file is used to store the
apptoken needed for interacting with the PowerShell Universal API.

The file will optionally store the credentials for a network share if you are using a network
share for your development environment.

See:
- https://dtmcyberstg.z19.web.core.windows.net/projects/PSIAM.Universal/developer/setup-shared-folders/
- https://dtmcyberstg.z19.web.core.windows.net/projects/PSIAM.Universal/developer/scripts/token.xml/
- https://dtmcyberstg.z19.web.core.windows.net/projects/PSIAM.Universal/developer/scripts/PushtoDev.ps1/


"@

Write-Host $hdr

if (Test-Path '.\token.xml') {
    $overwrite = Read-Host -Prompt "A token.xml file already exists. Do you want to overwrite it? (Y/N)"
    if ($overwrite -ne "Y") {
        Write-Host "Exiting script."
        exit
    }
}

$AppToken = Read-Host -Prompt "Enter your PowerShell Universal Dev App Token" -AsSecureString


$configSMBCred = Read-Host -Prompt "Do you want to configure credentials for a network share? (Y/N)"
if ($configSMBCred -eq "Y") {
    $smbCred = Get-Credential -Message "Enter credentials for the network share"
}


$obj = @{}
$obj.token = [PSCredential]::New('PowerShellDev', $AppToken)

if ($smbCred) {
    $obj.devcred = $smbCred
}

try {
    $obj | Export-Clixml -Path .\token.xml -ErrorAction Stop
} catch {
    Write-Error "Failed to save token"
}