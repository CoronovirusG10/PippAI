targetScope = 'resourceGroup'

// infra/main.bicep
@description('Subscription and location')
param location string = 'swedencentral'
@allowed([
  'B3'
  'P1v3'
  'P2v3'
])
param appServiceSku string = 'P2v3'

@description('Global names – do not change after first deploy')
var appServicePlanName       = 'pippaoflondon-plan'
var webAppName               = 'pippaoflondonai'
var storageAccountName       = 'pippaoflondonstore'
var cosmosAccountName        = 'pippaoflondon-cosmos'
var searchServiceName        = 'pippaoflondon-search'
var speechName               = 'pippaoflondonspeech001'
var openAIName               = 'pippaai-sc'
var keyVaultName             = 'pippaoflondon-kv2'
var botName                  = 'pippaoflondon-bot'

// --------------------------------------------------
//  Key Vault for runtime secrets
// --------------------------------------------------
resource kv 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: keyVaultName
  location: location
  properties: {
    enableSoftDelete: true
    enablePurgeProtection: true
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: [] // we’ll add the managed identity after creation
  }
}

// --------------------------------------------------
//  Storage account (blob + static web)
// --------------------------------------------------
resource sa 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_RAGRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    accessTier: 'Hot'
  }
}

// --------------------------------------------------
//  Cosmos DB (NoSQL API, autoscale 4 k → 40 k RU/s)
// --------------------------------------------------
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2023-04-15' = {
  name: cosmosAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    databaseAccountOfferType: 'Standard'
    enableFreeTier: false
    capabilities: [
      {name: 'EnableServerless'}
    ]
  }
}

// --------------------------------------------------
//  Azure AI Search (Standard)
// --------------------------------------------------
resource search 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchServiceName
  location: location
  sku: { name: 'standard' }
  properties: {}
}

// --------------------------------------------------
//  Speech service
// --------------------------------------------------
resource speech 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: speechName
  location: location
  sku: { name: 'S0' }
  kind: 'SpeechServices'
  properties: {}
}

// --------------------------------------------------
//  Azure OpenAI with five deployments
// --------------------------------------------------
resource aoai 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: openAIName
  location: location
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: openAIName
  }
}

// Removed GPT-4.1 from models array
var models = [
  { name: 'gpt4o',  sku: 'gpt-4o',   version: '2024-11-20' }
]

resource deployments 'Microsoft.CognitiveServices/accounts/deployments@2023-10-01-preview' = [for m in models: {
  parent: aoai
  name: m.name
  sku: {
    name: 'Standard'
    capacity: 1
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: m.sku
      version: m.version ?? 'latest' // Default to 'latest' if version is not specified
    }
  }
}]


// --------------------------------------------------
//  App Service Plan (B3 or P1v3)
// --------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: appServiceSku
    tier: appServiceSku == 'B3' ? 'Basic' : 'PremiumV3'
    size: appServiceSku
    capacity: 1
  }
  properties: {
    reserved: true   // Linux
  }
}

// --------------------------------------------------
//  Web App + staging slot
// --------------------------------------------------
resource web 'Microsoft.Web/sites@2023-01-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      appSettings: [
        { name: 'AZURE_OPENAI_ENDPOINT',         value: aoai.properties.endpoint }
        { name: 'AOAI_MODEL_GPT4O_DEPLOYMENT',   value: 'gpt4o' }
        { name: 'AZUREAI_SEARCH_ENDPOINT',       value: 'https://${search.name}.search.windows.net' }
        { name: 'AZUREAI_SEARCH_KEY',            value: search.listAdminKeys().primaryKey }
        { name: 'COSMOS_CONNECTION_STRING',      value: cosmos.listKeys().primaryMasterKey }
        { name: 'STORAGE_CONNECTION_STRING',     value: sa.listKeys().keys[0].value }
      ]
    }
  }
}

// staging slot
resource slot 'Microsoft.Web/sites/slots@2023-01-01' = {
  parent: web
  name: 'staging'
  location: location
  properties: {
    serverFarmId: plan.id
  }
}

// --------------------------------------------------
//  Bot Channels Registration (for Teams)
// --------------------------------------------------
resource bot 'Microsoft.BotService/botServices@2022-09-15' = {
  name: botName
  location: 'global'
  sku: { name: 'F0' }
  properties: {
    runtimeVersion: 'V4'
    ownerIds: [
      web.identity.principalId
    ]
    displayName: 'Pippa Teams Bot'
    msaAppId: web.identity.principalId
    endpoint: 'https://${webAppName}.azurewebsites.net/api/messages'
  }
}
