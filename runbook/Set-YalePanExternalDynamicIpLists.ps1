<#
.SYNOPSIS
    This commandlet will retrieve the private IP addresses within the specified Azure subscription.
    It will read the `DataSensitivity` tag of the VM machine using the private IP address and place
    the private IP address into an external dynamic list to be consumed by a properly configured
    Palo Alto Networks firewall appliance or a Palo Alto Networks Panorama management node.


.DESCRIPTION
    The commandlet reads the `DataSensitivity` resource tag on an Azure VM. This tag can comprise the values
    ['High', 'Medium', 'Low', 'None']. The runbook retrieves the Azure private IP addresses associated
    with any attached network interfaces. It then places the IP address into one of 4 blob storage endpoints
    corresponding to the value of the `DataSensitivity` tag. If the tag is nonexistent, the IP address
    is written to the storage blob endpoint corresponding to 'None'.

    It is possible that a VM may contain multiple network interfaces with separate private ip addresses.
    These network interfaces may possess DataSensitivity tags different from the vm.
    The code enforces the policy that all ip addresses associated with a VM be categorized with the value
    of the VM.

    The Palo Alto network virtual appliance must be configured to retrieve the address groups from the storage
    blob endpoints.


.PARAMETER SubscriptionId
    A list of Azure subscription ids from which to create private IP addresses and and assign the DataSensitity
    classification of the VM.

    Specifying 'all' will retrieve all the subscriptions.

    Specifying nothing will use the subscription in the current Azure login context.


.NOTES
    AUTHOR: Vincent Balbarin
    COPYRIGHT: Yale University 2019
    LASTEDIT: 2019-10-29
#>
using namespace System.Collections.Generic

[CmdletBinding()]

param
(
    # If not specified, the subscription of the current Azure context.
    [Parameter(Mandatory=$false)] [String[]] $SubscriptionID   # Subscription ID to look at
)


#region : PSAzureProfile
# Connect to Azure AD and obtain an authorized context to access directory information regarding owner
# and (in the future) access a blob storage container without a SAS token or storage account key
try {
  $connectionName = "AzureRunAsConnection"
  $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName

  Add-AzAccount -ServicePrincipal `
                -TenantId $servicePrincipalConnection.TenantId `
                -ApplicationId $servicePrincipalConnection.ApplicationId `
                -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 3>&1 2>&1 > $null
} catch {
  if (!$servicePrincipalConnection) {
      $errorMessage = "Connection $connectionName not found."
      throw $ErrorMessage
  } else {
      Write-Error -Message $_.Exception
      throw $_.Exception
  }
}
#endregion : PSAzureProfile

If (!$SubscriptionID) {
  $Subscriptions = @((Get-AzContext).Subscription)
} elseif ($SubscriptionID -ieq 'all') {
  $Subscriptions = Get-AzSubscription
} else {
  $Subscriptions = $SubscriptionID | ForEach-Object {$id = $_; Get-AzSubscription | Where-Object {$_.SubscriptionId -ieq $id}}
}

function Invoke-Main {

  $results = New-Object List[System.Object]
  $ipObjects = @{}
  $Subscriptions | ForEach-Object { Write-Verbose -Message $("$($_.Name) ($($_.Id)) will be scanned.")}
  $Subscriptions | ForEach-Object {
    $results = $results + $(Get-AzPrivateIps -SubscriptionId $_.Id).Value
  }
  $results = $results | Sort-Object -Property Address

  #TODO: Create commandlet to check membership of IP value for CIDR block
  # eg, Where-IPv4 -Address 10.6.3.4 in -Cidr 10.6.0.0/
  $cidr_filter = '10\.6\.[0-9]+\.[0-9]'
  $results | Where-Object {$_.Address -match $cidr_filter} | ForEach-Object {
    $comment = '#{0}|{1}|{2}' -f $_.Properties.AttachedVmName, $_.Properties.DataSensitivity, $_.Properties.AttachedToVnet
    $key = $_.Address
    if ($ipObjects.ContainsKey($key)) {
      Write-Warning -Message $('Duplicate: {0} {1}' -f $key, $comment)
      # Adding `#` prefix to IP address; if it is written to file, it will be
      # interpreted as comment.
      # Create new entry from first instance found. Append NOTE to comment
      $ipObjects.Add("#${key}", $ipObjects[$key] + "|DUPLICATE")
      # Remove entry of frist instance
      $ipObjects.Remove($key)
      #Create new entry using `##` to allow uniqueness.
      $ipObjects.Add("##${key}", "${comment}|DUPLICATE")
    } else {
      $ipObjects.Add($key, $comment)
    }
  }

  $dupes = ($ipObjects.Keys | Where-Object {$_ -match '#'})
  if ($dupes.Count -eq 0) {
    Write-Verbose -Message 'Creating external dynamic lists'
    $zoneFiles = @(
      './ZoneLists/HighSensitivityZone.txt'
      './ZoneLists/ModerateSensitivityZone.txt'
      './ZoneLists/LowSensitivityZone.txt'
      './ZoneLists/NoneSensitivityZone.txt'
    )
    $zoneFiles | ForEach-Object {
      $parms = @{
        InputObject = $("# Generated $(Get-Date), $((Get-AzContext).Account.Id)")
        FilePath = $_
        Encoding = 'ascii'
      }
      Out-File @parms
    }
    $ipObjects.GetEnumerator() | ForEach-Object {
      $ds = ($_.Value.Split('|')[1])
      $fn = "./ZoneLists/${ds}SensitivityZone.txt"
      $parms = @{
        InputObject = $("{0}/32 {1}" -f $_.Key, $_.Value)
        FilePath = $fn
        Encoding = 'ascii'
        Append = $true
      }
      Write-Verbose -Message $("Writing entry {0}/32 to {1}" -f $_.Key, $fn)
      Out-File @parms
    }
  } else {
    Write-Warning -Message 'No external dynamic IP lists generated. Duplicates found'
    Write-Warning -Message 'Remove duplicate IP addresses in Azure Portal and run scripts again'
    $dupes | ForEach-Object {Write-Warning -Message $($_ + ' ' + $ipObjects[$_])}
  }

}

#region : functions
function AzDataSensitivity {
  param(
      [Parameter(Mandatory=$True)]
      [AllowNull()]
      [HashTable] $Tags
  )

  if ($Tags.ContainsKey('DataSensitivity')) {
      $Tags.DataSensitivity
  } else {
      [String] 'None'
  }
}

function AzVmName {
  param(
      [Parameter(Mandatory=$True)]
      [AllowNull()]
      [Object] $Vm
  )

  if ($Vm) {
      # TODO: Perhaps throw exception if `$<Parameter>` does not have `<member>`.
      $vmId = $Vm.Id
      if (($vmId) -and !($vmId -eq [String]::Empty)) {
          [String] $($vmId.Split('/')[-1]) | ForEach-Object { if ($_ -ieq 'null') {[String] 'None'} else {$_} }
      } else {
          [String] 'None'
      }
  } else {
      [String] 'None'
  }
}

function AttachedVMTags {
  param(
    [Parameter(Mandatory=$True)]
    [AllowNull()]
    [Object] $Vm
  )

  $vmName = AzVmName -Vm $Vm
    if ($vmName -eq 'None') {
      @{}
    } else {
      (Get-AzVm -Name $vmName).Tags
    }

}

function AzVnetName {
  param(
      [Parameter(Mandatory=$True)]
      [AllowNull()]
      [Object] $Subnet
  )

  if ($Subnet) {
      # TODO: Perhaps throw execption if `$<Parameter>` does not have `<member>`.
      $subnetId = $Subnet.Id
      if (($subnetId) -and !($subnetId -eq [String]::Empty)) {
          [String] $($SubnetId.Split('/')[8])
      } else {
          [String] 'None'
      }
  } else {
      [String] 'None'
  }
}

function AzPips {
  # Function that returns Azure private IP addreses attached to an Azure network interface.
  param(
      [Parameter(Mandatory=$true)]
      $AzNetworkInterface
  )
  $azNic = $AzNetworkInterface
  $azPrivateIps = New-Object List[System.Object]

  $attachedVm = $azNic.VirtualMachine
  $vmTags = AttachedVMTags -Vm $attachedVm

  $azNic.IpConfigurations | ForEach-Object {
      $attachedSubnet = $_.Subnet
      $azPrivateIps.Add(
          [PSCustomObject] @{
              Address = $_.PrivateIpAddress
              Properties = [PSCustomObject] @{
                  DataSensitivity = AzDataSensitivity -Tags $vmTags
                  AttachedVmName = AzVmName -Vm $attachedVm
                  AttachedToVnet = AzVnetName -Subnet $attachedSubnet
              }
          }
      )
  }
  $azPrivateIps.ToArray()
}

function Get-AzPrivateIps {
  # Commandlet that returns private ips at three different scopes: Subscription, Resource Group, or VM
  [CmdletBinding()]

  param(
      [Parameter(ParameterSetName='SubscriptionId', Mandatory=$False)]
      [String] $SubscriptionId,

      [Parameter(ParameterSetName='ResourceGroup', Mandatory=$True)]
      [Parameter(ParameterSetName='VirtualMachine')]
      [String] $ResourceGroupName,

      [Parameter(ParameterSetName='VirtualMachine', Mandatory=$True)]
      [Alias('Name')]
      [String] $VirtualMachineName
  )

  $output = @{
      Result = 'NotExecuted'
      Value = 'None'
  }


  switch($PSCmdlet.ParameterSetName) {
      'SubscriptionId' {
          Write-Verbose -Message ("Retrieving IP addresses in subscription {0}." -f $SubscriptionId)
          Set-AzContext -SubscriptionId $SubscriptionId
          $nics = Get-AzNetworkInterface
      }
      'ResourceGroup' {
          Write-Verbose -Message ("Retrieving IP addresses in resource group {0} in subscription {1}." -f $ResourceGroupName, $SubscriptionId)
          $nics = (Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName)
      }
      'VirtualMachine' {
          Write-Verbose -Message ("Retrieving IP addresses for virtual machine {0} in resource group {1} in subscription {2}." -f $VirtualMachineName, $ResourceGroupName, $SubscriptionId)
          $nics = (Get-AzNetworkInterface -ResourceGroupName $ResourceGroupName |
                  Where-Object {$_.VirtualMachine.Id.Split('/')[-1] -ieq $VirtualMachineName})
      }
  }

  $ips = New-Object List[System.Object]
  $nics | ForEach-Object {
    AzPips -AzNetworkInterface $_ | ForEach-Object {
      $ips.Add($_)
      $comment = '#{0}|{1}|{2}' -f $_.Properties.AttachedVmName, $_.Properties.DataSensitivity, $_.Properties.AttachedToVnet
      Write-Verbose -Message  $("Found $($_.Address) ${comment}")
    }
  }

  $output = @{
      Result = 'Success'
      Value = $ips.ToArray()
  }

  Write-Output [PScustomObject] $output
}

function Get-AzResourceFromURI {
  [CmdletBinding()]

  param(
      [parameter(Mandatory=$True)]
      [String] $ResourceURI
  )

  # TODO: Validation?
  $azResource = @{}
  $elements = $ResourceURI.Split('/')

  $azResource = @{
      SubscriptionId = $elements[2]
      ResourceGroupName = $elements[4]
      Providers = $elements[6]
      Type = $elements[7]
      Name = $elements[8]
  }

  [PSCustomObject] $azResource
}
#endregion : functions

Invoke-Main