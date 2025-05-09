// infra/main.bicep
@description('Subscription and location')
param location string = 'swedencentral'
@allowed([
  'B3'
  'P1v3'
])
param appServiceSku string = 'B3'

@description('Global names – do not change after first deploy')
var resourceGroupName        = 'pippaoflondon-rg'
var appServicePlanName       = 'pippaoflondon-plan'
var webAppName               = 'pippaoflondonai'
var storageAccountName       = 'pippaoflondonstore'
var cosmosAccountName        = 'pippaoflondon-cosmos'
var searchServiceName        = 'pippaoflondon-search'
var speechName               = 'pippaoflondon-speech'
var openAIName               = 'pippaai-sc'
var docIntName               = 'pippaoflondon-docint'
var keyVaultName             = 'pippaoflondon-kv'
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
        zoneRedundant: false
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
    encryption: { status: 'Enabled' }
  }
}

// model deployments
var models = [
  { name: 'gpt4o'              sku: 'gpt-4o'                        }
  { name: 'gpt41'              sku: 'gpt-4.1'                      }
  { name: 'o3-mini'            sku: 'o3-mini'                      }
  { name: 'dalle3'             sku: 'dalle3'                       }
  { name: 'whisper'            sku: 'whisper'                      }
]

resource deployments 'Microsoft.CognitiveServices/accounts/deployments@2023-10-01' = [for m in models: {
  parent: aoai
  name: m.name
  properties: {
    model: {
      format: 'OpenAI'
      name: m.sku
      version: 'latest'
    }
    scaleSettings: {
      type: 'Standard'
    }
  }
}]

// --------------------------------------------------
//  Document Intelligence
// --------------------------------------------------
resource docInt 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: docIntName
  location: location
  kind: 'DocumentIntelligence'
  sku: { name: 'S0' }
}

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
        { name: 'AZURE_OPENAI_ENDPOINT'          value: aoai.properties.endpoint }
        { name: 'AOAI_MODEL_GPT4O_DEPLOYMENT'    value: 'gpt4o' }
        { name: 'AOAI_MODEL_GPT41_DEPLOYMENT'    value: 'gpt41' }
        { name: 'AOAI_MODEL_O3MINI_DEPLOYMENT'   value: 'o3-mini' }
        { name: 'AOAI_MODEL_DALLE_DEPLOYMENT'    value: 'dalle3' }
        { name: 'AOAI_MODEL_WHISPER_DEPLOYMENT'  value: 'whisper' }
        { name: 'AZUREAI_SEARCH_ENDPOINT'        value: 'https://${search.name}.search.windows.net' }
        { name: 'AZUREAI_SEARCH_KEY'             value: listAdminKeys(search.id, '2023-11-01').primaryKey }
        { name: 'COSMOS_CONNECTION_STRING'       value: listKeys(cosmos.id, '2023-04-15').primaryMasterKey }
        { name: 'STORAGE_CONNECTION_STRING'      value: listKeys(sa.id, '2023-01-01').keys[0].value }
        { name: 'BING_GROUNDING_ENDPOINT'        value: kv.getSecret('bing-endpoint') }
        { name: 'BING_GROUNDING_KEY'             value: kv.getSecret('bing-key') }
      ]
    }
  }
}

// staging slot
resource slot 'Microsoft.Web/sites/slots@2023-01-01' = {
  name: '${webAppName}/staging'
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: plan.id
  }
}

// --------------------------------------------------
//  Bot Channels Registration (for Teams)
// --------------------------------------------------
resource bot 'Microsoft.BotService/botServices@2023-05-15' = {
  name: botName
  location: 'global'
  sku: { name: 'F0' }
  properties: {
    displayName: 'Pippa Teams Bot'
    msaAppId: reference(web.id, '2023-01-01', 'Full').identity.principalId
    endpoint: 'https://${webAppName}.azurewebsites.net/api/messages'
    developerAppInsightKey: reference(web.id, '2023-01-01', 'Full').properties.siteConfig.appSettings[?name=='APPINSIGHTS_INSTRUMENTATIONKEY'].value
  }
}
