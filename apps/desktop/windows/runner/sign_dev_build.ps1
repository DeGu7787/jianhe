param(
  [Parameter(Mandatory = $true)]
  [string]$ExecutablePath,

  [Parameter(Mandatory = $true)]
  [string]$Configuration
)

if ($Configuration -ne 'Debug') {
  exit 0
}

$certificate = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
  Where-Object {
    $_.Subject -eq 'CN=Jianhe Local Development' -and
    $_.HasPrivateKey -and
    $_.NotAfter -gt (Get-Date)
  } |
  Sort-Object NotAfter -Descending |
  Select-Object -First 1

if ($null -eq $certificate) {
  Write-Warning 'Jianhe local development certificate was not found; leaving the Debug executable unsigned.'
  exit 0
}

$signature = Set-AuthenticodeSignature `
  -LiteralPath $ExecutablePath `
  -Certificate $certificate `
  -HashAlgorithm SHA256

if ($signature.Status -ne 'Valid') {
  throw "Failed to sign Jianhe Debug executable: $($signature.StatusMessage)"
}

Write-Host "Signed Jianhe Debug executable with $($certificate.Thumbprint)."
