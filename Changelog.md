# Changelog
Each version corresponds to a Jering.Redist.NodeJS [NuGet package](https://www.nuget.org/packages/Jering.Redist.NodeJS/).

The first three digits of a version indicate the [NodeJS](https://nodejs.org/en/) version in the package. E.g `12.13.1.1` would contain NodeJS `12.13.1`. 

We add a fourth digit when we make changes to NuGet package structure/metadata. E.g `12.13.1.2` and `12.13.1.1` both contain NodeJS `12.13.1`, but they may have different structures/metadata:
- We might've added NodeJS for additional platforms, e.g `win-arm64`.
- We might've made changes to .nuspec, [.props or .targets](https://docs.microsoft.com/en-us/nuget/create-packages/creating-a-package#include-msbuild-props-and-targets-in-a-package) files.
