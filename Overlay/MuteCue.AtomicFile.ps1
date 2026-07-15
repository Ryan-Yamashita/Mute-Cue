function Write-MuteCueAtomicText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Alias("Text")][AllowEmptyString()][string]$Content,
        [string]$BackupPath = "",
        [ValidateRange(1, 20)][int]$MaximumAttempts = 10
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($resolvedPath)
    if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
    $operationId = [Guid]::NewGuid().ToString("N")
    $temporaryPath = "{0}.{1}.{2}.tmp" -f $resolvedPath, $PID, $operationId
    $ephemeralBackupPath = "{0}.{1}.{2}.bak" -f $resolvedPath, $PID, $operationId
    $resolvedBackupPath = if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $ephemeralBackupPath
    } else {
        [IO.Path]::GetFullPath($BackupPath)
    }
    $encoding = New-Object Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($Content)
    $stream = New-Object IO.FileStream(
        $temporaryPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    $lastError = $null
    try {
        for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
            try {
                if ([IO.File]::Exists($resolvedPath)) {
                    [IO.File]::Replace($temporaryPath, $resolvedPath, $resolvedBackupPath, $true)
                    if ($resolvedBackupPath -eq $ephemeralBackupPath -and [IO.File]::Exists($ephemeralBackupPath)) {
                        [IO.File]::Delete($ephemeralBackupPath)
                    }
                } else {
                    [IO.File]::Move($temporaryPath, $resolvedPath)
                }
                return
            } catch [IO.IOException] {
                $lastError = $_.Exception
            } catch [UnauthorizedAccessException] {
                $lastError = $_.Exception
            }
            if ($attempt -lt $MaximumAttempts) {
                $delayMilliseconds = [Math]::Min(100, 5 * [Math]::Pow(2, [Math]::Min(5, $attempt - 1)))
                Start-Sleep -Milliseconds ([int]$delayMilliseconds)
            }
        }
        throw $lastError
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
        if ([IO.File]::Exists($ephemeralBackupPath)) { Remove-Item -LiteralPath $ephemeralBackupPath -Force -ErrorAction SilentlyContinue }
    }
}

function Read-MuteCueSharedText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 16777216)][int]$MaximumBytes = 2MB,
        [ValidateRange(1, 10)][int]$MaximumAttempts = 5
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $stream = $null
        try {
            $stream = [IO.FileStream]::new(
                $resolvedPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                $share,
                4096,
                [IO.FileOptions]::SequentialScan
            )
            if ($stream.Length -le 0 -or $stream.Length -gt $MaximumBytes) { throw "The shared file has an invalid size." }
            $reader = [IO.StreamReader]::new($stream, (New-Object Text.UTF8Encoding($false, $true)), $true, 4096, $true)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        } catch [IO.FileNotFoundException] {
            $lastError = $_.Exception
        } catch [IO.IOException] {
            $lastError = $_.Exception
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
        if ($attempt -lt $MaximumAttempts) { Start-Sleep -Milliseconds 2 }
    }
    throw $lastError
}
