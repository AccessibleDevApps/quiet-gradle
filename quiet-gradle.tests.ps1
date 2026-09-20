<#
Tests for quiet-gradle.ps1 using a mock gradlew.bat. No real Gradle, no network.
Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\quiet-gradle.tests.ps1
Fixtures live under .agent-logs\tests (git-ignored) and are removed afterwards.
Not automated: Ctrl+C interruption (check by hand with a slow scenario).
#>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$fixtures = Join-Path $here '.agent-logs\tests'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name) {
    if ($ok) { $script:pass++; Write-Host "  ok   $name" }
    else { $script:fail++; Write-Host "  FAIL $name" }
}

$mockPs1 = @'
$s = $env:MOCK_SCENARIO
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$rec = Join-Path $PSScriptRoot 'record.txt'
$lines = @("cwd=$((Get-Location).Path)")
$lines += ($args | ForEach-Object { "arg=[$_]" })
[IO.File]::WriteAllLines($rec, [string[]]$lines)
switch ($s) {
  'pass'   { 1..200 | ForEach-Object { "> Task :app:task$_ UP-TO-DATE" }; 'BUILD SUCCESSFUL in 3s'; exit 0 }
  'warn'   { 'w: file:///a/A.kt:1:1 Deprecated thing'; 'w: file:///a/A.kt:1:1 Deprecated thing'; 'A.java:3: warning: [deprecation] x'; '> Task :app:ok'; exit 0 }
  'kotlin' { '> Task :app:compileDebugKotlin FAILED'; 'e: file:///C:/x/Main.kt:42:5 Unresolved reference: value'; 'FAILURE: Build failed with an exception.'; '* What went wrong:'; 'Execution failed for task '':app:compileDebugKotlin''.'; 'BUILD FAILED in 2s'; exit 1 }
  'java'   { '> Task :app:compileDebugJavaWithJavac FAILED'; 'C:\x\Foo.java:12: error: cannot find symbol'; '  symbol: variable bar'; 'BUILD FAILED in 2s'; exit 1 }
  'test'   { 'com.example.SomeTest > testFoo FAILED'; '    java.lang.AssertionError at SomeTest.kt:9'; 'There were failing tests. See the report at: file:///C:/x/build/reports/tests/index.html'; 'BUILD FAILED in 2s'; exit 1 }
  'dep'    { '* What went wrong:'; 'Could not resolve all files for configuration'; '> Could not resolve com.example:lib:1.0.'; '   > Could not find com.example:lib:1.0.'; 'BUILD FAILED in 2s'; exit 1 }
  'generic'{ 'something odd happened'; 'and then it stopped'; exit 3 }
  'large'  { 1..30000 | ForEach-Object { "> Task :app:noise$_" }; 'e: file:///C:/x/Big.kt:7:1 Mid-log error'; 30001..60000 | ForEach-Object { "> Task :app:more$_" }; 'BUILD FAILED in 9s'; exit 1 }
  'unicode'{ 'h' + [char]0xE9 + 'llo ' + [char]0x2713 + ' ' + [char]0x65E5 + [char]0x672C; exit 0 }
  'mixed'  { 'out1'; [Console]::Error.WriteLine('err1'); 'out2'; exit 0 }
  'slow'   { Start-Sleep -Milliseconds 1500; 'slow done'; exit 0 }
  'exit7'  { 'nope'; exit 7 }
  'daemon' {
    # Lingering child like a Gradle daemon: own redirected std pipes, so it only keeps
    # other inheritable handles (e.g. the wrapper's stdout) alive.
    $ps = New-Object Diagnostics.ProcessStartInfo
    $ps.FileName = 'ping.exe'; $ps.Arguments = '-n 26 127.0.0.1'; $ps.WorkingDirectory = $env:SystemRoot
    $ps.UseShellExecute = $false; $ps.CreateNoWindow = $true
    $ps.RedirectStandardInput = $true; $ps.RedirectStandardOutput = $true; $ps.RedirectStandardError = $true
    [void][Diagnostics.Process]::Start($ps)
    'BUILD SUCCESSFUL'; exit 0
  }
  default  { 'no scenario'; exit 0 }
}
'@

function New-Fixture([string]$name, [bool]$withGradle = $true) {
    $dir = Join-Path $fixtures "$name with spaces"
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    [void](New-Item -ItemType Directory -Force $dir)
    Copy-Item (Join-Path $here 'quiet-gradle.ps1') $dir
    if ($withGradle) {
        [IO.File]::WriteAllText((Join-Path $dir 'mock.ps1'), $mockPs1, $utf8)
        [IO.File]::WriteAllText((Join-Path $dir 'gradlew.bat'),
            "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0mock.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n")
    }
    return $dir
}

function Invoke-QG([string]$dir, [string]$scenario, [string[]]$qgArgs) {
    $env:MOCK_SCENARIO = $scenario
    try {
        $text = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'quiet-gradle.ps1') @qgArgs | Out-String
        $code = $LASTEXITCODE
    } finally { Remove-Item Env:\MOCK_SCENARIO -ErrorAction SilentlyContinue }
    $logs = @()
    $ld = Join-Path $dir '.agent-logs\gradle'
    if (Test-Path $ld) { $logs = @(Get-ChildItem $ld -Filter *.log | Sort-Object Name) }
    $logText = if ($logs.Count) { [IO.File]::ReadAllText($logs[-1].FullName, $utf8) } else { '' }
    [pscustomobject]@{ Out = $text; Lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' }); Code = $code; Logs = $logs; Log = $logText }
}

# Run each test with a fresh fixture, from a different working directory.
Push-Location $env:SystemRoot
try {
    Write-Host 'success, noisy'
    $d = New-Fixture 'pass'; $r = Invoke-QG $d 'pass' @('assembleDebug')
    Check ($r.Code -eq 0) 'exit 0'
    Check ($r.Lines.Count -eq 2) 'only RUN and PASS lines'
    Check ($r.Out -match 'QG PASS assembleDebug\s+exit=0') 'PASS line'
    Check ($r.Out -notmatch 'UP-TO-DATE') 'no routine task output'
    Check ($r.Log -match 'Task :app:task200 UP-TO-DATE') 'log holds hidden output'

    Write-Host 'runs adjacent gradlew from another directory'
    $rec = Get-Content (Join-Path $d 'record.txt')
    Check ($rec[0] -eq "cwd=$d") 'working dir is project root'
    Check ($rec -contains 'arg=[--console=plain]') '--console=plain added'
    $r = Invoke-QG $d 'pass' @('--console=rich', 'assembleDebug')
    Check ((Get-Content (Join-Path $d 'record.txt')) -notcontains 'arg=[--console=plain]') 'caller console option respected'

    Write-Host 'warnings'
    $d = New-Fixture 'warn'; $r = Invoke-QG $d 'warn' @('assembleDebug')
    Check ($r.Out -notmatch 'Deprecated') 'hidden by default'
    $r = Invoke-QG $d 'warn' @('-ShowWarnings', 'assembleDebug')
    Check (([regex]::Matches($r.Out, 'Deprecated thing')).Count -eq 1) 'deduplicated'
    Check ($r.Out -match '\[deprecation\]') 'javac warning shown'
    Check ($r.Out -match 'QG PASS') 'PASS follows warnings'

    Write-Host 'failures'
    $d = New-Fixture 'kotlin'; $r = Invoke-QG $d 'kotlin' @('assembleDebug')
    Check ($r.Code -eq 1) 'exit 1 preserved'
    Check ($r.Out -match 'Main\.kt:42:5 Unresolved reference: value') 'kotlin error shown'
    Check ($r.Out -match [regex]::Escape($r.Logs[-1].FullName)) 'absolute log path printed'
    $d = New-Fixture 'java'; $r = Invoke-QG $d 'java' @('assembleDebug')
    Check ($r.Out -match 'Foo\.java:12: error: cannot find symbol') 'java error shown'
    $d = New-Fixture 'test'; $r = Invoke-QG $d 'test' @('testDebugUnitTest')
    Check ($r.Out -match 'SomeTest > testFoo FAILED' -and $r.Out -match 'reports/tests/index\.html') 'test failure and report path'
    $d = New-Fixture 'dep'; $r = Invoke-QG $d 'dep' @('assembleDebug')
    Check ($r.Out -match 'Could not resolve com\.example:lib' -and $r.Out -match 'Could not find') 'dependency failure block'
    $d = New-Fixture 'generic'; $r = Invoke-QG $d 'generic' @('assembleDebug')
    Check ($r.Code -eq 3) 'exit 3 preserved'
    Check ($r.Out -match 'no specific diagnostic block detected' -and $r.Out -match 'and then it stopped') 'bounded tail fallback'
    $d = New-Fixture 'exit7'; $r = Invoke-QG $d 'exit7' @('x')
    Check ($r.Code -eq 7) 'exit 7 preserved'

    Write-Host 'large output and limits'
    $d = New-Fixture 'large'
    $sw = [Diagnostics.Stopwatch]::StartNew(); $r = Invoke-QG $d 'large' @('assembleDebug'); $sw.Stop()
    Check ($r.Code -eq 1) 'exit 1'
    Check ($r.Lines.Count -le 215) "console bounded ($($r.Lines.Count) lines)"
    Check ($r.Out -match 'Big\.kt:7:1 Mid-log error') 'mid-log error found'
    Check (@($r.Log -split "`n").Count -gt 60000) 'log has everything'
    Write-Host ("       (60k-line run took {0:0.0}s)" -f $sw.Elapsed.TotalSeconds)
    $r = Invoke-QG $d 'large' @('-TailLines', '5', '-MaxSummaryLines', '10', 'assembleDebug')
    Check ($r.Lines.Count -le 20) "custom limits ($($r.Lines.Count) lines)"

    Write-Host 'arguments'
    $d = New-Fixture 'args'
    $r = Invoke-QG $d 'pass' @('testDebugUnitTest', '--tests', 'com.example.Some Test', '-Pfoo=bar baz', '-Dx.y=1', '-s', '-t', '-m', '-q', '-f')
    $rec = @(Get-Content (Join-Path $d 'record.txt'))
    Check ($rec -contains 'arg=[com.example.Some Test]') 'spaced test filter intact'
    Check ($rec -contains 'arg=[-Pfoo=bar baz]') 'spaced -P property intact'
    Check ($rec -contains 'arg=[-Dx.y=1]') '-D property intact'
    Check (($rec -contains 'arg=[-s]') -and ($rec -contains 'arg=[-t]') -and ($rec -contains 'arg=[-m]') -and ($rec -contains 'arg=[-f]')) 'short flags not stolen'

    Write-Host 'unicode and stream mixing'
    $d = New-Fixture 'uni'; $r = Invoke-QG $d 'unicode' @('x')
    Check ($r.Log -match ([string][char]0xE9 + 'llo ' + [char]0x2713 + ' ' + [char]0x65E5 + [char]0x672C)) 'unicode preserved in log'
    $d = New-Fixture 'mix'; $r = Invoke-QG $d 'mixed' @('x')
    Check (($r.Log -match 'out1') -and ($r.Log -match 'err1') -and ($r.Log -match 'out2')) 'stdout and stderr both logged'

    Write-Host '-Full'
    $d = New-Fixture 'full'; $r = Invoke-QG $d 'pass' @('-Full', 'assembleDebug')
    Check ($r.Out -match 'Task :app:task200 UP-TO-DATE') 'output streamed'
    $r = Invoke-QG $d 'kotlin' @('-Full', 'assembleDebug')
    Check ($r.Out -notmatch 'relevant Gradle output' -and $r.Out -match 'Full log:') 'no duplicate summary on failure'

    Write-Host 'parallel'
    $d = New-Fixture 'par'
    $env:MOCK_SCENARIO = 'slow'
    $p = 1..2 | ForEach-Object { Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $d 'quiet-gradle.ps1')`"", 'x' }
    Remove-Item Env:\MOCK_SCENARIO
    $p | Wait-Process
    $logs = @(Get-ChildItem (Join-Path $d '.agent-logs\gradle') -Filter *.log)
    Check ($logs.Count -eq 2) 'two distinct logs'
    Check (@($logs | Where-Object { (Get-Content $_.FullName -Raw) -match 'slow done' }).Count -eq 2) 'both logs complete'

    Write-Host 'lingering daemon must not hold the caller pipe'
    $d = New-Fixture 'daemon'
    $env:MOCK_SCENARIO = 'daemon'
    $pi = New-Object Diagnostics.ProcessStartInfo
    $pi.FileName = 'powershell.exe'
    $pi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $d 'quiet-gradle.ps1')`" assembleDebug"
    $pi.UseShellExecute = $false; $pi.RedirectStandardOutput = $true
    $pp = [Diagnostics.Process]::Start($pi)
    Remove-Item Env:\MOCK_SCENARIO
    $eof = $pp.StandardOutput.ReadToEndAsync()
    $done = $eof.Wait(15000)
    Check $done 'caller sees EOF while a child lingers (25s child, 15s limit)'
    if ($done) { Check ($eof.Result -match 'QG PASS') 'PASS reported' }
    $pp.WaitForExit()

    Write-Host 'wrapper errors'
    $d = New-Fixture 'nogradle' $false; $r = Invoke-QG $d 'pass' @('x')
    Check ($r.Code -eq 70 -and $r.Out -match 'gradlew\.bat not found') 'missing gradlew.bat -> 70'
    Check (-not (Test-Path (Join-Path $d '.agent-logs'))) 'no log dir created'
    $d = New-Fixture 'badlog'; [IO.File]::WriteAllText((Join-Path $d 'blocker'), 'x')
    $r = Invoke-QG $d 'pass' @('-LogDirectory', 'blocker\sub', 'x')
    Check ($r.Code -eq 70 -and $r.Out -match 'cannot create log') 'unwritable log dir -> 70'
    Check (-not (Test-Path (Join-Path $d 'record.txt'))) 'gradle never ran'
    $d = New-Fixture 'noargs'; $r = Invoke-QG $d 'pass' @()
    Check ($r.Code -eq 64 -and $r.Out -match 'QG USAGE') 'no arguments -> 64'
    $r = Invoke-QG $d 'pass' @('-TailLines', 'abc', 'x')
    Check ($r.Code -eq 64) 'bad -TailLines -> 64'

    Write-Host 'pruning'
    $d = New-Fixture 'prune'; $ld = Join-Path $d '.agent-logs\gradle'; [void](New-Item -ItemType Directory -Force $ld)
    1..25 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $ld ("20200101-0000{0:00}.000-p1-{1}.log" -f $_, ('{0:x8}' -f $_))), 'old') }
    [IO.File]::WriteAllText((Join-Path $ld 'keep-me.txt'), 'x'); [IO.File]::WriteAllText((Join-Path $ld 'notes.log'), 'x')
    [void](New-Item -ItemType Directory -Force (Join-Path $ld '20200101-000000.000-p1-deadbeef.log'))
    $r = Invoke-QG $d 'pass' @('-KeepLogs', '5', 'x')
    $strict = @(Get-ChildItem $ld -File | Where-Object { $_.Name -match '^\d{8}-\d{6}\.\d{3}-p\d+-[0-9a-f]{8}\.log$' })
    Check ($strict.Count -eq 5) "5 wrapper logs kept ($($strict.Count))"
    Check ((Test-Path (Join-Path $ld 'keep-me.txt')) -and (Test-Path (Join-Path $ld 'notes.log'))) 'foreign files untouched'
    Check (Test-Path (Join-Path $ld '20200101-000000.000-p1-deadbeef.log') -PathType Container) 'directory untouched'
    $r = Invoke-QG $d 'pass' @('-KeepLogs', '0', 'x'); $r = Invoke-QG $d 'pass' @('-KeepLogs', '0', 'x')
    Check (@(Get-ChildItem $ld -File | Where-Object { $_.Name -match '^\d{8}-' }).Count -ge 7) '-KeepLogs 0 disables pruning'
}
finally {
    Pop-Location
    if (Test-Path $fixtures) { Remove-Item -Recurse -Force $fixtures }
}

Write-Host ''
Write-Host "passed=$script:pass failed=$script:fail"
exit ([int]($script:fail -gt 0))
