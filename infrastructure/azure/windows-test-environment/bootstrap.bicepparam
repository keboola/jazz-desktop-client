using './bootstrap.bicep'

param location = 'westeurope'
param keyVaultName = 'kvjazzwin96fd974a'
param operatorObjectId = 'b9977d7c-2374-4e13-a35f-c761d56abb76'
param keyVaultOperatorRoleDefinitionId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
param softDeleteRetentionDays = 90
param tags = {
  environment: 'development'
  issue: '34'
  project: 'jazz'
  purpose: 'windows-qualification'
  managedBy: 'bicep'
}
