# CrowdStrike Falcon on Azure VMSS — Golden Image (Windows)

Build a **Windows golden image** with the CrowdStrike Falcon sensor pre-installed using **Azure Image Builder (AIB)** + **Azure Compute Gallery (ACG)**, then deploy a **Flexible-orchestration Virtual Machine Scale Set (VMSS)** from that image. Everything is defined in **Bicep** and deployable with two **Deploy to Azure** buttons.

The sensor is installed during the image build with **`NO_START=1`**, so the image itself never starts the sensor and never receives a Host ID (AID). When a VM is created from the image, the sensor **starts automatically on first boot and registers its own unique AID** — no runtime scripting required, which makes scale‑out clean.

---

## Architecture

```
Step 1 (golden image)                         Step 2 (VMSS)
┌─────────────────────────────┐               ┌──────────────────────────────┐
│ Key Vault (created + seeded  │               │ VNet / Subnet / NSG          │
│   from your secure inputs)   │               │ Load Balancer (Standard)     │
│ Azure Image Builder template │  publishes    │ VMSS (Flexible)              │
│  1. Windows Update + reboot  │  ─────────▶   │  └─ instances boot → sensor  │
│  2. Install Falcon NO_START=1│   image ver.  │     auto-starts, unique AID  │
│  3. Sysprep / generalize     │   to gallery  │                              │
│ Azure Compute Gallery + def. │               │ user-assigned identity       │
└─────────────────────────────┘               └──────────────────────────────┘
```

Key design points:
- **Step 1 creates the Key Vault and seeds the CrowdStrike secrets** from `@secure()` parameters you provide at deploy time — nothing sensitive lives in this repo, and there is no manual pre-setup.
- The AIB build VM reads those secrets from Key Vault using a **user-assigned managed identity** (granted *Key Vault Secrets User*).
- **CID is baked at build time** (retrieved from the CrowdStrike API) together with `NO_START=1`. Because the sensor never starts in the image, no AID is generated there — each clone gets its own.
- **Flexible orchestration** VMSS (user-assigned identity, Trusted Launch, secure boot + vTPM).

---

## Deploy to Azure

> Do the small [Prerequisites](#prerequisites) first (permissions + resource providers + a CrowdStrike API client). Step 1 builds everything else — including the Key Vault.

### Step 1 — Create the Key Vault, gallery, and Image Builder (then build)

You provide the CrowdStrike **API Client ID/Secret** (and cloud) as secure inputs. The template creates an RBAC Key Vault, stores the secrets, creates the Compute Gallery + image definition, and the Image Builder template with its managed identity.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image%2FuiFormDefinition.json)

This button opens a **guided form** (the portal's `CustomDeploymentBlade` renders `deploy/1-golden-image/uiFormDefinition.json`).

**Then start the image build.** Deploying only *creates* the Image Builder template — it doesn't build. Start it either way:

- **Portal (easiest):** open the image template resource (`crowdstrike-dev-aib-template`) and click **Start build**.
- **CLI:**
  ```bash
  az resource invoke-action \
    --resource-group <your-rg> \
    --resource-type Microsoft.VirtualMachineImages/imageTemplates \
    --name crowdstrike-dev-aib-template \
    --action Run

  # Watch until "Succeeded" (~25-40 min):
  az resource show -g <your-rg> \
    --resource-type Microsoft.VirtualMachineImages/imageTemplates \
    --name crowdstrike-dev-aib-template \
    --query "properties.lastRunStatus" -o json
  ```

### Step 2 — Deploy the VMSS from the golden image

Deploys networking + a Flexible VMSS from the image published in Step 1. Pass the **same Key Vault name** that Step 1 created (shown in Step 1's outputs).

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss%2FuiFormDefinition.json)

This button opens a **guided form** (renders `deploy/2-vmss/uiFormDefinition.json`). Use `imageVersion = latest` for the newest published version, or pin an exact version.

---

## Guided portal forms

The **Deploy to Azure** buttons above open a **guided, multi-step form** — not the raw parameter list. They use the portal's `CustomDeploymentBlade`, which takes both the template and a **Form view** definition:

```
https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/<template>/uiFormDefinitionUri/<uiFormDefinition>
```

Each step ships a [`uiFormDefinition.json`](deploy/) (Form view schema `2021-09-09`) that the button references, plus a [`createUiDefinition.json`](deploy/) (the Managed Applications format) for the sandbox / a managed-app package.

- **Step 1** — CrowdStrike **API Client ID / Secret** and the **source image** Publisher / Offer / SKU / Version.
- **Step 2** — local **admin username / password**, **Key Vault name**, **image version**, **VM size**, **instance count**.

> If you fork this repo, update the button URLs to point at **your** `raw.githubusercontent.com/<owner>/<repo>/<branch>/...` paths for both the `uri` (template) and `uiFormDefinitionUri` (form).

### Alternative: publish as Template Specs

Same forms, deployed from **Template specs → Deploy** in the portal instead of a button:

```bash
az ts create -g <your-rg> --name crowdstrike-golden-image --version 1.0 --location eastus \
  --template-file deploy/1-golden-image/azuredeploy.json \
  --ui-form-definition deploy/1-golden-image/uiFormDefinition.json

az ts create -g <your-rg> --name crowdstrike-vmss --version 1.0 --location eastus \
  --template-file deploy/2-vmss/azuredeploy.json \
  --ui-form-definition deploy/2-vmss/uiFormDefinition.json
```

### Preview without deploying

- **Form view sandbox:** <https://aka.ms/form/sandbox> — paste a `uiFormDefinition.json` to preview.
- **CreateUIDefinition sandbox:** <https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/SandboxBlade> — paste a `createUiDefinition.json` to preview.

> The blue buttons remain valid for a quick deploy with the basic parameter form; the Template Specs above are the way to get the guided form.

---

## Prerequisites

1. **Azure permissions.** Rights to create resources **and role assignments** (Owner, or Contributor + User Access Administrator) in the target resource group — both steps assign roles to managed identities.

2. **Register resource providers** (once per subscription):
   ```bash
   for p in Microsoft.VirtualMachineImages Microsoft.Compute Microsoft.Storage Microsoft.KeyVault Microsoft.Network Microsoft.ContainerInstance; do
     az provider register -n $p
   done
   ```

3. **A CrowdStrike Falcon API client** with these scopes (used only during the image build):
   - **Sensor Download** — *Read*
   - **Sensor Update Policies** — *Read*

   You supply its **Client ID** and **Client Secret** to Step 1 as secure parameters. That's it — Step 1 creates the Key Vault and stores them for you.

> **Sensor version comes from a Windows *Sensor Update Policy*.** The build resolves the version from the policy you name in `sensorUpdatePolicyName` (defaults to `platform_default`). If that policy points to a version no longer in the downloadable installer catalog, the build fails at "Unable to fetch installer details" — set it to a policy that targets a current, available version.

---

## Secrets (created by Step 1)

Step 1 writes these into the new Key Vault from the parameters you provide. **None of them live in this repo.**

| Secret name | Source parameter | Required |
|---|---|---|
| `crowdstrike-client-id` | `falconClientId` (secure) | ✅ |
| `crowdstrike-client-secret` | `falconClientSecret` (secure) | ✅ |
| `crowdstrike-falcon-cloud` | `falconCloud` (`us-1`/`us-2`/`eu-1`/`us-gov-1`) | ✅ |
| `crowdstrike-sensor-update-policy` | `sensorUpdatePolicyName` | optional (defaults to `platform_default`) |
| `crowdstrike-prov-token` | `provToken` (secure) | optional |

The CID is retrieved automatically from the CrowdStrike API during the build and baked into the image with `NO_START=1`.

---

## Deploy with the CLI (alternative to the buttons)

```bash
# Step 1 — Key Vault + gallery + Image Builder (self-contained)
az deployment group create -g <your-rg> \
  --template-file deploy/1-golden-image/main.bicep \
  --parameters falconClientId='<api-client-id>' \
               falconClientSecret='<api-client-secret>' \
               falconCloud='us-1'
# (optional) sensorUpdatePolicyName='<windows-sensor-update-policy>' provToken='<token>'

# ...trigger the build (see Step 1 above) and wait for Succeeded, then:

# Step 2 — VMSS from the image (use the keyVaultName from Step 1 outputs)
az deployment group create -g <your-rg> \
  --template-file deploy/2-vmss/main.bicep \
  --parameters keyVaultName='<kv-from-step1>' \
               adminPassword='<secure-password>' \
               imageVersion='latest'
```

> **Advanced / all-in-one:** the root [`main.bicep`](main.bicep) supports `deploymentMode` = `imageOnly` | `vmssOnly` | `complete` against an **existing** Key Vault (bring-your-own). The `deploy/` step templates above are the recommended path and are what the buttons use.

---

## Verify the sensor on VMSS instances

Flexible-orchestration instances are standard VMs:

```bash
az vm list -g <your-rg> --query "[?contains(name,'crowdstrike')].name" -o tsv

az vm run-command invoke -g <your-rg> -n <instance-name> \
  --command-id RunPowerShellScript \
  --scripts "(Get-Service CSFalconService).Status; (Get-Service CSFalconService).StartType"
```

Expect `Running` / `Automatic`, and each host appears in the Falcon console (Host Management → Hosts) with its own unique AID.

---

## Updating the image (new sensor version)

`NO_START=1` is only honored on the **first boot after install**. If a golden image is ever booted again, the sensor starts and gets an AID — which must never propagate to clones. So **always rebuild** rather than modifying an existing image:

1. Point `sensorUpdatePolicyName` at the desired version (or bump `imageVersion`).
2. Re-run the Image Builder template (Step 1 build command). AIB starts from a clean base image, installs the current sensor last with `NO_START=1`, and seals without a post-install reboot.
3. Publish the new version and update Step 2 to reference it (or use `latest`).

See [`scripts/Update-FalconGoldenImage.ps1`](scripts/Update-FalconGoldenImage.ps1) for a documented runbook.

---

## Repository layout

```
main.bicep                        # Advanced all-in-one orchestrator (existing KV; imageOnly|vmssOnly|complete)
parameters.json                   # EXAMPLE parameters for main.bicep (placeholders only — no secrets)
modules/
  keyVault.bicep                  # Creates RBAC Key Vault + seeds CrowdStrike secrets from secure params
  computeGallery.bicep            # Azure Compute Gallery + image definition (Trusted Launch)
  imageBuilder.bicep              # Azure Image Builder template + identity + role assignments
  networking.bicep                # VNet / Subnet / NSG
  vmss.bicep                      # Flexible VMSS from the gallery image (Trusted Launch)
deploy/
  1-golden-image/                 # Button 1: self-contained (KV + gallery + AIB) + azuredeploy.json + uiFormDefinition.json + createUiDefinition.json
  2-vmss/                         # Button 2: networking + VMSS + azuredeploy.json + uiFormDefinition.json + createUiDefinition.json
scripts/
  Install-FalconGoldenImage.ps1   # Reference: sensor install (NO_START=1) used by AIB
  Update-FalconGoldenImage.ps1    # Reference: image update runbook
  Register-FalconOnBoot.ps1       # Reference only (not used — CID is baked, sensor self-registers)
```

> If you fork this repo, update the `raw.githubusercontent.com/<owner>/<repo>/<branch>/...` paths in the Deploy buttons above, and **re-compile after any Bicep change**:
> `az bicep build --file deploy/1-golden-image/main.bicep --outfile deploy/1-golden-image/azuredeploy.json` (and likewise for `2-vmss`).

---

## Security notes

- **No secrets in this repo.** Step 1 takes them as `@secure()` inputs and writes them to a new Key Vault; `parameters.json` holds placeholders only.
- Managed identities are used for all secret access (AIB build VM and VMSS) — no credentials on disk.
- Secrets are written via ARM (management plane), so the deployer needs only Contributor/Owner — no data-plane role to seed them. The AIB identity gets *Key Vault Secrets User* to read them at build time.
- NSG is least-privilege; RDP is not opened unless you pass `rdpSourceIpRanges`.
- [`.gitignore`](.gitignore) excludes local Claude settings and `*.local.json` overrides.
