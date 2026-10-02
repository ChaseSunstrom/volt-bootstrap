#!/bin/sh
# C# calls Volt: build greet, then a console project with its greet.cs (made for the .NET installed)
set -e
cd "$(dirname "$0")"
D="${DOTNET:-dotnet}"
command -v "$D" >/dev/null || exit 77
GREET="$PWD/../greet/target/debug"
(cd ../greet && "${BOLT:-bolt}" build -q)
major=$("$D" --version | cut -d. -f1)
cat > Client.csproj <<XML
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net$major.0</TargetFramework>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
    <Nullable>enable</Nullable>
    <InvariantGlobalization>true</InvariantGlobalization>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="$GREET/bindings/greet.cs" />
  </ItemGroup>
</Project>
XML
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 LD_LIBRARY_PATH="$GREET" DYLD_LIBRARY_PATH="$GREET" "$D" run --nologo
