# Set-PanExternalDynamicIpLists

### Login
```powershell
Connect-AzAccount -SubscriptionName "{{ SubscriptionName }}"

$AZURE_SUBSCRIPTION_ID =(Get-AzContext).Subscription.Id
$AZURE_CONTEXT_ACCOUNT_ID = (Get-AzContext).Account.Id
```

## Create Resource Group
```powershell
$AZURE_APPLICATION_NAME = 'paniplist'
cp "./templates/resourcegroup/azuredeploy.parameters.json" "./templates/resourcegroup/azuredeploy.$AZURE_APP_NAME.parameters.json"

# Edit "./templates/resourcegroup/azuredeploy.$AZURE_APP_NAME.parameters.json"
# Fill in correct parameter values

# Deploy a new resource group

$AZURE_DEPLOYMENT_LOCATION = 'eastus2'

$splat = @{}
$splat = @{
  Location = $AZURE_DEPLOYMENT_LOCATION `
  TemplateFile = "./templates/resourcegroup/azuredeploy.json"
  TemplateParameterFile =  "./templates/resourcegroup/azuredeploy.$AZURE_APP_NAME.parameters.json"
}
$AZURE_RG_DEPLOYMENT = New-AzDeployment @splat
```

## Create Azure Automation Account

```powershell
# Create a new Azure Automation Account
$automationAccount = New-AzAutomationAccount -Name 'panostg-automation' `
                                             -ResourceGroupName $AZURE_RESOURCE_GROUP `
                                             -Location $AZURE_DEPLOYMENT_LOCATION `
                                             -Plan basic

$AZURE_AUTOMATION_ACCOUNT_NAME = $automationAccount.AutomationAccountName
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
# Get AppId of the automation account.
$AZURE_AUTOMATION_ACCOUNT_SP = Get-AzADApplication -DisplayNameStartWith $('{0}_' -f $AZURE_AUTOMATION_ACCOUNT_NAME)

$AZURE_AUTOMATION_ACCOUNT_SP_APPID = $AZURE_AUTOMATION_ACCOUNT_SP.ApplicationId.Guid

# Get all subscriptions that you have access to
$AZURE_SUBSCRIPTION_IDS = Get-AzSubscription | % {$_.SubscriptionId}

$splat = @{}
$splat =  @{
  ApplicationId = $AZURE_AUTOMATION_ACCOUNT_SP_APPID
  RoleDefinitionName = 'Reader'
}

$AZURE_SUBSCRIPTION_IDS | % { New-AzRoleAssignment @splat -Scope $('/subscriptions/{0}' -f $_) }
}

$splat = @{}
$splat = @{
  ObjectId = $AZURE_AUTOMATION_ACCOUNT_SP.ObjectId
  RoleDefinitionName = 'Contributor'
  Scope = $('/subscriptions/{0}' -f $AZURE_SUBSCRIPTION_ID)
}

Remove-AzRoleAssignment @splat

```


## Create Storage Account

An Azure Storage Account will be created to contain Azure blob storage and Azure table storage for use by the runbook.

```powershell
# Create a storage account to park artifacts used by the Automation account
# Add deployment parameters to existing hashtable specific to Storage

$AZURE_DEPLOYMENT_PARAMETERS = @{
    ResourceLocation         = '{{ ResourceLocation }}'
    OwnerSignInName          = '{{ OwnerSignInName }}'
    ChargingAccount          = '{{ ChargingAccount }}'
    ApplicationName          = '{{ ApplicationName }}'
    ApplicationBusinessUnit  = '{{ ApplicationBusinessUnit }}'
    Environment              = '{{ Environment }}'
    DataSensitivity          = '{{ DataSensitivity }}'
}

$AZURE_STORAGE_ACCOUNT_DEPLOYMENT_PARAMETERS =  $AZURE_DEPLOYMENT_PARAMETERS + @{
    SkuName           = 'Standard_LRS'
    AccountKind       = 'StorageV2'
    AccessTierDefault = 'Hot'
    CustomDomain      = ''
}

$AZURE_DEPLOYMENT = "storageaccount-$(Get-Date -Format 'yyMMddHHmmm')-deployment"

$AZURE_DEPLOYMENT_STORAGE_ACCOUNT = New-AzResourceGroupDeployment -Name $AZURE_DEPLOYMENT `
                                                          -ResourceGroupName $AZURE_RESOURCE_GROUP `
                                                          -TemplateFile ./templates/storageaccount/azuredeploy.json `
                                                          -TemplateParameterFILE ./templates/storageaccount/azuredeploy.$AZURE_APPLICATION_NAME.parameters.json

$AZURE_STORAGE_ACCOUNT = $AZURE_DEPLOYMENT_STORAGE_ACCOUNT.Outputs.storageAccountName.Value
$AZURE_STORAGE_KEY = $(Get-AzStorageAccountKey -Name "$AZURE_STORAGE_ACCOUNT" -ResourceGroupName "$AZURE_RESOURCE_GROUP" | ? {$_.KeyName -eq 'key1'}).Value


$AZURE_STORAGE_CONTEXT = New-AzStorageContext -StorageAccountName "$AZURE_STORAGE_ACCOUNT" `
                        -StorageAccountKey "$AZURE_STORAGE_KEY"

# Create container to hold Azure blobs
New-AzStorageContainer -Context $AZURE_STORAGE_CONTEXT `
                       -Permission Off `
                       -Name 'itsft-pan'

$StartTime = Get-Date
$ExpiryTime = $StartTime.AddYears(1)

$AZURE_STORAGE_SAS_TOKEN = New-AzStorageContainerSASToken -Context $AZURE_STORAGE_CONTEXT `
                                                          -Name 'itsft-pan' `
                                                          -Permission rl `
                                                          -StartTime $StartTime `
                                                          -ExpiryTime $ExpiryTime

$AZURE_FTS_PAN_CONFIGS=$(Get-ChildItem -Recurse "$HOME/Downloads/itsft-pan/ZoneLists")

$AZURE_FTS_PAN_CONFIGS | % { Set-AzStorageBlobContent -File $_ `
                                                      -Context $AZURE_STORAGE_CONTEXT `
                                                      -Container 'itsft-pan' `
                                                      -Blob $($_.Directory.Name + '/' + $_.Name) `
                                                      -Properties @{"ContentType" = "text/plain;charset=ansi"}
                              }

```

```


$AZURE_AAD_STORAGE_CONTEXT = New-AzStorageContext -StorageAccountName "$AZURE_STORAGE_ACCOUNT" `
                                        -UseConnectedAccount

# Assign current logged in user the Storage Blob Data Owner role
New-AzRoleAssignment -SignInName  $AZURE_CONTEXT_ACCOUNT_ID `
    -RoleDefinitionName "Storage Blob Data Owner" `
    -Scope  (("/subscriptions/{0}" + `
             "/resourceGroups/{1}" + `
             "/providers/Microsoft.Storage/storageAccounts/{2}" + `
             "/blobServices/default/containers/{3}") `
             -f $AZURE_SUBSCRIPTION_ID, $AZURE_RESOURCE_GROUP, $AZURE_STORAGE_ACCOUNT, "itsft-pan")

# Create a new storage context using current logged in user
$AZURE_AAD_STORAGE_CONTEXT = New-AzStorageContext -StorageAccountName "$AZURE_STORAGE_ACCOUNT" `
                                        -UseConnectedAccount

# Test uploading data
Set-AzStorageBlobContent `
 -Context $AZURE_AAD_STORAGE_CONTEXT `
 -Container itsft-pan `
 -File /Users/vbalbarin/projects/git.yale.edu/veb3/Azure/Yale-Azure-Zonelists/HighSensitivityZone.txt `
 -Blob 'ZoneLists/HighSensitivityZone.txt' `
 -Properties @{"ContentType" = "text/plain;charset=ansi"}

# Assign the application id of automation account contributor role
New-AzRoleAssignment -ApplicationId  $AZURE_AUTOMATION_ACCOUNT_SP_APPID `
    -RoleDefinitionName "Storage Blob Data Contributor" `
    -Scope  (("/subscriptions/{0}" + `
             "/resourceGroups/{1}" + `
             "/providers/Microsoft.Storage/storageAccounts/{2}" + `
             "/blobServices/default/containers/{3}") `
             -f $AZURE_SUBSCRIPTION_ID, $AZURE_RESOURCE_GROUP, $AZURE_STORAGE_ACCOUNT, "itsft-pan")
```