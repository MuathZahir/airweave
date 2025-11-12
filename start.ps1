Param(
    [switch]$NonInteractiveParam,
    [switch]$SkipLocalEmbeddingsParam,
    [switch]$SkipFrontendParam,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AdditionalArgs
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Have-Cmd {
    param([Parameter(Mandatory = $true)][string]$Command)
    try {
        Get-Command -Name $Command -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Run-Command {
    param(
        [Parameter(Mandatory = $true)][string[]]$CommandParts,
        [string[]]$Arguments = @(),
        [switch]$CaptureOutput
    )

    if ($CommandParts.Count -eq 0) {
        throw "CommandParts must contain at least one element."
    }

    $exe = $CommandParts[0]
    $baseArgs = @()
    if ($CommandParts.Count -gt 1) {
        $baseArgs = $CommandParts[1..($CommandParts.Count - 1)]
    }

    $fullArgs = @()
    if ($baseArgs) {
        $fullArgs += $baseArgs
    }
    if ($Arguments) {
        $fullArgs += $Arguments
    }

    if ($CaptureOutput) {
        $output = & $exe @fullArgs 2>&1
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $output
        }
    }

    & $exe @fullArgs
    return $LASTEXITCODE
}

function Test-CommandSuccess {
    param(
        [Parameter(Mandatory = $true)][string[]]$CommandParts,
        [string[]]$Arguments = @()
    )

    try {
        $result = Run-Command -CommandParts $CommandParts -Arguments $Arguments -CaptureOutput
        return $result.ExitCode -eq 0
    } catch {
        return $false
    }
}

function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if (-not (Test-Path -Path $FilePath)) {
        return $null
    }

    $regex = "^\s*$([Regex]::Escape($Key))\s*="
    $line = Get-Content -Path $FilePath | Where-Object { $_ -match $regex } | Select-Object -First 1

    if (-not $line) {
        return $null
    }

    $value = $line.Substring($line.IndexOf('=') + 1).Trim()
    if ($value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2)
    }

    return $value.Trim()
}

function Remove-EnvKey {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if (-not (Test-Path -Path $FilePath)) {
        return
    }

    $regex = "^\s*$([Regex]::Escape($Key))\s*="
    $lines = Get-Content -Path $FilePath
    $filtered = $lines | Where-Object { $_ -notmatch $regex }

    if ($filtered.Count -ne $lines.Count) {
        if ($filtered.Count -gt 0) {
            Set-Content -Path $FilePath -Value $filtered -Encoding UTF8
        } else {
            Clear-Content -Path $FilePath -ErrorAction SilentlyContinue
        }
    }
}

function Add-EnvLine {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Line
    )

    Add-Content -Path $FilePath -Value $Line -Encoding UTF8
}

function Add-EnvQuotedValue {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    Add-EnvLine -FilePath $FilePath -Line ("{0}=""{1}""" -f $Key, $Value)
}

function New-RandomBase64String {
    param([int]$Bytes = 32)

    $buffer = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    return [System.Convert]::ToBase64String($buffer)
}

function New-UrlSafeToken {
    param([int]$Bytes = 32)

    $buffer = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    $token = [System.Convert]::ToBase64String($buffer)
    $token = $token.TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return $token
}

$NonInteractive = $NonInteractiveParam.IsPresent
$SkipLocalEmbeddings = $SkipLocalEmbeddingsParam.IsPresent
$SkipFrontend = $SkipFrontendParam.IsPresent

if ($AdditionalArgs) {
    foreach ($arg in $AdditionalArgs) {
        switch ($arg) {
            "--noninteractive" { $NonInteractive = $true }
            "--skip-local-embeddings" { $SkipLocalEmbeddings = $true }
            "--skip-frontend" { $SkipFrontend = $true }
            default {
                Write-Error "Unknown arg: $arg"
                exit 2
            }
        }
    }
}

try {
    $envPath = Join-Path -Path (Get-Location) -ChildPath ".env"
    $envExamplePath = Join-Path -Path (Get-Location) -ChildPath ".env.example"

    if (-not (Test-Path -Path $envPath)) {
        Write-Host "Creating .env file from example..."
        Copy-Item -Path $envExamplePath -Destination $envPath -Force
        Write-Host ".env file created"
    }

    $existingKey = Get-EnvValue -FilePath $envPath -Key "ENCRYPTION_KEY"
    if (-not [string]::IsNullOrEmpty($existingKey)) {
        Write-Host "Encryption key already exists in .env file, skipping generation."
        Write-Host "Current ENCRYPTION_KEY value: ********"
    } else {
        Write-Host "No valid encryption key found. Generating new encryption key..."
        $newKey = New-RandomBase64String -Bytes 32
        Write-Host "Generated key: $newKey"
        Remove-EnvKey -FilePath $envPath -Key "ENCRYPTION_KEY"
        Add-EnvQuotedValue -FilePath $envPath -Key "ENCRYPTION_KEY" -Value $newKey
        Write-Host "Added new ENCRYPTION_KEY to .env file"
    }

    $existingStateSecret = Get-EnvValue -FilePath $envPath -Key "STATE_SECRET"
    if (-not [string]::IsNullOrEmpty($existingStateSecret)) {
        Write-Host "STATE_SECRET already exists in .env file, skipping generation."
        Write-Host "Current STATE_SECRET value: ********"
    } else {
        Write-Host "No valid STATE_SECRET found. Generating new HMAC secret..."
        $newStateSecret = New-UrlSafeToken -Bytes 32
        Write-Host "Generated STATE_SECRET: ********"
        Remove-EnvKey -FilePath $envPath -Key "STATE_SECRET"
        Add-EnvQuotedValue -FilePath $envPath -Key "STATE_SECRET" -Value $newStateSecret
        Write-Host "Added new STATE_SECRET to .env file"
    }

    if (-not (Select-String -Path $envPath -Pattern '^\s*SKIP_AZURE_STORAGE=' -Quiet)) {
        Add-EnvLine -FilePath $envPath -Line "SKIP_AZURE_STORAGE=true"
        Write-Host "Added SKIP_AZURE_STORAGE=true for faster startup"
    }

    if (-not $NonInteractive) {
        Write-Host ""
        Write-Host "OpenAI API key is required for files and natural language search functionality."
        $addOpenAiKey = Read-Host "Would you like to add your OPENAI_API_KEY now? You can also do this later by editing the .env file manually. (y/n)"

        if ($addOpenAiKey -eq "y" -or $addOpenAiKey -eq "Y") {
            $openAiKey = Read-Host "Enter your OpenAI API key"
            Remove-EnvKey -FilePath $envPath -Key "OPENAI_API_KEY"
            Add-EnvQuotedValue -FilePath $envPath -Key "OPENAI_API_KEY" -Value $openAiKey
            Write-Host "OpenAI API key added to .env file."
        } else {
            Write-Host "You can add your OPENAI_API_KEY later by editing the .env file manually."
            Write-Host "Add the following line to your .env file:"
            Write-Host 'OPENAI_API_KEY="your-api-key-here"'
        }
    } else {
        Write-Host "NONINTERACTIVE=1: Skipping OPENAI_API_KEY prompt."
    }

    if (-not $NonInteractive) {
        Write-Host ""
        Write-Host "Mistral API key is required for certain AI functionality."
        $addMistralKey = Read-Host "Would you like to add your MISTRAL_API_KEY now? You can also do this later by editing the .env file manually. (y/n)"

        if ($addMistralKey -eq "y" -or $addMistralKey -eq "Y") {
            $mistralKey = Read-Host "Enter your Mistral API key"
            Remove-EnvKey -FilePath $envPath -Key "MISTRAL_API_KEY"
            Add-EnvQuotedValue -FilePath $envPath -Key "MISTRAL_API_KEY" -Value $mistralKey
            Write-Host "Mistral API key added to .env file."
        } else {
            Write-Host "You can add your MISTRAL_API_KEY later by editing the .env file manually."
            Write-Host "Add the following line to your .env file:"
            Write-Host 'MISTRAL_API_KEY="your-api-key-here"'
        }
    } else {
        Write-Host "NONINTERACTIVE=1: Skipping MISTRAL_API_KEY prompt."
    }

    $composeCmdParts = @()
    $composeCmdDisplay = ""

    if (Test-CommandSuccess -CommandParts @("docker", "compose") -Arguments @("version")) {
        $composeCmdParts = @("docker", "compose")
        $composeCmdDisplay = "docker compose"
    } elseif (Have-Cmd -Command "docker-compose") {
        $composeCmdParts = @("docker-compose")
        $composeCmdDisplay = "docker-compose"
    } elseif (Have-Cmd -Command "podman-compose") {
        $composeCmdParts = @("podman-compose")
        $composeCmdDisplay = "podman-compose"
    } else {
        Write-Error "Neither 'docker compose', 'docker-compose', nor 'podman-compose' found. Please install Docker Compose."
        exit 1
    }

    $containerCmdParts = @()
    $containerCmdDisplay = ""

    if (Test-CommandSuccess -CommandParts @("docker") -Arguments @("info")) {
        $containerCmdParts = @("docker")
        $containerCmdDisplay = "docker"
    } elseif (Have-Cmd -Command "podman" -and Test-CommandSuccess -CommandParts @("podman") -Arguments @("info")) {
        $containerCmdParts = @("podman")
        $containerCmdDisplay = "podman"
    } else {
        Write-Error "Error: Docker daemon is not running. Please start Docker and try again."
        exit 1
    }

    Write-Host "Using commands: $containerCmdDisplay and $composeCmdDisplay"

    $existingContainersResult = Run-Command -CommandParts $containerCmdParts -Arguments @("ps", "-a", "--filter", "name=airweave", "--format", "{{.Names}}") -CaptureOutput
    $existingContainers = @()
    if ($existingContainersResult.ExitCode -eq 0 -and $existingContainersResult.Output) {
        $existingContainers = $existingContainersResult.Output | Where-Object { $_ -and $_.Trim().Length -gt 0 }
    }

    if ($existingContainers.Count -gt 0) {
        $containerList = ($existingContainers -join ' ')
        Write-Host "Found existing airweave containers: $containerList"

        if (-not $NonInteractive) {
            $removeContainers = Read-Host "Would you like to remove them before starting? (y/n)"
            if ($removeContainers -eq "y" -or $removeContainers -eq "Y") {
                Write-Host "Removing existing containers..."
                [void](Run-Command -CommandParts $containerCmdParts -Arguments (@("rm", "-f") + $existingContainers))
                Write-Host "Removing database volume..."
                try {
                    [void](Run-Command -CommandParts $containerCmdParts -Arguments @("volume", "rm", "airweave_postgres_data"))
                } catch { }
                Write-Host "Containers and volumes removed."
            } else {
                Write-Host "Warning: Starting with existing containers may cause conflicts."
            }
        } else {
            Write-Host "NONINTERACTIVE=1: Removing existing containers and volume..."
            [void](Run-Command -CommandParts $containerCmdParts -Arguments (@("rm", "-f") + $existingContainers))
            try {
                [void](Run-Command -CommandParts $containerCmdParts -Arguments @("volume", "rm", "airweave_postgres_data"))
            } catch { }
        }
    }

    Write-Host ""

    if ($env:BACKEND_IMAGE -or $env:FRONTEND_IMAGE) {
        $backendImage = if ($env:BACKEND_IMAGE) { $env:BACKEND_IMAGE } else { "ghcr.io/airweave-ai/airweave-backend:latest" }
        $frontendImage = if ($env:FRONTEND_IMAGE) { $env:FRONTEND_IMAGE } else { "ghcr.io/airweave-ai/airweave-frontend:latest" }
        Write-Host "Using custom Docker images:"
        Write-Host ("  Backend:  {0}" -f $backendImage)
        Write-Host ("  Frontend: {0}" -f $frontendImage)
        Write-Host ""
    }

    $useLocalEmbeddings = $true
    $useFrontend = $true

    $openAiValue = Get-EnvValue -FilePath $envPath -Key "OPENAI_API_KEY"
    if ($openAiValue -and $openAiValue -ne "your-api-key-here") {
        Write-Host "OpenAI API key detected - skipping local embeddings service (~2GB)"
        $useLocalEmbeddings = $false
    }

    if ($SkipLocalEmbeddings) {
        Write-Host "SKIP_LOCAL_EMBEDDINGS is set - skipping local embeddings service"
        $useLocalEmbeddings = $false
    }

    if ($SkipFrontend) {
        Write-Host "SKIP_FRONTEND is set - skipping frontend service"
        $useFrontend = $false
    }

    $composeArgs = @("-f", "docker/docker-compose.yml")
    if ($useLocalEmbeddings) {
        Write-Host "Starting with local embeddings service (text2vec-transformers)"
        $composeArgs += @("--profile", "local-embeddings")
    } else {
        Write-Host "Starting without local embeddings (backend will use OpenAI)"
    }

    if ($useFrontend) {
        Write-Host "Starting with frontend UI"
        $composeArgs += @("--profile", "frontend")
    } else {
        Write-Host "Starting without frontend (backend-only mode)"
    }

    Write-Host "Starting Docker services..."
    $composeUpExitCode = Run-Command -CommandParts $composeCmdParts -Arguments ($composeArgs + @("up", "-d"))
    if ($composeUpExitCode -ne 0) {
        Write-Host "❌ Failed to start Docker services"
        Write-Host "Check the error messages above and try running:"
        Write-Host "  docker logs airweave-backend"
        Write-Host "  docker logs airweave-frontend"
        exit 1
    }

    Write-Host ""
    Write-Host "Waiting for services to initialize..."
    Start-Sleep -Seconds 10

    Write-Host "Checking backend health..."
    $maxRetries = 30
    $backendHealthy = $false
    for ($retry = 0; $retry -lt $maxRetries; $retry++) {
        $healthResult = Run-Command -CommandParts $containerCmdParts -Arguments @("exec", "airweave-backend", "curl", "-f", "http://localhost:8001/health") -CaptureOutput

        if ($healthResult.ExitCode -eq 0) {
            Write-Host "✅ Backend is healthy!"
            $backendHealthy = $true
            break
        }

        Write-Host ("⏳ Backend is still starting... (attempt {0}/{1})" -f ($retry + 1), $maxRetries)
        Start-Sleep -Seconds 5
    }

    if (-not $backendHealthy) {
        Write-Host "❌ Backend failed to start after $maxRetries attempts"
        Write-Host "Check backend logs with: docker logs airweave-backend"
        Write-Host "Common issues:"
        Write-Host "  - Database connection problems"
        Write-Host "  - Missing environment variables"
        Write-Host "  - Platform sync errors"
    }

    if ($useFrontend) {
        $frontendInspect = Run-Command -CommandParts $containerCmdParts -Arguments @("inspect", "airweave-frontend", "--format", "{{.State.Status}}") -CaptureOutput
        if ($frontendInspect.ExitCode -eq 0 -and $frontendInspect.Output) {
            $frontendStatus = ($frontendInspect.Output | Select-Object -Last 1).Trim()
            if ($frontendStatus -eq "created" -or $frontendStatus -eq "exited") {
                Write-Host "Starting frontend container..."
                [void](Run-Command -CommandParts $containerCmdParts -Arguments @("start", "airweave-frontend"))
                Start-Sleep -Seconds 5
            }
        }
    }

    Write-Host ""
    Write-Host "🚀 Airweave Status:"
    Write-Host "=================="

    $servicesHealthy = $true

    $backendStatus = Run-Command -CommandParts $containerCmdParts -Arguments @("exec", "airweave-backend", "curl", "-f", "http://localhost:8001/health") -CaptureOutput
    if ($backendStatus.ExitCode -eq 0) {
        Write-Host "✅ Backend API:    http://localhost:8001"
    } else {
        Write-Host "❌ Backend API:    Not responding (check logs with: docker logs airweave-backend)"
        $servicesHealthy = $false
    }

    if ($useFrontend) {
        $frontendStatusCheck = Run-Command -CommandParts @("curl") -Arguments @("-f", "http://localhost:8080") -CaptureOutput
        if ($frontendStatusCheck.ExitCode -eq 0) {
            Write-Host "✅ Frontend UI:    http://localhost:8080"
        } else {
            Write-Host "❌ Frontend UI:    Not responding (check logs with: docker logs airweave-frontend)"
            $servicesHealthy = $false
        }
    } else {
        Write-Host "⏭️  Frontend UI:    Skipped (backend-only mode)"
    }

    Write-Host ""
    Write-Host "Other services:"
    Write-Host "📊 Temporal UI:    http://localhost:8088"
    Write-Host "🗄️  PostgreSQL:    localhost:5432"
    Write-Host "🔍 Qdrant:        http://localhost:6333"

    if ($useLocalEmbeddings) {
        Write-Host "🤖 Embeddings:    http://localhost:9878 (local text2vec)"
    } else {
        Write-Host "🤖 Embeddings:    OpenAI API"
    }

    Write-Host ""
    Write-Host "To view logs: docker logs <container-name>"
    Write-Host "To stop all services: docker compose -f docker/docker-compose.yml down"
    Write-Host ""

    if ($servicesHealthy) {
        Write-Host "🎉 All services started successfully!"
    } else {
        Write-Host "⚠️  Some services failed to start properly. Check the logs above for details."
        exit 1
    }
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
