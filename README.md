# Set-PanExternalDynamicIpLists

### Login
```powershell
Connect-AzAccount -SubscriptionName "{{ SubscriptionName }}"

$AZURE_SUBSCRIPTION_ID =(Get-AzContext).Subscription.Id
$AZURE_CONTEXT_ACCOUNT_ID = (Get-AzContext).Account.Id
```

## Create Resource Group
```powershell
mkdir ./scratch
$AZURE_APPLICATION_NAME = 'paniplist'

$splat = {}
$splat = @{
  Path = "./templates/resourcegroup/azuredeploy.parameters.json"
  Destination = "./scratch/azuredeploy.${AZURE_APPLICATION_NAME}.resourcegroup.parameters.json"
}
Copy-Item @splat

# Edit "./templates/resourcegroup/azuredeploy.$AZURE_APP_NAME.resourcegroup.parameters.json"
# Fill in correct parameter values

# Deploy a new resource group

$AZURE_DEPLOYMENT_LOCATION = 'eastus2'

$splat = @{}
$splat = @{
  Location = $AZURE_DEPLOYMENT_LOCATION
  TemplateFile = "./templates/resourcegroup/azuredeploy.json"
  TemplateParameterFile =  "./scratch/azuredeploy.${AZURE_APPLICATION_NAME}.resourcegroup.parameters.json"
}
$AZURE_RG_DEPLOYMENT = New-AzDeployment @splat
$AZURE_RESOURCE_GROUP = $AZURE_RG_DEPLOYMENT.Outputs.resourceGroupName.Value
```

## Create Azure Automation Account

```powershell
# Create a new Azure Automation Account
$splat = @{}
$splat = @{
  Name = "$AZURE_APPLICATION_NAME-automation"
  ResourceGroupName = "$AZURE_RESOURCE_GROUP"
  Location = "$AZURE_DEPLOYMENT_LOCATION"
  Plan = "basic"
}
$AZURE_AUTOMATION_ACCOUNT = New-AzAutomationAccount @splat

$AZURE_AUTOMATION_ACCOUNT_NAME = $AZURE_AUTOMATION_ACCOUNT.AutomationAccountName
```
Next, a new **Run as Account** will need to be created.

To continue, navigate to the Azure Portal page for the automation account **panostg-automation** and select **Run as accounts** under **Account Settings**. Click on **Azure Run as Account**.

![CreateAzureAutomationRunasAccountBladeAzurePortal](assets/CreateAzureAutomationRunasAccountBladeAzurePortal.png)

Click **Create** on the following blade:

![CreateAzureAutomationRunasRMAzurePortal](assets/CreateAzureAutomationRunasRMAzurePortal.png)

This will result in a new **Azure Automation Run As Account**:

![AzureAutomationRunasAccountBladeAzurePortal](assets/AzureAutomationRunasAccountBladeAzurePortal.png)

A corresponding **AzureRunAsConnection** will be created also and can be viewed under the **Shared Resources** of the ***resourcegroups-automation** Azure Automation Account:

![SharedResourcesAzureAutomationBladeAzurePortal](assets/SharedResourcesAzureAutomationBladeAzurePortal.png)

Once the account has been created, it must be assigned the proper role over the subscription. A Runas Automation account typically posseses `Contributor` over the scope of the subscription. Since this runbook will read information regarding the ip addresses, it will be given `Reader`, instead over a list of managed subscriptions.

```powershell
# Get ObjectId of the service principal associated with
# the Azure Automation RunAs account.
# When a RunAs account is created, it is registered as an Azure Ad application.
# An Azure Ad application has an associated Service Principal.
# The ObjectId of the associated Service Principal is required to assign an Azure AD role.

$AZURE_AUTOMATION_RUNASACCOUNT_SP = Get-AzADServicePrincipal -DisplayNameBeginsWith $('{0}_' -f $AZURE_AUTOMATION_ACCOUNT_NAME)

$AZURE_AUTOMATION_RUNASACCOUNT_SP_OBJID = $AZURE_AUTOMATION_RUNASACCOUNT_SP.Id

# Get all subscriptions that you have access to
$AZURE_SUBSCRIPTION_IDS = Get-AzSubscription | % {$_.SubscriptionId}

$splat = @{}
$splat =  @{
  ObjectId = "$AZURE_AUTOMATION_RUNASACCOUNT_SP_OBJID"
  RoleDefinitionName = 'Reader'
}

$AZURE_SUBSCRIPTION_IDS | % {
  New-AzRoleAssignment @splat -Scope $('/subscriptions/{0}' -f $_)
}

$splat = @{}
$splat = @{
  ObjectId = "$AZURE_AUTOMATION_RUNASACCOUNT_SP_OBJID"
  RoleDefinitionName = 'Contributor'
  Scope = $('/subscriptions/{0}' -f $AZURE_SUBSCRIPTION_ID)
}

Remove-AzRoleAssignment @splat

```

After the automation account has been created, the required `Az` Powershell modules must be added to the automation account.

```powershell
# Add Necessary Az modules
# The `Az.Accounts` module must the first module imported into the automation account

Find-Module -Name 'Az.Accounts' | ForEach {
    New-AzAutomationModule -AutomationAccountName $AZURE_AUTOMATION_ACCOUNT_NAME `
                           -ResourceGroupName $AZURE_RESOURCE_GROUP `
                           -ContentLink $('{0}/package/{1}/{2}' -f $_.RepositorySourceLocation, $_.Name, $_.Version) `
                           -Name $_.Name
}

# Once this module has been imported, the other required modules are imported
$AZURE_AUTOMATION_MODULES = @(
    'Az.Compute',
    'Az.Network',
    'Az.Resources',
    'Az.Storage'
) | ForEach {Find-Module -Name $_ -Repository PSGallery}

$splat = @{}
$splat @{
  AutomationAccountName = "$AZURE_AUTOMATION_ACCOUNT_NAME"
  ResourceGroupName = "$AZURE_RESOURCE_GROUP"
  ContentLink = $('{0}/package/{1}/{2}' -f $_.RepositorySourceLocation, $_.Name, $_.Version)
  Name = $_.Name
}
$AZURE_AUTOMATION_MODULES | ForEach {
    New-AzAutomationModule @splat
}

# Import runbook:
$splat = @{}
$splat = @{
  Path = ".\runbook\Set-YalePanExternalDynamicIpLists.ps1"
  ResourceGroupName = "$AZURE_RESOURCE_GROUP"
  AutomationAccountName = "$AZURE_AUTOMATION_ACCOUNT_NAME"
  Type = "PowerShell"
}
Import-AzAutomationRunbook @splat

# Publish runbook
Publish-AzAutomationRunbook -Name 'Get-AzDataSensitivityLevel' `
                            -ResourceGroupName $AZURE_RESOURCE_GROUP `
                            -AutomationAccountName $AZURE_AUTOMATION_ACCOUNT_NAME

```

## Create Storage Account

An Azure Storage Account will be created to contain Azure blob storage for the external dynamic IP lists.

```powershell
# Create a storage account to park artifacts used by the Automation account
# Add deployment parameters to existing hashtable specific to Storage

$splat = {}
$splat = @{
  Path = "./templates/storageaccount/azuredeploy.parameters.json"
  Destination = "./scratch/azuredeploy.${AZURE_APPLICATION_NAME}.storageaccount.parameters.json"
}
Copy-Item @splat

# Edit "./templates/resourcegroup/azuredeploy.$AZURE_APP_NAME.storageaccount.parameters.json"
# Fill in correct parameter values


$splat = @{}
$splat = @{
  Name = "storageaccount-$(Get-Date -Format 'yyMMddHHmmm')-deployment"
  ResourceGroupName = "$AZURE_RESOURCE_GROUP"
  TemplateFile = "./templates/storageaccount/azuredeploy.json"
  TemplateParameterFILE = "./scratch/azuredeploy.${AZURE_APPLICATION_NAME}.storageaccount.parameters.json"
}
$AZURE_DEPLOYMENT_STORAGE_ACCOUNT = New-AzResourceGroupDeployment @splat

$AZURE_STORAGE_ACCOUNT = $AZURE_DEPLOYMENT_STORAGE_ACCOUNT.Outputs.storageAccountName.Value

# Azure AD credentials can be used to establish a storage context
$AZURE_STORAGE_CONTEXT = New-AzStorageContext -StorageAccountName "$AZURE_STORAGE_ACCOUNT" `
                        -UseConnectedAccount

$AZURE_STORAGE_CONTAINER = New-AzStorageContainer -Context $AZURE_STORAGE_CONTEXT `
                                                  -Permission Off `
                                                  -Name 'pan-itsfts'

# Set Storage Blob Data Owner role for current user over the newly created container
$splat=@{}
$splat = @{
  SignInName = $AZURE_CONTEXT_ACCOUNT_ID
  RoleDefinitionName = "Storage Blob Data Owner"
  Scope = (("/subscriptions/{0}" + `
             "/resourceGroups/{1}" + `
             "/providers/Microsoft.Storage/storageAccounts/{2}" + `
             "/blobServices/default/containers/{3}") `
             -f $AZURE_SUBSCRIPTION_ID, $AZURE_RESOURCE_GROUP, $AZURE_STORAGE_ACCOUNT, "pan-itsfts")
}

New-AzRoleAssignment @splat
# NB, This will take a few minutes to propogate

# Test by repeating the followinng until success

Set-AzStorageBlobContent `
  -Context $AZURE_STORAGE_CONTEXT `
  -Container 'pan-itsfts' `
  -File "./templates/resourcegroup/azuredeploy.json" `
  -Blob 'templates/resourcegroup/azuredeploy.json' `
  -Properties @{"ContentType" = "text/plain;charset=ansi"}

# You can run the runbook here to populate the blobs and test locally

./runbook/Set-YalePanExternalDynamicIpLists.ps1 -SubscriptionIds @('all') -StorageAccount "$AZURE_STORAGE_ACCOUNT" -StorageContainer 'pan-itsfts' -Verbose

# Set Storage Blob Contributor role for RunAs account to allow the runbook to update blobs
$splat=@{}
$splat = @{
  ObjectId = "$AZURE_AUTOMATION_RUNASACCOUNT_SP_OBJID"
  RoleDefinitionName = "Storage Blob Data Contributor"
  Scope = (("/subscriptions/{0}" + `
             "/resourceGroups/{1}" + `
             "/providers/Microsoft.Storage/storageAccounts/{2}" + `
             "/blobServices/default/containers/{3}") `
             -f $AZURE_SUBSCRIPTION_ID, $AZURE_RESOURCE_GROUP, $AZURE_STORAGE_ACCOUNT, "pan-itsfts")
}

New-AzRoleAssignment @splat

# Generating tokens for acces
$StartTime = Get-Date
$ExpiryTime = $StartTime.AddYears(1)

$AZURE_STORAGE_SAS_TOKEN = New-AzStorageContainerSASToken -Context $AZURE_STORAGE_CONTEXT `
                                                          -Name 'pan-itsts' `
                                                          -Permission rl `
                                                          -StartTime $StartTime `
                                                          -ExpiryTime $ExpiryTime

```

```

# Assign the application id of automation account contributor role
New-AzRoleAssignment -ApplicationId  $AZURE_AUTOMATION_RUNASACCOUNT_SP_APPID `
    -RoleDefinitionName "Storage Blob Data Contributor" `
    -Scope  (("/subscriptions/{0}" + `
             "/resourceGroups/{1}" + `
             "/providers/Microsoft.Storage/storageAccounts/{2}" + `
             "/blobServices/default/containers/{3}") `
             -f $AZURE_SUBSCRIPTION_ID, $AZURE_RESOURCE_GROUP, $AZURE_STORAGE_ACCOUNT, "itsft-pan")
```