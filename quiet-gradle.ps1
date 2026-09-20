<#
quiet-gradle.ps1 - run this project's gradlew.bat with bounded console output.

Full Gradle output always goes to a project-local log. The console gets one
RUN line, then one PASS line, or a bounded failure excerpt plus the log path.

Usage:  .\quiet-gradle.ps1 [wrapper options] <gradle tasks and arguments>

Wrapper options (only recognised BEFORE the first Gradle argument, exact names):
  -Full                 stream Gradle output to the console (log is still saved)
  -ShowWarnings         on success, print a bounded, deduplicated warning list
  -TailLines N          trailing log lines kept in a failure excerpt (80)
  -MaxSummaryLines N    hard cap on log lines printed after a failure (200)
  -LogDirectory PATH    log directory (default .agent-logs\gradle, relative to script)
  -KeepLogs N           keep newest N wrapper logs, prune older; 0 = never prune (20)

Exit codes: Gradle's own code for Gradle outcomes.
            64 = usage/invocation error, 70 = wrapper error (no gradlew.bat,
            cannot write log, Gradle cannot start).

There is deliberately no param() block: PowerShell would accept abbreviations
such as -s, -t, -m, -f and steal Gradle's short flags.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ExitUsage    = 64
$ExitInternal = 70
$MaxLineChars = 400
$PipeGraceMs  = 5000

$out = [Console]::Out
function Say([string]$text) { $out.WriteLine($text) }

# ---- wrapper option parsing (leading options only) ------------------------
$Full = $false; $ShowWarnings = $false
$TailLines = 80; $MaxSummaryLines = 200; $KeepLogs = 20
$LogDirectory = Join-Path $PSScriptRoot '.agent-logs\gradle'

function Read-IntOption([string]$name, $value) {
    $n = 0
    if ($null -eq $value -or -not [int]::TryParse([string]$value, [ref]$n) -or $n -lt 0) {
        Say "QG ERROR $name needs a non-negative integer."
        exit $ExitUsage
    }
    return $n
}

$rest = @($args)
$i = 0
:opts while ($i -lt $rest.Count) {
    switch -exact ([string]$rest[$i]) {
        '-Full'            { $Full = $true; $i++ }
        '-ShowWarnings'    { $ShowWarnings = $true; $i++ }
        '-TailLines'       { $i++; $v = if ($i -lt $rest.Count) { $rest[$i] } else { $null }; $TailLines = Read-IntOption '-TailLines' $v; $i++ }
        '-MaxSummaryLines' { $i++; $v = if ($i -lt $rest.Count) { $rest[$i] } else { $null }; $MaxSummaryLines = Read-IntOption '-MaxSummaryLines' $v; $i++ }
        '-KeepLogs'        { $i++; $v = if ($i -lt $rest.Count) { $rest[$i] } else { $null }; $KeepLogs = Read-IntOption '-KeepLogs' $v; $i++ }
        '-LogDirectory'    {
            $i++
            if ($i -ge $rest.Count) { Say 'QG ERROR -LogDirectory needs a path.'; exit $ExitUsage }
            $LogDirectory = [string]$rest[$i]; $i++
        }
        default { break opts }
    }
}
$gradleArgs = New-Object 'System.Collections.Generic.List[string]'
for (; $i -lt $rest.Count; $i++) { $gradleArgs.Add([string]$rest[$i]) }

if ($gradleArgs.Count -eq 0) {
    Say 'QG USAGE  .\quiet-gradle.ps1 [-Full] [-ShowWarnings] [-TailLines N] [-MaxSummaryLines N]'
    Say '                             [-LogDirectory PATH] [-KeepLogs N] <gradle tasks and arguments>'
    exit $ExitUsage
}

# ---- locate gradlew.bat (beside this script only) --------------------------
$root   = [IO.Path]::GetFullPath($PSScriptRoot)
$gradle = Join-Path $root 'gradlew.bat'
if (-not (Test-Path -LiteralPath $gradle -PathType Leaf)) {
    Say "QG ERROR gradlew.bat not found beside the script: $gradle"
    exit $ExitInternal
}

if (-not ($gradleArgs | Where-Object { $_ -match '^--console(=|$)' })) {
    $gradleArgs.Insert(0, '--console=plain')
}
$label = ($gradleArgs | Where-Object { $_ -notmatch '^--console(=|$)' }) -join ' '
if ($label.Length -gt 100) { $label = $label.Substring(0, 97) + '...' }

# ---- create the unique log (fatal if it cannot be written) ------------------
$utf8 = New-Object System.Text.UTF8Encoding($false)
$logDir = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $LogDirectory))
$logPath = $null
$writer = $null
try {
    [void][IO.Directory]::CreateDirectory($logDir)
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss.fff', [Globalization.CultureInfo]::InvariantCulture)
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $logPath = Join-Path $logDir ("$stamp-p$PID-$suffix.log")
    $stream = New-Object IO.FileStream($logPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $writer = New-Object IO.StreamWriter($stream, $utf8)
    $writer.AutoFlush = $true
} catch {
    Say "QG ERROR cannot create log in '$logDir': $($_.Exception.Message)"
    exit $ExitInternal
}
$logShown = if ($logPath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { $logPath.Substring($root.Length + 1) } else { $logPath }

Say "QG RUN  $label  log=$logShown"

# ---- run gradlew.bat, capture stdout+stderr in arrival order ---------------
function ConvertTo-QuotedArg([string]$s) {
    if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { return $s }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($c in $s.ToCharArray()) {
        if ($c -eq '\') { $bs++ }
        elseif ($c -eq '"') { [void]$sb.Append('\', $bs * 2 + 1); [void]$sb.Append('"'); $bs = 0 }
        else { if ($bs) { [void]$sb.Append('\', $bs); $bs = 0 }; [void]$sb.Append($c) }
    }
    if ($bs) { [void]$sb.Append('\', $bs * 2) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $gradle
$psi.Arguments = ($gradleArgs | ForEach-Object { ConvertTo-QuotedArg $_ }) -join ' '
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = $utf8
$psi.StandardErrorEncoding = $utf8

# Gradle may spawn a long-lived daemon that would inherit OUR stdout/stderr handles and keep
# the caller's pipe open (a caller reading our output would hang until the daemon exits).
# PowerShell also duplicates its std handles as extra inheritable handles, so clear the
# inherit flag on every pipe and disk-file handle we hold; the child gets its own pipes.
try {
    Add-Type -Namespace QuietGradle -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetHandleInformation(IntPtr h, out uint flags);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
[DllImport("kernel32.dll")] public static extern uint GetFileType(IntPtr h);
public static void ClearInheritOnPipesAndFiles() {
    for (long v = 4; v < 65536; v += 4) {
        IntPtr h = new IntPtr(v); uint flags;
        if (!GetHandleInformation(h, out flags) || (flags & 1) == 0) continue;
        uint t = GetFileType(h);
        if (t == 1 || t == 3) SetHandleInformation(h, 1, 0);   // 1 = disk file, 3 = pipe
    }
}
'@
    [QuietGradle.Native]::ClearInheritOnPipesAndFiles()
} catch { }

$clock = [Diagnostics.Stopwatch]::StartNew()
$proc = $null
$finished = $false
$exitCode = $ExitInternal
$lineCount = 0

try {
    try {
        $proc = [Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Close()
    } catch {
        $writer.WriteLine("QG: could not start gradlew.bat: $($_.Exception.Message)")
        $writer.Dispose(); $writer = $null
        Say "QG ERROR could not start gradlew.bat: $($_.Exception.Message)"
        Say "Full log: $logPath"
        $finished = $true
        exit $ExitInternal
    }

    $readers = @($proc.StandardOutput, $proc.StandardError)
    $tasks = @($readers[0].ReadLineAsync(), $readers[1].ReadLineAsync())
    $quietSince = $null   # ms timestamp of last activity once the process has exited

    while ($null -ne $tasks[0] -or $null -ne $tasks[1]) {
        $active = 0
        for ($k = 0; $k -lt 2; $k++) {
            while ($null -ne $tasks[$k] -and $tasks[$k].IsCompleted) {
                $line = $null
                try { $line = $tasks[$k].Result } catch { $line = $null }
                if ($null -eq $line) { $tasks[$k] = $null; break }
                $writer.WriteLine($line)
                if ($Full) { $out.WriteLine($line) }
                $lineCount++; $active++
                $tasks[$k] = $readers[$k].ReadLineAsync()
            }
        }
        if ($null -eq $tasks[0] -and $null -eq $tasks[1]) { break }
        if ($active -gt 0) { $quietSince = $null; continue }

        $pending = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
        foreach ($t in $tasks) { if ($null -ne $t) { $pending.Add($t) } }
        [void][System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), 200)

        # A lingering child (e.g. a daemon) can hold the pipes open after gradlew exits.
        if ($proc.HasExited) {
            if ($null -eq $quietSince) { $quietSince = $clock.ElapsedMilliseconds }
            elseif ($clock.ElapsedMilliseconds - $quietSince -gt $PipeGraceMs) {
                $writer.WriteLine('QG: output pipe still open 5s after gradlew exited; stopped reading.')
                break
            }
        }
    }

    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    $finished = $true
} finally {
    if (-not $finished) {
        # Ctrl+C or another abort: never report success.
        try { if ($null -ne $proc -and -not $proc.HasExited) { $proc.Kill() } } catch { }
        Say "QG FAIL $label  interrupted  duration=$($clock.Elapsed.TotalSeconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))s"
        Say "Full log: $logPath"
    }
    if ($null -ne $writer) { $writer.Dispose() }
}

$clock.Stop()
$duration = $clock.Elapsed.TotalSeconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + 's'

# ---- summaries -------------------------------------------------------------
function Format-LogLine([string]$s) {
    if ($s.Length -gt $MaxLineChars) { return $s.Substring(0, $MaxLineChars) + ' ...[truncated]' }
    return $s
}

function Get-TailOnly([string[]]$lines) {
    $n = [Math]::Min([Math]::Min($TailLines, $MaxSummaryLines), $lines.Count)
    for ($j = $lines.Count - $n; $j -lt $lines.Count; $j++) { Format-LogLine $lines[$j] }
}

# pattern -> (lines before, lines after) context
$failRules = @(
    @{ Rx = 'What went wrong:';                  Before = 0; After = 6 },
    @{ Rx = 'FAILURE:';                          Before = 0; After = 2 },
    @{ Rx = '\bFAILED\b';                        Before = 1; After = 3 },
    @{ Rx = 'Execution failed for task';         Before = 0; After = 3 },
    @{ Rx = 'Caused by:';                        Before = 0; After = 1 },
    @{ Rx = '^e: ';                              Before = 0; After = 1 },
    @{ Rx = 'error:';                            Before = 0; After = 3 },
    @{ Rx = 'There were failing tests';          Before = 1; After = 2 },
    @{ Rx = 'See the report at';                 Before = 1; After = 1 },
    @{ Rx = 'Could not (resolve|find|get)';      Before = 0; After = 4 }
)
$opts = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Compiled
$anyPattern = ($failRules | ForEach-Object { '(?:' + $_.Rx + ')' }) -join '|'
$anyFail = New-Object Text.RegularExpressions.Regex($anyPattern, $opts)
$ruleRx = @($failRules | ForEach-Object { New-Object Text.RegularExpressions.Regex($_.Rx, $opts) })

function Write-FailureSummary([string]$path) {
    $lines = [IO.File]::ReadAllLines($path, $utf8)
    $n = $lines.Length
    $cap = $MaxSummaryLines
    $keep = New-Object 'bool[]' ([Math]::Max($n, 1))
    $used = 0
    $tailN = [Math]::Min([Math]::Min($TailLines, $cap), $n)
    for ($j = $n - $tailN; $j -lt $n; $j++) { $keep[$j] = $true; $used++ }

    $matched = $false
    $omitted = 0
    for ($j = 0; $j -lt $n; $j++) {
        if (-not $anyFail.IsMatch($lines[$j])) { continue }
        $matched = $true
        for ($r = 0; $r -lt $failRules.Count; $r++) {
            if (-not $ruleRx[$r].IsMatch($lines[$j])) { continue }
            $from = [Math]::Max(0, $j - $failRules[$r].Before)
            $to   = [Math]::Min($n - 1, $j + $failRules[$r].After)
            for ($q = $from; $q -le $to; $q++) {
                if ($keep[$q]) { continue }
                if ($used -ge $cap) { $omitted++; continue }
                $keep[$q] = $true; $used++
            }
        }
    }

    if ($matched) { Say '--- relevant Gradle output (bounded) ---' }
    else { Say '--- no specific diagnostic block detected; showing log tail ---' }
    $gap = $false
    for ($j = 0; $j -lt $n; $j++) {
        if ($keep[$j]) {
            if ($gap) { Say '...'; $gap = $false }
            Say (Format-LogLine $lines[$j])
        } elseif ($j -gt 0 -and $keep[$j - 1]) { $gap = $true }
    }
    if ($omitted -gt 0) { Say "($omitted more matching lines omitted by -MaxSummaryLines; see full log)" }
    Say '--- end relevant output ---'
}

function Write-WarningSummary([string]$path) {
    $rx = New-Object Text.RegularExpressions.Regex('^w: |warning:|^WARNING\b', $opts)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $ordered = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in [IO.File]::ReadAllLines($path, $utf8)) {
        if ($rx.IsMatch($l) -and $seen.Add($l)) { $ordered.Add($l) }
    }
    if ($ordered.Count -eq 0) { return }
    $shown = [Math]::Min($ordered.Count, $MaxSummaryLines)
    Say "--- warnings ($($ordered.Count) unique, showing $shown) ---"
    for ($j = 0; $j -lt $shown; $j++) { Say (Format-LogLine $ordered[$j]) }
    Say '--- end warnings ---'
}

if ($exitCode -eq 0) {
    if ($ShowWarnings -and -not $Full) {
        try { Write-WarningSummary $logPath } catch { Say "QG WARN could not summarise warnings: $($_.Exception.Message)" }
    }
    Say "QG PASS $label  exit=0  duration=$duration  log=$logShown"
} else {
    Say "QG FAIL $label  exit=$exitCode  duration=$duration"
    if (-not $Full) {
        try { Write-FailureSummary $logPath }
        catch {
            Say "QG WARN summary failed ($($_.Exception.Message)); raw tail follows."
            try { [IO.File]::ReadAllLines($logPath, $utf8) | Select-Object -Last ([Math]::Min($TailLines, $MaxSummaryLines)) | ForEach-Object { Say (Format-LogLine $_) } } catch { }
        }
    }
    Say "Full log: $logPath"
}

# ---- prune old wrapper logs (never affects the result) ---------------------
if ($KeepLogs -gt 0) {
    try {
        $rxName = '^\d{8}-\d{6}\.\d{3}-p\d+-[0-9a-f]{8}\.log$'
        $mine = [IO.Directory]::GetFiles($logDir, '*.log') |
            Where-Object { [IO.Path]::GetFileName($_) -match $rxName -and $_ -ne $logPath } |
            Sort-Object { [IO.Path]::GetFileName($_) } -Descending
        $mine = @($mine)
        $extra = $mine.Count - ($KeepLogs - 1)
        if ($extra -gt 0) {
            foreach ($old in $mine[($KeepLogs - 1)..($mine.Count - 1)]) { [IO.File]::Delete($old) }
        }
    } catch {
        Say "QG WARN could not prune old logs: $($_.Exception.Message)"
    }
}

exit $exitCode
