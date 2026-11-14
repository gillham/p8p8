# Builds p8c on Windows from the seed, with clang alone:
#
#     powershell -ExecutionPolicy Bypass -File tools\build-windows.ps1
#
# The seed (seed\p8c.ll.gz) is the compiler's own LLVM IR, the same file that macOS
# and Linux build from.  Four functions of the C library have other names on Windows;
# they are renamed where the seed calls or declares them, and then it is the IR the
# compiler writes for Windows itself.  clang makes a first compiler of that, the first
# compiles the sources, clang makes build\llvm64\p8c.exe of the result, and p8c.exe
# compiles the sources once more: that must give the same IR again.
#
# With -Dist it also makes dist\p8p8-<version>-windows-x86_64.zip: bin\p8c.exe and
# lib\p8p8 (the library, which p8c.exe finds there by itself), and the documents.
param([string]$Clang = "clang", [switch]$Dist)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

function Run([string]$what, [string]$exe, [string[]]$arguments) {
    Write-Host $what
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit status $LASTEXITCODE)" }
}

foreach ($dir in "build\stage0", "build\llvm64", "build\check") {
    New-Item -ItemType Directory -Force $dir | Out-Null
}

# the seed as text, with the Windows names
Write-Host "unpacking the seed"
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$packed = [System.IO.File]::OpenRead((Join-Path (Get-Location) "seed\p8c.ll.gz"))
$gzip = New-Object System.IO.Compression.GZipStream($packed, [System.IO.Compression.CompressionMode]::Decompress)
$reader = New-Object System.IO.StreamReader($gzip, $latin1)
$writer = New-Object System.IO.StreamWriter((Join-Path (Get-Location) "build\stage0\p8c.ll"), $false, $latin1)
$writer.NewLine = "`n"
while ($null -ne ($line = $reader.ReadLine())) {
    # (a line that starts with @ is data: the compiler's own text of these names stays)
    if (-not $line.StartsWith("@")) {
        $line = $line.Replace("@popen(", "@_popen(").Replace("@pclose(", "@_pclose(").Replace("@fseek(", "@_fseeki64(").Replace("@ftell(", "@_ftelli64(")
    }
    $writer.WriteLine($line)
}
$writer.Close()
$reader.Close()

$sources = @("-target", "llvm64", "-lib", "lib", "-srcdirs", "src:src/llvm64", "-llvm")

Run "clang builds the first compiler from the seed" $Clang @("-O2", "-Wno-override-module", "runtime\windows-console.c", "build\stage0\p8c.ll", "-o", "build\stage0\p8c.exe")
Run "the first compiler compiles the sources" "build\stage0\p8c.exe" ($sources + @("-out", "build\llvm64", "src\main.p8"))
Move-Item -Force "build\llvm64\main.ll" "build\llvm64\p8c.ll"
Run "clang builds p8c.exe" $Clang @("-O2", "-Wno-override-module", "runtime\windows-console.c", "build\llvm64\p8c.ll", "-o", "build\llvm64\p8c.exe")
Run "p8c.exe compiles the sources again" "build\llvm64\p8c.exe" ($sources + @("-out", "build\check", "src\main.p8"))

$first = (Get-FileHash "build\llvm64\p8c.ll").Hash
$second = (Get-FileHash "build\check\main.ll").Hash
if ($first -ne $second) { throw "p8c.exe does not reproduce itself: build\llvm64\p8c.ll and build\check\main.ll differ" }
Write-Host "built build\llvm64\p8c.exe; it compiles itself to the same LLVM IR"

if ($Dist) {
    if (-not (Test-Path "lib\prog8lib\prog8_lib.p8")) { throw "no library in lib\ (git submodule update --init)" }
    $version = [regex]::Match((Get-Content "src\version.p8" -Raw), 'str number = "([^"]+)"').Groups[1].Value
    $name = "p8p8-$version-windows-x86_64"
    $root = "dist\$name"
    if (Test-Path $root) { Remove-Item -Recurse -Force $root }
    foreach ($dir in "$root\bin", "$root\lib\p8p8\runtime", "$root\docs") {
        New-Item -ItemType Directory -Force $dir | Out-Null
    }
    Copy-Item "build\llvm64\p8c.exe" "$root\bin\"
    Copy-Item -Recurse "lib\prog8lib", "lib\common", "lib\targets" "$root\lib\p8p8\"
    Copy-Item "lib\VERSION", "lib\LICENSE" "$root\lib\p8p8\"
    Copy-Item "runtime\windows-console.c", "runtime\hosted-keys.c", "runtime\mos-c64-support.c" "$root\lib\p8p8\runtime\"
    Copy-Item "README.md", "LICENSE" "$root\"
    Copy-Item "docs\*.md" "$root\docs\"
    if (Test-Path "dist\$name.zip") { Remove-Item -Force "dist\$name.zip" }
    Compress-Archive -Path $root -DestinationPath "dist\$name.zip"
    Remove-Item -Recurse -Force $root
    Write-Host "wrote dist\$name.zip"
}
