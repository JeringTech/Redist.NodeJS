# Notes

## Duplication in Build and BuildTransitive
Duplication is [recommended](https://github.com/NuGet/Home/wiki/Allow-package--authors-to-define-build-assets-transitive-behavior) in the specifications
for BuildTransitive:
> To construct a package which allows build assets to flow transitively, package author will need to put all these build assets in /buildTransitive as well as /build folder to make the package compatible with packages.config.