if ($args.Count -gt 0) {
    $KvName = $args[0]
} else {
    $KvName = $null
}

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$WranglerToml = Join-Path $ProjectDir "wrangler.toml"
$LogFile = Join-Path $ScriptDir "step-kv.log"
$BackupDir = Join-Path $ScriptDir "backups"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "[$timestamp] $Message"
    Write-Host $logMsg
    Add-Content -Path $LogFile -Value $logMsg -Encoding UTF8
}

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
    Write-Log $Message
}

function Write-Success {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
    Write-Log $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
    Write-Log "WARN: $Message"
}

function Write-Err {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Log "ERROR: $Message"
}

function Initialize-BackupDir {
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        Write-Log "Created backup directory: $BackupDir"
    }
}

function Backup-ConfigFile {
    param([string]$FilePath)

    Initialize-BackupDir

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFileName = "wrangler_$timestamp.toml"
    $backupPath = Join-Path $BackupDir $backupFileName

    try {
        Copy-Item -Path $FilePath -Destination $backupPath -Force
        Write-Log "Backup created: $backupPath"
        return $backupPath
    } catch {
        Write-Err "Failed to create backup: $_"
        throw "Backup failed, aborting to prevent config corruption"
    }
}

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 2,
        [string]$OperationName = "operation",
        [object[]]$ArgumentList = @()
    )

    $attempt = 1
    $lastError = $null

    while ($attempt -le $MaxRetries) {
        try {
            Write-Log "Attempt $attempt/$MaxRetries for: $OperationName"

            if ($ArgumentList.Count -gt 0) {
                $result = & $ScriptBlock @ArgumentList
            } else {
                $result = & $ScriptBlock
            }

            if ($null -ne $result) {
                return $result
            }

            if ($attempt -eq $MaxRetries) {
                break
            }

        } catch {
            $lastError = $_
            Write-Warn "Attempt $attempt failed: $_"
        }

        if ($attempt -lt $MaxRetries) {
            Write-Log "Retrying in $DelaySeconds seconds..."
            Start-Sleep -Seconds $DelaySeconds
            $DelaySeconds = $DelaySeconds * 2
        }

        $attempt++
    }

    throw "$OperationName failed after $MaxRetries attempts. Last error: $lastError"
}

function Test-InputParameter {
    Write-Log "Validating input parameter: KvName"

    if ([string]::IsNullOrWhiteSpace($KvName)) {
        Write-Err "KV name parameter is required but was not provided"
        Write-Host ""
        Write-Host "Usage: .\step-kv.ps1 <KVName>" -ForegroundColor Yellow
        Write-Host "Example: .\step-kv.ps1 my-kv-namespace" -ForegroundColor Yellow
        exit 1
    }

    if ($KvName -notmatch '^[a-zA-Z0-9_-]+$') {
        Write-Err "Invalid KV name format. Only alphanumeric characters, underscores, and hyphens are allowed"
        Write-Host "Provided KV name: $KvName" -ForegroundColor Yellow
        exit 1
    }

    Write-Success "Input parameter validation passed: $KvName"
}

function Get-ExistingKvId {
    param([string]$Name)

    $result = $null
    try {
        $result = Invoke-WithRetry -OperationName "Query KV namespace" -MaxRetries 3 -DelaySeconds 2 -ScriptBlock {
            param([string]$Name)

            Write-Log "Checking if KV namespace '$Name' already exists..."

            $output = npx wrangler kv namespace list 2>&1 | Out-String

            if ([string]::IsNullOrWhiteSpace($output)) {
                Write-Log "Empty response from wrangler kv namespace list"
                return $null
            }

            $json = $output | ConvertFrom-Json

            if ($null -eq $json) {
                Write-Log "Failed to parse JSON response"
                return $null
            }

            if ($json -is [Array]) {
                $existing = $json | Where-Object { $_.title -eq $Name } | Select-Object -First 1
                if ($null -ne $existing) {
                    Write-Log "Found existing KV: $Name with ID: $($existing.id)"
                    return $existing.id
                }
            } elseif ($null -ne $json -and $json.title -eq $Name) {
                Write-Log "Found existing KV: $Name with ID: $($json.id)"
                return $json.id
            }

            Write-Log "KV namespace '$Name' does not exist"
            return $null

        } -ArgumentList @($Name)
    } catch {
        Write-Warn "Failed to query KV namespace: $_"
    }

    return $result
}

function New-KvNamespace {
    param([string]$Name)

    Write-Log "Creating new KV namespace: $Name"

    $result = $null
    try {
        $result = Invoke-WithRetry -OperationName "Create KV namespace" -MaxRetries 3 -DelaySeconds 3 -ScriptBlock {
            param([string]$Name)

            $output = npx wrangler kv namespace create $Name 2>&1 | Out-String
            Write-Log "Wrangler output: $output"

            if ($output -match "id = `"(.*?)`"") {
                $kvId = $matches[1]
                Write-Success "KV created successfully with ID: $kvId"
                return $kvId
            }

            if ($output -match "Error|error|ERROR") {
                Write-Err "KV creation failed: $output"
                throw "KV creation returned error: $output"
            }

            Write-Err "Failed to extract KV ID from output"
            throw "KV creation succeeded but ID extraction failed"

        } -ArgumentList @($Name)
    } catch {
        Write-Err "Failed to create KV namespace: $_"
    }

    return $result
}

function Test-WranglerTomlExists {
    if (-not (Test-Path $WranglerToml)) {
        Write-Err "wrangler.toml not found at: $WranglerToml"
        exit 1
    }
    Write-Log "wrangler.toml found at: $WranglerToml"
}

function Get-CurrentKvIdFromConfig {
    try {
        $content = Get-Content $WranglerToml -Raw -Encoding UTF8
        if ($content -match 'id\s*=\s*"(.*?)"') {
            return $matches[1]
        }
        return $null
    } catch {
        Write-Warn "Failed to read current KV ID from config: $_"
        return $null
    }
}

function Update-WranglerTomlConfig {
    param(
        [string]$KvId,
        [string]$KvName
    )

    Write-Log "Updating wrangler.toml with KV ID: $KvId"

    $backupPath = Backup-ConfigFile -FilePath $WranglerToml

    try {
        $content = Get-Content $WranglerToml -Raw -Encoding UTF8
        $originalContent = $content

        $updated = $false

        if ($content -match '(\[\[kv_namespaces\]\][\s\S]*?)id\s*=\s*"[^"]+"') {
            $content = $content -replace '(\[\[kv_namespaces\]\][\s\S]*?)id\s*=\s*"[^"]+"', "`$1id = `"$KvId`""
            $updated = $true
            Write-Log "Updated KV ID in [[kv_namespaces]] section"
        }

        if ($updated) {
            Set-Content -Path $WranglerToml -Value $content -Encoding UTF8 -NoNewline
            Write-Success "wrangler.toml updated successfully"
        } else {
            throw "Failed to update wrangler.toml - KV namespace id field not found"
        }

        return $true

    } catch {
        Write-Warn "Failed to update wrangler.toml: $_"
        if ($null -ne $backupPath -and $backupPath -ne "") {
            Write-Log "Restoring from backup: $backupPath"
            try {
                Copy-Item -Path $backupPath -Destination $WranglerToml -Force
                Write-Log "Config restored from backup"
            } catch {
                Write-Err "Critical: Failed to restore config from backup: $_"
            }
        }
        throw
    }
}

function Test-ConfigUpdate {
    param([string]$ExpectedKvId)

    Write-Log "Verifying config update..."

    try {
        $content = Get-Content $WranglerToml -Raw -Encoding UTF8

        if ($content -match 'id\s*=\s*"(.*?)"') {
            $actualId = $matches[1]

            if ($actualId -eq $ExpectedKvId) {
                Write-Success "Config verification passed - KV ID correctly written: $actualId"
                return $true
            } else {
                Write-Err "Config verification failed - Expected: $ExpectedKvId, Found: $actualId"
                return $false
            }
        } else {
            Write-Err "Config verification failed - No KV ID found in config"
            return $false
        }
    } catch {
        Write-Err "Config verification error: $_"
        return $false
    }
}

function Find-DocumentationFiles {
    $docExtensions = @("*.md", "*.txt", "*.json", "*.yaml", "*.yml")
    $excludeDirs = @("node_modules", ".git", "dist", "build", "coverage", "scripts", "backups")

    $docs = @()
    foreach ($ext in $docExtensions) {
        $docs += Get-ChildItem -Path $ProjectDir -Recurse -Include $ext -File -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -notmatch ($excludeDirs -join '|') }
    }
    return $docs
}

function Update-DocumentationKvId {
    param(
        [string]$OldKvId,
        [string]$NewKvId,
        [string]$KvName
    )

    if ([string]::IsNullOrEmpty($OldKvId)) {
        Write-Log "No old KV ID provided, skipping documentation update"
        return
    }

    Write-Log "Checking documentation files for KV ID updates..."

    $docs = Find-DocumentationFiles
    $updatedCount = 0

    foreach ($doc in $docs) {
        try {
            $content = Get-Content $doc.FullName -Raw -Encoding UTF8
            if ($content -match [regex]::Escape($OldKvId)) {
                $newContent = $content -replace [regex]::Escape($OldKvId), $NewKvId
                Set-Content -Path $doc.FullName -Value $newContent -Encoding UTF8
                Write-Log "Updated KV ID in: $($doc.FullName)"
                $updatedCount++
            }
        } catch {
            Write-Warn "Failed to update $($doc.FullName): $_"
        }
    }

    if ($updatedCount -gt 0) {
        Write-Success "Updated $updatedCount documentation file(s)"
    } else {
        Write-Log "No documentation files needed updating"
    }
}

function Main {
    Write-Host ""
    Write-Host "========== KV Namespace Management ==========" -ForegroundColor Cyan
    Write-Log "Starting KV namespace management for: $KvName"
    Write-Host ""

    Test-InputParameter
    Test-WranglerTomlExists

    $currentKvId = Get-CurrentKvIdFromConfig
    if ($null -ne $currentKvId) {
        Write-Log "Current KV ID in wrangler.toml: $currentKvId"
    }

    Set-Location $ProjectDir

    Write-Log "Step 1: Query KV namespace status..."
    $existingKvId = Get-ExistingKvId -Name $KvName

    $kvIdToUse = $null
    $isNewKv = $false

    if ($null -ne $existingKvId) {
        Write-Info "KV namespace '$KvName' already exists with ID: $existingKvId"
        $kvIdToUse = $existingKvId

        if ($existingKvId -eq $currentKvId) {
            Write-Info "Current wrangler.toml already uses this KV ID, no update needed"
            Write-Success "========== SUCCESS =========="
            Write-Success "Using existing KV namespace: $KvName"
            Write-Success "KV ID: $kvIdToUse"
            Write-Success "wrangler.toml: Already up to date"
            Write-Host ""
            Write-Host "Next: npm run deploy" -ForegroundColor Cyan
            Write-Log "Done"
            return
        } else {
            Write-Info "Updating wrangler.toml to use existing KV ID..."
            $success = Update-WranglerTomlConfig -KvId $kvIdToUse -KvName $KvName
            if (-not $success) {
                Write-Err "Failed to update wrangler.toml"
                exit 1
            }
            if ($null -ne $currentKvId) {
                Update-DocumentationKvId -OldKvId $currentKvId -NewKvId $kvIdToUse -KvName $KvName
            }
        }
    } else {
        Write-Log "Step 2: Creating new KV namespace..."
        $kvIdToUse = New-KvNamespace -Name $KvName

        if ([string]::IsNullOrEmpty($kvIdToUse)) {
            Write-Err "Failed to create KV namespace"
            exit 1
        }

        $isNewKv = $true

        Write-Log "Step 3: Updating wrangler.toml..."
        $success = Update-WranglerTomlConfig -KvId $kvIdToUse -KvName $KvName

        if (-not $success) {
            Write-Err "Failed to update wrangler.toml"
            exit 1
        }

        if ($null -ne $currentKvId) {
            Update-DocumentationKvId -OldKvId $currentKvId -NewKvId $kvIdToUse -KvName $KvName
        }
    }

    Write-Log "Step 4: Verifying configuration update..."
    $verified = Test-ConfigUpdate -ExpectedKvId $kvIdToUse
    if (-not $verified) {
        Write-Err "Configuration verification failed, please check the config file manually"
        exit 1
    }

    Write-Host ""
    Write-Host "========== SUCCESS ==========" -ForegroundColor Green
    if ($isNewKv) {
        Write-Success "New KV namespace created: $KvName"
    } else {
        Write-Success "Using existing KV namespace: $KvName"
    }
    Write-Success "KV ID: $kvIdToUse"
    Write-Success "wrangler.toml: Updated and verified"
    Write-Host ""
    Write-Host "Next: npm run deploy" -ForegroundColor Cyan
    Write-Log "Done - All steps completed successfully"
}

Main
