param(
  [switch]$DryRun,
  [switch]$SkipSecrets,
  [switch]$SkipPubSub
)

$ErrorActionPreference = "Stop"

# ---------- Helpers ----------
function Run([string]$cmd) {
  Write-Host ">>> $cmd" -ForegroundColor Cyan
  if ($DryRun) { return }
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $out = & cmd /c $cmd 2>&1
  $code = $LASTEXITCODE; $ErrorActionPreference = $old
  if ($code -ne 0) {
    Write-Host $out -ForegroundColor Red
    throw "Command failed (exit $code): $cmd"
  }
}

function Remove-BOM([string]$s) {
  if ($null -eq $s) { return $s }
  $s = $s -replace "^\uFEFF", ""
  return $s.Trim()
}

function Invoke-Gcloud([string]$GcloudParams) {
  # Executes gcloud.cmd safely; never throws. Returns @{ ExitCode; Output<string>; Raw<string> }
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $raw = & cmd /c "gcloud.cmd $GcloudParams" 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $old
  $txt = ($raw | Out-String)
  return @{ ExitCode = $code; Output = $txt; Raw = $txt }
}

function Get-GcloudValue([string]$GcloudParams) {
  # For 'gcloud config get-value ...' etc. Returns the last non-empty line,
  # ignoring banners like "Your active configuration is:"
  $res = Invoke-Gcloud $GcloudParams
  $lines = ($res.Output -split "(`r`n|`n|`r)") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  $clean = $lines | Where-Object { $_ -notlike "Your active configuration is:*" }
  if ($clean.Count -gt 0) { return $clean[-1] }
  elseif ($lines.Count -gt 0) { return $lines[-1] }
  else { return "" }
}

function SecretExists([string]$name, [string]$project) {
  Write-Host ">>> gcloud secrets describe $name --project $project" -ForegroundColor Cyan
  $res = Invoke-Gcloud "secrets describe $name --project $project --format=""value(name)"""
  return ($res.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($res.Output))
}
function TopicExists([string]$name, [string]$project) {
  Write-Host ">>> gcloud pubsub topics describe $name --project $project" -ForegroundColor Cyan
  $res = Invoke-Gcloud "pubsub topics describe $name --project $project --format=""value(name)"""
  return ($res.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($res.Output))
}
function SubscriptionExists([string]$name, [string]$project) {
  Write-Host ">>> gcloud pubsub subscriptions describe $name --project $project" -ForegroundColor Cyan
  $res = Invoke-Gcloud "pubsub subscriptions describe $name --project $project --format=""value(name)"""
  return ($res.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($res.Output))
}
function New-SecretTempFile([string]$value) {
  $tmp = New-TemporaryFile
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($tmp, $value, $utf8NoBom)
  return $tmp
}
function Get-RunUrl([string]$svc, [string]$project, [string]$region) {
  Write-Host ">>> gcloud run services describe $svc --project $project --region $region --format=value(status.url)" -ForegroundColor Cyan
  $res = Invoke-Gcloud "run services describe $svc --project $project --region $region --format=""value(status.url)"""
  if ($res.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($res.Output)) { return $null }
  return ($res.Output.Trim())
}
function Set-PubSubTopic([string]$topic, [string]$project, [string]$retention) {
  if (-not (TopicExists -name $topic -project $project)) {
    $cmd = "gcloud pubsub topics create $topic --project $project"
    if ($retention) { $cmd += " --message-retention-duration=$retention" }
    Run $cmd
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

# ---------- Load .env ----------
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

# ---------- Deploy params ----------
$serviceName = "ble-callback-sender"

# Project (prefer env var if set)
$projectId = $env:GOOGLE_CLOUD_PROJECT
if (-not $projectId) { $projectId = Get-GcloudValue "config get-value project" }
if (-not $projectId -or $projectId -eq "(unset)") {
  throw "Set default project: gcloud config set project <PROJECT_ID>"
}

# Region (fallback default)
$region = Get-GcloudValue "config get-value run/region"
if (-not $region -or $region -eq "(unset)") { $region = "europe-west1" }

$repo = "$region-docker.pkg.dev/$projectId/e2blebackend"

# Image tag
$imageTag = "latest"
if ($envMap.ContainsKey('IMAGE_TAG') -and $envMap.IMAGE_TAG) { $imageTag = $envMap.IMAGE_TAG }
$imagePath = "{0}/{1}:{2}" -f $repo, $serviceName, $imageTag

# Service account (PS 5.1–safe)
$svcAcct = "ble-callback-sender-cloudrun@$projectId.iam.gserviceaccount.com"
if ($envMap.ContainsKey('SERVICE_ACCOUNT') -and $envMap.SERVICE_ACCOUNT) {
  $svcAcct = $envMap.SERVICE_ACCOUNT
}

Write-Host "Project: $projectId" -ForegroundColor Gray
Write-Host "Region:  $region" -ForegroundColor Gray
Write-Host "Image:   $imagePath" -ForegroundColor Gray
Write-Host "SA:      $svcAcct" -ForegroundColor Gray

# ---------- Ensure SA + roles ----------
$saCheck = Invoke-Gcloud "iam service-accounts describe $svcAcct --project $projectId --format=""value(email)"""
if ($saCheck.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($saCheck.Output)) {
  Write-Host "Service account not found; creating $svcAcct" -ForegroundColor Yellow
  $createRes = Invoke-Gcloud "iam service-accounts create ble-callback-sender-cloudrun --project $projectId --display-name ""ble-callback-sender (Cloud Run)"""
  if ($createRes.ExitCode -ne 0) {
    Write-Host $createRes.Raw -ForegroundColor Red
    throw "Failed to create service account. Do you have roles/iam.serviceAccountAdmin on $projectId?"
  }
}

Run "gcloud projects add-iam-policy-binding $projectId --member=""serviceAccount:$svcAcct"" --role=""roles/cloudsql.client"""
Run "gcloud projects add-iam-policy-binding $projectId --member=""serviceAccount:$svcAcct"" --role=""roles/logging.logWriter"""

# ---------- Secrets (unless -SkipSecrets) ----------
$requiredKeys = @('DB_USER','DB_PASSWORD','DB_NAME','INSTANCE_CONNECTION_NAME','PRIVATE_IP')  # NOTE: no PORT
$runtimeKeys = @()
foreach ($k in $requiredKeys) {
  if ($envMap.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace($envMap[$k])) {
    $runtimeKeys += $k
  }
}
if ($runtimeKeys.Count -lt 4) { throw "Missing required .env values for DB/INSTANCE." }

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

# ---------- Deploy Cloud Run service ----------
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

# Cloud SQL instance
$inst = $envMap['INSTANCE_CONNECTION_NAME']
if ($inst -and $inst.Trim() -ne "") { $cmd += "--add-cloudsql-instances=""$inst""" }

# Optional runtime knobs (ensure quota-friendly values)
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

# ---------- Pub/Sub wiring (unless -SkipPubSub) ----------
if (-not $SkipPubSub) {
  # Defaults (override via .env if you want)
  $topic        = 'ble-callbacks'
  $dlqTopic     = "$topic-dlq"
  $subName      = 'ble-callbacks-push'
  $retention    = '24h'
  $maxAttempts  = '5'
  $orderingFlag = $true

  # Overrides (strip inline comments safely)
  if ($envMap.ContainsKey('CALLBACK_TOPIC') -and $envMap['CALLBACK_TOPIC']) { $topic = $envMap['CALLBACK_TOPIC'] }
  if ($envMap.ContainsKey('CALLBACK_DLQ_TOPIC') -and $envMap['CALLBACK_DLQ_TOPIC']) { $dlqTopic = $envMap['CALLBACK_DLQ_TOPIC'] }
  if ($envMap.ContainsKey('CALLBACK_SUBSCRIPTION_NAME') -and $envMap['CALLBACK_SUBSCRIPTION_NAME']) { $subName = $envMap['CALLBACK_SUBSCRIPTION_NAME'] }
  if ($envMap.ContainsKey('PUBSUB_RETENTION') -and $envMap['PUBSUB_RETENTION']) { $retention = ($envMap['PUBSUB_RETENTION'] -replace '\s+#.*$','').Trim() }
  if ($envMap.ContainsKey('PUBSUB_MAX_DELIVERY_ATTEMPTS') -and $envMap['PUBSUB_MAX_DELIVERY_ATTEMPTS']) { $maxAttempts = ($envMap['PUBSUB_MAX_DELIVERY_ATTEMPTS'] -replace '\s+#.*$','').Trim() }
  if ($envMap.ContainsKey('CALLBACK_ORDERING') -and $envMap['CALLBACK_ORDERING']) {
    $v = ($envMap['CALLBACK_ORDERING'] -replace '\s+#.*$','').Trim().ToLower()
    $orderingFlag = ($v -eq '1' -or $v -eq 'true' -or $v -eq 'yes')
  }

  # Ensure Pub/Sub API enabled (idempotent)
  Run "gcloud services enable pubsub.googleapis.com --project $projectId"

  # Hardcoded identities (no project-number lookup needed)
  $pushSa   = "ble-pubsub-push@ble-backend-prod.iam.gserviceaccount.com"
  $pubsubSA = "service-1021490588060@gcp-sa-pubsub.iam.gserviceaccount.com"  # Pub/Sub service agent for your project

  # Ensure push SA exists
  $saPushCheck = Invoke-Gcloud "iam service-accounts describe $pushSa --project $projectId --format=value(email)"
  if ($saPushCheck.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($saPushCheck.Output)) {
    $pushSaId = $pushSa.Split('@')[0]
    Run ("gcloud iam service-accounts create {0} --project {1} --display-name ""Pub/Sub Push (callbacks)""" -f $pushSaId, $projectId)
  }

  # Ensure topics (main + DLQ)
  Set-PubSubTopic -topic $topic    -project $projectId -retention $retention
  Set-PubSubTopic -topic $dlqTopic -project $projectId -retention $retention

  # Cloud Run URL (push endpoint)
  $pushEndpoint = Get-RunUrl -svc $serviceName -project $projectId -region $region

  if ($pushEndpoint) {
    # Allow Pub/Sub service agent to mint OIDC tokens AS your push SA
    Run ("gcloud iam service-accounts add-iam-policy-binding {0} --project {1} --member serviceAccount:{2} --role roles/iam.serviceAccountTokenCreator" `
         -f $pushSa, $projectId, $pubsubSA)

    # Allow your current caller to ActAs the push SA (so create sub with --push-auth-service-account works)
$acct = Get-GcloudValue "config get-value account"   # strips 'Your active configuration is: ...'
if (-not [string]::IsNullOrWhiteSpace($acct)) {
  if ($acct.ToLower().Contains("gserviceaccount.com")) { $callerMember = "serviceAccount:$acct" } else { $callerMember = "user:$acct" }
  Run ("gcloud iam service-accounts add-iam-policy-binding {0} --project {1} --member {2} --role roles/iam.serviceAccountUser" `
       -f $pushSa, $projectId, $callerMember)
}

    # Allow the push SA to invoke your Cloud Run service
    Run ("gcloud run services add-iam-policy-binding {0} --project {1} --region {2} --member serviceAccount:{3} --role roles/run.invoker" `
         -f $serviceName, $projectId, $region, $pushSa)

    # Create push subscription authenticated as your push SA
    Set-PubSubSubscription -subName $subName -topic $topic -project $projectId `
      -pushEndpoint $pushEndpoint -oidcSA $pushSa `
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