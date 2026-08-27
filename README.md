# CrowdStrike Falcon on Azure VMSS — Golden Image (Windows & Linux)

Build a **golden image** with the CrowdStrike Falcon sensor pre-installed using **Azure Image Builder (AIB)** + **Azure Compute Gallery**, then deploy a **Flexible-orchestration Virtual Machine Scale Set (VMSS)** from it. Everything is **Bicep**, deployable from **Deploy to Azure** buttons with guided portal forms. **Windows and Linux** are both supported.

The image is built so it carries the **CID but no Host ID (AID)**. Each VM cloned from the image registers its **own unique AID on first boot** — no runtime scripting, clean scale-out.

| OS | How "no AID in the image" is achieved | Sensor service |
|---|---|---|
| **Windows** | Sensor installed with **`NO_START=1`** — never starts in the image, so no AID is ever generated | `CSFalconService` |
| **Linux** | Vendor script run with **`PREP_GOLDEN_IMAGE=true`** — installs, registers, then **strips the AID** (`falconctl -d -f --aid`) | `falcon-sensor` |

---

## Architecture

```
Step 1 — Golden image                         Step 2 — VMSS
┌─────────────────────────────┐               ┌──────────────────────────────┐
│ Key Vault (created + seeded  │               │ VNet / Subnet / NSG          │
│   from your secure inputs)   │               │ Load Balancer (Standard)     │
│ Azure Image Builder template │  publishes    │ VMSS (Flexible orchestration)│
│  1. OS updates + reboot      │  ─────────▶   │  └─ instances boot → sensor  │
│  2. Install Falcon (last)    │  image ver.   │     auto-starts, unique AID  │
│  3. Generalize / seal        │  to gallery   │ user-assigned identity       │
│ Azure Compute Gallery + def. │               │ Trusted Launch (secure boot) │
└─────────────────────────────┘               └──────────────────────────────┘
```

- **Step 1 creates the Key Vault** and seeds the CrowdStrike secrets from `@secure()` parameters you provide — nothing sensitive lives in this repo, no manual pre-setup.
- The AIB build VM reads those secrets from Key Vault via a **user-assigned managed identity** (granted *Key Vault Secrets User*).
- **CID is baked at build time** (fetched from the Falcon API). The sensor is installed **last**, then the image is generalized.
- VMSS uses **Flexible orchestration**, a **user-assigned identity**, and **Trusted Launch** (secure boot + vTPM) to match the Gen2 image.

---

## Deploy to Azure

Each button opens a **guided, multi-step form** (the portal's `CustomDeploymentBlade` rendering a Form-view definition). Do the [Prerequisites](#prerequisites) once first.

| | Step 1 — Build the golden image | Step 2 — Deploy the VMSS |
|---|---|---|
| **Windows** | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image%2FuiFormDefinition.json) | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss%2FuiFormDefinition.json) |
| **Linux** | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image-linux%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image-linux%2FuiFormDefinition.json) | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss-linux%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss-linux%2FuiFormDefinition.json) |

### Step 1 — Build the golden image

The form asks for your CrowdStrike **API Client ID / Secret** and the **source image**. It creates an RBAC Key Vault (seeded with your secrets), a Compute Gallery + image definition, and the Image Builder template with its managed identity.

- **Windows** source image: choose Publisher / Offer / SKU / Version (SKU is a live dropdown filtered to Gen2).
- **Linux** source image: **Publisher → Offer → SKU → Version are all live, cascading dropdowns** pulled from the Azure API (defaults to Ubuntu Server 22.04 LTS Gen2).

**Then start the build** — deploying only *creates* the Image Builder template; it doesn't run it. Use the portal (**Start build** on the image template) or the CLI:

```bash
# template name: crowdstrike-dev-aib-template (Windows) | crowdstrike-dev-linux-aib-template (Linux)
az resource invoke-action -g <your-rg> \
  --resource-type Microsoft.VirtualMachineImages/imageTemplates \
  --name <template-name> --action Run

# watch until "Succeeded" (~20-40 min)
az resource show -g <your-rg> \
  --resource-type Microsoft.VirtualMachineImages/imageTemplates \
  --name <template-name> --query "properties.lastRunStatus" -o json
```

### Step 2 — Deploy the VMSS

Deploys networking + a Flexible VMSS from the image published in Step 1. Provide the **Key Vault name** and **Image definition name** shown in **Step 1's outputs**, plus a local **admin username / password**, **VM size**, and **instance count**. Use `imageVersion = latest` for the newest published version or pin an exact one.

> Linux instances use password auth by default (mirroring Windows). For production, switch `modules/vmssLinux.bicep` to SSH keys.

---

## Prerequisites

1. **Azure permissions** to create resources **and role assignments** (Owner, or Contributor + User Access Administrator) in the target resource group — both steps assign roles to managed identities.
2. **Register resource providers** (once per subscription):
   ```bash
   for p in Microsoft.VirtualMachineImages Microsoft.Compute Microsoft.Storage Microsoft.KeyVault Microsoft.Network Microsoft.ContainerInstance; do
     az provider register -n $p
   done
   ```
3. **A CrowdStrike Falcon API client** with **Sensor Download (Read)** and **Sensor Update Policies (Read)** scopes. You supply its Client ID/Secret to Step 1 as secure parameters.

> **Sensor version comes from a Sensor Update Policy.** Set `sensorUpdatePolicyName` to a policy that resolves to a version still in the downloadable catalog. Windows defaults to `platform_default`; if that points to an aged-out version in your tenant the build fails at *"Unable to fetch installer details"* — name a current policy instead. On Linux, leaving it empty installs the latest available version.

---

## Secrets (created by Step 1)

Step 1 writes these into the new Key Vault from the parameters you provide. **None live in this repo.**

| Secret name | Source parameter | Required |
|---|---|---|
| `crowdstrike-client-id` | `falconClientId` (secure) | ✅ |
| `crowdstrike-client-secret` | `falconClientSecret` (secure) | ✅ |
| `crowdstrike-falcon-cloud` | `falconCloud` (`us-1`/`us-2`/`eu-1`/`us-gov-1`) | ✅ |
| `crowdstrike-sensor-update-policy` | `sensorUpdatePolicyName` | optional |
| `crowdstrike-prov-token` | `provToken` (secure) | optional |
| `crowdstrike-cid` | `falconCid` (secure) | optional (auto-fetched if omitted) |

---

## Deploy with the CLI (alternative to the buttons)

```bash
# Step 1 — Key Vault + gallery + Image Builder (self-contained). Swap the -linux path for Linux.
az deployment group create -g <your-rg> \
  --template-file deploy/1-golden-image/main.bicep \
  --parameters falconClientId='<id>' falconClientSecret='<secret>' falconCloud='us-1'
  # optional: sensorUpdatePolicyName='<policy>' provToken='<token>' falconCid='<cid>'

# ...start the build (see Step 1) and wait for Succeeded, then:

# Step 2 — VMSS from the image (use the keyVaultName + imageDefinitionName from Step 1 outputs)
az deployment group create -g <your-rg> \
  --template-file deploy/2-vmss/main.bicep \
  --parameters keyVaultName='<kv-from-step1>' imageDefinitionName='<def-from-step1>' \
               adminPassword='<secure-password>' imageVersion='latest'
```

### Publish as Template Specs (optional)

Get the same guided forms from **Template specs → Deploy** in the portal:

```bash
az ts create -g <your-rg> --name crowdstrike-golden-image --version 1.0 --location eastus \
  --template-file deploy/1-golden-image/azuredeploy.json \
  --ui-form-definition deploy/1-golden-image/uiFormDefinition.json
```

### Preview a form without deploying

- **Form view sandbox:** <https://aka.ms/form/sandbox> — paste a `uiFormDefinition.json`.
- **CreateUIDefinition sandbox:** <https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/SandboxBlade> — paste a `createUiDefinition.json`.

> **Forking?** Update the `raw.githubusercontent.com/<owner>/<repo>/<branch>/...` paths in the buttons (both the `uri` template and the `uiFormDefinitionUri`), and **recompile after any Bicep change**: `az bicep build --file deploy/<folder>/main.bicep --outfile deploy/<folder>/azuredeploy.json`.

---

## Verify the sensor on VMSS instances

Flexible-orchestration instances are standard VMs. Each should report the service running and a **unique AID** in the Falcon console.

```bash
az vm list -g <your-rg> --query "[?contains(name,'crowdstrike')].name" -o tsv

# Windows
az vm run-command invoke -g <your-rg> -n <instance> --command-id RunPowerShellScript \
  --scripts "(Get-Service CSFalconService).Status; (Get-Service CSFalconService).StartType"

# Linux
az vm run-command invoke -g <your-rg> -n <instance> --command-id RunShellScript \
  --scripts "systemctl is-active falcon-sensor; sudo /opt/CrowdStrike/falconctl -g --aid"
```

Expect `Running`/`Automatic` (Windows) or `active` (Linux), and a distinct AID per instance.

---

## Updating the image (new sensor version)

The "no AID" state only holds on the **first boot after install** — never re-boot and re-publish a golden image. **Always rebuild** instead:

1. Point `sensorUpdatePolicyName` at the desired version (or bump `imageVersion`).
2. Re-run the Image Builder template (Step 1 build). AIB starts from a clean base image, installs the current sensor last, and seals.
3. Publish the new version and point Step 2 at it (or use `latest`).

See [`scripts/Update-FalconGoldenImage.ps1`](scripts/Update-FalconGoldenImage.ps1) for a runbook.

---

## Repository layout

```
modules/
  keyVault.bicep            # RBAC Key Vault + seeds CrowdStrike secrets from secure params
  computeGallery.bicep      # Compute Gallery + image definition (Trusted Launch; osType Windows|Linux)
  imageBuilder.bicep        # AIB template — Windows (NO_START=1)
  imageBuilderLinux.bicep   # AIB template — Linux (PREP_GOLDEN_IMAGE, Shell customizer)
  networking.bicep          # VNet / Subnet / NSG
  vmss.bicep                # Flexible VMSS — Windows (Trusted Launch)
  vmssLinux.bicep           # Flexible VMSS — Linux (Trusted Launch)
deploy/
  1-golden-image/           # Windows Step 1  ┐ each: main.bicep + azuredeploy.json
  2-vmss/                   # Windows Step 2  │        + uiFormDefinition.json (button form)
  1-golden-image-linux/     # Linux   Step 1  │        + createUiDefinition.json (sandbox/managed-app)
  2-vmss-linux/             # Linux   Step 2  ┘
main.bicep                  # Advanced all-in-one orchestrator (bring-your-own KV; imageOnly|vmssOnly|complete)
parameters.json             # EXAMPLE parameters (placeholders only — no secrets)
scripts/                    # Reference PowerShell (install / update runbooks)
```

---

## Security notes

- **No secrets in this repo.** Step 1 takes them as `@secure()` inputs and writes them to a new Key Vault; `parameters.json` holds placeholders only.
- All secret access uses **managed identities** (AIB build VM and VMSS) — no credentials on disk.
- Secrets are written via ARM (management plane), so the deployer needs only Contributor/Owner — no data-plane role to seed them. The AIB identity is granted *Key Vault Secrets User* to read them at build time.
- NSG is least-privilege; remote-access ports aren't opened unless you pass a source IP range.
- [`.gitignore`](.gitignore) excludes local Claude settings, `.remember/`, and `*.local.json` overrides.
