$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$javaHome = 'D:\AndroidStdio\jbr'
$javaExe = Join-Path $javaHome 'bin\java.exe'

if (-not (Test-Path $javaExe)) {
    throw "Java runtime not found: $javaExe"
}

$env:JAVA_HOME = $javaHome
$env:PATH = "$javaHome\bin;$env:PATH"

Set-Location $projectRoot
flutter pub get
flutter build apk --debug
