# CrowdStrike Falcon on Azure VMSS — Golden Image (Windows & Linux)

Build a **golden image** with the CrowdStrike Falcon sensor pre-installed using **Azure Image Builder (AIB)** + **Azure Compute Gallery**, then deploy a **Flexible-orchestration Virtual Machine Scale Set (VMSS)** from it. Everything is **Bicep**, deployable from **Deploy to Azure** buttons with guided portal forms. **Windows and Linux** are both supported.

The image is built so it carries the **CID but no Host ID (AID)**. Each VM cloned from the image registers its **own unique AID on first boot** — no runtime scripting, clean scale-out.

| OS | How "no AID in the image" is achieved | Sensor service |
|---|---|---|
| **Windows** | Sensor installed with **`NO_START=1`** — never starts in the image, so no AID is ever generated | `CSFalconService` |
| **Linux** | Vendor script run with **`PREP_GOLDEN_IMAGE=true`** — installs, registers, then **strips the AID** (`falconctl -d -f --aid`) | `falcon-sensor` |

---

## How it works

Two steps, one **Deploy to Azure** button each.

**Step 1 — Golden image** &nbsp;·&nbsp; *Azure Image Builder → Compute Gallery*
1. Creates a Key Vault and stores the CrowdStrike secrets you provide.
2. Builds from a marketplace base image: OS updates → installs the Falcon sensor **last** → generalizes.
3. Publishes a versioned image to the Compute Gallery.

**Step 2 — VMSS** &nbsp;·&nbsp; *from the gallery image*
1. Creates VNet / subnet / NSG and a Standard load balancer.
2. Deploys a Flexible-orchestration VMSS from the image.
3. Each instance boots, the sensor auto-starts and registers its **own unique AID**.

**Design highlights**
- Secrets live only in the Key Vault that Step 1 creates — never in this repo, no manual pre-setup.
- The AIB build VM reads them via a **user-assigned managed identity** (*Key Vault Secrets User*); the CID is **baked at build time** from the Falcon API.
- VMSS uses **Trusted Launch** (secure boot + vTPM) to match the Gen2 image, with a **user-assigned identity**.

---

## Deploy to Azure

**Verify the [prerequisites](#prerequisites) first.** Then use the button for your OS and step — each opens a **guided, multi-step form** (the portal's `CustomDeploymentBlade` rendering a Form-view definition).

| | Step 1 — Build the golden image | Step 2 — Deploy the VMSS |
|---|---|---|
| **Windows** | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image-windows%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image-windows%2FuiFormDefinition.json) | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss-windows%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss-windows%2FuiFormDefinition.json) |
| **Linux** | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image-linux%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image-linux%2FuiFormDefinition.json) | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss-linux%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss-linux%2FuiFormDefinition.json) |

### Step 1 — Build the golden image

The form asks for your CrowdStrike **API Client ID / Secret** and the **source image**, then creates the Key Vault (seeded with your secrets), the Compute Gallery + image definition, and the Image Builder template.

- **Windows** — pick Publisher / Offer / SKU / Version (SKU is a live dropdown filtered to Gen2).
- **Linux** — Publisher → Offer → SKU → Version are **live cascading dropdowns** from the Azure API (defaults to Ubuntu Server 22.04 LTS Gen2).

Deploying only *creates* the Image Builder template — **you then start the build** (portal: **Start build** on the image template; or the CLI below). It takes ~20–40 min.

The image-definition name is generated automatically from the distro (e.g. `CrowdStrike-Ubuntu-2204`, `CrowdStrike-RHEL-9`), and the Image Builder template name is made unique per image. **Both are shown in Step 1's deployment outputs** (`imageDefinitionName`, `imageBuilderTemplateName`) — use those exact values below and in Step 2.

```bash
# use the imageBuilderTemplateName from Step 1's outputs (it carries a unique suffix)
az resource invoke-action -g <your-rg> \
  --resource-type Microsoft.VirtualMachineImages/imageTemplates \
  --name <imageBuilderTemplateName> --action Run

az resource show -g <your-rg> \
  --resource-type Microsoft.VirtualMachineImages/imageTemplates \
  --name <imageBuilderTemplateName> --query "properties.lastRunStatus" -o json   # watch until "Succeeded"
```

### Step 2 — Deploy the VMSS

Deploys networking + a Flexible VMSS from the Step 1 image. **Pick the golden image** from any Compute Gallery you can read (the form's image selector), choose a **version**, and set the local **admin username / password**, **VM size**, and **instance count**. No Key Vault or image names to type — the sensor's CID is already baked into the image.

> Linux instances use password auth by default (mirroring Windows). For production, switch `modules/vmssLinux.bicep` to SSH keys.
>
> **Forking?** Update the `raw.githubusercontent.com/<owner>/<repo>/<branch>/...` paths in the buttons above (both the `uri` template and the `uiFormDefinitionUri` form), and recompile after any Bicep change: `az bicep build --file deploy/<folder>/main.bicep --outfile deploy/<folder>/azuredeploy.json`.

---

## Prerequisites

1. **Azure permissions** to create resources **and role assignments** (Owner, or Contributor + User Access Administrator) in the target resource group — both steps assign roles to managed identities.
2. **Register resource providers** (once per subscription):
   ```bash
   for p in Microsoft.VirtualMachineImages Microsoft.Compute Microsoft.Storage Microsoft.KeyVault Microsoft.Network Microsoft.ContainerInstance; do
     az provider register -n $p
   done
   ```
3. **A CrowdStrike Falcon API client** with **Sensor Download (Read)** and **Sensor Update Policies (Read)** scopes. You supply its Client ID / Secret to Step 1 as secure parameters.

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
  --template-file deploy/1-golden-image-windows/main.bicep \
  --parameters falconClientId='<id>' falconClientSecret='<secret>' falconCloud='us-1'
  # optional: sensorUpdatePolicyName='<policy>' provToken='<token>' falconCid='<cid>'

# ...start the build (see Step 1) and wait for Succeeded, then:

# Step 2 — VMSS from the image (use imageDefinitionId from Step 1 outputs)
az deployment group create -g <your-rg> \
  --template-file deploy/2-vmss-windows/main.bicep \
  --parameters imageDefinitionId='<imageDefinitionId-from-step1>' \
               adminPassword='<secure-password>' imageVersion='latest'
```

> **Preview a form without deploying:** paste a `uiFormDefinition.json` into the [Form view sandbox](https://aka.ms/form/sandbox).

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
2. Re-run the Step 1 build — AIB starts from a clean base image, installs the current sensor last, and seals.
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
  1-golden-image-windows/   # Windows Step 1  ┐ each folder: main.bicep + azuredeploy.json
  2-vmss-windows/           # Windows Step 2  │   + uiFormDefinition.json  (button form)
  1-golden-image-linux/     # Linux   Step 1  │   + createUiDefinition.json (sandbox/managed-app)
  2-vmss-linux/             # Linux   Step 2  ┘
main.bicep                  # Advanced all-in-one orchestrator (bring-your-own KV; imageOnly|vmssOnly|complete)
parameters.json             # EXAMPLE parameters (placeholders only — no secrets)
scripts/                    # Reference PowerShell (install / update runbooks)
```

---

## Security notes

- **No secrets in this repo.** Step 1 takes them as `@secure()` inputs and writes them to a new Key Vault; `parameters.json` holds placeholders only.
- The **AIB build VM** reads the CrowdStrike secrets from Key Vault via a managed identity — no credentials on disk. The VMSS needs no secret access at runtime (the CID is baked into the image).
- Secrets are written via ARM (management plane), so the deployer needs only Contributor/Owner — no data-plane role to seed them. The AIB identity is granted *Key Vault Secrets User* to read them at build time.
- NSG is least-privilege; remote-access ports aren't opened unless you pass a source IP range.
- [`.gitignore`](.gitignore) excludes local Claude settings, `.remember/`, and `*.local.json` overrides.
