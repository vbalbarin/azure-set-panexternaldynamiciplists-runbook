<#
Sample Test Webhook
This creates a Webhook object that allows you tO execute the runbook interactively

Dot source this file from prompt:

```
. ./runbook/webhook-version/Set-TestWebhokVariable
```
in order to have $testWebhookData available to script environment

The following variables should be set prior to running:

```
$AZ_SUBSCRIPTION_IDS = <list of subscription ids>|empty list|keyword 'all'
$AZ_STORAGE_ACCOUNT_NAME = <storage account name>
$AZURE_STORAGE_CONTAINER_NAME = <storage container name>
```
#>
Remove-Variable -Name testWebhook -Force -ErrorAction Ignore

$testWebhookData = [PsCustomObject] @{
  WebhookName =  'TestWebhook'
  RequestHeader = 'Content-Type: application/json'
  RequestBody = "`{`"SubscriptionIds`":[$($($AZ_SUBSCRIPTION_IDS | % { '`"' + $_ + '`"' }) -join ',')],`"StorageAccount`":`"${AZ_STORAGE_ACCOUNT_NAME}`",`"StorageContainer`":`"${AZ_STORAGE_CONTAINER_NAME}`"`}"
}

$testWebhookData