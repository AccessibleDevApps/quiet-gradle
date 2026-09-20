# quiet-gradle

A single-file PowerShell wrapper that runs a project's `gradlew.bat` with bounded console output. Built to keep routine Gradle noise out of an AI agent's context window while saving the complete log for later.

- Success: one `QG RUN` line and one `QG PASS` line.
- Failure: a bounded excerpt (errors, failed tests, dependency problems, log tail) plus the full path to the saved log.
- Gradle's real exit code is preserved.
- No network access, no global Gradle fallback, no build-file changes.

Windows PowerShell 5.1 or newer. Windows only.

## Install

Copy `quiet-gradle.ps1` next to your project's `gradlew.bat`. Add `.agent-logs/` to the project's `.gitignore`.

## Use

```powershell
.\quiet-gradle.ps1 assembleDebug
.\quiet-gradle.ps1 testDebugUnitTest --tests "com.example.SomeTest"
.\quiet-gradle.ps1 -ShowWarnings lintDebug
.\quiet-gradle.ps1 -Full dependencies
.\quiet-gradle.ps1 -TailLines 120 assembleDebug --stacktrace
```

Wrapper options must come before the first Gradle argument and are matched by exact name, so Gradle's own short flags (`-s`, `-t`, `-m`, ...) pass through untouched.

| Option | Default | Meaning |
|---|---|---|
| `-Full` | off | Stream Gradle output to the console as well as the log |
| `-ShowWarnings` | off | On success, print a bounded, deduplicated warning list |
| `-TailLines N` | 80 | Trailing log lines kept in a failure excerpt |
| `-MaxSummaryLines N` | 200 | Hard cap on log lines printed after a failure |
| `-LogDirectory PATH` | `.agent-logs\gradle` | Log directory, relative to the script |
| `-KeepLogs N` | 20 | Keep the newest N wrapper logs; `0` disables pruning |

Logs are named `yyyyMMdd-HHmmss.fff-p<pid>-<random>.log`, so parallel runs never collide.

Exit codes: Gradle's own code for Gradle outcomes; `64` for usage errors; `70` for wrapper errors (missing `gradlew.bat`, unwritable log directory, Gradle cannot start).

## Agent instruction

Add to your project's agent instructions:

> When a task requires direct Gradle execution, use `.\quiet-gradle.ps1` instead of invoking `gradlew.bat` directly. If the quiet failure summary is insufficient, inspect the saved full log rather than rerunning solely to obtain verbose output.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\quiet-gradle.tests.ps1
```

Uses a mock `gradlew.bat`; no real Gradle or network. Fixtures go under `.agent-logs\tests` and are removed afterwards. Ctrl+C handling is not automated.

## Notes

- Logs can contain sensitive values that Gradle, plugins or tests print. Keep `.agent-logs/` out of source control.
- The failure excerpt is a heuristic. If it is not enough, read the saved log.
- The wrapper clears the inherit flag on its own pipe and file handles before launching Gradle. Without that, a Gradle daemon started by the first build keeps the caller's output pipe open and anything reading the wrapper's output hangs.
- Arguments containing `%` are still expanded by `cmd.exe` because `gradlew.bat` is a batch file.

## License

MIT
