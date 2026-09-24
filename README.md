# Put a server's CA chain in Key Vault and mount it into a container

Fixes errors like `unable to verify leaf signature`, `unable to get local issuer certificate`, and `certificate signed by unknown authority`.

## Get the script

```sh
git clone https://github.com/gunwadev/keyvault-ca-bundle.git
cd keyvault-ca-bundle
```

Or download [`Build-CaBundle.ps1`](Build-CaBundle.ps1) and [`hosts.example.txt`](hosts.example.txt) directly.

## Prerequisites

| Tool | Needed for | Windows | Mac | Linux |
|---|---|---|---|---|
| PowerShell 7.2+ | Running the script | `winget install Microsoft.PowerShell` | `brew install --cask powershell` | [Microsoft install guide](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux) |
| Azure CLI | Uploading to Key Vault | `winget install Microsoft.AzureCLI` | `brew install azure-cli` | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` |
| Terraform | Granting ESO read access to the vault | `winget install Hashicorp.Terraform` | `brew install hashicorp/tap/terraform` | [HashiCorp install guide](https://developer.hashicorp.com/terraform/install) |
| OpenSSL | The pipeline task, and checking a server by hand. `Build-CaBundle.ps1` doesn't need it. | `winget install ShiningLight.OpenSSL.Light`, or use the one in Git Bash | Already installed | `sudo apt install openssl` |

The script needs PowerShell 7 (`pwsh`). The built-in Windows PowerShell 5.1 (`powershell.exe`) won't run it. Check with `pwsh -v`.

Azure Cloud Shell already has PowerShell 7, Azure CLI, Terraform, and OpenSSL.

You also need:

- An Azure Key Vault that already exists. Note its name and the subscription it's in.
- Network access to each server. Use the VPN for internal hosts.
- The **Key Vault Secrets Officer** role on the vault, to upload.
- External Secrets Operator (ESO) in the cluster, with a `ClusterSecretStore` for the vault.

No Key Vault yet? Create one and give yourself upload rights:

```sh
az keyvault create --name my-kv --resource-group rg-shared --location eastus --enable-rbac-authorization true
az role assignment create --role "Key Vault Secrets Officer" \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --scope "$(az keyvault show --name my-kv --query id -o tsv)"
```

Vault names are global across Azure, so pick a unique one. The role can take a few minutes to apply.

## The terms, in one line each

- **Leaf certificate:** the server's own certificate, for example `*.mydomain.com`.
- **Intermediate certificate:** the certificate that signed the leaf.
- **Root certificate:** the certificate that signed the intermediate. It signs itself. Clients keep a list of roots they trust.
- **Chain:** leaf, then intermediate, then root. A client trusts the leaf only if it can follow the chain up to a root it trusts.
- **CA bundle:** one `.pem` file holding the intermediate and root, stacked.
- **ESO (External Secrets Operator):** a Kubernetes add-on that copies secrets from Key Vault into Kubernetes Secrets and keeps them in sync.
- **Private CA:** a company's own root. It isn't in the public trust list, so clients must be given it. The root certificate is not secret. Only its private key is.
- **Why it matters:** the server should send the leaf and the intermediate. If it sends only the leaf, most clients can't build the chain and refuse to connect. Browsers fetch the missing piece on their own, so the site still works in Chrome.

The script reads each certificate's built-in link to the certificate that signed it. It follows those links to rebuild the chain, checks the result, and uploads it to Key Vault.

## Steps

**1. Sign in to Azure and select the Key Vault's subscription.** Commands like `az keyvault show` and role assignments only search the active subscription, so it must be the one that holds the vault.

```sh
az login

# Find which subscription the vault is in
az graph query -q "resources | where type =~ 'microsoft.keyvault/vaults' and name =~ 'my-kv' | project subscriptionId, resourceGroup"

# Select that subscription, then confirm the vault is visible
az account set --subscription "<subscriptionId from above>"
az keyvault show --name my-kv --query name -o tsv
```

The first `az graph` run may ask to install the `resource-graph` extension. Say yes. You can also find the subscription in the Azure portal, on the vault's Overview page.

**2. Check the server (optional).** A `1` means it sends only the leaf.

```sh
openssl s_client -connect sub.mydomain.com:443 -servername sub.mydomain.com -showcerts </dev/null 2>/dev/null | grep -c 'BEGIN CERT'
```

**3. List your hosts** in `hosts.txt`, one per line. An optional second column sets the Key Vault secret name.

```
sub.mydomain.com
https://api.mydomain.com/health   internal-api-ca
reports.mydomain.com:8443
```

**4. Do a dry run.** Nothing is uploaded.

```powershell
pwsh ./Build-CaBundle.ps1 -InputFile hosts.txt -VaultName my-kv -CombinedSecretName internal-ca-bundle -WhatIf
```

Each host should end with `Verified: leaf chains to the bundle root.` The run also prints `CA type: public` or `private` for each host.

**5. If a host says `Root CA not found`**, it uses a private CA. Get its root with one of these, then add `-ExtraRootCertPath ./company-root.pem` to the command.

- Run the script again from inside the company network or VPN. It may download the root on its own.
- Export it from a company laptop. Replace `Contoso` with the company name from the issuer.

  Windows:
  ```powershell
  $root = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like '*Contoso*' | Select-Object -First 1
  $root.Subject   # check it's the right one
  [IO.File]::WriteAllText("$PWD/company-root.pem", $root.ExportCertificatePem())
  ```

  Mac:
  ```sh
  security find-certificate -a -c "Contoso" -p /Library/Keychains/System.keychain > company-root.pem
  ```

- Ask the PKI or IT team for the root CA certificate.

A wrong file can't do harm. Verification fails and nothing is uploaded.

**6. Upload to Key Vault.**

CA certificates are stored as Key Vault **secrets**, not certificate objects. Certificate objects need a private key, and you don't have (or need) one for a CA.

Run the same command as the dry run, without `-WhatIf`. The script skips any host that fails verification, and skips hosts whose bundle hasn't changed.

```powershell
pwsh ./Build-CaBundle.ps1 -InputFile hosts.txt -VaultName my-kv -CombinedSecretName internal-ca-bundle
```

To upload a `.pem` file by hand instead, this is the same `az` command the script runs:

```sh
az keyvault secret set --vault-name my-kv --name internal-ca-bundle \
  --file ./ca-bundles/internal-ca-bundle.pem \
  --content-type application/x-pem-file \
  --expires 2028-09-02T23:59:59Z   # the earliest expiry the script printed
```

**7. Let External Secrets Operator read the vault.** ESO's identity needs **Key Vault Secrets User** on the vault.

Most clusters already have this set up. To check without cluster access, look in the GitOps repo for other `ExternalSecret` files. If they use a `ClusterSecretStore` or `SecretStore` that points at your vault (its `vaultUrl`), ESO can already read it.

If you have `kubectl` access, you can check directly (optional):

```sh
kubectl get clustersecretstore   # READY should be True
kubectl get clustersecretstore azure-keyvault -o jsonpath='{.spec.provider.azurekv.vaultUrl}'
```

If a store is ready and points at your vault, skip the rest of this step. No Terraform is needed. If not, add the role with Terraform:

```hcl
data "azurerm_key_vault" "kv" {
  name                = "my-kv"
  resource_group_name = "rg-shared"
}

resource "azurerm_role_assignment" "eso_reads_kv" {
  scope                = data.azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.eso_identity_principal_id   # ESO's managed identity
}
```

**8. Create the ExternalSecret** in your GitOps repo. This assumes a `ClusterSecretStore` named `azure-keyvault` already points at the vault.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: internal-site-public-cert
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: azure-keyvault
  target:
    name: internal-site-public-cert    # the Kubernetes Secret ESO creates
  data:
    - secretKey: internal-ca-bundle.pem  # becomes the file name. Must end in .pem
      remoteRef:
        key: internal-ca-bundle          # the Key Vault secret name
```

Use the same `apiVersion` as the other `ExternalSecret` files in your repo. Older ESO releases use `external-secrets.io/v1beta1`.

**Test checkpoint.** After the pipeline applies the ExternalSecret, check that it synced before you change the Deployment. Any one of these works:

- **GitOps tool dashboard** (Argo CD, Flux UI): the `internal-site-public-cert` ExternalSecret shows healthy or synced.
- **Azure portal:** open the AKS cluster, go to **Kubernetes resources > Configuration > Secrets**, and look for `internal-site-public-cert` in the namespace.
- **kubectl (optional):**

  ```sh
  kubectl -n monitoring get externalsecret internal-site-public-cert   # STATUS: SecretSynced
  kubectl -n monitoring get secret internal-site-public-cert \
    -o jsonpath='{.data.internal-ca-bundle\.pem}' | base64 -d | grep -c 'BEGIN CERT'
  ```

  The count should match the certificates the script uploaded.

That confirms Key Vault and ESO work. The container still won't trust the server until step 9 mounts the Secret.

**9. Mount it into the container.** Add this to the Deployment in your GitOps repo:

```yaml
spec:
  template:
    spec:
      containers:
        - name: dd-synthetics-worker    # your container's name
          volumeMounts:
            - name: corporate-ca-volume
              mountPath: /etc/datadog/certs/   # Datadog's custom CA folder. See the table below for others.
              readOnly: true
      volumes:
        - name: corporate-ca-volume
          secret:
            secretName: internal-site-public-cert   # the Secret ESO creates
```

Where the certificate goes depends on the container:

| Container | Mount path | Notes |
|---|---|---|
| ⭐ Datadog Synthetics private location worker | `/etc/datadog/certs/` | Loads every `.pem` file in the folder ([Datadog docs](https://docs.datadoghq.com/synthetics/platform/private_locations/#custom-root-certificates)). Intermediate must come before root in the file. The script's bundles already are in that order. |
| Prometheus Blackbox Exporter | Your choice, e.g. `/etc/blackbox/certs/` | Set `tls_config.ca_file` in the probe module to the file ([docs](https://github.com/prometheus/blackbox_exporter/blob/master/CONFIGURATION.md)). |
| Elastic Heartbeat | Your choice, e.g. `/usr/share/heartbeat/certs/` | Set `ssl.certificate_authorities` on the monitor to the file ([docs](https://www.elastic.co/guide/en/beats/heartbeat/current/configuration-ssl.html)). |
| Anything else | The folder its docs name for custom CA files | If it has none, use an environment variable (below). |

Blackbox Exporter (`blackbox.yml`):

```yaml
modules:
  http_internal:
    prober: http
    http:
      tls_config:
        ca_file: /etc/blackbox/certs/internal-ca-bundle.pem
```

Elastic Heartbeat (`heartbeat.yml`):

```yaml
heartbeat.monitors:
  - type: http
    id: internal-site
    urls: ["https://sub.mydomain.com"]
    schedule: "@every 1m"
    ssl:
      certificate_authorities: ["/usr/share/heartbeat/certs/internal-ca-bundle.pem"]
```

In both, the setting replaces the built-in trust list for that check. Use a separate module or monitor for public sites.

Mount the whole folder, not a single file with `subPath`, because `subPath` mounts never update.

If the container has no such folder, set an environment variable that points at the file instead:

| Container runtime | Setting |
|---|---|
| Node.js | `NODE_EXTRA_CA_CERTS=/etc/ssl/internal/internal-ca-bundle.pem` |
| Python requests | `REQUESTS_CA_BUNDLE=/etc/ssl/internal/internal-ca-bundle.pem` |
| curl, OpenSSL, Go | `SSL_CERT_FILE=/etc/ssl/internal/internal-ca-bundle.pem` |

The Python and curl settings replace the built-in trust list. If the container also calls public sites, add the system bundle to the same file.

**10. Push and test.** Commit the Deployment change and let the pipeline apply it. Adding the volume changes the pod template, so the pods restart on their own and load the certificate.

Then test the connection that was failing.

Optional checks: the GitOps dashboard shows the Deployment healthy with new pods. With `kubectl` access, you can also list the mounted files:

```sh
kubectl -n monitoring exec deploy/<your-deployment> -- ls /etc/datadog/certs/
```

**When the certificate changes,** redo step 6. ESO picks up the new value within `refreshInterval`. Many containers read CA files only at startup, so restart the pods too. Through the pipeline, change an annotation on the pod template and push:

```yaml
spec:
  template:
    metadata:
      annotations:
        ca-bundle-updated: "2026-09-23"   # change this date to restart the pods
```

**11. Fix it at the source.** If the server sent only its leaf, ask the server team to configure it to send the leaf and intermediate together. After that, clients need nothing extra, and you can remove all of this. A private CA is different: trusting its root is the normal setup, so keep the bundle.

## Run it in a pipeline instead

[`azure-pipelines.yml`](azure-pipelines.yml) does step 6 as one Azure DevOps task, on a weekly schedule. It uses OpenSSL and curl, not PowerShell. Nothing is committed: each run downloads the certificates from the server and uploads them to Key Vault.

1. Set the variables at the top: `certHosts` (space-separated) and `vaultName`. Each host is uploaded as `ca-bundle-<host-with-dashes>`, and the last step lists every CA bundle in the vault.
2. Set `azureSubscription` to a service connection whose identity has **Key Vault Secrets Officer** on the vault.
3. Use a Linux agent pool that can reach the host. Linux agents already have bash, OpenSSL, and curl. Microsoft-hosted agents can't reach internal servers.
4. In Azure DevOps, create a pipeline from this file.

The task handles hosts whose CA can be downloaded. For several hosts or a private CA root, run `Build-CaBundle.ps1` in the task instead.

## Script options

| Option | What it does |
|---|---|
| `-Url a.com, b.com:8443` | Hosts on the command line, instead of or as well as `-InputFile` |
| `-InputFile hosts.txt` | Hosts from a file |
| `-VaultName my-kv` | Upload to this vault. Leave it out to only build and verify. |
| `-CombinedSecretName name` | Also upload one bundle for all hosts |
| `-SecretPrefix ca-bundle` | Default secret name: `ca-bundle-sub-mydomain-com` |
| `-ExtraRootCertPath root.pem` | A root you exported or got from IT |
| `-OutDir ./ca-bundles` | Where the `.pem` files are saved |
| `-WhatIf` | Dry run, no upload |

Tested with PowerShell 7.4 on Linux. Not yet tested on Windows.
