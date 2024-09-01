$WarningPrefHolder = $WarningPreference
$WarningPreference = 'SilentlyContinue'

$siteUrl = (Get-Content .\mkdocs.yml | Select-String 'site_url').ToString().split( ':', 2)[1].trim()
$blobRootPath = 'projects/PSIAM.Universal'
$docSrcPath = (Join-Path $PSScriptRoot 'docs')
$docRootPath = (Join-Path $PSScriptRoot 'site')
$storageAccount = 'dtmcyberstg'
$containerName = '$web'
$azSubId = 'b77aaef9-396e-4bbf-9809-d485dfa65677'
$azTenant = '644ee707-2edc-41d2-959a-887310d2fe2a'
$missingTools = @()
$requiredTools = @(
    @{
        name    = 'python'
        check   = 'python --version'
        install = 'winget install python3'
    },
    @{
        name    = 'mkdocs'
        check   = 'pip list | Select-String "^mkdocs\s+"'
        install = 'pip install mkdocs'
    },
    @{
        name    = 'mkdocs-material'
        check   = 'pip list | Select-String "^mkdocs-material"'
        install = 'pip install mkdocs-material'
    },
    @{
        name    = 'Az.Storage'
        check   = 'Get-Module -ListAvailable -Name Az.Storage -ErrorAction SilentlyContinue'
        install = 'Install-Module -Name Az.Storage -Force -AllowClobber -Scope CurrentUser'
    }
)

Write-Host 'Checking for required tools and modules...'

foreach ($tool in $requiredTools) {
    if (Invoke-Expression $tool.check -ErrorAction SilentlyContinue) {
        Write-Host "`t ✅ $($tool.name) found"
    }
    else {

        Write-Host "`t ❌ $($tool.name) not found. Attempting to install..."
        try {
            Invoke-Expression $tool.install -ErrorAction Stop
            Write-Host "`t ✅ $($tool.name) installed"
        }
        catch {
            Write-Host "`t ❌ Failed to install $($tool.name)"
            $missingTools += $tool.name
        }
    }
}

if ($missingTools) {
    Write-Error "The following tools are required:"
    $missingTools | ForEach-Object {
        Write-Error "`t$_`t$$RequiredTools[$$_].install"
    }
    exit 1
}

# Copy any schema files to the documentation root
$sourcePath = Join-Path $PSScriptRoot 'src/PSIAM.Universal/data/schema'
if (Test-Path $sourcePath) {
    Write-Information "Copying schema files to documentation source path" -InformationAction Continue
    Get-ChildItem $sourcePath -Recurse -File | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $docSrcPath -Force
    }
}


# Build the documentation
Write-Host 'Staring mkdocs build...'
$proc = Start-Process mkdocs.exe -ArgumentList 'build' -Wait -PassThru -NoNewWindow

if ($proc.ExitCode -ne 0) {
    Write-Error "Failed to build the documentation"
    exit 1
}

# Copy the documentation to the blob storage
Write-Host 'Uploading documentation to Azure Blob Storage...'
$login = $false
if (Get-AzAccessToken -ErrorAction SilentlyContinue) {
    Write-Host 'Azure access token found. Using existing credentials.'
    $Context = Get-AzContext | Select-Object Tenant, Subscription

    if ($Context.Tenant.Id -ne $azTenant -or $Context.Subscription.Id -ne $azSubId) {
        Write-Host 'Azure context does not match the required tenant and subscription.'
        $login = $true
    }
}
else {
    $login = $true
}

if ($login) {
    Write-Host 'Please log in to your Azure account.'
    Write-Host ('Connecting to Azure Tenant {0} and Subscription {1}' -f $azTenant, $azSubId)
    Connect-AzAccount -Subscription $azSubId -Tenant $azTenant
}


$context = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount
$siteFiles = Get-ChildItem -Path $docRootPath -Recurse -File

$totalFiles = $siteFiles.Count
$currentFile = 0

foreach ($file in $siteFiles) {
    $currentFile++
    $progressPercent = [math]::Round(($currentFile / $totalFiles) * 100, 2)

    Write-Progress -Activity "Uploading file: $($file.Name)" -Status "Processing $currentFile of $totalFiles files" -PercentComplete $progressPercent

    $blobPath = $file.FullName.Replace($docRootPath, $blobRootPath).Replace('\', '/')
    $splat = @{
        Context   = $context
        Container = $containerName
        Blob      = $blobPath
        File      = $file.FullName
        Force     = $true
    }

    switch ($file.Extension) {
        '.html' {
            $splat['Properties'] = @{ ContentType = "text/html; charset=utf-8"; }
        }
        '.css' {
            $splat['Properties'] = @{ ContentType = "text/css"; }
        }
        '.js' {
            $splat['Properties'] = @{ ContentType = "application/javascript"; }
        }
        '.png' {
            $splat['Properties'] = @{ ContentType = "image/png"; }
        }
        '.jpg' {
            $splat['Properties'] = @{ ContentType = "image/jpeg"; }
        }
        '.gif' {
            $splat['Properties'] = @{ ContentType = "image/gif"; }
        }
        '.svg' {
            $splat['Properties'] = @{ ContentType = "image/svg+xml"; }
        }
        '.ico' {
            $splat['Properties'] = @{ ContentType = "image/x-icon"; }
        }
        '.json' {
            $splat['Properties'] = @{ ContentType = "application/json"; }
        }
        '.xml' {
            $splat['Properties'] = @{ ContentType = "application/xml"; }
        }
        '.txt' {
            $splat['Properties'] = @{ ContentType = "text/plain"; }
        }
        '.pdf' {
            $splat['Properties'] = @{ ContentType = "application/pdf"; }
        }
        '.zip' {
            $splat['Properties'] = @{ ContentType = "application/zip"; }
        }
        '.gz' {
            $splat['Properties'] = @{ ContentType = "application/gzip"; }
        }
        '.tar' {
            $splat['Properties'] = @{ ContentType = "application/x-tar"; }
        }
        '.tgz' {
            $splat['Properties'] = @{ ContentType = "application/x-compressed"; }
        }
    }

    if ($verbose) {
        Set-AzStorageBlobContent @splat | Select-Object -Property Name, ContentType, Length, LastModified
    }
    else {
        $null = Set-AzStorageBlobContent @splat
    }
}
Write-Progress -Activity "Uploading files" -Completed -Status "Upload complete"

Write-Host ('=' * 80)
Write-Host "`n`n"
Write-Host "Documentation uploaded to:"
Write-Host "$siteUrl/"
Write-Host "`n`n"
Write-Host ('=' * 80)


$WarningPreference = $WarningPrefHolder