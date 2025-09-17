param(
  [switch]$DryRun,
  [switch]$SkipSecrets,
  [switch]$SkipPubSub
)

$ErrorActionPreference = "Stop"

function Run([string]$cmd) {
  Write-Host ">>> $cmd" -ForegroundColor Cyan
  if (-not $DryRun) { Invoke-Expression $cmd }
}

function Remove-BOM([string]$s) {
  if ($null -eq $s) { return $s }
  $s = $s -replace "^\uFEFF", ""
  return $s.Trim()
}

# ---- Helpers (use gcloud.cmd via cmd /c to avoid PS error records) ----
function SecretExists([string]$name, [string]$project) {
  $cmd = "gcloud.cmd secrets describe $name --project $project --format=""value(name)"""
  Write-Host ">>> $cmd" -ForegroundColor Cyan
  if ($DryRun) { return $true }
  $null = & cmd /c $cmd 2>&1
  return ($LASTEXITCODE -eq 0)
}
function TopicExists([string]$name, [string]$project) {
  $cmd = "gcloud.cmd pubsub topics describe $name --project $project --format=""value(name)"""
  Write-Host ">>> $cmd" -ForegroundColor Cyan
  if ($DryRun) { return $true }
  $null = & cmd /c $cmd 2>&1
  return ($LASTEXITCODE -eq 0)
}
function SubscriptionExists([string]$name, [string]$project) {
  $cmd = "gcloud.cmd pubsub subscriptions describe $name --project $project --format=""value(name)"""
  Write-Host ">>> $cmd" -ForegroundColor Cyan
  if ($DryRun) { return $true }
  $null = & cmd /c $cmd 2>&1
  return ($LASTEXITCODE -eq 0)
}
function New-SecretTempFile([string]$value) {
  $tmp = New-TemporaryFile
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($tmp, $value, $utf8NoBom)
  return $tmp
}
function Get-RunUrl([string]$svc, [string]$project, [string]$region) {
  $cmd = "gcloud.cmd run services describe $svc --project $project --region $region --format=""value(status.url)"""
  Write-Host ">>> $cmd" -ForegroundColor Cyan
  if ($DryRun) { return $null }
  $out = & cmd /c $cmd 2>&1
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) {
    Write-Warning "Could not resolve Cloud Run URL for '$svc' in region '$region'."
    return $null
  }
  return $out.Trim()
}
function Set-PubSubTopic([string]$topic, [string]$project, [string]$retention) {
  if (-not (TopicExists -name $topic -project $project)) {
    $create = "gcloud pubsub topics create $topic --project $project"
    if ($retention) { $create += " --message-retention-duration=$retention" }
    Run $create
  } else {
    if ($retention) {
      Run "gcloud pubsub topics update $topic --project $project --message-retention-duration=$retention"
    }
  }
}
function Set-PubSubSubscription(
  [string]$subName, [string]$topic, [string]$project,
  [string]$pushEndpoint, [string]$oidcSA,
  [string]$dlqTopic, [string]$maxAttempts, [bool]$ordering
) {
  if (SubscriptionExists -name $subName -project $project) {
    Write-Host "Subscription $subName exists" -ForegroundColor Gray
    return
  }
  $cmd = @(
    "gcloud pubsub subscriptions create $subName",
    "--project $project",
    "--topic=$topic"
  )
  if ($pushEndpoint) { $cmd += "--push-endpoint=""$pushEndpoint""" }
  if ($oidcSA)      { $cmd += "--push-auth-service-account=""$oidcSA""" }
  if ($dlqTopic)    { $cmd += "--dead-letter-topic=projects/$project/topics/$dlqTopic" }
  if ($maxAttempts) { $cmd += "--max-delivery-attempts=$maxAttempts" }
  if ($ordering)    { $cmd += "--enable-message-ordering" }

  Run ($cmd -join " ")
}
function Add-RunInvokerBinding([string]$service, [string]$member, [string]$project, [string]$region) {
  Run "gcloud run services add-iam-policy-binding $service --project $project --region $region --member=""serviceAccount:$member"" --role=""roles/run.invoker"""
}

# ---- Load .env ----
$envMap = @{}
$envFile = ".env"
if (!(Test-Path $envFile)) { throw ".env not found" }

(Get-Content $envFile | Where-Object { $_ -and ($_ -notmatch '^\s*#') }) | ForEach-Object {
  $line = Remove-BOM $_
  $pair = $line -split '=', 2
  if ($pair.Count -eq 2) {
    $key = Remove-BOM ($pair[0].Trim())
    $val = Remove-BOM ($pair[1].Trim())
    if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
      $val = $val.Substring(1, $val.Length - 2)
    }
    $envMap[$key] = $val
  }
}

# ---- Deploy params ----
$serviceName = "ble-callback-sender"

$projectId = (& gcloud config get-value project) -replace '\s',''
if (-not $projectId) { throw "Set default project first: gcloud config set project <ID>" }

$region = (& gcloud config get-value run/region) -replace '\s',''
if (-not $region) { $region = "europe-west1" }

$repo = "$region-docker.pkg.dev/$projectId/e2blebackend"
$imageTag = if ($envMap.ContainsKey('IMAGE_TAG') -and $envMap.IMAGE_TAG) { $envMap.IMAGE_TAG } else { "latest" }
$imagePath = "{0}/{1}:{2}" -f $repo, $serviceName, $imageTag

$svcAcct = if ($envMap.ContainsKey('SERVICE_ACCOUNT') -and $envMap.SERVICE_ACCOUNT) {
  $envMap.SERVICE_ACCOUNT
} else {
  "$serviceName-cloudrun@$projectId.iam.gserviceaccount.com"
}

Write-Host "Project: $projectId" -ForegroundColor Gray
Write-Host "Region:  $region" -ForegroundColor Gray
Write-Host "Image:   $imagePath" -ForegroundColor Gray
Write-Host "SA:      $svcAcct" -ForegroundColor Gray

# ---- Ensure SA + roles (idempotent) ----
$null = (& cmd /c "gcloud.cmd iam service-accounts describe $svcAcct" 2>&1)
if ($LASTEXITCODE -ne 0) {
  Run "gcloud iam service-accounts create $($serviceName)-cloudrun --display-name ""$serviceName (Cloud Run)"""
}
Run "gcloud projects add-iam-policy-binding $projectId --member=""serviceAccount:$svcAcct"" --role=""roles/cloudsql.client"""
Run "gcloud projects add-iam-policy-binding $projectId --member=""serviceAccount:$svcAcct"" --role=""roles/logging.logWriter"""

# ---- Secrets (unless -SkipSecrets) ----
$requiredKeys = @('DB_USER','DB_PASSWORD','DB_NAME','INSTANCE_CONNECTION_NAME','PRIVATE_IP','PORT')
$runtimeKeys = @()
foreach ($k in $requiredKeys) {
  if ($envMap.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace($envMap[$k])) {
    $runtimeKeys += $k
  }
}
if ($runtimeKeys.Count -lt 4) { throw "Missing required .env values for DB/INSTANCE/PORT." }

$updatePairs = @()  # ENV=SECRET:latest
foreach ($key in $runtimeKeys) {
  $updatePairs += "{0}={1}:latest" -f $key, $key

  if ($SkipSecrets) { continue }

  $val = Remove-BOM $envMap[$key]
  $tmpFile = New-SecretTempFile -value $val

  $exists = SecretExists -name $key -project $projectId
  if (-not $exists) {
    Run "gcloud secrets create $key --project $projectId --replication-policy=automatic --data-file=""$tmpFile"""
  } else {
    Run "gcloud secrets versions add $key --project $projectId --data-file=""$tmpFile"""
  }
  Run "gcloud secrets add-iam-policy-binding $key --project $projectId --member=""serviceAccount:$svcAcct"" --role=""roles/secretmanager.secretAccessor"" --quiet"
}
$updateSecretsArg = ($updatePairs -join ",")

# ---- Deploy Cloud Run service ----
$cmd = @(
  "gcloud run deploy $serviceName",
  "--project ""$projectId""",
  "--image=""$imagePath""",
  "--platform managed",
  "--region $region",
  "--service-account=""$svcAcct""",
  "--no-allow-unauthenticated",
  "--update-secrets=""$updateSecretsArg"""
)

# Cloud SQL
$inst = $envMap['INSTANCE_CONNECTION_NAME']
if ($inst -and $inst.Trim() -ne "") { $cmd += "--add-cloudsql-instances=""$inst""" }

# Optional runtime knobs
foreach ($kv in @('CR_MEMORY','CR_CPU','CR_MIN_INSTANCES','CR_MAX_INSTANCES','CR_CONCURRENCY','VPC_CONNECTOR')) {
  if ($envMap.ContainsKey($kv) -and $envMap[$kv]) {
    switch ($kv) {
      'CR_MEMORY'        { $cmd += "--memory=$($envMap[$kv])" }
      'CR_CPU'           { $cmd += "--cpu=$($envMap[$kv])" }
      'CR_MIN_INSTANCES' { $cmd += "--min-instances=$($envMap[$kv])" }
      'CR_MAX_INSTANCES' { $cmd += "--max-instances=$($envMap[$kv])" }
      'CR_CONCURRENCY'   { $cmd += "--concurrency=$($envMap[$kv])" }
      'VPC_CONNECTOR'    { $cmd += "--vpc-connector=$($envMap[$kv])" }
    }
  }
}

$deployCommand = ($cmd -join " ")
Write-Host "`nDeploy command:" -ForegroundColor Yellow
Write-Host $deployCommand -ForegroundColor Cyan

if ($DryRun) { Write-Host "`n(Dry run) Not executing." -ForegroundColor Yellow; return }
Run $deployCommand

# ---- Pub/Sub wiring (unless -SkipPubSub) ----
if (-not $SkipPubSub) {
  # Defaults
  $topic       = 'ble-callbacks'
  $subName     = 'ble-callbacks-push'
  $dlqTopic    = "$topic-dlq"
  $retention   = '7d'
  $maxAttempts = '5'
  $orderingFlag = $true   # recommended for per-device ordering

  # Overrides from .env
  if ($envMap.ContainsKey('CALLBACK_TOPIC') -and $envMap['CALLBACK_TOPIC']) { $topic = $envMap['CALLBACK_TOPIC'] }
  if ($envMap.ContainsKey('CALLBACK_SUBSCRIPTION_NAME') -and $envMap['CALLBACK_SUBSCRIPTION_NAME']) { $subName = $envMap['CALLBACK_SUBSCRIPTION_NAME'] }
  if ($envMap.ContainsKey('CALLBACK_DLQ_TOPIC') -and $envMap['CALLBACK_DLQ_TOPIC']) { $dlqTopic = $envMap['CALLBACK_DLQ_TOPIC'] }
  if ($envMap.ContainsKey('PUBSUB_RETENTION') -and $envMap['PUBSUB_RETENTION']) { $retention = $envMap['PUBSUB_RETENTION'] }
  if ($envMap.ContainsKey('PUBSUB_MAX_DELIVERY_ATTEMPTS') -and $envMap['PUBSUB_MAX_DELIVERY_ATTEMPTS']) { $maxAttempts = $envMap['PUBSUB_MAX_DELIVERY_ATTEMPTS'] }
  if ($envMap.ContainsKey('CALLBACK_ORDERING') -and $envMap['CALLBACK_ORDERING']) {
    $v = $envMap['CALLBACK_ORDERING'].ToString().ToLower()
    $orderingFlag = ($v -eq '1' -or $v -eq 'true' -or $v -eq 'yes')
  }

  # Resolve service URL
  $pushEndpoint = Get-RunUrl -svc $serviceName -project $projectId -region $region

  # Topics (main + DLQ)
  Set-PubSubTopic -topic $topic    -project $projectId -retention $retention
  Set-PubSubTopic -topic $dlqTopic -project $projectId -retention $retention

  # Pub/Sub service agent (for OIDC + invoker)
  $projectNumber = (& cmd /c "gcloud.cmd projects describe $projectId --format=""value(projectNumber)""" 2>&1).Trim()
  $pubsubSA = "service-$projectNumber@gcp-sa-pubsub.iam.gserviceaccount.com"

  if ($pushEndpoint) {
    # Allow Pub/Sub to invoke the service
    Add-RunInvokerBinding -service $serviceName -member $pubsubSA -project $projectId -region $region

    # Create push subscription
    Set-PubSubSubscription -subName $subName -topic $topic -project $projectId `
      -pushEndpoint $pushEndpoint -oidcSA $pubsubSA `
      -dlqTopic $dlqTopic -maxAttempts $maxAttempts -ordering $orderingFlag
  } else {
    Write-Warning "Service URL not found; skipping invoker binding and push subscription creation."
  }
} else {
  Write-Host "Skipping Pub/Sub configuration per -SkipPubSub." -ForegroundColor Yellow
}

# Print URL
$svcUrl = Get-RunUrl -svc $serviceName -project $projectId -region $region
if ($svcUrl) { Write-Host "Service URL: $svcUrl" -ForegroundColor Green }