<#
.SYNOPSIS
    Builds the module using Invoke-Build.
.DESCRIPTION
    This script builds the module using the Invoke-Build module. It sets the
    build configuration and runs the build script based on configured tasks.

    Available tasks:
    - Build - Runs tests, builds the module, and builds the documentation.
    - Test - Runs Pester tests.
    - DevBuild - Builds the module.
    - DevTest - Runs tests.
    - DevDoc - Builds the documentation.
    - Clean - Cleans the build directory.
    - FormattingCheck - Checks the formatting of the module against PSScriptAnalyzer.
.EXAMPLE
    Invoke-Build

    This will perform the default build tasks.

.EXAMPLE
    Invoke-Build -AddBuildTask Analyze,Test

    This will perform only the Analyze and Test tasks.
.NOTES
    - The script requires the Invoke-Build module.
    - The script requires the Pester module.
    - The script requires the PSScriptAnalyzer module.

    Special variables (from Invoke-Build):
    - $BuildRoot - The full path of the build script directory. See https://github.com/nightroman/Invoke-Build/wiki/Special-Variables#buildroot
    - $BuildFile - The full path of the build script (this file). See https://github.com/nightroman/Invoke-Build/wiki/Special-Variables#buildfile
    - $BuildTask - The list of initial tasks. See https://github.com/nightroman/Invoke-Build/wiki/Special-Variables#buildtask
    - $Task - The current task being processed. See https://github.com/nightroman/Invoke-Build/wiki/Special-Variables#task
    - $Job - The current action job being processed. See https://github.com/nightroman/Invoke-Build/wiki/Special-Variables#job
#>

#Include: Settings
$ModuleName = [regex]::Match((Get-Item $BuildFile).Name, '^(.*)\.build\.ps1$').Groups[1].Value
. "./$ModuleName.Settings.ps1"

function Test-ManifestBool ($Path) {
    Get-ChildItem $Path | Test-ModuleManifest -ErrorAction SilentlyContinue | Out-Null; $?
}

#region Available Tasks
# Set the default task set
$DefaultTasks = @(
    'Clean',
    'ValidateRequirements',
    'ImportModuleManifest',
    'FormattingCheck',
    'Analyze',
    'Test',
    'CreateHelpStart',
    'Build',
    'Archive'
)
Add-BuildTask -Name . -Jobs $DefaultTasks
Add-BuildTask -Name DevBuild -Jobs @('Clean', 'ValidateRequirements', 'ImportModuleManifest', 'FormattingCheck', 'Analyze', 'CreateHelpStart', 'Build', 'Archive')
Add-BuildTask -Name DevLocal -Jobs @('Clean', 'ValidateRequirements', 'ImportModuleManifest', 'FormattingCheck', 'Analyze', 'Build')
Add-BuildTask -Name BuildHelp -Jobs @('ImportModuleManifest', 'CreateHelpStart')
Add-BuildTask -Name PushDevLocal -Jobs @('Clean',
    'ValidateRequirements',
    'ImportModuleManifest',
    'Build',
    'PushToDev')
#endregion

#region Build Configuration
Enter-Build {
    $script:ModuleName = [regex]::Match((Get-Item $BuildFile).Name, '^(.*)\.build\.ps1$').Groups[1].Value

    # Identify other required paths
    $script:ProjectRoot = (Get-Item $BuildRoot).Parent.FullName
    $script:ModuleSourcePath = Join-Path -Path $BuildRoot -ChildPath $script:ModuleName
    $script:ModuleFiles = Join-Path -Path $script:ModuleSourcePath -ChildPath '*'

    $script:ModuleManifestFile = Join-Path -Path $script:ModuleSourcePath -ChildPath "$($script:ModuleName).psd1"

    $manifestInfo = Import-PowerShellDataFile -Path $script:ModuleManifestFile
    $script:ModuleVersion = $manifestInfo.ModuleVersion
    $script:ModuleDescription = $manifestInfo.Description
    $script:FunctionsToExport = $manifestInfo.FunctionsToExport

    $script:TestsPath = Join-Path -Path $BuildRoot -ChildPath 'Tests'
    $script:UnitTestsPath = Join-Path -Path $script:TestsPath -ChildPath 'Unit'
    $script:IntegrationTestsPath = Join-Path -Path $script:TestsPath -ChildPath 'Integration'

    $script:ArtifactsPath = Join-Path -Path $BuildRoot -ChildPath 'Artifacts'
    $script:ArchivePath = Join-Path -Path $BuildRoot -ChildPath 'Archive'

    $script:BuildModuleRootFile = Join-Path -Path $script:ArtifactsPath -ChildPath "$($script:ModuleName).psm1"

    # Ensure our builds fail until if below a minimum defined code test coverage threshold
    $script:coverageThreshold = 1

    [version]$script:MinPesterVersion = '5.2.2'
    [version]$script:MaxPesterVersion = '5.99.99'
    $script:testOutputFormat = 'NUnitXML'
}

Set-BuildHeader {
    param($Path)

    # separator line
    Write-Build DarkMagenta ('=' * 79)

    # default header + synopsis
    Write-Build DarkGray "Task $Path : $(Get-BuildSynopsis $Task)"

    # task location in a script
    Write-Build DarkGray "At $($Task.InvocationInfo.ScriptName):$($Task.InvocationInfo.ScriptLineNumber)"

    Write-Build Yellow "Manifest File: $script:ModuleManifestFile"
    Write-Build Yellow "Manifest Version: $($manifestInfo.ModuleVersion)"
} #Set-BuildHeader

# Define footers similar to default but change the color to DarkGray.
Set-BuildFooter {
    param($Path)
    Write-Build DarkGray "Done $Path, $($Task.Elapsed)"
    # # separator line
    # Write-Build Gray ('=' * 79)
} #Set-BuildFooter
#endregion

#region Task Definitions
#region BumpVersionTask
Add-BuildTask BumpVersion -Before ImportModuleManifest {
    <#
    .SYNOPSIS
        Bumps the module version.
    #>
    Write-Build White "`tBumping module version... Current version: $script:ModuleVersion"
    $versionTxt   = [version] (Get-Content (Join-Path $ProjectRoot -ChildPath 'VERSION.txt'))
    $buildVersion = [version]$script:ModuleVersion

    if ($versionTxt -gt $buildVersion) {
        Write-Build DarkMagenta "`t...New version will be set to: $versionTxt"
        $script:ModuleVersion = $versionTxt.ToString()

        Write-Build White "`t...Bumping version in module manifest file..."
        $pattern = '(ModuleVersion).*'
        $manifest = Get-Content $script:ModuleManifestFile -Raw
        $newManifest = $manifest -replace $pattern, "`$1 = '$script:ModuleVersion'"
        $newManifest | Set-Content -Path $script:ModuleManifestFile -Force
    }
    else {
        Write-Build White "`tNo version change detected."
    }

    Write-Build Green "`tModule version: $script:ModuleVersion"
}
#endregion

#region UpdateModuleManifestTask
Add-BuildTask UpdateModuleManifest -After BumpVersion {
    <#
    .SYNOPSIS
        Updates the module manifest file with the exported functions.
    #>
    Write-Build White "`tUpdating module manifest file..."
    $publicFolder = (Join-Path $script:ModuleSourcePath -ChildPath 'Public')
    $publicFunctions = Get-ChildItem -Path $publicFolder -Recurse -Include '*.ps1' | Select-Object -ExpandProperty BaseName
    $script:FunctionsToExport = $publicFunctions

    $updateProps = @{
        Path             = $script:ModuleManifestFile
        Output           = $script:ModuleManifestFile
        Properties       = @{
            FunctionsToExport = $script:FunctionsToExport
        }
    }
    Update-ModuleManifest @updateProps
    Write-Build Green "`t...Module manifest file updated."
}
#endregion

#region ValidateRequirementsTask
Add-BuildTask ValidateRequirements {
    <#
    .SYNOPSIS
        Validates the required modules are installed for the build.
    #>
    # this setting comes from the *.Settings.ps1
    Write-Build White "`tVerifying at least PowerShell $script:requiredPSVersion..."
    Assert-Build ($PSVersionTable.PSVersion -ge $script:requiredPSVersion) "At least Powershell $script:requiredPSVersion is required for this build to function properly"
    Write-Build Green "`t...Verification Complete!"

    Write-Build White "`tVerifying required modules are installed..."
    $requiredModules = @('InvokeBuild', 'platyPS', 'Pester', 'PSScriptAnalyzer', 'PsdKit', 'Universal')

    $requiredModules | ForEach-Object {
        $module = $_
        $moduleInstalled = Get-Module -ListAvailable -Name $module
        Assert-Build $moduleInstalled "Module $module is required for this build to function properly"
    }
}
#endregion

#region TestModuleManifestTask
Add-BuildTask TestModuleManifest -Before ImportModuleManifest {
    <#
    .SYNOPSIS
        Tests the module manifest file.
    #>
    Write-Build White '      Running module manifest tests...'
    Assert-Build (Test-Path $script:ModuleManifestFile) 'Unable to locate the module manifest file.'
    Assert-Build (Test-ManifestBool -Path $script:ModuleManifestFile) 'Module Manifest test did not pass verification.'
    Write-Build Green '      ...Module Manifest Verification Complete!'
}
#endregion

# region ImportModuleManifestTask
Add-BuildTask ImportModuleManifest -Before Build {
    <#
    .SYNOPSIS
        Imports the module manifest file.
    #>
    Write-Build White '      Attempting to load the project module.'
    try {
        Import-Module $script:ModuleManifestFile -Force -PassThru -ErrorAction Stop
    }
    catch {
        throw 'Unable to load the project module'
    }
    Write-Build Green "      ...$script:ModuleName imported successfully"
}
#endregion

#region PushToDevTask
Add-BuildTask PushToDev {
    <#
    .SYNOPSIS
        Copies module content to a development server and restarts the app.
    .DESCRIPTION
        This task copies the module content to a development server and restarts the app.
        The task requires a token.xml file and a .env file in the project root.
        The token.xml file should contain a PSCredential object with the following properties:
        - token: A PSCredential object with the app token.
        - devcred: A PSCredential object with the dev server credentials.
        The .env file should contain the following environment variables:
        - DEV_SERVER_URL: The URL of the development server.
        - DEV_APP_NAME: The name of the app to restart.
        - DEV_NETWORK_SHARE: The network share path to copy the module files to.
        - DEV_VM_SHARE: The VM share path to copy the module files to.
    #>
    Write-Build White "Entering PushToDev task..."
    Write-Build White "`tChecking necessary files..."
    $TokenPath = Join-Path -Path $ProjectRoot -ChildPath 'token.xml'
    $EnvPath = Join-Path -Path $ProjectRoot -ChildPath '.env'

    # Exit early if required files are missing
    $missing = @()
    $missing += if (-not (Test-Path $TokenPath)) { $TokenPath }
    $missing += if (-not (Test-Path $EnvPath)) { $EnvPath }
    if ($missing) {
        throw "Required files are missing: $($missing -join ', '). View README for details."
    }

    Write-Build Green "`tRequired files found."

    Write-Build White "`tLoading token.xml file..."
    $Token = Import-Clixml $TokenPath
    $AppToken = $Token.token.GetNetworkCredential().Password

    Write-Build White "`tClearing DEV environment variables..."
    Remove-Item env:DEV_* -ErrorAction SilentlyContinue

    Write-Build White "`tLoading environment variables from .env file..."
    # Load environment variables from .env file
    # Resolve any templatized values in the .env file
    $env = Get-Content $EnvPath -Raw | ConvertFrom-StringData
    $pattern = '\$\{([^\}]+)\}'
    $resolvedEnv = @{}
    foreach ($key in $env.Keys) {
        $resolvedEnv[$key] = $env[$key] -replace $pattern, { $env[$_.groups[1].value] }
    }

    # Set environment variables
    $resolvedEnv.GetEnumerator() | ForEach-Object {
        [Environment]::SetEnvironmentVariable($_.Key, $_.Value)
    }

    Write-Build Green "`tEnvironment variables loaded."

    if ($env:DEV_NETWORK_SHARE) {
        Write-Build DarkGray "`tConnecting to $($env:DEV_NETWORK_SHARE)..."
        New-PSDrive -Name Universal -PSProvider FileSystem -Root $env:DEV_NETWORK_SHARE -Credential $Token.devcred -ErrorAction Stop | Out-Null
        $DestinationRoot = "Universal:\$script:ModuleName"
    }
    else {
        Assert-Build ($env:DEV_NETWORK_SHARE) "DEV_NETWORK_SHARE environment variable is required."
    }

    $DestinationPath = "{0}\{1}" -f $DestinationRoot, $script:ModuleVersion
    Write-Build DarkGray "`tDestination root directory: $DestinationRoot"
    Write-Build DarkGray "`tDestination directory: $DestinationPath"

    if (Test-Path $DestinationRoot) {
        Write-Build White "`tRemoving existing module files from $DestinationRoot..."
        Remove-Item -Path $DestinationRoot -Recurse -Force -ErrorAction Stop
    }

    Write-Build White "`tCreating destination directory $DestinationPath..."
    $null = New-Item -Path $DestinationPath -ItemType Directory -ErrorAction Stop

    Write-Build White "`tCopying module files from $script:ArtifactsPath to $DestinationPath..."
    Copy-Item $script:ArtifactsPath\* -Destination $DestinationPath\ -Recurse -Force

    # Get-ChildItem -Path $script:ModuleSourcePath -Recurse | ForEach-Object {
    #     $DestStub = $_.FullName -split '\\src\\PSIAM.Universal' | Select-Object -Skip 1
    #     $DestinationFile = Join-Path $DestinationPath $DestStub
    #     Write-Build DarkGray "`t`tCopying $($_.Name) to $DestStub..."
    #     Copy-Item -Path $_.FullName -Destination $DestinationFile -Force
    # }

    Write-Build White "`tModule files copied."

    Write-Build DarkGray "`tConnecting to PowerShell Universal Server..."
    try {
        $null = Connect-PSUServer -ComputerName $env:DEV_SERVER_URL -AppToken $AppToken -ErrorAction Stop
    }
    catch {
        Write-Build Red "`tFailed to connect to $($env:DEV_SERVER_URL)."
        throw $_
    }

    if (Get-PSUApp -Name $env:DEV_APP_NAME -ErrorAction SilentlyContinue) {
        Write-Build DarkGray "`t`tRestarting '$($env:DEV_APP_NAME)' app..."
        Get-PSUApp -Name $env:DEV_APP_NAME | Stop-PSUApp
        Get-PSUApp -Name $env:DEV_APP_NAME | Start-PSUApp
    }
    else {
        Write-Build DarkMagenta "`tPSU App $env:DEV_APP_NAME not found. PowerShell Universal service may need to be restarted manuall."
    }

    Write-Build White "`t`tApp Restart complete."
    if (Get-PSDrive -Name 'Universal' -ErrorAction SilentlyContinue) {
        Write-Build DarkGray "`tRemoving PSDrive 'Universal'..."
        Remove-PSDrive -Name 'Universal'
    }
    Write-Build Green "`t...Dev copy complete."
}
#endregion

#region CleanTask
Add-BuildTask Clean {
    <#
    .SYNOPSIS
        Cleans the Artifacts and Archive directories.
    #>
    Write-Build White "`tClean up our Artifacts/Archive directory..."

    $null = Remove-Item $script:ArtifactsPath -Force -Recurse -ErrorAction 0
    $null = New-Item $script:ArtifactsPath -ItemType:Directory
    $null = Remove-Item $script:ArchivePath -Force -Recurse -ErrorAction 0
    $null = New-Item $script:ArchivePath -ItemType:Directory

    Write-Build Green "`t...Clean Complete!"
}
#endregion

#region AnalyzeTask
Add-BuildTask Analyze {
    <#
    .SYNOPSIS
        Runs PS ScriptAnalyzer against the module and test scripts.
    #>
    $scriptAnalyzerParams = @{
        Path    = $script:ModuleSourcePath
        Setting = 'PSScriptAnalyzerSettings.psd1'
        Recurse = $true
        Verbose = $false
    }

    Write-Build White "`tPerforming Module ScriptAnalyzer checks..."
    $scriptAnalyzerResults = Invoke-ScriptAnalyzer @scriptAnalyzerParams

    if ($scriptAnalyzerResults) {
        $scriptAnalyzerResults | Format-Table
        throw "`tOne or more PSScriptAnalyzer errors/warnings where found."
    }
    else {
        Write-Build Green "`t...Module Analyze Complete!"
    }
}
#endregion

#region AnalyzeTestsTask
Add-BuildTask AnalyzeTests -After Analyze {
    <#
    .SYNOPSIS
        Runs PS ScriptAnalyzer against the test scripts.
    #>
    if (Test-Path -Path $script:TestsPath) {

        $scriptAnalyzerParams = @{
            Path        = $script:TestsPath
            Setting     = 'PSScriptAnalyzerSettings.psd1'
            ExcludeRule = 'PSUseDeclaredVarsMoreThanAssignments'
            Recurse     = $true
            Verbose     = $false
        }

        Write-Build White "`tPerforming Test ScriptAnalyzer checks..."
        $scriptAnalyzerResults = Invoke-ScriptAnalyzer @scriptAnalyzerParams

        if ($scriptAnalyzerResults) {
            $scriptAnalyzerResults | Format-Table
            throw "`tOne or more PSScriptAnalyzer errors/warnings where found."
        }
        else {
            Write-Build Green "`t...Test Analyze Complete!"
        }
    }
}
#endregion

#region FormattingCheckTask
Add-BuildTask FormattingCheck -After AnalyzeTests{
    <#
    .SYNOPSIS
        Analyze scripts to verify if they adhere to desired coding format (Stroustrup / OTBS / Allman)
    #>
    $scriptAnalyzerParams = @{
        Setting     = 'CodeFormattingStroustrup'
        ExcludeRule = 'PSUseConsistentWhitespace'
        Recurse     = $true
        Verbose     = $false
    }



    Write-Build White "`tPerforming script formatting checks..."
    $scriptAnalyzerResults = Get-ChildItem -Path $script:ModuleSourcePath -Exclude "*.psd1" | Invoke-ScriptAnalyzer @scriptAnalyzerParams

    if ($scriptAnalyzerResults) {
        $scriptAnalyzerResults | Format-Table
        throw "`tPSScriptAnalyzer code formatting check did not adhere to {0} standards" -f $scriptAnalyzerParams.Setting
    }
    else {
        Write-Build Green "`t...Formatting Analyze Complete!"
    }
}
#endregion

#region TestTask
Add-BuildTask Test {
    <#
    .SYNOPSIS
        Runs Pester tests against the module's Public and Private functions.
    #>
    Write-Build White "`tImporting desired Pester version. Min: $script:MinPesterVersion Max: $script:MaxPesterVersion"
    Remove-Module -Name Pester -Force -ErrorAction SilentlyContinue # there are instances where some containers have Pester already in the session
    Import-Module -Name Pester -MinimumVersion $script:MinPesterVersion -MaximumVersion $script:MaxPesterVersion -ErrorAction 'Stop'

    $codeCovPath = "$script:ArtifactsPath\ccReport\"
    $testOutPutPath = "$script:ArtifactsPath\testOutput\"
    if (-not(Test-Path $codeCovPath)) {
        New-Item -Path $codeCovPath -ItemType Directory | Out-Null
    }
    if (-not(Test-Path $testOutPutPath)) {
        New-Item -Path $testOutPutPath -ItemType Directory | Out-Null
    }
    if (Test-Path -Path $script:UnitTestsPath) {
        $pesterConfiguration = New-PesterConfiguration
        $pesterConfiguration.run.Path = $script:UnitTestsPath
        $pesterConfiguration.Run.PassThru = $true
        $pesterConfiguration.Run.Exit = $false
        $pesterConfiguration.CodeCoverage.Enabled = $true
        $pesterConfiguration.CodeCoverage.Path = "$ProjectRoot\src\$ModuleName\P*\*.ps1"
        $pesterConfiguration.CodeCoverage.CoveragePercentTarget = $script:coverageThreshold
        $pesterConfiguration.CodeCoverage.OutputPath = "$codeCovPath\CodeCoverage.xml"
        $pesterConfiguration.CodeCoverage.OutputFormat = 'JaCoCo'
        $pesterConfiguration.TestResult.Enabled = $true
        $pesterConfiguration.TestResult.OutputPath = "$testOutPutPath\PesterTests.xml"
        $pesterConfiguration.TestResult.OutputFormat = $script:testOutputFormat
        $pesterConfiguration.Output.Verbosity = 'Detailed'

        Write-Build White "`tPerforming Pester Unit Tests..."
        # Publish Test Results
        $testResults = Invoke-Pester -Configuration $pesterConfiguration

        # This will output a nice json for each failed test (if running in CodeBuild)
        if ($env:CODEBUILD_BUILD_ARN) {
            $testResults.TestResult | ForEach-Object {
                if ($_.Result -ne 'Passed') {
                    ConvertTo-Json -InputObject $_ -Compress
                }
            }
        }

        $numberFails = $testResults.FailedCount
        Assert-Build($numberFails -eq 0) ('Failed "{0}" unit tests.' -f $numberFails)

        Write-Build Gray ("`t...CODE COVERAGE - CommandsExecutedCount: {0}" -f $testResults.CodeCoverage.CommandsExecutedCount)
        Write-Build Gray ("`t...CODE COVERAGE - CommandsAnalyzedCount: {0}" -f $testResults.CodeCoverage.CommandsAnalyzedCount)

        if ($testResults.CodeCoverage.NumberOfCommandsExecuted -ne 0) {
            $coveragePercent = '{0:N2}' -f ($testResults.CodeCoverage.CommandsExecutedCount / $testResults.CodeCoverage.CommandsAnalyzedCount * 100)

            <#
            if ($testResults.CodeCoverage.NumberOfCommandsMissed -gt 0) {
                'Failed to analyze "{0}" commands' -f $testResults.CodeCoverage.NumberOfCommandsMissed
            }
            Write-Host "PowerShell Commands not tested:`n$(ConvertTo-Json -InputObject $testResults.CodeCoverage.MissedCommands)"
            #>
            if ([Int]$coveragePercent -lt $coverageThreshold) {
                throw ('Failed to meet code coverage threshold of {0}% with only {1}% coverage' -f $coverageThreshold, $coveragePercent)
            }
            else {
                Write-Build Cyan "      $('Covered {0}% of {1} analyzed commands in {2} files.' -f $coveragePercent,$testResults.CodeCoverage.CommandsAnalyzedCount,$testResults.CodeCoverage.FilesAnalyzedCount)"
                Write-Build Green "`t...Pester Unit Tests Complete!"
            }
        }
        else {
            # account for new module build condition
            Write-Build Yellow "`tCode coverage check skipped. No commands to execute..."
        }

    }
}
#endregion

#region DevCCTask
Add-BuildTask DevCC {
    <#
    .SYNOPSIS
        Used primarily during active development to generate xml file to graphically display code coverage in VSCode using Coverage Gutters
    #>
    Write-Build White "`tGenerating code coverage report at root..."
    Write-Build White "`tImporting desired Pester version. Min: $script:MinPesterVersion Max: $script:MaxPesterVersion"
    Remove-Module -Name Pester -Force -ErrorAction SilentlyContinue # there are instances where some containers have Pester already in the session
    Import-Module -Name Pester -MinimumVersion $script:MinPesterVersion -MaximumVersion $script:MaxPesterVersion -ErrorAction 'Stop'
    $pesterConfiguration = New-PesterConfiguration
    $pesterConfiguration.run.Path = $script:UnitTestsPath
    $pesterConfiguration.CodeCoverage.Enabled = $true
    $pesterConfiguration.CodeCoverage.Path = "$PSScriptRoot\$ModuleName\*\*.ps1"
    $pesterConfiguration.CodeCoverage.CoveragePercentTarget = $script:coverageThreshold
    $pesterConfiguration.CodeCoverage.OutputPath = '..\..\..\cov.xml'
    $pesterConfiguration.CodeCoverage.OutputFormat = 'CoverageGutters'

    Invoke-Pester -Configuration $pesterConfiguration
    Write-Build Green "`t...Code Coverage report generated!"
}
#endregion

#region HelpTasks
#region CreateHelpStartTask
Add-BuildTask CreateHelpStart {
    <#
    .SYNOPSIS
        Initializes the help creation process.
    #>
    Write-Build White "`tPerforming all help related actions."

    Write-Build Gray "`t`tImporting platyPS v0.12.0 ..."
    Import-Module platyPS -RequiredVersion 0.12.0 -ErrorAction Stop
    Write-Build Gray "`t`t...platyPS imported successfully."
}
#endregion


#region CreateMarkdownHelpTask
Add-BuildTask CreateMarkdownHelp -After CreateHelpStart {
    <#
    .SYNOPSIS
        Generates markdown help files for the module.
    #>
    $ModulePage = "$script:ArtifactsPath\docs\$($ModuleName).md"

    $markdownParams = @{
        Module         = $ModuleName
        OutputFolder   = "$script:ArtifactsPath\docs\"
        Force          = $true
        WithModulePage = $true
        Locale         = 'en-US'
        FwLink         = "NA"
        HelpVersion    = $script:ModuleVersion
    }

    Write-Build Gray "`t     Generating markdown files..."
    $null = New-MarkdownHelp @markdownParams
    Write-Build Gray "`t     ...Markdown generation completed."

    Write-Build Gray "`t     Replacing markdown elements..."
    # Replace multi-line EXAMPLES
    $OutputDir = "$script:ArtifactsPath\docs\"
    $OutputDir | Get-ChildItem -File | ForEach-Object {
        # fix formatting in multiline examples
        $content = Get-Content $_.FullName -Raw
        $newContent = $content -replace '(## EXAMPLE [^`]+?```\r\n[^`\r\n]+?\r\n)(```\r\n\r\n)([^#]+?\r\n)(\r\n)([^#]+)(#)', '$1$3$2$4$5$6'
        if ($newContent -ne $content) {
            Set-Content -Path $_.FullName -Value $newContent -Force
        }
    }
    # Replace each missing element we need for a proper generic module page .md file
    $ModulePageFileContent = Get-Content -Raw $ModulePage
    $ModulePageFileContent = $ModulePageFileContent -replace '{{Manually Enter Description Here}}', $script:ModuleDescription
    $script:FunctionsToExport | ForEach-Object {
        Write-Build DarkGray "             Updating definition for the following function: $($_)"
        $TextToReplace = "{{Manually Enter $($_) Description Here}}"
        $ReplacementText = (Get-Help -Detailed $_).Synopsis
        $ModulePageFileContent = $ModulePageFileContent -replace $TextToReplace, $ReplacementText
    }

    $ModulePageFileContent | Out-File $ModulePage -Force -Encoding:utf8
    Write-Build Gray "`t     ...Markdown replacements complete."

    Write-Build Gray "`t     Verifying GUID..."
    $MissingGUID = Select-String -Path "$script:ArtifactsPath\docs\*.md" -Pattern "(00000000-0000-0000-0000-000000000000)"
    if ($MissingGUID.Count -gt 0) {
        Write-Build Yellow "`t       The documentation that got generated resulted in a generic GUID. Check the GUID entry of your module manifest."
        throw 'Missing GUID. Please review and rebuild.'
    }

    Write-Build Gray "`t     Evaluating if running 7.4.0 or higher..."
    # https://github.com/PowerShell/platyPS/issues/595
    if ($PSVersionTable.PSVersion -ge [version]'7.4.0') {
        Write-Build Gray "`t         Performing Markdown repair"
        # dot source markdown repair
        . $BuildRoot\MarkdownRepair.ps1
        $OutputDir | Get-ChildItem -File | ForEach-Object {
            Repair-PlatyPSMarkdown -Path $_.FullName
        }
    }

    Write-Build Gray "`t     Checking for missing documentation in md files..."
    $MissingDocumentation = Select-String -Path "$script:ArtifactsPath\docs\*.md" -Pattern "({{.*}})"
    if ($MissingDocumentation.Count -gt 0) {
        Write-Build Yellow "`t       The documentation that got generated resulted in missing sections which should be filled out."
        Write-Build Yellow "`t       Please review the following sections in your comment based help, fill out missing information and rerun this build:"
        Write-Build Yellow "`t       (Note: This can happen if the .EXTERNALHELP CBH is defined for a function before running this build.)"
        Write-Build Yellow "             Path of files with issues: $script:ArtifactsPath\docs\"
        $MissingDocumentation | Select-Object FileName, LineNumber, Line | Format-Table -AutoSize
        throw 'Missing documentation. Please review and rebuild.'
    }

    Write-Build Gray "`t     Checking for missing SYNOPSIS in md files..."
    $fSynopsisOutput = @()
    $synopsisEval = Select-String -Path "$script:ArtifactsPath\docs\*.md" -Pattern "^## SYNOPSIS$" -Context 0, 1
    $synopsisEval | ForEach-Object {
        $chAC = $_.Context.DisplayPostContext.ToCharArray()
        if ($null -eq $chAC) {
            $fSynopsisOutput += $_.FileName
        }
    }
    if ($fSynopsisOutput) {
        Write-Build Yellow "             The following files are missing SYNOPSIS:"
        $fSynopsisOutput
        throw 'SYNOPSIS information missing. Please review.'
    }

    Write-Build Gray "`t`t...Markdown generation complete."
}
#endregion

#region CreateExternalHelpTask
Add-BuildTask CreateExternalHelp -After CreateMarkdownHelp {
    <#
    .SYNOPSIS
        Generates external xml help files for the module.
    #>
    Write-Build Gray "`t`tCreating external xml help file..."
    $null = New-ExternalHelp "$script:ArtifactsPath\docs" -OutputPath "$script:ArtifactsPath\en-US\" -Force
    Write-Build Gray "`t`t...External xml help file created!"
}
#endregion

#region CreateHelpCompleteTask
Add-BuildTask CreateHelpComplete -After CreateExternalHelp {
    Write-Build Green "`t...CreateHelp Complete!"
}
#endregion

#region UpdateCBHTask
Add-BuildTask UpdateCBH -After AssetCopy {
    <#
    .SYNOPSIS
        Replaces comment based help (CBH) with external help in all public functions for this project.
    #>
    $ExternalHelp = @"
<#
.EXTERNALHELP $($ModuleName)-help.xml
#>
"@

    $CBHPattern = "(?ms)(\<#.*\.SYNOPSIS.*?#>)"
    Get-ChildItem -Path "$script:ArtifactsPath\Public\*.ps1" -File | ForEach-Object {
        $FormattedOutFile = $_.FullName
        Write-Output "      Replacing CBH in file: $($FormattedOutFile)"
        $UpdatedFile = (Get-Content  $FormattedOutFile -raw) -replace $CBHPattern, $ExternalHelp
        $UpdatedFile | Out-File -FilePath $FormattedOutFile -force -Encoding:utf8
    }
}
#endregion
#endregion

#region AssetCopyTask
Add-BuildTask AssetCopy -Before Build {
    <#
    .SYNOPSIS
        Copies the module assets to the Artifacts directory.
    #>
    Write-Build Gray "`tCopying assets to Artifacts..."
    Copy-Item -Path "$script:ModuleSourcePath\*" -Destination $script:ArtifactsPath -Exclude *.psm1 -Recurse -ErrorAction Stop
    Write-Build Gray "`t...Assets copy complete."
}
#endregion

#region BuildTask
Add-BuildTask Build {
    <#
    .SYNOPSIS
        Builds the module.
    #>
    Write-Build White "`tPerforming Module Build"

    Write-Build Gray "`t`tCopying manifest file to Artifacts..."
    Copy-Item -Path $script:ModuleManifestFile -Destination $script:ArtifactsPath -Force -ErrorAction Stop
    #Copy-Item -Path $script:ModuleSourcePath\bin -Destination $script:ArtifactsPath -Recurse -ErrorAction Stop
    Write-Build Gray "`t`t...manifest copy complete."

    Write-Build Gray "`t`tMerging Public and Private functions to one module file..."
    $scriptContent = [System.Text.StringBuilder]::new()

    # Get only public and private functions, excluding any scripts that define pages,
    # or are intended
    $powerShellScripts = Get-ChildItem -Path $script:ArtifactsPath -Recurse -File -Include *.ps1 | Where-Object {
        (($_.FullName | Split-Path) | Split-Path -Leaf) -match 'Public|Private'
    }
    foreach ($script in $powerShellScripts) {
        $null = $scriptContent.Append((Get-Content -Path $script.FullName -Raw))
        $null = $scriptContent.AppendLine('')
        $null = $scriptContent.AppendLine('')
    }
    $scriptContent.ToString() | Out-File -FilePath $script:BuildModuleRootFile -Encoding utf8 -Force
    Write-Build Gray "`t`t...Module creation complete."

    Write-Build Gray "`t`tCleaning up leftover artifacts..."
    #cleanup artifacts that are no longer required
    if (Test-Path "$script:ArtifactsPath\Public") {
        Remove-Item "$script:ArtifactsPath\Public" -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path "$script:ArtifactsPath\Private") {
        Remove-Item "$script:ArtifactsPath\Private" -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path "$script:ArtifactsPath\Imports.ps1") {
        Remove-Item "$script:ArtifactsPath\Imports.ps1" -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path "$script:ArtifactsPath\docs") {
        #here we update the parent level docs. If you would prefer not to update them, comment out this section.
        Write-Build Gray "`t`tOverwriting docs output..."
        if (-not (Test-Path '..\docs\')) {
            New-Item -Path '..\docs\' -ItemType Directory -Force | Out-Null
        }
        Move-Item "$script:ArtifactsPath\docs\*.md" -Destination '..\docs\' -Force
        Remove-Item "$script:ArtifactsPath\docs" -Recurse -Force -ErrorAction Stop
        Write-Build Gray "`t`t...Docs output completed."
    }

    Write-Build Green "`t...Build Complete!"
}
#endregion

#region ArchiveTask
Add-BuildTask Archive {
    <#
    .SYNOPSIS
        Archives the module.
    #>
    Write-Build White "`tPerforming Archive..."

    $archiveRoot = Join-Path -Path $BuildRoot -ChildPath 'Archive'
    $archivePath = Join-Path -Path $archiveRoot -ChildPath "scratch\$script:ModuleName\$script:ModuleVersion"
    if (Test-Path -Path $archiveRoot) {
        $null = Remove-Item -Path $archiveRoot -Recurse -Force
    }

    $null = New-Item -Path $archivePath -ItemType Directory -Force
    Copy-Item $script:ArtifactsPath\* -Destination $archivePath -Recurse -Force

    $zipFileName = '{0}_{1}_{2}.{3}.zip' -f $script:ModuleName, $script:ModuleVersion, ([DateTime]::UtcNow.ToString("yyyyMMdd")), ([DateTime]::UtcNow.ToString("hhmmss"))
    $zipFile = Join-Path -Path $archiveRoot -ChildPath $zipFileName

    if ($PSEdition -eq 'Desktop') {
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    }
    [System.IO.Compression.ZipFile]::CreateFromDirectory("$archiveRoot\scratch", $zipFile)
    $null = Remove-Item -Path "$archiveRoot\scratch" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Build Green "`t...Archive Complete!"
}
#endregion
#endregion