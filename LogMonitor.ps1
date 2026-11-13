<#
================================================================================
 Script Name    : LogMonitor.ps1
 Description    : ArcSight SmartConnector & System Resource Monitoring Controller
                  (Single-file edition - all modules embedded)
 Author         : Lars Niklasson
 Current Version: 5.4
 Last Modified  : 2026-10-12
 Requirements   : PowerShell 5.1+
 Embedded       : AlertHandler (v4.3), HostChecks (v4.3), ConnectorChecks (v4.12),
                  ConfigGen (v4.5)
 Changelog      :
   - v5.4 : Fix: -SendTest skickade bara första gången (daily_test_alarm låg kvar
            som ALERT i state-filen). Skickar nu alltid via -ForceSend.
            -SendTest visar vilken syslog-server/port som används och om
            värdet kommer från LogMonitor.properties eller standardvärdet.
            Syslog-anslutning har nu riktig 3 s timeout (ConnectAsync) och
            felmeddelandet visar den faktiska orsaken.
   - v5.3 : -SendTest skriver en varning (konsol + logg) och avslutar med
            exitkod 2 om testlarmet inte kunde skickas via syslog.
   - v5.2 : Efter första misslyckade syslog-sändningen hoppas syslog över för
            resten av körningen (loggas som WARN per överhoppat larm).
            Nästa körning försöker skicka på nytt.
   - v5.1 : Misslyckad syslog-sändning (CEF/TCP) loggas nu som WARN i
            LogMonitor.log och visas i konsolen med -Debug. Lyckade
            sändningar loggas som DEBUG när -Debug används.
   - v5.0 : Sammanslagen till en fil. AlertHandler.ps1, HostChecks.ps1,
            ConnectorChecks.ps1 och ConfigGen.ps1 är inbäddade som funktioner
            (Handle-AlertState, Invoke-HostChecks, Invoke-ConnectorChecks,
            Invoke-ConfigGen). Ingen funktionell ändring jämfört med v4.6.
   - v4.6 : Automatically sends CLEAR state for monitors when disabled via config.
            Preserves custom settings during -UpdateConfig.
            Fixed case-insensitive matching in -CheckConfig to avoid false 
            CUSTOM / UNKNOWN classifications on global settings.
================================================================================
#>
[CmdletBinding()]
param (
    [Alias("h")]
    [switch]$Help,
    [string]$ConnectorPath,
    [string]$Connector,
    [switch]$Check,
    [switch]$UpdateConfig,
    [switch]$Status,
    [switch]$Alert,
    [switch]$Message,
    [switch]$ResetConfig,
    [switch]$ResetMonitoring,
    [switch]$CheckConfig,
    [switch]$NonDefault,
    [switch]$SendTest
)

$isDebugMode = $PSBoundParameters.ContainsKey('Debug')
if ($isDebugMode) { $DebugPreference = 'Continue' }

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configFile = Join-Path $scriptDir "LogMonitor.properties"

if ($Help -or (-not $Check -and -not $UpdateConfig -and -not $Status -and -not $ResetConfig -and -not $ResetMonitoring -and -not $CheckConfig -and -not $SendTest)) {
    Write-Host "======================================================================"
    Write-Host " ArcSight Log Monitoring Script (v5.4 Single-file)"
    Write-Host "======================================================================"
    Write-Host "Usage: .\LogMonitor.ps1 [Parameters]"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -Check                     Run all enabled operational and health checks"
    Write-Host "  -UpdateConfig              Generate or update the LogMonitor.properties file"
    Write-Host "  -Status                    Display current status of all monitors from state file"
    Write-Host "  -Alert                     Filter -Status to show only items currently in alert state"
    Write-Host "  -Message                   Show detailed alert messages in -Status output"
    Write-Host "  -Connector <Name>          Filter status or checks for a specific connector name"
    Write-Host "  -ConnectorPath <Path>      Specify target connector directory path directly"
    Write-Host "  -CheckConfig               Validate current configuration against defaults"
    Write-Host "  -NonDefault                Show only non-default configuration values"
    Write-Host "  -SendTest                  Manually trigger the daily test alarm (FUNK20)"
    Write-Host "  -ResetConfig               Delete existing config and regenerate defaults"
    Write-Host "  -ResetMonitoring           Clear monitor state file (monitor_state.json)"
    Write-Host "  -Debug                     Enable verbose console logging output"
    Write-Host "  -Help / -h                 Display this help message"
    Write-Host "======================================================================"
    exit 0
}

$currentHost = $env:COMPUTERNAME
# Default syslog destination per host naming pattern.
# Replace these example values with your own, or set SyslogServer in LogMonitor.properties
# (a value in LogMonitor.properties always overrides these defaults).
$defaultSyslogServer = "192.0.2.10"
if ($currentHost -like "site-a-*" -or $currentHost -like "site-b-*") { $defaultSyslogServer = "192.0.2.11" }
elseif ($currentHost -like "site-c-*") { $defaultSyslogServer = "192.0.2.10" }
elseif ($currentHost -like "site-d-*") { $defaultSyslogServer = "198.51.100.20" }
elseif ($currentHost -like "site-e-*" -or $currentHost -like "site-f-*") { $defaultSyslogServer = "198.51.100.21" }

if ($ResetConfig) {
    if (Test-Path $configFile) { Remove-Item -Path $configFile -Force -ErrorAction SilentlyContinue }
    $UpdateConfig = $true
}

# Läs in konfiguration och rensa osynliga BOM-tecken
$existingConfig = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path $configFile) {
    Get-Content $configFile -Encoding UTF8 | ForEach-Object {
        if ($_ -match '^\s*([^#=]+)\s*=\s*(.*)$') { 
            $key = $matches[1].Trim().Trim([char]0xFEFF)
            $val = $matches[2].Trim().Trim('"').Trim("'")
            $existingConfig[$key] = $val 
        }
    }
}

function Get-CfgVal {
    param($key, $defaultVal)
    
    if ($existingConfig.ContainsKey($key)) {
        $val = $existingConfig[$key]
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            return $val.Trim()
        }
    }
    return $defaultVal
}

$commonFolder    = Get-CfgVal "CommonFolderPath" "C:\arcsight\alertlogs\scripts"
$scriptLogPath   = Get-CfgVal "ScriptLogPath" "$commonFolder\LogMonitor.log"
$alertLogPath    = Get-CfgVal "AlertLogPath" "C:\arcsight\alertlogs\arcsightalerts.log"
$stateFilePath   = Get-CfgVal "StateFilePath" "$commonFolder\monitor_state.json"
$maxLogSizeBytes = [long](Get-CfgVal "MaxScriptLogSizeBytes" "104857600")

# -------------------------------------------------------------------------
# Hantera -CheckConfig och -NonDefault
# -------------------------------------------------------------------------
if ($CheckConfig) {
    if (-not (Test-Path $configFile)) {
        Write-Host "Config file not found at: $configFile" -ForegroundColor Red
        exit 1
    }

    # 1. Globala standardvärden
    $globalDefaultDict = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    @{
        "AgentStatsMinThroughputT"           = "0.01"
        "AgentStatsMaxCacheC"                = "100"
        "AgentStatsMinSentS"                 = "1"
        "SyslogEnabled"                      = "true"
        "EventLogEnabled"                    = "true"
        "PatternSearchEnabled"               = "true"
        "PatternThresholdCount"              = "100"
        "PatternLookbackMinutes"             = "15"
        "EpsSearchEnabled"                   = "true"
        "EpsLookbackMinutes"                 = "15"
        "DiskCheckEnabled"                   = "true"
        "DefaultMinDiskFreePercentThreshold" = "10.0"
        "RamCheckEnabled"                    = "true"
        "MaxRamUsagePercentThreshold"        = "90.0"
        "CpuCheckEnabled"                    = "true"
        "MaxCpuUsagePercentThreshold"        = "90.0"
        "AccountCheckEnabled"                = "true"
        "ConnectorMemoryCheckEnabled"        = "true"
        "MinConnectorFreePercentThreshold"   = "10.0"
        "CommonFolderPath"                   = "C:\arcsight\alertlogs\scripts"
        "ScriptLogPath"                      = "C:\arcsight\alertlogs\scripts\LogMonitor.log"
        "AlertLogPath"                       = "C:\arcsight\alertlogs\arcsightalerts.log"
        "StateFilePath"                      = "C:\arcsight\alertlogs\scripts\monitor_state.json"
        "MaxScriptLogSizeBytes"              = "104857600"
        "ConnectorsRootPath"                 = "C:\arcsight\connectors"
    }.GetEnumerator() | ForEach-Object { $globalDefaultDict[$_.Key] = $_.Value }

    # 2. Standardmallar för per-connector-inställningar
    $connectorDefaultDict = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    @{
        "enabled"                         = "true"
        "pattern.enabled"                 = "true"
        "eps.enabled"                     = "true"
        "min_eps"                         = "0.1"
        "max_eps"                         = "500"
        "memory.enabled"                  = "true"
        "rawevent.enabled"                = "true"
        "dropcount.enabled"               = "true"
        "postaggslc.enabled"              = "true"
        "recvstatus.enabled"              = "true"
        "agentstats.enabled"              = "true"
        "agentstats.missinglog.enabled"   = "true"
        "agentstats.cache.enabled"        = "true"
        "agentstats.sent.enabled"         = "true"
        "agentstats.throughput.enabled"   = "true"
    }.GetEnumerator() | ForEach-Object { $connectorDefaultDict[$_.Key] = $_.Value }

    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host " Configuration Verification against Standard Defaults" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan

    foreach ($key in ($existingConfig.Keys | Sort-Object)) {
        $val = $existingConfig[$key]
        $def = $null
        $isMatched = $false

        # A. Skiftlägesokänslig matchning mot globala inställningar
        if ($globalDefaultDict.ContainsKey($key)) {
            $def = $globalDefaultDict[$key]
            $isMatched = $true
        }

        # B. Matchning mot per-connector-inställningar
        if (-not $isMatched) {
            foreach ($cKey in $connectorDefaultDict.Keys) {
                if ($key.EndsWith(".$cKey", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $def = $connectorDefaultDict[$cKey]
                    $isMatched = $true
                    break
                }
            }
        }

        $isDifferent = ($isMatched -and $val.Trim().ToLower() -ne $def.Trim().ToLower())

        if ($NonDefault -and -not $isDifferent -and $isMatched) { continue }

        if ($isDifferent) {
            Write-Host ("{0,-48} = {1,-15} [MODIFIED, Default: {2}]" -f $key, $val, $def) -ForegroundColor Yellow
        } elseif (-not $isMatched) {
            Write-Host ("{0,-48} = {1,-15} [CUSTOM / UNKNOWN]" -f $key, $val) -ForegroundColor Magenta
        } else {
            Write-Host ("{0,-48} = {1,-15}" -f $key, $val) -ForegroundColor DarkGray
        }
    }
    Write-Host "======================================================================" -ForegroundColor Cyan
    exit 0
}

if ($ResetMonitoring -and (Test-Path $stateFilePath)) {
    Remove-Item -Path $stateFilePath -Force -ErrorAction SilentlyContinue
}

$scriptLogDir = Split-Path $scriptLogPath -Parent
$alertLogDir  = Split-Path $alertLogPath -Parent
if ($scriptLogDir -and -not (Test-Path $scriptLogDir)) { New-Item -ItemType Directory -Path $scriptLogDir -Force | Out-Null }
if ($alertLogDir -and -not (Test-Path $alertLogDir)) { New-Item -ItemType Directory -Path $alertLogDir -Force | Out-Null }
if (-not (Test-Path $alertLogPath)) { New-Item -ItemType File -Path $alertLogPath -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO", [System.ConsoleColor]$Color = [System.ConsoleColor]::White)
    if (Test-Path $scriptLogPath) {
        $fileInfo = Get-Item $scriptLogPath -ErrorAction SilentlyContinue
        if ($fileInfo -and $fileInfo.Length -ge $maxLogSizeBytes) {
            Move-Item -Path $scriptLogPath -Destination "$scriptLogPath.1" -Force -ErrorAction SilentlyContinue
        }
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine   = "[$timestamp] [$Level] $Message"
    if ($isDebugMode) { Write-Host $logLine -ForegroundColor $Color }
    Add-Content -Path $scriptLogPath -Value $logLine -Encoding UTF8
}

$previousState = @{}
if (Test-Path $stateFilePath) {
    try {
        $rawJson = Get-Content $stateFilePath -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($rawJson)) {
            $parsed = $rawJson | ConvertFrom-Json
            if ($parsed) { foreach ($prop in $parsed.psobject.Properties) { $previousState[$prop.Name] = $prop.Value } }
        }
    } catch { $previousState = @{} }
}
$currentState = @{}

# Sätts till $true om en syslog-sändning misslyckas; resten av körningen hoppar då
# över syslog. Återställs automatiskt vid nästa körning (lever bara i minnet).
$script:syslogSkipRun = $false


# ##############################################################################
#  MODULE: AlertHandler (v4.3)
#  Alert State Management & CEF Syslog TCP Transmission
# ##############################################################################
function Handle-AlertState {
    param(
        [string]$MonitorKey,
        [string]$EventID,
        [bool]$IsAlarm,
        [string]$AlarmMessage,
        [string]$ClearMessage,
        [string]$ConfiguredSeverity = "WARN",
        [hashtable]$CustomData = $null,
        [switch]$ForceSend   # Skicka larmet även om monitorn redan står i ALERT (används av -SendTest)
    )

    $wasInAlarm = $false
    $savedStateKey = $null

    if ($previousState.ContainsKey($MonitorKey)) {
        $prevStateVal = $previousState[$MonitorKey]
        if ($prevStateVal -is [PSCustomObject]) {
            $wasInAlarm = [bool]$prevStateVal.isAlarm
            $savedStateKey = [string]$prevStateVal.stateKey
        } else {
            $wasInAlarm = [bool]$prevStateVal
        }
    }
    
    $isFirstRun = -not $previousState.ContainsKey($MonitorKey)
    $StateKey = if ($savedStateKey) { $savedStateKey } else { (Get-Date).ToString("yyyyMMddHHmmss") + (((Get-Date).Ticks % 10000000) * 100).ToString("D9") }

    $activeMessage = if ($IsAlarm) { $AlarmMessage } else { $ClearMessage }
    
    $stateObj = @{
        isAlarm  = $IsAlarm
        stateKey = $StateKey
        message  = $activeMessage
    }

    if ($CustomData) {
        foreach ($cKey in $CustomData.Keys) { 
            $stateObj[$cKey] = $CustomData[$cKey] 
        }
    }
    $currentState[$MonitorKey] = $stateObj

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $eventLogEnabled = [system.boolean]::Parse((Get-CfgVal "EventLogEnabled" "true"))
    $eventLogSource  = Get-CfgVal "EventLogSource" "ArcSightMonitor"
    $eventLogName    = Get-CfgVal "EventLogName" "Application"

    $syslogEnabled   = [system.boolean]::Parse((Get-CfgVal "SyslogEnabled" "true"))
    $syslogServer    = Get-CfgVal "SyslogServer" $defaultSyslogServer
    $syslogPort      = [int](Get-CfgVal "SyslogPort" "514")
    $syslogFacility  = [int](Get-CfgVal "SyslogFacility" "16")

    [int]$numericEventId = if ($EventID -match '(\d+)') { [int]$matches[1] } else { 100 }

    $SendSyslogCefTcp = {
        param([string]$Message, [string]$StatusType, [string]$ConfiguredSevStr, [string]$ActiveStateKey)
        
        if ($script:syslogSkipRun) {
            Write-Log "Syslog skipped: [$EventID] $StatusType (StateKey: $ActiveStateKey) - syslog disabled for this run after earlier failure." -Level "WARN" -Color DarkYellow
            return
        }

        $tcpClient = $null
        $sendError = $null
        try {
            $cefSeverity = 2
            $cs2LogLevel = "CLEAR"
            
            if ($StatusType -eq "ALERT") {
                switch -Wildcard ($ConfiguredSevStr.ToUpper()) {
                    "*CRIT*"  { $cefSeverity = 10; $cs2LogLevel = "CRIT" }
                    "*FATAL*" { $cefSeverity = 10; $cs2LogLevel = "CRIT" }
                    "*ERR*"   { $cefSeverity = 8;  $cs2LogLevel = "ERROR" }
                    Default   { $cefSeverity = 7;  $cs2LogLevel = "WARN" }
                }
            }

            $syslogSev = if ($StatusType -eq "ALERT") { 4 } else { 6 }
            $pri = ($syslogFacility * 8) + $syslogSev
            $syslogTime = (Get-Date).ToString("MMM dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture)
            $hostname = $env:COMPUTERNAME
            $epochTime = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()

            $cefCategory = "System/Monitor"
            switch -Wildcard ($EventID) {
                "ARC021" { $cefCategory = "Application/Error" }
                "ARC022" { $cefCategory = "Resource/EPS" }
                "ARC023" { $cefCategory = "System/Services" }
                "ARC024" { $cefCategory = "System/Disk" }
                "ARC025" { $cefCategory = "System/RAM" }
                "ARC026" { $cefCategory = "System/CPU" }
                "ARC027" { $cefCategory = "System/Account" }
                "ARC035" { $cefCategory = "Resource/Memory" }
                "ARC036" { $cefCategory = "Resource/RawEvents" }
                "ARC037" { $cefCategory = "Resource/DropCount" }
                "ARC038" { $cefCategory = "Resource/Throughput" }
                "ARC039" { $cefCategory = "System/ReceiverStatus" }
                "ARC040" { $cefCategory = "System/TestAlarm" }
                "ARC041" { $cefCategory = "Agent/MissingLog" }
                "ARC042" { $cefCategory = "Agent/Cache" }
                "ARC043" { $cefCategory = "Agent/Threads" }
                "ARC044" { $cefCategory = "Agent/SentCount" }
                "ARC045" { $cefCategory = "Agent/Throughput" }
            }

            $cefName = "$cefCategory $StatusType"
            $cs2Timestamp = (Get-Date).ToString("MM dd yy HH:mm:ss")
            $customString2 = "${cs2Timestamp} ${cs2LogLevel}|${ActiveStateKey}|${EventID}|${Message}"

            $escapedName = $cefName -replace '\\', '\\' -replace '\|', '\|'
            $escapedMsg  = $Message -replace '\\', '\\' -replace '=', '\='
            $escapedCS2  = $customString2 -replace '\\', '\\' -replace '=', '\='

            $cefExtensions = "msg=$escapedMsg cat=$cefCategory cs1Label=StateKey cs1=$ActiveStateKey cs2Label=AlertLine cs2=$escapedCS2 rt=$epochTime"
            $cefHeader = "CEF:0|FM|ArcSight SmartConnector Monitor|1.0|$EventID|$escapedName|$cefSeverity|$cefExtensions"
            $syslogPacket = "<$pri>$syslogTime $hostname $cefHeader" + [char]10

            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $tcpClient.SendTimeout = 3000
            $tcpClient.ReceiveTimeout = 3000
            # Connect() ignorerar SendTimeout och kan hänga ~20 s mot en IP som inte svarar,
            # därför används ConnectAsync med en egen timeout på 3 sekunder.
            $connectTask = $tcpClient.ConnectAsync($syslogServer, $syslogPort)
            if (-not $connectTask.Wait(3000)) { throw "Connection timed out after 3000 ms" }
            
            if ($tcpClient.Connected) {
                $stream = $tcpClient.GetStream()
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($syslogPacket)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                $stream.Close()
                $tcpClient.Close()
                if ($isDebugMode) { Write-Log "Syslog sent: [$EventID] $StatusType to ${syslogServer}:${syslogPort} (StateKey: $ActiveStateKey)" -Level "DEBUG" -Color DarkGray }
            } else {
                $sendError = "could not connect"
            }
        }
        catch {
            $ex = $_.Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            $sendError = $ex.Message
        }
        finally {
            if ($tcpClient -and $tcpClient.Connected) { $tcpClient.Close() }
        }

        if ($sendError) {
            Write-Log "Syslog send FAILED: [$EventID] $StatusType to ${syslogServer}:${syslogPort} (StateKey: $ActiveStateKey) - $sendError" -Level "WARN" -Color Yellow
            Write-Log "Syslog disabled for the remainder of this run. Remaining alerts are written to alert log/Event Log only. Syslog will be retried on next run." -Level "WARN" -Color Yellow
            $script:syslogSkipRun = $true
        }
    }

    if ($IsAlarm) {
        if (-not $wasInAlarm -or $ForceSend) {
            $alertLine = "[$timestamp] [ALERT] [$EventID] $AlarmMessage"
            Add-Content -Path $alertLogPath -Value $alertLine -Encoding UTF8
            Write-Log "ALERT GENERATED: [$EventID] (StateKey: $StateKey) $AlarmMessage" -Level "ALARM" -Color Red
            
            if ($eventLogEnabled) {
                try { 
                    Write-EventLog -LogName $eventLogName -Source $eventLogSource -EntryType Warning -EventId $numericEventId -Message $AlarmMessage -ErrorAction SilentlyContinue 
                } catch {}
            }
            if ($syslogEnabled) { 
                & $SendSyslogCefTcp -Message $AlarmMessage -StatusType "ALERT" -ConfiguredSevStr $ConfiguredSeverity -ActiveStateKey $StateKey 
            }
        }
    } else {
        if ($isFirstRun -or $wasInAlarm) {
            $clearLine = "[$timestamp] [CLEAR] [$EventID] $ClearMessage"
            Add-Content -Path $alertLogPath -Value $clearLine -Encoding UTF8
            Write-Log "CLEAR GENERATED: [$EventID] (StateKey: $StateKey) $ClearMessage" -Level "CLEAR" -Color Green
            
            if ($eventLogEnabled) {
                try { 
                    Write-EventLog -LogName $eventLogName -Source $eventLogSource -EntryType Information -EventId $numericEventId -Message $ClearMessage -ErrorAction SilentlyContinue 
                } catch {}
            }
            if ($syslogEnabled) { 
                & $SendSyslogCefTcp -Message $ClearMessage -StatusType "CLEAR" -ConfiguredSevStr "CLEAR" -ActiveStateKey $StateKey 
            }
        }
    }
}


# ##############################################################################
#  MODULE: HostChecks (v4.3)
#  Host System Resources & Windows/AD Checks
# ##############################################################################
function Invoke-HostChecks {
    Write-Log "--- CHECK: Starting Host Checks ---" -Level "INFO" -Color Yellow
    $invCulture = [System.Globalization.CultureInfo]::InvariantCulture

    # 1. Disk Check (FUNK04)
    if ([system.boolean]::Parse((Get-CfgVal "DiskCheckEnabled" "true"))) {
        $minDiskPct = [double]::Parse((Get-CfgVal "DefaultMinDiskFreePercentThreshold" "10.0"), $invCulture)
        foreach ($drv in (Get-PSDrive -PSProvider FileSystem)) {
            if ($drv.Used -and $drv.Free) {
                $freePct = [Math]::Round(($drv.Free / ($drv.Used + $drv.Free)) * 100, 2)
                $isAlarm = ($freePct -lt $minDiskPct)
                Handle-AlertState -MonitorKey "disk_$($drv.Name)" -EventID (Get-CfgVal "AlertEventID_Func4" "ARC024") -IsAlarm $isAlarm -AlarmMessage "Drive $($drv.Name): free space $freePct%." -ClearMessage "Drive $($drv.Name) OK ($freePct% free)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func4" "WARN")
                if ($isAlarm) { $script:overallHasErrors = $true }
            }
        }
    }

    # 2. RAM Check (FUNK05)
    if ([system.boolean]::Parse((Get-CfgVal "RamCheckEnabled" "true"))) {
        $maxRamPct = [double]::Parse((Get-CfgVal "MaxRamUsagePercentThreshold" "90.0"), $invCulture)
        $os = Get-CimInstance Win32_OperatingSystem
        $usedRamPct = [Math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 2)
        $isAlarm = ($usedRamPct -gt $maxRamPct)
        Handle-AlertState -MonitorKey "system_ram" -EventID (Get-CfgVal "AlertEventID_Func5" "ARC025") -IsAlarm $isAlarm -AlarmMessage "RAM usage $usedRamPct%." -ClearMessage "RAM OK ($usedRamPct% used)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func5" "WARN")
        if ($isAlarm) { $script:overallHasErrors = $true }
    }

    # 3. CPU Check (FUNK06)
    if ([system.boolean]::Parse((Get-CfgVal "CpuCheckEnabled" "true"))) {
        $maxCpuPct = [double]::Parse((Get-CfgVal "MaxCpuUsagePercentThreshold" "90.0"), $invCulture)
        $cpuSamples = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        if ($null -eq $cpuSamples) { $cpuSamples = 0.0 }
        $isAlarm = ($cpuSamples -gt $maxCpuPct)
        Handle-AlertState -MonitorKey "system_cpu" -EventID (Get-CfgVal "AlertEventID_Func6" "ARC026") -IsAlarm $isAlarm -AlarmMessage "CPU usage $cpuSamples%." -ClearMessage "CPU OK ($cpuSamples% used)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func6" "WARN")
        if ($isAlarm) { $script:overallHasErrors = $true }
    }

    # 4. Windows Services Check (FUNK03)
    if ([system.boolean]::Parse((Get-CfgVal "ServiceCheckEnabled" "true"))) {
        foreach ($svc in (Get-Service | Where-Object { $_.Name -like "arc_*" -or $_.Name -like "*ArcSight*" })) {
            $sName = $svc.Name
            if ([system.boolean]::Parse((Get-CfgVal "service.${sName}.enabled" "true"))) {
                $isAlarm = ($svc.Status -ne 'Running')
                Handle-AlertState -MonitorKey "service_${sName}" -EventID (Get-CfgVal "AlertEventID_Func3" "ARC023") -IsAlarm $isAlarm -AlarmMessage "Service '${sName}' status $($svc.Status)." -ClearMessage "Service '${sName}' running." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func3" "WARN")
                if ($isAlarm) { $script:overallHasErrors = $true }
            }
        }
    }

    # 5. Active Directory Check (FUNK07)
    if ([system.boolean]::Parse((Get-CfgVal "AccountCheckEnabled" "true"))) {
        $accWarnDays = [int]::Parse((Get-CfgVal "AccountExpThresholdDays" "30"), $invCulture)
        $pwdWarnDays = [int]::Parse((Get-CfgVal "PasswordExpThresholdDays" "14"), $invCulture)
        foreach ($acc in ((Get-CfgVal "AccountList" "svc_account1, svc_account2") -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })) {
            try {
                $adUser = Get-ADUser -Identity $acc -Properties PasswordLastSet, AccountExpirationDate, PasswordNeverExpires -ErrorAction Stop
                $now = Get-Date
                if ($adUser.AccountExpirationDate) {
                    $daysLeft = ($adUser.AccountExpirationDate - $now).Days
                    $isAlarm = ($daysLeft -le $accWarnDays)
                    Handle-AlertState -MonitorKey "ad_account_exp_${acc}" -EventID (Get-CfgVal "AlertEventID_Func7" "ARC027") -IsAlarm $isAlarm -AlarmMessage "AD account '$acc' expires in $daysLeft days." -ClearMessage "AD account '$acc' OK." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func7" "WARN")
                    if ($isAlarm) { $script:overallHasErrors = $true }
                }
                if (-not $adUser.PasswordNeverExpires -and $adUser.PasswordLastSet) {
                    $pwdDaysLeft = ($adUser.PasswordLastSet.AddDays(90) - $now).Days
                    $isPwdAlarm = ($pwdDaysLeft -le $pwdWarnDays)
                    Handle-AlertState -MonitorKey "ad_password_exp_${acc}" -EventID (Get-CfgVal "AlertEventID_Func7" "ARC027") -IsAlarm $isPwdAlarm -AlarmMessage "AD password for '$acc' expires in $pwdDaysLeft days." -ClearMessage "AD password for '$acc' OK." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func7" "WARN")
                    if ($isPwdAlarm) { $script:overallHasErrors = $true }
                }
            } catch {}
        }
    }
}


# ##############################################################################
#  MODULE: ConnectorChecks (v4.12)
#  SmartConnector Operational & AgentStats Parsing Checks
#   - Strictly filter [logStatus] lines to only include entries containing 'ET='
#     and exclude 'ET=Down, HT=Up'.
# ##############################################################################
function Invoke-ConnectorChecks {
    Write-Log "--- CHECK: Starting Connector Checks ---" -Level "INFO" -Color Yellow;

    if (-not $targetPaths -or $targetPaths.Count -eq 0) {
        Write-Log "No target connector paths found to evaluate." -Level "WARN" -Color Yellow;
    }

    $patternStrings = (Get-CfgVal "PatternString" "[ERROR], [FATAL]") -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" };
    $invCulture = [System.Globalization.CultureInfo]::InvariantCulture;

    foreach ($path in $targetPaths) {
        $connectorName = Split-Path $path -Leaf;
        Write-Log "Evaluating Connector: $connectorName ($path)" -Level "INFO" -Color Cyan;

        if ([string]::Compare((Get-CfgVal "${connectorName}.enabled" "true"), "false", $true) -eq 0) {
            Write-Log "Connector $connectorName is disabled in configuration (.enabled=false). Skipping." -Level "INFO" -Color DarkGray;
            continue;
        }

        # ---------------------------------------------------------------------
        # Hämta loggar: Läs agent.log.1 först (om den finns) och sedan agent.log
        # ---------------------------------------------------------------------
        $logLines = @();
        $primaryLog = Join-Path $path "current\logs\agent.log";
        
        if (-not (Test-Path $primaryLog)) { 
            $primaryLog = Join-Path $path "logs\agent.log";
        }

        $rotatedLog = "$primaryLog.1";
        
        if (Test-Path $rotatedLog) {
            $logLines += Get-Content $rotatedLog -ErrorAction SilentlyContinue;
        }
        
        if (Test-Path $primaryLog) {
            $logLines += Get-Content $primaryLog -ErrorAction SilentlyContinue;
        }

        if ($logLines.Count -eq 0) {
            Write-Log "No agent log files found for connector: $connectorName" -Level "WARN" -Color Yellow;
            continue;
        }

        # ---------------------------------------------------------------------
        # FUNK01: Pattern Search (ERROR/FATAL)
        # ---------------------------------------------------------------------
        if ([system.boolean]::Parse((Get-CfgVal "PatternSearchEnabled" "true"))) {
            if ([string]::Compare((Get-CfgVal "${connectorName}.pattern.enabled" "true"), "true", $true) -eq 0) {
                
                $lookbackMin = [int](Get-CfgVal "PatternLookbackMinutes" "15");
                $thresholdCount = [int](Get-CfgVal "PatternThresholdCount" "100");
                $cutoffTime = (Get-Date).AddMinutes(-$lookbackMin);
                $totalCount = 0;
                $evaluatedLines = 0;

                foreach ($line in $logLines) {
                    if ($line -match "\[?(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})\s+(?<time>\d{2}:\d{2}:\d{2})") {
                        try {
                            $dtStr = "$($matches['year'])-$($matches['month'])-$($matches['day']) $($matches['time'])";
                            $logTime = [datetime]::ParseExact($dtStr, "yyyy-MM-dd HH:mm:ss", $invCulture);
                            
                            if ($logTime -ge $cutoffTime) {
                                $evaluatedLines++;
                                
                                foreach ($pStr in $patternStrings) {
                                    $cleanPattern = $pStr.Trim('[', ']');
                                    if ($line.IndexOf($pStr, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or $line.IndexOf($cleanPattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                                        $totalCount++;
                                        break;
                                    }
                                }
                            }
                        } catch {}
                    }
                }

                Write-Log "Pattern Check (FUNK01) for $connectorName : Evaluated $evaluatedLines lines, found $totalCount matches." -Level "INFO" -Color DarkGray;

                $isAlarm = ($totalCount -ge $thresholdCount);
                Handle-AlertState -MonitorKey "${connectorName}_pattern_error" -EventID (Get-CfgVal "AlertEventID_Func1" "ARC021") -IsAlarm $isAlarm -AlarmMessage "Connector $connectorName recorded $totalCount error patterns in last $lookbackMin min." -ClearMessage "Connector $connectorName pattern count normal ($totalCount matches)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func1" "WARN");
                
                if ($isAlarm) { 
                    $script:overallHasErrors = $true;
                }
            }
        }

        # ---------------------------------------------------------------------
        # Extrahera [logStatus] - ENBART rader som innehåller 'ET='
        # Exkludera endast 'ET=Down' kombinerat med 'HT=Up'
        # ---------------------------------------------------------------------
        $statsLines = @();
        $statsCutoff = (Get-Date).AddMinutes(-30);

        foreach ($line in $logLines) {
            if ($line -match "\[logStatus\]\{(?<content>.*?)\}") {
                
                $contentStr = $matches['content'];
                
                # Krav 1: Måste vara en destinationsrad (innehålla ET=)
                if ($contentStr.IndexOf("ET=", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    continue;
                }

                # Krav 2: Exkludera ENDAST sekundära speglingsrader (ET=Down OCH HT=Up)
                if ($contentStr.IndexOf("ET=Down", [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and $contentStr.IndexOf("HT=Up", [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { 
                    continue;
                }

                if ($line -match "\[?(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})\s+(?<time>\d{2}:\d{2}:\d{2})") {
                    try {
                        $dtStr = "$($matches['year'])-$($matches['month'])-$($matches['day']) $($matches['time'])";
                        $logTime = [datetime]::ParseExact($dtStr, "yyyy-MM-dd HH:mm:ss", $invCulture);
                        
                        if ($logTime -ge $statsCutoff) {
                            $statsLines += [PSCustomObject]@{ Time = $logTime; Content = $contentStr };
                        }
                    } catch {}
                }
            }
        }

        # Sortera kronologiskt
        $sortedStats = $statsLines | Sort-Object Time;
        $lastStatus  = $sortedStats | Select-Object -Last 1;
        $firstStatus = $sortedStats | Select-Object -First 1;
        $now = Get-Date;

        # ---------------------------------------------------------------------
        # FUNK02: EPS Average Check
        # ---------------------------------------------------------------------
        if ([system.boolean]::Parse((Get-CfgVal "EpsSearchEnabled" "true")) -and [string]::Compare((Get-CfgVal "${connectorName}.eps.enabled" "true"), "true", $true) -eq 0) {
            
            $minEps = [double]::Parse((Get-CfgVal "${connectorName}.min_eps" "0.1"), $invCulture);
            $maxEps = [double]::Parse((Get-CfgVal "${connectorName}.max_eps" "500"), $invCulture);
            $epsValues = @();
            
            foreach ($r in ($sortedStats | Where-Object { $_.Time -ge $now.AddMinutes(-15) })) {
                if ($r.Content -match "(?:^|\s|,)T=(?<val>[\d\.]+)") { 
                    $epsValues += [double]::Parse($matches['val'], $invCulture);
                }
            }
            
            $avgEps = 0.0;
            if ($epsValues.Count -gt 0) {
                $statsObj = $epsValues | Measure-Object -Average;
                $avgEps = [Math]::Round($statsObj.Average, 2);
            }
            
            $isEpsAlarm = ($avgEps -lt $minEps -or $avgEps -gt $maxEps);
            Handle-AlertState -MonitorKey "${connectorName}_eps" -EventID (Get-CfgVal "AlertEventID_Func2" "ARC022") -IsAlarm $isEpsAlarm -AlarmMessage "Connector $connectorName avg EPS is $avgEps (Limits: $minEps - $maxEps)." -ClearMessage "Connector $connectorName avg EPS OK ($avgEps)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func2" "WARN");
            
            if ($isEpsAlarm) { 
                $script:overallHasErrors = $true;
            }
        }

        # ---------------------------------------------------------------------
        # FUNK15: JVM Free Memory Check
        # ---------------------------------------------------------------------
        if ([system.boolean]::Parse((Get-CfgVal "ConnectorMemoryCheckEnabled" "true")) -and [string]::Compare((Get-CfgVal "${connectorName}.memory.enabled" "true"), "true", $true) -eq 0) {
            
            $minMemFreePct = [double]::Parse((Get-CfgVal "MinConnectorFreePercentThreshold" "10.0"), $invCulture);
            $freeMemPct = -1.0;

            if ($lastStatus) {
                $freeB = 0.0;
                $totalB = 0.0;
                if ($lastStatus.Content -match "(?:^|\s|,)FM=(?<free>\d+)") { $freeB = [double]::Parse($matches['free'], $invCulture); }
                if ($lastStatus.Content -match "(?:^|\s|,)TM=(?<total>\d+)") { $totalB = [double]::Parse($matches['total'], $invCulture); }

                if ($totalB -gt 0) {
                    $freeMemPct = [Math]::Round(($freeB / $totalB) * 100, 2);
                }
            }

            if ($freeMemPct -ge 0) {
                $isMemAlarm = ($freeMemPct -lt $minMemFreePct);
                Handle-AlertState -MonitorKey "${connectorName}_jvm_memory" -EventID (Get-CfgVal "AlertEventID_Func15" "ARC035") -IsAlarm $isMemAlarm -AlarmMessage "Connector $connectorName JVM free memory is $freeMemPct% (Min: $minMemFreePct%)." -ClearMessage "Connector $connectorName JVM memory OK ($freeMemPct% free)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func15" "WARN");
                
                if ($isMemAlarm) { 
                    $script:overallHasErrors = $true;
                }
            }
        }

        # ---------------------------------------------------------------------
        # FUNK16 - FUNK19: SmartMessage Checks
        # ---------------------------------------------------------------------
        if ($lastStatus) {
            if ([system.boolean]::Parse((Get-CfgVal "RawEventCheckEnabled" "true")) -and [string]::Compare((Get-CfgVal "${connectorName}.rawevent.enabled" "true"), "true", $true) -eq 0) {
                if ($lastStatus.Content -match "(?:^|\s|,)R=(?<val>\d+)") {
                    $rawVal = [long]::Parse($matches['val'], $invCulture);
                    $isRawAlarm = ($rawVal -eq 0);
                    Handle-AlertState -MonitorKey "${connectorName}_raw_events" -EventID (Get-CfgVal "AlertEventID_Func16" "ARC036") -IsAlarm $isRawAlarm -AlarmMessage "Connector $connectorName raw event count is 0." -ClearMessage "Connector $connectorName raw events active ($rawVal)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func16" "WARN");
                } else {
                    Handle-AlertState -MonitorKey "${connectorName}_raw_events" -EventID (Get-CfgVal "AlertEventID_Func16" "ARC036") -IsAlarm $false -AlarmMessage "OK" -ClearMessage "Connector $connectorName raw event metric not present (OK)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func16" "WARN");
                }
            }

            if ([system.boolean]::Parse((Get-CfgVal "DropCountCheckEnabled" "true")) -and [string]::Compare((Get-CfgVal "${connectorName}.dropcount.enabled" "true"), "true", $true) -eq 0) {
                $isDropAlarm = $lastStatus.Content -match "(?:^|\s|,)D=(?<val>[1-9]\d*)";
                Handle-AlertState -MonitorKey "${connectorName}_drop_count" -EventID (Get-CfgVal "AlertEventID_Func17" "ARC037") -IsAlarm $isDropAlarm -AlarmMessage "Connector $connectorName dropping events detected." -ClearMessage "Connector $connectorName drop count OK (0 drops)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func17" "WARN");
            }

            if ([system.boolean]::Parse((Get-CfgVal "PostAggSlcCheckEnabled" "true")) -and [string]::Compare((Get-CfgVal "${connectorName}.postaggslc.enabled" "true"), "true", $true) -eq 0) {
                $isSlcAlarm = $lastStatus.Content -match "\bSLC=Down\b";
                Handle-AlertState -MonitorKey "${connectorName}_post_agg_slc" -EventID (Get-CfgVal "AlertEventID_Func18" "ARC038") -IsAlarm $isSlcAlarm -AlarmMessage "Connector $connectorName Post-Aggregation SLC is Down." -ClearMessage "Connector $connectorName Post-Aggregation SLC OK." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func18" "WARN");
            }

            if ([system.boolean]::Parse((Get-CfgVal "ReceiverStatusCheckEnabled" "true")) -and [string]::Compare((Get-CfgVal "${connectorName}.recvstatus.enabled" "true"), "true", $true) -eq 0) {
                $isRecvAlarm = $lastStatus.Content -match "\bRCV=Down\b";
                Handle-AlertState -MonitorKey "${connectorName}_receiver_status" -EventID (Get-CfgVal "AlertEventID_Func19" "ARC039") -IsAlarm $isRecvAlarm -AlarmMessage "Connector $connectorName Receiver status is Down." -ClearMessage "Connector $connectorName Receiver active." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func19" "WARN");
            }
        }

        # ---------------------------------------------------------------------
        # FUNK21 - FUNK25: AgentStats Checks
        # ---------------------------------------------------------------------
        if ([system.boolean]::Parse((Get-CfgVal "AgentStatsCheckEnabled" "true")) -and [string]::Compare((Get-CfgVal "${connectorName}.agentstats.enabled" "true"), "true", $true) -eq 0) {
            
            # FUNK21: Missing Log
            if ([string]::Compare((Get-CfgVal "${connectorName}.agentstats.missinglog.enabled" "true"), "true", $true) -eq 0) {
                $recentCount = ($sortedStats | Where-Object { $_.Time -ge $now.AddMinutes(-5) }).Count;
                $isMissingAlarm = ($recentCount -eq 0);
                Handle-AlertState -MonitorKey "${connectorName}_missing_log" -EventID (Get-CfgVal "AlertEventID_Func21" "ARC041") -IsAlarm $isMissingAlarm -AlarmMessage "Connector $connectorName missing agent log status entries." -ClearMessage "Connector $connectorName log status present." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func21" "WARN");
                
                if ($isMissingAlarm) { 
                    $script:overallHasErrors = $true; 
                    continue; 
                }
            }

            # FUNK22: Cache C=
            if ([string]::Compare((Get-CfgVal "${connectorName}.agentstats.cache.enabled" "true"), "true", $true) -eq 0) {
                $globalMaxC = [double]::Parse((Get-CfgVal "AgentStatsMaxCacheC" "100"), $invCulture);
                $cacheValues = @();
                
                foreach ($r in $sortedStats) {
                    if ($r.Content -match "(?:^|\s|,)C=(?<val>\d+)") { 
                        $cacheValues += [double]::Parse($matches['val'], $invCulture); 
                    }
                }
                
                $avgCache = 0.0;
                if ($cacheValues.Count -gt 0) {
                    $cStats = $cacheValues | Measure-Object -Average;
                    $avgCache = [Math]::Round($cStats.Average, 1);
                }
                
                $isCacheAlarm = ($avgCache -gt $globalMaxC);
                Handle-AlertState -MonitorKey "${connectorName}_cache_c" -EventID (Get-CfgVal "AlertEventID_Func22" "ARC042") -IsAlarm $isCacheAlarm -AlarmMessage "Connector $connectorName avg cache level $avgCache exceeds threshold $globalMaxC." -ClearMessage "Connector $connectorName cache normal ($avgCache)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func22" "WARN");
                
                if ($isCacheAlarm) { 
                    $script:overallHasErrors = $true; 
                }
            }

            # FUNK24: Sent S= 
            if ([string]::Compare((Get-CfgVal "${connectorName}.agentstats.sent.enabled" "true"), "true", $true) -eq 0 -and $lastStatus) {
                $minSentReq = [long]::Parse((Get-CfgVal "AgentStatsMinSentS" "1"), $invCulture);
                
                $sLatest = if ($lastStatus.Content -match "(?:^|\s|,)S=(?<val>\d+)") { [long]::Parse($matches['val'], $invCulture); } else { 0 };
                $sFirst  = if ($firstStatus -and $firstStatus.Content -match "(?:^|\s|,)S=(?<val>\d+)") { [long]::Parse($matches['val'], $invCulture); } else { $sLatest };
                
                $diffS = [Math]::Max(0, $sLatest - $sFirst);

                $isSentAlarm = ($diffS -lt $minSentReq);
                Handle-AlertState -MonitorKey "${connectorName}_sent_s" -EventID (Get-CfgVal "AlertEventID_Func24" "ARC044") -IsAlarm $isSentAlarm -AlarmMessage "Connector $connectorName sent count increase is $diffS (Below threshold $minSentReq)." -ClearMessage "Connector $connectorName sent events OK (Sent total: $sLatest, Increase: $diffS)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func24" "WARN");
                
                if ($isSentAlarm) { 
                    $script:overallHasErrors = $true; 
                }
            }

            # FUNK25: Throughput T= 
            if ([string]::Compare((Get-CfgVal "${connectorName}.agentstats.throughput.enabled" "true"), "true", $true) -eq 0 -and $lastStatus) {
                $minTReq = [double]::Parse((Get-CfgVal "AgentStatsMinThroughputT" "0.01"), $invCulture);
                
                $curT = 0.0;
                if ($lastStatus.Content -match "(?:^|\s|,)T=(?<val>[\d\.]+)") { 
                    $curT = [double]::Parse($matches['val'], $invCulture); 
                }

                $isThroughputAlarm = ($curT -lt $minTReq);
                Handle-AlertState -MonitorKey "${connectorName}_throughput_t" -EventID (Get-CfgVal "AlertEventID_Func25" "ARC045") -IsAlarm $isThroughputAlarm -AlarmMessage "Connector $connectorName throughput is $curT EPS (Below threshold $minTReq EPS)." -ClearMessage "Connector $connectorName throughput OK ($curT EPS)." -ConfiguredSeverity (Get-CfgVal "AlertSeverity_Func25" "WARN");
                
                if ($isThroughputAlarm) { 
                    $script:overallHasErrors = $true; 
                }
            }
        }
    }
}


# ##############################################################################
#  MODULE: ConfigGen (v4.5)
#  Properties File Generator - bevarar befintliga värden via Get-CfgVal
# ##############################################################################
function Invoke-ConfigGen {
    Write-Log "Starting configuration update (-UpdateConfig)..." -Level "INFO" -Color Cyan

    $discoveredServices = (Get-Service | Where-Object { $_.Name -like "arc_*" -or $_.Name -like "*ArcSight*" }).Name

    $configLines = @(
        "# ======================================================================",
        "# ArcSight Log Monitoring Script Configuration Properties",
        "# ======================================================================",
        "",
        "# Shared Directory Pointer",
        "CommonFolderPath=$(Get-CfgVal 'CommonFolderPath' $commonFolder)",
        "",
        "# Root directory to search for connector log files",
        "ConnectorsRootPath=$(Get-CfgVal 'ConnectorsRootPath' $connectorsBase)",
        "LogFileFilter=$(Get-CfgVal 'LogFileFilter' 'agent.log')",
        "",
        "# Alert Output Settings (File, Syslog & Event Log)",
        "AlertLogPath=$(Get-CfgVal 'AlertLogPath' $alertLogPath)",
        "SyslogEnabled=$(Get-CfgVal 'SyslogEnabled' 'true')",
        "SyslogServer=$(Get-CfgVal 'SyslogServer' $defaultSyslogServer)",
        "SyslogPort=$(Get-CfgVal 'SyslogPort' '514')",
        "SyslogFacility=$(Get-CfgVal 'SyslogFacility' '16')",
        "",
        "# Windows Event Log Settings",
        "EventLogEnabled=$(Get-CfgVal 'EventLogEnabled' 'true')",
        "EventLogSource=$(Get-CfgVal 'EventLogSource' 'ArcSightMonitor')",
        "EventLogName=$(Get-CfgVal 'EventLogName' 'Application')",
        "",
        "# Global Agent Stats Thresholds",
        "AgentStatsMinThroughputT=$(Get-CfgVal 'AgentStatsMinThroughputT' '0.01')",
        "AgentStatsMaxCacheC=$(Get-CfgVal 'AgentStatsMaxCacheC' '100')",
        "AgentStatsMinSentS=$(Get-CfgVal 'AgentStatsMinSentS' '1')",
        "",
        "# ======================================================================",
        "# ArcSight Event IDs per Function",
        "# ======================================================================",
        "AlertEventID_Func1=$(Get-CfgVal 'AlertEventID_Func1' 'ARC021')",
        "AlertEventID_Func2=$(Get-CfgVal 'AlertEventID_Func2' 'ARC022')",
        "AlertEventID_Func3=$(Get-CfgVal 'AlertEventID_Func3' 'ARC023')",
        "AlertEventID_Func4=$(Get-CfgVal 'AlertEventID_Func4' 'ARC024')",
        "AlertEventID_Func5=$(Get-CfgVal 'AlertEventID_Func5' 'ARC025')",
        "AlertEventID_Func6=$(Get-CfgVal 'AlertEventID_Func6' 'ARC026')",
        "AlertEventID_Func7=$(Get-CfgVal 'AlertEventID_Func7' 'ARC027')",
        "AlertEventID_Func15=$(Get-CfgVal 'AlertEventID_Func15' 'ARC035')",
        "AlertEventID_Func16=$(Get-CfgVal 'AlertEventID_Func16' 'ARC036')",
        "AlertEventID_Func17=$(Get-CfgVal 'AlertEventID_Func17' 'ARC037')",
        "AlertEventID_Func18=$(Get-CfgVal 'AlertEventID_Func18' 'ARC038')",
        "AlertEventID_Func19=$(Get-CfgVal 'AlertEventID_Func19' 'ARC039')",
        "AlertEventID_Func20=$(Get-CfgVal 'AlertEventID_Func20' 'ARC040')",
        "AlertEventID_Func21=$(Get-CfgVal 'AlertEventID_Func21' 'ARC041')",
        "AlertEventID_Func22=$(Get-CfgVal 'AlertEventID_Func22' 'ARC042')",
        "AlertEventID_Func23=$(Get-CfgVal 'AlertEventID_Func23' 'ARC043')",
        "AlertEventID_Func24=$(Get-CfgVal 'AlertEventID_Func24' 'ARC044')",
        "AlertEventID_Func25=$(Get-CfgVal 'AlertEventID_Func25' 'ARC045')",
        "",
        "# ======================================================================",
        "# ArcSight Alert Severity per Function (WARN or CRIT)",
        "# ======================================================================",
        "AlertSeverity_Func1=$(Get-CfgVal 'AlertSeverity_Func1' 'WARN')",
        "AlertSeverity_Func2=$(Get-CfgVal 'AlertSeverity_Func2' 'WARN')",
        "AlertSeverity_Func3=$(Get-CfgVal 'AlertSeverity_Func3' 'WARN')",
        "AlertSeverity_Func4=$(Get-CfgVal 'AlertSeverity_Func4' 'WARN')",
        "AlertSeverity_Func5=$(Get-CfgVal 'AlertSeverity_Func5' 'WARN')",
        "AlertSeverity_Func6=$(Get-CfgVal 'AlertSeverity_Func6' 'WARN')",
        "AlertSeverity_Func7=$(Get-CfgVal 'AlertSeverity_Func7' 'WARN')",
        "AlertSeverity_Func15=$(Get-CfgVal 'AlertSeverity_Func15' 'WARN')",
        "AlertSeverity_Func16=$(Get-CfgVal 'AlertSeverity_Func16' 'WARN')",
        "AlertSeverity_Func17=$(Get-CfgVal 'AlertSeverity_Func17' 'WARN')",
        "AlertSeverity_Func18=$(Get-CfgVal 'AlertSeverity_Func18' 'WARN')",
        "AlertSeverity_Func19=$(Get-CfgVal 'AlertSeverity_Func19' 'WARN')",
        "AlertSeverity_Func20=$(Get-CfgVal 'AlertSeverity_Func20' 'WARN')",
        "AlertSeverity_Func21=$(Get-CfgVal 'AlertSeverity_Func21' 'WARN')",
        "AlertSeverity_Func22=$(Get-CfgVal 'AlertSeverity_Func22' 'WARN')",
        "AlertSeverity_Func23=$(Get-CfgVal 'AlertSeverity_Func23' 'WARN')",
        "AlertSeverity_Func24=$(Get-CfgVal 'AlertSeverity_Func24' 'WARN')",
        "AlertSeverity_Func25=$(Get-CfgVal 'AlertSeverity_Func25' 'WARN')",
        "",
        "# Script Operational Logging Settings",
        "ScriptLogPath=$(Get-CfgVal 'ScriptLogPath' 'C:\arcsight\alertlogs\scripts\LogMonitor.log')",
        "MaxScriptLogSizeBytes=$(Get-CfgVal 'MaxScriptLogSizeBytes' '104857600')",
        "StateFilePath=$(Get-CfgVal 'StateFilePath' 'C:\arcsight\alertlogs\scripts\monitor_state.json')",
        "",
        "# ======================================================================",
        "# Operational Check Configurations (FUNK 1 - 25)",
        "# ======================================================================",
        "# Function 1 Configuration: String Pattern Occurrence Threshold",
        "PatternSearchEnabled=$(Get-CfgVal 'PatternSearchEnabled' 'true')",
        "PatternString=$(Get-CfgVal 'PatternString' '[ERROR], [FATAL]')",
        "PatternThresholdCount=$(Get-CfgVal 'PatternThresholdCount' '100')",
        "PatternLookbackMinutes=$(Get-CfgVal 'PatternLookbackMinutes' '15')",
        "",
        "# Function 2 Configuration: Average EPS Threshold Check",
        "EpsSearchEnabled=$(Get-CfgVal 'EpsSearchEnabled' 'true')",
        "EpsLookbackMinutes=$(Get-CfgVal 'EpsLookbackMinutes' '15')",
        "",
        "# Function 3 Configuration: Windows Service Status Check",
        "ServiceCheckEnabled=$(Get-CfgVal 'ServiceCheckEnabled' 'true')"
    )

    if ($discoveredServices) {
        $configLines += "# Discovered ArcSight Services for Function 3"
        foreach ($svc in $discoveredServices) { 
            $configLines += "service.${svc}.enabled=$(Get-CfgVal "service.${svc}.enabled" 'true')" 
        }
    }

    $configLines += @(
        "",
        "# Function 4 Configuration: Disk Free Space Check",
        "DiskCheckEnabled=$(Get-CfgVal 'DiskCheckEnabled' 'true')",
        "DefaultMinDiskFreePercentThreshold=$(Get-CfgVal 'DefaultMinDiskFreePercentThreshold' '10.0')",
        "",
        "# Function 5 Configuration: RAM Memory Usage Check",
        "RamCheckEnabled=$(Get-CfgVal 'RamCheckEnabled' 'true')",
        "MaxRamUsagePercentThreshold=$(Get-CfgVal 'MaxRamUsagePercentThreshold' '90.0')",
        "",
        "# Function 6 Configuration: CPU Usage Check",
        "CpuCheckEnabled=$(Get-CfgVal 'CpuCheckEnabled' 'true')",
        "MaxCpuUsagePercentThreshold=$(Get-CfgVal 'MaxCpuUsagePercentThreshold' '90.0')",
        "",
        "# Function 7 Configuration: Active Directory Account & Password Expiration Check",
        "AccountCheckEnabled=$(Get-CfgVal 'AccountCheckEnabled' 'true')",
        "AccountList=$(Get-CfgVal 'AccountList' 'svc_account1, svc_account2')",
        "AccountExpThresholdDays=$(Get-CfgVal 'AccountExpThresholdDays' '30')",
        "PasswordExpThresholdDays=$(Get-CfgVal 'PasswordExpThresholdDays' '14')",
        "",
        "# Function 15 Configuration: SmartConnector JVM Memory Check",
        "ConnectorMemoryCheckEnabled=$(Get-CfgVal 'ConnectorMemoryCheckEnabled' 'true')",
        "MinConnectorFreePercentThreshold=$(Get-CfgVal 'MinConnectorFreePercentThreshold' '10.0')",
        "",
        "# Function 16-19 Configuration: SmartMessage Checks",
        "RawEventCheckEnabled=$(Get-CfgVal 'RawEventCheckEnabled' 'true')",
        "DropCountCheckEnabled=$(Get-CfgVal 'DropCountCheckEnabled' 'true')",
        "PostAggSlcCheckEnabled=$(Get-CfgVal 'PostAggSlcCheckEnabled' 'true')",
        "ReceiverStatusCheckEnabled=$(Get-CfgVal 'ReceiverStatusCheckEnabled' 'true')",
        "",
        "# Function 20 Configuration: Scheduled Daily Test Alarm",
        "TestAlarmEnabled=$(Get-CfgVal 'TestAlarmEnabled' 'true')",
        "TestAlarmTime=$(Get-CfgVal 'TestAlarmTime' '06:00')",
        "",
        "# Functions 21-25 Configuration: Advanced Agent Stats Checks",
        "AgentStatsCheckEnabled=$(Get-CfgVal 'AgentStatsCheckEnabled' 'true')",
        "",
        "# ======================================================================",
        "# Per-Connector Overrides & Granular Check Controls",
        "# ======================================================================"
    )

    foreach ($path in $targetPaths) {
        $cName = Split-Path $path -Leaf
        $configLines += @(
            "",
            "# --- Connector: $cName ---",
            "${cName}.enabled=$(Get-CfgVal "${cName}.enabled" 'true')",
            "${cName}.agentstats.enabled=$(Get-CfgVal "${cName}.agentstats.enabled" 'true')",
            "${cName}.agentstats.missinglog.enabled=$(Get-CfgVal "${cName}.agentstats.missinglog.enabled" 'true')",
            "${cName}.agentstats.cache.enabled=$(Get-CfgVal "${cName}.agentstats.cache.enabled" 'true')",
            "${cName}.agentstats.threads.enabled=$(Get-CfgVal "${cName}.agentstats.threads.enabled" 'true')",
            "${cName}.agentstats.sent.enabled=$(Get-CfgVal "${cName}.agentstats.sent.enabled" 'true')",
            "${cName}.agentstats.throughput.enabled=$(Get-CfgVal "${cName}.agentstats.throughput.enabled" 'true')",
            "${cName}.pattern.enabled=$(Get-CfgVal "${cName}.pattern.enabled" 'true')",
            "${cName}.eps.enabled=$(Get-CfgVal "${cName}.eps.enabled" 'true')",
            "${cName}.min_eps=$(Get-CfgVal "${cName}.min_eps" '0.1')",
            "${cName}.max_eps=$(Get-CfgVal "${cName}.max_eps" '500')",
            "${cName}.memory.enabled=$(Get-CfgVal "${cName}.memory.enabled" 'true')",
            "${cName}.rawevent.enabled=$(Get-CfgVal "${cName}.rawevent.enabled" 'true')",
            "${cName}.dropcount.enabled=$(Get-CfgVal "${cName}.dropcount.enabled" 'true')",
            "${cName}.postaggslc.enabled=$(Get-CfgVal "${cName}.postaggslc.enabled" 'true')",
            "${cName}.recvstatus.enabled=$(Get-CfgVal "${cName}.recvstatus.enabled" 'true')"
        )
    }

    $configLines | Set-Content $configFile -Encoding UTF8
    Write-Log "Configuration successfully saved to: $configFile" -Level "INFO" -Color Green
}


# ##############################################################################
#  MAIN CONTROLLER
# ##############################################################################

if ($Status) {
    if (-not (Test-Path $stateFilePath)) { Write-Host "No monitor state file found at: $stateFilePath" -ForegroundColor Yellow; exit 0 }
    $rawJson = Get-Content $stateFilePath -Raw -ErrorAction SilentlyContinue
    $parsed = $rawJson | ConvertFrom-Json
    foreach ($prop in ($parsed.psobject.Properties | Sort-Object Name)) {
        $keyName = $prop.Name
        if (-not [string]::IsNullOrWhiteSpace($Connector) -and $keyName -notlike "*$Connector*") { continue }
        $val = $prop.Value
        $isAlarm = if ($val -is [PSCustomObject]) { [bool]$val.isAlarm } else { [bool]$val }
        if ($Alert -and -not $isAlarm) { continue }
        $color = if ($isAlarm) { "Red" } else { "Green" }
        Write-Host ("[{0,-5}] {1,-45}" -f ($(if($isAlarm){"ALERT"}else{"CLEAR"}), $keyName)) -ForegroundColor $color
        if ($Message -and $val -is [PSCustomObject] -and $val.message) { Write-Host ("        Message: {0}" -f $val.message) -ForegroundColor DarkGray }
    }
    exit 0
}

if ($SendTest) {
    if (-not (Test-Path $configFile)) {
        Write-Host "Config file not found at: $configFile - run with -UpdateConfig first." -ForegroundColor Red
        exit 1
    }

    $sysEnabled = [system.boolean]::Parse((Get-CfgVal "SyslogEnabled" "true"))
    $sysSrv     = Get-CfgVal "SyslogServer" $defaultSyslogServer
    $sysPort    = Get-CfgVal "SyslogPort" "514"
    $sysSource  = if ($existingConfig.ContainsKey("SyslogServer") -and -not [string]::IsNullOrWhiteSpace($existingConfig["SyslogServer"])) { "LogMonitor.properties" } else { "built-in default for $currentHost" }

    if ($sysEnabled) {
        Write-Host "Sending test alarm via syslog to ${sysSrv}:${sysPort} (source: $sysSource)..." -ForegroundColor Cyan
        Write-Log "SendTest: syslog target ${sysSrv}:${sysPort} (source: $sysSource)" -Level "INFO" -Color Cyan
    } else {
        Write-Host "SyslogEnabled=false in LogMonitor.properties - test alarm will NOT be sent via syslog." -ForegroundColor Yellow
        Write-Log "SendTest: syslog disabled in config (SyslogEnabled=false)." -Level "WARN" -Color Yellow
    }

    Handle-AlertState -MonitorKey "daily_test_alarm" -EventID "ARC040" -IsAlarm $true -AlarmMessage "Scheduled daily test alarm (FUNK20)." -ClearMessage "OK" -ConfiguredSeverity "WARN" -CustomData @{ TestAlarmLastRunDate = (Get-Date).ToString("yyyy-MM-dd") } -ForceSend
    try { 
        foreach ($k in $previousState.Keys) { if (-not $currentState.ContainsKey($k)) { $currentState[$k] = $previousState[$k] } }
        $currentState | ConvertTo-Json | Set-Content -Path $stateFilePath -Encoding UTF8 
    } catch {}
    if ($script:syslogSkipRun) {
        Write-Host "WARNING: Test alarm could NOT be sent via syslog to ${sysSrv}:${sysPort}. See $scriptLogPath for details." -ForegroundColor Yellow
        Write-Host "Test alarm was written to alert log/Event Log only. Syslog will be retried on next run." -ForegroundColor Yellow
        exit 2
    }
    if ($sysEnabled) {
        Write-Host "Test alarm sent successfully via syslog to ${sysSrv}:${sysPort}." -ForegroundColor Green
    } else {
        Write-Host "Test alarm written to alert log/Event Log (syslog disabled)." -ForegroundColor Green
    }
    exit 0
}

$connectorsBase = Get-CfgVal "ConnectorsRootPath" "C:\arcsight\connectors"
$targetPaths = if ([string]::IsNullOrWhiteSpace($ConnectorPath)) {
    if (Test-Path $connectorsBase) {
        Get-ChildItem -Path $connectorsBase -Directory | Where-Object { (Test-Path (Join-Path $_.FullName "current\user\agent\agent.properties")) -or (Test-Path (Join-Path $_.FullName "current\logs")) } | Select-Object -ExpandProperty FullName
    } else { @() }
} else { @($ConnectorPath) }

if ($UpdateConfig) {
    # Generera konfiguration men bevara befintliga värden
    Invoke-ConfigGen
}

$overallHasErrors = $false

if ($Check) {
    if (-not (Test-Path $configFile)) { exit 1 }
    Write-Log "Starting monitoring check against $configFile" -Level "INFO" -Color Cyan

    # -------------------------------------------------------------------------
    # FUNKTION: Generera CLEAR för inaktiverade övervakningar
    # -------------------------------------------------------------------------
    foreach ($monitorKey in $previousState.Keys) {
        $stateObj = $previousState[$monitorKey]
        $wasAlarm = if ($stateObj -is [PSCustomObject]) { [bool]$stateObj.isAlarm } else { [bool]$stateObj }
        
        if ($wasAlarm) {
            $shouldClear = $false
            
            # Identifiera om övervakningen tillhör en inaktiverad connector eller global kontroll
            foreach ($path in $targetPaths) {
                $cName = Split-Path $path -Leaf
                if ($monitorKey.StartsWith("${cName}_", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $connEnabled = (Get-CfgVal "${cName}.enabled" "true").ToLower() -ne "false"
                    if (-not $connEnabled) {
                        $shouldClear = $true
                        break
                    }
                    
                    # Kolla delkontroller per connector
                    if ($monitorKey -like "*_eps" -and (Get-CfgVal "${cName}.eps.enabled" "true").ToLower() -eq "false") { $shouldClear = $true }
                    if ($monitorKey -like "*_pattern_error" -and (Get-CfgVal "${cName}.pattern.enabled" "true").ToLower() -eq "false") { $shouldClear = $true }
                    if ($monitorKey -like "*_jvm_memory" -and (Get-CfgVal "${cName}.memory.enabled" "true").ToLower() -eq "false") { $shouldClear = $true }
                    if ($monitorKey -like "*_throughput_t" -and (Get-CfgVal "${cName}.agentstats.throughput.enabled" "true").ToLower() -eq "false") { $shouldClear = $true }
                    if ($monitorKey -like "*_sent_s" -and (Get-CfgVal "${cName}.agentstats.sent.enabled" "true").ToLower() -eq "false") { $shouldClear = $true }
                    if ($monitorKey -like "*_cache_c" -and (Get-CfgVal "${cName}.agentstats.cache.enabled" "true").ToLower() -eq "false") { $shouldClear = $true }
                    if ($monitorKey -like "*_missing_log" -and (Get-CfgVal "${cName}.agentstats.missinglog.enabled" "true").ToLower() -eq "false") { $shouldClear = $true }
                }
            }

            # Kolla globala kontroller
            if ($monitorKey -eq "syslog_service" -and (Get-CfgVal "SyslogEnabled" "true").ToLower() -eq "false") { $shouldClear = $true }
            if ($monitorKey -eq "eventlog_service" -and (Get-CfgVal "EventLogEnabled" "true").ToLower() -eq "false") { $shouldClear = $true }

            if ($shouldClear) {
                Write-Log "Monitor '$monitorKey' was disabled in config while in ALARM state. Automatically issuing CLEAR." -Level "INFO" -Color Yellow
                Handle-AlertState -MonitorKey $monitorKey -EventID "CLR000" -IsAlarm $false -AlarmMessage "OK" -ClearMessage "Monitor was disabled in configuration." -ConfiguredSeverity "INFO"
            }
        }
    }

    Invoke-HostChecks
    Invoke-ConnectorChecks

    try {
        if ($previousState.ContainsKey("daily_test_alarm") -and -not $currentState.ContainsKey("daily_test_alarm")) {
            $currentState["daily_test_alarm"] = $previousState["daily_test_alarm"]
        }
        $currentState | ConvertTo-Json | Set-Content -Path $stateFilePath -Encoding UTF8
    } catch {}
}

if ($overallHasErrors) { exit 2 } else { exit 0 }
