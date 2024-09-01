param([switch]$Rebase)

Remove-Item env:DEV_* -ErrorAction SilentlyContinue

# Exit early if required files are missing
if (-not (Test-Path .\.env) -or -not (Test-Path .\token.xml)) {
    Write-Error 'No .env or token.xml found. View README for details.'
    exit 1
}

# Install Universal module if not already installed
if (-not (Get-Module -ListAvailable -Name Universal)) {
    Install-Module -Name Universal -Scope CurrentUser -Force -AllowClobber
}

# Load environment variables from .env file
# Resolve any templatized values in the .env file
$env = Get-Content .\.env -Raw | ConvertFrom-StringData
$pattern = '\$\{([^\}]+)\}'
$resolvedEnv = @{}
foreach ($key in $env.Keys) {
    $resolvedEnv[$key] = $env[$key] -replace $pattern, { $env[$_.groups[1].value] }
}

# Set environment variables
$resolvedEnv.GetEnumerator() | ForEach-Object {
    [Environment]::SetEnvironmentVariable($_.Key, $_.Value)
}

$Token = Import-Clixml token.xml
$AppToken = $Token.token.GetNetworkCredential().Password

$SourceRoot = (Join-Path (Get-Location).Path 'src\PSIAM.Universal')
$Manifest = Import-PowerShellDataFile (Resolve-Path $SourceRoot\*.psd1).Path
$DestinationRoot = if ($env:DEV_NETWORK_SHARE) {
    New-PSDrive -Name Universal -PSProvider FileSystem -Root $env:DEV_NETWORK_SHARE -Credential $Token.devcred -ErrorAction Stop | Out-Null
    "Universal:\"
}
else {
    $env:DEV_VM_SHARE
}
$DestinationPath = "{0}\{1}\{2}" -f $DestinationRoot, ($SourceRoot | Split-Path -Leaf), $Manifest.ModuleVersion

Write-Host "Source directory: $SourceRoot"
Write-Host "Module version: $($Manifest.ModuleVersion)"
Write-Host "Destination root: $DestinationRoot"
Write-Host "Destination directory: $DestinationPath"

#Copy-Item -Path $SourceRoot -Destination $DestinationPath -Recurse -Force
# try {
#     Write-Information -MessageData "Connecting to $($env:DEV_SERVER_URL)..." -InformationAction Continue

#     $null = Connect-PSUServer -ComputerName $env:DEV_SERVER_URL -AppToken $AppToken -ErrorAction Stop
#     Write-Information -MessageData "Connected to $($env:DEV_SERVER_URL)." -InformationAction Continue
#     Write-Information -MessageData "Stopping $($env:DEV_APP_NAME)..." -InformationAction Continue

#     if (Get-PSUApp -Name $env:DEV_APP_NAME -ErrorAction SilentlyContinue) {
#         Get-PSUApp -Name $env:DEV_APP_NAME | Stop-PSUApp
#     }
#     else {
#         Write-Information "PSU App $env:DEV_APP_NAME not found. PowerShell Universal service may need to be restarted manually."
#     }
# }
# catch {
#     Write-Error "Unable to connect to Univeral Server. Run Connect-PSUServer locally for additional troubleshooting."
#     return
# }

if ($Rebase) {
    Write-Information -MessageData "Rebasing $($env:DEV_APP_NAME)..." -InformationAction Continue
    Remove-Item -Path $DestinationPath -Recurse -Force
}

Write-Information -MessageData "Copying files from $SourceRoot to $DestinationPath..." -InformationAction Continue
Get-ChildItem -Path $SourceRoot -Recurse | ForEach-Object {
    $DestStub = $_.FullName -split '\\src\\PSIAM.Universal' | Select-Object -Skip 1
    $DestinationFile = Join-Path $DestinationPath $DestStub
    Copy-Item -Path $_.FullName -Destination $DestinationFile -Force
}

#Write-Information -MessageData "Starting $($env:DEV_APP_NAME)..." -InformationAction Continue
#Get-PSUApp -Name $env:DEV_APP_NAME | Start-PSUApp


try {
   Write-Information -MessageData "Connecting to $($env:DEV_SERVER_URL)..." -InformationAction Continue
   $null = Connect-PSUServer -ComputerName $env:DEV_SERVER_URL -AppToken $AppToken -ErrorAction Stop
   Write-Information -MessageData "Connected to $($env:DEV_SERVER_URL)." -InformationAction Continue
}
catch {
   Write-Error "Unable to connect to Univeral Server. Run Connect-PSUServer locally for additional troubleshooting."
   return
}

if (Get-PSUApp -Name $env:DEV_APP_NAME -ErrorAction SilentlyContinue) {
   Write-Information "Restarting '$($env:DEV_APP_NAME)' app..." -InformationAction Continue
   Get-PSUApp -Name $env:DEV_APP_NAME | Stop-PSUApp
   Get-PSUApp -Name $env:DEV_APP_NAME | Start-PSUApp
}
else {
   Write-Information "PSU App $env:DEV_APP_NAME not found. PowerShell Universal service may need to be restarted manuall."
}

if (Get-PSDrive -Name 'Universal' -ErrorAction SilentlyContinue) {
   Write-Information "Removing PSDrive 'Universal'..." -InformationAction Continue
   Remove-PSDrive -Name 'Universal'
}
Write-Information 'Complete.' -InformationAction Continue