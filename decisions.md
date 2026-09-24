# Decisions

## 2026-09-23 PowerShell 7 only, no OpenSSL
The script uses .NET 7+ APIs (AIA extension parsing, CustomRootTrust chain building, PEM export). Windows PowerShell 5.1 lacks them. Rejected: shelling out to openssl, because it is not installed on most Windows machines.

## 2026-09-23 Store CA bundles as Key Vault secrets, not certificate objects
Key Vault certificate objects require a private key. A CA bundle has none.

## 2026-09-23 Intermediates before roots in every bundle
Datadog's private location worker requires the intermediate to precede the root in a combined file. The combined bundle used to be sorted by thumbprint, which could put a root first.

## 2026-09-23 Verify against the bundle alone before uploading
Chain building uses CustomRootTrust with downloads disabled, so a bundle is uploaded only if it proves the leaf without the machine's trust store.

## 2026-09-23 Pipeline task uses bash + OpenSSL, the script stays PowerShell
The pipeline task runs on Linux agents, which always have openssl and curl, so it needs no PowerShell 7 install. Build-CaBundle.ps1 stays .NET-only so it runs on Windows without OpenSSL.
