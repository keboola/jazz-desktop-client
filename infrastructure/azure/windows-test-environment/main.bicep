targetScope = 'resourceGroup'

param location string
param tags object
param keyVaultName string
param developmentBreakGlassCredentialName string
param qualificationBreakGlassCredentialName string
param virtualNetworkName string
param virtualNetworkPrefix string
param bastionSubnetPrefix string
param developmentSubnetName string
param developmentSubnetPrefix string
param qualificationSubnetName string
param qualificationSubnetPrefix string
param developmentNetworkSecurityGroupName string
param qualificationNetworkSecurityGroupName string
param developmentNicName string
param qualificationNicName string
param bastionName string
param bastionPublicIpName string
param bastionSku string
param natGatewayName string
param natGatewayPublicIpName string
param natGatewayIdleTimeoutMinutes int
param rdpPort string
param allowBastionRdpPriority int
param denyLateralTrafficPriority int
param developmentVmName string
param developmentVmSize string
param qualificationVmName string
param qualificationVmSize string
param adminUsername string
param imagePublisher string
param imageOffer string
param imageSku string
param imageVersion string
param osDiskSizeGiB int
param osDiskStorageAccountType string
param windowsTimeZone string
param operatorObjectId string
param vmAdministratorLoginRoleDefinitionId string
param readerRoleDefinitionId string

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' existing = {
  name: keyVaultName
}

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2025-07-01' = {
  name: bastionPublicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2025-07-01' = {
  name: natGatewayPublicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2025-07-01' = {
  name: natGatewayName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: natGatewayIdleTimeoutMinutes
    publicIpAddresses: [
      {
        id: natGatewayPublicIp.id
      }
    ]
  }
}

resource developmentNsg 'Microsoft.Network/networkSecurityGroups@2025-07-01' = {
  name: developmentNetworkSecurityGroupName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-rdp-from-bastion'
        properties: {
          priority: allowBastionRdpPriority
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: developmentSubnetPrefix
          destinationPortRange: rdpPort
        }
      }
      {
        name: 'deny-lateral-vnet-ingress'
        properties: {
          priority: denyLateralTrafficPriority
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: developmentSubnetPrefix
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource qualificationNsg 'Microsoft.Network/networkSecurityGroups@2025-07-01' = {
  name: qualificationNetworkSecurityGroupName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-rdp-from-bastion'
        properties: {
          priority: allowBastionRdpPriority
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: qualificationSubnetPrefix
          destinationPortRange: rdpPort
        }
      }
      {
        name: 'deny-lateral-vnet-ingress'
        properties: {
          priority: denyLateralTrafficPriority
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: qualificationSubnetPrefix
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2025-07-01' = {
  name: virtualNetworkName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        virtualNetworkPrefix
      ]
    }
  }
}

resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-07-01' = {
  parent: virtualNetwork
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefix: bastionSubnetPrefix
    defaultOutboundAccess: false
  }
}

resource developmentSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-07-01' = {
  parent: virtualNetwork
  name: developmentSubnetName
  properties: {
    addressPrefix: developmentSubnetPrefix
    defaultOutboundAccess: false
    natGateway: {
      id: natGateway.id
    }
    networkSecurityGroup: {
      id: developmentNsg.id
    }
  }
}

resource qualificationSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-07-01' = {
  parent: virtualNetwork
  name: qualificationSubnetName
  properties: {
    addressPrefix: qualificationSubnetPrefix
    defaultOutboundAccess: false
    natGateway: {
      id: natGateway.id
    }
    networkSecurityGroup: {
      id: qualificationNsg.id
    }
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2025-07-01' = {
  name: bastionName
  location: location
  tags: tags
  sku: {
    name: bastionSku
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ip-configuration'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: bastionSubnet.id
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
}

resource developmentNic 'Microsoft.Network/networkInterfaces@2025-07-01' = {
  name: developmentNicName
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: developmentSubnet.id
          }
        }
      }
    ]
  }
}

resource qualificationNic 'Microsoft.Network/networkInterfaces@2025-07-01' = {
  name: qualificationNicName
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: qualificationSubnet.id
          }
        }
      }
    ]
  }
}

module developmentVm './vm.bicep' = {
  name: 'deploy-${developmentVmName}'
  params: {
    location: location
    tags: union(tags, { workload: 'development' })
    vmName: developmentVmName
    vmSize: developmentVmSize
    nicId: developmentNic.id
    adminUsername: adminUsername
    breakGlassAdminPassword: keyVault.getSecret(developmentBreakGlassCredentialName)
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    imageVersion: imageVersion
    osDiskSizeGiB: osDiskSizeGiB
    osDiskStorageAccountType: osDiskStorageAccountType
    windowsTimeZone: windowsTimeZone
    operatorObjectId: operatorObjectId
    vmAdministratorLoginRoleDefinitionId: vmAdministratorLoginRoleDefinitionId
  }
}

module qualificationVm './vm.bicep' = {
  name: 'deploy-${qualificationVmName}'
  params: {
    location: location
    tags: union(tags, { workload: 'qualification' })
    vmName: qualificationVmName
    vmSize: qualificationVmSize
    nicId: qualificationNic.id
    adminUsername: adminUsername
    breakGlassAdminPassword: keyVault.getSecret(qualificationBreakGlassCredentialName)
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    imageVersion: imageVersion
    osDiskSizeGiB: osDiskSizeGiB
    osDiskStorageAccountType: osDiskStorageAccountType
    windowsTimeZone: windowsTimeZone
    operatorObjectId: operatorObjectId
    vmAdministratorLoginRoleDefinitionId: vmAdministratorLoginRoleDefinitionId
  }
}

resource operatorBastionReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(bastion.id, operatorObjectId, readerRoleDefinitionId)
  scope: bastion
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleDefinitionId)
  }
}

resource operatorDevelopmentNicReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(developmentNic.id, operatorObjectId, readerRoleDefinitionId)
  scope: developmentNic
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleDefinitionId)
  }
}

resource operatorQualificationNicReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(qualificationNic.id, operatorObjectId, readerRoleDefinitionId)
  scope: qualificationNic
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleDefinitionId)
  }
}

output bastionId string = bastion.id
output developmentVmId string = developmentVm.outputs.id
output qualificationVmId string = qualificationVm.outputs.id
