# ArcSight LogMonitor (Windows)

A single-file PowerShell script that monitors ArcSight SmartConnectors and the Windows host they run on. Alerts are written to a local alert log and the Windows Event Log, and sent as CEF over TCP syslog. Each monitor keeps its ALERT/CLEAR state between runs, so an alert is only sent when its state changes.

## Requirements

- Windows PowerShell 5.1 or later
- ActiveDirectory module (only for the AD account and password checks)
- Rights to write to the Event Log source `ArcSightMonitor`

## Quick start

```powershell
# 1. Generate LogMonitor.properties next to the script (finds connectors and ArcSight services)
.\LogMonitor.ps1 -UpdateConfig

#    (or copy LogMonitor.properties.example to LogMonitor.properties)

# 2. Edit LogMonitor.properties: set SyslogServer, AccountList, thresholds, etc.

# 3. Send a test alarm to check that syslog delivery works
.\LogMonitor.ps1 -SendTest

# 4. Run all checks (schedule this, e.g. every 5 minutes)
.\LogMonitor.ps1 -Check
```

## Configuration

All settings live in `LogMonitor.properties` next to the script. [`LogMonitor.properties.example`](LogMonitor.properties.example) shows every key with its default value, plus two example connectors with per-connector overrides. Keys that are missing from the file fall back to the defaults built into the script.

## Parameters

| Parameter | Description |
|---|---|
| `-Check` | Run all enabled host and connector checks |
| `-UpdateConfig` | Create or update `LogMonitor.properties`, keeping existing values |
| `-ResetConfig` | Delete the config file and generate a new one with default values |
| `-CheckConfig` | Compare the config against the defaults (`-NonDefault` shows only changed values) |
| `-Status` | Show the state of every monitor (`-Alert` shows only active alerts, `-Message` adds the messages) |
| `-Connector <name>` | Limit `-Status` to one connector |
| `-ConnectorPath <path>` | Check one connector directory directly |
| `-SendTest` | Send the daily test alarm (ARC040) and report whether syslog delivery worked |
| `-ResetMonitoring` | Clear the state file (`monitor_state.json`) |
| `-Debug` | Show the log output in the console |
| `-Help` / `-h` | Show help |

## Checks

| Event ID | Check |
|---|---|
| ARC021 | ERROR/FATAL pattern count in `agent.log` |
| ARC022 | Average EPS outside the min/max range |
| ARC023 | ArcSight Windows service not running |
| ARC024 / 025 / 026 | Disk free space, RAM use, CPU use |
| ARC027 | AD account or password about to expire |
| ARC035 | SmartConnector JVM free memory |
| ARC036–039 | Raw events, drop count, post-aggregation SLC, receiver status |
| ARC040 | Daily test alarm |
| ARC041–045 | AgentStats: missing log status, cache, sent count, throughput |

Each check can be turned on or off globally, and per connector with keys such as `<connector>.eps.enabled=false`. When a monitor in ALERT state is disabled in the config, the script sends a CLEAR for it automatically.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | Config file missing |
| 2 | One or more checks are in alert, or `-SendTest` could not deliver via syslog |

## Syslog behaviour

- The syslog target comes from `SyslogServer` and `SyslogPort` in `LogMonitor.properties`. The host-pattern defaults in the script are example values only.
- The connection times out after 3 seconds.
- If a send fails, a WARN line is written to `LogMonitor.log` and syslog is skipped for the rest of that run. Alerts are still written to the alert log and the Event Log. The next run tries syslog again.

## License

[MIT](LICENSE)
