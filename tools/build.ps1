<#
.SYNOPSIS
    Updates the Jering.Redist.NodeJS package feed on NuGet.Org.
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

#----------------------------------------------------------[Declarations]----------------------------------------------------------

# Map of selected .Net runtime identifiers to information on the files to download for them.
$archivesToDownload = @{
    # "linux-arm"   = @{ "platform" = "linux-armv7l"; "extension" = ".tar.gz" }
    # "linux-arm64" = @{ "platform" = "linux-arm64"; "extension" = ".tar.gz" }
    "linux-x64" = @{ "platform" = "linux-x64"; "extension" = ".tar.gz" }
    # "osx-x64"     = @{ "platform" = "darwin-x64"; "extension" = ".tar.gz" }
    "win-x64"   = @{ "platform" = "win-x64"; "extension" = ".7z" }
    # "win-x86" = @{ "platform" = "win-x86"; "extension" = ".7z" }
};

$indentation = "";
$dirSeparator = [IO.Path]::DirectorySeparatorChar;
$rootDir = resolve-path "$PSScriptRoot/..";
$srcDir = Join-Path -path $rootDir -childpath "src";
$objDir = Join-Path -path $rootDir -childpath "obj";
$tempDir = Join-Path -path $objDir -childpath "temp";
$nodejsRepo = "https://github.com/nodejs/node.git";

#-----------------------------------------------------------[Functions]------------------------------------------------------------

# TODO
# - why is 7z "scanning"
# - dotnet pack test manually, /p:version ?
# - logic for publishing to nuget
#   - use dotnet publish, try publishing a package to int.nuget
# - logic for updating changelog
#   - keep track of successful publishes/publishes where package already exists, in "finally", update changelog and push
#   - create bot account
#       - use jering email that redirects > we need to check up on our email addresses
#   - push to repo to test
# - run end to end locally, publish 1 version to int.nuget
# - run on azure pipelines, publish 1 version to int.nuget
# - schedule azure pipelines automated build, publish all remaining versions to int.nuget

# Note: Expects Chocolatey to be available and expects powershell process to have administrator privileges

function FindNewVersions() {
    # Retrieve release versions
    WriteSectionHeader "Retrieving release versions from `"$nodejsRepo`":";
    $allTags = git ls-remote --tags --sort=v:refname $nodejsRepo;
    HandleExternalProcessError("Release versions retrieval failed.");
    $releaseVersions = $allTags | select-string -pattern ".*?refs/tags/v(\d{2,}\.\d+\.\d+)$" | foreach-object { $_.matches.groups[1].value };
    $releaseVersions | WriteSectionBody;
    WriteLine

    # Retrieve package versions
    $changelogPath = Join-Path -path $rootDir -childpath "Changelog.md";
    WriteSectionHeader "Retrieving package versions from `"$changelogPath`":"
    $packageVersions = get-content $changelogPath | select-string -pattern '^##[ \t]*\[(\d+\.\d+\.\d+)\]' | foreach-object { $_.matches.groups[1].value };
    $packageVersions | WriteSectionBody;
    WriteLine

    # Find new versions
    WriteSectionHeader "Identifying new versions:"
    $newVersions = $releaseVersions | where-object { -not($packageVersions -contains $_) };
    if ($newVersions) {
        $newVersions | WriteSectionBody;
        WriteLine
        return $true;
    }
    else {
        WriteSectionFooter "No new versions." $true
        return $false;
    }
}

function CreatePackage($version) {
    WriteSectionHeader "Creating package for $($version):";
    IncreaseIndent;
    
    # Create obj directory
    WriteSectionHeader "Creating `"$objDir`":";
    remove-item $objDir -r -erroraction "ignore"; # Delete existing folder
    new-item -path $rootDir -name "obj" -itemtype "directory" | WriteSectionBody;
    WriteLine

    # Copy package template to directory
    $srcPackageTemplateDir = Join-Path -path $srcDir -ChildPath "PackageTemplate";
    $objPackageTemplateDir = Join-Path -path $objDir -ChildPath "PackageTemplate";
    WriteSectionHeader "Copying `"$srcPackageTemplateDir$($dirSeparator)**`" to `"$objPackageTemplateDir`":";
    copy-item -path $srcPackageTemplateDir -destination $objPackageTemplateDir -recurse;
    WriteSectionFooter "Package template copied.";

    # Retrieve version verification assets
    RetrieveVersionVerificationAssets $version;

    # Retrieve executables
    foreach ($runtimeIdentifier in $archivesToDownload.keys) {
        RetrieveExecutable $version $runtimeIdentifier $archivesToDownload[$runtimeIdentifier];
    }

    # Pack
    WriteSectionHeader "Packing NuGet package:";
    nuget pack "$objDir/PackageTemplate" -version $version | WriteSectionBody
    HandleExternalProcessError("NuGet pack failed.");
    WriteLine

    DecreaseIndent;
}

function ReleasePackage() {
    # Publish
    oy2eyhzkfgapdv2gcpeaqufu6rinhg2e5gvyoxluyeyafe

    # Update changelog
    # TODO
}

function RetrieveExecutable($version, $runtimeIdentifier, $archiveToDownload) {
    $platform = $archiveToDownload["platform"];
    $extension = $archiveToDownload["extension"];
    $archiveName = "node-v$version-$platform$extension";
    
    WriteSectionHeader "Retrieving executable for $($runtimeIdentifier):";
    IncreaseIndent;

    # Create temp dir
    WriteSectionHeader "Creating `"$tempDir`":";
    remove-item "$tempDir" -r -erroraction "ignore";
    new-item -path "$objDir" -name "temp" -itemtype "directory" | WriteSectionBody;
    WriteLine

    # Download archive
    $archiveUri = "https://nodejs.org/dist/v$version/$archiveName";
    $archivePath = Join-Path -path $tempDir -childpath $archiveName;
    $packageNodeDir = Join-Path -path $objDir -childpath "PackageTemplate/runtimes/$runtimeIdentifier/native";
    WriteSectionHeader "Downloading `"$archiveUri`" to `"$archivePath`":";
    invoke-webrequest -uri $archiveUri -outfile "$archivePath";
    WriteSectionFooter "`"$archiveUri`" downloaded.";

    # Verify archive
    WriteSectionHeader "Verifying `"$archivePath`":";
    $expectedShasum = (get-content "$objDir/shasums256.txt" | where-object { $_.contains($archiveName) }).ToLower();
    "Expected shasum: $expectedShasum" | WriteSectionBody;
    $localShasum = (get-filehash -path $archivePath -algorithm "sha256").hash.ToLower();
    "Local shasum: $localShasum" | WriteSectionBody;
    if (-not($expectedShasum.Contains($localShasum))) {
        throw "Archive verification failed."
    }
    WriteLine

    if ($extension -eq ".7z") {
        # Extract node.exe
        $nodePath = Join-Path -path $tempDir -childpath "node.exe";
        WriteSectionHeader "Extracting node.exe from `"$archivePath`" to `"$nodePath`":" $false;
        7z e "$archivePath" "node.exe" -o"$tempDir" -r | WriteSectionBody;
        HandleExternalProcessError("node.exe extraction failed.");
        WriteLine

        # Copy node.exe to package
        WriteSectionHeader "Copying `"$nodePath`" to `"$packageNodeDir`":";
        copy-item -path $nodePath -destination $packageNodeDir;
        WriteSectionFooter "node.exe copied.";
    }
    else {
        #.tar.gz
        # Decompress archive
        $tarPath = $archivePath.Substring(0, $archivePath.Length - 3); # Remove .gz
        WriteSectionHeader "Decompressing `"$archivePath`" to `"$tarPath`":" $false;    
        7z x $archivePath -o"$tempDir" | WriteSectionBody;
        HandleExternalProcessError("Archive decompressing failed.");
        WriteLine

        # Untar archive
        $archiveDir = $tarPath.Substring(0, $tarPath.Length - 4); # Remove .tar
        WriteSectionHeader "Untaring `"$tarPath`" to `"$archiveDir`":" $false;    
        7z x $tarPath -o"$tempDir" | select-string -pattern "^Extracting " -notmatch | WriteSectionBody; # Untaring is really verbose by default
        HandleExternalProcessError("Archive untaring failed.");
        WriteLine

        # Copy node to package
        $nodePath = Join-Path -path $archiveDir -childpath "/bin/node";
        WriteSectionHeader "Copying `"$nodePath`" to `"$packageNodeDir`":";
        copy-item -path $nodePath -destination $packageNodeDir;
        WriteSectionFooter "node copied.";       
    }

    # Remove temp directory
    WriteSectionHeader "Removing `"$tempDir`":";
    remove-item "$tempDir" -r;
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
    HandleExternalProcessError("GnuPG keys retrieval failed.");
    WriteLine;
}

function RetrieveVersionVerificationAssets($version) {
    # Download shasums
    $shasumsUri = "https://nodejs.org/dist/v$version/SHASUMS256.txt";
    $shasumsPath = Join-Path -path $objDir -childpath "shasums256.txt";
    WriteSectionHeader "Downloading `"$shasumsUri`" to `"$shasumsPath`":";
    invoke-webrequest -uri $shasumsUri -outfile $shasumsPath;
    WriteSectionFooter "`"$shasumsUri`" downloaded.";

    # Retrieve shasums file signature
    $shasumsSigUri = "https://nodejs.org/dist/v$version/SHASUMS256.txt.sig";
    $shasumsSigPath = Join-Path -path $objDir -childpath "shasums256.txt.sig";
    WriteSectionHeader "Downloading `"$shasumsSigUri`" to `"$shasumsSigPath`":";
    invoke-webrequest -uri $shasumsSigUri -outfile $shasumsSigPath
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
    $gpgVerifyOutput = gpg --verify $shasumsSigPath $shasumsPath 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = "stop";
    HandleExternalProcessError("Shasums verification failed.");
    $gpgVerifyOutput | WriteSectionBody;
    WriteLine
    if (-not($gpgVerifyOutput[2].StartsWith("gpg: Good signature from"))) {
        throw "Shasums verification failed."
    }
}

# Utils
function Install7zip {
    WriteSectionHeader "Installing 7zip:" $false;   

    # Check whether 7z exists
    $install7zip = $null -eq (get-command "7z" -ErrorAction "SilentlyContinue");

    # Check existing installation version
    if (-not($install7zip)) {
        $7zOutput = 7z;
        HandleExternalProcessError("7zip invocation failed.");
        $7zOutput | WriteSectionBody;

        if (($7zOutput | select-string -pattern "7-Zip 19.00" -simplematch).length -eq 0) {
            $install7zip = $true;
        }
    } 

    if ($install7zip) {
        choco install 7zip.install --version="19.00" -y | WriteSectionBody;
        HandleExternalProcessError("7zip installation failed.");
        ResetEnv;
    }
    else {
        WriteSectionFooter "7zip 19.0 already installed." $true; 
    }
}

function InstallGpg {
    WriteSectionHeader "Installing GnuPG:";  

    # Check whether gpg exists
    $installGpg = $null -eq (get-command "gpg" -ErrorAction "SilentlyContinue");

    # Verify existing installation version
    if (-not($installGpg)) {
        $gpgOutput = gpg --version;
        HandleExternalProcessError("GnuPG invocation failed.");
        $gpgOutput | WriteSectionBody;

        if (($gpgOutput | select-string -pattern "gpg (GnuPG) 2.2.19" -simplematch).length -eq 0) {
            $installGpg = $true;
        }
    }

    if ($installGpg) {
        choco install gnupg --version="2.2.19" -y | WriteSectionBody;
        HandleExternalProcessError("GnuPG installation failed.");
        ResetEnv;
    }
    else {
        WriteSectionFooter "GnuPG 2.2.19 already installed." $true;
    }
}

function InstallNuget {
    WriteSectionHeader "Installing NuGet:";  

    # Check whether gpg exists
    $installNuget= $null -eq (get-command "nuget" -ErrorAction "SilentlyContinue");

    # Verify existing installation version
    if (-not($installNuget)) {
        $nugetOutput = nuget;
        HandleExternalProcessError("NuGet invocation failed.");
        $nugetOutput | WriteSectionBody;

        if (($nugetOutput | select-string -pattern "NuGet Version: 5.4.0" -simplematch).length -eq 0) {
            $installNuget= $true;
        }
    }

    if ($installNuget) {
        choco install nuget.commandline --version="5.4.0" -y | WriteSectionBody;
        HandleExternalProcessError("NuGet installation failed.");
        ResetEnv;
    }
    else {
        WriteSectionFooter "NuGet 5.4.0 already installed." $true;
    }
}

function ResetEnv {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User");
}

function HandleSuccess {
    # update readme
    # post logs
}

function HandleExternalProcessError($message) {
    if ($lastExitCode -ne 0) {
        throw $message
    }
}

function WriteSectionBody() { 
    param(
        [Parameter(ValueFromPipeline = $true)]
        $content
    )
        
    process {
        if (-not($content -is [string])) {
            ;
            $content = $content | out-string;
        }
            
        # TODO if line is longer than console we should split it up
        $trimmedContent = $content.Trim();
        
        if (-not($trimmedContent)) {
            Write-Host ""; # Shortcut for empty lines
        }
        else {
            # TrimEnd so we wrapping doesn't cause new empty lines
            $trimmedContent.Replace("`r", "").Split("`n").TrimEnd() | ForEach-Object { write-host "$indentation    $_"; };
        }
    }
}

function WriteSectionHeader($content, $newlineAfter = $true) {
    write-host "$indentation$content";

    if ($newlineAfter) {
        Write-Host "";
    }
}

function WriteSectionFooter($content, $newlineBefore) {
    if ($newlineBefore) {
        Write-Host "";
    }

    write-host "$($indentation)    $content`n";
}

function WriteLine {
    write-host "";
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

try {
    # Make all errors terminating errors so we catch and log them
    $ErrorActionPreference = 'stop';

    # Find new versions
    WriteSectionHeader "Finding new versions:"
    IncreaseIndent;
    $newVersionsFound = FindNewVersions;
    if (-not($newVersionsFound)) {
        WriteSectionFooter "No new versions found.";
        exit 0;
    }
    ResetIndent;

    # Install tools
    WriteSectionHeader "Installing tools:";
    IncreaseIndent;
    Install7zip;
    InstallGpg;
    ResetIndent;
    
    # Retrieve shared verification assets
    RetrieveSharedVerificationAssets;

    # TODO temp
    $newVersions = "12.13.1";

    # Add packages
    $newVersions | foreach-object { CreatePackage $_ };
}
catch {
    WriteSectionHeader "Error:";
    $_ | WriteSectionBody
    exit 1; # TODO don't exit here so we can push changelog
}
finally {
    # Reset
    $ErrorActionPreference = $prevErrorActionPreference;
}