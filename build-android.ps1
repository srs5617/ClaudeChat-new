param(
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$flutter = Join-Path $projectRoot '.tooling\sdk\flutter\bin\flutter.bat'
$gradleZip = Join-Path $projectRoot '.tooling\gradle-9.1.0-bin.zip'
$wrapper = Join-Path $projectRoot 'android\gradle\wrapper\gradle-wrapper.properties'
$expectedHash = 'A17DDD85A26B6A7F5DDB71FF8B05FC5104C0202C6E64782429790C933686C806'

$androidSdk = @(
    $env:ANDROID_SDK_ROOT,
    $env:ANDROID_HOME,
    (Join-Path $env:LOCALAPPDATA 'Android\sdk')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
    Select-Object -First 1
if (!$androidSdk) {
    throw 'Android SDK not found. Set ANDROID_SDK_ROOT or install Android Studio.'
}

$javaHome = @(
    $env:JAVA_HOME,
    (Join-Path $env:ProgramFiles 'Android\Android Studio\jbr')
) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'bin\java.exe') -PathType Leaf) } |
    Select-Object -First 1
if (!$javaHome) {
    throw 'Java 17+ not found. Set JAVA_HOME or install Android Studio.'
}

if (!(Test-Path -LiteralPath $flutter -PathType Leaf)) {
    throw "Flutter SDK not found: $flutter"
}
if (!(Test-Path -LiteralPath $gradleZip -PathType Leaf)) {
    throw "Gradle archive not found: $gradleZip"
}
$actualHash = (Get-FileHash -LiteralPath $gradleZip -Algorithm SHA256).Hash
if ($actualHash -ne $expectedHash) {
    throw "Gradle SHA-256 mismatch. Expected $expectedHash, received $actualHash"
}

$gradlePathForUrl = $gradleZip.Replace('\', '/') -replace '^([A-Za-z]):', '$1\:'
$escapedGradleUrl = "distributionUrl=file\:///$gradlePathForUrl"
$wrapperLines = Get-Content -LiteralPath $wrapper
$wrapperLines = $wrapperLines | ForEach-Object {
    if ($_ -like 'distributionUrl=*') { $escapedGradleUrl } else { $_ }
}
Set-Content -LiteralPath $wrapper -Value $wrapperLines -Encoding utf8

$env:JAVA_HOME = $javaHome
$env:ANDROID_HOME = $androidSdk
$env:ANDROID_SDK_ROOT = $androidSdk
$env:PUB_HOSTED_URL = 'https://pub.dev'

$aapt2 = Get-ChildItem -LiteralPath (Join-Path $androidSdk 'build-tools') -Recurse -Filter 'aapt2.exe' -File |
    Sort-Object { [version]$_.Directory.Name } -Descending |
    Select-Object -First 1
if (!$aapt2) {
    throw "AAPT2 not found under $androidSdk\build-tools"
}
[Environment]::SetEnvironmentVariable(
    'ORG_GRADLE_PROJECT_android.aapt2FromMavenOverride',
    $aapt2.FullName,
    'Process'
)

& $flutter pub get --offline
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $flutter analyze --no-pub
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $flutter test --no-pub
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# The reproducible Windows build targets ARM64, which covers current Android
# phones and avoids fetching simulator/legacy engine artifacts unnecessarily.
& $flutter build apk "--$Mode" --target-platform android-arm64 --no-pub
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$builtApk = Join-Path $projectRoot "build\app\outputs\flutter-apk\app-$Mode.apk"
$portableApk = Join-Path $projectRoot "ClaudeChat-$Mode-arm64.apk"
Copy-Item -LiteralPath $builtApk -Destination $portableApk -Force
Write-Host "APK: $portableApk"
exit 0
