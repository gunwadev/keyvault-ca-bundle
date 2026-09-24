# keyvault-ca-bundle

Builds a verified CA bundle (intermediate + root) for HTTPS hosts, uploads it to Azure Key Vault as a secret, and documents how to mount it into a container. Public repo: `README.md` is the published guide.

## Never

- **Never commit identifying details.** This repo is public. No real hostnames, org, subscription, tenant, vault, or domain names. Use the placeholders already in `README.md` (`sub.mydomain.com`, `my-kv`, `Contoso`, `rg-shared`). Local test specifics go in `CLAUDE.local.md` (gitignored).
- **Never push an unverified pipeline file.** Check that `azure-pipelines.yml` parses and is non-empty before any push. An empty file was pushed once when a download step failed silently.
- **Never upload a bundle that failed verification.** Both implementations check the chain before uploading. Keep it that way.

## Two implementations of the same job

- `Build-CaBundle.ps1`: PowerShell 7 and .NET only, no OpenSSL. Handles many hosts, combined bundles, private roots (`-ExtraRootCertPath`), `-WhatIf`.
- `azure-pipelines.yml`: inline bash with OpenSSL and curl, for Linux build agents. Manual trigger only (`trigger: none`, no schedule).

A fix to chain-walking logic usually belongs in both. Why they differ, and the real-world chain quirks each must handle: `decisions.md`, entries "Pipeline task uses bash + OpenSSL" and "Pipeline task: real-world chain quirks".

## Test commands

PowerShell 7 isn't installed on the dev Mac. Run everything in the .NET SDK container, which has `pwsh`, `openssl`, and `curl` (use `--platform linux/arm64` on Apple silicon):

```sh
# PowerShell script, dry run against public test hosts
docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w mcr.microsoft.com/dotnet/sdk:8.0 \
  pwsh -NoLogo -Command './Build-CaBundle.ps1 -Url incomplete-chain.badssl.com, google.com -OutDir /tmp/out'
# Use -Command, not -File: with -File, "-Url a, b" is not parsed as a list.

# Pipeline YAML parses
python3 -c "import yaml; yaml.safe_load(open('azure-pipelines.yml'))"
```

To test the pipeline's inline script: extract the first `inlineScript` block, put a fake `az` first on `PATH` that echoes its arguments, and run it with `CERTHOSTS` and `VAULTNAME` set.

Test hosts that cover the known cases: `incomplete-chain.badssl.com` (server sends leaf only), `google.com` (cross-signed root), `github.com` (Sectigo `.p7c` issuer), `learn.microsoft.com` (two issuer URLs), `self-signed.badssl.com`, `expired.badssl.com` (must fail).

## Writing style

`README.md` is read by people with low reading energy. Short complete sentences, answer first, numbered steps. No em dashes or smart quotes. Datadog is one example among several, not the subject.

## Before finishing

Append a `decisions.md` entry for any non-obvious choice or gotcha. Never edit old entries.
