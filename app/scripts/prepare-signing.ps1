$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$developmentRoot = Split-Path -Parent $projectRoot
$signingRoot = Join-Path $developmentRoot 'work\signing'
New-Item -ItemType Directory -Path $signingRoot -Force | Out-Null
$keystorePath = Join-Path $signingRoot 'focus-garden.jks'
$secretPath = Join-Path $signingRoot 'credentials.json'
if (-not (Test-Path -LiteralPath $keystorePath)) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $secret = [Convert]::ToBase64String($bytes)
    $env:FOCUS_KEYSTORE_PASSWORD = $secret
    $jdk = Get-ChildItem (Join-Path $developmentRoot 'work\jdk') -Directory | Select-Object -First 1
    & (Join-Path $jdk.FullName 'bin\keytool.exe') -genkeypair -noprompt -keystore $keystorePath -storetype JKS -alias focusgarden -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=Focus Garden, O=Personal Offline Apps, C=CN' -storepass:env FOCUS_KEYSTORE_PASSWORD -keypass:env FOCUS_KEYSTORE_PASSWORD
    if ($LASTEXITCODE -ne 0) { throw 'Could not create Android signing key' }
    @{ password=$secret; alias='focusgarden' } | ConvertTo-Json | Set-Content -LiteralPath $secretPath -Encoding utf8
    Remove-Item Env:FOCUS_KEYSTORE_PASSWORD
}
$credentials = Get-Content -LiteralPath $secretPath -Raw | ConvertFrom-Json
$propertyPath = Join-Path $projectRoot 'android\key.properties'
$keyPath = $keystorePath.Replace('\','/')
@("storeFile=$keyPath", "storePassword=$($credentials.password)", "keyPassword=$($credentials.password)", "keyAlias=$($credentials.alias)") | Set-Content -LiteralPath $propertyPath -Encoding utf8
Write-Output 'Android release signing is ready. Keep work/signing private and backed up.'
