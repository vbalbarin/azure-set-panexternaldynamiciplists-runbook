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
$AZURE_SUBSCRIPTION_IDS = <list of subscription ids>|empty list|keyword 'all'
$AZURE_STORAGE_ACCOUNT_NAME
AZURE_STORAGE_CONTAINER_NAME
```
#>
Remove-Variable -Name testWebhook -Force -ErrorAction Ignore

$testWebhookData = [PsCustomObject] @{
  WebhookName =  'TestWebhook'
  RequestHeader = 'Content-Type: application/json'
  RequestBody = "`{`"SubscriptionIds`":[$($($AZURE_SUBSCRIPTION_IDS | % { '`"' + $_ + '`"' }) -join ',')],`"StorageAccount`":`"${AZURE_STORAGE_ACCOUNT_NAME}`",`"StorageContainer`":`"${AZURE_STORAGE_CONTAINER_NAME}`"`}"
}

$testWebhookData