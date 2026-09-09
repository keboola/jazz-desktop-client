targetScope = 'resourceGroup'

param location string
param keyVaultName string
param operatorObjectId string
param keyVaultOperatorRoleDefinitionId string
param softDeleteRetentionDays int
param tags object

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: []
    enablePurgeProtection: true
    enableRbacAuthorization: true
    enabledForTemplateDeployment: true
    publicNetworkAccess: 'Enabled'
    softDeleteRetentionInDays: softDeleteRetentionDays
  }
}

resource operatorSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, operatorObjectId, keyVaultOperatorRoleDefinitionId)
  scope: keyVault
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      keyVaultOperatorRoleDefinitionId
    )
  }
}

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
