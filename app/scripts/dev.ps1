param([ValidateSet('analyze','test','windows','android','run')][string]$Action = 'test')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$developmentRoot = Split-Path -Parent $projectRoot
# All physical files remain under the development root. A drive alias avoids
# upstream Dart/native-build and Android tools' handling of spaces in SDK paths.
if (-not (Test-Path 'P:\app\pubspec.yaml')) {
    if (Test-Path 'P:\') { throw 'P: is already occupied. Choose an unused build drive in this script.' }
    subst P: $developmentRoot
}
$env:PUB_CACHE = 'P:\work\pub-cache'
$env:GRADLE_USER_HOME = 'P:\work\gradle-cache'
$env:ANDROID_HOME = 'P:\work\android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:ANDROID_USER_HOME = 'P:\work\android-user'
$jdk = Get-ChildItem 'P:\work\jdk' -Directory | Select-Object -First 1
$env:JAVA_HOME = $jdk.FullName
$env:PATH = "$env:JAVA_HOME\bin;P:\work\flutter\bin;$env:PATH"
if ($Action -eq 'android' -and (Test-Path 'P:\work\gradle-cache\init.d\focus-maven.gradle')) {
    $connection = [System.Net.Sockets.TcpClient]::new()
    try { $cacheReady = $connection.ConnectAsync('127.0.0.1',18884).Wait(1000) -and $connection.Connected }
    catch { $cacheReady = $false }
    finally { $connection.Dispose() }
    if (-not $cacheReady) {
        Start-Process -FilePath 'python' -ArgumentList @('-u','P:\work\maven_cache.py') -WindowStyle Hidden `
            -RedirectStandardOutput 'P:\work\maven-cache-dev.log' -RedirectStandardError 'P:\work\maven-cache-dev-error.log' | Out-Null
        Start-Sleep -Milliseconds 800
    }
}
Set-Location 'P:\app'
python "$PSScriptRoot\patch_flutter_links.py" 'P:\work'
if ($LASTEXITCODE -ne 0) { throw 'Could not prepare Flutter junction support' }
$metadata = Get-Content .flutter-plugins-dependencies -Raw | ConvertFrom-Json
$linkRoot = 'P:\app\windows\flutter\ephemeral\.plugin_symlinks'
New-Item -ItemType Directory -Path $linkRoot -Force | Out-Null
foreach ($plugin in $metadata.plugins.windows) {
    $linkPath = Join-Path $linkRoot $plugin.name
    if (-not (Test-Path -LiteralPath $linkPath)) {
        New-Item -ItemType Junction -Path $linkPath -Target $plugin.path | Out-Null
    }
}
$dart = 'P:\work\flutter\bin\cache\dart-sdk\bin\dart.exe'
$flutterTool = 'P:\work\flutter\packages\flutter_tools\bin\flutter_tools.dart'
$packages = 'P:\work\flutter\packages\flutter_tools\.dart_tool\package_config.json'
switch ($Action) {
    'analyze' { & $dart "--packages=$packages" $flutterTool --no-version-check analyze --no-pub }
    'test' { & $dart "--packages=$packages" $flutterTool --no-version-check test --no-pub --reporter expanded }
    'windows' { & $dart "--packages=$packages" $flutterTool --no-version-check build windows --release --no-pub --target lib/main.dart }
    'android' { & $dart "--packages=$packages" $flutterTool --no-version-check build apk --release --no-pub --target lib/main.dart }
    'run' { & $dart "--packages=$packages" $flutterTool --no-version-check run -d windows --no-pub }
}
if ($LASTEXITCODE -ne 0) { throw "Flutter $Action failed ($LASTEXITCODE)" }
