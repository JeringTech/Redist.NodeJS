<#
.SYNOPSIS
    Updates the Jering.Redist.NodeJS package feed on NuGet.Org.

    This script can be run locally or as an Azure Pipelines task. It requires Chocolatey and several environment variables. 
    Refer to the constants declaration section for the required environment variables.
.DESCRIPTION
    Performs the following operations:

    1. Retrieves the list of NodeJS release versions from https://github.com/nodejs/node.
    2. Retrieves the list of Jering.Redist.NodeJS package versions from NuGet.Org.
    3. Generate the list of missing Jering.Redist.NodeJS package versions.
    4. For each NodeJS release in the list, generates a new package, pushes it and updates changelog.
    5. Updates https://github.com/JeringTech/Redist.NodeJS/blob/master/ReadMe.md with last check time and version of latest package.

    If an error occurs in any step, creates an issue in https://github.com/JeringTech/Redist.NodeJS and aborts.
.Notes
    We keep output "verbose" and clear since it is effectively our log (AzurePipelines build logs).
#>

#-----------------------------------------------------------[Functions]------------------------------------------------------------

# TODO
# - read through scheduled build logs

function FindNewVersions() {
    # Retrieve release versions
    WriteSectionHeader "Retrieving release versions from `"$nodejsRepo`":";
    $allTags = git ls-remote --tags --sort=v:refname $nodejsRepo;
    HandleExternalProcessError "Failed to retrieve release versions.";
    $releaseVersions = $allTags | Select-String ".*?refs/tags/v(\d{2,}\.\d+\.\d+)$" | ForEach-Object { $_.Matches.Groups[1].Value };
    WriteSectionBody $releaseVersions;
    WriteLine;

    # Retrieve package versions
    WriteSectionHeader "Retrieving package versions from `"$changelogPath`":";
    $packageVersions = Get-Content $changelogPath | Select-String $changelogVersionLinePattern | ForEach-Object { $_.Matches.Groups[1].Value };
    WriteSectionBody $packageVersions;
    WriteLine;

    # Find new versions
    WriteSectionHeader "Identifying new versions:";
    $newVersions = $releaseVersions | Where-Object { -not($packageVersions -contains $_) };
    if ($newVersions) {
        WriteSectionBody $newVersions;
        WriteLine;
    }
    else {
        WriteSectionFooter "No new versions." $true;
    }

    return $newVersions;
}

function AddPackage($version) {
    $packageName = "Jering.Redist.NodeJS.$($version).nupkg";
    WriteSectionHeader "Adding $($packageName):";
    IncreaseIndent;

    # Create obj directory
    WriteSectionHeader "Creating `"$objDir`":";
    Remove-Item $objDir -Recurse -ErrorAction "ignore"; # Delete existing folder
    New-Item $objDir -ItemType "directory" | WriteSectionBody;
    WriteLine;

    # Copy package template to directory
    $srcPackageTemplateDir = Join-Path $srcDir "PackageTemplate";
    $objPackageTemplateDir = Join-Path $objDir "PackageTemplate";
    WriteSectionHeader "Copying `"$srcPackageTemplateDir$($dirSeparator)**`" to `"$objPackageTemplateDir`":";
    Copy-Item $srcPackageTemplateDir $objPackageTemplateDir -Recurse;
    WriteSectionFooter "Package template copied.";

    # Retrieve version verification assets
    RetrieveVersionVerificationAssets $version;

    # Retrieve executables
    foreach ($runtimeIdentifier in $archivesToDownload.Keys) {
        RetrieveExecutable $version $runtimeIdentifier $archivesToDownload[$runtimeIdentifier];
    }

    # Pack
    WriteSectionHeader "Packing NuGet package:";
    nuget pack "$objDir/PackageTemplate" -Version $version -OutputDirectory $objDir | WriteSectionBody
    HandleExternalProcessError "Failed to pack NuGet package.";
    WriteLine;

    # Push package
    $packagePath = Join-Path $objDir $packageName;
    WriteSectionHeader "Pushing `"$packagePath`":";
    $ErrorActionPreference = "continue";
    $nugetPushOutput = nuget push $packagePath -Source $nugetEndpoint -ApiKey $nugetPat 2>&1 | ForEach-Object { "$_" } | Out-String;
    $ErrorActionPreference = "stop";
    WriteSectionBody $nugetPushOutput;
    # Handle push fail
    if ($lastExitCode -ne 0) {
        # 409 returned if a package with the provided ID and version already exists - https://docs.microsoft.com/en-us/nuget/api/package-publish-resource#push-a-package
        if ($nugetPushOutput.Contains(" 409 ")) {
            # If package already exists, continue processing
            # TODO check whether package exists before creating package.
            WriteLine;
            WriteSectionBody "$packageName already exists in feed $nugetEndpoint.";
        }
        else {
            throw "Failed to push NuGet package.";
        }
    }
    WriteLine;

    # Update changelog
    UpdateChangelog $version;

    DecreaseIndent;
}

function RetrieveExecutable($version, $runtimeIdentifier, $archiveToDownload) {
    $platform = $archiveToDownload["platform"];
    $extension = $archiveToDownload["extension"];
    $archiveName = "node-v$version-$platform$extension";
    $packageNodeDir = Join-Path $objDir "PackageTemplate/runtimes/$runtimeIdentifier/native";

    WriteSectionHeader "Retrieving executable for $($runtimeIdentifier):";
    IncreaseIndent;

    # Create temp dir
    WriteSectionHeader "Creating `"$tempDir`":";
    Remove-Item $tempDir -Recurse -ErrorAction "ignore";
    New-Item $tempDir -ItemType "directory" | WriteSectionBody;
    WriteLine;

    # Download archive
    $archiveUri = "https://nodejs.org/dist/v$version/$archiveName";
    WriteSectionHeader "Downloading `"$archiveUri`" to `"$tempDir`":";
    $archivePath = Join-Path $tempDir $archiveName;
    Invoke-WebRequest $archiveUri -OutFile "$archivePath";
    WriteSectionFooter "`"$archiveUri`" downloaded.";

    # Verify archive
    WriteSectionHeader "Verifying `"$archivePath`":";
    $expectedShasumLine = (Get-Content "$objDir/shasums256.txt" | Where-Object { $_.Contains($archiveName) }).ToLower();
    WriteSectionBody "Expected shasum line: $expectedShasumLine";
    $localShasum = (Get-FileHash $archivePath "sha256").Hash.ToLower();
    WriteSectionBody "Local shasum: $localShasum";
    if (-not($expectedShasumLine.Contains($localShasum))) {
        throw "Failed to verify archive.";
    }
    WriteLine;

    # Create temp dir
    WriteSectionHeader "Creating `"$packageNodeDir`":";
    New-Item $packageNodeDir -ItemType "directory" | WriteSectionBody;
    WriteLine;

    if ($extension -eq ".7z") {
        # Extract node.exe
        WriteSectionHeader "Extracting node.exe from `"$archivePath`" to `"$tempDir`":" $false;
        7z e "$archivePath" "node.exe" -o"$tempDir" -r | WriteSectionBody;
        HandleExternalProcessError "Failed to extract node.exe.";
        WriteLine;

        # Copy node.exe to package
        $nodePath = Join-Path $tempDir "node.exe";
        WriteSectionHeader "Copying `"$nodePath`" to `"$packageNodeDir`":";
        Copy-Item $nodePath $packageNodeDir;
        WriteSectionFooter "node.exe copied.";
    }
    else {
        #.tar.gz
        # Decompress archive
        WriteSectionHeader "Decompressing `"$archivePath`" to `"$tempDir`":" $false;
        7z x $archivePath -o"$tempDir" | WriteSectionBody;
        HandleExternalProcessError "Failed to decompress archive.";
        WriteLine;

        # Untar archive
        $tarPath = $archivePath.Substring(0, $archivePath.Length - 3); # Remove .gz
        WriteSectionHeader "Untaring `"$tarPath`" to `"$tempDir`":" $false;
        7z x $tarPath -o"$tempDir" | WriteSectionBody;
        HandleExternalProcessError "Failed to untar archive.";
        WriteLine;

        # Copy node to package
        $archiveDir = $tarPath.Substring(0, $tarPath.Length - 4); # Remove .tar
        $nodePath = Join-Path $archiveDir "/bin/node";
        WriteSectionHeader "Copying `"$nodePath`" to `"$packageNodeDir`":";
        Copy-Item $nodePath $packageNodeDir;
        WriteSectionFooter "node copied.";
    }

    # Remove temp directory
    WriteSectionHeader "Removing `"$tempDir`":";
    Remove-Item "$tempDir" -Recurse;
    WriteSectionFooter "`"$tempDir`" removed.";

    DecreaseIndent;
}

function RetrieveSharedVerificationAssets() {
    # Retrieve keys
    WriteSectionHeader "Retrieving GnuPG keys:";
    $ErrorActionPreference = "continue";
    gpg --keyserver pool.sks-keyservers.net --recv-keys 4ED778F539E3634C779C87C6D7062848A1AB005C 2>&1 | ForEach-Object { "$_" } | WriteSectionBody;
    gpg --keyserver pool.sks-keyservers.net --recv-keys B9E2F5981AA6E0CD28160D9FF13993A75599653C 2>&1 | ForEach-Object { "$_" } | WriteSectionBody;
    gpg --keyserver pool.sks-keyservers.net --recv-keys 94AE36675C464D64BAFA68DD7434390BDBE9B9C5 2>&1 | ForEach-Object { "$_" } | WriteSectionBody;
    gpg --keyserver pool.sks-keyservers.net --recv-keys B9AE9905FFD7803F25714661B63B535A4C206CA9 2>&1 | ForEach-Object { "$_" } | WriteSectionBody;
    gpg --keyserver pool.sks-keyservers.net --recv-keys 77984A986EBC2AA786BC0F66B01FBB92821C587A 2>&1 | ForEach-Object { "$_" } | WriteSectionBody;
    gpg --keyserver pool.sks-keyservers.net --recv-keys 71DCFD284A79C3B38668286BC97EC7A07EDE3FC1 2>&1 | ForEach-Object { "$_" } | WriteSectionBody;
    gpg --keyserver pool.sks-keyservers.net --recv-keys FD3A5288F042B6850C66B31F09FE44734EB7990E 2>&1 | ForEach-Object { "$_" } | WriteSectionBody;
    gpg --keyserver pool.sks-keyservers.net --recv-keys 8FCCA13FEF1D0C2E91008E09770F7A9A5AE15600 2>&1 | ForEach-Object { "$_" } | WriteSectionBody;
    gpg --keyserver pool.sks-keyservers.net --recv-keys C4F0DFFF4E8C1A8236409D08E73BC641CC11F4C8 2>&1 | ForEach-Object { "$_" } | WriteSectionBody;
    gpg --keyserver pool.sks-keyservers.net --recv-keys DD8F2338BAE7501E3DD5AC78C273792F7D83545D 2>&1 | ForEach-Object { "$_" } | WriteSectionBody;
    gpg --keyserver pool.sks-keyservers.net --recv-keys A48C2BEE680E841632CD4E44F07496B3EB3C1762 2>&1 | ForEach-Object { "$_" } | WriteSectionBody;
    $ErrorActionPreference = "stop";
    HandleExternalProcessError "Failed to retrieve GnuPG keys.";
    WriteLine;
}

function RetrieveVersionVerificationAssets($version) {
    # Download shasums
    $shasumsUri = "https://nodejs.org/dist/v$version/SHASUMS256.txt";
    $shasumsPath = Join-Path $objDir "shasums256.txt";
    WriteSectionHeader "Downloading `"$shasumsUri`" to `"$shasumsPath`":";
    Invoke-WebRequest $shasumsUri -OutFile $shasumsPath;
    WriteSectionFooter "`"$shasumsUri`" downloaded.";

    # Retrieve shasums file signature
    $shasumsSigUri = "https://nodejs.org/dist/v$version/SHASUMS256.txt.sig";
    $shasumsSigPath = Join-Path $objDir "shasums256.txt.sig";
    WriteSectionHeader "Downloading `"$shasumsSigUri`" to `"$shasumsSigPath`":";
    Invoke-WebRequest $shasumsSigUri -OutFile $shasumsSigPath;
    WriteSectionFooter "`"$shasumsSigUri`" downloaded.";

    # Verify shasums file signature
    # TODO gpg is writing to stderr because we don't have the full "certificate chain".
    # I.e we need to trust someone who trusts the signer or we will keep seeing "WARNING: This key is not certified with a trusted signature!"
    # - https://github.com/nodejs/node/issues/23992#issuecomment-434830030.
    #
    # "gpg --verify" exit code isn't indicative of signature verification outcome, we must grep output to check outcome - https://lists.gnupg.org/pipermail/gnupg-users/2004-August/023141.html.
    # Because gpg writes to stderr, we must redirect stderr to stdout. This causes an additional problem: redirecting an error object to stdout in powershell
    # causes a NativeCommandError - https://stackoverflow.com/questions/10666101/lastexitcode-0-but-false-in-powershell-redirecting-stderr-to-stdout-gives?noredirect=1&lq=1.
    # We work around it by writing plain strings to stdout.
    #
    # Considering that the signer isn't "trusted", this verification might seem like theater. But, it actually does improve security
    # since for shasums256.txt to be compromised, both https://nodejs.org and pool.sks-keyservers.net would need to be compromised.
    WriteSectionHeader "Verifying `"$shasumsPath`":";
    $ErrorActionPreference = "continue";
    $gpgVerifyOutput = gpg --verify $shasumsSigPath $shasumsPath 2>&1 | ForEach-Object { "$_" };
    $ErrorActionPreference = "stop";
    HandleExternalProcessError "Failed to verify shasums.";
    WriteSectionBody $gpgVerifyOutput;
    WriteLine;
    if (-not($gpgVerifyOutput[2].StartsWith("gpg: Good signature from"))) {
        throw "Failed to verify shasums.";
    }
}

function UpdateChangelog($version) {
    WriteSectionHeader "Adding changelog item for $($version):";
    $additionMade = $false;
    $newChangelog = Get-Content $changelogPath | ForEach-Object {
        # Add before first version line
        if (-not($additionMade) -and $_ -match $changelogVersionLinePattern) {
            AddChangelogItem $version;
            $additionMade = $true;
        }

        Write-Output $_; # Write existing line
    };
    # Changelog has no items yet
    if (-not($additionMade)) {
        $newChangelogItem = AddChangelogItem $version $true;
        $newChangelog = $newChangelog + $newChangelogItem;
    }
    $newChangelog | Set-Content $changelogPath;

    # Verify that changelog has changed
    WriteSectionHeader "Verifying `"$changelogPath`" has changed:";
    if ((git -c "core.safecrlf=false" diff --name-only | Where-Object { $_ -eq $changelogName }).Length -eq 0) {
        throw "Changelog unexpectedly unchanged.";
    }
    WriteSectionFooter "Changelog has changed.";

    # Stage changelog
    WriteSectionHeader "Staging `"$changelogPath`":";
    git -c "core.safecrlf=false" add $changelogPath;
    HandleExternalProcessError "Failed to stage changelog.";
    WriteSectionFooter "Staged changelog.";
    
    # Commit changes to changelog
    WriteSectionHeader "Comitting `"$changelogPath`" changes:";    
    git -c "user.email=$commitAuthorEmail" -c "user.name=$commitAuthorName" commit -m "Added changelog item for $version." | WriteSectionBody;
    HandleExternalProcessError "Failed to commit changelog.";
    WriteLine;

    # Tag commit
    WriteSectionHeader "Tagging commit:";    
    git -c "user.email=$commitAuthorEmail" -c "user.name=$commitAuthorName" tag -a $version -m "Released $version";
    HandleExternalProcessError "Failed to tag commit.";
    WriteSectionFooter "Tagged commit.";

    # Push changes to Github
    WriteSectionHeader "Pushing tag and commit to `"$redistRepo`":";
    git push -u $redistRepoAuthenticated -q --follow-tags | WriteSectionBody;
    HandleExternalProcessError "Failed to push tag and commit.";
    WriteLine;
}

function AddChangelogItem($version, $newlineBefore) {
    $majorVersion = [regex]::Match($version, "^(\d+)\.").Captures.Groups[1].Value;
    $output = @"
## [$version](https://github.com/nodejs/node/blob/master/doc/changelogs/CHANGELOG_V$majorVersion.md#$version) - $utcDate
### Executables

"@;
    foreach ($runtimeIdentifier in $archivesToDownload.Keys) {
        $output += "- $runtimeIdentifier`n";
    }
    if ($newlineBefore) {
        $output = "`n$output";
    }
    Write-Output $output;
    WriteSectionBody $output
    WriteLine;
}

# Utils
function Install7zip {
    WriteSectionHeader "Installing 7zip:" $false;

    # Check whether 7z exists
    $install7zip = $null -eq (Get-Command "7z" -ErrorAction "SilentlyContinue");

    # Check existing installation version
    if (-not($install7zip)) {
        $7zOutput = 7z;
        HandleExternalProcessError "Failed to invoke 7zip.";
        $7zOutput | WriteSectionBody;

        if (($7zOutput | Select-String "7-Zip 19.00" -SimpleMatch).Length -eq 0) {
            $install7zip = $true;
        }
    }

    if ($install7zip) {
        choco install 7zip.install --version="19.00" -y | WriteSectionBody;
        HandleExternalProcessError "Failed to install 7zip.";
        WriteLine;
        ResetEnv;
    }
    else {
        WriteSectionFooter "7zip 19.0 already installed." $true;
    }
}

function InstallGpg {
    WriteSectionHeader "Installing GnuPG:";

    # Check whether gpg exists
    $installGpg = $null -eq (Get-Command "gpg" -ErrorAction "SilentlyContinue");

    # Verify existing installation version
    if (-not($installGpg)) {
        $gpgOutput = gpg --version;
        HandleExternalProcessError "Failed to invoke GnuPG.";
        WriteSectionBody $gpgOutput;

        if (($gpgOutput | Select-String "gpg (GnuPG) 2.2.19" -SimpleMatch).length -eq 0) {
            $installGpg = $true;
        }
    }

    if ($installGpg) {
        choco install gnupg --version="2.2.19" -y | WriteSectionBody;
        HandleExternalProcessError "Failed to install GnuPG.";
        WriteLine;
        ResetEnv;
    }
    else {
        WriteSectionFooter "GnuPG 2.2.19 already installed." $true;
    }
}

function InstallNuget {
    WriteSectionHeader "Installing NuGet:";

    # Check whether gpg exists
    $installNuget = $null -eq (Get-Command "nuget" -ErrorAction "SilentlyContinue");

    # Verify existing installation version
    if (-not($installNuget)) {
        $nugetOutput = nuget;
        HandleExternalProcessError "Failed to invoke NuGet.";
        WriteSectionBody $nugetOutput;

        if (($nugetOutput | Select-String "NuGet Version: 5.4.0" -SimpleMatch).length -eq 0) {
            $installNuget = $true;
        }
    }

    if ($installNuget) {
        choco install nuget.commandline --version="5.4.0" -y | WriteSectionBody;
        HandleExternalProcessError "Failed to install NuGet.";
        WriteLine;
        ResetEnv;
    }
    else {
        WriteSectionFooter "NuGet 5.4.0 already installed." $true;
    }
}

function ResetEnv {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User");
}

function HandleExternalProcessError($message) {
    if ($lastExitCode -ne 0) {
        throw $message;
    }
}

function WriteSectionBody() {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $content
    )

    process {
        if (-not($content -is [string])) {
            $content = $content | Out-String;
        }

        # TODO if line is longer than console we should split it up
        $trimmedContent = $content.Trim();

        if (-not($trimmedContent)) {
            Write-Host ""; # Shortcut for empty lines
        }
        else {
            # TrimEnd so we wrapping doesn't cause new empty lines
            $trimmedContent.Replace("`r", "").Split("`n").TrimEnd() | ForEach-Object { Write-Host "$indentation    $_"; };
        }
    }
}

function WriteSectionHeader($content, $newlineAfter = $true) {
    Write-Host "$indentation$content";

    if ($newlineAfter) {
        Write-Host "";
    }
}

function WriteSectionFooter($content, $newlineBefore) {
    if ($newlineBefore) {
        Write-Host "";
    }

    Write-Host "$($indentation)    $content`n";
}

function WriteLine {
    Write-Host "";
}

function SetIndent($indentLevel) {
    $indentation = "";
    For ($i = 0; $i -lt $indentLevel; $i++) {
        $indentation += "    ";
    }

    $script:indentation = $indentation;
}

function IncreaseIndent {
    $script:indentation += "    ";
}

function DecreaseIndent {
    $newLength = $indentation.Length - 4;
    if ($newLength -lt 0) {
        $newLength = 0;
    }
    $script:indentation = $indentation.Substring(0, $newLength);
}

function ResetIndent {
    $script:indentation = "";
}

#-----------------------------------------------------------[Execution]------------------------------------------------------------
$prevErrorActionPreference = $ErrorActionPreference;
$exitCode = 0;

try {
    # Make all errors terminating errors so we catch and log them
    $ErrorActionPreference = 'stop';

    # Constants
    # Map of selected .Net runtime identifiers to information on the files to download for them.
    $archivesToDownload = @{
        "linux-arm"   = @{ "platform" = "linux-armv7l"; "extension" = ".tar.gz" }
        "linux-arm64" = @{ "platform" = "linux-arm64"; "extension" = ".tar.gz" }
        "linux-x64"   = @{ "platform" = "linux-x64"; "extension" = ".tar.gz" }
        "osx-x64"     = @{ "platform" = "darwin-x64"; "extension" = ".tar.gz" }
        "win-x64"     = @{ "platform" = "win-x64"; "extension" = ".7z" }
        "win-x86"     = @{ "platform" = "win-x86"; "extension" = ".7z" }
    };
    $dirSeparator = [IO.Path]::DirectorySeparatorChar;
    $utcDate = [DateTime]::UtcNow.ToString("MMM d, yyyy");
    $rootDir = resolve-path $env:DEFAULT_WORKING_DIRECTORY;
    $srcDir = Join-Path $rootDir "src";
    $objDir = Join-Path $rootDir "obj";
    $tempDir = Join-Path $objDir "temp";
    $changelogName = "Changelog.md";
    $changelogPath = Join-Path $rootDir $changelogName;
    $changelogVersionLinePattern = '^##[ \t]*\[(\d+\.\d+\.\d+)\]';
    $nugetPat = $env:NUGET_PAT;
    $nugetEndpoint = "https://apiint.nugettest.org/v3/index.json";
    $commitAuthorName = "JeringBot";
    $commitAuthorEmail = "bot@jering.tech";
    $githubPat = $env:GITHUB_PAT;
    $redistRepo = "https://github.com/JeringTech/Redist.NodeJS.git";
    $redistRepoAuthenticated = $redistRepo -replace "github.com", "$githubPat@github.com";
    $nodejsRepo = "https://github.com/nodejs/node.git";

    # Variables
    $indentation = "";

    # Find new versions
    WriteSectionHeader "Finding new versions:";
    IncreaseIndent;
    $newVersions = FindNewVersions;
    if (-not($newVersions)) {
        WriteSectionFooter "No new versions found.";
        exit 0;
    }
    ResetIndent;

    # Checkout master branch (can't commit in detached head state)
    WriteSectionHeader "Checking out master:";
    git checkout master | WriteSectionBody;
    HandleExternalProcessError "Failed to checkout master.";
    WriteLine;

    # Install tools
    WriteSectionHeader "Installing tools:";
    IncreaseIndent;
    Install7zip;
    InstallGpg;
    InstallNuget;
    ResetIndent;

    # Retrieve shared verification assets
    RetrieveSharedVerificationAssets;
    
    # Add packages
    $newVersions | ForEach-Object { AddPackage $_ };
}
catch {
    WriteSectionHeader "Error:";
    $_ | WriteSectionBody;

    $exitCode = 1;
}
finally {
    # Reset
    $ErrorActionPreference = $prevErrorActionPreference;

    # Exit
    exit $exitCode;
}