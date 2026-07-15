$script:MuteCueDiagnosticState = [pscustomobject]@{
    Path = $null
    ArchivePath = $null
    MaximumBytes = 2MB
    Gate = New-Object object
    ThrottleGate = New-Object object
    LastWrites = @{}
}

function Write-MuteCueDiagnosticThrottled {
    param(
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet("Info", "Warning", "Error")][string]$Level = "Error",
        [string]$Component = "Runtime",
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][System.Exception]$Exception,
        [double]$MinimumIntervalSeconds = 10
    )

    $now = [DateTime]::UtcNow
    $shouldWrite = $false
    [System.Threading.Monitor]::Enter($script:MuteCueDiagnosticState.ThrottleGate)
    try {
        if (
            -not $script:MuteCueDiagnosticState.LastWrites.ContainsKey($Key) -or
            ($now - [DateTime]$script:MuteCueDiagnosticState.LastWrites[$Key]).TotalSeconds -ge $MinimumIntervalSeconds
        ) {
            $script:MuteCueDiagnosticState.LastWrites[$Key] = $now
            $shouldWrite = $true
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:MuteCueDiagnosticState.ThrottleGate)
    }
    if ($shouldWrite) {
        Write-MuteCueDiagnostic -Level $Level -Component $Component -Message $Message -Exception $Exception
    }
}

function Initialize-MuteCueDiagnostics {
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MaximumBytes = 2MB
    )

    $script:MuteCueDiagnosticState.Path = [System.IO.Path]::GetFullPath($Path)
    $script:MuteCueDiagnosticState.ArchivePath = $script:MuteCueDiagnosticState.Path + ".1"
    $script:MuteCueDiagnosticState.MaximumBytes = [Math]::Max(64KB, $MaximumBytes)
}

function ConvertTo-MuteCueSafeDiagnosticText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return "" }
    $text = ([string]$Value).Replace("`r", " ").Replace("`n", " ").Trim()
    $text = [regex]::Replace(
        $text,
        '(?i)(access[_ -]?token|refresh[_ -]?token|client[_ -]?secret|authorization)\s*[:=]\s*[^\s;,]+',
        '$1=[redacted]'
    )
    if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) + "..." }
    return $text
}

function Write-MuteCueDiagnostic {
    param(
        [ValidateSet("Info", "Warning", "Error")][string]$Level = "Error",
        [string]$Component = "Runtime",
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][System.Exception]$Exception
    )

    $path = [string]$script:MuteCueDiagnosticState.Path
    if ([string]::IsNullOrWhiteSpace($path)) { return }

    $safeMessage = ConvertTo-MuteCueSafeDiagnosticText -Value $Message
    $exceptionText = ""
    if ($null -ne $Exception) {
        $exceptionText = " | {0}: {1}" -f `
            (ConvertTo-MuteCueSafeDiagnosticText -Value $Exception.GetType().FullName), `
            (ConvertTo-MuteCueSafeDiagnosticText -Value $Exception.Message)
    }
    $line = "{0:yyyy-MM-ddTHH:mm:ss.fffK} [{1}] [{2}] {3}{4}{5}" -f `
        [DateTimeOffset]::Now,
        $Level.ToUpperInvariant(),
        (ConvertTo-MuteCueSafeDiagnosticText -Value $Component),
        $safeMessage,
        $exceptionText,
        [Environment]::NewLine

    [System.Threading.Monitor]::Enter($script:MuteCueDiagnosticState.Gate)
    try {
        $directory = [System.IO.Path]::GetDirectoryName($path)
        if (-not [System.IO.Directory]::Exists($directory)) {
            [void][System.IO.Directory]::CreateDirectory($directory)
        }
        if (
            [System.IO.File]::Exists($path) -and
            (New-Object System.IO.FileInfo($path)).Length -ge $script:MuteCueDiagnosticState.MaximumBytes
        ) {
            if ([System.IO.File]::Exists($script:MuteCueDiagnosticState.ArchivePath)) {
                [System.IO.File]::Delete($script:MuteCueDiagnosticState.ArchivePath)
            }
            [System.IO.File]::Move($path, $script:MuteCueDiagnosticState.ArchivePath)
        }
        [System.IO.File]::AppendAllText($path, $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # Diagnostics must never destabilize the overlay.
    } finally {
        [System.Threading.Monitor]::Exit($script:MuteCueDiagnosticState.Gate)
    }
}
