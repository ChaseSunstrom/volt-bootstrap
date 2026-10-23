#!/bin/sh
# C# calls Volt: build greet, then a console project with its greet.cs (made for the .NET installed)
set -e
cd "$(dirname "$0")"
D="${DOTNET:-dotnet}"
command -v "$D" >/dev/null || exit 77
GREET="$PWD/../greet/target/debug"
(cd ../greet && "${BOLT:-bolt}" build -q)
# the directory as .NET reads it (Git Bash's /d/a is D:/a on Windows)
GREET_NET=$(cd "$GREET" && pwd -W 2>/dev/null) || GREET_NET="$GREET"
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
    <Compile Include="$GREET_NET/bindings/greet.cs" />
  </ItemGroup>
</Project>
XML
# (the library: through LD_LIBRARY_PATH, DYLD_LIBRARY_PATH, or on Windows PATH)
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 LD_LIBRARY_PATH="$GREET" DYLD_LIBRARY_PATH="$GREET" PATH="$GREET:$PATH" "$D" run --nologo
