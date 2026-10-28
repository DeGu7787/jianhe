param(
  [string]$ApiBaseUrl = 'https://jianhe.neodaas.com',
  # Keep in step with pubspec.yaml, the installer and the landing page.
  [string]$AppVersion = '0.1.10'
)

$ErrorActionPreference = 'Stop'

$parsedApiBaseUrl = $null
if (-not [Uri]::TryCreate($ApiBaseUrl, [UriKind]::Absolute, [ref]$parsedApiBaseUrl) -or
    $parsedApiBaseUrl.Scheme -ne 'https' -or
    -not [string]::IsNullOrEmpty($parsedApiBaseUrl.Query) -or
    -not [string]::IsNullOrEmpty($parsedApiBaseUrl.Fragment) -or
    ($parsedApiBaseUrl.AbsolutePath -ne '/')) {
  throw 'ApiBaseUrl must be an HTTPS origin, for example https://jianhe.neodaas.com'
}

$repositoryRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
# Prefer a portable SDK under .tooling\flutter (git-ignored); otherwise use the
# Flutter SDK on PATH.
$flutterExecutable = Join-Path $repositoryRoot '.tooling\flutter\bin\flutter.bat'
$dartExecutable = Join-Path $repositoryRoot '.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe'
if (-not (Test-Path -LiteralPath $flutterExecutable)) {
  $onPath = Get-Command flutter -ErrorAction SilentlyContinue
  if ($onPath) {
    $flutterExecutable = $onPath.Source
    $dartExecutable = Join-Path (Split-Path $onPath.Source) 'cache\dart-sdk\bin\dart.exe'
  }
}
$desktopDirectory = Join-Path $repositoryRoot 'apps\desktop'
$cliDirectory = Join-Path $repositoryRoot 'apps\cli'
$releaseDirectory = Join-Path $desktopDirectory 'build\windows\x64\runner\Release'
$cliBundleDirectory = Join-Path $releaseDirectory 'cli'

if (-not (Test-Path -LiteralPath $flutterExecutable)) {
  throw "Flutter executable not found: $flutterExecutable"
}
if (-not (Test-Path -LiteralPath $dartExecutable)) {
  throw "Dart executable not found: $dartExecutable"
}

Push-Location $desktopDirectory
try {
  & $flutterExecutable build windows --release `
    --dart-define="JIANHE_API_BASE_URL=$ApiBaseUrl" `
    --dart-define="JIANHE_APP_VERSION=$AppVersion"
  if ($LASTEXITCODE -ne 0) {
    throw 'Flutter Windows release build failed.'
  }
}
finally {
  Pop-Location
}

Push-Location $cliDirectory
try {
  & $dartExecutable build cli --target 'bin\jianhe.dart' --output $cliBundleDirectory
  if ($LASTEXITCODE -ne 0) {
    throw 'Jianhe CLI bundle build failed.'
  }
}
finally {
  Pop-Location
}

Write-Output "Windows release ready: $releaseDirectory"
