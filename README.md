# CrowdStrike Falcon on Azure VMSS — Golden Image

Build a **golden image** with the CrowdStrike Falcon sensor pre-installed (Azure Image Builder → Compute Gallery), then deploy a **VMSS** from it. Each instance registers its own unique Host ID (AID) on first boot. **Windows and Linux** supported, via **Deploy to Azure** buttons with guided forms.

## Prerequisites

1. **Azure rights** to create resources **and role assignments** (Owner, or Contributor + User Access Administrator) in the target resource group.
2. **A CrowdStrike Falcon API client** with **Sensor Download (Read)** + **Sensor Update Policies (Read)** scopes. You'll enter its Client ID / Secret in Step 1.

## Deploy

| | Step 1 — Build the image | Step 2 — Deploy the VMSS |
|---|---|---|
| **Windows** | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image-windows%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image-windows%2FuiFormDefinition.json) | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss-windows%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss-windows%2FuiFormDefinition.json) |
| **Linux** | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image-linux%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F1-golden-image-linux%2FuiFormDefinition.json) | [![Deploy](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#view/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss-linux%2Fazuredeploy.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fmikedzikowski%2Fazure-vmss-cs-golden-image%2Fmain%2Fdeploy%2F2-vmss-linux%2FuiFormDefinition.json) |

**Step 1 — Build the image.** Click the button, pick your OS image, and enter your Falcon API Client ID / Secret. Deploying creates the Image Builder template; then **start the build** — in the portal, open the image template resource and click **Start build**. Takes ~20–40 min. The image definition name is shown in the deployment **Outputs**.

> If the build fails at *"Unable to fetch installer details,"* your Sensor Update Policy points to a version no longer in the catalog. Set **Sensor Update Policy name** to a current policy (Windows defaults to `platform_default`; on Linux, leave blank for the latest).

**Step 2 — Deploy the VMSS.** Once the build succeeds, click the Step 2 button, **select the golden image** from the gallery, pick a **version**, and set the **admin username / password**, **VM size**, and **instance count**.

## Verify

Each instance should show the sensor service running (`CSFalconService` on Windows, `falcon-sensor` on Linux) and appear in the Falcon console with its own unique AID.
