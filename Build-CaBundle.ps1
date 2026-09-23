#Requires -Version 7.2
using namespace System.Security.Cryptography.X509Certificates
<#
.SYNOPSIS
    Builds a verified CA bundle (intermediate + root) for one or more HTTPS hosts
    and uploads each bundle to Azure Key Vault.

.DESCRIPTION
    For each host, in order:
      1. Connects and records the certificates the server actually sends.
      2. Walks the chain from the leaf up to the root. Missing issuers are
         downloaded from the "CA Issuers" (AIA) URL inside each certificate.
      3. Verifies the leaf against ONLY the bundle (no OS trust store).
      4. Uploads the bundle to Key Vault as a PEM secret, with the secret's
         expiry set to the earliest certificate expiry in the bundle.
    A host that fails any step is reported and never uploaded. The script moves
    on to the next host.

.PARAMETER Url
    One or more hosts. Accepts "sub.mydomain.com", "sub.mydomain.com:8443",
    or "https://sub.mydomain.com/path".

.PARAMETER InputFile
    Text file, one host per line. Optional second column = secret name.
    Lines starting with # are ignored.

.PARAMETER VaultName
    Key Vault to upload to. Leave out to build and verify only.

.PARAMETER SecretPrefix
    Used to name secrets when no name is given: <prefix>-sub-mydomain-com.

.PARAMETER CombinedSecretName
    Also upload one de-duplicated bundle holding every verified host's CAs.
    Use this when one client needs to trust every host in the list.

.PARAMETER ExtraRootCertPath
    PEM/DER root certificate(s) from your PKI team. Needed when a private CA's
    root cannot be downloaded.

.EXAMPLE
    ./Build-CaBundle.ps1 sub.mydomain.com

.EXAMPLE
    ./Build-CaBundle.ps1 -Url a.mydomain.com, b.mydomain.com:8443 -VaultName my-kv

.EXAMPLE
    ./Build-CaBundle.ps1 -InputFile hosts.txt -VaultName my-kv -CombinedSecretName internal-site-public-cert -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)] [string[]] $Url,
    [string]   $InputFile,
    [string]   $VaultName,
    [string]   $SecretPrefix = 'ca-bundle',
    [string]   $CombinedSecretName,
    [string[]] $ExtraRootCertPath,
    [string]   $OutDir = './ca-bundles',
    [int]      $TimeoutSec = 15
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- helpers ----

function ConvertTo-Target([string] $Raw, [string] $SecretName) {
    $u = if ($Raw -match '^[a-z]+://') { [uri]$Raw } else { [uri]"https://$Raw" }
    $port = if ($u.IsDefaultPort) { 443 } else { $u.Port }
    if (-not $SecretName) {
        $SecretName = ("$SecretPrefix-$($u.Host)" -replace '[^A-Za-z0-9-]', '-')
        $SecretName = $SecretName.Substring(0, [Math]::Min(127, $SecretName.Length))
    }
    [pscustomobject]@{ Host = $u.Host; Port = $port; Secret = $SecretName }
}

function Get-ServedCertificate([string] $HostName, [int] $Port) {
    $state = @{ Served = @() }
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        if (-not $tcp.ConnectAsync($HostName, $Port).Wait($TimeoutSec * 1000)) {
            throw "Timed out connecting to ${HostName}:${Port}"
        }
        # Accept any cert here: we only want to see what the server sends.
        $callback = [System.Net.Security.RemoteCertificateValidationCallback] {
            param($s, $cert, $chain, $errors)
            $state.Served = @($chain.ChainPolicy.ExtraStore | ForEach-Object { [X509Certificate2]::new($_) })
            $true
        }.GetNewClosure()
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, $callback)
        $ssl.ReadTimeout = $TimeoutSec * 1000
        $ssl.AuthenticateAsClient($HostName)   # sends SNI
        $leaf = [X509Certificate2]::new($ssl.RemoteCertificate)
        $ssl.Dispose()
    } finally { $tcp.Dispose() }

    # ExtraStore can include the leaf itself; keep it first and unique.
    $others = @($state.Served | Where-Object Thumbprint -ne $leaf.Thumbprint)
    [pscustomobject]@{ Leaf = $leaf; Served = @($leaf) + $others }
}

function Import-CertBytes([byte[]] $Bytes) {
    $col = [X509Certificate2Collection]::new()
    $text = [Text.Encoding]::ASCII.GetString($Bytes)
    if ($text -match '-----BEGIN CERTIFICATE-----') { $col.ImportFromPem($text) }
    else { $col.Import($Bytes) }   # DER or PKCS#7 (.p7c)
    $col
}

function Get-AiaIssuerUri([X509Certificate2] $Cert) {
    $ext = $Cert.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.5.5.7.1.1' }
    if (-not $ext) { return @() }
    $aia = [X509AuthorityInformationAccessExtension]::new($ext.RawData, $ext.Critical)
    @($aia.EnumerateCAIssuersUris())
}

$http = [System.Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

function Find-Issuer([X509Certificate2] $Cert, [X509Certificate2[]] $Pool) {
    $hit = $Pool | Where-Object { $_.Subject -eq $Cert.Issuer -and $_.Thumbprint -ne $Cert.Thumbprint } |
        Select-Object -First 1
    if ($hit) { return [pscustomobject]@{ Cert = $hit; From = 'served/supplied' } }

    foreach ($uri in Get-AiaIssuerUri $Cert) {
        try {
            $bytes = $http.GetByteArrayAsync($uri).GetAwaiter().GetResult()
            $hit = Import-CertBytes $bytes | Where-Object Subject -eq $Cert.Issuer | Select-Object -First 1
            if ($hit) { return [pscustomobject]@{ Cert = $hit; From = $uri } }
        } catch { Write-Verbose "AIA download failed: $uri ($($_.Exception.Message))" }
    }
    $null
}

function Test-Bundle([X509Certificate2] $Leaf, [X509Certificate2[]] $Bundle, [switch] $SystemTrust) {
    $chain = [X509Chain]::new()
    $p = $chain.ChainPolicy
    $p.RevocationMode = 'NoCheck'
    $p.DisableCertificateDownloads = $true
    $roots = @($Bundle | Where-Object { $_.Subject -eq $_.Issuer })
    $Bundle | Where-Object { $_.Subject -ne $_.Issuer } | ForEach-Object { [void]$p.ExtraStore.Add($_) }
    if ($SystemTrust) { $roots | ForEach-Object { [void]$p.ExtraStore.Add($_) } }
    if (-not $SystemTrust) {
        $p.TrustMode = 'CustomRootTrust'
        $roots | ForEach-Object { [void]$p.CustomTrustStore.Add($_) }
    }
    $ok = $chain.Build($Leaf)
    [pscustomobject]@{
        Ok     = $ok
        Status = ($chain.ChainStatus | ForEach-Object { $_.StatusInformation.Trim() }) -join '; '
    }
}

function ConvertTo-Pem([X509Certificate2[]] $Certs) {
    (($Certs | ForEach-Object { $_.ExportCertificatePem() }) -join "`n") + "`n"
}

function Publish-Bundle([string] $Name, [string] $PemPath, [datetime] $Expires) {
    $current = az keyvault secret show --vault-name $VaultName --name $Name --query value -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and ($current -join "`n").Trim() -eq (Get-Content $PemPath -Raw).Trim()) {
        return 'unchanged'
    }
    if (-not $PSCmdlet.ShouldProcess("$VaultName/$Name", 'Upload CA bundle')) { return 'skipped (WhatIf)' }
    az keyvault secret set --vault-name $VaultName --name $Name --file $PemPath `
        --content-type 'application/x-pem-file' `
        --expires $Expires.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') --output none
    if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed for $Name" }
    'uploaded'
}

# ------------------------------------------------------------------ input ----

$targets = [System.Collections.Generic.List[object]]::new()
foreach ($u in @($Url | Where-Object { $_ })) { $targets.Add((ConvertTo-Target $u)) }
if ($InputFile) {
    foreach ($line in Get-Content $InputFile) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $cols = $line -split '\s+'
        $targets.Add((ConvertTo-Target $cols[0] ($cols.Count -gt 1 ? $cols[1] : $null)))
    }
}
if ($targets.Count -eq 0) { throw 'Give at least one host: -Url <host> or -InputFile <file>.' }

if ($VaultName -and -not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) not found. Install it, run "az login", or leave out -VaultName.'
}

$extraRoots = @()
foreach ($path in @($ExtraRootCertPath | Where-Object { $_ })) {
    $extraRoots += @(Import-CertBytes ([IO.File]::ReadAllBytes((Resolve-Path $path))))
}

New-Item -ItemType Directory -Force -Path $OutDir -WhatIf:$false | Out-Null

# ------------------------------------------------------------------- main ----

$results = foreach ($t in $targets) {
    $r = [ordered]@{
        Host = "$($t.Host):$($t.Port)"; Served = 0; CA = '?'; Verified = $false
        Secret = $t.Secret; Action = 'none'; Note = ''
    }
    Write-Host "`n==> $($r.Host)" -ForegroundColor Cyan
    try {
        # 1. What does the server send?
        $got = Get-ServedCertificate $t.Host $t.Port
        $r.Served = $got.Served.Count
        Write-Host "    Server sent $($r.Served) certificate(s)."
        if ($r.Served -eq 1 -and $got.Leaf.Subject -ne $got.Leaf.Issuer) {
            Write-Host '    Server sends only the leaf. Clients that do not fetch missing intermediates will fail.' -ForegroundColor Yellow
        }

        # 2. Walk leaf -> root.
        $pool = @($got.Served) + $extraRoots
        $bundle = [System.Collections.Generic.List[X509Certificate2]]::new()
        $current = $got.Leaf
        Write-Host "    [0] $($current.Subject)"
        if ($current.Subject -eq $current.Issuer) {
            # Self-signed leaf: the only thing to trust is the leaf itself.
            Write-Host '        Leaf is self-signed. The bundle will be the leaf itself.' -ForegroundColor Yellow
            $bundle.Add($current)
        }
        for ($depth = 1; $depth -le 6 -and $current.Subject -ne $current.Issuer; $depth++) {
            $next = Find-Issuer $current $pool
            if (-not $next) {
                Write-Host "        Issuer not found: $($current.Issuer)" -ForegroundColor Yellow
                break
            }
            Write-Host "    [$depth] $($next.Cert.Subject)  <- $($next.From)"
            $bundle.Add($next.Cert)
            $current = $next.Cert
        }
        if ($bundle.Count -eq 0) { throw 'No issuer certificate found. Ask the PKI team for the intermediate and root.' }
        if ($current.Subject -ne $current.Issuer) {
            throw 'Root CA not found (private CA, or a retired root). Get the root from the PKI team and pass -ExtraRootCertPath root.pem.'
        }

        # Public or private CA? Public roots are in the OS trust store.
        $public = Test-Bundle $got.Leaf $bundle -SystemTrust
        $r.CA = $public.Ok ? 'public' : 'private'
        Write-Host "    CA type: $($r.CA) ($($current.Subject))"

        # 3. Verify using ONLY the bundle.
        $check = Test-Bundle $got.Leaf $bundle
        if (-not $check.Ok) { throw "Bundle does not verify the leaf: $($check.Status)" }
        $r.Verified = $true
        Write-Host '    Verified: leaf chains to the bundle root.' -ForegroundColor Green

        $pemPath = Join-Path $OutDir "$($t.Secret).pem"
        [IO.File]::WriteAllText($pemPath, (ConvertTo-Pem $bundle))
        $expires = ($bundle | Measure-Object NotAfter -Minimum).Minimum
        $r.Note = "expires $($expires.ToString('yyyy-MM-dd')); $pemPath"
        $r.Bundle = $bundle

        # 4. Upload.
        if ($VaultName) {
            $r.Action = Publish-Bundle $t.Secret $pemPath $expires
            Write-Host "    Key Vault: $($r.Action) -> $VaultName/$($t.Secret)"
        }
    } catch {
        $r.Note = $_.Exception.GetBaseException().Message
        Write-Host "    FAILED: $($r.Note)" -ForegroundColor Red
    }
    [pscustomobject]$r
}

# Optional: one combined bundle for every verified host.
$verified = @($results | Where-Object Verified)
if ($CombinedSecretName -and $verified.Count -gt 0) {
    # Intermediates first, then roots: some clients need each intermediate before its root.
    $seen = @{}
    $unique = @($verified | ForEach-Object { $_.Bundle } | Where-Object { -not $seen.ContainsKey($_.Thumbprint) -and ($seen[$_.Thumbprint] = $true) })
    $all = @($unique | Where-Object { $_.Subject -ne $_.Issuer }) + @($unique | Where-Object { $_.Subject -eq $_.Issuer })
    $pemPath = Join-Path $OutDir "$CombinedSecretName.pem"
    [IO.File]::WriteAllText($pemPath, (ConvertTo-Pem $all))
    $expires = ($all | Measure-Object NotAfter -Minimum).Minimum
    Write-Host "`n==> Combined bundle: $($all.Count) unique cert(s) -> $pemPath" -ForegroundColor Cyan
    if ($VaultName) {
        $action = Publish-Bundle $CombinedSecretName $pemPath $expires
        Write-Host "    Key Vault: $action -> $VaultName/$CombinedSecretName"
    }
}

$http.Dispose()
Write-Host ''
$results | Select-Object Host, Served, CA, Verified, Secret, Action, Note | Format-Table -AutoSize -Wrap
if (@($results | Where-Object { -not $_.Verified }).Count -gt 0) { exit 1 }
