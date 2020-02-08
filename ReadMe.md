# Jering.Redist.NodeJS
[![Build Status](https://dev.azure.com/JeringTech/Redist.NodeJS/_apis/build/status/JeringTech.Redist.NodeJS?branchName=master)](https://dev.azure.com/JeringTech/Redist.NodeJS/_build/latest?definitionId=9&branchName=master)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/Pkcs11Interop/Pkcs11Interop/blob/master/LICENSE.md)
TODO publish package:  
[![NuGet](https://img.shields.io/nuget/vpre/Jering.Redist.NodeJS.svg?label=nuget)](https://www.nuget.org/packages/Jering.Redist.NodeJS/)

## Table of Contents
[Overview](#overview)  
[Installation](#installation)  
[Usage](#usage)  
[Projects Using this Package](#projects-using-this-package)  
[Contributing](#contributing)  
[About](#about)  

## Overview
Jering.Redist.NodeJS places [NodeJS](https://nodejs.org/en/) executables in your application's output directory.  

This package is automatically updated. Package versions correspond to NodeJS versions.

## Installation
Using Package Manager:
```
PM> Install-Package Jering.Redist.NodeJS
```
Using .Net CLI:
```
> dotnet add package Jering.Redist.NodeJS
```

## Usage
### Where Do the Executables Go?
NodeJS executables for 4 kinds of operating systems are copied to the output directory of your project:

```
/<project path>/bin/<configuration>/<target framework>
├──<your application>.dll
|
├──miscellaneous dlls
|
└──/NodeJS
   |
   ├──/linux-x64
   |  └──node
   |
   ├──/osx-x64
   |  └──node
   |
   ├──/win-x64
   |  └──node.exe
   |
   └──/win-x86
      └──node.exe
```

### Using the Executables
We recommend using [Jering.Javascript.NodeJS](https://github.com/JeringTech/Javascript.NodeJS) to invoke javascript in NodeJS. Jering.Javascript.NodeJS starts and manages NodeJS processes for you, reusing them indefinitely to avoid the overhead of starting and killing NodeJS processes.  

If you prefer to manage your own NodeJS process, here's how you can locate a suitable executable:

```chsarp
public Process CreateNodeJSProcess(string args)
{
    string runtimeIdentifier;
    bool isWindows;

    // Determine OS
    if (isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
    {
        runtimeIdentifier = "win-";
    }
    else if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
    {
        runtimeIdentifier = "linux-";
    }
    else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
    {
        runtimeIdentifier = "osx-";
    }
    else
    {
        // Jering.Redist.NodeJS doesn't provide an executable suitable for the current machine
        return null;
    }

    // Determine architecture
    if (RuntimeInformation.OSArchitecture == Architecture.X64)
    {
        runtimeIdentifier += "x64";
    }
    else if (isWindows && RuntimeInformation.OSArchitecture == Architecture.X86)
    {
        runtimeIdentifier += "x86";
    }
    else
    {
        // Jering.Redist.NodeJS doesn't provide an executable suitable for the current machine
        return null;
    }

    // Create executable path
    string executablePath = Path.Combine(Directory.GetCurrentDirectory(), "NodeJS", runtimeIdentifier, "node");

    // Start process
    return Process.Start(executablePath, args);
}
```

Do note that logic in the example for starting a process is trivialized. You'd typically need at least exception and
output (stdout/stderr) handling. Refer to [Microsoft's documentation for the Process type](https://docs.microsoft.com/en-us/dotnet/api/system.diagnostics.process?view=netstandard-2.1) for more information.

## Projects Using this Package
[Jering.Javascript.NodeJS](https://github.com/JeringTech/Javascript.NodeJS) - Invoke Javascript in NodeJS, from C#.

## Contributing
Contributions are welcome!

## About
Follow [@JeringTech](https://twitter.com/JeringTech) for updates and more.
