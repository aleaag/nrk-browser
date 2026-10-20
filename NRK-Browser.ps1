<#
.SYNOPSIS
    NRK Browser - browse tv.nrk.no categories and the A-Å programme index,
    watch, listen and download (FFmpeg) - see README.md.

.DESCRIPTION
    Windows PowerShell 5.1+ / PowerShell 7+ (GUI needs Windows).

    Endpoints used (verified against psapi.nrk.no, October 2026):
      /tv/pages                              -> { pageListItems: [ {id,title,pageType,_links} ] }
      /tv/pages/{pageId}                     -> { sections: [ {type:'included', included:{title,plugs:[...]}} ] }
      /medium/tv/letters                     -> [ {id:'A',title:'A',availableInNorway:..} ]  (the A-Å list on tv.nrk.no/programmer)
      /medium/tv/letters/{l}/indexelements   -> [ {id,title,type:'series'|'programme',description,isGeoBlocked} ]
      /tv/catalog/series/{seriesId}          -> series + _links.seasons[] (+ _links.extramaterial)
      /tv/catalog/programs/{programId}       -> programme metadata
      /playback/manifest/program/{programId} -> playability ('playable' / 'nonPlayable' + reason)

    Every request, its HTTP status, size and timing, plus all errors with stack
    traces, are written to a daily log file (default: %LOCALAPPDATA%\NRK-Browser\logs).

.PARAMETER LogDir
    Folder for log files. Default: %LOCALAPPDATA%\NRK-Browser\logs (falls back to %TEMP%).

.PARAMETER DumpResponses
    Also save every raw JSON response to <LogDir>\responses\ for inspection.

.NOTES
    Startup checks these components and asks before installing any of them:
      Microsoft Edge WebView2 Runtime  (embedded NRK player engine; winget)
      WebView2 SDK for .NET            (nuget.org, stored in %LOCALAPPDATA%\NRK-Browser)
      FFmpeg                           (downloads; winget Gyan.FFmpeg)
      hls.js                           (the audio bar and the built-in video player)
      winget                           (only if needed to install the above)
    The app never needs to run as administrator.

.PARAMETER ShowConsole
    Keep the PowerShell console window visible (it is hidden while the app runs by default).

.PARAMETER Tray
    Start hidden in the system tray (used by the "Start with Windows" shortcut).

.PARAMETER UpdatedFrom
    Set by the updater when it restarts the app after an update.

.PARAMETER SelfTest
    No GUI. Calls each endpoint once, prints a summary and writes the log.
    Run this first if the browser shows nothing.

.PARAMETER NoGui
    Loads everything and stops before any window (for tests and scripts that dot-source this file).

.PARAMETER Index
    No window. Runs the indexer: walks every TV and radio folder slowly into the local
    cache (one request at a time). Started from the Indexer window or a daily scheduled task.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NRK-Browser.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\NRK-Browser.ps1 -SelfTest -DumpResponses
#>
[CmdletBinding()]
param(
    [string] $LogDir,
    [switch] $DumpResponses,
    [switch] $SelfTest,
    [switch] $Index,                # no window: walk the whole catalogue slowly into the cache (the Indexer)
    [switch] $NoGui,
    [switch] $ShowConsole,
    [switch] $Tray,                 # start hidden in the system tray (used by "Start with Windows")
    [string] $UpdatedFrom = '',     # set by the updater when it restarts the app
    [string] $UpdateResult = '',    # result file written by the update helper
    [string] $Play = ''             # 2.9.0: start a channel, e.g. radio:p1 or tv:nrk1 (the taskbar jump list)
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Windows PowerShell draws a (hidden) progress bar per web request: much slower
$script:AppVersion      = '2.9.4'   # the updater compares this line with the copy on GitHub
# Updates: the script on GitHub is both the version check and the update. Its version line
# is compared with ours; when it is newer, that same download is checked and installed.
$script:UpdateRepo      = 'aleaag/nrk-browser'
$script:UpdateBranch    = 'main'
$script:UpdateScriptUrl = "https://raw.githubusercontent.com/$($script:UpdateRepo)/refs/heads/$($script:UpdateBranch)/NRK-Browser.ps1"
$script:ApiBase      = 'https://psapi.nrk.no'
$script:WebBase      = 'https://tv.nrk.no'
$script:UserAgent    = "NRK-Browser/$($script:AppVersion) (PowerShell $($PSVersionTable.PSVersion))"
$script:DumpResponses = [bool]$DumpResponses
$script:Cache        = @{}
$script:ScriptDir    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

#region ---------- Logging ----------------------------------------------------

$script:LogCount = 0          # lines logged this session (the Logs window adds only what is new)
$script:LogBuf = New-Object System.Text.StringBuilder; $script:LogBuffered = $false
# One log file per day (logs\NRK-Browser_<date>.log), kept for LogDays days (settings.json,
# default 3). Removing the oldest day is deleting a file; the Logs window shows all days merged.
function Initialize-Log {
    param([string] $Dir)
    $candidates = @()
    if ($Dir) { $candidates += $Dir }
    # the app's own folder, installed or not (never next to a downloaded script)
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'NRK-Browser\logs') }
    $candidates += (Join-Path ([IO.Path]::GetTempPath()) 'NRK-Browser\logs')

    # logs on disk are optional (Logs window / Options: "Save logs to disk", off by default);
    # this session's lines are always kept in memory for the Logs window
    $script:LogToDisk = [bool]$script:ForceLogToDisk
    if (-not $script:LogToDisk) {
        try { $sf = Join-Path $env:LOCALAPPDATA 'NRK-Browser\settings.json'; if (Test-Path -LiteralPath $sf) { $script:LogToDisk = [bool]((Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json).Logging) } } catch { }
    }
    foreach ($c in $candidates) {
        try {
            $file = Join-Path $c ('NRK-Browser_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
            if ($script:LogToDisk) {
                New-Item -ItemType Directory -Path $c -Force | Out-Null
                [IO.File]::AppendAllText($file, '', (New-Object Text.UTF8Encoding($false)))
            }
            $script:LogDir  = $c
            $script:LogFile = $file
            if ($script:LogToDisk) { Write-LogPending }
            return
        } catch { continue }
    }
    $script:LogFile = $null
}

function Add-LogText([string] $Text) {
    # Until the main window runs (and always in the indexer) every line goes to the file at once.
    # After that, lines are collected and written once a second (Start-LogFlushTimer): one file
    # open per second instead of one per line. The file is opened for each write, so the indexer
    # (another process writing the same day's file) and this app never overwrite each other.
    if (-not $script:LogFile) { return }
    if ($script:LogBuffered) { [void]$script:LogBuf.Append($Text); if ($script:LogBuf.Length -gt 262144) { Close-LogWriter }; return }
    Write-LogFileText $Text
}

function Write-LogFileText([string] $Text) {
    $enc = New-Object Text.UTF8Encoding($false)
    try { [IO.File]::AppendAllText($script:LogFile, $Text, $enc) }
    catch { try { New-Item -ItemType Directory -Path (Split-Path -Parent $script:LogFile) -Force | Out-Null; [IO.File]::AppendAllText($script:LogFile, $Text, $enc) } catch { } }
}

function Close-LogWriter {
    # write what is collected (exit, Clear log, switching off, the 1 s timer)
    if (-not $script:LogBuf -or -not $script:LogBuf.Length) { return }
    $t = $script:LogBuf.ToString(); [void]$script:LogBuf.Clear()
    if ($script:LogToDisk -and $script:LogFile) { Write-LogFileText $t }
}

function Start-LogFlushTimer {
    if ($script:IndexMode -or $script:LogFlushTimer) { return }
    $script:LogBuffered = $true
    $script:LogFlushTimer = New-Object System.Windows.Forms.Timer
    $script:LogFlushTimer.Interval = 1000
    $script:LogFlushTimer.Add_Tick({ Close-LogWriter })
    $script:LogFlushTimer.Start()
}

function Write-LogPending {
    # lines from before logging to disk was switched on (this session) go into the file first
    if (-not $script:LogPending -or -not $script:LogPending.Count -or -not $script:LogFile) { return }
    try {
        Add-LogText (($script:LogPending -join [Environment]::NewLine) + [Environment]::NewLine)
        $script:LogPending.Clear()
    } catch { }
}

function Set-LogToDisk([bool] $On) {
    $script:LogToDisk = $On
    if ($On) { Write-LogPending; Write-Log INFO 'Logging to disk switched on' } else { Close-LogWriter; Write-Log INFO 'Logging to disk switched off (this session is kept in memory only)' }
}

function Write-Log {
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'DL')] [string] $Level = 'INFO',
        [string] $Message
    )
    if ($script:IndexMode -and $Level -eq 'DEBUG') { return }   # keep the indexer's log readable
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    # always in memory (the Logs window's "This session"), on disk only when switched on
    if (-not $script:LogMem) { $script:LogMem = New-Object System.Collections.Generic.List[string]; $script:LogPending = New-Object System.Collections.Generic.List[string] }
    $script:LogMem.Add($line); $script:LogCount++; if ($script:LogMem.Count -gt 6000) { $script:LogMem.RemoveRange(0, 1000) }
    if ($script:LogToDisk -and $script:LogFile) {
        Add-LogText ($line + [Environment]::NewLine)
    } elseif ($null -eq $script:LogToDisk -or -not $script:LogToDisk) {
        $script:LogPending.Add($line); if ($script:LogPending.Count -gt 6000) { $script:LogPending.RemoveRange(0, 1000) }
    }
    Write-Verbose $line
}

function Write-LogException {
    param($ErrorRecord, [string] $Context)
    $e = $ErrorRecord.Exception
    if ($e -and $e.Message -eq 'NRKB-NEEDFETCH') { return }   # (a background job asking for a page: not an error)
    Write-Log ERROR ("{0}: {1}: {2}" -f $Context, $e.GetType().FullName, $e.Message)
    $inner = $e.InnerException
    while ($inner) {
        Write-Log ERROR ("  inner: {0}: {1}" -f $inner.GetType().FullName, $inner.Message)
        $inner = $inner.InnerException
    }
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        Write-Log DEBUG ('  at: ' + ($ErrorRecord.InvocationInfo.PositionMessage -replace '\r?\n', ' | '))
    }
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Log DEBUG ('  stack: ' + ($ErrorRecord.ScriptStackTrace -replace '\r?\n', ' <- '))
    }
}

function Write-EnvironmentInfo {
    Write-Log INFO ('===== NRK-Browser {0} started =====' -f $script:AppVersion)
    Write-Log INFO ('PowerShell {0} ({1}), OS: {2}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, [Environment]::OSVersion.VersionString)
    Write-Log INFO ('.NET: {0}; 64-bit process: {1}; culture: {2}' -f [Environment]::Version, [Environment]::Is64BitProcess, (Get-Culture).Name)
    Write-Log INFO ('Script: {0}' -f $(if ($PSCommandPath) { $PSCommandPath } else { '(not from file)' }))
    Write-Log INFO ('Log file: {0}; DumpResponses={1}' -f $script:LogFile, $script:DumpResponses)
    try { Write-Log INFO ('SecurityProtocol: {0}' -f [Net.ServicePointManager]::SecurityProtocol) } catch { }
    try {
        $proxy = [Net.WebRequest]::DefaultWebProxy
        if ($proxy) {
            $p = $proxy.GetProxy([uri]$script:ApiBase)
            Write-Log INFO ('System proxy for {0}: {1}' -f $script:ApiBase, $(if ($p -and $p.AbsoluteUri -ne ($script:ApiBase + '/')) { $p.AbsoluteUri } else { '(direct)' }))
        }
    } catch { Write-Log DEBUG "Could not query proxy: $($_.Exception.Message)" }
}

#endregion

#region ---------- HTTP / JSON -------------------------------------------------

function ConvertTo-PSObjectDeep {
    # Used only by the Windows PowerShell 5.1 fallback JSON parser.
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-PSObjectDeep $InputObject[$k] }
        return [pscustomobject]$h
    }
    if (($InputObject -is [Collections.IEnumerable]) -and ($InputObject -isnot [string])) {
        $list = New-Object Collections.Generic.List[object]
        foreach ($x in $InputObject) { $list.Add((ConvertTo-PSObjectDeep $x)) }
        return , $list.ToArray()
    }
    return $InputObject
}

function ConvertFrom-JsonSafe {
    param([string] $Json, [string] $Source)
    try {
        return ($Json | ConvertFrom-Json)
    } catch {
        if ($PSVersionTable.PSEdition -ne 'Desktop') { throw }
        # Windows PowerShell 5.1 can choke on very large documents (category pages
        # are several MB). Retry with an unlimited JavaScriptSerializer.
        Write-Log WARN ("ConvertFrom-Json failed for {0} ({1}); retrying with JavaScriptSerializer" -f $Source, $_.Exception.Message)
        Add-Type -AssemblyName System.Web.Extensions
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $ser.RecursionLimit = 512
        return (ConvertTo-PSObjectDeep ($ser.DeserializeObject($Json)))
    }
}

# ---- disk cache ---------------------------------------------------------------------
# NRK responses that are not live are kept in <app data>\cache\api. A saved copy is used
# straight away; when it is older than its refresh time, a fresh copy is fetched in the
# background for next time ("stale while revalidate"). Live lists, programme guides and
# playback manifests (their stream addresses expire) are never cached.
$script:CacheBypassUntil = [datetime]::MinValue   # Reload / self-test: go to NRK directly
$script:ApiRefresh = @{}
$script:ApiRefreshTimer = $null

# Refresh choices (Options > "Refresh saved NRK data"): minutes for pages / for catalogues
$script:CacheModes = [ordered]@{
    Off    = @{ Label = 'Always fetch from NRK (no cache)'; Pages = 0;      Catalog = 0 }
    Fast   = @{ Label = 'Every 15 minutes';                 Pages = 15;     Catalog = 15 }
    Normal = @{ Label = 'Normal (pages hourly, catalogues every 12 hours)'; Pages = 60; Catalog = 720 }
    Slow   = @{ Label = 'Every 6 hours';                    Pages = 360;    Catalog = 1440 }
    Daily  = @{ Label = 'Once a day';                       Pages = 1440;   Catalog = 1440 }
    Manual = @{ Label = 'Only when I press Reload';         Pages = 525600; Catalog = 525600 }
}
$script:CacheMode = 'Normal'   # read from the settings at startup

function Get-ApiCacheTtl([string] $Uri) {
    # minutes before a saved copy is refreshed; 0 = never cache
    $p = $Uri -replace '^https?://[^/]+', ''
    if ($p -match '^/(tv|radio)/live|^/epg/|^/playback/|/userdata/|/ipcheck|^/radio/channels/') { return 0 }
    $m = $script:CacheModes[$script:CacheMode]; if (-not $m) { $m = $script:CacheModes['Normal'] }
    if ($p -match '^/(tv|radio)/pages') { return $m.Pages }   # front and category pages change during the day
    return $m.Catalog                                          # catalogues, seasons, episodes, A-Å
}

function Get-CacheFile([string] $Key, [string] $Kind = 'api', [string] $Ext = '.json') {
    $sha = [Security.Cryptography.SHA1]::Create()
    $hex = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key)) | ForEach-Object { $_.ToString('x2') })
    $sha.Dispose()
    $dir = Join-Path (Join-Path $script:AppDataDir 'cache') $Kind
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return Join-Path $dir ($hex + $Ext)
}

function Save-CacheFile([string] $File, [byte[]] $Bytes) {
    try {
        $tmp = "$File.$PID.tmp"
        [IO.File]::WriteAllBytes($tmp, $Bytes)
        Move-Item -LiteralPath $tmp -Destination $File -Force
    } catch { Write-Log DEBUG "cache write failed for ${File}: $($_.Exception.Message)" }
}

function Request-ApiRefresh([string] $Uri, [string] $File) {
    # background refresh of a stale cache entry (GUI only; at most a few at a time)
    if ($script:ApiRefresh.ContainsKey($Uri) -or $script:ApiRefresh.Count -ge 6) { return }
    if (-not ('System.Windows.Forms.Timer' -as [type])) { return }
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = $script:UserAgent
        $wc.Headers['Accept'] = 'application/json'
        $script:ApiRefresh[$Uri] = @{ Client = $wc; File = $File; Task = $wc.DownloadDataTaskAsync($Uri); Started = Get-Date }
        if (-not $script:ApiRefreshTimer) {
            $script:ApiRefreshTimer = New-Object System.Windows.Forms.Timer
            $script:ApiRefreshTimer.Interval = 500
            $script:ApiRefreshTimer.Add_Tick({
                foreach ($u in @($script:ApiRefresh.Keys)) {
                    $r = $script:ApiRefresh[$u]
                    if (-not $r.Task.IsCompleted) {
                        # stuck (no answer in 30 s): give the slot back
                        if (((Get-Date) - $r.Started).TotalSeconds -gt 30) { Write-Log DEBUG "cache refresh timed out: $u"; try { $r.Client.CancelAsync() } catch { }; try { $r.Client.Dispose() } catch { }; $script:ApiRefresh.Remove($u) }
                        continue
                    }
                    if ($r.Task.IsFaulted) { Write-Log DEBUG "cache refresh failed: $u ($($r.Task.Exception.GetBaseException().Message))" }
                    else { Save-CacheFile $r.File $r.Task.Result; Write-Log DEBUG ('cache refreshed: {0} ({1:N0} bytes)' -f $u, $r.Task.Result.Length) }
                    $r.Client.Dispose(); $script:ApiRefresh.Remove($u)
                }
                if ($script:ApiRefresh.Count -eq 0) { $script:ApiRefreshTimer.Stop() }
            })
        }
        $script:ApiRefreshTimer.Start()
    } catch { Write-Log DEBUG "cache refresh could not start for ${Uri}: $($_.Exception.Message)" }
}

# ---- prefetch: load what you are likely to open next, quietly, into the same cache
# High: the folders and files inside what you just opened (look one level ahead).
# Low:  after startup, every category page and A-Å letter (warm the top levels).
# Up to 3 downloads at a time; anything already saved and fresh is skipped.
$script:Prefetch = @{ High = (New-Object System.Collections.Queue); Low = (New-Object System.Collections.Queue)
                      Active = @{}; Seen = @{}; Timer = $null; Done = 0 }

function Add-Prefetch {
    param([string[]] $Paths, [switch] $Low, [switch] $Image)
    if (-not $script:AppDataDir -or -not ('System.Windows.Forms.Timer' -as [type])) { return }
    if ((Get-Date) -lt $script:CacheBypassUntil) { return }      # Reload is fetching everything anyway
    $pf = $script:Prefetch
    $added = 0
    foreach ($p in $Paths) {
        if (-not $p) { continue }
        $uri = if ($p -match '^https?://') { $p } else { $script:ApiBase + $p }
        if ($pf.Seen.ContainsKey($uri)) { continue }
        if ($Image) { $file = Get-CacheFile $uri 'img' '.img'; if (Test-Path -LiteralPath $file) { continue } }
        else {
            $ttl = Get-ApiCacheTtl $uri
            if ($ttl -le 0) { continue }                           # never cached (or caching off)
            $file = Get-CacheFile $uri
            if ((Test-Path -LiteralPath $file) -and ((Get-Date) - (Get-Item -LiteralPath $file).LastWriteTime).TotalMinutes -lt $ttl) { continue }
        }
        $pf.Seen[$uri] = $true
        $job = @{ Uri = $uri; File = $file }
        if ($Low) { $pf.Low.Enqueue($job) } else { $pf.High.Enqueue($job) }
        $added++
    }
    if ($added -eq 0) { return }
    if (-not $pf.Timer) {
        $pf.Timer = New-Object System.Windows.Forms.Timer
        $pf.Timer.Interval = 250
        $pf.Timer.Add_Tick({ Update-Prefetch })
    }
    $pf.Timer.Start()
}

function Update-Prefetch {
    $pf = $script:Prefetch
    foreach ($u in @($pf.Active.Keys)) {
        $j = $pf.Active[$u]
        if (-not $j.Task.IsCompleted) {
            if (((Get-Date) - $j.Started).TotalSeconds -gt 30) { try { $j.Client.CancelAsync() } catch { }; try { $j.Client.Dispose() } catch { }; $pf.Active.Remove($u); $pf.Seen.Remove($u) }
            continue
        }
        if (-not $j.Task.IsFaulted) { Save-CacheFile $j.File $j.Task.Result; $pf.Done++ }
        $j.Client.Dispose(); $pf.Active.Remove($u); $pf.Seen.Remove($u)
    }
    while ($pf.Active.Count -lt 3 -and ($pf.High.Count -gt 0 -or $pf.Low.Count -gt 0)) {
        $j = if ($pf.High.Count -gt 0) { $pf.High.Dequeue() } else { $pf.Low.Dequeue() }
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers['User-Agent'] = $script:UserAgent
            $j.Client = $wc; $j.Task = $wc.DownloadDataTaskAsync($j.Uri); $j.Started = Get-Date
            $pf.Active[$j.Uri] = $j
        } catch { $pf.Seen.Remove($j.Uri) }
    }
    if ($pf.Active.Count -eq 0 -and $pf.High.Count -eq 0 -and $pf.Low.Count -eq 0) {
        $pf.Timer.Stop()
        if ($pf.Done) { Write-Log DEBUG "Prefetch: $($pf.Done) item(s) saved ahead"; $pf.Done = 0 }
    }
}

function Request-FolderPrefetch {
    # what is inside a folder that was just loaded: its sub-folders' data
    param($Node)
    $tag = $Node.Tag
    $paths = @()
    switch ($tag.Kind) {
        { $_ -in 'category', 'letter' } { $paths = @($tag.Items | Where-Object Type -eq 'series' | Select-Object -First 60 | ForEach-Object { Get-ApiPath tvseries -Id $_.Id }) }
        { $_ -in 'radiocategory', 'radioletter' } { $paths = @($tag.Items | Where-Object Type -eq 'radioseries' | Select-Object -First 60 | ForEach-Object { Get-ApiPath radioseries -Id $_.Id -Sub $_.Kind }) }
        'series' { $paths = @($tag.Info.Seasons | ForEach-Object { Get-ApiPath tvseason -Id $tag.Item.Id -Sub $_.Name }) }
        'radioseries' { $paths = @($tag.Info.Seasons | Select-Object -First 40 | ForEach-Object { Get-ApiPath radioepisodes -Id $_.Href -Newest:$_.Newest }) }
    }
    if ($paths.Count) { Add-Prefetch $paths }
}

function Request-FilesPrefetch {
    # the files now in the list: their details and pictures, so clicking one is instant
    $files = @($script:Files | Select-Object -First 40)
    $details = @($files | Where-Object { $_.Type -in 'program', 'episode' } | ForEach-Object { Get-ApiPath tvprogram -Id $_.Id })
    if ($details.Count) { Add-Prefetch $details }
    $imgs = @($files | ForEach-Object { if ($_.ImageUrl) { $_.ImageUrl } elseif ($_.SeriesItem -and $_.SeriesItem.ImageUrl) { $_.SeriesItem.ImageUrl } } | Select-Object -Unique)
    if ($imgs.Count) { Add-Prefetch $imgs -Image }
}

function Request-WarmPrefetch {
    # after startup: every category page and A-Å letter, behind anything you open yourself
    $paths = @()
    foreach ($n in @($script:CatsNode.Nodes)) { if ($n.Tag.Kind -eq 'category') { $paths += Get-ApiPath tvpage -Id $n.Tag.Id } }
    foreach ($n in @($script:LettersNode.Nodes)) { if ($n.Tag.Kind -eq 'letter') { $paths += Get-ApiPath tvletter -Id $n.Tag.Id } }
    foreach ($n in @($script:RadioCatsNode.Nodes)) { if ($n.Tag.Kind -eq 'radiocategory') { $paths += Get-ApiPath radiopage -Id $n.Tag.Id } }
    foreach ($n in @($script:RadioLettersNode.Nodes)) { if ($n.Tag.Kind -eq 'radioletter') { $paths += Get-ApiPath radioletter -Id $n.Tag.Id } }
    if ($paths.Count) { Write-Log INFO "Prefetch: warming $($paths.Count) category and letter pages in the background"; Add-Prefetch $paths -Low }
}

function Measure-CacheSize {
    # adds up the cache with .NET directly (much faster than Get-ChildItem for 100 000 files); saved in cache\size.txt
    $dir = Join-Path $script:AppDataDir 'cache'
    $sum = 0L
    if (Test-Path -LiteralPath $dir) {
        try { foreach ($f in [IO.Directory]::EnumerateFiles($dir, '*', [IO.SearchOption]::AllDirectories)) { try { $sum += (New-Object IO.FileInfo($f)).Length } catch { } } } catch { }
        try { [IO.File]::WriteAllText((Join-Path $dir 'size.txt'), [string]$sum) } catch { }
    }
    return $sum
}

function Get-CacheSize {
    # the size saved by the last clean-up (fast); counted now only when there is none
    $file = Join-Path (Join-Path $script:AppDataDir 'cache') 'size.txt'
    try { if (Test-Path -LiteralPath $file) { return [long]([IO.File]::ReadAllText($file).Trim()) } } catch { }
    return Measure-CacheSize
}

function Clear-AppCache {
    $dir = Join-Path $script:AppDataDir 'cache'
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    $script:Cache = @{}
    Write-Log INFO 'Cache cleared'
}

function Optimize-AppCache {
    # drop entries nobody has used for 30 days, and keep images under ~300 MB (once a day, see Shown)
    $dir = Join-Path $script:AppDataDir 'cache'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $old = (Get-Date).AddDays(-30)
    $n = 0
    foreach ($path in [IO.Directory]::EnumerateFiles($dir, '*', [IO.SearchOption]::AllDirectories)) {
        try {
            $f = New-Object IO.FileInfo($path)
            if ($f.LastAccessTime -lt $old -and $f.LastWriteTime -lt $old -and $f.Name -ne 'size.txt') { $f.Delete(); $n++ }
        } catch { }
    }
    $img = Join-Path $dir 'img'
    if (Test-Path -LiteralPath $img) {
        $files = @(Get-ChildItem -LiteralPath $img -File | Sort-Object LastWriteTime -Descending)
        $sum = 0L
        foreach ($f in $files) { $sum += $f.Length; if ($sum -gt 300MB) { try { Remove-Item -LiteralPath $f.FullName -Force; $n++ } catch { } } }
    }
    if ($n) { Write-Log INFO "Cache: removed $n old file(s)" }
    [void](Measure-CacheSize)
}

function Test-UiPump {
    # true when a GET may keep the window alive while it waits (the main window's own thread,
    # its message loop running, not the indexer or the self-test, and not already waiting)
    if ($script:IndexMode -or $script:Pumping -or $script:ApiJob) { return $false }
    if (-not ('System.Windows.Forms.Application' -as [type]) -or -not [System.Windows.Forms.Application]::MessageLoop) { return $false }
    $f = Get-Variable -Name form -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if (-not $f -or $f.IsDisposed -or -not $f.IsHandleCreated -or $f.InvokeRequired) { return $false }
    if (-not ('NrkInputBlock' -as [type])) {
        if ($script:PumpFailed) { return $false }
        try {
            $refs = if ($PSVersionTable.PSEdition -eq 'Desktop') { @('System.Windows.Forms') }
                    else { [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { -not $_.IsDynamic -and $_.Location -and $_.GetName().Name -match '^System\.(Windows\.Forms(\.Primitives)?|Runtime|ComponentModel\.Primitives|Private\.CoreLib)$' } | ForEach-Object Location }
            Add-Type -ReferencedAssemblies $refs -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;
// While a GET is waiting the window still paints, but clicks and keys are held back and sent
// again, in order, once it is done (no second action starts halfway through the first one, and
// nothing typed or clicked meanwhile is lost). Timer ticks are skipped (they come again).
public class NrkInputBlock : IMessageFilter {
    struct Held { public IntPtr H; public int M; public IntPtr W; public IntPtr L; }
    readonly List<Held> held = new List<Held>();
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    public bool PreFilterMessage(ref Message m) {
        int x = m.Msg;
        if (x == 0x113) return true;
        bool input = (x >= 0x100 && x <= 0x109) || (x >= 0x200 && x <= 0x20E) || (x >= 0xA0 && x <= 0xAD);
        if (!input) return false;
        // (mouse moves are not kept: only where the pointer is now matters)
        if (x != 0x200 && x != 0xA0 && held.Count < 300) held.Add(new Held { H = m.HWnd, M = x, W = m.WParam, L = m.LParam });
        return true;
    }
    public void Release() {
        foreach (var h in held) PostMessage(h.H, h.M, h.W, h.L);
        held.Clear();
    }
}
'@
        } catch { $script:PumpFailed = $true; Write-Log DEBUG "Input filter not available, GETs wait without painting: $($_.Exception.Message)"; return $false }
    }
    if (-not $script:Http) {
        try {
            if (-not ('System.Net.Http.HttpClient' -as [type])) { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop }
            $h = New-Object System.Net.Http.HttpClientHandler
            $h.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
            $c = New-Object System.Net.Http.HttpClient($h)
            $c.Timeout = [TimeSpan]::FromSeconds(30)
            [void]$c.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $script:UserAgent)
            [void]$c.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'application/json')
            $script:Http = $c
        } catch { $script:PumpFailed = $true; return $false }
    }
    return $true
}

function Invoke-PumpedGet([string] $Uri) {
    # The GET runs while the window keeps painting (no "Not responding"). Returns
    # @{ Status; Bytes; ContentType }; throws with .Data['Status'] set on HTTP errors.
    $script:Pumping = $true
    $filter = New-Object NrkInputBlock
    [System.Windows.Forms.Application]::AddMessageFilter($filter)
    $old = $form.Cursor; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $task = $script:Http.GetAsync($Uri)
        while (-not $task.IsCompleted) { [System.Windows.Forms.Application]::DoEvents(); [void]$task.Wait(15) }
        if ($task.IsCanceled) { throw (New-Object TimeoutException("No answer from $Uri in 30 s")) }
        if ($task.IsFaulted) { $ex = $task.Exception.GetBaseException(); throw $ex }
        $resp = $task.Result
        try {
            $read = $resp.Content.ReadAsByteArrayAsync()
            while (-not $read.IsCompleted) { [System.Windows.Forms.Application]::DoEvents(); [void]$read.Wait(15) }
            $bytes = $read.Result
            $status = [int]$resp.StatusCode
            if (-not $resp.IsSuccessStatusCode) {
                $ex = New-Object System.Net.Http.HttpRequestException(('Response status code does not indicate success: {0} ({1}).' -f $status, $resp.ReasonPhrase))
                $ex.Data['Status'] = $status
                throw $ex
            }
            $ctype = if ($resp.Content.Headers.ContentType) { [string]$resp.Content.Headers.ContentType } else { '' }
            return @{ Status = $status; Bytes = $bytes; ContentType = $ctype }
        } finally { $resp.Dispose() }
    } finally {
        [System.Windows.Forms.Application]::RemoveMessageFilter($filter)
        try { $filter.Release() } catch { }
        $form.Cursor = $old
        $script:Pumping = $false
    }
}

# ---- background jobs: NRK pages fetched without the window waiting -------------------------
# Start-ApiJob runs $Work; whenever it needs a page that is not saved yet, Invoke-NrkApi stops it
# (NRKB-NEEDFETCH), the page is fetched in the background and $Work runs again from the start
# with that page at hand. When it gets through, $Done gets its result (on the window's thread).
# $Work must only read (no changes), since it may run several times.
$script:ApiJob = $null
# folders that list things from many places (no "next episode", no NRK order)
$script:MixedKinds = @('recent', 'search', 'newweek', 'expiring', 'continue', 'watchlater')
$script:ApiJobs = New-Object System.Collections.ArrayList   # (an ArrayList: a generic List refuses hashtables in Add - 'Argument types do not match')

function Start-ApiJob([string] $Name, [scriptblock] $Work, [scriptblock] $Done, [scriptblock] $Failed = $null, $State = $null) {
    $job = @{ Name = $Name; Work = $Work; Done = $Done; Failed = $Failed; State = $State; Got = @{}; Need = $null; Fetch = $null; Runs = 0; Canceled = $false }
    [void]$script:ApiJobs.Add($job)
    if (-not $script:ApiJobTimer) {
        $script:ApiJobTimer = New-Object System.Windows.Forms.Timer
        $script:ApiJobTimer.Interval = 100
        $script:ApiJobTimer.Add_Tick({ Step-ApiJobs })
    }
    $script:ApiJobTimer.Start()
    return $job
}

function Step-ApiJobs {
    if ($script:ApiJob) { return }   # (one at a time)
    foreach ($job in @($script:ApiJobs)) {
        if ($job.Canceled) { [void]$script:ApiJobs.Remove($job); continue }
        $f = $job.Fetch
        if ($f) {
            if (-not $f.Task.IsCompleted) {
                if ($f.Watch.Elapsed.TotalSeconds -gt 30) { try { $f.Client.CancelAsync() } catch { } }
                continue
            }
            $entry = @{}
            if ($f.Task.IsFaulted -or $f.Task.IsCanceled) {
                $ex = if ($f.Task.Exception) { $f.Task.Exception.GetBaseException() } else { New-Object TimeoutException("No answer from $($f.Uri) in 30 s") }
                $code = 'n/a'; try { if ($ex.Response) { $code = [int]$ex.Response.StatusCode } } catch { }
                Write-Log ERROR ('GET {0} FAILED (background, HTTP {1}): {2}' -f $f.Uri, $code, $ex.Message)
                $entry.Error = $ex
            } else {
                $entry.Bytes = $f.Task.Result
                Write-Log INFO ('GET {0} -> {1:N0} bytes, {2} ms (background)' -f $f.Uri, $entry.Bytes.Length, $f.Watch.ElapsedMilliseconds)
                $cf = if ($script:AppDataDir -and (Get-ApiCacheTtl $f.Uri) -gt 0) { Get-CacheFile $f.Uri } else { $null }
                if ($cf) { try { [void](ConvertFrom-JsonSafe -Json ([Text.Encoding]::UTF8.GetString($entry.Bytes)) -Source $f.Uri); Save-CacheFile $cf $entry.Bytes } catch { } }
            }
            try { $f.Client.Dispose() } catch { }
            $job.Got[$f.Uri] = $entry; $job.Fetch = $null
        }
        # run it (again)
        $job.Need = $null; $job.Runs++
        $script:ApiJob = $job
        $result = $null; $err = $null
        try { $result = & $job.Work $job.State } catch { $err = $_ }
        finally { $script:ApiJob = $null }
        if ($job.Need -and $job.Runs -lt 400) {
            # a page is missing (even if $Work caught the signal itself): fetch it, then run again
            try {
                $wc = New-Object System.Net.WebClient
                $wc.Headers['User-Agent'] = $script:UserAgent; $wc.Headers['Accept'] = 'application/json'
                Write-Log DEBUG "GET $($job.Need) (background: $($job.Name))"
                $job.Fetch = @{ Uri = $job.Need; Client = $wc; Task = $wc.DownloadDataTaskAsync($job.Need); Watch = [Diagnostics.Stopwatch]::StartNew() }
            } catch { $job.Got[$job.Need] = @{ Error = $_.Exception } }
            continue
        }
        [void]$script:ApiJobs.Remove($job)
        if ($err) { if ($job.Failed) { try { & $job.Failed $err $job.State } catch { Write-LogException $_ $job.Name } } else { Write-LogException $err $job.Name } }
        else { try { & $job.Done $result $job.State } catch { Write-LogException $_ $job.Name } }
    }
    if (-not $script:ApiJobs.Count) { $script:ApiJobTimer.Stop() }
}

function Invoke-NrkApi {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $uri = if ($Path -match '^https?://') { $Path } else { $script:ApiBase + $Path }
    $job = $script:ApiJob
    if ($job -and $job.Got.ContainsKey($uri)) {
        # a background job (Start-ApiJob): this page was fetched for it meanwhile
        $hit = $job.Got[$uri]
        if ($hit.Error) { throw $hit.Error }
        return (ConvertFrom-JsonSafe -Json ([Text.Encoding]::UTF8.GetString($hit.Bytes)) -Source $uri)
    }
    $ttl = Get-ApiCacheTtl $uri
    $cacheFile = $null
    if ($ttl -gt 0 -and $script:AppDataDir) {
        $cacheFile = Get-CacheFile $uri
        if ((Get-Date) -ge $script:CacheBypassUntil -and (Test-Path -LiteralPath $cacheFile)) {
            try {
                $age = ((Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime).TotalMinutes
                # the indexer fetches anything older than IndexFreshMin itself, one at a time
                if ($script:IndexMode -and $age -gt $script:IndexFreshMin) { throw 'stale' }
                $cached = ConvertFrom-JsonSafe -Json ([IO.File]::ReadAllText($cacheFile, [Text.Encoding]::UTF8)) -Source "cache:$uri"
                if ($script:IndexMode) { $script:Idx.Cached++; return $cached }
                if ($age -gt $ttl) { Request-ApiRefresh $uri $cacheFile }
                Write-Log DEBUG ('GET {0} -> from cache ({1:N0} min old{2})' -f $uri, $age, $(if ($age -gt $ttl) { ', refreshing in the background' } else { '' }))
                return $cached
            } catch { if (-not $script:IndexMode) { Write-Log DEBUG "cache entry unreadable, fetching: $uri" } }
        }
    }
    if ($job) { if (-not $job.Need) { $job.Need = $uri }; throw 'NRKB-NEEDFETCH' }   # (fetched in the background, then the job runs again)
    Write-Log DEBUG "GET $uri"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (Test-UiPump) { $r = Invoke-PumpedGet $uri }
        else {
            $resp = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -TimeoutSec 30 `
                -UserAgent $script:UserAgent -Headers @{ 'Accept' = 'application/json' } -ErrorAction Stop
            $r = @{ Status = [int]$resp.StatusCode; Bytes = $resp.RawContentStream.ToArray(); ContentType = ($resp.Headers['Content-Type'] -join ',') }
        }
    } catch {
        $sw.Stop()
        $code = 'n/a'
        try { if ($_.Exception.Data -and $_.Exception.Data.Contains('Status')) { $code = [int]$_.Exception.Data['Status'] } elseif ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
        Write-Log ERROR ('GET {0} FAILED after {1} ms (HTTP {2})' -f $uri, $sw.ElapsedMilliseconds, $code)
        Write-LogException $_ 'Invoke-NrkApi'
        if ($script:IndexMode) { $err = $_; Register-IndexFetch $false $code; throw $err }   # (no stale copy: the indexer counts it as an error)
        if ($cacheFile -and (Test-Path -LiteralPath $cacheFile) -and $code -notin 404, 410) {
            # offline or NRK down: use the last saved copy
            Write-Log WARN "Using the saved copy of $uri"
            try { return (ConvertFrom-JsonSafe -Json ([IO.File]::ReadAllText($cacheFile, [Text.Encoding]::UTF8)) -Source "cache:$uri") } catch { }
        }
        throw
    }
    $sw.Stop()

    # Decode bytes as UTF-8 ourselves, so æ/ø/å survive on every PowerShell version.
    $bytes = $r.Bytes
    $text  = [Text.Encoding]::UTF8.GetString($bytes)
    $ctype = $r.ContentType
    Write-Log INFO ('GET {0} -> HTTP {1}, {2:N0} bytes, {3} ms, {4}' -f $uri, $r.Status, $bytes.Length, $sw.ElapsedMilliseconds, $ctype)

    if ($script:DumpResponses -and $script:LogDir) {
        try {
            $dumpDir = Join-Path $script:LogDir 'responses'
            New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null
            $name = ($Path -replace '^https?://[^/]+', '' -replace '[^\w\-\.]+', '_').Trim('_')
            $file = Join-Path $dumpDir ('{0}_{1}.json' -f (Get-Date -Format 'HHmmss'), $name)
            [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($false)))
            Write-Log DEBUG "  saved response to $file"
        } catch { Write-Log WARN "Could not save response dump: $($_.Exception.Message)" }
    }

    $parsed = ConvertFrom-JsonSafe -Json $text -Source $uri
    if ($cacheFile -and $r.Status -eq 200) { Save-CacheFile $cacheFile $bytes }   # only when it parsed
    if ($script:IndexMode) { Register-IndexFetch $true 200 }
    return $parsed
}

function Get-Prop {
    # Null-safe property lookup that never throws under Set-StrictMode.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-PropNames {
    param($Object)
    if ($null -eq $Object) { return '(null)' }
    if ($Object -is [array]) { return "(array of $($Object.Count))" }
    return (($Object.PSObject.Properties | ForEach-Object { $_.Name }) -join ', ')
}

#endregion

#region ---------- NRK data layer ---------------------------------------------

function New-NrkItem {
    param([string] $Type, [string] $Id, [string] $Title, [string] $Description, $GeoBlocked, [string] $Section, $Raw, [string] $ImageUrl)
    $web = $null
    switch ($Type) {
        'series'  { $web = '{0}/serie/{1}'   -f $script:WebBase, $Id }
        'program' { $web = '{0}/program/{1}' -f $script:WebBase, $Id }
        'live'    { $web = '{0}/direkte/{1}' -f $script:WebBase, $Id }
    }
    [pscustomobject]@{
        Type         = $Type
        Id           = $Id
        Title        = $Title
        Description  = $Description
        GeoBlocked   = $GeoBlocked
        Section      = $Section
        WebUrl       = $web
        Downloadable = ([bool]$web -and $Type -ne 'live')
        Playable     = [bool]$web
        ImageUrl     = $ImageUrl
        Raw          = $Raw
    }
}

function Select-NrkImageUrl {
    # NRK image lists look like [{uri|url, width}, ...]; pick the one closest to $Width.
    param($Images, [int] $Width = 960)
    $best = $null; $bestDiff = [int]::MaxValue
    foreach ($img in @($Images)) {
        if ($null -eq $img) { continue }
        $u = Get-Prop $img 'uri'; if (-not $u) { $u = Get-Prop $img 'url' }
        if (-not $u) { continue }
        $w = Get-Prop $img 'width'; if ($null -eq $w) { $w = Get-Prop $img 'pixelWidth' }
        $w = [int]$w
        $diff = [Math]::Abs($w - $Width)
        if ($diff -lt $bestDiff) { $best = [string]$u; $bestDiff = $diff }
    }
    return $best
}

function Get-NrkPlayUrl {
    # NRK's own share/player link; tv.nrk.no redirects it to the player page.
    param([string] $ProgramId)
    if (-not $ProgramId) { return $null }
    return '{0}/se?v={1}' -f $script:WebBase, [uri]::EscapeDataString($ProgramId)
}

function Get-NrkLiveChannels {
    # /tv/live or /radio/live -> [ {type:'regionalChannel'|'districtChannel', id, _embedded.playback{title,isGeoBlocked,posters}} ]
    param([ValidateSet('tv', 'radio')] [string] $Medium = 'tv')
    $r = Invoke-NrkApi "/$Medium/live"
    $n = 0
    foreach ($c in $r) {
        $id = [string](Get-Prop $c 'id')
        if (-not $id) { continue }
        $pb = Get-Prop (Get-Prop $c '_embedded') 'playback'
        $poster = @(Get-Prop $pb 'posters')[0]
        $district = ([string](Get-Prop $c 'type') -eq 'districtChannel')
        $title = [string](Get-Prop $pb 'title'); if (-not $title) { $title = $id }
        $img = Select-NrkImageUrl (Get-Prop (Get-Prop $poster 'image') 'items')
        $n++
        if ($Medium -eq 'radio') {
            $square = Select-NrkImageUrl (Get-Prop (Get-Prop (@(Get-Prop $pb 'squarePosters')[0]) 'image') 'items') 300
            $manifest = Get-NrkLinkHref (Get-Prop $c '_links') 'manifest'
            if (-not $manifest) { $manifest = '/playback/manifest/channel/{0}' -f $id }
            $item = New-NrkRadioItem -Type 'radiolive' -Id $id -Title $title -Section $(if ($district) { 'Radio - regional' } else { 'Radio' }) -Raw $c `
                -ImageUrl $img -SquareUrl $square -WebUrl ('https://radio.nrk.no/direkte/{0}' -f $id) -ManifestPath $manifest -GeoBlocked (Get-Prop $pb 'isGeoBlocked')
        } else {
            $item = New-NrkItem -Type 'live' -Id $id -Title $title -Description '' -GeoBlocked (Get-Prop $pb 'isGeoBlocked') `
                -Section $(if ($district) { 'LIVE - regional' } else { 'LIVE' }) -Raw $c -ImageUrl $img
        }
        $item | Add-Member -NotePropertyName District -NotePropertyValue $district
        $item
    }
    Write-Log INFO "Parsed $n live channels from /$Medium/live"
}

function ConvertFrom-NrkDate {
    # NRK EPG dates look like "/Date(1792378800000+0200)/" (milliseconds since 1970, UTC)
    param([string] $Value)
    if (-not $Value) { return $null }
    if ($Value -match '/Date\((-?\d+)') { return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Matches[1]).LocalDateTime }
    try { return [datetime]$Value } catch { return $null }
}

function ConvertTo-LocalTime($Value) {
    # an NRK date (ISO text, or a [datetime] when ConvertFrom-Json already made one) as local time
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try {
        if ($Value -is [datetime]) { if ($Value.Kind -eq 'Utc') { return $Value.ToLocalTime() } else { return $Value } }
        if ($Value -is [datetimeoffset]) { return $Value.LocalDateTime }
        return ([datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
    } catch { return $null }
}

function Get-NrkRights($Raw) {
    # When something can be watched or heard. Catalogue entries have usageRights.from/to.date,
    # playback metadata has availability.onDemand.from/to. An end in 2099 or later means "always".
    # (sortable local times, 'yyyy-MM-ddTHH:mm:ss'; '' when NRK gives none)
    $ur = Get-Prop $Raw 'usageRights'
    $od = Get-Prop (Get-Prop $Raw 'availability') 'onDemand'
    $from = ConvertTo-LocalTime (Get-Prop (Get-Prop $ur 'from') 'date')
    if (-not $from) { $from = ConvertTo-LocalTime (Get-Prop $ur 'availableFrom') }
    if (-not $from) { $from = ConvertTo-LocalTime (Get-Prop $od 'from') }
    $to = ConvertTo-LocalTime (Get-Prop (Get-Prop $ur 'to') 'date')
    if (-not $to) { $to = ConvertTo-LocalTime (Get-Prop $ur 'availableTo') }
    if (-not $to) { $to = ConvertTo-LocalTime (Get-Prop $od 'to') }
    $year = Get-Prop $Raw 'productionYear'
    [pscustomobject]@{
        From    = $(if ($from) { $from.ToString('s') } else { '' })
        To      = $(if ($to -and $to.Year -lt 2099) { $to.ToString('s') } else { '' })
        Always  = [bool]($to -and $to.Year -ge 2099)   # (NRK writes "always available" as an end in 2100)
        Year    = $(if ($year) { [string]$year } else { '' })
    }
}

function Add-RightsInfo($Item, $Raw) {
    # AvailableFrom / AvailableTo / Year on a file (plain strings, so they survive recent.json etc.)
    if (-not $Item) { return }
    $r = Get-NrkRights $Raw
    foreach ($k in 'From', 'To') { $Item | Add-Member -NotePropertyName "Available$k" -NotePropertyValue $r.$k -Force }
    $Item | Add-Member -NotePropertyName AvailableAlways -NotePropertyValue $r.Always -Force
    if ($r.Year -or -not $Item.PSObject.Properties['Year']) { $Item | Add-Member -NotePropertyName Year -NotePropertyValue $r.Year -Force }
}

function Get-DaysLeft([string] $To) {
    if (-not $To) { return $null }
    try { $d = [datetime]::Parse($To, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
    return [int][Math]::Floor(($d.Date - (Get-Date).Date).TotalDays)
}

function Format-AvailableUntil($File, [switch] $Short) {
    # "12.11.2026 23:59  (23 days left)" / "23 days left" / 'Always' / ''
    $to = [string]$File.AvailableTo
    if (-not $to) { if ($File.AvailableAlways -and -not $Short) { return 'Always' } else { return '' } }
    $days = Get-DaysLeft $to
    if ($null -eq $days) { return '' }
    $left = if ($days -lt 0) { 'expired' } elseif ($days -eq 0) { 'last day' } elseif ($days -eq 1) { '1 day left' } else { "$days days left" }
    if ($Short) { return $left }
    return '{0:dd.MM.yyyy HH:mm}  ({1})' -f ([datetime]::Parse($to, [Globalization.CultureInfo]::InvariantCulture)), $left
}

function Test-FileAvailable($File) {
    # NRK's availability status: available, expires (still there, going soon), coming, expired, notAvailableOnline
    return (-not $File.Available -or [string]$File.Available -in 'available', 'expires')
}

function Get-NrkEpg {
    # Today's programme guide for a live channel: /epg/{channelId}
    param([Parameter(Mandatory = $true)] [string] $ChannelId)
    $r = Invoke-NrkApi ('/epg/{0}' -f [uri]::EscapeDataString($ChannelId))
    $day = @($r)[0]
    $entries = Get-Prop $day 'entries'
    if ($null -eq $entries) { Write-Log WARN ("/epg/{0}: no entries (keys: {1})" -f $ChannelId, (Get-PropNames $day)); return }
    $list = foreach ($e in $entries) {
        $start = ConvertFrom-NrkDate ([string](Get-Prop $e 'actualStart'))
        if (-not $start) { $start = ConvertFrom-NrkDate ([string](Get-Prop $e 'plannedStart')) }
        if (-not $start) { continue }
        $dur = [TimeSpan]::Zero
        try { $dur = [Xml.XmlConvert]::ToTimeSpan([string](Get-Prop $e 'duration')) } catch { }
        [pscustomobject]@{
            Title       = [string](Get-Prop $e 'title')
            SeriesTitle = [string](Get-Prop $e 'seriesTitle')
            Description = [string](Get-Prop $e 'description')
            ProgramId   = [string](Get-Prop $e 'programId')
            Start       = $start
            End         = $start + $dur
            Duration    = $dur
            HasRights   = [bool](Get-Prop (Get-Prop $e 'onDemandUsageRights') 'hasRightsNow')
            ImageUrl    = Select-NrkImageUrl (Get-Prop (Get-Prop $e 'image') 'webImages')
        }
    }
    $list = @($list | Sort-Object Start)
    Write-Log INFO ("EPG {0}: {1} entries" -f $ChannelId, $list.Count)
    $list
}

# ---- API paths: one place, so a prefetch and the real request hit the same cache entry
function Get-ApiPath {
    param([Parameter(Mandatory = $true)] [string] $Kind, [string] $Id, [string] $Sub, [switch] $Newest)
    $e = { param($v) [uri]::EscapeDataString([string]$v) }
    switch ($Kind) {
        'tvpage'        { '/tv/pages/{0}' -f (& $e $Id) }
        'tvletter'      { '/medium/tv/letters/{0}/indexelements' -f (& $e $Id.ToLowerInvariant()) }
        'tvseries'      { '/tv/catalog/series/{0}' -f (& $e $Id) }
        'tvseason'      { if ($Sub -eq 'ekstramateriale') { '/tv/catalog/series/{0}/extramaterial' -f (& $e $Id) } else { '/tv/catalog/series/{0}/seasons/{1}' -f (& $e $Id), (& $e $Sub) } }
        'tvprogram'     { '/tv/catalog/programs/{0}' -f (& $e $Id) }
        'radiopage'     { '/radio/pages/{0}' -f (& $e $Id) }
        'radioletter'   { '/radio/search/categories/alt-innhold?letter={0}&take=100&skip=0' -f (& $e $Id) }
        'radioseries'   { '/radio/catalog/{0}/{1}' -f $(if ($Sub -eq 'podcast') { 'podcast' } else { 'series' }), (& $e $Id) }
        'radioepisodes' {
            # first page of a season (or of the whole series): $Id is the season href
            $path = if ($Id -match '/episodes(\?|$)') { $Id } else { ($Id -replace '\?.*$', '') + '/episodes' }
            if ($path -notmatch 'pageSize=') { $path += $(if ($path -match '\?') { '&' } else { '?' }) + 'pageSize=50' }
            if ($Newest -and $path -notmatch 'sort=') { $path += '&sort=desc' }
            $path
        }
    }
}

function Get-NrkCategories {
    $r = Invoke-NrkApi '/tv/pages'
    $items = Get-Prop $r 'pageListItems'
    if ($null -eq $items) {
        Write-Log WARN ("/tv/pages: no 'pageListItems' in response. Top-level keys: {0}" -f (Get-PropNames $r))
        return
    }
    $n = 0
    foreach ($p in $items) {
        $n++
        [pscustomobject]@{ Kind = 'category'; Id = [string]$p.id; Title = [string]$p.title; PageType = [string](Get-Prop $p 'pageType') }
    }
    Write-Log INFO "Parsed $n categories from /tv/pages"
}

function Get-NrkLetters {
    $r = Invoke-NrkApi '/medium/tv/letters'
    $n = 0
    foreach ($l in $r) {
        if (-not (Get-Prop $l 'id')) { continue }
        $n++
        [pscustomobject]@{ Kind = 'letter'; Id = [string]$l.id; Title = [string]$l.title; Count = Get-Prop $l 'availableInNorway' }
    }
    Write-Log INFO "Parsed $n letters from /medium/tv/letters"
}

function Get-NrkLetterItems {
    param([Parameter(Mandatory = $true)] [string] $Letter)
    $path = Get-ApiPath tvletter -Id $Letter
    $r = Invoke-NrkApi $path
    $types = @{}
    $n = 0
    foreach ($e in $r) {
        $t = [string](Get-Prop $e 'type')
        $types[$t] = 1 + [int]$types[$t]
        $type = switch ($t) { 'series' { 'series' } 'programme' { 'program' } 'program' { 'program' } default { $t } }
        $n++
        New-NrkItem -Type $type -Id ([string]$e.id) -Title ([string]$e.title) -Description ([string](Get-Prop $e 'description')) `
            -GeoBlocked (Get-Prop $e 'isGeoBlocked') -Section "A-Å: $Letter" -Raw $e `
            -ImageUrl (Select-NrkImageUrl (Get-Prop (Get-Prop $e 'image') 'webImages'))
    }
    Write-Log INFO ('Letter {0}: {1} items, types: {2}' -f $Letter, $n, (($types.Keys | ForEach-Object { "$_=$($types[$_])" }) -join ', '))
}

function ConvertFrom-NrkPlug {
    param($Plug, [string] $SectionTitle)
    $t = [string](Get-Prop $Plug 'targetType')
    $content = Get-Prop $Plug 'displayContractContent'
    $title = [string](Get-Prop $content 'contentTitle')
    $desc  = [string](Get-Prop $content 'description')
    $child = Get-Prop $Plug $t   # e.g. $plug.series / $plug.standaloneProgram / $plug.episode
    $geo   = Get-Prop (Get-Prop $child 'usageRights') 'isGeoBlocked'
    $img   = Select-NrkImageUrl (Get-Prop (Get-Prop $content 'displayContractImage') 'webImages')

    switch ($t) {
        'series' {
            return New-NrkItem -Type 'series' -Id ([string](Get-Prop $child 'seriesId')) -Title $title -Description $desc -GeoBlocked $geo -Section $SectionTitle -Raw $Plug -ImageUrl $img
        }
        { $_ -in 'standaloneProgram', 'program', 'episode' } {
            $id = [string](Get-Prop $child 'programId')
            if (-not $id) { $id = [string](Get-Prop $child 'id') }
            $it = New-NrkItem -Type 'program' -Id $id -Title $title -Description $desc -GeoBlocked $geo -Section $SectionTitle -Raw $Plug -ImageUrl $img
            Add-RightsInfo $it $child
            return $it
        }
        default {
            Write-Log DEBUG ("Plug '{0}' has unhandled targetType '{1}' (keys: {2})" -f $title, $t, (Get-PropNames $Plug))
            return New-NrkItem -Type $t -Id ([string](Get-Prop $Plug 'id')) -Title $title -Description $desc -Section $SectionTitle -Raw $Plug -ImageUrl $img
        }
    }
}

function Get-NrkCategoryItems {
    param([Parameter(Mandatory = $true)] [string] $PageId)
    $r = Invoke-NrkApi (Get-ApiPath tvpage -Id $PageId)
    $sections = Get-Prop $r 'sections'
    if ($null -eq $sections) {
        Write-Log WARN ("/tv/pages/{0}: no 'sections'. Top-level keys: {1}" -f $PageId, (Get-PropNames $r))
        return
    }
    $seen = @{}
    $nSections = 0; $nItems = 0; $nDupes = 0
    foreach ($s in $sections) {
        $nSections++
        $stype = [string](Get-Prop $s 'type')
        $inc = Get-Prop $s $stype       # usually $s.included
        $plugs = Get-Prop $inc 'plugs'
        if ($null -eq $plugs) {
            Write-Log DEBUG ("  section #{0} type '{1}' has no plugs (keys: {2})" -f $nSections, $stype, (Get-PropNames $s))
            continue
        }
        $sectionTitle = [string](Get-Prop $inc 'title')
        if (-not $sectionTitle) { $sectionTitle = '(highlight)' }
        foreach ($p in $plugs) {
            $item = ConvertFrom-NrkPlug -Plug $p -SectionTitle $sectionTitle
            if (-not $item) { continue }
            $key = '{0}|{1}' -f $item.Type, $item.Id
            if ($item.Id -and $seen.ContainsKey($key)) { $nDupes++; continue }
            $seen[$key] = $true
            $nItems++
            $item
        }
    }
    Write-Log INFO ("Category {0}: {1} sections, {2} unique items ({3} duplicates skipped)" -f $PageId, $nSections, $nItems, $nDupes)
}

function Get-NrkSeriesInfo {
    param([Parameter(Mandatory = $true)] [string] $SeriesId)
    $r = Invoke-NrkApi (Get-ApiPath tvseries -Id $SeriesId)
    $stype = [string](Get-Prop $r 'seriesType')
    $body  = Get-Prop $r $stype
    $links = Get-Prop $r '_links'
    $seasons = @()
    foreach ($s in @(Get-Prop $links 'seasons')) {
        if ($null -eq $s) { continue }
        $seasons += [pscustomobject]@{ Name = [string]$s.name; Title = [string]$s.title }
    }
    if (Get-Prop $links 'extramaterial') {
        # nrkdownload's season id for extra material is 'ekstramateriale'
        $seasons += [pscustomobject]@{ Name = 'ekstramateriale'; Title = 'Ekstramateriale' }
    }
    Write-Log INFO ("Series {0}: type={1}, {2} seasons/groups" -f $SeriesId, $stype, $seasons.Count)
    [pscustomobject]@{
        SeriesType = $stype
        Title      = [string](Get-Prop (Get-Prop $body 'titles') 'title')
        Subtitle   = [string](Get-Prop (Get-Prop $body 'titles') 'subtitle')
        Category   = [string](Get-Prop (Get-Prop $body 'category') 'name')
        ImageUrl   = Select-NrkImageUrl (Get-Prop $body 'image')
        Seasons    = $seasons
        Raw        = $r
    }
}

function Get-NrkProgramInfo {
    param([Parameter(Mandatory = $true)] [string] $ProgramId)
    $enc = [uri]::EscapeDataString($ProgramId)
    $r = Invoke-NrkApi (Get-ApiPath tvprogram -Id $ProgramId)
    $more = Get-Prop $r 'moreInformation'

    $playability = 'unknown'; $reason = $null
    try {
        $m = Invoke-NrkApi "/playback/manifest/program/$enc"
        $playability = [string](Get-Prop $m 'playability')
        $np = Get-Prop $m 'nonPlayable'
        if ($np) { $reason = '{0} - {1}' -f (Get-Prop $np 'reason'), (Get-Prop $np 'endUserMessage') }
        Write-Log INFO ("Program {0}: playability={1} {2}" -f $ProgramId, $playability, $reason)
    } catch {
        Write-Log WARN "Program ${ProgramId}: could not read playback manifest"
    }

    [pscustomobject]@{
        Title         = [string](Get-Prop (Get-Prop (Get-Prop $r 'programInformation') 'titles') 'title')
        OriginalTitle = [string](Get-Prop $more 'originalTitle')
        Year          = Get-Prop $more 'productionYear'
        Duration      = [string](Get-Prop (Get-Prop $more 'duration') 'displayValue')
        Category      = [string](Get-Prop (Get-Prop $more 'category') 'displayValue')
        AgeRating     = [string](Get-Prop (Get-Prop (Get-Prop (Get-Prop $more 'legalAge') 'body') 'rating') 'displayAge')
        ImageUrl      = Select-NrkImageUrl (Get-Prop (Get-Prop $r 'programInformation') 'image')
        Playability   = $playability
        NotPlayable   = $reason
        Raw           = $r
    }
}

function Get-NrkSeasonEpisodes {
    param([Parameter(Mandatory = $true)] [string] $SeriesId, [Parameter(Mandatory = $true)] [string] $Season)
    $sid = [uri]::EscapeDataString($SeriesId)
    $path = Get-ApiPath tvseason -Id $SeriesId -Sub $Season
    $list = @(); $pages = 0
    # news-type series can have hundreds of instalments per season: follow NRK's "next" pages
    while ($path -and $pages -lt 40) {
        $r = Invoke-NrkApi $path
        $pages++
        $emb = Get-Prop $r '_embedded'
        # 'sequential' series use 'episodes'; 'news' and 'standard' series use 'instalments'.
        $part = Get-Prop $emb 'episodes'
        if ($null -eq $part) { $part = Get-Prop $emb 'instalments' }
        if ($null -eq $part) {
            if ($pages -eq 1) { Write-Log WARN ("{0}: no episodes/instalments. _embedded keys: {1}" -f $path, (Get-PropNames $emb)); return }
            break
        }
        $list += @($part)
        $nextPath = Get-NrkLinkHref (Get-Prop $r '_links') 'next'
        if (-not $nextPath) { $nextPath = Get-NrkLinkHref (Get-Prop $emb '_links') 'next' }
        $path = if ($nextPath -and $nextPath -ne $path) { $nextPath } else { $null }
    }
    if ($pages -gt 1) { Write-Log INFO "Series $SeriesId season ${Season}: $pages pages" }
    $n = 0
    foreach ($ep in $list) {
        $id = [string](Get-Prop $ep 'prfId')
        if (-not $id) { $id = [string](Get-Prop $ep 'id') }
        $titles = Get-Prop $ep 'titles'
        $secs = Get-Prop $ep 'durationInSeconds'
        $avail = [string](Get-Prop (Get-Prop $ep 'availability') 'status')
        $rights = Get-NrkRights $ep
        $n++
        [pscustomobject]@{
            AvailableFrom = $rights.From; AvailableTo = $rights.To; AvailableAlways = $rights.Always; Year = $rights.Year
            Id          = $id
            Title       = [string](Get-Prop $titles 'title')
            Subtitle    = [string](Get-Prop $titles 'subtitle')
            Duration    = $(if ($secs) { '{0} min' -f [Math]::Round([double]$secs / 60) } else { [string](Get-Prop $ep 'durationDisplayValue') })
            Available   = $avail
            Season      = $Season
            ImageUrl    = Select-NrkImageUrl (Get-Prop $ep 'image')
            Raw         = $ep
        }
    }
    Write-Log INFO ("Series {0} season {1}: {2} episodes" -f $SeriesId, $Season, $n)
}

# ---- NRK Radio (radio.nrk.no) ----------------------------------------------------
# radio.nrk.no is built on the same psapi.nrk.no as the TV site:
#   /radio/pages                         -> pages[] {id, title}           (Nyheter, Sport, Podkast, ...)
#   /radio/pages/{id}                    -> sections[].included.plugs[]  (type + payload under that type)
#   /radio/live                          -> live channels (same shape as /tv/live)
#   /radio/catalog/series/{id}           -> series; _links.seasons[] {name, href, title}
#   /radio/catalog/podcast/{id}          -> podcast; same shape
#   {season href}/episodes?pageSize=50   -> _embedded.episodes[]
#   /playback/manifest/program/{id}      -> HLS audio (AAC)
#   /playback/manifest/podcast/{pod}/{ep}-> MP3 file
#   /playback/manifest/channel/{id}      -> live HLS audio with a 3 h sliding buffer

function Get-NrkLinkHref {
    # psapi links are either {"href": "..."} or a bare string
    param($Links, [string] $Name)
    $l = Get-Prop $Links $Name
    if ($null -eq $l) { return $null }
    if ($l -is [string]) { return $l }
    if ($l -is [array]) { $l = $l[0] }
    return [string](Get-Prop $l 'href')
}

function Format-NrkDuration {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    $secs = $null
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { $secs = [double]$Value }
    elseif ("$Value" -match '^P') { try { $secs = [Xml.XmlConvert]::ToTimeSpan([string]$Value).TotalSeconds } catch { } }
    elseif (Get-Prop $Value 'displayValue') { return [string](Get-Prop $Value 'displayValue') }
    if ($null -eq $secs) { return [string]$Value }
    if ($secs -ge 3600) { return '{0} h {1} min' -f [Math]::Floor($secs / 3600), [Math]::Round(($secs % 3600) / 60) }
    return '{0} min' -f [Math]::Max(1, [Math]::Round($secs / 60))
}

function New-NrkRadioItem {
    # Radio items: radiolive (channel), radioseries (series or podcast = folder), audio (playable file)
    param([string] $Type, [string] $Id, [string] $Title, [string] $Description, [string] $Section, $Raw,
          [string] $ImageUrl, [string] $SquareUrl, [string] $WebUrl, [string] $ManifestPath, [string] $Kind,
          [string] $SeriesId, [string] $SeriesTitle, [string] $Duration, [string] $Date, [string] $Available, $GeoBlocked)
    [pscustomobject]@{
        Medium       = 'radio'
        Type         = $Type
        Kind         = $Kind          # series | podcast (folders and their episodes)
        Id           = $Id
        Title        = $(if ($Title) { $Title } else { $Id })
        Description  = $Description
        Section      = $Section
        ImageUrl     = $ImageUrl
        SquareUrl    = $(if ($SquareUrl) { $SquareUrl } else { $ImageUrl })
        WebUrl       = $WebUrl
        ManifestPath = $ManifestPath
        SeriesId     = $SeriesId
        SeriesTitle  = $SeriesTitle
        Duration     = $Duration
        Date         = $Date
        Available    = $Available
        GeoBlocked   = $GeoBlocked
        Playable     = [bool]$ManifestPath
        Downloadable = ($Type -eq 'audio')
        Raw          = $Raw
    }
}

function Get-NrkRadioCategories {
    $r = Invoke-NrkApi '/radio/pages'
    $pages = Get-Prop $r 'pages'
    if ($null -eq $pages) { Write-Log WARN ("/radio/pages: no 'pages' (keys: {0})" -f (Get-PropNames $r)); return }
    $n = 0
    foreach ($p in $pages) {
        $id = [string](Get-Prop $p 'id'); if (-not $id) { continue }
        $title = [string](Get-Prop $p 'title')
        # "Alt innhold" is radio.nrk.no's A-Å page, not a category: it is under Radio Archive > A-Å
        if ($id -match '^alt-?innhold$' -or $title -match '^\s*alt innhold\s*$') { continue }
        $n++
        [pscustomobject]@{ Kind = 'radiocategory'; Id = $id; Title = [string](Get-Prop $p 'title') }
    }
    Write-Log INFO "Parsed $n radio categories from /radio/pages"
}

function ConvertFrom-NrkRadioPlug {
    param($Plug, [string] $SectionTitle)
    $t = [string](Get-Prop $Plug 'type')
    $links = Get-Prop $Plug '_links'
    $body = Get-Prop $Plug $t
    if ($null -eq $body -and $t -eq 'standaloneProgram') { $body = Get-Prop $Plug 'program' }   # payload key differs from the type
    $titles = Get-Prop $body 'titles'
    $title = [string](Get-Prop $titles 'title'); if (-not $title) { $title = [string](Get-Prop $body 'title') }
    $desc = [string](Get-Prop $titles 'subtitle')
    $img = [string](Get-Prop $body 'imageUrl')
    if (-not $img) { $img = Select-NrkImageUrl (Get-Prop (Get-Prop $body 'image') 'webImages') }
    if (-not $img -and (Get-Prop $body 'image') -is [array]) { $img = Select-NrkImageUrl (Get-Prop $body 'image') }
    $square = Select-NrkImageUrl (Get-Prop (Get-Prop $body 'squareImage') 'webImages') 600
    $dur = Format-NrkDuration (Get-Prop $body 'duration')
    $seriesTitle = [string](Get-Prop (Get-Prop (Get-Prop $body 'series') 'titles') 'title')
    if (-not $seriesTitle) { $seriesTitle = [string](Get-Prop (Get-Prop (Get-Prop $body 'podcast') 'titles') 'title') }
    switch ($t) {
        { $_ -in 'series', 'podcast' } {
            $href = Get-NrkLinkHref $links $t
            $id = ($href -split '/')[-1]
            if (-not $id) { return $null }
            $web = if ($t -eq 'podcast') { 'https://radio.nrk.no/podkast/{0}' -f $id } else { 'https://radio.nrk.no/serie/{0}' -f $id }
            return New-NrkRadioItem -Type 'radioseries' -Kind $t -Id $id -Title $title -Description $desc -Section $SectionTitle -Raw $Plug -ImageUrl $img -SquareUrl $square -WebUrl $web
        }
        { $_ -in 'episode', 'standaloneProgram', 'program' } {
            $href = Get-NrkLinkHref $links $(if ($t -eq 'episode') { 'episode' } else { 'program' })
            if (-not $href) { $href = Get-NrkLinkHref $links 'mediaelement' }
            $id = ($href -split '/')[-1]
            if (-not $id) { return $null }
            $sid = (Get-NrkLinkHref $links 'series') -replace '^.*/', ''
            return New-NrkRadioItem -Type 'audio' -Kind 'series' -Id $id -Title $title -Description $desc -Section $SectionTitle -Raw $Plug `
                -ImageUrl $img -SquareUrl $square -WebUrl ('https://radio.nrk.no/program/{0}' -f $id) -ManifestPath ('/playback/manifest/program/{0}' -f $id) `
                -SeriesId $sid -SeriesTitle $seriesTitle -Duration $dur
        }
        'podcastEpisode' {
            $href = Get-NrkLinkHref $links 'podcastEpisode'      # /podcasts/{pod}/episodes/{ep}
            if ($href -notmatch '/podcasts/([^/]+)/episodes/([^/?]+)') { return $null }
            $pod = $Matches[1]; $ep = $Matches[2]
            return New-NrkRadioItem -Type 'audio' -Kind 'podcast' -Id $ep -Title $title -Description $desc -Section $SectionTitle -Raw $Plug `
                -ImageUrl $img -SquareUrl $square -WebUrl ('https://radio.nrk.no/podkast/{0}/{1}' -f $pod, $ep) -ManifestPath ('/playback/manifest/podcast/{0}/{1}' -f $pod, $ep) `
                -SeriesId $pod -SeriesTitle $seriesTitle -Duration $dur
        }
        default {
            Write-Log DEBUG ("Radio plug '{0}' has unhandled type '{1}' (keys: {2})" -f $title, $t, (Get-PropNames $Plug))
            return $null
        }
    }
}

function Get-NrkRadioPageItems {
    param([Parameter(Mandatory = $true)] [string] $PageId)
    $r = Invoke-NrkApi (Get-ApiPath radiopage -Id $PageId)
    $sections = Get-Prop $r 'sections'
    if ($null -eq $sections) { Write-Log WARN ("/radio/pages/{0}: no 'sections' (keys: {1})" -f $PageId, (Get-PropNames $r)); return }
    $seen = @{}; $nItems = 0; $nSections = 0
    foreach ($s in $sections) {
        $nSections++
        $inc = Get-Prop $s ([string](Get-Prop $s 'type'))
        $plugs = Get-Prop $inc 'plugs'
        if ($null -eq $plugs) { continue }
        $sectionTitle = [string](Get-Prop $inc 'title')
        foreach ($p in $plugs) {
            $item = ConvertFrom-NrkRadioPlug -Plug $p -SectionTitle $sectionTitle
            if (-not $item) { continue }
            $key = '{0}|{1}|{2}' -f $item.Type, $item.Kind, $item.Id
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true; $nItems++
            $item
        }
    }
    Write-Log INFO ("Radio page {0}: {1} sections, {2} unique items" -f $PageId, $nSections, $nItems)
}

function Get-NrkRadioLetters {
    # /radio/search/categories/alt-innhold -> letters[] {letter, count, link}  (the A-Å index of radio.nrk.no)
    $r = Invoke-NrkApi '/radio/search/categories/alt-innhold?take=1&skip=0'
    $n = 0
    foreach ($l in @(Get-Prop $r 'letters')) {
        $t = [string](Get-Prop $l 'letter'); if (-not $t) { continue }
        $n++
        [pscustomobject]@{ Kind = 'radioletter'; Id = $t; Title = $t; Count = Get-Prop $l 'count' }
    }
    Write-Log INFO "Parsed $n radio letters from /radio/search/categories/alt-innhold"
}

function ConvertFrom-NrkRadioListItem {
    # A row of /radio/search/categories/...: series, podcast, singleProgram or customSeason
    param($Entry, [string] $Section)
    $t = [string](Get-Prop $Entry 'type')
    $links = Get-Prop $Entry '_links'
    $title = [string](Get-Prop $Entry 'title')
    $img = Select-NrkImageUrl (Get-Prop $Entry 'images')
    $square = Select-NrkImageUrl (Get-Prop $Entry 'squareImages') 600
    switch ($t) {
        'singleProgram' {
            $id = [string](Get-Prop $Entry 'id')
            return New-NrkRadioItem -Type 'audio' -Kind 'series' -Id $id -Title $title -Section $Section -Raw $Entry -ImageUrl $img -SquareUrl $square `
                -WebUrl ('https://radio.nrk.no/program/{0}' -f $id) -ManifestPath ('/playback/manifest/program/{0}' -f $id)
        }
        default {
            # series / podcast / customSeason (a season shown on its own): a folder for the series or podcast
            $href = Get-NrkLinkHref $links $t
            $kind = if ($t -eq 'podcast' -or $href -match '/podcast/') { 'podcast' } else { 'series' }
            $id = [string](Get-Prop $Entry 'seriesId'); if (-not $id) { $id = [string](Get-Prop $Entry 'id') }
            if (-not $id) { return $null }
            $web = if ($kind -eq 'podcast') { 'https://radio.nrk.no/podkast/{0}' -f $id } else { 'https://radio.nrk.no/serie/{0}' -f $id }
            return New-NrkRadioItem -Type 'radioseries' -Kind $kind -Id $id -Title $title -Section $Section -Raw $Entry -ImageUrl $img -SquareUrl $square -WebUrl $web
        }
    }
}

function Get-NrkRadioLetterItems {
    param([Parameter(Mandatory = $true)] [string] $Letter, [int] $Max = 2000)
    $path = Get-ApiPath radioletter -Id $Letter
    $n = 0; $pages = 0; $seen = @{}
    while ($path -and $n -lt $Max -and $pages -lt 25) {
        $r = Invoke-NrkApi $path
        $pages++
        $rows = @(Get-Prop $r 'series')
        if ($rows.Count -eq 0) { break }
        foreach ($e in $rows) {
            $it = ConvertFrom-NrkRadioListItem $e "Radio A-Å: $Letter"
            if (-not $it) { continue }
            $key = '{0}|{1}|{2}' -f $it.Type, $it.Kind, $it.Id
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true; $n++
            $it
        }
        $path = Get-NrkLinkHref (Get-Prop $r '_links') 'nextPage'
    }
    Write-Log INFO ("Radio letter {0}: {1} items on {2} page(s)" -f $Letter, $n, $pages)
}

function Get-NrkRadioSeriesInfo {
    param([Parameter(Mandatory = $true)] [string] $Kind, [Parameter(Mandatory = $true)] [string] $Id)
    $r = Invoke-NrkApi (Get-ApiPath radioseries -Id $Id -Sub $Kind)
    $body = Get-Prop $r 'series'
    $links = Get-Prop $r '_links'
    $seasons = @()
    foreach ($s in @(Get-Prop $links 'seasons')) {
        if ($null -eq $s) { continue }
        $seasons += [pscustomobject]@{ Name = [string](Get-Prop $s 'name'); Title = [string](Get-Prop $s 'title'); Href = [string](Get-Prop $s 'href'); Newest = $false }
    }
    if ($seasons.Count -eq 0) {
        # news-type series and simple podcasts have no seasons: one folder with the newest episodes
        $seasons += [pscustomobject]@{ Name = 'all'; Title = 'Episodes'; Href = (Get-NrkLinkHref $links 'episodes'); Newest = $true }
    }
    $web = Get-NrkLinkHref $links 'share'
    if (-not $web) { $web = 'https://radio.nrk.no/{0}/{1}' -f $(if ($Kind -eq 'podcast') { 'podkast' } else { 'serie' }), $Id }
    Write-Log INFO ("Radio {0} {1}: type={2}, {3} seasons" -f $Kind, $Id, (Get-Prop $r 'seriesType'), $seasons.Count)
    [pscustomobject]@{
        Kind       = $Kind
        SeriesType = [string](Get-Prop $r 'seriesType')
        Title      = [string](Get-Prop (Get-Prop $body 'titles') 'title')
        Subtitle   = [string](Get-Prop (Get-Prop $body 'titles') 'subtitle')
        Category   = [string](Get-Prop (Get-Prop $body 'category') 'name')
        ImageUrl   = Select-NrkImageUrl (Get-Prop $body 'image')
        SquareUrl  = Select-NrkImageUrl (Get-Prop $body 'squareImage') 600
        WebUrl     = $web
        Seasons    = $seasons
        Raw        = $r
    }
}

function ConvertFrom-NrkRadioEpisode {
    param($Episode, [string] $Kind, [string] $SeriesId, [string] $SeriesTitle)
    $id = [string](Get-Prop $Episode 'episodeId'); if (-not $id) { $id = [string](Get-Prop $Episode 'id') }
    $links = Get-Prop $Episode '_links'
    $manifest = (Get-NrkLinkHref $links 'playback') -replace '^/playback/metadata/', '/playback/manifest/'
    if (-not $manifest) {
        $manifest = if ($Kind -eq 'podcast') { '/playback/manifest/podcast/{0}/{1}' -f $SeriesId, $id } else { '/playback/manifest/program/{0}' -f $id }
    }
    $web = Get-NrkLinkHref $links 'share'
    if (-not $web) { $web = if ($Kind -eq 'podcast') { 'https://radio.nrk.no/podkast/{0}/{1}' -f $SeriesId, $id } else { 'https://radio.nrk.no/program/{0}' -f $id } }
    $date = ''
    try { $d = [string](Get-Prop $Episode 'date'); if ($d) { $date = ([datetimeoffset]::Parse($d, [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime.ToString('dd.MM.yyyy') } } catch { }
    $secs = Get-Prop $Episode 'durationInSeconds'
    $titles = Get-Prop $Episode 'titles'
    $it = New-NrkRadioItem -Type 'audio' -Kind $Kind -Id $id -Title ([string](Get-Prop $titles 'title')) -Description ([string](Get-Prop $titles 'subtitle')) `
        -Section $SeriesTitle -Raw $Episode -ImageUrl (Select-NrkImageUrl (Get-Prop $Episode 'image')) -SquareUrl (Select-NrkImageUrl (Get-Prop $Episode 'squareImage') 600) `
        -WebUrl $web -ManifestPath $manifest -SeriesId $SeriesId -SeriesTitle $SeriesTitle `
        -Duration $(if ($secs) { Format-NrkDuration ([double]$secs) } else { Format-NrkDuration (Get-Prop $Episode 'duration') }) `
        -Date $date -Available ([string](Get-Prop (Get-Prop $Episode 'availability') 'status')) `
        -GeoBlocked (Get-Prop (Get-Prop (Get-Prop $Episode 'usageRights') 'geoBlock') 'isGeoBlocked')
    Add-RightsInfo $it $Episode
    $it
}

$script:RadioMore = @{}   # season href -> where its next episodes start
function Get-NrkRadioEpisodes {
    # Episodes of a season (or of the whole series when it has no seasons), following "next" pages.
    param([Parameter(Mandatory = $true)] [string] $Href, [string] $Kind, [string] $SeriesId, [string] $SeriesTitle,
          [switch] $Newest, [int] $Max = 300)
    if (-not $Href) { return }
    $path = Get-ApiPath radioepisodes -Id $Href -Newest:$Newest
    $n = 0; $pages = 0
    while ($path -and $n -lt $Max -and $pages -lt 10) {
        $r = Invoke-NrkApi $path
        $pages++
        $list = Get-Prop (Get-Prop $r '_embedded') 'episodes'
        # season endpoints wrap the list once more: _embedded.episodes._embedded.episodes
        if ($null -ne $list -and $list -isnot [array] -and (Get-Prop $list '_embedded')) { $r = $list; $list = Get-Prop (Get-Prop $list '_embedded') 'episodes' }
        if ($null -eq $list) { Write-Log WARN ("{0}: no episodes (keys: {1})" -f $path, (Get-PropNames (Get-Prop $r '_embedded'))); break }
        foreach ($ep in @($list)) {
            if ($null -eq $ep) { continue }
            $n++
            ConvertFrom-NrkRadioEpisode $ep $Kind $SeriesId $SeriesTitle
        }
        $path = Get-NrkLinkHref (Get-Prop $r '_links') 'next'
    }
    # more than fit: remember where the next page starts ("Load more episodes" in the list)
    if ($path) { $script:RadioMore[$Href] = $path } else { [void]$script:RadioMore.Remove($Href) }
    Write-Log INFO ("Radio episodes {0}: {1} on {2} page(s){3}" -f $Href, $n, $pages, $(if ($path) { ', more available' } else { '' }))
}

function Get-NrkAudioStream {
    # Resolves a playback manifest to the stream the audio player plays.
    param([Parameter(Mandatory = $true)] [string] $ManifestPath)
    $m = Invoke-NrkApi $ManifestPath
    $pl = Get-Prop $m 'playable'
    $asset = @(Get-Prop $pl 'assets') | Where-Object { $_ } | Select-Object -First 1
    $reason = $null
    $np = Get-Prop $m 'nonPlayable'
    if ($np) { $reason = (@((Get-Prop $np 'endUserMessage'), (Get-Prop $np 'reason')) | Where-Object { $_ }) -join ' - ' }
    $live = [bool](Get-Prop $pl 'liveBuffer') -or ($ManifestPath -match '/channel/')
    $res = [pscustomobject]@{
        Playable = (([string](Get-Prop $m 'playability') -eq 'playable') -and [bool]$asset)
        Url      = [string](Get-Prop $asset 'url')
        Format   = [string](Get-Prop $asset 'format')
        Mime     = [string](Get-Prop $asset 'mimeType')
        Live     = $live
        Duration = [string](Get-Prop $pl 'duration')
        Reason   = $reason
    }
    Write-Log INFO ("Audio stream {0}: playable={1} format={2} live={3} {4}" -f $ManifestPath, $res.Playable, $res.Format, $res.Live, $(if ($reason) { "($reason)" } else { $res.Url }))
    return $res
}

$script:ImageCache = @{}
$script:ImageFailed = @{}   # url -> time of the failure: tried again after a minute
$script:ImageOrder = New-Object System.Collections.Queue
function Get-NrkImage {
    # Downloads an image (gfx.nrk.no) once and returns a System.Drawing.Image (or $null).
    param([string] $Url)
    if (-not $Url) { return $null }
    if ($script:ImageCache.ContainsKey($Url)) { return $script:ImageCache[$Url] }
    if ($script:ImageFailed.ContainsKey($Url) -and ((Get-Date) - $script:ImageFailed[$Url]).TotalSeconds -lt 60) { return $null }
    $img = $null
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $file = if ($script:AppDataDir) { Get-CacheFile $Url 'img' '.img' } else { $null }
        if ($file -and (Test-Path -LiteralPath $file)) { $bytes = [IO.File]::ReadAllBytes($file) }
        else {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20 -UserAgent $script:UserAgent -ErrorAction Stop
            $bytes = $resp.RawContentStream.ToArray()
            if ($file) { Save-CacheFile $file $bytes }
        }
        $ms = New-Object IO.MemoryStream(, $bytes)
        $tmp = [System.Drawing.Image]::FromStream($ms)
        $img = New-Object System.Drawing.Bitmap($tmp)   # detach from the stream
        $tmp.Dispose(); $ms.Dispose()
        Write-Log DEBUG ('IMG {0} -> {1:N0} bytes, {2}x{3}, {4} ms' -f $Url, $bytes.Length, $img.Width, $img.Height, $sw.ElapsedMilliseconds)
    } catch {
        Write-Log WARN "IMG $Url failed: $($_.Exception.Message) (tried again in a minute)"
    }
    if ($img) {
        $script:ImageCache[$Url] = $img; $script:ImageFailed.Remove($Url); [void]$script:ImageOrder.Enqueue($Url)
        # keep the newest 250 pictures in memory; older ones are read from disk again when needed
        while ($script:ImageOrder.Count -gt 250) {
            $old = $script:ImageOrder.Dequeue()
            $bm = $script:ImageCache[$old]
            if ($bm -and -not [object]::ReferenceEquals($bm, $pic.Image)) { $script:ImageCache.Remove($old); try { $bm.Dispose() } catch { } }
            elseif ($bm) { [void]$script:ImageOrder.Enqueue($old) ; break }
        }
    } else { $script:ImageFailed[$Url] = Get-Date }
    return $img
}

# Parsed NRK data is also kept in memory, but only for MemoryTtlMin minutes: after that it is
# read again from the disk cache, which the background refresh and the indexer keep current.
# (Without this a long session in the tray would keep showing the lists from when it started.)
$script:CacheAt = @{}
$script:MemoryTtlMin = 30
function Get-Cached {
    param([string] $Key, [scriptblock] $Loader)
    if ($script:Cache.ContainsKey($Key)) {
        $at = $script:CacheAt[$Key]
        if (-not $at -or ((Get-Date) - $at).TotalMinutes -lt $script:MemoryTtlMin) {
            Write-Log DEBUG "cache hit: $Key"
            return $script:Cache[$Key]
        }
        Write-Log DEBUG "memory copy older than $($script:MemoryTtlMin) min, reading again: $Key"
    }
    $value = @(& $Loader)
    $script:Cache[$Key] = $value; $script:CacheAt[$Key] = Get-Date
    return $value
}

#endregion

#region ---------- Download hand-off ------------------------------------------

# Downloads run through the download queue (Downloads window), see 'Download queue' below.

#endregion

#region ---------- External tools: FFmpeg / winget ----------------------------

function Update-PathFromRegistry {
    # A newly installed tool is added to the registry PATH, not to this running
    # process. Merge Machine + User PATH into the current process (no duplicates).
    $parts = New-Object Collections.Generic.List[string]
    foreach ($src in @($env:Path, [Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'))) {
        if (-not $src) { continue }
        foreach ($p in ($src -split [IO.Path]::PathSeparator)) {
            if ($p -and -not $parts.Contains($p)) { $parts.Add($p) }
        }
    }
    $env:Path = $parts -join [IO.Path]::PathSeparator
}

function Add-ToProcessPath {
    param([string] $Dir)
    if ($Dir -and (($env:Path -split [IO.Path]::PathSeparator) -notcontains $Dir)) {
        $env:Path = $Dir + [IO.Path]::PathSeparator + $env:Path
        Write-Log INFO "Added $Dir to PATH for this session (downloads started from here will find it)"
    }
}

function Find-FFmpeg([switch] $Refresh) {
    # found once: remembered for the session (it was looked up again for every download and cast);
    # not found: looked for again next time (it may have been installed meanwhile)
    if ($script:FFmpegFound -and -not $Refresh -and (Test-Path -LiteralPath $script:FFmpegFound.Path)) { return $script:FFmpegFound }
    Update-PathFromRegistry
    $path = $null; $how = $null

    $cmd = Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $path = $cmd.Source; $how = 'PATH' }

    if (-not $path -and $env:LOCALAPPDATA) {
        $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'
        if (Test-Path -LiteralPath $link) { $path = $link; $how = 'winget link' }
    }
    if (-not $path -and $env:LOCALAPPDATA) {
        $pkgRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        if (Test-Path -LiteralPath $pkgRoot) {
            $hit = Get-ChildItem -Path $pkgRoot -Directory -Filter 'Gyan.FFmpeg*' -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ChildItem -Path $_.FullName -Recurse -Depth 4 -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue } |
                Select-Object -First 1
            if ($hit) { $path = $hit.FullName; $how = 'winget package folder' }
        }
    }

    $version = $null
    if ($path) {
        try { $version = (& $path -hide_banner -version 2>$null | Select-Object -First 1) } catch { $version = "(could not run: $($_.Exception.Message))" }
        if ($how -ne 'PATH') { Add-ToProcessPath (Split-Path -Parent $path) }
    }
    Write-Log INFO ("FFmpeg: {0}" -f $(if ($path) { "$path [$how] $version" } else { 'not found' }))
    $res = [pscustomobject]@{ Found = [bool]$path; Path = $path; Source = $how; Version = $version }
    $script:FFmpegFound = if ($path) { $res } else { $null }
    return $res
}

function Find-Winget {
    $cmd = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $path = if ($cmd) { $cmd.Source } elseif ($env:LOCALAPPDATA -and (Test-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'))) {
        Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    } else { $null }
    $version = $null
    if ($path) { try { $version = (& $path --version 2>$null | Select-Object -First 1) } catch { } }
    Write-Log INFO ("winget: {0}" -f $(if ($path) { "$path $version" } else { 'not found' }))
    [pscustomobject]@{ Found = [bool]$path; Path = $path; Version = $version }
}

function Get-WebView2RuntimeVersion {
    # Microsoft's documented detection: the 'pv' value under the EdgeUpdate client key.
    $guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    foreach ($k in @("HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$guid",
                     "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid",
                     "HKCU:\Software\Microsoft\EdgeUpdate\Clients\$guid")) {
        try {
            $pv = (Get-ItemProperty -Path $k -Name pv -ErrorAction Stop).pv
            if ($pv -and $pv -ne '0.0.0.0') { return [string]$pv }
        } catch { }
    }
    return $null
}

$script:HlsJsVersion = '1.7.3'   # latest stable (github.com/video-dev/hls.js/releases, Sep 2026)
$script:HlsJsPath = $null   # set once the app data folder is known (below)
function Find-HlsJs {
    # The HLS player library used by the audio bar and the built-in video player.
    try {
        $f = Get-Item -LiteralPath $script:HlsJsPath -ErrorAction Stop
        if ($f.Length -gt 100KB) { return $f.FullName }
    } catch { }
    return $null
}

function Get-HlsJsInstalledVersion {
    # the version the installer wrote next to the file (older installs have none: "older")
    try { $v = ([IO.File]::ReadAllText((Join-Path (Split-Path -Parent $script:HlsJsPath) 'version.txt'))).Trim(); if ($v -match '^\d+(\.\d+)+$') { return $v } } catch { }
    return ''
}

function Get-DependencyStatus {
    # One row per component the app relies on. Method says how it gets installed.
    $rows = New-Object Collections.Generic.List[object]
    $wg = Find-Winget
    $rt = Get-WebView2RuntimeVersion
    $sdk = Find-WebView2Sdk (Join-Path $script:AppDataDir 'webview2-sdk')
    $ff = Find-FFmpeg -Refresh   # (the components window: always the real state)
    $hls = Find-HlsJs

    $rows.Add([pscustomobject]@{ Key = 'webview2-runtime'; Name = 'Microsoft Edge WebView2 Runtime'
        Purpose = "The Edge engine that plays NRK's TV player and the radio audio bar inside this app. Normally part of Windows 10/11."
        Found = [bool]$rt; Detail = $(if ($rt) { "version $rt" } else { 'not installed' })
        Method = 'winget'; Package = 'Microsoft.EdgeWebView2Runtime'; Admin = $true })
    $rows.Add([pscustomobject]@{ Key = 'webview2-sdk'; Name = "WebView2 SDK for .NET $($script:WebView2PackageVersion)"
        Purpose = 'Microsoft library that lets PowerShell show the player. About 5 MB from nuget.org, stored in your user profile.'
        Found = [bool]$sdk; Detail = $(if ($sdk) { Split-Path -Parent $sdk.WinForms } else { 'not downloaded' })
        Method = 'nuget'; Package = 'Microsoft.Web.WebView2'; Admin = $false })
    $rows.Add([pscustomobject]@{ Key = 'ffmpeg'; Name = 'FFmpeg'
        Purpose = 'Downloads (TV with subtitles, chapters and cover; radio as M4A, MP3 or FLAC) and casting to a TV.'
        Found = $ff.Found; Detail = $(if ($ff.Found) { $ff.Path } else { 'not installed' })
        Method = 'winget'; Package = 'Gyan.FFmpeg'; Admin = $false })
    $hlsVer = if ($hls) { Get-HlsJsInstalledVersion } else { '' }
    $hlsOld = $hls -and (-not $hlsVer -or ([version]$hlsVer -lt [version]$script:HlsJsVersion))
    $rows.Add([pscustomobject]@{ Key = 'hlsjs'; Name = "hls.js $($script:HlsJsVersion) (radio and video player)"
        Purpose = 'Plays NRK streams (HLS) in the audio bar and the built-in video player. One JavaScript file (~500 KB), stored in your user profile.'
        Found = ([bool]$hls -and -not $hlsOld)
        Detail = $(if (-not $hls) { 'not downloaded' } elseif ($hlsOld) { "update available: $(if ($hlsVer) { $hlsVer } else { 'older version' }) installed" } else { "$hlsVer  ·  $hls" })
        Method = 'download'; Package = 'hls.js'; Admin = $false })
    $rows.Add([pscustomobject]@{ Key = 'winget'; Name = 'Windows Package Manager (winget)'
        Purpose = 'Installs the components above. Only needed if one of them is missing.'
        Found = $wg.Found; Detail = $(if ($wg.Found) { "$($wg.Version)" } else { 'not installed' })
        Method = 'bootstrap'; Package = 'Microsoft.DesktopAppInstaller'; Admin = $false })
    return $rows
}

# Installer that runs as a separate, hidden Windows PowerShell process so the GUI stays
# responsive. It reports progress through a status file and logs everything with Start-Transcript.
$script:DependencyInstallScript = @'
# NRK Browser installer. Runs hidden and works through a plan, one step per item:
#   sdk-remove | sdk-install | hlsjs-remove | hlsjs-install | winget-ensure | winget-repair
#   winget-install=Id|Name | winget-install-force=Id|Name | winget-uninstall=Id|Name | note=Text
# The app shows progress by reading
#   -StatusPath     : one line "step|total|state|text" (state = running, done, failed)
#   -TranscriptPath : full output, shown under the progress bar and copied to the log
param(
    [string] $TranscriptPath,
    [string] $StatusPath,
    [string] $Plan = '',
    [string] $WebView2SdkRoot = '',
    [string] $WebView2SdkVersion = '',
    [string] $HlsJsPath = '',
    [string] $HlsJsVersion = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Start-Transcript -Path $TranscriptPath -Append | Out-Null
$problems = New-Object System.Collections.Generic.List[string]
$steps = @($Plan -split ';' | Where-Object { $_.Trim() })
$total = $steps.Count
$script:step = 0

function Set-InstallStatus([string] $State, [string] $Text) {
    $line = '{0}|{1}|{2}|{3}' -f $script:step, $total, $State, $Text
    for ($i = 0; $i -lt 5; $i++) {   # the app may be reading the file at the same moment
        try { [IO.File]::WriteAllText($StatusPath, $line, (New-Object Text.UTF8Encoding($false))); break } catch { Start-Sleep -Milliseconds 100 }
    }
}
function Start-Step([string] $Text) {
    $script:step++
    Write-Host ''
    Write-Host "==> [$($script:step)/$total] $Text"
    Set-InstallStatus 'running' $Text
}
function Invoke-Logged {
    # Runs a native command and copies its output into the transcript line by line.
    # Spinner/progress-bar redraws (\r) are reduced to their final state.
    param([string] $Exe, [string[]] $Arguments)
    $ErrorActionPreference = 'Continue'   # stderr lines (pip warnings, winget notes) must not abort
    & $Exe @Arguments 2>&1 | ForEach-Object {
        $t = [string]$_
        $t = ($t -split "`r" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if ($t -and $t.Trim() -notmatch '^[-\\|/]$') { Write-Host "    $t" }
    }
    return $LASTEXITCODE
}
function Update-Path {
    $parts = @(); foreach ($src in @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'), $env:Path)) {
        if ($src) { foreach ($p in ($src -split ';')) { if ($p -and $parts -notcontains $p) { $parts += $p } } } }
    $env:Path = $parts -join ';'
}
function Find-Winget {
    Update-Path
    $c = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $p) { return $p }
    return $null
}
function Invoke-WingetBootstrap([switch] $Repair) {
    # Re-register App Installer, then (if still missing, or when repairing) Microsoft.WinGet.Client + Repair-WinGetPackageManager
    $w = Find-Winget
    if (-not $w -or $Repair) {
        Write-Host '    re-registering App Installer (Microsoft.DesktopAppInstaller)'
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe }
        catch { Write-Host "    re-register failed: $($_.Exception.Message)" }
        Start-Sleep -Seconds 3; $w = Find-Winget
    }
    if (-not $w -or $Repair) {
        Write-Host '    installing Microsoft.WinGet.Client (PowerShell Gallery), then Repair-WinGetPackageManager'
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
            Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
            Import-Module Microsoft.WinGet.Client -Force
            Repair-WinGetPackageManager | Out-String | Write-Host
        } catch { Write-Host "    repair failed: $($_.Exception.Message)" }
        Start-Sleep -Seconds 3; $w = Find-Winget
    }
    return $w
}
function Get-Winget {
    if (-not $script:winget) { $script:winget = Find-Winget }
    if (-not $script:winget) { $script:winget = Invoke-WingetBootstrap }
    return $script:winget
}

try {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $elevated = try { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { 'unknown' }
    Write-Host "=== NRK Browser installer $(Get-Date -Format s) | $([Environment]::OSVersion.VersionString) | PowerShell $($PSVersionTable.PSVersion) | elevated: $elevated"
    Write-Host "Plan ($total steps): $($steps -join '  ->  ')"
    Set-InstallStatus 'running' 'Preparing'
    $script:winget = $null

    foreach ($item in $steps) {
        $action, $arg = $item.Trim() -split '=', 2
        $id, $name = "$arg" -split '\|', 2
        if (-not $name) { $name = $id }
        switch ($action) {
            'note' { Start-Step $arg; Write-Host "    $arg" }
            'sdk-remove' {
                Start-Step 'Removing WebView2 SDK'
                if (Test-Path $WebView2SdkRoot) {
                    try { Remove-Item $WebView2SdkRoot -Recurse -Force; Write-Host "    removed $WebView2SdkRoot" }
                    catch { Write-Host "    some files are in use (the player has loaded them); a fresh copy is put next to them and used from the next start" }
                } else { Write-Host '    not present' }
            }
            'sdk-install' {
                Start-Step "Downloading WebView2 SDK $WebView2SdkVersion (nuget.org)"
                try {
                    New-Item -ItemType Directory -Path $WebView2SdkRoot -Force | Out-Null
                    $zip = Join-Path $WebView2SdkRoot 'webview2.nupkg.zip'
                    $got = $false
                    foreach ($u in @("https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$WebView2SdkVersion", 'https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2')) {
                        try {
                            Write-Host "    GET $u"
                            Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing -TimeoutSec 180
                            Write-Host ('    {0:N0} bytes' -f (Get-Item $zip).Length)
                            $got = $true; break
                        } catch { Write-Host "    failed: $($_.Exception.Message)" }
                    }
                    if (-not $got) { throw 'download from nuget.org failed' }
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    $dest = Join-Path $WebView2SdkRoot 'pkg'
                    if (Test-Path $dest) {
                        try { Remove-Item $dest -Recurse -Force } catch { $dest = Join-Path $WebView2SdkRoot ('pkg-' + (Get-Date -Format 'yyyyMMddHHmmss')) }
                    }
                    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
                    Remove-Item $zip -Force -ErrorAction SilentlyContinue
                    Write-Host "    extracted to $dest"
                } catch { $problems.Add("WebView2 SDK: $($_.Exception.Message)") }
            }
            'hlsjs-remove' {
                Start-Step 'Removing hls.js'
                if (Test-Path $HlsJsPath) { Remove-Item $HlsJsPath -Force; Write-Host "    removed $HlsJsPath" } else { Write-Host '    not present' }
            }
            'hlsjs-install' {
                Start-Step "Downloading hls.js $HlsJsVersion"
                try {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $HlsJsPath) -Force | Out-Null
                    $tmp = "$HlsJsPath.download"
                    $got = $false
                    foreach ($u in @("https://cdn.jsdelivr.net/npm/hls.js@$HlsJsVersion/dist/hls.min.js", "https://unpkg.com/hls.js@$HlsJsVersion/dist/hls.min.js")) {
                        try {
                            Write-Host "    GET $u"
                            Invoke-WebRequest -Uri $u -OutFile $tmp -UseBasicParsing -TimeoutSec 120
                            $len = (Get-Item $tmp).Length
                            # the UMD wrapper registers the global at the very end: "...).Hls=i()}"
                            $body = [IO.File]::ReadAllText($tmp)
                            if ($len -lt 100KB -or $body -notmatch '\bHls\b' -or $body -match '^\s*<') { throw "unexpected file ($len bytes)" }
                            Write-Host ('    {0:N0} bytes' -f $len)
                            Move-Item $tmp $HlsJsPath -Force
                            $got = $true; break
                        } catch { Write-Host "    failed: $($_.Exception.Message)" }
                    }
                    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                    if (-not $got) { throw 'download failed from both cdn.jsdelivr.net and unpkg.com' }
                    [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $HlsJsPath) 'version.txt'), $HlsJsVersion)
                    Write-Host "    saved to $HlsJsPath (version $HlsJsVersion)"
                } catch { $problems.Add("hls.js: $($_.Exception.Message)") }
            }
            'winget-ensure' {
                Start-Step 'Checking winget (Windows Package Manager)'
                $w = Get-Winget
                if ($w) { Write-Host "    winget: $w ($(& $w --version))" }
                else { $problems.Add('winget could not be installed automatically. Install "App Installer" from the Microsoft Store: https://apps.microsoft.com/detail/9nblggh4nns1') }
            }
            'winget-repair' {
                Start-Step 'Repairing winget (re-register App Installer + Repair-WinGetPackageManager)'
                $script:winget = Invoke-WingetBootstrap -Repair
                if ($script:winget) { Write-Host "    winget: $($script:winget) ($(& $script:winget --version))" }
                else { $problems.Add('winget repair did not succeed - see the output above') }
            }
            { $_ -in 'winget-install', 'winget-install-force' } {
                Start-Step "Installing $name ($id)"
                $w = Get-Winget
                if (-not $w) { $problems.Add("$($name): skipped, winget is not available"); break }
                $wgArgs = @('install', '--id', $id, '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
                if ($id -like 'Python.Python.*') { $wgArgs += @('--scope', 'user') }   # per-user Python: no admin needed
                if ($action -eq 'winget-install-force') { $wgArgs += '--force' }
                $code = Invoke-Logged $w $wgArgs
                Write-Host "    winget exit code: $code"
            }
            'winget-uninstall' {
                Start-Step "Uninstalling $name ($id)"
                $w = Get-Winget
                if (-not $w) { $problems.Add("$($name): cannot uninstall, winget is not available"); break }
                $code = Invoke-Logged $w @('uninstall', '--id', $id, '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
                if ($code -ne 0) { Write-Host "    winget exit code $code - probably not installed through winget; continuing with the install" }
                else { Write-Host '    uninstalled' }
            }
            default { Start-Step "Unknown step '$item'"; $problems.Add("unknown plan step '$item'") }
        }
    }
} catch {
    $problems.Add("$($_.Exception.GetType().FullName): $($_.Exception.Message)")
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
} finally {
    Write-Host ''
    Write-Host "=== installer finished $(Get-Date -Format s); problems: $($problems.Count)"
    foreach ($p in $problems) { Write-Host "  - $p" }
    if ($problems.Count -eq 0) { Set-InstallStatus 'done' 'Finished' }
    else { Set-InstallStatus 'failed' ($problems -join ' / ') }
    try { Stop-Transcript | Out-Null } catch { }
}
if ($problems.Count -eq 0) { exit 0 } else { exit 1 }
'@

function Get-InstallPlan {
    # Turns "install these / reinstall these" into installer steps (see the script header).
    param([string[]] $Install = @(), [string[]] $Reinstall = @(), [object[]] $Status = @())
    $plan = New-Object Collections.Generic.List[string]
    foreach ($k in $Reinstall) {
        switch ($k) {
            'webview2-sdk'     { $plan.Add('sdk-remove'); $plan.Add('sdk-install') }
            'hlsjs'            { $plan.Add('hlsjs-remove'); $plan.Add('hlsjs-install') }
            'webview2-runtime' { $plan.Add('note=WebView2 Runtime is part of Windows and cannot be uninstalled - reinstalling over it'); $plan.Add('winget-install-force=Microsoft.EdgeWebView2Runtime|Microsoft Edge WebView2 Runtime') }
            'ffmpeg'           { $plan.Add('winget-uninstall=Gyan.FFmpeg|FFmpeg'); $plan.Add('winget-install=Gyan.FFmpeg|FFmpeg') }
            'winget'           { $plan.Add('winget-repair') }
        }
    }
    foreach ($k in $Install) {
        switch ($k) {
            'webview2-sdk'     { $plan.Add('sdk-install') }
            'hlsjs'            { $plan.Add('hlsjs-install') }
            'webview2-runtime' { $plan.Add('winget-install=Microsoft.EdgeWebView2Runtime|Microsoft Edge WebView2 Runtime') }
            'ffmpeg'           { $plan.Add('winget-install=Gyan.FFmpeg|FFmpeg') }
            'winget'           { $plan.Add('winget-ensure') }
        }
    }
    # winget must be ready before any winget step: make sure it is checked first
    $needsWinget = @($plan | Where-Object { $_ -like 'winget-install*' -or $_ -like 'winget-uninstall*' }).Count -gt 0
    if ($needsWinget -and -not ($plan -contains 'winget-ensure') -and -not ($plan -contains 'winget-repair')) { $plan.Insert(0, 'winget-ensure') }
    elseif ($plan -contains 'winget-ensure') { [void]$plan.Remove('winget-ensure'); $plan.Insert(0, 'winget-ensure') }
    return , $plan.ToArray()
}

function Start-DependencyInstall {
    # Starts the installer hidden; returns the process plus the files it reports progress through.
    param([string[]] $Plan)
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $tmp = [IO.Path]::GetTempPath()
    $scriptFile = Join-Path $tmp "NRK-Browser_install_$stamp.ps1"
    $statusFile = Join-Path $tmp "NRK-Browser_install_$stamp.status"
    $transcript = Join-Path $tmp "NRK-Browser_install_$stamp.log"   # copied into the app log when done, then removed
    [IO.File]::WriteAllText($scriptFile, $script:DependencyInstallScript, (New-Object Text.UTF8Encoding($true)))

    # Windows PowerShell is preferred: Add-AppxPackage and PowerShellGet are native there.
    $winPs = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { $null }
    $exe = if ($winPs -and (Test-Path -LiteralPath $winPs)) { $winPs } else { (Get-Process -Id $PID).Path }
    $argList = @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptFile`"",
                 '-TranscriptPath', "`"$transcript`"", '-StatusPath', "`"$statusFile`"", '-Plan', "`"$($Plan -join ';')`"",
                 '-WebView2SdkRoot', "`"$(Join-Path $script:AppDataDir 'webview2-sdk')`"", '-WebView2SdkVersion', $script:WebView2PackageVersion,
                 '-HlsJsPath', "`"$script:HlsJsPath`"", '-HlsJsVersion', $script:HlsJsVersion)
    Write-Log INFO ('Starting installer (hidden): "{0}" {1}' -f $exe, ($argList -join ' '))
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden -PassThru
    [pscustomobject]@{ Process = $proc; Transcript = $transcript; StatusFile = $statusFile; ScriptFile = $scriptFile }
}

function Read-InstallStatus {
    # Parses the installer's "step|total|state|text" status line.
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $line = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd().Trim() } finally { $fs.Dispose() }
        $p = $line -split '\|', 4
        if ($p.Count -lt 4) { return $null }
        return [pscustomobject]@{ Step = [int]$p[0]; Total = [int]$p[1]; State = $p[2]; Text = $p[3] }
    } catch { return $null }
}

function Read-LogTail {
    # Reads a (possibly in-use) log file; returns at most the last $MaxBytes.
    param([string] $Path, [int] $MaxBytes = 2MB)
    if (-not (Test-Path -LiteralPath $Path)) { return "(file not found: $Path)" }
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $prefix = ''
        if ($fs.Length -gt $MaxBytes) { [void]$fs.Seek(-$MaxBytes, [IO.SeekOrigin]::End); $prefix = "... (showing last $([int]($MaxBytes / 1KB)) KB)`r`n" }
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
        $text = $sr.ReadToEnd()
        return $prefix + ($text -replace "(?<!`r)`n", "`r`n")
    } finally { $fs.Dispose() }
}

#endregion

#region ---------- WebView2 (embedded NRK player) -----------------------------
# The embedded player is Microsoft Edge WebView2 showing NRK's own player page.
# Two parts are needed:
#   * WebView2 Runtime - part of Windows 10/11 (Edge). Checked, not installed by us.
#   * WebView2 SDK DLLs - downloaded once from nuget.org (official Microsoft package)
#     into %LOCALAPPDATA%\NRK-Browser\webview2-sdk.

$script:WebView2PackageVersion = '1.0.4258.31'   # latest stable on nuget.org, Oct 2026
$script:AppDataDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'NRK-Browser' } else { Join-Path ([IO.Path]::GetTempPath()) 'NRK-Browser' }
# The app used to be called "NRK TV Browser": move its data folder once (settings, WebView2
# SDK, hls.js, player data) so nothing has to be downloaded or set up again.
$script:LegacyAppDataDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'NRK-TV-Browser' } else { $null }
if ($script:LegacyAppDataDir -and (Test-Path -LiteralPath $script:LegacyAppDataDir) -and -not (Test-Path -LiteralPath $script:AppDataDir)) {
    try { Rename-Item -LiteralPath $script:LegacyAppDataDir -NewName (Split-Path -Leaf $script:AppDataDir) -ErrorAction Stop }
    catch {
        # in use (an old copy still running?): copy what matters instead
        New-Item -ItemType Directory -Path $script:AppDataDir -Force | Out-Null
        foreach ($n in 'settings.json', 'webview2-sdk', 'hls.js') {
            $src = Join-Path $script:LegacyAppDataDir $n
            if (Test-Path -LiteralPath $src) { try { Copy-Item -LiteralPath $src -Destination $script:AppDataDir -Recurse -Force } catch { } }
        }
    }
}
$script:HlsJsPath = Join-Path $script:AppDataDir 'hls.js\hls.min.js'
$script:WebView2 = @{ Loaded = $false; Error = $null; Fatal = $false; RuntimeVersion = $null; SdkDir = $null }

function Get-WebView2Arch {
    switch ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()) {
        'X64'   { 'win-x64' }
        'X86'   { 'win-x86' }
        'Arm64' { 'win-arm64' }
        default { if ([Environment]::Is64BitProcess) { 'win-x64' } else { 'win-x86' } }
    }
}

function Find-WebView2Sdk {
    param([string] $Root)
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    # newest copy first: a reinstall may put a fresh copy next to files the running app still has loaded
    $all = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' -File -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending)   # (zip extraction keeps old LastWriteTimes)
    if ($all.Count -eq 0) { return $null }
    # Windows PowerShell 5.1 = .NET Framework -> lib\net462 (or net45 in old packages).
    # PowerShell 7 = .NET -> netcoreapp3.0 build if the package has one, else net462.
    $prefs = if ($PSVersionTable.PSEdition -eq 'Desktop') { @('[\\/]net462[\\/]', '[\\/]net45[\\/]') } else { @('[\\/]netcoreapp3', '[\\/]net462[\\/]', '[\\/]net45[\\/]') }
    $winforms = $null
    foreach ($p in $prefs) { $winforms = $all | Where-Object { $_.FullName -match $p } | Select-Object -First 1; if ($winforms) { break } }
    if (-not $winforms) { $winforms = $all[0] }
    $core = Join-Path $winforms.DirectoryName 'Microsoft.Web.WebView2.Core.dll'
    $arch = Get-WebView2Arch
    $loader = Get-ChildItem -LiteralPath $Root -Recurse -Filter 'WebView2Loader.dll' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match ('[\\/]{0}[\\/]' -f [regex]::Escape($arch)) } | Select-Object -First 1
    if (-not (Test-Path -LiteralPath $core) -or -not $loader) { return $null }
    [pscustomobject]@{ WinForms = $winforms.FullName; Core = $core; LoaderDir = $loader.DirectoryName; Arch = $arch }
}

function Initialize-WebView2 {
    # Returns $true when the WebView2 control can be created. Never throws.
    if ($script:WebView2.Loaded) { return $true }
    if ($script:WebView2.Fatal) { return $false }   # assembly load failed half-way: needs an app restart
    try {
        $root = Join-Path $script:AppDataDir 'webview2-sdk'
        $sdk = Find-WebView2Sdk $root
        if (-not $sdk) { throw "The WebView2 SDK is not installed (expected under $root). Open Options > Components... to install it." }
        Write-Log INFO ("WebView2 SDK: core={0}; winforms={1}; loader={2} ({3})" -f $sdk.Core, $sdk.WinForms, $sdk.LoaderDir, $sdk.Arch)
        $script:WebView2.Fatal = $true    # from here on a failure can't be retried in this process
        Add-Type -Path $sdk.Core
        Add-Type -Path $sdk.WinForms
        $script:WebView2.Fatal = $false
        [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($sdk.LoaderDir)
        try {
            $script:WebView2.RuntimeVersion = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
        } catch {
            throw "Microsoft Edge WebView2 Runtime is not installed ($($_.Exception.Message)). Install it with: winget install Microsoft.EdgeWebView2Runtime"
        }
        if (-not $script:WebView2.RuntimeVersion) { throw 'Microsoft Edge WebView2 Runtime is not installed. Install it with: winget install Microsoft.EdgeWebView2Runtime' }
        Write-Log INFO "WebView2 Runtime version: $($script:WebView2.RuntimeVersion)"
        $script:WebView2.SdkDir = Split-Path -Parent $sdk.WinForms
        $script:WebView2.Error = $null
        $script:WebView2.Loaded = $true
        return $true
    } catch {
        Write-LogException $_ 'Initialize-WebView2'
        $script:WebView2.Error = $_.Exception.Message
        return $false
    }
}

#endregion

#region ---------- Indexer (-Index: slow background walk of the whole catalogue) -------
# A second, windowless copy of this script (started with -Index, by hand from the Indexer
# window or daily by a Windows scheduled task) walks every TV and radio category, the A-Å
# indexes, every series, season and episode list, one request at a time with a pause in
# between, and saves them in the same cache the app reads. Folders then open instantly.
# Entries saved in the last IndexFreshHours are skipped without a request, so a stopped run
# simply continues where it was. It also writes indexer\search.tsv (one line per series,
# programme and episode): what Search, New this week and Last chance read.
#   indexer\status.json   progress, written by the indexer, read by the Indexer window
#   indexer\control.json  { Command: pause | resume | stop, PaceMs } written by the window
$script:IndexMode   = $false
$script:IndexDir    = Join-Path $script:AppDataDir 'indexer'
$script:IndexStatusFile  = Join-Path $script:IndexDir 'status.json'
$script:IndexControlFile = Join-Path $script:IndexDir 'control.json'
$script:IndexFile   = Join-Path $script:IndexDir 'index.jsonl'   # (older versions wrote it; removed on the next run)
$script:SearchFile  = Join-Path $script:IndexDir 'search.tsv'    # what "search everything" looks through
$script:EmptyFile   = Join-Path $script:IndexDir 'empty.txt'     # folders NRK has nothing in
$script:IndexTaskName = 'NRK Browser indexer'
$script:IndexFreshMin = 20 * 60
$script:IndexPaceMs = 1000
$script:Idx = $null

function Read-JsonFile([string] $Path) {
    # $null when the file is not there; a damaged file is logged and kept as <name>.damaged
    # (the app then starts that list empty instead of silently losing it)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop) }
    catch {
        $keep = "$Path.damaged"
        try { Copy-Item -LiteralPath $Path -Destination $keep -Force -ErrorAction Stop; $where = " (a copy is kept as $keep)" } catch { $where = '' }
        try { Write-Log WARN ('Could not read {0}: {1}{2}' -f $Path, $_.Exception.Message, $where) } catch { }
        return $null
    }
}

function Write-JsonFile([string] $Path, $Object) {
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $tmp = "$Path.$PID.tmp"
        [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        Write-Log WARN ('Could not save {0}: {1}' -f $Path, $_.Exception.Message)
        try { if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

function Write-IndexStatus([switch] $Force) {
    $x = $script:Idx
    if (-not $x) { return }
    $now = Get-Date
    if (-not $Force -and ($now - $x.LastWrite).TotalMilliseconds -lt 1500) { return }
    $x.LastWrite = $now
    $eta = $null
    if ($x.PhaseTotal -gt 0 -and $x.PhaseDone -gt 0 -and $x.State -eq 'running') {
        $secs = ($now - $x.PhaseStarted).TotalSeconds - $x.PhasePaused
        $eta = [int]([Math]::Max(0, $secs / $x.PhaseDone * ($x.PhaseTotal - $x.PhaseDone)))
    }
    Write-JsonFile $script:IndexStatusFile ([ordered]@{
        State = $x.State; Pid = $PID; Version = $script:AppVersion
        Started = $x.Started.ToString('o'); Updated = $now.ToString('o'); Finished = $x.Finished
        Phase = $x.Phase; PhaseNo = $x.PhaseNo; PhaseCount = 6; PhaseDone = $x.PhaseDone; PhaseTotal = $x.PhaseTotal; EtaSeconds = $eta
        Current = $x.Current; PaceMs = $script:IndexPaceMs
        Requests = $x.Fetched; Skipped = $x.Cached; Errors = $x.Errors; LastError = $x.LastError
        TvSeries = $x.Tv.Count; RadioSeries = $x.Radio.Count; Programs = $x.Programs.Count; Episodes = $x.Episodes
        LastFull = $x.LastFull; LastFullSeconds = $x.LastFullSeconds
    })
}

function Read-IndexControl {
    # reads control.json only when it changed
    $x = $script:Idx
    try {
        if (-not (Test-Path -LiteralPath $script:IndexControlFile)) { return }
        $t = (Get-Item -LiteralPath $script:IndexControlFile).LastWriteTimeUtc
        if ($t -eq $x.ControlTime) { return }
        $x.ControlTime = $t
        $c = Read-JsonFile $script:IndexControlFile
        if (-not $c) { return }
        if ($c.PaceMs) { $script:IndexPaceMs = [Math]::Max(0, [Math]::Min(60000, [int]$c.PaceMs)) }
        switch ([string]$c.Command) {
            'pause'  { if ($x.State -eq 'running') { $x.State = 'paused'; Write-Log INFO 'Indexer: paused' } }
            'resume' { if ($x.State -eq 'paused') { $x.State = 'running'; Write-Log INFO 'Indexer: resumed' } }
            'stop'   { $x.State = 'stopping'; Write-Log INFO 'Indexer: stop requested' }
        }
    } catch { }
}

function Wait-IndexPace {
    # after every request to NRK: wait PaceMs (plus any back-off), stay paused while asked, stop when asked
    $x = $script:Idx
    $wait = $script:IndexPaceMs + $x.Backoff
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        Read-IndexControl
        if ($x.State -eq 'stopping') { throw (New-Object System.OperationCanceledException('Indexer stopped')) }
        if ($x.State -eq 'paused') {
            $p0 = Get-Date
            Write-IndexStatus -Force
            Start-Sleep -Milliseconds 500
            $x.PhasePaused += ((Get-Date) - $p0).TotalSeconds
            continue
        }
        $left = $wait - $sw.ElapsedMilliseconds
        if ($left -le 0) { break }
        Start-Sleep -Milliseconds ([Math]::Min(250, [int]$left))
        Write-IndexStatus
    }
}

function Register-IndexFetch([bool] $Ok, $Code) {
    # called by Invoke-NrkApi for every request it sends while indexing
    $x = $script:Idx
    $x.Fetched++
    if ($Ok) { $x.Backoff = [Math]::Max(0, [int]($x.Backoff / 2)) }
    elseif ("$Code" -match '^(429|5\d\d|n/a)$') {
        # NRK says slow down, or the connection failed: wait longer, up to a minute
        $x.Backoff = [Math]::Min(60000, [Math]::Max(5000, $x.Backoff * 2))
        Write-Log WARN "Indexer: HTTP $Code, waiting $([int]($x.Backoff / 1000)) s longer between requests"
    }
    Wait-IndexPace
}

function Invoke-IndexStep([string] $What, [scriptblock] $Action) {
    # one unit of work; an NRK error is counted and the walk goes on
    $x = $script:Idx
    $x.Current = $What
    Read-IndexControl
    if ($x.State -eq 'stopping') { throw (New-Object System.OperationCanceledException('Indexer stopped')) }
    if ($x.State -eq 'paused') { Wait-IndexPace }
    Write-IndexStatus
    try { & $Action }
    catch [System.OperationCanceledException] { throw }
    catch {
        if ($_.Exception -is [System.OperationCanceledException] -or $_.Exception.InnerException -is [System.OperationCanceledException]) { throw }
        $x.Errors++; $x.LastError = "${What}: $($_.Exception.Message)"
        Write-Log WARN "Indexer: $($x.LastError)"
    }
}

function Start-IndexPhase([int] $No, [string] $Name, [int] $Total) {
    $x = $script:Idx
    $x.PhaseNo = $No; $x.Phase = $Name; $x.PhaseTotal = $Total; $x.PhaseDone = 0
    $x.PhaseStarted = Get-Date; $x.PhasePaused = 0
    Write-Log INFO "Indexer: phase $No/6 $Name ($Total)"
    Write-IndexStatus -Force
}

function Add-IndexSeries([hashtable] $Map, [string] $Key, $Item, [string] $Where) {
    $x = $script:Idx
    if ($x -and $x.Hidden) {
        $hk = if ($Item.Type -eq 'series') { "series|$($Item.Id)" } elseif ($Item.Type -eq 'radioseries') { "radioseries|$($Item.Kind)|$($Item.Id)" } else { "file|$($Item.Type)|$($Item.Id)" }
        if ($x.Hidden.Contains($hk)) { return }
    }
    if (-not $Map.ContainsKey($Key)) { $Map[$Key] = @{ Item = $Item; Where = New-Object System.Collections.Generic.List[string] } }
    if ($Where -and -not $Map[$Key].Where.Contains($Where)) { $Map[$Key].Where.Add($Where) }
}


function Add-SearchRow {
    # one line of search.tsv: type, id, title, subtitle, series id, series title, season, kind, date,
    # available from, available to, year (from/to: sortable local times; used by New this week / Last chance)
    param([string] $Type, [string] $Id, [string] $Title, [string] $Sub = '', [string] $SeriesId = '', [string] $SeriesTitle = '', [string] $Season = '', [string] $Kind = '', [string] $Date = '', $Rights = $null)
    $w = $script:Idx.SearchW
    if (-not $w -or -not $Id) { return }
    $f = foreach ($v in @($Type, $Id, $Title, $Sub, $SeriesId, $SeriesTitle, $Season, $Kind, $Date, $Rights.AvailableFrom, $Rights.AvailableTo, $Rights.Year)) { ([string]$v) -replace '[\t\r\n]+', ' ' }
    $w.WriteLine(($f -join "`t"))
}

function Invoke-Indexer {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\NRK-Browser-Indexer')
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { Write-Log INFO 'Indexer: another indexer is already running; exiting'; return }
    try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }

    $script:IndexMode = $true
    $script:CacheMode = 'Daily'          # every catalogue/page is cacheable while indexing
    $script:CacheBypassUntil = [datetime]::MinValue
    $set = Read-JsonFile (Join-Path $script:AppDataDir 'settings.json')
    if ($set -and $null -ne $set.IndexPaceMs) { $script:IndexPaceMs = [Math]::Max(0, [int]$set.IndexPaceMs) }
    if ($set -and $set.IndexFreshHours) { $script:IndexFreshMin = [Math]::Max(1, [int]$set.IndexFreshHours) * 60 }
    $prev = Read-JsonFile $script:IndexStatusFile
    New-Item -ItemType Directory -Path $script:IndexDir -Force | Out-Null
    Remove-Item -LiteralPath $script:IndexControlFile -Force -ErrorAction SilentlyContinue
    # a run that was killed (shutdown, crash) leaves its unfinished list behind
    foreach ($t in @(Get-ChildItem -LiteralPath $script:IndexDir -Filter '*.tmp' -File -ErrorAction SilentlyContinue)) { try { Remove-Item -LiteralPath $t.FullName -Force } catch { } }

    $script:Idx = @{
        State = 'running'; Started = (Get-Date); Finished = $null; LastWrite = [datetime]::MinValue; ControlTime = $null
        Phase = 'Starting'; PhaseNo = 0; PhaseDone = 0; PhaseTotal = 0; PhaseStarted = (Get-Date); PhasePaused = 0
        Current = ''; Fetched = 0; Cached = 0; Errors = 0; LastError = ''; Backoff = 0; Episodes = 0
        Tv = @{}; Radio = @{}; Programs = @{}
        LastFull = $(if ($prev) { $prev.LastFull } else { $null }); LastFullSeconds = $(if ($prev) { $prev.LastFullSeconds } else { $null })
        SearchTmp = Join-Path $script:IndexDir "search.$PID.tmp"; SearchW = $null
        Empty = New-Object System.Collections.Generic.List[string]   # folders NRK has nothing in (hidden in the app)
    }
    $x = $script:Idx
    # what you hid (Options > Hidden items): never fetched or listed again
    $x.Hidden = New-Object 'System.Collections.Generic.HashSet[string]'
    $ex = Read-JsonFile (Join-Path $script:AppDataDir 'excluded.json')
    if ($ex) { foreach ($r in @($ex.Items | Where-Object { $_ -and $_.Key })) { [void]$x.Hidden.Add([string]$r.Key) } }
    Write-Log INFO ("Indexer {0} started: pace {1} ms, entries younger than {2} h are skipped" -f $script:AppVersion, $script:IndexPaceMs, ($script:IndexFreshMin / 60))
    Write-IndexStatus -Force
    try {
        Remove-Item -LiteralPath $script:IndexFile -Force -ErrorAction SilentlyContinue   # (index.jsonl from older versions: nothing reads it)
        $x.SearchW = New-Object System.IO.StreamWriter($x.SearchTmp, $false, (New-Object Text.UTF8Encoding($false)))
        $x.SearchW.WriteLine("#nrkb-search 2")

        # 1. TV categories
        $cats = @(); Invoke-IndexStep 'TV categories' { $script:IdxCats = @(Get-NrkCategories) }; $cats = @($script:IdxCats)
        Start-IndexPhase 1 'TV categories' $cats.Count
        foreach ($c in $cats) {
            if ($x.Hidden.Contains("category|$($c.Id)")) { $x.PhaseDone++; continue }
            Invoke-IndexStep "TV category $($c.Title)" {
                $items = @(Get-NrkCategoryItems -PageId $c.Id)
                if ($items.Count -eq 0) { $x.Empty.Add("category|$($c.Id)") }
                foreach ($it in $items) {
                    if ($it.Type -eq 'series') { Add-IndexSeries $x.Tv $it.Id $it $c.Title }
                    elseif ($it.Type -eq 'program') { Add-IndexSeries $x.Programs $it.Id $it $c.Title }
                }
            }
            $x.PhaseDone++
        }
        # 2. TV A-Å
        $letters = @(); Invoke-IndexStep 'TV A-Å' { $script:IdxLetters = @(Get-NrkLetters) }; $letters = @($script:IdxLetters)
        Start-IndexPhase 2 'TV A-Å' $letters.Count
        foreach ($l in $letters) {
            if ($x.Hidden.Contains("letter|$($l.Id)")) { $x.PhaseDone++; continue }
            Invoke-IndexStep "TV letter $($l.Title)" {
                $items = @(Get-NrkLetterItems -Letter $l.Id)
                if ($items.Count -eq 0) { $x.Empty.Add("letter|$($l.Id)") }
                foreach ($it in $items) {
                    if ($it.Type -eq 'series') { Add-IndexSeries $x.Tv $it.Id $it '' }
                    elseif ($it.Type -eq 'program') { Add-IndexSeries $x.Programs $it.Id $it '' }
                }
            }
            $x.PhaseDone++
        }
        # 3. Radio categories
        $rcats = @(); Invoke-IndexStep 'Radio categories' { $script:IdxRcats = @(Get-NrkRadioCategories) }; $rcats = @($script:IdxRcats)
        Start-IndexPhase 3 'Radio categories' $rcats.Count
        foreach ($c in $rcats) {
            if ($x.Hidden.Contains("radiocategory|$($c.Id)")) { $x.PhaseDone++; continue }
            Invoke-IndexStep "Radio category $($c.Title)" {
                $items = @(Get-NrkRadioPageItems -PageId $c.Id)
                if ($items.Count -eq 0) { $x.Empty.Add("radiocategory|$($c.Id)") }
                foreach ($it in $items) {
                    if ($it.Type -eq 'radioseries') { Add-IndexSeries $x.Radio "$($it.Kind)|$($it.Id)" $it $c.Title }
                }
            }
            $x.PhaseDone++
        }
        # 4. Radio A-Å
        $rl = @(); Invoke-IndexStep 'Radio A-Å' { $script:IdxRl = @(Get-NrkRadioLetters) }; $rl = @($script:IdxRl)
        Start-IndexPhase 4 'Radio A-Å' $rl.Count
        foreach ($l in $rl) {
            if ($x.Hidden.Contains("radioletter|$($l.Id)")) { $x.PhaseDone++; continue }
            Invoke-IndexStep "Radio letter $($l.Title)" {
                $items = @(Get-NrkRadioLetterItems -Letter $l.Id)
                if ($items.Count -eq 0) { $x.Empty.Add("radioletter|$($l.Id)") }
                foreach ($it in $items) {
                    if ($it.Type -eq 'radioseries') { Add-IndexSeries $x.Radio "$($it.Kind)|$($it.Id)" $it '' }
                }
            }
            $x.PhaseDone++
        }
        foreach ($k in $x.Programs.Keys) {
            $p = $x.Programs[$k]
            Add-SearchRow tvprogram $p.Item.Id $p.Item.Title $p.Item.Description -Rights $p.Item
        }
        # 5. TV series: seasons and episode lists
        Start-IndexPhase 5 'TV series' $x.Tv.Count
        foreach ($k in @($x.Tv.Keys | Sort-Object)) {
            $s = $x.Tv[$k]
            Invoke-IndexStep "TV $($s.Item.Title)" {
                $info = Get-NrkSeriesInfo -SeriesId $s.Item.Id
                $total = 0
                Add-SearchRow tvseries $s.Item.Id $s.Item.Title $s.Item.Description
                foreach ($sea in @($info.Seasons)) {
                    if ($x.Hidden.Contains("season|$($s.Item.Id)|$($sea.Name)")) { continue }
                    $eps = @(Get-NrkSeasonEpisodes -SeriesId $s.Item.Id -Season $sea.Name | Where-Object { -not $x.Hidden.Contains("file|episode|$($_.Id)") })
                    $x.Episodes += $eps.Count; $total += $eps.Count
                    if ($eps.Count -eq 0) { $x.Empty.Add("season|$($s.Item.Id)|$($sea.Name)") }
                    foreach ($e in $eps) { Add-SearchRow tvepisode $e.Id $e.Title $e.Subtitle $s.Item.Id $s.Item.Title $sea.Name -Rights $e }
                }
                if ($total -eq 0) { $x.Empty.Add("series|$($s.Item.Id)") }
            }
            $x.PhaseDone++
        }
        # 6. Radio series and podcasts
        Start-IndexPhase 6 'Radio series and podcasts' $x.Radio.Count
        foreach ($k in @($x.Radio.Keys | Sort-Object)) {
            $s = $x.Radio[$k]
            Invoke-IndexStep "Radio $($s.Item.Title)" {
                $info = Get-NrkRadioSeriesInfo -Kind $s.Item.Kind -Id $s.Item.Id
                $total = 0
                $stitle = if ($info.Title) { $info.Title } else { $s.Item.Title }
                Add-SearchRow radioseries $s.Item.Id $stitle $s.Item.Description '' '' '' $s.Item.Kind
                foreach ($sea in @($info.Seasons)) {
                    if ($x.Hidden.Contains("radioseason|$($s.Item.Id)|$($sea.Name)")) { continue }
                    $eps = @(Get-NrkRadioEpisodes -Href $sea.Href -Kind $s.Item.Kind -SeriesId $s.Item.Id -SeriesTitle $info.Title -Newest:$sea.Newest)
                    $eps = @($eps | Where-Object { -not $x.Hidden.Contains("file|audio|$($_.Id)") })
                    $x.Episodes += $eps.Count; $total += $eps.Count
                    if ($eps.Count -eq 0) { $x.Empty.Add("radioseason|$($s.Item.Id)|$($sea.Name)") }
                    foreach ($e in $eps) { Add-SearchRow radioepisode $e.Id $e.Title $e.Description $s.Item.Id $stitle $sea.Name $s.Item.Kind $e.Date -Rights $e }
                }
                if ($total -eq 0) { $x.Empty.Add("radioseries|$($s.Item.Kind)|$($s.Item.Id)") }
            }
            $x.PhaseDone++
        }

        $x.SearchW.Close(); $x.SearchW = $null
        Move-Item -LiteralPath $x.SearchTmp -Destination $script:SearchFile -Force
        # only a complete walk knows what is empty
        [IO.File]::WriteAllLines($script:EmptyFile, [string[]]@($x.Empty | Select-Object -Unique), (New-Object Text.UTF8Encoding($false)))
        $x.State = 'done'
        $x.LastFull = (Get-Date).ToString('o'); $x.LastFullSeconds = [int]((Get-Date) - $x.Started).TotalSeconds
        $x.Phase = 'Finished'; $x.Current = ''
        Write-Log INFO ("Indexer finished in {0:N0} min: {1} TV series, {2} programmes, {3} radio series/podcasts, {4} episodes; {5} requests, {6} up to date, {7} errors" -f `
            ($x.LastFullSeconds / 60), $x.Tv.Count, $x.Programs.Count, $x.Radio.Count, $x.Episodes, $x.Fetched, $x.Cached, $x.Errors)
    } catch {
        if ($_.Exception -is [System.OperationCanceledException] -or $_.Exception.InnerException -is [System.OperationCanceledException] -or $x.State -eq 'stopping') {
            $x.State = 'stopped'; $x.Current = ''
            # no search list yet: the part found so far is better than nothing
            if (-not (Test-Path -LiteralPath $script:SearchFile) -and $x.SearchW) {
                try { $x.SearchW.Close(); $x.SearchW = $null; Move-Item -LiteralPath $x.SearchTmp -Destination $script:SearchFile -Force } catch { }
            }
            Write-Log INFO ("Indexer stopped: {0} requests, {1} up to date. The next run continues from the saved data." -f $x.Fetched, $x.Cached)
        } else {
            $x.State = 'failed'; $x.LastError = $_.Exception.Message
            Write-LogException $_ 'Indexer'
        }
    } finally {
        if ($x.SearchW) { try { $x.SearchW.Close() } catch { } }
        Remove-Item -LiteralPath $x.SearchTmp -Force -ErrorAction SilentlyContinue
        $x.Finished = (Get-Date).ToString('o')
        Write-IndexStatus -Force
        Remove-Item -LiteralPath $script:IndexControlFile -Force -ErrorAction SilentlyContinue
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}

#endregion

#region ---------- Self-test (no GUI) -----------------------------------------

function Invoke-SelfTest {
    $results = New-Object Collections.Generic.List[object]
    function Add-Result([string]$Step, [bool]$Ok, [string]$Detail) {
        $results.Add([pscustomobject]@{ Step = $Step; Result = $(if ($Ok) { 'OK' } else { 'FAIL' }); Detail = $Detail })
        Write-Log $(if ($Ok) { 'INFO' } else { 'ERROR' }) "SELFTEST $Step : $(if ($Ok) { 'OK' } else { 'FAIL' }) $Detail"
    }

    $cats = @(); $letters = @(); $aItems = @(); $catItems = @()
    try { $cats = @(Get-NrkCategories); Add-Result 'Categories (/tv/pages)' ($cats.Count -gt 0) "$($cats.Count) categories: $(($cats | Select-Object -First 5 | ForEach-Object Title) -join ', ')..." }
    catch { Add-Result 'Categories (/tv/pages)' $false $_.Exception.Message }

    try { $letters = @(Get-NrkLetters); Add-Result 'A-Å letters' ($letters.Count -gt 0) "$($letters.Count) letters" }
    catch { Add-Result 'A-Å letters' $false $_.Exception.Message }

    try {
        $aItems = @(Get-NrkLetterItems -Letter 'A')
        $s = @($aItems | Where-Object Type -eq 'series').Count; $p = @($aItems | Where-Object Type -eq 'program').Count
        Add-Result 'Letter A items' ($aItems.Count -gt 0) "$($aItems.Count) items ($s series, $p programs)"
    } catch { Add-Result 'Letter A items' $false $_.Exception.Message }

    if ($cats.Count -gt 0) {
        $c = $cats | Where-Object Id -eq 'dokumentar' | Select-Object -First 1
        if (-not $c) { $c = $cats[0] }
        try { $catItems = @(Get-NrkCategoryItems -PageId $c.Id); Add-Result "Category '$($c.Title)' content" ($catItems.Count -gt 0) "$($catItems.Count) items" }
        catch { Add-Result "Category '$($c.Title)' content" $false $_.Exception.Message }
    }

    $all = @($catItems) + @($aItems)
    $series = $all | Where-Object Type -eq 'series' | Select-Object -First 1
    if ($series) {
        try { $si = Get-NrkSeriesInfo -SeriesId $series.Id; Add-Result "Series '$($series.Id)'" ([bool]$si.SeriesType) "type=$($si.SeriesType), $(@($si.Seasons).Count) seasons" }
        catch { Add-Result "Series '$($series.Id)'" $false $_.Exception.Message }
    }
    $prog = $all | Where-Object Type -eq 'program' | Select-Object -First 1
    if ($prog) {
        try { $pi = Get-NrkProgramInfo -ProgramId $prog.Id; Add-Result "Program '$($prog.Id)'" ([bool]$pi.Title) "'$($pi.Title)' ($($pi.Year)), playability=$($pi.Playability) $($pi.NotPlayable)" }
        catch { Add-Result "Program '$($prog.Id)'" $false $_.Exception.Message }
    }

    $results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    Write-Host 'Components:'
    Get-DependencyStatus | Format-Table @{ n = 'Component'; e = { $_.Name } }, @{ n = 'Installed'; e = { $_.Found } }, Detail -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    Write-Host "Log file: $script:LogFile"
}

#endregion

$script:ForceLogToDisk = [bool]($SelfTest -or $LogDir -or $DumpResponses)   # (asked for on the command line: always on disk)
Initialize-Log -Dir $LogDir

# Windows PowerShell 5.1 on older .NET defaults may not offer TLS 1.2, which psapi.nrk.no requires.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
}
Write-EnvironmentInfo

if ($SelfTest) { $script:CacheBypassUntil = [datetime]::MaxValue; Invoke-SelfTest; return }
if ($Index) {
    # the indexer has its own day-file next to the app's logs
    if ($script:LogDir) { $script:LogFile = Join-Path $script:LogDir ('NRK-Indexer_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd')) }
    Invoke-Indexer; return
}
if ($NoGui) { return }


# Windows Forms and WebView2 need a single-threaded apartment. Windows PowerShell
# consoles are STA by default; restart ourselves with -STA if this host is not.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    Write-Log WARN 'Not running in STA mode (required by Windows Forms/WebView2); restarting with -STA'
    $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($LogDir) { $relaunch += @('-LogDir', "`"$LogDir`"") }
    if ($DumpResponses) { $relaunch += '-DumpResponses' }
    if ($ShowConsole) { $relaunch += '-ShowConsole' }
    if ($Tray) { $relaunch += '-Tray' }
    if ($UpdatedFrom) { $relaunch += @('-UpdatedFrom', $UpdatedFrom) }
    if ($UpdateResult) { $relaunch += @('-UpdateResult', "`"$UpdateResult`"") }
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $relaunch | Out-Null
    return
}

# One copy at a time. A second start talks to the running copy over a named pipe (IPC):
#   INFO -> "OK <version>|<pid>|<script path>"     SHOW -> brings its window to the front
#   EXIT -> closes it ("BUSY ..." while a download runs)
# When this file is a newer version than the running copy, it offers to close that copy and
# carry on (the install check below then upgrades the installed copy). Copies from before
# the pipe existed are found through their command line instead.
$script:ShowEvent = $null
$script:PipeName = 'NRK-Browser-{0}-{1}' -f $env:USERNAME, [Diagnostics.Process]::GetCurrentProcess().SessionId

function Send-InstanceCommand([string] $Command, [int] $TimeoutMs = 2000) {
    # one request/response over the pipe; $null when no copy answers
    $c = $null
    try {
        $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $script:PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $c.Connect($TimeoutMs)
        $w = New-Object System.IO.StreamWriter($c); $w.AutoFlush = $true
        $r = New-Object System.IO.StreamReader($c)
        $w.WriteLine($Command)
        $task = $r.ReadLineAsync()
        if (-not $task.Wait($TimeoutMs)) { return $null }
        return $task.Result
    } catch { return $null } finally { if ($c) { $c.Dispose() } }
}

function Get-RunningInstance {
    # version / pid / path of the running copy: ask it, or (older copies) read its command line
    $answer = Send-InstanceCommand 'INFO'
    if ($answer -match '^OK (.*?)\|(\d+)\|(.*)$') { return [pscustomobject]@{ Version = $Matches[1]; Pid = [int]$Matches[2]; Path = $Matches[3]; Pipe = $true } }
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)) {
            if ($p.ProcessId -eq $PID -or $p.CommandLine -match '\s-Index\b' -or $p.CommandLine -notmatch '-File\s+"?([^"]*NRK-(?:TV-)?Browser\.ps1)"?') { continue }
            $path = $Matches[1]; $ver = ''
            try { if ([IO.File]::ReadAllText($path) -match "(?m)^\s*\`$script:AppVersion\s*=\s*'([0-9.]+)'") { $ver = $Matches[1] } } catch { }
            return [pscustomobject]@{ Version = $ver; Pid = [int]$p.ProcessId; Path = $path; Pipe = $false }
        }
    } catch { Write-Log WARN "Could not look for the running copy: $($_.Exception.Message)" }
    return $null
}

function Compare-AppVersion([string] $A, [string] $B) {
    # -1 / 0 / 1; an unknown version counts as older
    $f = { param($v) $p = @("$v".Split('.') | Where-Object { $_ -match '^\d+$' } | Select-Object -First 4); while ($p.Count -lt 4) { $p += '0' }; [version]($p -join '.') }
    if (-not $B) { return 1 }
    return (& $f $A).CompareTo((& $f $B))
}

try {
    $script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\NRK-Browser-Instance')
    $owned = $false
    try { $owned = $script:InstanceMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\NRK-Browser-Show')
    if (-not $owned) {
        $run = Get-RunningInstance
        Write-Log INFO ("Another copy is running: version {0}, pid {1}, {2} (pipe: {3})" -f $run.Version, $run.Pid, $run.Path, $run.Pipe)
        $takeOver = $false
        if (-not $Tray -and $run -and (Compare-AppVersion $script:AppVersion $run.Version) -gt 0) {
            Add-Type -AssemblyName System.Windows.Forms
            $q = [System.Windows.Forms.MessageBox]::Show(("NRK Browser {0} is already running:`n{1}`n`nThis file is version {2}. Close the running copy and continue with {2}?" -f $(if ($run.Version) { $run.Version } else { '(older)' }), $run.Path, $script:AppVersion),
                'NRK Browser', 'YesNo', 'Question')
            $takeOver = ($q -eq 'Yes')
        }
        if ($takeOver) {
            $reply = if ($run.Pipe) { Send-InstanceCommand 'EXIT' 4000 } else { $null }
            if ($reply -like 'BUSY*') {
                [void][System.Windows.Forms.MessageBox]::Show("The running copy is busy ($($reply.Substring(4).Trim())). Finish or cancel that first, then start this version again.", 'NRK Browser', 'OK', 'Information')
                [void]$script:ShowEvent.Set()
                return
            }
            if (-not $run.Pipe) {
                # an older copy without the pipe: close its window, end it if it does not close
                try { $p = Get-Process -Id $run.Pid -ErrorAction Stop; [void]$p.CloseMainWindow(); if (-not $p.WaitForExit(8000)) { $p.Kill() } } catch { }
            }
            $got = $false
            try { $got = $script:InstanceMutex.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
            if (-not $got) {
                [void][System.Windows.Forms.MessageBox]::Show('The running copy did not close. Close it from the tray menu (Exit) and start this version again.', 'NRK Browser', 'OK', 'Warning')
                return
            }
            Write-Log INFO "Took over from version $($run.Version); continuing with $($script:AppVersion)"
        } else {
            if ($Play) { [void](Send-InstanceCommand "PLAY $Play") }
            elseif (-not $Tray) { if ((Send-InstanceCommand 'SHOW') -ne 'OK') { [void]$script:ShowEvent.Set() } }
            Write-Log INFO 'NRK Browser is already running: asked it to come to the front; this copy exits'
            return
        }
    }
} catch { Write-Log WARN "Single-instance check failed: $($_.Exception.Message)" }

#region ---------- GUI: theme ------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-Log ERROR ("Unhandled UI exception: {0}: {1}`n{2}" -f $e.Exception.GetType().FullName, $e.Exception.Message, $e.Exception.StackTrace)
    # (2.9.2) which script line: PowerShell's own position and call stack
    try {
        $er = $e.Exception.ErrorRecord
        if ($er) {
            if ($er.InvocationInfo -and $er.InvocationInfo.PositionMessage) { Write-Log ERROR ("  at: {0}" -f ($er.InvocationInfo.PositionMessage -replace '\s+', ' ')) }
            if ($er.ScriptStackTrace) { Write-Log ERROR ("  script stack: {0}" -f ($er.ScriptStackTrace -replace "`r?`n", ' <- ')) }
        }
        $inner = $e.Exception.InnerException
        if ($inner) { Write-Log ERROR ("  inner: {0}: {1}" -f $inner.GetType().FullName, $inner.Message) }
    } catch { }
    try { $statusLabel.Text = "Error: $($e.Exception.Message) (see Logs)" } catch { }
})

# Two palettes modelled on the reference design. Every colour must be unique within its
# palette: switching theme maps each control's colour back to its palette key.
$script:Palettes = @{
    Dark = @{
        Bg          = [System.Drawing.Color]::FromArgb(16, 22, 26)
        Panel       = [System.Drawing.Color]::FromArgb(21, 28, 33)
        Surface     = [System.Drawing.Color]::FromArgb(28, 37, 43)
        Border      = [System.Drawing.Color]::FromArgb(38, 49, 56)
        Sel         = [System.Drawing.Color]::FromArgb(34, 48, 56)
        Hover       = [System.Drawing.Color]::FromArgb(40, 54, 62)
        Text        = [System.Drawing.Color]::FromArgb(226, 232, 236)
        Muted       = [System.Drawing.Color]::FromArgb(134, 147, 156)
        Accent      = [System.Drawing.Color]::FromArgb(72, 201, 210)
        AccentHover = [System.Drawing.Color]::FromArgb(104, 219, 226)
        OnAccent    = [System.Drawing.Color]::FromArgb(10, 30, 34)
        Ok          = [System.Drawing.Color]::FromArgb(86, 196, 128)
        Bad         = [System.Drawing.Color]::FromArgb(236, 106, 106)
        Program     = [System.Drawing.Color]::FromArgb(96, 150, 220)
        Live        = [System.Drawing.Color]::FromArgb(236, 84, 84)
        Star        = [System.Drawing.Color]::FromArgb(240, 190, 70)
    }
    Light = @{
        Bg          = [System.Drawing.Color]::FromArgb(246, 248, 250)
        Panel       = [System.Drawing.Color]::FromArgb(236, 240, 243)
        Surface     = [System.Drawing.Color]::FromArgb(253, 254, 255)
        Border      = [System.Drawing.Color]::FromArgb(212, 219, 224)
        Sel         = [System.Drawing.Color]::FromArgb(215, 236, 238)
        Hover       = [System.Drawing.Color]::FromArgb(226, 233, 237)
        Text        = [System.Drawing.Color]::FromArgb(22, 30, 36)
        Muted       = [System.Drawing.Color]::FromArgb(96, 110, 120)
        Accent      = [System.Drawing.Color]::FromArgb(0, 120, 132)
        AccentHover = [System.Drawing.Color]::FromArgb(0, 140, 152)
        OnAccent    = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Ok          = [System.Drawing.Color]::FromArgb(22, 138, 70)
        Bad         = [System.Drawing.Color]::FromArgb(196, 46, 46)
        Program     = [System.Drawing.Color]::FromArgb(40, 100, 190)
        Live        = [System.Drawing.Color]::FromArgb(212, 44, 44)
        Star        = [System.Drawing.Color]::FromArgb(190, 130, 0)
    }
}

function Get-SystemTheme {
    # Windows "Choose your app mode": AppsUseLightTheme = 0 means dark. Missing = light (Windows default).
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ($v -eq 0) { return 'Dark' } else { return 'Light' }
    } catch { return 'Light' }
}
function Resolve-Theme([string] $Mode) {
    switch ($Mode) { 'Light' { 'Light' } 'Dark' { 'Dark' } default { Get-SystemTheme } }
}
$T = @{}   # the active palette; code reads $T.<Key> at paint time, so it is updated in place
function Set-ThemePalette([string] $Name) {
    $pal = $script:Palettes[$Name]
    foreach ($k in @($pal.Keys)) { $T[$k] = $pal[$k] }
    $script:ThemeEffective = $Name
}
# Theme setting: System (default), Light or Dark - read straight from settings.json
$script:ThemeMode = 'System'
try {
    $sf = Join-Path $script:AppDataDir 'settings.json'
    if (Test-Path -LiteralPath $sf) {
        $th = (Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json).Theme
        if ($th -in 'System', 'Light', 'Dark') { $script:ThemeMode = $th }
    }
} catch { }
Set-ThemePalette (Resolve-Theme $script:ThemeMode)
Write-Log INFO ("Theme: {0} (setting: {1}, Windows app mode: {2})" -f $script:ThemeEffective, $script:ThemeMode, (Get-SystemTheme))
$script:FontUi     = New-Object System.Drawing.Font('Segoe UI', 10)
$script:FontSmall  = New-Object System.Drawing.Font('Segoe UI', 9)
$script:FontBold   = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$script:FontHeader = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$script:FontTitle  = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$script:FontIcon   = New-Object System.Drawing.Font('Segoe UI Symbol', 13)

# Native helpers: dark title bar, dark scrollbars, placeholder text in text boxes
if (-not ('NrkNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NrkNative {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, string lParam);
    public static void DarkTitleBar(IntPtr hwnd) { TitleBar(hwnd, true); }
    public static void TitleBar(IntPtr hwnd, bool dark) {
        int on = dark ? 1 : 0;
        if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) { DwmSetWindowAttribute(hwnd, 19, ref on, 4); }
    }
    public static void Placeholder(IntPtr hwnd, string text) { SendMessage(hwnd, 0x1501, (IntPtr)1, text); }
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
}
'@
}

# Own taskbar identity, so the window gets its own taskbar button and icon instead of
# being grouped with PowerShell.
try {
    if (-not ('NrkShell' -as [type])) {
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class NrkShell { [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id); }'
    }
    [void][NrkShell]::SetCurrentProcessExplicitAppUserModelID('NRK.Browser')
} catch { }

# Hide the PowerShell console behind the app; it comes back when the app closes.
$script:ConsoleHwnd = [IntPtr]::Zero
function Hide-AppConsole {
    if ($ShowConsole) { return }
    try {
        $h = [NrkNative]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) {
            [void][NrkNative]::ShowWindow($h, 0)   # SW_HIDE
            $script:ConsoleHwnd = $h
            Write-Log INFO 'Console window hidden (use -ShowConsole to keep it)'
        }
    } catch { Write-Log DEBUG "Could not hide console: $($_.Exception.Message)" }
}
function Show-AppConsole {
    if ($script:ConsoleHwnd -ne [IntPtr]::Zero) { try { [void][NrkNative]::ShowWindow($script:ConsoleHwnd, 5) } catch { } }   # SW_SHOW
}
Hide-AppConsole

function Update-MaxBounds {
    # Tells Windows exactly where a maximized window may go: the work area of the monitor
    # the window is on (so the taskbar stays visible), or the whole monitor in full screen.
    # MaximizedBounds is relative to that monitor, hence the subtraction of its origin.
    param($Window, [bool] $FullScreen = $false)
    if (-not $Window -or $Window.IsDisposed) { return }
    try {
        $scr = [System.Windows.Forms.Screen]::FromHandle($Window.Handle)
        $b = $scr.Bounds
        if ($FullScreen -or $Window.FormBorderStyle -eq 'None') {
            $r = New-Object System.Drawing.Rectangle(0, 0, $b.Width, $b.Height)
        } else {
            $wa = $scr.WorkingArea
            # A normal maximized window overhangs the work area by its invisible resize border.
            $fx = [NrkNative]::GetSystemMetrics(32) + [NrkNative]::GetSystemMetrics(92)   # SM_CXSIZEFRAME + SM_CXPADDEDBORDER
            $fy = [NrkNative]::GetSystemMetrics(33) + [NrkNative]::GetSystemMetrics(92)   # SM_CYSIZEFRAME + SM_CXPADDEDBORDER
            $r = New-Object System.Drawing.Rectangle(($wa.X - $b.X - $fx), ($wa.Y - $b.Y - $fy), ($wa.Width + 2 * $fx), ($wa.Height + 2 * $fy))
        }
        # (MaximizedBounds is "protected" in Windows Forms: PowerShell can't see it, so through reflection.
        #  Before 2.9.2 this failed silently, which is why maximized windows covered the taskbar.)
        if (-not $script:MaxBoundsProp) { $script:MaxBoundsProp = [System.Windows.Forms.Form].GetProperty('MaximizedBounds', [System.Reflection.BindingFlags]'Instance, NonPublic, Public') }
        if ($script:MaxBoundsProp -and $script:MaxBoundsProp.GetValue($Window, $null) -ne $r) { $script:MaxBoundsProp.SetValue($Window, $r, $null) }
    } catch { Write-Log DEBUG "Update-MaxBounds: $($_.Exception.Message)" }
}

function Enable-DarkTitleBar($Window) {
    # (name kept from the dark-only version) title bar follows the active theme
    try { [NrkNative]::TitleBar($Window.Handle, ($script:ThemeEffective -eq 'Dark')) } catch { Write-Log DEBUG "Title bar theme not available: $($_.Exception.Message)" }
    if ($script:AppIcon) { try { if ($Window.Icon -ne $script:AppIcon) { $Window.Icon = $script:AppIcon } } catch { } }
}
function Enable-DarkScrollbars($Control) {
    # scrollbars follow the active theme
    $theme = if ($script:ThemeEffective -eq 'Dark') { 'DarkMode_Explorer' } else { 'Explorer' }
    try { [void][NrkNative]::SetWindowTheme($Control.Handle, $theme, $null) } catch { }
}

# Dark menu renderer (C#; needs WinForms references). Falls back to plain colours if compiling fails.
$script:DarkRenderer = $null
try {
    if (-not ('NrkDarkColors' -as [type])) {
        $refs = if ($PSVersionTable.PSEdition -eq 'Desktop') { @('System.Windows.Forms', 'System.Drawing') }
                else { [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { -not $_.IsDynamic -and $_.Location -and $_.GetName().Name -match '^System\.(Windows\.Forms(\.Primitives)?|Drawing(\.Common|\.Primitives)?|ComponentModel\.Primitives|Runtime|Collections\.Specialized)$' } | ForEach-Object Location }
        Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
public class NrkDarkColors : ProfessionalColorTable {
    private Color bg, sel, border;
    public NrkDarkColors(Color bg, Color sel, Color border) { this.bg = bg; this.sel = sel; this.border = border; UseSystemColors = false; }
    public override Color ToolStripDropDownBackground { get { return bg; } }
    public override Color ImageMarginGradientBegin { get { return bg; } }
    public override Color ImageMarginGradientMiddle { get { return bg; } }
    public override Color ImageMarginGradientEnd { get { return bg; } }
    public override Color MenuItemSelected { get { return sel; } }
    public override Color MenuItemSelectedGradientBegin { get { return sel; } }
    public override Color MenuItemSelectedGradientEnd { get { return sel; } }
    public override Color MenuItemPressedGradientBegin { get { return sel; } }
    public override Color MenuItemPressedGradientEnd { get { return sel; } }
    public override Color MenuItemBorder { get { return sel; } }
    public override Color MenuBorder { get { return border; } }
    public override Color SeparatorDark { get { return border; } }
    public override Color SeparatorLight { get { return bg; } }
}
'@
    }
} catch {
    Write-Log WARN "Themed menu renderer unavailable, using default menu colours: $($_.Exception.Message)"
}
function New-ThemeRenderer {
    if (-not ('NrkDarkColors' -as [type])) { return $null }
    return (New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object NrkDarkColors($T.Surface, $T.Hover, $T.Border))))
}
try { $script:DarkRenderer = New-ThemeRenderer } catch {
    Write-Log WARN "Dark menu renderer unavailable, using default menu colours: $($_.Exception.Message)"
}

function New-FlatButton {
    param([string] $Text, [int] $Width = 0, [switch] $Primary, [switch] $Icon)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.UseVisualStyleBackColor = $false
    $b.Height = 34
    if ($Width -gt 0) { $b.Width = $Width } else { $b.AutoSize = $true; $b.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 0) }
    if ($Primary) {
        $b.BackColor = $T.Accent; $b.ForeColor = $T.OnAccent; $b.Font = $script:FontBold
        $b.FlatAppearance.MouseOverBackColor = $T.AccentHover
    } else {
        $b.BackColor = $T.Surface; $b.ForeColor = $T.Text; $b.Font = $(if ($Icon) { $script:FontIcon } else { $script:FontUi })
        $b.FlatAppearance.MouseOverBackColor = $T.Hover
    }
    $b.FlatAppearance.MouseDownBackColor = $T.Sel
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    return $b
}

function Set-DarkTheme {
    # Recursively applies the dark palette to a dialog built from standard controls.
    param($Control)
    switch -Regex ($Control.GetType().Name) {
        '^(Form)$'                        { $Control.BackColor = $T.Bg; $Control.ForeColor = $T.Text }
        '^(Panel|FlowLayoutPanel|TableLayoutPanel|GroupBox)$' { $Control.BackColor = $T.Bg; $Control.ForeColor = $T.Text }
        '^Label$'                         { if ($Control.ForeColor -eq [System.Drawing.SystemColors]::ControlText) { $Control.ForeColor = $T.Text } }
        '^TextBox$'                       { $Control.BackColor = $T.Surface; $Control.ForeColor = $T.Text; $Control.BorderStyle = 'FixedSingle'; Enable-DarkScrollbars $Control }
        '^ComboBox$'                      { $Control.FlatStyle = 'Flat'; $Control.BackColor = $T.Surface; $Control.ForeColor = $T.Text }
        '^CheckBox$'                      { $Control.ForeColor = $T.Text }
        '^ListView$'                      { Enable-DarkScrollbars $Control }
        '^Button$' {
            if ($Control.BackColor -ne $T.Accent) {
                $Control.FlatStyle = 'Flat'; $Control.FlatAppearance.BorderSize = 0; $Control.UseVisualStyleBackColor = $false
                $Control.BackColor = $T.Surface; $Control.ForeColor = $T.Text
                $Control.FlatAppearance.MouseOverBackColor = $T.Hover
            }
        }
    }
    foreach ($c in $Control.Controls) { Set-DarkTheme $c }
}

# ---- icons and pictures from the GitHub repository -----------------------------------------
# icons\<dark|light>\<style>\<name>.png (top bar, 48 px), icons\<theme>\list\<kind>.png (44x68)
# and pictures\<name>.png (960x540) are fetched into <app data>\assets at startup, only what is
# missing. Until a file is there the app draws its own version.
$script:AssetBase = 'https://raw.githubusercontent.com/{0}/refs/heads/main' -f $script:UpdateRepo
$script:AssetsDir = Join-Path $script:AppDataDir 'assets'
$script:AssetImgs = @{}
$script:AssetTopStyles = @('thin', 'bold', 'solid', 'accent', 'duotone', 'ring', 'tiles', 'soft', 'muted', 'muted-hover')
$script:AssetTopNames = @('back', 'index', 'down', 'logs', 'reload', 'options',
    # 2.9.2: the buttons of the Downloads and Logs windows, the main window and the cast bar
    'play', 'pause', 'stop', 'cancel', 'check', 'selectall', 'minus', 'folder', 'copy', 'edit', 'trash', 'web', 'link', 'cast', 'rewind', 'forward', 'volume',
    'previous', 'next', 'window', 'record',
    # 2.9.3: the video player's bar
    'startover', 'speed', 'subtitles', 'quality', 'sleep', 'pin', 'fullscreen', 'mini', 'camera')
$script:AssetListKinds = @('folder', 'program', 'episode', 'live', 'other', 'star', 'new', 'clock')
$script:AssetPictures = @{ continue = 'continue-watching'; watchlater = 'watch-later'; tv = 'tv'; radio = 'radio'; recent = 'recently-played'; fav = 'favourites'; new = 'new-this-week'; last = 'last-chance' }

function Get-AssetList {
    $l = New-Object System.Collections.Generic.List[string]
    foreach ($th in 'dark', 'light') {
        foreach ($st in $script:AssetTopStyles) { foreach ($n in $script:AssetTopNames) { $l.Add("icons/$th/$st/$n.png") } }
        foreach ($k in $script:AssetListKinds) { $l.Add("icons/$th/list/$k.png") }
    }
    foreach ($n in $script:AssetPictures.Values) { $l.Add("pictures/$n.png") }
    return $l
}

function Get-AssetFile([string] $Rel) { return (Join-Path $script:AssetsDir ($Rel -replace '/', '\')) }

function Get-AssetImage([string] $Rel) {
    # the picture from <app data>\assets (read once; the file is not kept open), or $null
    if ($script:AssetImgs.ContainsKey($Rel)) { return $script:AssetImgs[$Rel] }
    $img = $null
    $f = Get-AssetFile $Rel
    if (Test-Path -LiteralPath $f) {
        try { $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($f)); $img = New-Object System.Drawing.Bitmap($ms) }
        catch { Write-Log DEBUG "Asset ${Rel}: $($_.Exception.Message)"; $img = $null }
    }
    $script:AssetImgs[$Rel] = $img
    return $img
}

function Get-AssetTheme { if ($script:ThemeEffective -eq 'Light') { 'light' } else { 'dark' } }

function New-ScaledImage($Src, [int] $W, [int] $H, [int] $BoxH = 0) {
    # a new bitmap (the caller may dispose it) with $Src scaled to W x H, centred in a W x BoxH box
    if ($BoxH -lt $H) { $BoxH = $H }
    $bmp = New-Object System.Drawing.Bitmap($W, $BoxH)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.SmoothingMode = 'AntiAlias'
    $g.DrawImage($Src, (New-Object System.Drawing.Rectangle(0, [int](($BoxH - $H) / 2), $W, $H)))
    $g.Dispose()
    return $bmp
}

function Get-AssetHash([string] $Path) {
    # the first 16 hex digits of the file's SHA-256 (what assets.json in the repository lists)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))) -replace '-', '').Substring(0, 16).ToLower() } finally { $sha.Dispose() }
}

function Start-AssetDownload {
    # GUI only, in the background: assets.json in the repository lists every icon and picture with
    # a hash; what is missing here or has changed there is fetched (4 at a time), then the app
    # switches to it. Without assets.json: only what is missing. A failed file is tried next start.
    if ($script:AssetRun -or -not ('System.Windows.Forms.Timer' -as [type])) { return }
    $old = Join-Path $script:AppDataDir 'images'   # (older versions kept NRK's TV logo there)
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
    $wc = New-Object System.Net.WebClient; $wc.Headers['User-Agent'] = $script:UserAgent
    $script:AssetRun = @{ Phase = 'manifest'; ManifestClient = $wc; ManifestTask = $wc.DownloadDataTaskAsync("$($script:AssetBase)/assets.json")
                          Queue = (New-Object System.Collections.Generic.Queue[string]); Want = @{}; Busy = @{}; Got = 0; Failed = 0; FirstError = $null
                          Timer = (New-Object System.Windows.Forms.Timer) }
    $script:AssetRun.Timer.Interval = 200
    $script:AssetRun.Timer.Add_Tick({ try { Update-AssetDownload } catch { Write-LogException $_ 'Assets'; $script:AssetRun.Timer.Stop() } })
    $script:AssetRun.Timer.Start()
}

function Update-AssetDownload {
    $run = $script:AssetRun
    $localFile = Join-Path $script:AssetsDir 'assets.local.json'   # what we have: name -> hash
    if ($run.Phase -eq 'zip') { if ($run.Zip.Task.IsCompleted) { Complete-AssetZip }; return }
    if ($run.Phase -eq 'manifest') {
        if (-not $run.ManifestTask.IsCompleted) { return }
        $list = @{}
        try {
            if ($run.ManifestTask.IsFaulted) { throw $run.ManifestTask.Exception.GetBaseException() }
            $j = [Text.Encoding]::UTF8.GetString($run.ManifestTask.Result) | ConvertFrom-Json
            if ($j.zip -and $j.sha256) {
                # 2.9.4: everything in one zip (assets.zip); fetched only when its hash changed
                try { $run.ManifestClient.Dispose() } catch { }
                Start-AssetZip $j
                return
            }
            foreach ($p in $j.files.PSObject.Properties) { if ($p.Name -match '^(icons|pictures)/[\w\-/]+\.png$') { $list[$p.Name] = [string]$p.Value } }
            Write-Log DEBUG "Assets: assets.json lists $($list.Count) file(s)"
        } catch {
            Write-Log DEBUG "Assets: no assets.json ($($_.Exception.Message)); fetching only what is missing"
            foreach ($r in (Get-AssetList)) { $list[$r] = '' }
        }
        try { $run.ManifestClient.Dispose() } catch { }
        $have = @{}
        $lj = Read-JsonFile $localFile
        if ($lj) { foreach ($p in $lj.PSObject.Properties) { $have[$p.Name] = [string]$p.Value } }
        $run.Have = $have; $run.LocalFile = $localFile
        foreach ($r in $list.Keys) {
            $f = Get-AssetFile $r
            $exists = Test-Path -LiteralPath $f
            if ($exists -and $list[$r] -and -not $have[$r]) { try { $have[$r] = Get-AssetHash $f } catch { } }   # (fetched before there was a list)
            if (-not $exists -or ($list[$r] -and $have[$r] -ne $list[$r])) { $run.Queue.Enqueue($r); $run.Want[$r] = $list[$r] }
        }
        if (-not $run.Queue.Count) { $run.Timer.Stop(); $run.Timer.Dispose(); Save-AssetLocal; return }
        Write-Log INFO "Assets: fetching $($run.Queue.Count) new or changed icon(s)/picture(s) from $($script:AssetBase)"
        $run.Phase = 'files'
    }
    foreach ($rel in @($run.Busy.Keys)) {
        $j = $run.Busy[$rel]
        if (-not $j.Task.IsCompleted) { continue }
        $run.Busy.Remove($rel)
        try {
            if ($j.Task.IsFaulted -or $j.Task.IsCanceled) { throw $(if ($j.Task.Exception) { $j.Task.Exception.GetBaseException() } else { 'cancelled' }) }
            $b = $j.Task.Result
            if (-not $b -or $b.Length -lt 8 -or $b[0] -ne 0x89 -or $b[1] -ne 0x50) { throw 'not a PNG' }
            $f = Get-AssetFile $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $f) -Force | Out-Null
            [IO.File]::WriteAllBytes("$f.part", $b); Move-Item -LiteralPath "$f.part" -Destination $f -Force
            $run.Have[$rel] = if ($run.Want[$rel]) { $run.Want[$rel] } else { Get-AssetHash $f }
            $run.Got++
        } catch { $run.Failed++; if (-not $run.FirstError) { $run.FirstError = "${rel}: $(if ($_.Exception.Message) { $_.Exception.Message } else { $_ })" } }
        finally { try { $j.Client.Dispose() } catch { } }
    }
    while ($run.Busy.Count -lt 4 -and $run.Queue.Count) {
        $rel = $run.Queue.Dequeue()
        try {
            $c = New-Object System.Net.WebClient
            $c.Headers['User-Agent'] = $script:UserAgent
            $run.Busy[$rel] = @{ Client = $c; Task = $c.DownloadDataTaskAsync("$($script:AssetBase)/$rel") }
        } catch { $run.Failed++ }
    }
    if (-not $run.Busy.Count -and -not $run.Queue.Count) {
        $run.Timer.Stop(); $run.Timer.Dispose()
        Save-AssetLocal
        Write-Log $(if ($run.Failed) { 'WARN' } else { 'INFO' }) ("Assets: {0} saved in {1}{2}" -f $run.Got, $script:AssetsDir, $(if ($run.Failed) { ", $($run.Failed) failed (first: $($run.FirstError)); tried again next start" } else { '' }))
        if ($run.Got) { try { Update-AssetPictures } catch { Write-LogException $_ 'Assets' } }
    }
}

function Start-AssetZip($Manifest) {
    # assets.json { format: 'zip', zip: 'assets.zip', sha256, size, files }: the zip is fetched when its
    # hash differs from the one saved last time (assets\assets.zip.json), checked, unpacked into a new
    # folder and only then put in place of the old one - a failed download keeps what is there
    $run = $script:AssetRun
    $sha = ([string]$Manifest.sha256).ToLower()
    $mine = Read-JsonFile (Join-Path $script:AssetsDir 'assets.zip.json')
    if ($mine -and [string]$mine.sha256 -eq $sha -and (Test-Path -LiteralPath (Join-Path $script:AssetsDir 'icons'))) {
        Write-Log DEBUG "Assets: assets.zip unchanged ($($Manifest.files) files)"
        $run.Timer.Stop(); $run.Timer.Dispose(); return
    }
    $name = [string]$Manifest.zip
    if ($name -notmatch '^[\w\-.]+\.zip$') { Write-Log WARN "Assets: odd zip name in assets.json: $name"; $run.Timer.Stop(); $run.Timer.Dispose(); return }
    Write-Log INFO ("Assets: fetching {0} ({1:N0} KB, {2} files) from {3}" -f $name, ([double]$Manifest.size / 1KB), $Manifest.files, $script:AssetBase)
    $wc = New-Object System.Net.WebClient; $wc.Headers['User-Agent'] = $script:UserAgent
    $run.Zip = @{ Client = $wc; Task = $wc.DownloadDataTaskAsync("$($script:AssetBase)/$name"); Sha = $sha; Manifest = $Manifest; Watch = [Diagnostics.Stopwatch]::StartNew() }
    $run.Phase = 'zip'
}

function Complete-AssetZip {
    $run = $script:AssetRun; $z = $run.Zip
    $run.Timer.Stop(); $run.Timer.Dispose()
    $new = Join-Path $script:AppDataDir 'assets.new'; $old = Join-Path $script:AppDataDir 'assets.old'
    try {
        if ($z.Task.IsFaulted -or $z.Task.IsCanceled) { throw $(if ($z.Task.Exception) { $z.Task.Exception.GetBaseException() } else { 'cancelled' }) }
        $bytes = $z.Task.Result
        $shaObj = [Security.Cryptography.SHA256]::Create()
        $got = (([BitConverter]::ToString($shaObj.ComputeHash($bytes))) -replace '-', '').ToLower(); $shaObj.Dispose()
        if ($got -ne $z.Sha) { throw "the zip's SHA-256 is $got, assets.json says $($z.Sha)" }
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force }
        New-Item -ItemType Directory -Path $new -Force | Out-Null
        $ms = New-Object IO.MemoryStream(, $bytes)
        $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Read)
        $n = 0
        try {
            foreach ($e in $zip.Entries) {
                $rel = $e.FullName -replace '\\', '/'
                if ($rel.EndsWith('/')) { continue }
                # only pictures, only inside the folder (no "..\")
                if ($rel -notmatch '^(icons|pictures)/[\w\-/]+\.png$' -or $rel -match '\.\.') { continue }
                $dest = Join-Path $new ($rel -replace '/', '\')
                New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
                $in = $e.Open(); $out = [IO.File]::Create($dest)
                try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
                $n++
            }
        } finally { $zip.Dispose(); $ms.Dispose() }
        if ($n -lt 10) { throw "only $n picture(s) in the zip" }
        Write-JsonFile (Join-Path $new 'assets.zip.json') ([ordered]@{ sha256 = $z.Sha; files = $n; at = (Get-Date).ToString('o') })
        # swap: the pictures in use are in memory (read once), so the folders can be renamed
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $script:AssetsDir) { Rename-Item -LiteralPath $script:AssetsDir -NewName 'assets.old' }
        Rename-Item -LiteralPath $new -NewName 'assets'
        Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log INFO ("Assets: {0} pictures from {1} in {2:N1} s" -f $n, $z.Manifest.zip, $z.Watch.Elapsed.TotalSeconds)
        Update-AssetPictures
    } catch {
        Write-Log WARN "Assets: $($z.Manifest.zip) not used ($($_.Exception.Message)); keeping the pictures there are; tried again next start"
        Remove-Item -LiteralPath $new -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $script:AssetsDir) -and (Test-Path -LiteralPath $old)) { Rename-Item -LiteralPath $old -NewName 'assets' -ErrorAction SilentlyContinue }
    } finally { try { $z.Client.Dispose() } catch { } }
}

function Save-AssetLocal {
    $run = $script:AssetRun
    if (-not $run.Have) { return }
    $o = [ordered]@{}; foreach ($k in ($run.Have.Keys | Sort-Object)) { if ($run.Have[$k]) { $o[$k] = $run.Have[$k] } }
    Write-JsonFile $run.LocalFile $o
}

function Update-AssetPictures {
    # new files arrived: use them everywhere now, and free the pictures they replace
    $old = New-Object System.Collections.Generic.List[object]
    foreach ($v in @($script:AssetImgs.Values) + @($script:Placeholders.Values) + @($script:SmallPlaceholders.Values)) { if ($v -and -not $old.Contains($v)) { $old.Add($v) } }
    $script:AssetImgs = @{}
    foreach ($k in @($script:Placeholders.Keys)) { $script:Placeholders.Remove($k) }
    $script:SmallPlaceholders = @{}
    Reset-ListIcons
    Set-TopBarIcons   # (also the other buttons: Update-IconButtons)
    try { if (-not $script:SelectedFile) { $pic.Image = $null; Show-FolderPreview } } catch { }
    try { $itemsList.Refresh(); $folderTree.Refresh() } catch { }
    $shown = try { $pic.Image } catch { $null }
    foreach ($v in $old) { if (-not [object]::ReferenceEquals($v, $shown)) { try { $v.Dispose() } catch { } } }
}

# ---- small drawn icons for the lists
function New-ListIcon {
    param([string] $Kind, [int] $W = 22, [int] $H = 34)
    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $cy = [int]($H / 2)
    switch ($Kind) {
        'folder' {
            $b = New-Object System.Drawing.SolidBrush($T.Accent)
            $g.FillRectangle($b, 2, $cy - 7, 8, 3)
            $g.FillRectangle($b, 2, $cy - 5, 17, 12)
            $b.Dispose()
        }
        'program' {
            $b = New-Object System.Drawing.SolidBrush($T.Program)
            $g.FillRectangle($b, 2, $cy - 6, 17, 12)
            # (not $w: PowerShell names are case-insensitive, $w would be the [int] $W parameter)
            $playBrush = New-Object System.Drawing.SolidBrush($T.Bg)
            $pts = [System.Drawing.Point[]]@((New-Object System.Drawing.Point(8, ($cy - 3))), (New-Object System.Drawing.Point(8, ($cy + 3))), (New-Object System.Drawing.Point(14, $cy)))
            $g.FillPolygon($playBrush, $pts)
            $b.Dispose(); $playBrush.Dispose()
        }
        'live' {
            $b = New-Object System.Drawing.SolidBrush($T.Live)
            $g.FillEllipse($b, 5, $cy - 6, 12, 12)
            $ring = New-Object System.Drawing.Pen($T.Live, 1.5)
            $g.DrawEllipse($ring, 2, $cy - 9, 18, 18)
            $b.Dispose(); $ring.Dispose()
        }
        'episode' {
            $b = New-Object System.Drawing.SolidBrush($T.Muted)
            $pts = [System.Drawing.Point[]]@((New-Object System.Drawing.Point(6, ($cy - 5))), (New-Object System.Drawing.Point(6, ($cy + 5))), (New-Object System.Drawing.Point(15, $cy)))
            $g.FillPolygon($b, $pts)
            $b.Dispose()
        }
        'star' {
            # favourites: a five-pointed star
            $b = New-Object System.Drawing.SolidBrush($T.Star)
            $pts = New-Object 'System.Drawing.PointF[]' 10
            for ($i = 0; $i -lt 10; $i++) {
                $rad = if ($i % 2) { 3.4 } else { 8.5 }
                $a = -[Math]::PI / 2 + $i * [Math]::PI / 5
                $pts[$i] = New-Object System.Drawing.PointF((10.5 + $rad * [Math]::Cos($a)), ($cy + 0.5 + $rad * [Math]::Sin($a)))
            }
            $g.FillPolygon($b, $pts)
            $b.Dispose()
        }
        'new' {
            # new this week: a small sparkle
            $p = New-Object System.Drawing.Pen($T.Accent, 2)
            $g.DrawLine($p, 10, $cy - 8, 10, $cy + 8); $g.DrawLine($p, 2, $cy, 18, $cy)
            $p.Width = 1.5
            $g.DrawLine($p, 5, $cy - 5, 15, $cy + 5); $g.DrawLine($p, 5, $cy + 5, 15, $cy - 5)
            $p.Dispose()
        }
        'clock' {
            # last chance: a clock
            $p = New-Object System.Drawing.Pen($T.Live, 1.6)
            $g.DrawEllipse($p, 2, $cy - 8, 16, 16)
            $g.DrawLine($p, 10, $cy, 10, $cy - 5); $g.DrawLine($p, 10, $cy, 14, $cy + 2)
            $p.Dispose()
        }
        default {
            $b = New-Object System.Drawing.SolidBrush($T.Muted)
            $g.FillEllipse($b, 6, $cy - 4, 8, 8)
            $b.Dispose()
        }
    }
    $g.Dispose()
    return $bmp
}

$script:Icons = New-Object System.Windows.Forms.ImageList
$script:Icons.ColorDepth = 'Depth32Bit'
$script:Icons.ImageSize = New-Object System.Drawing.Size(22, 34)
# the same icons for taller rows (files list with a second line: the description)
$script:IconsTall = New-Object System.Windows.Forms.ImageList
$script:IconsTall.ColorDepth = 'Depth32Bit'
$script:IconsTall.ImageSize = New-Object System.Drawing.Size(22, 52)
$script:IconKinds = @('folder', 'program', 'episode', 'live', 'other', 'star', 'new', 'clock')
function Reset-ListIcons {
    $script:Icons.Images.Clear(); $script:IconsTall.Images.Clear()
    $th = Get-AssetTheme
    foreach ($k in $script:IconKinds) {
        $png = Get-AssetImage "icons/$th/list/$k.png"
        if ($png) { $script:Icons.Images.Add($k, (New-ScaledImage $png 22 34)); $script:IconsTall.Images.Add($k, (New-ScaledImage $png 22 34 52)) }
        else { $script:Icons.Images.Add($k, (New-ListIcon $k)); $script:IconsTall.Images.Add($k, (New-ListIcon $k 22 52)) }
    }
}
Reset-ListIcons

# ---- top bar icons (Options > General > Top bar icons) -------------------------------------
# 'text' is the font symbols the app always had; the rest are drawn here, in 11 looks.
$script:TopIconStyles = [ordered]@{
    text = 'Text symbols (as before)'; thin = 'Thin outline'; bold = 'Bold outline'; solid = 'Solid'; accent = 'Accent outline'
    duotone = 'Duotone (white, teal detail)'; ring = 'Ring'; tiles = 'Teal tiles'; soft = 'Soft tiles'; muted = 'Muted, lights on hover'; label = 'Icon + label'
}

function Get-TopIconPicture([string] $Kind, [string] $Style, [System.Drawing.Color] $Color, [int] $Size = 22, [string] $AssetStyle) {
    # the downloaded icon (icons\<theme>\<style>\<name>.png) when it is there, otherwise drawn
    if (-not $AssetStyle) { $AssetStyle = $Style }
    $name = if ($Kind -eq 'opts') { 'options' } else { $Kind }
    $png = Get-AssetImage ("icons/{0}/{1}/{2}.png" -f (Get-AssetTheme), $AssetStyle, $name)
    if ($png) { return (New-ScaledImage $png $Size $Size) }
    return (New-TopIcon $Kind $Style $Color $Size)
}

function New-TopIcon([string] $Kind, [string] $Style, [System.Drawing.Color] $Color, [int] $Size = 22) {
    # one icon on a 24-unit grid (like the preview), scaled to $Size pixels
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $k = $Size / 24.0; $g.ScaleTransform($k, $k)
    $fill = $Style -in 'solid', 'tiles', 'soft'
    $sw = switch ($Style) { 'thin' { 1.5 } 'bold' { 2.4 } 'ring' { 1.8 } default { 2.0 } }
    $detail = if ($Style -eq 'duotone') { $T.Accent } else { $Color }
    $hole = switch ($Style) { 'tiles' { $T.Accent } 'soft' { $script:SoftTile } default { $T.Bg } }   # (cut-outs in filled icons)
    if ($Style -eq 'ring') {
        # the ring is part of the picture; the icon inside it is smaller
        $rp = New-Object System.Drawing.Pen($T.Border, 1.4); $g.DrawEllipse($rp, 0.8, 0.8, 22.4, 22.4); $rp.Dispose()
        $g.TranslateTransform(4.2, 4.2); $g.ScaleTransform(0.65, 0.65)
    }
    $pen = New-Object System.Drawing.Pen($Color, $sw); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $dpen = New-Object System.Drawing.Pen($detail, $sw); $dpen.StartCap = 'Round'; $dpen.EndCap = 'Round'; $dpen.LineJoin = 'Round'
    $br = New-Object System.Drawing.SolidBrush($Color); $dbr = New-Object System.Drawing.SolidBrush($detail)
    $hp = New-Object System.Drawing.Pen($hole, 1.6); $hp.StartCap = 'Round'; $hp.EndCap = 'Round'
    $pt = { param($x, $y) New-Object System.Drawing.PointF([float]$x, [float]$y) }
    switch ($Kind) {
        'back' {
            if ($fill) { $g.FillPolygon($br, [System.Drawing.PointF[]]@((& $pt 15.5 4.5), (& $pt 7 12), (& $pt 15.5 19.5))) }
            else { $g.DrawLines($dpen, [System.Drawing.PointF[]]@((& $pt 15 5), (& $pt 8 12), (& $pt 15 19))) }
        }
        'index' {
            if ($fill) {
                $g.FillRectangle($br, 4.5, 5.5, 15, 12.5); $g.FillEllipse($br, 4.5, 2.7, 15, 5.6); $g.FillEllipse($br, 4.5, 15.2, 15, 5.6)
                $g.DrawArc($hp, 4.5, 2.7, 15, 5.6, 10, 160); $g.DrawArc($hp, 4.5, 8.7, 15, 5.6, 10, 160)
            } else {
                $g.DrawEllipse($dpen, 4.5, 2.7, 15, 5.6)
                $g.DrawArc($pen, 4.5, 8.7, 15, 5.6, 0, 180); $g.DrawArc($pen, 4.5, 15.2, 15, 5.6, 0, 180)
                $g.DrawLine($pen, 4.5, 5.5, 4.5, 18); $g.DrawLine($pen, 19.5, 5.5, 19.5, 18)
            }
        }
        'down' {
            if ($fill) {
                $g.FillPolygon($br, [System.Drawing.PointF[]]@((& $pt 10 3), (& $pt 14 3), (& $pt 14 11), (& $pt 18 11), (& $pt 12 18), (& $pt 6 11), (& $pt 10 11)))
                $g.FillRectangle($br, 4, 19, 16, 2.4)
            } else {
                $g.DrawLine($pen, 12, 4, 12, 15); $g.DrawLines($pen, [System.Drawing.PointF[]]@((& $pt 7 10), (& $pt 12 15), (& $pt 17 10)))
                $g.DrawLine($dpen, 5, 20, 19, 20)
            }
        }
        'logs' {
            if ($fill) {
                $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
                $gp.AddArc(4, 3, 5, 5, 180, 90); $gp.AddArc(15, 3, 5, 5, 270, 90); $gp.AddArc(15, 16, 5, 5, 0, 90); $gp.AddArc(4, 16, 5, 5, 90, 90); $gp.CloseFigure()
                $g.FillPath($br, $gp); $gp.Dispose()
                $g.DrawLine($hp, 8, 8, 16, 8); $g.DrawLine($hp, 8, 12, 16, 12); $g.DrawLine($hp, 8, 16, 13, 16)
            } else {
                foreach ($y in 6, 12, 18) { $g.DrawLine($pen, 9, $y, 20, $y); $g.FillEllipse($dbr, 3.1, $y - 1.4, 2.8, 2.8) }
            }
        }
        'reload' {
            $p2 = if ($fill) { New-Object System.Drawing.Pen($Color, ($sw + 0.8)) } else { $pen }
            $p2.StartCap = 'Round'; $p2.EndCap = 'Round'; $p2.LineJoin = 'Round'
            $g.DrawArc($p2, 4.5, 4.5, 15, 15, 0, 315)
            $ap = if ($fill) { $p2 } else { $dpen }
            $g.DrawLines($ap, [System.Drawing.PointF[]]@((& $pt 19.5 4), (& $pt 19.5 8.6), (& $pt 14.9 8.6)))
            if ($fill) { $p2.Dispose() }
        }
        'opts' {
            $state = $g.Save()
            for ($i = 0; $i -lt 8; $i++) {
                $g.TranslateTransform(12, 12); $g.RotateTransform(45); $g.TranslateTransform(-12, -12)
                $g.FillRectangle($br, 10.6, 1.6, 2.8, 4.2)
            }
            $g.Restore($state)
            if ($fill) { $g.FillEllipse($br, 5, 5, 14, 14); $hb = New-Object System.Drawing.SolidBrush($hole); $g.FillEllipse($hb, 9.4, 9.4, 5.2, 5.2); $hb.Dispose() }
            else { $g.DrawEllipse($pen, 5, 5, 14, 14); $g.DrawEllipse($dpen, 9.4, 9.4, 5.2, 5.2) }
        }
    }
    $pen.Dispose(); $dpen.Dispose(); $br.Dispose(); $dbr.Dispose(); $hp.Dispose(); $g.Dispose()
    return $bmp
}

function Set-TopBarIcons {
    # applies the chosen look to the six top-bar buttons (again after a theme change)
    $style = [string](Get-AppSettings).TopIcons
    if (-not $script:TopIconStyles.Contains($style)) { $style = 'text' }
    $script:SoftTile = if ($script:ThemeEffective -eq 'Light') { [System.Drawing.Color]::FromArgb(205, 232, 235) } else { [System.Drawing.Color]::FromArgb(24, 51, 56) }
    $defs = @(
        @($btnBack, 'back', [string][char]0x2039, 'Back'), @($btnIndexer, 'index', [string][char]0x25A6, 'Indexer'), @($btnDownloads, 'down', [string][char]0x2193, 'Downloads'),
        @($btnLogs, 'logs', [string][char]0x2630, 'Logs'), @($btnReload, 'reload', [string][char]0x27F3, 'Reload'), @($btnSettings, 'opts', [string][char]0x2699, 'Options'))
    foreach ($d in $defs) {
        $b = $d[0]
        if ($b.Tag -is [hashtable] -and $b.Tag.On) { try { $b.Tag.On.Dispose() } catch { } }   # (the hover picture of "Muted")
        if ($b.Image) { $old = $b.Image; $b.Image = $null; try { $old.Dispose() } catch { } }
        $b.Tag = $null
        $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $T.Surface; $b.ForeColor = $T.Text
        $b.FlatAppearance.MouseOverBackColor = $T.Hover
        $b.TextImageRelation = 'Overlay'; $b.ImageAlign = 'MiddleCenter'; $b.TextAlign = 'MiddleCenter'
        $b.Padding = New-Object System.Windows.Forms.Padding(0)
        $b.Width = 40; $b.Font = $script:FontIcon
        if ($style -eq 'text') { $b.Text = $d[2]; continue }
        $b.Text = ''
        $col = switch ($style) { 'accent' { $T.Accent } 'soft' { $T.Accent } 'tiles' { $T.OnAccent } 'muted' { $T.Muted } default { $T.Text } }
        switch ($style) {
            'tiles' { $b.BackColor = $T.Accent; $b.FlatAppearance.MouseOverBackColor = $T.AccentHover }
            'soft'  { $b.BackColor = $script:SoftTile; $b.FlatAppearance.MouseOverBackColor = $T.Hover }
            'ring'  { $b.BackColor = $T.Bg; $b.FlatAppearance.MouseOverBackColor = $T.Bg }
        }
        if ($style -eq 'label') {
            # the icon and the word side by side (the top bar keeps its height); wide enough for the word
            $b.Image = Get-TopIconPicture $d[1] 'thin' $T.Text 18
            $b.Text = $d[3]; $b.Font = $script:FontSmall; $b.ForeColor = $T.Text
            $b.TextImageRelation = 'ImageBeforeText'; $b.ImageAlign = 'MiddleLeft'; $b.TextAlign = 'MiddleRight'
            $b.Padding = New-Object System.Windows.Forms.Padding(6, 0, 8, 0)
            $b.Width = [System.Windows.Forms.TextRenderer]::MeasureText($d[3], $script:FontSmall).Width + 40
            continue
        }
        $b.Image = Get-TopIconPicture $d[1] $style $col $(if ($style -eq 'ring') { 30 } else { 22 })
        if ($style -eq 'muted') {
            # grey until the mouse is over it
            $b.Tag = @{ Off = $b.Image; On = (Get-TopIconPicture $d[1] 'accent' $T.Accent 22 'muted-hover') }
            if (-not $script:TopHoverWired) { }
        }
    }
    if (-not $script:TopHoverWired) {
        $script:TopHoverWired = $true
        foreach ($d in $defs) {
            $d[0].Add_MouseEnter({ if ($this.Tag -is [hashtable] -and $this.Tag.On) { $this.Image = $this.Tag.On } })
            $d[0].Add_MouseLeave({ if ($this.Tag -is [hashtable] -and $this.Tag.Off) { $this.Image = $this.Tag.Off } })
        }
    }
    try { Update-IconButtons } catch { }   # (2.9.2: the other windows' buttons in the same look)
}

# ---- 2.9.2: icons on the buttons of the Downloads and Logs windows, the main window and the cast bar
# The same look as the top bar (Options > General > Top bar icons): icons\<theme>\<style>\<kind>.png from
# the repository. "Text symbols" (or a missing file): the old symbol in the text, as before.
# The teal (primary) buttons use the "tiles" icons, which are made for a teal background.
$script:IconButtons = New-Object System.Collections.ArrayList   # @{ Button; Kind; Text; Glyph; Primary; IconOnly }
$script:BtnIconCache = @{}

function Get-ButtonIcon([string] $Kind, [bool] $Primary, [int] $Size = 18) {
    $style = [string](Get-AppSettings).TopIcons
    if (-not $style -or $style -eq 'text') { return $null }
    # (on an ordinary button: label = thin; ring = thin, the ring is too small at 18 px; tiles = solid,
    #  its dark icons are made for a teal tile)
    $folder = if ($Primary) { 'tiles' } else { switch ($style) { 'label' { 'thin' } 'ring' { 'thin' } 'tiles' { 'solid' } default { $style } } }
    $key = '{0}|{1}|{2}|{3}' -f (Get-AssetTheme), $folder, $Kind, $Size
    if ($script:BtnIconCache.ContainsKey($key)) { return $script:BtnIconCache[$key] }
    $png = Get-AssetImage ('icons/{0}/{1}/{2}.png' -f (Get-AssetTheme), $folder, $Kind)
    $img = if ($png) { New-ScaledImage $png $Size $Size } else { $null }
    $script:BtnIconCache[$key] = $img
    return $img
}

function Set-IconText($Button, [string] $Kind, [string] $Text, [string] $Glyph = '', [switch] $Primary, [switch] $IconOnly, [string] $Plain = '') {
    # (-Plain: the exact text when there is no icon, e.g. "-15")
    # sets a button's icon and text (and remembers them, so a change of look or theme redraws it)
    if (-not $Button) { return }
    $meta = $null
    foreach ($m in $script:IconButtons) { if ([object]::ReferenceEquals($m.Button, $Button)) { $meta = $m; break } }
    if (-not $meta) { $meta = @{ Button = $Button }; [void]$script:IconButtons.Add($meta); $Button.Add_Disposed({ $me = $this; foreach ($m in @($script:IconButtons)) { if ([object]::ReferenceEquals($m.Button, $me)) { $script:IconButtons.Remove($m) } } }) }
    $meta.Kind = $Kind; $meta.Text = $Text; $meta.Glyph = $Glyph; $meta.Primary = [bool]$Primary; $meta.IconOnly = [bool]$IconOnly; $meta.Plain = $Plain
    $img = Get-ButtonIcon $Kind ([bool]$Primary) $(if ($IconOnly) { 20 } else { 18 })
    if ($img) {
        if (-not [object]::ReferenceEquals($Button.Image, $img)) { $Button.Image = $img }
        $Button.TextImageRelation = 'ImageBeforeText'
        if ($Button.TextAlign -eq 'MiddleLeft') { $Button.ImageAlign = 'MiddleLeft' } else { $Button.ImageAlign = 'MiddleCenter' }
        $t = if ($IconOnly) { '' } else { ' ' + $Text }
    } else {
        if ($Button.Image -and $script:BtnIconCache.Count -ge 0) { $Button.Image = $null }
        $Button.TextImageRelation = 'Overlay'
        $t = if ($Plain) { $Plain } elseif ($IconOnly) { $Glyph } elseif ($Glyph) { '{0}  {1}' -f $Glyph, $Text } else { $Text }
    }
    if ($Button.Text -ne $t) { $Button.Text = $t }
}

function Update-IconButtons {
    # the look or the theme changed (or new icons arrived): every remembered button again
    $old = $script:BtnIconCache; $script:BtnIconCache = @{}
    foreach ($m in @($script:IconButtons)) {
        if (-not $m.Button -or $m.Button.IsDisposed) { $script:IconButtons.Remove($m); continue }
        Set-IconText $m.Button $m.Kind $m.Text $m.Glyph -Primary:$m.Primary -IconOnly:$m.IconOnly -Plain ([string]$m.Plain)
    }
    foreach ($v in @($old.Values)) { if ($v) { try { $v.Dispose() } catch { } } }
}


$script:Brushes = @{}
function Get-Brush([System.Drawing.Color] $Color) {
    $key = $Color.ToArgb()
    if (-not $script:Brushes.ContainsKey($key)) { $script:Brushes[$key] = New-Object System.Drawing.SolidBrush($Color) }
    return $script:Brushes[$key]
}

function Invoke-DrawDarkRow {
    # Owner-draw for every list: dark row, accent bar on the selected row, optional icon,
    # primary text on the left and muted secondary text (SubItems[1]) on the right.
    param($List, $E)
    $item = $E.Item
    $r = $item.Bounds
    $row = New-Object System.Drawing.Rectangle($r.X, $r.Y, $List.ClientSize.Width, $r.Height)
    $g = $E.Graphics
    if ($item.Tag -is [string] -and $item.Tag -eq '__heading') {
        # group heading row: not selectable, small muted caps
        $g.FillRectangle((Get-Brush $List.BackColor), $row)
        $hr = New-Object System.Drawing.Rectangle(($row.X + 12), ($row.Y + 8), ($row.Width - 20), ($row.Height - 8))
        [System.Windows.Forms.TextRenderer]::DrawText($g, $item.Text, $script:FontSmall, $hr, $T.Muted,
            [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, SingleLine, NoPrefix')
        return
    }
    $bg = if ($item.Selected) { $T.Sel } else { $List.BackColor }
    $g.FillRectangle((Get-Brush $bg), $row)
    if ($item.Selected) { $g.FillRectangle((Get-Brush $T.Accent), $row.X, $row.Y + 6, 3, $row.Height - 12) }

    $x = $row.X + 12
    if ($List.SmallImageList -and $List.SmallImageList.ImageSize.Width -gt 1 -and $item.ImageKey) {
        $img = $List.SmallImageList.Images[$item.ImageKey]
        if ($img) { $g.DrawImage($img, $x, $row.Y + [int](($row.Height - $img.Height) / 2)); $x += $img.Width + 8 }
    }
    $kv = ($List.Tag -eq 'kv')
    $secondary = if ($item.SubItems.Count -gt 1) { $item.SubItems[1].Text } else { '' }
    $flagsL = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, SingleLine, NoPrefix'
    $flagsR = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter, EndEllipsis, SingleLine, NoPrefix'
    $right = $row.Right - 12
    $secW = 0
    if ($secondary) {
        $max = if ($kv) { [int]($row.Width * 0.62) } else { [int]($row.Width * 0.4) }
        $secW = [Math]::Min(([System.Windows.Forms.TextRenderer]::MeasureText($secondary, $script:FontSmall)).Width + 4, $max)
        $secRect = New-Object System.Drawing.Rectangle(($right - $secW), $row.Y, $secW, $row.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $secondary, $script:FontSmall, $secRect, $(if ($kv) { $T.Text } else { $T.Muted }), $flagsR)
    }
    $fore = if ($kv) { $T.Muted } elseif ($item.ForeColor -eq $T.Muted) { $T.Muted } else { $T.Text }
    $textW = [Math]::Max(10, $right - $secW - 8 - $x)
    $desc = if ($List.Tag -eq 'two' -and $item.Tag -and $item.Tag.PSObject) { [string]$item.Tag.ListLine2 } else { '' }
    if ($desc) {
        # files list with descriptions: title on the first line, the description (muted) under it
        $half = [int]($row.Height / 2)
        $t1 = New-Object System.Drawing.Rectangle($x, ($row.Y + 3), $textW, ($half - 3))
        $t2 = New-Object System.Drawing.Rectangle($x, ($row.Y + $half), ([Math]::Max(10, $right - $x)), ($half - 5))
        [System.Windows.Forms.TextRenderer]::DrawText($g, $item.Text, $List.Font, $t1, $fore, [System.Windows.Forms.TextFormatFlags]'Left, Bottom, EndEllipsis, SingleLine, NoPrefix')
        [System.Windows.Forms.TextRenderer]::DrawText($g, $desc, $script:FontSmall, $t2, $T.Muted, [System.Windows.Forms.TextFormatFlags]'Left, Top, EndEllipsis, SingleLine, NoPrefix')
    } else {
        $textRect = New-Object System.Drawing.Rectangle($x, $row.Y, $textW, $row.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $item.Text, $List.Font, $textRect, $fore, $flagsL)
    }
    if ($item.Tag -and $item.Tag.PSObject -and $null -ne $script:WatchDraw) { & $script:WatchDraw $g $row $item.Tag }   # watched mark / progress (when there is any)
}

function New-DarkList {
    param([System.Drawing.Color] $Back = $T.Panel, [int] $RowHeight = 34, [switch] $WithIcons, [string] $Mode = '', [string] $Header = '')
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true
    $lv.HeaderStyle = if ($Header) { 'Nonclickable' } else { 'None' }
    $lv.MultiSelect = $false; $lv.HideSelection = $false; $lv.BorderStyle = 'None'
    $lv.BackColor = $Back; $lv.ForeColor = $T.Text; $lv.Font = $script:FontUi
    $lv.OwnerDraw = $true; $lv.Tag = $Mode
    [void]$lv.Columns.Add($(if ($Header) { $Header } else { 'Main' }), 200)
    if ($WithIcons) { $lv.SmallImageList = $script:Icons }
    else {
        $il = New-Object System.Windows.Forms.ImageList
        $il.ImageSize = New-Object System.Drawing.Size(1, $RowHeight)
        $lv.SmallImageList = $il
    }
    $lv.Add_DrawColumnHeader({
        # dark header: list background, muted caps text, thin line underneath
        $l = $args[0]; $e = $args[1]
        $r = New-Object System.Drawing.Rectangle($e.Bounds.X, $e.Bounds.Y, $l.ClientSize.Width, $e.Bounds.Height)
        $e.Graphics.FillRectangle((Get-Brush $l.BackColor), $r)
        $e.Graphics.FillRectangle((Get-Brush $T.Border), $r.X, $r.Bottom - 1, $r.Width, 1)
        $tr = New-Object System.Drawing.Rectangle(($r.X + 12), $r.Y, ($r.Width - 20), $r.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text.ToUpper(), $script:FontSmall, $tr, $T.Muted,
            [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, SingleLine, NoPrefix')
    })
    $lv.Add_DrawItem({ })
    $lv.Add_DrawSubItem({ if ($args[1].ColumnIndex -eq 0) { Invoke-DrawDarkRow $args[0] $args[1] } })
    $lv.Add_Resize({ $l = $args[0]; if ($l.Columns.Count -gt 0) { $l.Columns[0].Width = [Math]::Max(60, $l.ClientSize.Width - 1) } })
    $lv.Add_HandleCreated({ Enable-DarkScrollbars $args[0] })
    return $lv
}

function Add-DarkListRow {
    param($List, [string] $Text, [string] $Secondary = '', $Tag = $null, [string] $Icon = '', [switch] $Dim)
    $row = New-Object System.Windows.Forms.ListViewItem([string]$Text)
    [void]$row.SubItems.Add([string]$Secondary)
    if ($Icon) { $row.ImageKey = $Icon }
    if ($Dim) { $row.ForeColor = $T.Muted }
    $row.Tag = $Tag
    [void]$List.Items.Add($row)
    return $row
}

function New-SectionLabel([string] $Text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Dock = 'Top'; $l.Height = 36; $l.Font = $script:FontHeader; $l.ForeColor = $T.Text
    $l.TextAlign = 'BottomLeft'; $l.Padding = New-Object System.Windows.Forms.Padding(4, 0, 0, 6)
    return $l
}

#endregion

#region ---------- GUI: settings file -----------------------------------------------

$script:SettingsFile = Join-Path $script:AppDataDir 'settings.json'
$script:SettingDefaults = [ordered]@{
    SkippedDependencies = @(); Layout = $null; Theme = 'System'; DownloadDir = ''; RadioDownloadDir = ''; RadioFormat = 'original'; AppIcon = ''
    TrayIcon = $false; MinimizeToTray = $false; CloseToTray = $false; StartWithWindows = $false
    StartMenuShortcut = $true; DesktopShortcut = $true; OnePlayer = $true
    LastCacheClean = ''
    CheckUpdates = $true; LastUpdateCheck = ''; SkippedVersion = ''; CacheRefresh = 'Normal'
    DlKeepList = $true   # downloads: the whole list (also finished ones) is still there after a restart
    DlParallel = 3; DlAutoResume = $true   # downloads: pieces at a time / pause and continue by itself when the connection drops
    DlEmbedSubs = $true; DlKeepSrt = $true   # downloads: subtitles inside the video file / keep the .srt as well
    Logging = $false   # save logs to disk (the Logs window always shows this session)
    AudioDevice = ''   # sound output for this app only ('' = the Windows default)
    VideoPlayer = 'builtin'   # programmes/episodes: builtin (our own player) or web (NRK's page)
    ResumePlayback = $false; LastPlayed = ''   # continue where you left off (LastPlayed: JSON)
    IndexAuto = $true   # run the indexer by itself when the saved data is more than a day old
    IndexPaceMs = 1000; IndexFreshHours = 20; IndexSchedule = $false; IndexTime = '03:00'   # the Indexer
    SortOrder = 'desc'   # folders and files: desc (Z-A), asc (A-Z) or nrk (NRK's own order)
    LogDays = 3   # days of log files to keep (settings.json only)
    ListDescriptions = $true   # files list: the description on a second line
    ResumePosition = $true; HideWatched = $false   # continue each programme where you stopped / hide watched ones in the list
    SearchTv = $true; SearchRadio = $true; SearchSeries = $true; SearchPrograms = $true; SearchEpisodes = $true
    SearchAvailable = $false; SearchYear = 'any'   # search filters (the button next to the search box)
    VideoRate = '1'; SubSize = 120; SubsOff = $false   # built-in player: speed, subtitle size, subtitles turned off
    PreferAD = $false; DlAudioDescription = $false   # audio description (synstolking): play / download it when there is one
    DlSkipHistory = $true; DlNfo = $false; DlQuality = 'best'; DlContainer = 'mp4'   # downloads: history, Kodi files, quality, MP4/MKV
    DlSeriesNewest = 0; DlSeriesAfter = ''; DlSpeedKB = 0; DlWindow = ''; DlNotify = $true   # whole series: newest N / after a date; speed limit; hours; notifications
    AutoNext = $true   # play the next episode (video, radio, cast) when one ends
    FilesView = 'list'   # files list: list (rows) or grid (thumbnails)
    ChildMode = $false; ChildMaxAge = 'A'; ChildPin = ''   # child mode: only NRK Super, up to this age; the PIN (hashed) to leave it
    TopIcons = 'text'   # top bar icons: text, thin, bold, solid, accent, duotone, ring, tiles, soft, muted, label
    # ---- 2.9.0 (see CHANGES-2.9.0.md) ----
    SubColor = 'white'; SubBg = 'box'; SubPos = 'bottom'   # built-in player subtitles: colour, background, height
    UpNextCard = $true; UpNextSeconds = 10   # end of an episode: a card that counts down to the next one (off: straight on, as before)
    SleepFade = $true   # sleep timer: lower the volume over the last minute
    NowPlaying = $true   # live radio: the song playing now (when NRK tells)
    AlarmOn = $false; AlarmTime = '07:00'; AlarmDays = '1,2,3,4,5'; AlarmChannel = 'p1'; AlarmChannelTitle = 'NRK P1'; AlarmLast = ''   # wake to radio
    RecordDir = ''   # recordings of live TV / radio ('' = <download folder>\Recordings)
    DlNameTv = ''; DlNameRadio = ''   # file-name templates ('' = the built-in names)
    Hotkeys = $true; HotkeyMap = ''   # global hotkeys (work while the app is in the background); HotkeyMap: JSON, '' = the defaults
    KeyMap = ''   # in-app shortcuts (JSON, '' = the defaults)
    RemoteOn = $false; RemoteKey = ''   # phone remote (a page on your network)
    StatsOn = $true   # count what you watch and listen to (Statistics)
    SkipSilence = $false; VoiceBoost = $false   # radio bar: quiet parts faster; clearer speech
    TaskbarButtons = $true   # Previous / Play-Pause / Next under the taskbar preview, and the jump list
}
# Settings are read from disk only when settings.json changed (another copy, the indexer or
# an edit by hand): otherwise the last read is reused. Each caller gets its own copy.
$script:SettingsMem = @{ Stamp = ''; Values = $null }
function Get-AppSettings {
    # In memory: Save-AppSettings (and a restore) start a fresh read; the file itself is looked at
    # at most every 10 s (for a change made outside the app), not on every call.
    if ($script:SettingsMem.Stamp -and $script:SettingsMem.Values -and $script:SettingsMem.CheckedAt -and ([Environment]::TickCount - $script:SettingsMem.CheckedAt) -lt 10000 -and ([Environment]::TickCount - $script:SettingsMem.CheckedAt) -ge 0) {
        $copy = [ordered]@{}; foreach ($k in $script:SettingsMem.Values.Keys) { $copy[$k] = $script:SettingsMem.Values[$k] }
        return [pscustomobject]$copy
    }
    $stamp = ''
    try { $fi = New-Object IO.FileInfo($script:SettingsFile); if ($fi.Exists) { $stamp = '{0}|{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length } else { $stamp = 'none' } } catch { }
    $script:SettingsMem.CheckedAt = [Environment]::TickCount
    if ($stamp -and $stamp -eq $script:SettingsMem.Stamp -and $script:SettingsMem.Values) {
        $copy = [ordered]@{}; foreach ($k in $script:SettingsMem.Values.Keys) { $copy[$k] = $script:SettingsMem.Values[$k] }
        return [pscustomobject]$copy
    }
    $r = Read-AppSettingsFile
    $vals = [ordered]@{}; foreach ($p in $r.PSObject.Properties) { $vals[$p.Name] = $p.Value }
    $script:SettingsMem = @{ Stamp = $stamp; Values = $vals; CheckedAt = [Environment]::TickCount }
    return $r
}
function Read-AppSettingsFile {
    $h = [ordered]@{}
    foreach ($k in $script:SettingDefaults.Keys) { $h[$k] = $script:SettingDefaults[$k] }
    try {
        $loaded = $null
        foreach ($f in @($script:SettingsFile, "$($script:SettingsFile).bak")) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try { $loaded = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $loaded = $null }
            if ($loaded) { if ($f -ne $script:SettingsFile -and -not $script:SettingsBakNoted) { $script:SettingsBakNoted = $true; Write-Log WARN 'settings.json could not be read: using settings.json.bak' }; break }
        }
        if ($loaded) {
            foreach ($k in @($h.Keys)) {
                $prop = $loaded.PSObject.Properties[$k]
                if (-not $prop -or $null -eq $prop.Value) { continue }
                $def = $script:SettingDefaults[$k]
                if ($def -is [bool]) { $h[$k] = [bool]$prop.Value }
                elseif ($def -is [int]) { $n = 0; if ([int]::TryParse([string]$prop.Value, [ref]$n)) { $h[$k] = $n } }
                elseif ($k -eq 'SkippedDependencies') { $h[$k] = @($prop.Value) }
                elseif ($k -eq 'Theme') { if ($prop.Value -in 'System', 'Light', 'Dark') { $h[$k] = [string]$prop.Value } }
                elseif ($k -eq 'Layout') { $h[$k] = $prop.Value }
                else { $h[$k] = [string]$prop.Value }
            }
        }
    } catch { Write-Log WARN "Could not read settings: $($_.Exception.Message)" }
    return [pscustomobject]$h
}
function Save-AppSettings($Settings) {
    # never half-written: write a new file next to it, then swap it in (the old one stays as .bak)
    try {
        New-Item -ItemType Directory -Path $script:AppDataDir -Force | Out-Null
        $json = $Settings | ConvertTo-Json -Depth 12
        $tmp = "$($script:SettingsFile).$PID.tmp"
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $script:SettingsFile) {
            try { [IO.File]::Replace($tmp, $script:SettingsFile, "$($script:SettingsFile).bak") }
            catch {
                # in use for a moment (the indexer reading it?): try again, then copy over it
                Start-Sleep -Milliseconds 150
                try { [IO.File]::Replace($tmp, $script:SettingsFile, "$($script:SettingsFile).bak") }
                catch { Copy-Item -LiteralPath $script:SettingsFile -Destination "$($script:SettingsFile).bak" -Force -ErrorAction SilentlyContinue; Copy-Item -LiteralPath $tmp -Destination $script:SettingsFile -Force; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
        else { [IO.File]::Move($tmp, $script:SettingsFile) }
        $script:SettingsMem.Stamp = ''      # read again next time
        Write-Log INFO "Settings saved: $($script:SettingsFile)"
    } catch {
        Write-Log WARN "Could not save settings: $($_.Exception.Message)"
        Remove-Item -LiteralPath "$($script:SettingsFile).$PID.tmp" -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region ---------- GUI: dependency check (runs before the main window) ---------------

$script:TranscriptNoise = '^\*{5,}$|^(Windows PowerShell transcript|PowerShell transcript|Start time|End time|Username|RunAs User|Configuration Name|Machine|Host Application|Process ID|PSVersion|PSEdition|PSCompatibleVersions|BuildVersion|CLRVersion|WSManStackVersion|PSRemotingProtocolVersion|SerializationVersion|Transcript started)'

function Update-InstallProgress {
    # Timer tick while the background installer runs: moving dots, step text, bar, output tail.
    $u = $script:DepUi
    if (-not $u -or $u.Form.IsDisposed) { return }
    $job = $u.State.Job
    $u.State.Tick++

    # moving dots under the step text
    $frames = @('●  ○  ○  ○', '○  ●  ○  ○', '○  ○  ●  ○', '○  ○  ○  ●', '○  ○  ●  ○', '○  ●  ○  ○')
    $u.Dots.Text = $frames[$u.State.Tick % $frames.Count]

    $st = Read-InstallStatus $job.StatusFile
    if ($st) {
        if ($st.Text -ne $u.State.LastStep) {
            $u.State.LastStep = $st.Text
            Write-Log INFO ("Installer step {0}/{1}: {2}" -f $st.Step, $st.Total, $st.Text)
        }
        $u.Step.Text = $st.Text
        if ($st.Total -gt 0) {
            $u.Counter.Text = 'Step {0} of {1}' -f [Math]::Max(1, $st.Step), $st.Total
            # a running step counts as half done so the bar moves as soon as it starts
            $doneSteps = [Math]::Max(0, $st.Step - 1) + 0.5
            $u.Fill.Width = [int]($u.Track.Width * [Math]::Min(1, $doneSteps / $st.Total))
        }
    }

    # installer output, refreshed about once a second
    if ($u.State.Tick % 3 -eq 0 -or $job.Process.HasExited) {
        try {
            if (Test-Path -LiteralPath $job.Transcript) {
                $raw = Read-LogTail -Path $job.Transcript -MaxBytes 256KB
                if ($raw.Length -ne $u.State.LastLen) {
                    $u.State.LastLen = $raw.Length
                    $lines = $raw -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch $script:TranscriptNoise }
                    $u.Log.Text = ($lines -join "`r`n")
                    $u.Log.SelectionStart = $u.Log.TextLength; $u.Log.ScrollToCaret()
                }
            }
        } catch { }
    }

    if (-not $job.Process.HasExited) { return }

    # ---- finished
    $u.State.Timer.Stop()
    $code = $job.Process.ExitCode
    Write-Log $(if ($code -eq 0) { 'INFO' } else { 'ERROR' }) "Installer exited with code $code (transcript: $($job.Transcript))"
    try { foreach ($line in ((Read-LogTail -Path $job.Transcript -MaxBytes 512KB) -split "`r?`n")) { if ($line.Trim() -and $line -notmatch $script:TranscriptNoise) { Write-Log DEBUG "  [installer] $line" } } } catch { }
    foreach ($f in $job.ScriptFile, $job.StatusFile, $job.Transcript) { try { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue } catch { } }

    $u.State.Done = $true
    $u.Status = Get-DependencyStatus
    $still = @($u.Status | Where-Object { $u.State.Keys -contains $_.Key -and -not $_.Found })
    # anything that is present now no longer needs a "don't ask again" entry
    $settings = Get-AppSettings
    $present = @($u.Status | Where-Object Found | ForEach-Object Key)
    if (@($settings.SkippedDependencies | Where-Object { $present -contains $_ }).Count -gt 0) {
        $settings.SkippedDependencies = @($settings.SkippedDependencies | Where-Object { $present -notcontains $_ })
        Save-AppSettings $settings
    }
    $u.Fill.Width = $u.Track.Width
    $u.Dots.Text = ''
    $verb = if ($u.State.Mode -eq 'reinstall') { 'reinstalled' } else { 'installed' }
    if ($still.Count -eq 0 -and $code -eq 0) {
        $u.Head.Text = 'All set'
        $u.Step.Text = "Everything you selected is $verb."
        $u.Step.ForeColor = $T.Ok; $u.Fill.BackColor = $T.Ok
        $u.Counter.Text = 'Done'
    } else {
        $u.Head.Text = $(if ($still.Count -gt 0) { 'Some installs did not complete' } else { 'Finished with warnings' })
        $u.Step.Text = $(if ($still.Count -gt 0) { 'Still missing: ' + (($still | ForEach-Object Name) -join ', ') } else { 'Check the output below.' })
        $u.Step.ForeColor = $T.Bad; $u.Fill.BackColor = $T.Bad
        $u.Counter.Text = "Exit code $code"
        $u.Sub.Text = 'See the output below, or Logs (top bar), for the reason.'
    }
    $u.Install.Text = $(if ($u.Startup) { 'Continue' } else { 'Back to list' })
    $u.Install.Enabled = $true; $u.Skip.Enabled = $true
}

function Get-DependencyHow {
    param($Row, [switch] $Reinstall)
    if ($Reinstall) {
        switch ($Row.Key) {
            'webview2-sdk'     { 'Reinstall: delete the downloaded SDK  ->  download it again from nuget.org' }
            'hlsjs'            { 'Reinstall: delete hls.min.js  ->  download it again (cdn.jsdelivr.net)' }
            'webview2-runtime' { 'Reinstall: winget install --force (it is part of Windows and cannot be uninstalled)' }
            'ffmpeg'           { 'Reinstall: winget uninstall Gyan.FFmpeg  ->  winget install Gyan.FFmpeg' }
            'winget'           { 'Repair: re-register App Installer  ->  Repair-WinGetPackageManager' }
        }
        return
    }
    $how = switch ($Row.Method) {
        'winget'     { "Install: winget install $($Row.Package)" }
        'nuget'      { 'Install: download from nuget.org (official Microsoft package)' }
        'download'   { "Install: download hls.min.js $($script:HlsJsVersion) from cdn.jsdelivr.net (open-source, Apache 2.0)" }
        'bootstrap'  { 'Install: re-register App Installer, or Microsoft.WinGet.Client from the PowerShell Gallery' }
    }
    if ($Row.Admin) { $how += '   (Windows may ask for administrator approval)' }
    return $how
}

function Show-DepRows {
    # (Re)builds the component list: every component, with Install tickbox or Reinstall button.
    $u = $script:DepUi
    $u.Rows.SuspendLayout()
    foreach ($c in @($u.Rows.Controls)) { $c.Dispose() }
    $u.Rows.Controls.Clear()
    $u.Checks = @{}
    $settings = Get-AppSettings
    $missing = @($u.Status | Where-Object { -not $_.Found })
    $u.Head.Text = if ($missing.Count -gt 0) { 'Some components are missing' } else { 'Components' }
    $u.Sub.Text = if ($u.Startup) { 'Nothing is installed without your OK. Untick an item to skip it; that feature will not work until it is installed. Exit closes NRK Browser.' }
                  else { 'What NRK Browser uses and where it was found. Install what is missing, or reinstall something that is broken.' }
    $u.Sub.ForeColor = $T.Muted

    $y = 4
    foreach ($r in $u.Status) {
        $mark = New-Object System.Windows.Forms.Label
        $mark.Text = $(if ($r.Found) { [string][char]0x2714 } else { [string][char]0x2716 })
        $mark.ForeColor = $(if ($r.Found) { $T.Ok } else { $T.Bad })
        $mark.Font = $script:FontHeader; $mark.Location = New-Object System.Drawing.Point(18, $y); $mark.Size = New-Object System.Drawing.Size(24, 24)
        $name = New-Object System.Windows.Forms.Label
        $name.Text = $r.Name; $name.Font = $script:FontBold; $name.ForeColor = $T.Text
        $name.Location = New-Object System.Drawing.Point(44, ($y + 2)); $name.Size = New-Object System.Drawing.Size(480, 22)
        $purpose = New-Object System.Windows.Forms.Label
        $purpose.Text = $r.Purpose; $purpose.ForeColor = $T.Muted
        $purpose.Location = New-Object System.Drawing.Point(44, ($y + 26)); $purpose.Size = New-Object System.Drawing.Size(520, 20); $purpose.AutoEllipsis = $true
        $detail = New-Object System.Windows.Forms.Label
        $detail.Text = $(if ($r.Found) { "Found: $($r.Detail)" } else { Get-DependencyHow $r })
        $detail.ForeColor = $T.Muted; $detail.Font = $script:FontSmall; $detail.AutoEllipsis = $true
        $detail.Location = New-Object System.Drawing.Point(44, ($y + 48)); $detail.Size = New-Object System.Drawing.Size(520, 18)
        $u.Rows.Controls.AddRange(@($mark, $name, $purpose, $detail))

        if ($r.Found) {
            $b = New-FlatButton $(if ($r.Key -eq 'winget') { 'Repair' } else { 'Reinstall' }) 110
            $b.Location = New-Object System.Drawing.Point(590, ($y + 10))
            $b.Tag = $r.Key
            $tip = New-Object System.Windows.Forms.ToolTip
            $tip.SetToolTip($b, (Get-DependencyHow $r -Reinstall))
            $b.Add_Click({ Start-DepReinstall ([string]$this.Tag) })
            $u.Rows.Controls.Add($b)
        } else {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = 'Install'; $cb.AutoSize = $true; $cb.ForeColor = $T.Text
            $cb.Location = New-Object System.Drawing.Point(600, ($y + 14))
            $skipped = ($u.Startup -and $settings.SkippedDependencies -contains $r.Key)
            # winget is only needed when something else is installed with it
            $cb.Checked = -not $skipped -and $r.Key -ne 'winget'
            $cb.Tag = $r.Key
            $cb.Add_CheckedChanged({ Update-DepInstallButton })
            $u.Rows.Controls.Add($cb)
            $u.Checks[$r.Key] = $cb
        }
        $line = New-Object System.Windows.Forms.Panel
        $line.BackColor = $T.Border; $line.Location = New-Object System.Drawing.Point(18, ($y + 76)); $line.Size = New-Object System.Drawing.Size(684, 1)
        $u.Rows.Controls.Add($line)
        $y += 86
    }
    $u.Rows.ResumeLayout()
    $u.DontAsk.Visible = ($u.Startup -and $missing.Count -gt 0)
    $u.Rows.Visible = $true; $u.Prog.Visible = $false
    $u.State.Done = $false; $u.State.Job = $null
    $u.Skip.Enabled = $true
    Update-DepInstallButton
}

function Update-DepInstallButton {
    $u = $script:DepUi
    if (-not $u -or $u.State.Job) { return }
    $any = @($u.Checks.Values | Where-Object Checked).Count -gt 0
    if ($any) { $u.Install.Text = 'Install selected'; $u.Install.Enabled = $true }
    elseif ($u.Startup) { $u.Install.Text = 'Continue'; $u.Install.Enabled = $true }   # everything skipped on purpose
    else { $u.Install.Text = 'Install selected'; $u.Install.Enabled = $false }
}

function Start-DepJob {
    # Switches the window to the progress view and runs an installer plan in the background.
    param([string[]] $Plan, [string[]] $Keys, [string] $Mode, [string] $Title)
    $u = $script:DepUi
    Write-Log INFO ("Installer plan ({0}): {1}" -f $Mode, ($Plan -join '  ->  '))
    $u.Rows.Visible = $false; $u.DontAsk.Visible = $false; $u.Prog.Visible = $true
    $u.Head.Text = $Title
    $u.Sub.Text = 'This runs in the background; Windows may ask for approval for some packages. Details are kept in Logs (top bar).'
    $u.Sub.ForeColor = $T.Muted
    $u.Step.Text = 'Starting installer'; $u.Step.ForeColor = $T.Text
    $u.Counter.Text = ''; $u.Dots.Text = ''; $u.Log.Text = ''
    $u.Fill.Width = 0; $u.Fill.BackColor = $T.Accent
    $u.Install.Enabled = $false; $u.Skip.Enabled = $false
    $u.State.Keys = $Keys; $u.State.Mode = $Mode; $u.State.Done = $false
    $u.State.Tick = 0; $u.State.LastLen = -1; $u.State.LastStep = ''
    try {
        $u.State.Job = Start-DependencyInstall -Plan $Plan
        if (-not $u.State.Timer) {
            $u.State.Timer = New-Object System.Windows.Forms.Timer
            $u.State.Timer.Interval = 350
            $u.State.Timer.Add_Tick({ Update-InstallProgress })
        }
        $u.State.Timer.Start()
    } catch {
        Write-LogException $_ 'Start-DependencyInstall'
        $u.Step.Text = "Could not start the installer: $($_.Exception.Message)"
        $u.Step.ForeColor = $T.Bad
        $u.State.Job = $null; $u.State.Done = $true
        $u.Install.Text = $(if ($u.Startup) { 'Continue' } else { 'Back to list' })
        $u.Install.Enabled = $true; $u.Skip.Enabled = $true
    }
}

function Start-DepReinstall {
    param([string] $Key)
    $u = $script:DepUi
    $row = $u.Status | Where-Object Key -eq $Key | Select-Object -First 1
    $plan = Get-InstallPlan -Reinstall @($Key) -Status $u.Status
    $what = if ($Key -eq 'winget') { 'Repair' } else { 'Reinstall' }
    $msg = "{0} {1}?`n`n{2}`n`nSteps:`n{3}" -f $what, $row.Name, (Get-DependencyHow $row -Reinstall),
           (($plan | ForEach-Object { '  - ' + ($_ -replace '\|.*$', '' -replace '=', ' ') }) -join "`n")
    if ([System.Windows.Forms.MessageBox]::Show($u.Form, $msg, "$what component", 'YesNo', 'Question') -ne 'Yes') { return }
    Write-Log INFO "User approved $($what.ToLower()) of $Key"
    Start-DepJob -Plan $plan -Keys @($Key) -Mode 'reinstall' -Title ('{0}ing {1}' -f $(if ($what -eq 'Repair') { 'Repair' } else { 'Reinstall' }), $row.Name)
}

function Show-DependencyDialog {
    # The components window. At startup (-Startup) it only opens when something is missing
    # (and not skipped), and its second button is "Exit". From Options it always opens and
    # lists every component, with Install for missing ones and Reinstall for installed ones.
    # Returns 'continue' or 'exit'.
    param([object[]] $Status, [System.Windows.Forms.IWin32Window] $Owner = $null, [switch] $IncludeSkipped, [switch] $Startup)

    if ($Startup) {
        $settings = Get-AppSettings
        $missing = @($Status | Where-Object { -not $_.Found -and $_.Key -ne 'winget' })
        if (-not $IncludeSkipped) { $missing = @($missing | Where-Object { $settings.SkippedDependencies -notcontains $_.Key }) }
        if ($missing.Count -eq 0) { Write-Log INFO 'Dependency check: nothing to install'; return 'continue' }
        Write-Log INFO ('Dependency check: missing {0}' -f (($missing | ForEach-Object Name) -join '; '))
    }

    $d = New-Object System.Windows.Forms.Form
    Set-AppIcon $d   # window, title bar and taskbar icon
    $d.Text = 'NRK Browser - components'
    $d.ClientSize = New-Object System.Drawing.Size(740, 720)
    $d.StartPosition = $(if ($Owner) { 'CenterParent' } else { 'CenterScreen' })
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.Font = $script:FontUi; $d.BackColor = $T.Bg; $d.ForeColor = $T.Text

    $head = New-Object System.Windows.Forms.Label
    $head.Font = $script:FontTitle; $head.Location = New-Object System.Drawing.Point(20, 16); $head.AutoSize = $true
    $sub = New-Object System.Windows.Forms.Label
    $sub.ForeColor = $T.Muted; $sub.Location = New-Object System.Drawing.Point(22, 58); $sub.Size = New-Object System.Drawing.Size(696, 40)

    # component rows (scrolls if needed)
    $rows = New-Object System.Windows.Forms.Panel
    $rows.Location = New-Object System.Drawing.Point(0, 104); $rows.Size = New-Object System.Drawing.Size(740, 528)
    $rows.AutoScroll = $true; $rows.BackColor = $T.Bg

    # progress view (same area)
    $prog = New-Object System.Windows.Forms.Panel
    $prog.Location = New-Object System.Drawing.Point(0, 104); $prog.Size = New-Object System.Drawing.Size(740, 528)
    $prog.BackColor = $T.Bg; $prog.Visible = $false
    $step = New-Object System.Windows.Forms.Label
    $step.Location = New-Object System.Drawing.Point(22, 4); $step.Size = New-Object System.Drawing.Size(696, 26)
    $step.Font = $script:FontHeader; $step.AutoEllipsis = $true
    $dots = New-Object System.Windows.Forms.Label
    $dots.Location = New-Object System.Drawing.Point(22, 32); $dots.Size = New-Object System.Drawing.Size(200, 24)
    $dots.Font = New-Object System.Drawing.Font('Segoe UI', 12); $dots.ForeColor = $T.Accent
    $counter = New-Object System.Windows.Forms.Label
    $counter.Location = New-Object System.Drawing.Point(518, 32); $counter.Size = New-Object System.Drawing.Size(200, 24)
    $counter.TextAlign = 'MiddleRight'; $counter.ForeColor = $T.Muted
    $track = New-Object System.Windows.Forms.Panel
    $track.Location = New-Object System.Drawing.Point(22, 62); $track.Size = New-Object System.Drawing.Size(696, 6); $track.BackColor = $T.Surface
    $fill = New-Object System.Windows.Forms.Panel
    $fill.Location = New-Object System.Drawing.Point(0, 0); $fill.Size = New-Object System.Drawing.Size(0, 6); $fill.BackColor = $T.Accent
    $track.Controls.Add($fill)
    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
    $log.Font = New-Object System.Drawing.Font('Consolas', 9); $log.BackColor = $T.Surface; $log.ForeColor = $T.Text; $log.BorderStyle = 'None'
    $log.Location = New-Object System.Drawing.Point(22, 82); $log.Size = New-Object System.Drawing.Size(696, 440)
    $prog.Controls.AddRange(@($step, $dots, $counter, $track, $log))

    $dontAsk = New-Object System.Windows.Forms.CheckBox
    $dontAsk.Text = "Don't ask again at startup for items I leave unticked"
    $dontAsk.ForeColor = $T.Muted; $dontAsk.AutoSize = $true; $dontAsk.Location = New-Object System.Drawing.Point(22, 650)

    $btnInstall = New-FlatButton 'Install selected' 150 -Primary
    $btnInstall.Location = New-Object System.Drawing.Point(410, 670)
    $btnSkip = New-FlatButton $(if ($Startup) { 'Exit' } else { 'Close' }) 150
    $btnSkip.Location = New-Object System.Drawing.Point(570, 670)
    $d.Controls.AddRange(@($head, $sub, $rows, $prog, $dontAsk, $btnInstall, $btnSkip))

    # Closing the window any other way than Install/Continue counts as Exit (at startup) or Close.
    $state = @{ Job = $null; Done = $false; Result = $(if ($Startup) { 'exit' } else { 'continue' }); Timer = $null; Keys = @(); Mode = '' }
    $script:DepUi = @{ Form = $d; Head = $head; Sub = $sub; Rows = $rows; Prog = $prog; Step = $step; Dots = $dots; Counter = $counter
                       Track = $track; Fill = $fill; Log = $log; DontAsk = $dontAsk; Install = $btnInstall; Skip = $btnSkip
                       State = $state; Status = $Status; Startup = [bool]$Startup; Checks = @{} }

    $btnSkip.Add_Click({
        $ui = $script:DepUi
        if ($ui.State.Job -and -not $ui.State.Job.Process.HasExited) { return }
        Write-Log INFO "Dependency dialog: user chose '$($ui.Skip.Text)'"
        $ui.Form.Close()
    })

    $btnInstall.Add_Click({
        $ui = $script:DepUi
        if ($ui.State.Done) {
            if ($ui.Startup) { $ui.State.Result = 'continue'; $ui.Form.Close() }
            else { Show-DepRows }   # back to the refreshed list
            return
        }
        $sel = @($ui.Checks.Keys | Where-Object { $ui.Checks[$_].Checked })
        $skip = @($ui.Checks.Keys | Where-Object { -not $ui.Checks[$_].Checked -and $_ -ne 'winget' })
        if ($ui.Startup -and $ui.DontAsk.Checked -and $skip.Count -gt 0) {
            $st = Get-AppSettings
            $st.SkippedDependencies = @(@($st.SkippedDependencies) + $skip | Select-Object -Unique)
            Save-AppSettings $st
        }
        if ($sel.Count -eq 0) { $ui.State.Result = 'continue'; $ui.Form.Close(); return }
        Write-Log INFO "User approved install of: $($sel -join ', ')"
        Start-DepJob -Plan (Get-InstallPlan -Install $sel -Status $ui.Status) -Keys $sel -Mode 'install' -Title 'Installing'
    })

    $d.Add_FormClosing({
        param($s, $e)
        $u = $script:DepUi
        if ($u.State.Job -and -not $u.State.Job.Process.HasExited) { $e.Cancel = $true }   # don't lose track of a running install
    })

    Show-DepRows
    Enable-DarkTitleBar $d
    if ($Owner) { [void]$d.ShowDialog($Owner) } else { [void]$d.ShowDialog() }
    if ($state.Timer) { $state.Timer.Stop(); $state.Timer.Dispose() }
    $d.Dispose()
    Write-Log INFO "Dependency dialog result: $($state.Result)"
    return $state.Result
}

#endregion

#region ---------- GUI: main window -------------------------------------------------

$script:Files         = @()      # what the files list shows (channels, programmes or episodes)
$script:SelectedFile  = $null
$script:CatsNode      = $null
$script:LettersNode   = $null

$form = New-Object System.Windows.Forms.Form
$form.Text = "NRK Browser $($script:AppVersion)"
try { $Host.UI.RawUI.WindowTitle = "NRK Browser $($script:AppVersion)" } catch { }   # the (hidden) console too
$form.Size = New-Object System.Drawing.Size(1480, 900)
$form.MinimumSize = New-Object System.Drawing.Size(1100, 640)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $T.Bg; $form.ForeColor = $T.Text
$form.Font = $script:FontUi
$form.KeyPreview = $true

# ---- top bar: back | breadcrumb ............ search | reload | settings
$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = 60; $top.BackColor = $T.Bg
$top.Padding = New-Object System.Windows.Forms.Padding(14, 13, 14, 13)

$btnBack = New-FlatButton ([string][char]0x2039) 36 -Icon
$btnBack.Dock = 'Left'; $btnBack.Enabled = $false
# breadcrumb: every folder in the path is clickable (back), and the deeper folders you came
# from stay visible in grey until you go somewhere else (forward)
$crumb = New-Object System.Windows.Forms.FlowLayoutPanel
$crumb.Dock = 'Fill'; $crumb.WrapContents = $false; $crumb.BackColor = $T.Bg
$crumb.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$script:CrumbNav = $false
$script:CrumbTips = New-Object System.Windows.Forms.ToolTip

$btnSettings = New-FlatButton ([string][char]0x2699) 40 -Icon
$btnSettings.Dock = 'Right'
$btnReload = New-FlatButton ([string][char]0x27F3) 40 -Icon
$btnReload.Dock = 'Right'
$btnLogs = New-FlatButton ([string][char]0x2630) 40 -Icon
$btnLogs.Dock = 'Right'
$btnDownloads = New-FlatButton ([string][char]0x2193) 40 -Icon
$btnDownloads.Dock = 'Right'
$btnIndexer = New-FlatButton ([string][char]0x25A6) 40 -Icon
$btnIndexer.Dock = 'Right'
$gap5 = New-Object System.Windows.Forms.Panel; $gap5.Dock = 'Right'; $gap5.Width = 8
$gap3 = New-Object System.Windows.Forms.Panel; $gap3.Dock = 'Right'; $gap3.Width = 8
$gap4 = New-Object System.Windows.Forms.Panel; $gap4.Dock = 'Right'; $gap4.Width = 8
# hover text for the top-bar buttons
$topTips = New-Object System.Windows.Forms.ToolTip
$topTips.InitialDelay = 300; $topTips.ShowAlways = $true
$topTips.SetToolTip($btnBack, 'Back  (to the folder above)')
$topTips.SetToolTip($btnReload, 'Reload  (fetch everything from NRK again)')
$topTips.SetToolTip($btnDownloads, 'Downloads  (queue and progress, Ctrl+D)')
$topTips.SetToolTip($btnLogs, 'Logs  (Ctrl+L)')
$topTips.SetToolTip($btnIndexer, 'Indexer  (saves every folder in the background, Ctrl+I)')
$topTips.SetToolTip($btnSettings, 'Options  (theme, components, Ctrl+,)')
$gap1 = New-Object System.Windows.Forms.Panel; $gap1.Dock = 'Right'; $gap1.Width = 8
$gap2 = New-Object System.Windows.Forms.Panel; $gap2.Dock = 'Right'; $gap2.Width = 8
$searchHost = New-Object System.Windows.Forms.Panel
$searchHost.Dock = 'Right'; $searchHost.Width = 300; $searchHost.BackColor = $T.Surface
$searchHost.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 4)
$search = New-Object System.Windows.Forms.TextBox
$search.Dock = 'Fill'; $search.BorderStyle = 'None'; $search.BackColor = $T.Surface; $search.ForeColor = $T.Text; $search.Font = $script:FontUi
$searchHost.Controls.Add($search)

$btnFilter = New-FlatButton ([string][char]0x25BE) 34 -Icon
$btnFilter.Dock = 'Right'
$gapF = New-Object System.Windows.Forms.Panel; $gapF.Dock = 'Right'; $gapF.Width = 4
$top.Controls.Add($crumb)        # Fill first
$top.Controls.Add($btnFilter)    # (left of the search box)
$top.Controls.Add($gapF)
$top.Controls.Add($searchHost)
$top.Controls.Add($gap2)
$top.Controls.Add($btnReload)
$top.Controls.Add($gap1)
$top.Controls.Add($btnIndexer)
$top.Controls.Add($gap5)
$top.Controls.Add($btnDownloads)
$top.Controls.Add($gap3)
$top.Controls.Add($btnLogs)
$top.Controls.Add($gap4)
$top.Controls.Add($btnSettings)  # last Right = right-most
$top.Controls.Add($btnBack)

$topLine = New-Object System.Windows.Forms.Panel
$topLine.Dock = 'Top'; $topLine.Height = 1; $topLine.BackColor = $T.Border


# ---- status bar
$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock = 'Bottom'; $statusBar.Height = 30; $statusBar.BackColor = $T.Panel
$statusBar.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 0)
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Dock = 'Fill'; $statusLabel.TextAlign = 'MiddleLeft'; $statusLabel.ForeColor = $T.Muted; $statusLabel.Font = $script:FontSmall
$statusLabel.Text = 'Ready'; $statusLabel.AutoEllipsis = $true
$statusRight = New-Object System.Windows.Forms.Label
$statusRight.Dock = 'Right'; $statusRight.Width = 420; $statusRight.TextAlign = 'MiddleRight'; $statusRight.ForeColor = $T.Muted
$statusRight.Font = $script:FontSmall; $statusRight.AutoEllipsis = $true
$statusRight.Visible = $false   # (the log file is in the Logs window, not down here)
$statusBar.Controls.Add($statusLabel)
$statusBar.Controls.Add($statusRight)

# ---- audio bar (radio), above the status bar; hidden until something is played
$audioBar = New-Object System.Windows.Forms.Panel
$audioBar.Dock = 'Bottom'; $audioBar.Height = 84; $audioBar.BackColor = $T.Panel; $audioBar.Visible = $false
$audioLine = New-Object System.Windows.Forms.Panel
$audioLine.Dock = 'Top'; $audioLine.Height = 1; $audioLine.BackColor = $T.Border
$audioHost = New-Object System.Windows.Forms.Panel
$audioHost.Dock = 'Fill'; $audioHost.BackColor = $T.Panel
$audioBar.Controls.Add($audioHost)
$audioBar.Controls.Add($audioLine)

# ---- folder tree (far left) and files list (next to it)
$folderTree = New-Object System.Windows.Forms.TreeView
$folderTree.Dock = 'Fill'; $folderTree.BorderStyle = 'None'
$folderTree.BackColor = $T.Panel; $folderTree.ForeColor = $T.Text; $folderTree.Font = $script:FontUi
$folderTree.ImageList = $script:Icons; $folderTree.ItemHeight = 34; $folderTree.Indent = 18
$folderTree.ShowLines = $false; $folderTree.ShowRootLines = $true; $folderTree.FullRowSelect = $true
$folderTree.HideSelection = $false; $folderTree.HotTracking = $true
$folderHeader = New-Object System.Windows.Forms.Label
$folderHeader.Dock = 'Top'; $folderHeader.Height = 30; $folderHeader.Text = 'FOLDERS'
$folderHeader.Font = $script:FontSmall; $folderHeader.ForeColor = $T.Muted; $folderHeader.BackColor = $T.Panel
$folderHeader.TextAlign = 'MiddleLeft'; $folderHeader.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$folderHeaderLine = New-Object System.Windows.Forms.Panel
$folderHeaderLine.Dock = 'Top'; $folderHeaderLine.Height = 1; $folderHeaderLine.BackColor = $T.Border
$folderPane = New-Object System.Windows.Forms.Panel
$folderPane.Dock = 'Fill'; $folderPane.BackColor = $T.Panel
$folderPane.Controls.Add($folderTree)        # Fill first
$folderPane.Controls.Add($folderHeaderLine)
$folderPane.Controls.Add($folderHeader)

$itemsList = New-DarkList -Back $T.Bg -WithIcons -Header 'Pick a folder'
$itemsList.Dock = 'Fill'
$itemsList.MultiSelect = $true   # Shift/Ctrl+click to select several files
$itemsList.Add_DrawItem({ if ($args[0].View -eq 'LargeIcon') { try { Invoke-DrawGridItem $args[1] } catch { } } })   # (thumbnail tiles; rows draw in DrawSubItem)

# right-click menus: files list and folder tree
function New-ThemedMenu {
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $m.Font = $script:FontUi; $m.ShowImageMargin = $false
    if ($script:DarkRenderer) { $m.Renderer = $script:DarkRenderer }
    $m.BackColor = $T.Surface; $m.ForeColor = $T.Text
    return $m
}
function New-ThemedMenuItem([string] $Text) {
    $i = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
    $i.ForeColor = $T.Text; $i.Padding = New-Object System.Windows.Forms.Padding(4, 3, 4, 3)
    return $i
}
$filesMenu = New-ThemedMenu
$miFPlay = New-ThemedMenuItem 'Play'
$miFDownload = New-ThemedMenuItem 'Download'
$miFWeb = New-ThemedMenuItem 'Open on NRK'
$miFCopy = New-ThemedMenuItem 'Copy URL'
$miFHide = New-ThemedMenuItem "Hide (don't show or index)"
$miFFav = New-ThemedMenuItem 'Add the series to favourites'
$miFPlayNext = New-ThemedMenuItem 'Play next'
$miFQueue = New-ThemedMenuItem 'Add to queue'
$miFQueueClear = New-ThemedMenuItem 'Clear the radio queue'
$miFView = New-ThemedMenuItem 'Show as thumbnails    (Ctrl+G)'
$miFWatched = New-ThemedMenuItem 'Mark as watched'
$miFUnwatched = New-ThemedMenuItem 'Mark as not watched'
$miFLater = New-ThemedMenuItem 'Watch later'
$miFRecord = New-ThemedMenuItem 'Record...'
[void]$filesMenu.Items.AddRange(@($miFPlay, $miFPlayNext, $miFQueue, $miFQueueClear, $miFDownload, $miFLater, $miFRecord, $miFFav, $miFWatched, $miFUnwatched, (New-Object System.Windows.Forms.ToolStripSeparator), $miFWeb, $miFCopy, (New-Object System.Windows.Forms.ToolStripSeparator), $miFView, $miFHide))
$treeMenu = New-ThemedMenu
$miTDownload = New-ThemedMenuItem 'Download'
$miTOpen = New-ThemedMenuItem 'Open'
$miTClearRecent = New-ThemedMenuItem 'Clear recently played'
$miTCloseSearch = New-ThemedMenuItem 'Close search'
$miTHide = New-ThemedMenuItem "Hide (don't show or index)"
$miTFav = New-ThemedMenuItem 'Add to favourites'
$miTFollow = New-ThemedMenuItem 'Follow (download new episodes by themselves)'
$miTCheckFollow = New-ThemedMenuItem 'Check followed series for new episodes now'
$miTFeed = New-ThemedMenuItem 'Copy the podcast feed address (RSS)'
$miTFollowNotify = New-ThemedMenuItem 'Follow (only tell me about new episodes)'
$miTOpml = New-ThemedMenuItem 'Export the podcasts (OPML)...'
[void]$treeMenu.Items.AddRange(@($miTOpen, $miTDownload, $miTFav, $miTFollow, $miTFollowNotify, $miTCheckFollow, $miTFeed, $miTOpml, $miTClearRecent, $miTCloseSearch, $miTHide))

# ---- content panel: preview card on top, a divider, then details below
#      (+ today's schedule for live channels)
$center = New-Object System.Windows.Forms.Panel
$center.Dock = 'Fill'; $center.BackColor = $T.Bg
$center.Padding = New-Object System.Windows.Forms.Padding(20, 16, 20, 12)

$pic = New-Object System.Windows.Forms.PictureBox
$pic.Dock = 'Top'; $pic.Height = 300; $pic.SizeMode = 'Zoom'; $pic.BackColor = $T.Surface; $pic.Cursor = [System.Windows.Forms.Cursors]::Hand
$pTitle = New-Object System.Windows.Forms.Label
$pTitle.Dock = 'Top'; $pTitle.Height = 52; $pTitle.Font = $script:FontTitle; $pTitle.ForeColor = $T.Text
$pTitle.TextAlign = 'BottomLeft'; $pTitle.AutoEllipsis = $true; $pTitle.Text = 'NRK Browser'
$pMeta = New-Object System.Windows.Forms.Label
$pMeta.Dock = 'Top'; $pMeta.Height = 28; $pMeta.ForeColor = $T.Muted; $pMeta.TextAlign = 'MiddleLeft'; $pMeta.AutoEllipsis = $true
$pMeta.Text = 'Choose a folder on the left.'
$pActions = New-Object System.Windows.Forms.FlowLayoutPanel
$pActions.Dock = 'Top'; $pActions.Height = 52; $pActions.WrapContents = $false; $pActions.BackColor = $T.Bg
$pActions.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
$btnPlay = New-FlatButton ("{0}  Play" -f [char]0x25B6) 120 -Primary
$btnDownload = New-FlatButton ("Download  {0}" -f [char]0x25BE) 130
$btnCast = New-FlatButton ("Cast  {0}" -f [char]0x25BE) 96
$btnOpenWeb = New-FlatButton 'Open on NRK' 0
$btnCopyUrl = New-FlatButton 'Copy URL' 0
$pActions.Controls.AddRange(@($btnPlay, $btnDownload, $btnCast, $btnOpenWeb, $btnCopyUrl))
$btnCast.Width = 110
# (2.9.2: icons in the chosen look; Play is set in Update-Actions)
Set-IconText $btnDownload 'down' ("Download  {0}" -f [char]0x25BE)
Set-IconText $btnCast 'cast' ("Cast  {0}" -f [char]0x25BE)
Set-IconText $btnOpenWeb 'web' 'Open on NRK'
Set-IconText $btnCopyUrl 'link' 'Copy URL'
$pDesc = New-Object System.Windows.Forms.Label
$pDesc.Dock = 'Top'; $pDesc.Height = 24; $pDesc.ForeColor = $T.Muted; $pDesc.AutoEllipsis = $true
$pDesc.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)

# divider between the preview and the details
$divider = New-Object System.Windows.Forms.Panel
$divider.Dock = 'Top'; $divider.Height = 18; $divider.BackColor = $T.Bg
$dividerLine = New-Object System.Windows.Forms.Panel
$dividerLine.Dock = 'Bottom'; $dividerLine.Height = 1; $dividerLine.BackColor = $T.Border
$divider.Controls.Add($dividerLine)

$details = New-Object System.Windows.Forms.Panel
$details.Dock = 'Fill'; $details.BackColor = $T.Bg
$hdrDetails = New-SectionLabel 'Details'
# details: a compact grid of label/value pairs, two columns when there is room
$metaList = New-Object System.Windows.Forms.Panel
$metaList.Dock = 'Top'; $metaList.Height = 10; $metaList.BackColor = $T.Bg
$metaList.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic, Instance').SetValue($metaList, $true)
$script:MetaPairs = New-Object System.Collections.ArrayList
$script:MetaTips = New-Object System.Windows.Forms.ToolTip
$script:MetaRowH = 26
function Get-MetaLayout {
    # columns, column width, label width, rows for the current width
    $w = [Math]::Max(100, $metaList.ClientSize.Width)
    $cols = if ($w -ge 560 -and $script:MetaPairs.Count -gt 3) { 2 } else { 1 }
    $gap = 28
    $colW = [int](($w - ($cols - 1) * $gap) / $cols)
    $labelW = [int][Math]::Min(120, $colW * 0.4)
    $rows = [int][Math]::Ceiling($script:MetaPairs.Count / $cols)
    return @{ Cols = $cols; ColW = $colW; LabelW = $labelW; Rows = $rows; Gap = $gap }
}
function Update-MetaHeight {
    $L = Get-MetaLayout
    $h = [Math]::Max(4, $L.Rows * $script:MetaRowH + 4)
    if ($metaList.Height -ne $h) { $metaList.Height = $h; if (Get-Command Update-ContentLayout -ErrorAction SilentlyContinue) { Update-ContentLayout } }
    $metaList.Invalidate()
}
$metaList.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $L = Get-MetaLayout
    $flags = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, SingleLine, NoPrefix'
    for ($i = 0; $i -lt $script:MetaPairs.Count; $i++) {
        $col = [int][Math]::Floor($i / [Math]::Max(1, $L.Rows)); $row = $i % [Math]::Max(1, $L.Rows)   # fill down, then the next column
        $x = $col * ($L.ColW + $L.Gap) + 4; $y = $row * $script:MetaRowH
        $pair = $script:MetaPairs[$i]
        $g.FillRectangle((Get-Brush $T.Border), $x, ($y + $script:MetaRowH - 1), ($L.ColW - 4), 1)
        $kr = New-Object System.Drawing.Rectangle($x, $y, $L.LabelW, $script:MetaRowH)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $pair[0], $script:FontSmall, $kr, $T.Muted, $flags)
        $vr = New-Object System.Drawing.Rectangle(($x + $L.LabelW + 8), $y, [Math]::Max(10, $L.ColW - $L.LabelW - 12), $script:MetaRowH)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $pair[1], $script:FontSmall, $vr, $T.Text, $flags)
    }
})
$metaList.Add_Resize({ Update-MetaHeight })
$metaList.Add_MouseMove({
    param($s, $e)
    # full value on hover (long ids, titles)
    $L = Get-MetaLayout
    $col = [int][Math]::Floor($e.X / ($L.ColW + $L.Gap)); $row = [int][Math]::Floor($e.Y / $script:MetaRowH)
    $i = $col * $L.Rows + $row
    $tip = if ($row -lt $L.Rows -and $i -ge 0 -and $i -lt $script:MetaPairs.Count) { '{0}: {1}' -f $script:MetaPairs[$i][0], $script:MetaPairs[$i][1] } else { '' }
    if ($script:MetaTips.GetToolTip($metaList) -ne $tip) { $script:MetaTips.SetToolTip($metaList, $tip) }
})
$hdrSchedule = New-SectionLabel 'Schedule today'
$scheduleList = New-DarkList -Back $T.Bg -WithIcons
$scheduleList.Dock = 'Fill'
$hdrSchedule.Visible = $false; $scheduleList.Visible = $false
$details.Controls.Add($scheduleList)   # Fill first, then Top items bottom-to-top
$details.Controls.Add($hdrSchedule)
$details.Controls.Add($metaList)
$details.Controls.Add($hdrDetails)

$downloadMenu = New-Object System.Windows.Forms.ContextMenuStrip
$downloadMenu.Font = $script:FontUi; $downloadMenu.ShowImageMargin = $false
if ($script:DarkRenderer) { $downloadMenu.Renderer = $script:DarkRenderer }
$downloadMenu.BackColor = $T.Surface; $downloadMenu.ForeColor = $T.Text
$miDlEpisode = New-Object System.Windows.Forms.ToolStripMenuItem('This episode')
$miDlSeason = New-Object System.Windows.Forms.ToolStripMenuItem('This season')
$miDlSeries = New-Object System.Windows.Forms.ToolStripMenuItem('Whole series')
foreach ($mi in $miDlEpisode, $miDlSeason, $miDlSeries) { $mi.ForeColor = $T.Text; [void]$downloadMenu.Items.Add($mi) }

$center.Controls.Add($details)       # Fill first, then Top items bottom-to-top
$center.Controls.Add($divider)
$center.Controls.Add($pDesc)
$center.Controls.Add($pActions)
$center.Controls.Add($pMeta)
$center.Controls.Add($pTitle)
$center.Controls.Add($pic)

function Update-ContentLayout {
    # Description gets the height its text needs (up to 6 lines); the picture shrinks so
    # the details below always keep some room.
    $w = [Math]::Max(100, $center.ClientSize.Width - $center.Padding.Horizontal)
    $h = 24
    if ($pDesc.Text) {
        $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText($pDesc.Text, $pDesc.Font, (New-Object System.Drawing.Size($w, 2000)), $flags)
        $h = [int][Math]::Min($sz.Height + $pDesc.Padding.Vertical + 4, ($pDesc.Font.Height * 6) + $pDesc.Padding.Vertical + 4)
    }
    if ($pDesc.Height -ne $h) { $pDesc.Height = $h }
    $avail = $center.ClientSize.Height - $center.Padding.Vertical
    $detailsH = $metaList.Height + $(if ($script:ScheduleOn) { $hdrSchedule.Height + 150 } else { 12 })
    $fixed = $pTitle.Height + $pMeta.Height + $pActions.Height + $pDesc.Height + $divider.Height + $hdrDetails.Height + [Math]::Max(90, $detailsH)
    $picH = [int][Math]::Max(120, [Math]::Min($w * 9 / 16, $avail - $fixed))
    if ($pic.Height -ne $picH) { $pic.Height = $picH }
}

# ---- two draggable split panels:
#   [ Folders | [ Files list | Preview + details ] ]
function New-DarkSplit {
    param([System.Windows.Forms.Control] $Left, [System.Windows.Forms.Control] $Right,
          [System.Drawing.Color] $LeftBack, [System.Drawing.Color] $RightBack, [string] $Fixed = 'Panel1', [int] $Min1 = 160, [int] $Min2 = 200)
    $sc = New-Object System.Windows.Forms.SplitContainer
    $sc.Dock = 'Fill'; $sc.Orientation = 'Vertical'
    $sc.SplitterWidth = 5; $sc.BackColor = $T.Border   # the splitter itself shows the container's colour
    $sc.FixedPanel = $Fixed
    $sc.Panel1.BackColor = $LeftBack; $sc.Panel2.BackColor = $RightBack
    # Minimum sizes are applied in Set-PaneLayout: setting them now (container still at its
    # 150 px default width) makes WinForms throw.
    $sc.Tag = @{ Min1 = $Min1; Min2 = $Min2 }
    $sc.Panel1.Controls.Add($Left); $sc.Panel2.Controls.Add($Right)
    $sc.Add_SplitterMoved({ $args[0].Panel1.Invalidate(); $args[0].Panel2.Invalidate() })
    return $sc
}
$splitItems = New-DarkSplit -Left $itemsList -Right $center -LeftBack $T.Bg -RightBack $T.Bg -Fixed 'Panel1' -Min1 200 -Min2 420
$splitMain = New-DarkSplit -Left $folderPane -Right $splitItems -LeftBack $T.Panel -RightBack $T.Bg -Fixed 'Panel1' -Min1 150 -Min2 640
$splitMain.Panel1.Padding = New-Object System.Windows.Forms.Padding(4, 6, 2, 6)
$splitItems.Panel1.Padding = New-Object System.Windows.Forms.Padding(2, 6, 2, 6)

function Set-PaneLayout {
    # Applies saved (or default) splitter positions; values are clamped to the window size.
    param($Layout)
    $folders = 260; $items = 380
    foreach ($sc in $splitMain, $splitItems) {
        try { $sc.Panel1MinSize = $sc.Tag.Min1; $sc.Panel2MinSize = $sc.Tag.Min2 }
        catch { Write-Log DEBUG "Pane minimum size not applied: $($_.Exception.Message)" }
    }
    if ($Layout) {
        if ($Layout.Folders) { $folders = [int]$Layout.Folders }
        if ($Layout.Items) { $items = [int]$Layout.Items }
    }
    foreach ($pair in @(@($splitMain, $folders), @($splitItems, $items))) {
        $sc = $pair[0]
        $max = $sc.Width - $sc.Panel2MinSize - $sc.SplitterWidth
        try { $sc.SplitterDistance = [Math]::Max($sc.Panel1MinSize, [Math]::Min($pair[1], $max)) } catch { }
    }
}

function Save-PaneLayout {
    $st = Get-AppSettings
    $st.Layout = [pscustomobject]@{
        Folders = $splitMain.SplitterDistance
        Items   = $splitItems.SplitterDistance
    }
    Save-AppSettings $st
}

$form.Controls.Add($splitMain)
$form.Controls.Add($audioBar)     # docked after the status bar, so it sits just above it
$form.Controls.Add($statusBar)
$form.Controls.Add($topLine)
$form.Controls.Add($top)

#endregion

#region ---------- GUI: behaviour ---------------------------------------------------

function Update-ControlTheme {
    # Re-colours a control tree: each colour that belongs to the old palette is replaced by
    # the same key from the new one. Colours outside the palette (e.g. the black video area) stay.
    param($Control, [hashtable] $Map)
    if ($Control.GetType().Name -eq 'WebView2') { return }
    foreach ($prop in 'BackColor', 'ForeColor') {
        try {
            $key = $Map[$Control.$prop.ToArgb()]
            if ($key) { $Control.$prop = $T[$key] }
        } catch { }
    }
    if ($Control -is [System.Windows.Forms.Button]) {
        foreach ($prop in 'MouseOverBackColor', 'MouseDownBackColor') {
            $key = $Map[$Control.FlatAppearance.$prop.ToArgb()]
            if ($key) { $Control.FlatAppearance.$prop = $T[$key] }
        }
    }
    if ($Control -is [System.Windows.Forms.ListView]) {
        foreach ($it in $Control.Items) { $key = $Map[$it.ForeColor.ToArgb()]; if ($key) { $it.ForeColor = $T[$key] } }
        Enable-DarkScrollbars $Control
        $Control.Invalidate()
    }
    if ($Control -is [System.Windows.Forms.TextBox]) { Enable-DarkScrollbars $Control }
    if ($Control -is [System.Windows.Forms.TreeView]) { Enable-DarkScrollbars $Control; $Control.Invalidate() }
    foreach ($child in @($Control.Controls)) { Update-ControlTheme $child $Map }
}

function Set-AppTheme {
    # Mode = System | Light | Dark. Applies the palette to every open window right away.
    param([string] $Mode, [switch] $Force)
    $script:ThemeMode = $Mode
    $eff = Resolve-Theme $Mode
    if ($eff -eq $script:ThemeEffective -and -not $Force) { return }
    $map = @{}
    foreach ($k in @($T.Keys)) { $map[$T[$k].ToArgb()] = $k }
    Set-ThemePalette $eff
    Write-Log INFO "Theme switched to $eff (setting: $Mode)"

    Reset-ListIcons
    try { Update-IconButtons } catch { }   # (2.9.2)

    $script:DarkRenderer = New-ThemeRenderer
    foreach ($m in @($downloadMenu, $filesMenu, $treeMenu) + @($(if ($script:DlUi) { $script:DlUi.Menu }))) {
        if ($script:DarkRenderer) { $m.Renderer = $script:DarkRenderer }
        $m.BackColor = $T.Surface; $m.ForeColor = $T.Text
        foreach ($i in $m.Items) { $i.ForeColor = $T.Text }
    }

    $forms = New-Object System.Collections.Generic.List[object]
    foreach ($f in @([System.Windows.Forms.Application]::OpenForms) + @($form) + @($(if ($script:PlayerWin) { $script:PlayerWin.Form }))) {
        if ($f -and -not $f.IsDisposed -and -not $forms.Contains($f)) { $forms.Add($f) }
    }
    Update-AudioTheme
    foreach ($f in $forms) {
        Update-ControlTheme $f $map
        Enable-DarkTitleBar $f
        # Windows only repaints the title bar colour after a frame change
        if ($f.Visible -and $f.WindowState -eq 'Normal') { $f.Width += 1; $f.Width -= 1 }
        $f.Refresh()
    }
    try { Set-TopBarIcons } catch { }   # (drawn in the theme's colours)
}

function Set-Status([string] $Text) {
    $statusLabel.Text = $Text
    $statusLabel.Refresh()
}

function Invoke-Ui {
    # Runs a UI action with a wait cursor; logs and shows any error instead of crashing.
    param([string] $What, [scriptblock] $Action)
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { & $Action }
    catch {
        Write-LogException $_ $What
        Set-Status "$What failed: $($_.Exception.Message)  (details in Logs)"
    }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function New-CrumbLabel([string] $Text, [System.Drawing.Color] $Color, $Node = $null, [switch] $Bold) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.AutoSize = $true; $l.ForeColor = $Color; $l.UseMnemonic = $false
    $l.Font = if ($Bold) { $script:FontHeader } else { $script:FontBold }
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 7, 0, 0)
    $l.Padding = New-Object System.Windows.Forms.Padding(3, 2, 3, 2)
    if ($Node) {
        $l.Tag = $Node; $l.Cursor = [System.Windows.Forms.Cursors]::Hand
        $l.Add_MouseEnter({ $this.BackColor = $T.Hover })
        $l.Add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::Transparent })
        $l.Add_Click({ Select-CrumbNode $this.Tag })
        $script:CrumbTips.SetToolTip($l, "Go to $($Node.Text)")
    }
    return $l
}

function Select-CrumbNode($Node) {
    # Breadcrumb click: select that folder in the tree, open it and keep the tree in sync
    if (-not $Node -or -not $Node.TreeView) { return }
    Write-Log INFO "UI: breadcrumb -> $($Node.Text)"
    if ($folderTree.SelectedNode -eq $Node) {
        # same folder: just leave the file and show the folder again
        $script:SelectedFile = $null; $itemsList.SelectedItems.Clear(); Show-FolderPreview; Update-Actions; Update-Crumb
        return
    }
    # going back up: close everything below that level, so the tree matches the path
    $goingBack = $false
    for ($n = $folderTree.SelectedNode; $n; $n = $n.Parent) { if ($n -eq $Node) { $goingBack = $true; break } }
    $script:CrumbNav = $true
    $folderTree.BeginUpdate()
    try {
        if ($goingBack) { foreach ($c in @($Node.Nodes)) { if ($c.IsExpanded) { $c.Collapse($false) } } }   # $false: their sub-folders too
        $folderTree.SelectedNode = $Node
        $Node.Expand()
        $Node.EnsureVisible()
    } finally { $folderTree.EndUpdate(); $script:CrumbNav = $false }
}

function Update-Crumb {
    $node = $folderTree.SelectedNode
    # the path is always the selected folder and its parents (going back closes the deeper folders, so they leave the path too)
    $trail = @(); for ($n = $node; $n; $n = $n.Parent) { $trail = @($n) + $trail }
    $crumb.SuspendLayout()
    foreach ($c in @($crumb.Controls)) { $c.Dispose() }
    $crumb.Controls.Clear()
    $sep = [string][char]0x203A
    if (-not $node) { [void]$crumb.Controls.Add((New-CrumbLabel 'NRK Browser' $T.Text -Bold)) }
    $ahead = $false
    for ($i = 0; $i -lt $trail.Count; $i++) {
        $n = $trail[$i]
        if ($i -gt 0) { [void]$crumb.Controls.Add((New-CrumbLabel $sep $T.Muted)) }
        $isCur = ($n -eq $node)
        $color = if ($ahead) { $T.Muted } else { $T.Text }
        $text = ($n.Text -replace '\s{2,}\(.*\)$', '')   # drop "(123)" counts
        [void]$crumb.Controls.Add((New-CrumbLabel $text $color $n -Bold:$isCur))
        if ($isCur) { $ahead = $true }
    }
    if ($script:SelectedFile -and $node) {
        [void]$crumb.Controls.Add((New-CrumbLabel $sep $T.Muted))
        $f = New-CrumbLabel $script:SelectedFile.Title $T.Accent
        $f.AutoSize = $false; $f.Width = 320; $f.Height = 26; $f.AutoEllipsis = $true
        [void]$crumb.Controls.Add($f)
    }
    $crumb.ResumeLayout()
    # too long: hide the first folders and show "..." instead
    $labels = @($crumb.Controls)
    $hidden = 0
    while ($crumb.PreferredSize.Width -gt $crumb.ClientSize.Width -and $hidden -lt ($labels.Count - 3)) {
        $labels[$hidden].Visible = $false; $hidden++
    }
    if ($hidden -gt 0) {
        $dots = New-CrumbLabel ([string][char]0x2026) $T.Muted
        $crumb.Controls.Add($dots); $crumb.Controls.SetChildIndex($dots, 0)
    }
}

function Set-ItemsHeader([string] $Text) {
    $itemsList.Columns[0].Text = $Text
}

# ---- folder tree --------------------------------------------------------------------
# Node tags: @{ Kind = live | group | category | letter | series | season; ... }
# category / letter / series nodes load their children the first time they are opened.

function New-FolderNode {
    param([string] $Text, [hashtable] $Tag, [string] $Icon = 'folder', [switch] $Lazy)
    $n = New-Object System.Windows.Forms.TreeNode($Text)
    $n.Tag = $Tag; $n.ImageKey = $Icon; $n.SelectedImageKey = $Icon
    if ($Lazy) {
        $ph = New-Object System.Windows.Forms.TreeNode('Loading...')
        $ph.Tag = @{ Kind = 'placeholder' }; $ph.ImageKey = 'other'; $ph.SelectedImageKey = 'other'
        [void]$n.Nodes.Add($ph)
    }
    return $n
}

# ---- sort order (Options: SortOrder = desc | asc | nrk) -----------------------------
# Folders and files are shown sorted by title; numbers compare as numbers (Season 10 after Season 9)
# and Norwegian letters sort as in Norwegian (... Z Æ Ø Å). 'nrk' keeps NRK's own order.
$script:NbCompare = [System.Globalization.CultureInfo]::GetCultureInfo('nb-NO').CompareInfo

if (-not ('NrkSort' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
public static class NrkSort {
    static readonly CompareInfo Nb = CultureInfo.GetCultureInfo("nb-NO").CompareInfo;
    static readonly Regex Digits = new Regex(@"\d+");
    // numbers compare as numbers: "Sesong 9" < "Sesong 10"
    public static string Key(string s) { return Digits.Replace((s ?? "").Trim(), m => m.Value.PadLeft(12, '0')); }
    // positions in display order; equal keys keep NRK's order (sign -1 = Z-A)
    public static int[] Order(string[] titles, int[] nrkOrder, int sign) {
        int n = titles.Length; var keys = new string[n]; var idx = new int[n];
        for (int i = 0; i < n; i++) { keys[i] = Key(titles[i]); idx[i] = i; }
        Array.Sort(idx, (a, b) => {
            int c = Nb.Compare(keys[a], keys[b], CompareOptions.IgnoreCase);
            if (c != 0) return sign * c;
            return nrkOrder[a].CompareTo(nrkOrder[b]);
        });
        return idx;
    }
}
'@ -ErrorAction SilentlyContinue
}
$script:SortOrder = 'desc'
function Get-SortOrder { if ($script:SortOrder -in 'desc', 'asc', 'nrk') { return $script:SortOrder } else { return 'desc' } }

function Get-SortKey([string] $Text) {
    return [regex]::Replace(([string]$Text).Trim(), '\d+', { param($m) $m.Value.PadLeft(12, '0') })
}

function Sort-ByTitle {
    # Returns the items in display order. $Title picks the text to sort on; $Order the original position.
    param([object[]] $Items, [scriptblock] $Title, [scriptblock] $Order, [string] $Mode = (Get-SortOrder))
    $list = @($Items)
    if ($list.Count -lt 2) { return ,$list }
    if ($Mode -eq 'nrk') { return ,@($list | Sort-Object -Property @{ Expression = { [int](& $Order $_) } }) }
    $keys = New-Object 'string[]' $list.Count; $ord = New-Object 'int[]' $list.Count
    for ($i = 0; $i -lt $list.Count; $i++) { $keys[$i] = [string](& $Title $list[$i]); $ord[$i] = [int](& $Order $list[$i]) }
    if ('NrkSort' -as [type]) {
        # compiled: a few ms for thousands of items (a PowerShell comparer takes seconds)
        $idx = [NrkSort]::Order($keys, $ord, $(if ($Mode -eq 'desc') { -1 } else { 1 }))
        return ,@(foreach ($i in $idx) { $list[$i] })
    }
    $keyed = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $list.Count; $i++) { $keyed.Add([pscustomobject]@{ K = (Get-SortKey $keys[$i]); O = $ord[$i]; V = $list[$i] }) }
    $cmp = $script:NbCompare; $sign = if ($Mode -eq 'desc') { -1 } else { 1 }
    $arr = $keyed.ToArray()
    # stable: equal titles keep NRK's order
    $byKey = {
        param($a, $b)
        $c = $cmp.Compare($a.K, $b.K, [System.Globalization.CompareOptions]::IgnoreCase)
        if ($c -ne 0) { return $sign * $c }
        return ([int]$a.O).CompareTo([int]$b.O)
    }.GetNewClosure()
    [Array]::Sort($arr, [System.Comparison[object]]$byKey)
    return ,@($arr | ForEach-Object { $_.V })
}

function Set-NodeChildren {
    # Replaces a folder's children, remembering NRK's order and showing them in the chosen sort order.
    param([System.Windows.Forms.TreeNode] $Parent, [object[]] $Children)
    $kids = @($Children | Where-Object { $_ -and -not (Test-KnownEmpty $_) -and -not (Test-Excluded (Get-NodeKey $_)) })
    for ($i = 0; $i -lt $kids.Count; $i++) { if ($kids[$i].Tag -is [hashtable] -and $null -eq $kids[$i].Tag.Order) { $kids[$i].Tag.Order = $i } }
    $sorted = Sort-ByTitle $kids { param($n) if ($n.Tag.Title) { $n.Tag.Title } else { $n.Text } } { param($n) [int]$n.Tag.Order }
    $Parent.Nodes.Clear()
    if ($sorted.Count -gt 0) { $Parent.Nodes.AddRange([System.Windows.Forms.TreeNode[]]$sorted) }
}

function Update-TreeSort {
    # Re-sorts every loaded folder after the sort order changes (the top-level groups stay as they are).
    $sel = $folderTree.SelectedNode
    $folderTree.BeginUpdate()
    $script:SuppressSelect = $true   # re-adding nodes moves the selection about: open nothing meanwhile
    try {
        $stack = New-Object System.Collections.Stack
        foreach ($n in $folderTree.Nodes) { foreach ($c in $n.Nodes) { $stack.Push($c) } }
        foreach ($g in @($script:CatsNode, $script:LettersNode, $script:RadioCatsNode, $script:RadioLettersNode)) { if ($g) { $stack.Push($g) } }
        $seen = @{}
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            if ($seen.ContainsKey($n.GetHashCode())) { continue }; $seen[$n.GetHashCode()] = $true
            $kids = @($n.Nodes | ForEach-Object { $_ })
            if ($kids.Count -gt 1 -and -not ($kids | Where-Object { $_.Tag.Kind -eq 'placeholder' })) {
                $wasOpen = $n.IsExpanded
                Set-NodeChildren $n $kids
                if ($wasOpen) { $n.Expand() }
            }
            foreach ($c in $kids) { $stack.Push($c) }
        }
        if ($sel -and $sel.TreeView) { $folderTree.SelectedNode = $sel; $sel.EnsureVisible() }
    } finally { $folderTree.EndUpdate(); $script:SuppressSelect = $false }
    Show-Files
}

function Initialize-Tree {
    $folderTree.BeginUpdate()
    $folderTree.Nodes.Clear()
    $script:SearchNode = $null
    Read-KnownEmpty
    $script:RecentNode = New-FolderNode 'Recently played' @{ Kind = 'recent'; Title = 'Recently played' } 'other'
    $script:ContinueNode = New-FolderNode 'Continue watching' @{ Kind = 'continue'; Title = 'Continue watching' } 'episode'
    $script:WatchLaterNode = New-FolderNode ('Watch later   ({0})' -f @(Get-WatchLaterRecords).Count) @{ Kind = 'watchlater'; Title = 'Watch later' } 'program'
    $script:FavNode = New-FolderNode 'Favourites' @{ Kind = 'favourites'; Title = 'Favourites' } 'star'
    $script:NewNode = New-FolderNode 'New this week' @{ Kind = 'newweek'; Title = 'New this week' } 'new'
    $script:LastNode = New-FolderNode 'Last chance' @{ Kind = 'expiring'; Title = 'Last chance' } 'clock'
    # LIVE: TV channels and radio channels
    # live channels: two folders of their own (no "LIVE" folder around them)
    $script:TvLiveNode = New-FolderNode 'LIVE TV' @{ Kind = 'live'; Title = 'LIVE TV' } 'live'
    $script:RadioLiveNode = New-FolderNode 'LIVE Radio' @{ Kind = 'radiolive'; Title = 'LIVE Radio' } 'live'
    # TV Archive: the tv.nrk.no categories and the A-Å index
    $script:TvNode = New-FolderNode 'TV Archive' @{ Kind = 'group'; Title = 'TV Archive' }
    $script:CatsNode = New-FolderNode 'Categories' @{ Kind = 'group'; Title = 'Categories' }
    $script:LettersNode = New-FolderNode ('A {0} Å' -f [char]0x2013) @{ Kind = 'group'; Title = 'A - Å' }
    $child = Test-ChildMode   # (child mode: no A-Å, no New this week / Last chance, only children's categories)
    if ($child) { [void]$script:TvNode.Nodes.Add($script:CatsNode) } else { [void]$script:TvNode.Nodes.AddRange(@($script:CatsNode, $script:LettersNode)) }
    # Radio: radio.nrk.no live channels, recordings and podcasts (played in the audio bar)
    $script:RadioNode = New-FolderNode 'Radio Archive' @{ Kind = 'group'; Title = 'Radio Archive' }
    $script:RadioLettersNode = New-FolderNode ('A {0} Å' -f [char]0x2013) @{ Kind = 'group'; Title = 'Radio A - Å' }
    $script:RadioCatsNode = New-FolderNode 'Categories' @{ Kind = 'group'; Title = 'Radio categories' }
    if ($child) { [void]$script:RadioNode.Nodes.Add($script:RadioCatsNode) } else { [void]$script:RadioNode.Nodes.AddRange(@($script:RadioCatsNode, $script:RadioLettersNode)) }
    if ($child) { [void]$folderTree.Nodes.AddRange(@($script:RecentNode, $script:ContinueNode, $script:FavNode, $script:TvLiveNode, $script:RadioLiveNode, $script:TvNode, $script:RadioNode)) }
    else { [void]$folderTree.Nodes.AddRange(@($script:ContinueNode, $script:RecentNode, $script:WatchLaterNode, $script:FavNode, $script:NewNode, $script:LastNode, $script:TvLiveNode, $script:RadioLiveNode, $script:TvNode, $script:RadioNode)) }
    $folderTree.EndUpdate()
    $script:Favs = $null   # (read again: a restore may have changed it)
    Update-FavouritesNode
    $script:FavNode.Expand()

    Invoke-Ui 'Loading categories' {
        $cats = @(Get-Cached 'categories' { Get-NrkCategories })
        if ($child) { $cats = @($cats | Where-Object { Test-ChildFolder $_ }) }
        Set-NodeChildren $script:CatsNode @(foreach ($c in $cats) { New-FolderNode $c.Title @{ Kind = 'category'; Id = $c.Id; Title = $c.Title } -Lazy })
        if ($cats.Count -eq 0) { [void]$script:CatsNode.Nodes.Add((New-FolderNode '(not loaded - see Logs)' @{ Kind = 'placeholder' } 'other')) }
    }
    if (-not $child) { Invoke-Ui 'Loading A-Å index' {
        $letters = @(Get-Cached 'letters' { Get-NrkLetters })
        Set-NodeChildren $script:LettersNode @(foreach ($l in $letters) {
            $text = if ($null -ne $l.Count) { '{0}   ({1:N0})' -f $l.Title, $l.Count } else { $l.Title }
            New-FolderNode $text @{ Kind = 'letter'; Id = $l.Id; Title = $l.Title } -Lazy
        })
        if ($letters.Count -eq 0) { [void]$script:LettersNode.Nodes.Add((New-FolderNode '(not loaded - see Logs)' @{ Kind = 'placeholder' } 'other')) }
    } }
    Invoke-Ui 'Loading radio categories' {
        $rcats = @(Get-Cached 'radio:pages' { Get-NrkRadioCategories })
        if ($child) { $rcats = @($rcats | Where-Object { Test-ChildFolder $_ }) }
        Set-NodeChildren $script:RadioCatsNode @(foreach ($c in $rcats) { New-FolderNode $c.Title @{ Kind = 'radiocategory'; Id = $c.Id; Title = $c.Title } -Lazy })
        if ($rcats.Count -eq 0) { [void]$script:RadioCatsNode.Nodes.Add((New-FolderNode '(not loaded - see Logs)' @{ Kind = 'placeholder' } 'other')) }
    }
    if (-not $child) { Invoke-Ui 'Loading radio A-Å index' {
        $rl = @(Get-Cached 'radio:letters' { Get-NrkRadioLetters })
        Set-NodeChildren $script:RadioLettersNode @(foreach ($l in $rl) {
            $text = if ($null -ne $l.Count) { '{0}   ({1:N0})' -f $l.Title, $l.Count } else { $l.Title }
            New-FolderNode $text @{ Kind = 'radioletter'; Id = $l.Id; Title = "Radio $($l.Title)" } -Lazy
        })
        if ($rl.Count -eq 0) { [void]$script:RadioLettersNode.Nodes.Add((New-FolderNode '(not loaded - see Logs)' @{ Kind = 'placeholder' } 'other')) }
    } }
    $script:TvNode.Expand(); $script:RadioNode.Expand()
    Set-Status ('Loaded {0} TV categories, {1} letters and {2} radio categories from psapi.nrk.no' -f $script:CatsNode.Nodes.Count, $script:LettersNode.Nodes.Count, $script:RadioCatsNode.Nodes.Count)
    try { Request-WarmPrefetch } catch { Write-Log DEBUG "Prefetch: $($_.Exception.Message)" }
}

function Expand-FolderNode {
    # Fills a lazy node (category, letter or series) the first time it is needed. Returns $true when loaded.
    param([System.Windows.Forms.TreeNode] $Node)
    $tag = $Node.Tag
    # loaded a while ago and closed: load it again (the saved data may have been refreshed since)
    if ($tag.Loaded -and $tag.LoadedAt -and -not $Node.IsExpanded -and ((Get-Date) - $tag.LoadedAt).TotalMinutes -gt $script:MemoryTtlMin) { $tag.Loaded = $false }
    if ($tag.Loaded) { return $true }
    # (a hashtable, because the Invoke-Ui script block runs in a child scope)
    $result = @{ Ok = $false }
    Invoke-Ui "Loading $($tag.Kind) $($tag.Title)" {
        $children = @()
        switch ($tag.Kind) {
            { $_ -in 'category', 'letter' } {
                $items = if ($tag.Kind -eq 'category') { @(Get-Cached "cat:$($tag.Id)" { Get-NrkCategoryItems -PageId $tag.Id }) }
                         else { @(Get-Cached "letter:$($tag.Id)" { Get-NrkLetterItems -Letter $tag.Id }) }
                $tag.Items = $items
                foreach ($s in $items | Where-Object Type -eq 'series') {
                    $children += New-FolderNode $s.Title @{ Kind = 'series'; Title = $s.Title; Item = $s } -Lazy
                }
            }
            { $_ -in 'radiocategory', 'radioletter' } {
                $items = if ($tag.Kind -eq 'radioletter') { @(Get-Cached "rletter:$($tag.Id)" { Get-NrkRadioLetterItems -Letter $tag.Id }) }
                         else { @(Get-Cached "rcat:$($tag.Id)" { Get-NrkRadioPageItems -PageId $tag.Id }) }
                $tag.Items = $items
                foreach ($s in $items | Where-Object Type -eq 'radioseries') {
                    $children += New-FolderNode $s.Title @{ Kind = 'radioseries'; Title = $s.Title; Item = $s } -Lazy
                }
            }
            'radioseries' {
                $info = @(Get-Cached "rseries:$($tag.Item.Kind):$($tag.Item.Id)" { Get-NrkRadioSeriesInfo -Kind $tag.Item.Kind -Id $tag.Item.Id })[0]
                $tag.Info = $info
                foreach ($s in $info.Seasons) {
                    $children += New-FolderNode $s.Title @{ Kind = 'radioseason'; Title = $s.Title; Season = $s; Item = $tag.Item; Info = $info }
                }
            }
            'series' {
                $info = Get-Cached "series:$($tag.Item.Id)" { Get-NrkSeriesInfo -SeriesId $tag.Item.Id }
                $info = @($info)[0]
                $tag.Info = $info
                foreach ($s in $info.Seasons) {
                    $children += New-FolderNode $s.Title @{ Kind = 'season'; Title = $s.Title; Season = $s.Name; Item = $tag.Item; Info = $info }
                }
            }
        }
        $folderTree.BeginUpdate()
        Set-NodeChildren $Node $children
        $folderTree.EndUpdate()
        $tag.Loaded = $true; $tag.LoadedAt = Get-Date
        $result.Ok = $true
        # loaded fine, but nothing in it: hide it
        $hasFiles = @($tag.Items | Where-Object { $_.Type -in 'program', 'audio' }).Count -gt 0
        if ($Node.Nodes.Count -eq 0 -and -not $hasFiles) { $result.Empty = $true }
    }
    if ($result.Empty) { Hide-EmptyNode $Node }
    if ($result.Ok) { try { Request-FolderPrefetch $Node } catch { Write-Log DEBUG "Prefetch: $($_.Exception.Message)" } }
    if (-not $result.Ok) {
        $Node.Nodes.Clear()
        [void]$Node.Nodes.Add((New-FolderNode '(failed - see Logs)' @{ Kind = 'placeholder' } 'other'))
    }
    return $result.Ok
}

# ---- hidden items (your own exclusion list) ------------------------------------------------
# Anything you hide (right-click > "Hide and don't index") disappears from the folders, the
# file list and search, and the indexer skips it. The list is yours only: excluded.json in the
# app data folder. Options > Hidden items... shows it, and puts things back.
$script:ExcludedFile = Join-Path $script:AppDataDir 'excluded.json'
$script:Excluded = $null          # key -> record (loaded on first use)
$script:ExcludedVer = 0

function Get-ExcludedMap {
    if ($null -ne $script:Excluded) { return $script:Excluded }
    $m = @{}
    $j = Read-JsonFile $script:ExcludedFile
    if ($j) { foreach ($r in @($j.Items | Where-Object { $_ -and $_.Key })) { $m[[string]$r.Key] = $r } }
    $script:Excluded = $m
    return $m
}

function Get-FileKey($File) { return 'file|{0}|{1}' -f $File.Type, $File.Id }

function Test-Excluded([string] $Key) { return [bool]($Key -and (Get-ExcludedMap).ContainsKey($Key)) }

function Save-ExcludedMap {
    $items = @((Get-ExcludedMap).Values | Sort-Object { [string]$_.Added } -Descending)
    Write-JsonFile $script:ExcludedFile ([ordered]@{ Items = $items })
    $script:ExcludedVer++
}

function Get-ExcludedLabel([string] $Key) {
    $map = [ordered]@{
        '^file\|program\|' = 'Programme'; '^file\|episode\|' = 'Episode'; '^file\|audio\|' = 'Radio episode'; '^file\|(live|radiolive)\|' = 'Live channel'
        '^series\|' = 'TV series'; '^season\|' = 'TV season'; '^radioseries\|podcast\|' = 'Podcast'; '^radioseries\|' = 'Radio series'
        '^radioseason\|' = 'Radio season'; '^(category|radiocategory)\|' = 'Category'; '^(letter|radioletter)\|' = 'Letter'
    }
    foreach ($k in $map.Keys) { if ($Key -match $k) { return $map[$k] } }   # first match wins
    return 'Item'
}

function Add-Excluded {
    # hides files and/or folders (nodes) and remembers them
    param([object[]] $Files = @(), [object[]] $Nodes = @())
    $m = Get-ExcludedMap
    $names = @()
    foreach ($f in $Files) {
        if (-not $f -or -not $f.Id -or $f.Type -eq 'more') { continue }
        $k = Get-FileKey $f
        $m[$k] = [pscustomobject]@{ Key = $k; Title = [string]$(if ($f.Type -eq 'episode' -and $f.SeriesItem) { '{0}  ·  {1}' -f $f.SeriesItem.Title, $f.Title } elseif ($f.SeriesTitle) { '{0}  ·  {1}' -f $f.SeriesTitle, $f.Title } else { $f.Title }); Added = (Get-Date).ToString('o') }
        $names += $f.Title
    }
    foreach ($n in $Nodes) {
        if (-not $n -or -not $n.Tag -or $n.Tag.Kind -in 'group', 'live', 'radiolive', 'search', 'recent', 'placeholder', 'favourites', 'newweek', 'expiring', 'continue', 'watchlater') { continue }
        $k = Get-NodeKey $n
        $title = [string]$n.Tag.Title
        if ($n.Tag.Kind -in 'season', 'radioseason' -and $n.Parent) { $title = '{0}  ·  {1}' -f $n.Parent.Tag.Title, $title }
        $m[$k] = [pscustomobject]@{ Key = $k; Title = $title; Added = (Get-Date).ToString('o') }
        $names += $n.Tag.Title
    }
    if (-not $names.Count) { return }
    Save-ExcludedMap
    Write-Log INFO ("Hidden (not shown or indexed): {0}" -f ($names -join ', '))
    # out of sight now
    foreach ($n in $Nodes) {
        if (-not $n -or -not $n.TreeView) { continue }
        for ($s = $folderTree.SelectedNode; $s; $s = $s.Parent) { if ($s -eq $n) { if ($n.Parent) { $folderTree.SelectedNode = $n.Parent }; break } }
        if ($n.TreeView) { $n.Remove() }
    }
    if ($Files.Count) { $script:SelectedFile = $null; Show-Files; Show-FolderPreview; Update-Actions }
    Set-Status ("Hidden: {0}  ·  Options > Hidden items... puts it back" -f (($names | Select-Object -First 3) -join ', ') + $(if ($names.Count -gt 3) { " and $($names.Count - 3) more" } else { '' }))
}

function Show-ExcludedWindow {
    param($Owner = $form)
    Write-Log INFO 'UI: opened Hidden items window'
    $w = New-Object System.Windows.Forms.Form
    Set-AppIcon $w
    $w.Text = 'Hidden items - NRK Browser'
    $w.ClientSize = New-Object System.Drawing.Size(720, 480)
    $w.MinimumSize = New-Object System.Drawing.Size(520, 320)
    $w.StartPosition = 'CenterParent'
    $w.Font = $script:FontUi; $w.BackColor = $T.Bg; $w.ForeColor = $T.Text
    $info = New-Object System.Windows.Forms.Label
    $info.Text = "Things you hid. They are not shown in folders, lists or search, and the indexer skips them. Remove them from this list to see them again (after Reload)."
    $info.Dock = 'Top'; $info.Height = 46; $info.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 0); $info.ForeColor = $T.Muted
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $true; $lv.HideSelection = $false; $lv.Dock = 'Fill'
    $lv.BorderStyle = 'None'; $lv.BackColor = $T.Panel; $lv.ForeColor = $T.Text
    [void]$lv.Columns.Add('Title', 400); [void]$lv.Columns.Add('Type', 130); [void]$lv.Columns.Add('Hidden', 140)
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'; $bar.Height = 52; $bar.Padding = New-Object System.Windows.Forms.Padding(12, 9, 12, 6); $bar.BackColor = $T.Bg
    $bRemove = New-FlatButton 'Show again' 130 -Primary
    $bAll = New-FlatButton 'Show all again' 150
    $bReload = New-FlatButton 'Reload folders' 140
    $bClose = New-FlatButton 'Close' 100
    $count = New-Object System.Windows.Forms.Label; $count.AutoSize = $false; $count.Width = 160; $count.Height = 34; $count.TextAlign = 'MiddleLeft'; $count.ForeColor = $T.Muted
    $bar.Controls.AddRange(@($bRemove, $bAll, $bReload, $bClose, $count))
    $w.Controls.Add($lv); $w.Controls.Add($bar); $w.Controls.Add($info)
    $script:ExclUi = @{ Form = $w; List = $lv; Count = $count; Changed = $false }
    $script:ExclFill = {
        $u = $script:ExclUi
        $u.List.BeginUpdate(); $u.List.Items.Clear()
        foreach ($r in @((Get-ExcludedMap).Values | Sort-Object { [string]$_.Added } -Descending)) {
            $row = New-Object System.Windows.Forms.ListViewItem([string]$r.Title)
            [void]$row.SubItems.Add((Get-ExcludedLabel $r.Key))
            [void]$row.SubItems.Add($(try { ([datetime]$r.Added).ToString('dd.MM.yyyy HH:mm') } catch { '' }))
            $row.Tag = $r.Key; $row.ToolTipText = $r.Key
            [void]$u.List.Items.Add($row)
        }
        $u.List.EndUpdate()
        $u.Count.Text = '{0} hidden' -f $u.List.Items.Count
    }
    $remove = {
        param([string[]] $Keys)
        if (-not $Keys) { return }
        $m = Get-ExcludedMap
        foreach ($k in $Keys) { [void]$m.Remove($k) }
        Save-ExcludedMap
        Write-Log INFO ("Shown again: {0} item(s)" -f $Keys.Count)
        $script:ExclUi.Changed = $true
        & $script:ExclFill
    }
    $script:ExclRemove = $remove
    $bRemove.Add_Click({ & $script:ExclRemove @($script:ExclUi.List.SelectedItems | ForEach-Object { [string]$_.Tag }) })
    $bAll.Add_Click({
        if ($script:ExclUi.List.Items.Count -eq 0) { return }
        if ([System.Windows.Forms.MessageBox]::Show($script:ExclUi.Form, 'Show everything on the list again?', 'Hidden items', 'YesNo', 'Question') -eq 'Yes') { & $script:ExclRemove @($script:ExclUi.List.Items | ForEach-Object { [string]$_.Tag }) }
    })
    $bReload.Add_Click({ $script:ExclUi.Changed = $false; $btnReload.PerformClick() })
    $bClose.Add_Click({ $script:ExclUi.Form.Close() })
    $lv.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Delete') { & $script:ExclRemove @($script:ExclUi.List.SelectedItems | ForEach-Object { [string]$_.Tag }); $e.Handled = $true } })
    & $script:ExclFill
    Set-DarkTheme $w
    $lv.BackColor = $T.Panel
    Enable-DarkTitleBar $w
    [void]$w.ShowDialog($Owner)
    $changed = $script:ExclUi.Changed
    $script:ExclUi = $null; $w.Dispose()
    if ($changed) {
        Show-Files
        if ([System.Windows.Forms.MessageBox]::Show($form, 'Reload the folders now, so the items you put back show up?', 'Hidden items', 'YesNo', 'Question') -eq 'Yes') { $btnReload.PerformClick() }
    }
}

# ---- search everything ------------------------------------------------------------------
# Enter in the search box looks through the indexer's list of every series, programme and
# episode (indexer\search.tsv). The matching series appear as folders and the programmes and
# episodes as files in a "Search" folder at the top of the tree. The search itself runs in a
# small compiled helper, so a list of 100 000+ titles answers instantly.
if (-not ('NrkSearch' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
public static class NrkSearch {
    static string[][] rows = new string[0][];
    static string[] keys = new string[0], titles = new string[0];
    static string file = null; static DateTime stamp = DateTime.MinValue;
    public static int Count { get { return rows.Length; } }
    public static string Norm(string s) {
        if (string.IsNullOrEmpty(s)) return "";
        var sb = new StringBuilder(s.Length);
        foreach (char ch in s.ToLowerInvariant()) {
            switch (ch) {
                case 'é': case 'è': case 'ê': case 'ë': sb.Append('e'); break;
                case 'á': case 'à': case 'â': sb.Append('a'); break;
                case 'ó': case 'ò': case 'ô': sb.Append('o'); break;
                case 'ü': case 'ú': sb.Append('u'); break;
                case 'ö': sb.Append('ø'); break;
                case 'ä': sb.Append('æ'); break;
                case 'í': case 'ì': sb.Append('i'); break;
                default: sb.Append(char.IsLetterOrDigit(ch) ? ch : ' '); break;
            }
        }
        return " " + string.Join(" ", sb.ToString().Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries)) + " ";
    }
    // (re)reads the list when the file changed; returns the number of entries
    public static int Load(string path) {
        if (!File.Exists(path)) { rows = new string[0][]; keys = new string[0]; titles = new string[0]; file = null; return 0; }
        var t = File.GetLastWriteTimeUtc(path);
        if (path == file && t == stamp) return rows.Length;
        var r = new List<string[]>(); var k = new List<string>(); var ti = new List<string>();
        foreach (var line in File.ReadLines(path, Encoding.UTF8)) {
            if (line.Length == 0 || line[0] == '#') continue;
            var f = line.Split('\t');
            if (f.Length < 12) Array.Resize(ref f, 12);   // (lists from before 2.7: no from/to/year)
            for (int i = 0; i < 12; i++) if (f[i] == null) f[i] = "";
            r.Add(f); ti.Add(Norm(f[2])); k.Add(Norm(f[2]) + "|" + Norm(f[5]) + "|" + Norm(f[3]));
        }
        rows = r.ToArray(); keys = k.ToArray(); titles = ti.ToArray(); file = path; stamp = t;
        return rows.Length;
    }
    public static string[] Row(int i) { return rows[i]; }
    public static int[] Find(string query, int max) { return Find(query, max, null, false, "", 0, 0); }
    // year of a row: the production year, else the year it came on NRK
    static int YearOf(string[] r) {
        int y; if (int.TryParse(r[11], out y)) return y;
        if (r[9].Length >= 4 && int.TryParse(r[9].Substring(0, 4), out y)) return y;
        return 0;
    }
    // can be watched now: started (or no start given) and not ended
    static bool OpenNow(string[] r, string now) {
        if (r[9].Length > 0 && string.CompareOrdinal(r[9], now) > 0) return false;
        if (r[10].Length > 0 && string.CompareOrdinal(r[10], now) < 0) return false;
        return true;
    }
    // best matches first: every word must appear; titles that start with the query rank highest.
    // types: allowed row types separated by commas (null = all); yMin/yMax 0 = any year
    public static int[] Find(string query, int max, string types, bool availNow, string now, int yMin, int yMax) {
        string q = Norm(query).Trim();
        if (q.Length == 0) return new int[0];
        string[] terms = q.Split(' ');
        string typeList = string.IsNullOrEmpty(types) ? null : "," + types + ",";   // (PowerShell passes $null as "")
        var hits = new List<KeyValuePair<int, int>>();
        for (int i = 0; i < rows.Length; i++) {
            if (typeList != null && typeList.IndexOf("," + rows[i][0] + ",", StringComparison.Ordinal) < 0) continue;
            bool isSeries = rows[i][0] == "tvseries" || rows[i][0] == "radioseries";
            if (availNow && !isSeries && !OpenNow(rows[i], now)) continue;
            if ((yMin > 0 || yMax > 0) && !isSeries) {
                int y = YearOf(rows[i]);
                if (y == 0 || (yMin > 0 && y < yMin) || (yMax > 0 && y > yMax)) continue;
            }
            string key = keys[i]; bool all = true;
            foreach (var w in terms) { if (key.IndexOf(w, StringComparison.Ordinal) < 0) { all = false; break; } }
            if (!all) continue;
            string t = titles[i]; int score;
            if (t == " " + q + " ") score = 1000;
            else if (t.StartsWith(" " + q)) score = 600;
            else if (t.Contains(" " + q)) score = 400;
            else if (t.Contains(q)) score = 300;
            else {
                bool inTitle = true; foreach (var w in terms) if (t.IndexOf(w, StringComparison.Ordinal) < 0) { inTitle = false; break; }
                score = inTitle ? 250 : 100;
            }
            // whole words beat parts of words ("42" should not prefer "1042")
            bool starts = true, whole = true;
            foreach (var w in terms) {
                if (key.IndexOf(" " + w, StringComparison.Ordinal) < 0) starts = false;
                if (key.IndexOf(" " + w + " ", StringComparison.Ordinal) < 0) whole = false;
            }
            if (starts) score += 40; if (whole) score += 30;
            string type = rows[i][0];
            if (type == "tvseries" || type == "radioseries") score += 60; else if (type == "tvprogram") score += 50;
            hits.Add(new KeyValuePair<int, int>(i, score));
        }
        hits.Sort((a, b) => b.Value != a.Value ? b.Value.CompareTo(a.Value) : string.CompareOrdinal(titles[a.Key], titles[b.Key]));
        int n = Math.Min(max, hits.Count); var res = new int[n];
        for (int i = 0; i < n; i++) res[i] = hits[i].Key;
        return res;
    }
    // mode 0: came on NRK between limit and now (newest first); mode 1: ends between now and limit (soonest first)
    public static int[] Dated(int mode, string now, string limit, int max) {
        var hits = new List<int>();
        for (int i = 0; i < rows.Length; i++) {
            string t = rows[i][0];
            if (t != "tvepisode" && t != "tvprogram" && t != "radioepisode") continue;
            string from = rows[i][9], to = rows[i][10];
            if (mode == 0) { if (from.Length == 0 || string.CompareOrdinal(from, limit) < 0 || string.CompareOrdinal(from, now) > 0) continue; if (to.Length > 0 && string.CompareOrdinal(to, now) < 0) continue; }
            else { if (to.Length == 0 || string.CompareOrdinal(to, now) < 0 || string.CompareOrdinal(to, limit) > 0) continue; if (from.Length > 0 && string.CompareOrdinal(from, now) > 0) continue; }
            hits.Add(i);
        }
        if (mode == 0) hits.Sort((a, b) => string.CompareOrdinal(rows[b][9], rows[a][9]));
        else hits.Sort((a, b) => string.CompareOrdinal(rows[a][10], rows[b][10]));
        if (hits.Count > max) hits.RemoveRange(max, hits.Count - max);
        return hits.ToArray();
    }
}
'@ -ErrorAction SilentlyContinue
}
$script:SearchNode = $null
$script:SearchMax = 500

$script:SearchYears = [ordered]@{
    any = @{ Label = 'Any year'; Min = 0; Max = 0 }; '2020' = @{ Label = '2020 and later'; Min = 2020; Max = 0 }
    '2010' = @{ Label = '2010 - 2019'; Min = 2010; Max = 2019 }; '2000' = @{ Label = '2000 - 2009'; Min = 2000; Max = 2009 }
    '1990' = @{ Label = '1990 - 1999'; Min = 1990; Max = 1999 }; old = @{ Label = 'Before 1990'; Min = 0; Max = 1989 }
}
function Get-SearchFilter {
    # the filters from the button next to the search box, for the compiled search
    $st = Get-AppSettings
    $types = New-Object System.Collections.Generic.List[string]
    if ($st.SearchTv) {
        if ($st.SearchSeries) { $types.Add('tvseries') }; if ($st.SearchPrograms) { $types.Add('tvprogram') }; if ($st.SearchEpisodes) { $types.Add('tvepisode') }
    }
    if ($st.SearchRadio) {
        if ($st.SearchSeries) { $types.Add('radioseries') }; if ($st.SearchEpisodes -or $st.SearchPrograms) { $types.Add('radioepisode') }
    }
    $y = $script:SearchYears[[string]$st.SearchYear]; if (-not $y) { $y = $script:SearchYears['any'] }
    $note = @()
    if (-not $st.SearchTv) { $note += 'radio only' } elseif (-not $st.SearchRadio) { $note += 'TV only' }
    $kinds = @(@('series', $st.SearchSeries), @('programmes', $st.SearchPrograms), @('episodes', $st.SearchEpisodes) | Where-Object { $_[1] } | ForEach-Object { $_[0] })
    if ($kinds.Count -lt 3) { $note += ($kinds -join ' + ') }
    if ($st.SearchAvailable) { $note += 'available now' }
    if ($y.Min -or $y.Max) { $note += $y.Label }
    if ($types.Count -eq 0) { $types.Add('none') }   # (nothing ticked: nothing matches)
    return @{ Types = $(if ($types.Count -eq 5) { '' } else { $types -join ',' }); Available = [bool]$st.SearchAvailable; YearMin = [int]$y.Min; YearMax = [int]$y.Max; Note = ($note -join ', ') }
}

function Invoke-SearchAll([string] $Query) {
    $q = $Query.Trim()
    if (Test-ChildMode) { Set-Status 'Search everything is off in child mode (the box still filters this folder)'; return }
    if ($q.Length -lt 2) { Set-Status 'Type at least 2 letters, then press Enter to search everything'; return }
    if (-not ('NrkSearch' -as [type])) { Set-Status 'Search is not available (the search helper did not compile - see Logs)'; return }
    if (-not (Test-Path -LiteralPath $script:SearchFile)) {
        $st = Get-IndexerState
        $msg = if ($st.Running) { "The indexer is building the list that search uses; it is ready when the first full run finishes.`n`nOpen the Indexer to see how far it is?" }
               else { "Search everything looks through the list the indexer builds of every TV and radio series, programme and episode. It isn't there yet.`n`nStart the indexer now? A first full run takes a few hours in the background; browsing works as usual meanwhile." }
        if ([System.Windows.Forms.MessageBox]::Show($form, $msg, 'Search everything', 'YesNo', 'Question') -eq 'Yes') { if (-not $st.Running) { Start-Indexer }; Open-IndexerWindow }
        return
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $n = [NrkSearch]::Load($script:SearchFile)
    $flt = Get-SearchFilter
    $hits = [NrkSearch]::Find($q, $script:SearchMax, $flt.Types, $flt.Available, (Get-Date).ToString('s'), $flt.YearMin, $flt.YearMax)
    $folders = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]
    $seriesItems = @{}
    foreach ($i in $hits) {
        $r = ConvertFrom-SearchRow ([NrkSearch]::Row($i)) $seriesItems   # (nothing you hid)
        if (-not $r) { continue }
        if ($r.Folder) { $folders.Add($r.Folder) } elseif ($r.File) { $files.Add($r.File) }
    }
    Write-Log INFO ("Search '{0}': {1} of {2:N0} entries match, {3} ms" -f $q, $hits.Count, $n, $sw.ElapsedMilliseconds)
    $folderTree.BeginUpdate()
    try {
        if (-not $script:SearchNode -or -not $script:SearchNode.TreeView) {
            $script:SearchNode = New-FolderNode 'Search' @{ Kind = 'search'; Title = 'Search' } 'other'
            $folderTree.Nodes.Insert(0, $script:SearchNode)
        }
        $sn = $script:SearchNode
        $sn.Text = 'Search: {0}   ({1:N0})' -f $q, $hits.Count
        $sn.Tag = @{ Kind = 'search'; Title = "Search: $q"; Query = $q; Items = @($files); Loaded = $true }
        $sn.Nodes.Clear()
        if ($folders.Count) { $sn.Nodes.AddRange([System.Windows.Forms.TreeNode[]]$folders.ToArray()) }   # best matches first
    } finally { $folderTree.EndUpdate() }
    $search.Text = ''          # (the box filters the list it shows; the results are already the match)
    if ($folderTree.SelectedNode -eq $script:SearchNode) { Open-Folder $script:SearchNode } else { $folderTree.SelectedNode = $script:SearchNode }
    $script:SearchNode.Expand()
    $more = if ($hits.Count -ge $script:SearchMax) { "  ·  showing the best $($script:SearchMax): add a word to narrow it down" } else { '' }
    Set-Status ("'{0}': {1} series (folders), {2} programmes and episodes (files){3}{4}" -f $q, $folders.Count, $files.Count, $more, $(if ($flt.Note) { "  ·  filters: $($flt.Note)" } else { '' }))
}

# ---- search filters (the button next to the search box) -------------------------------------
function Show-SearchFilterMenu {
    if (-not $script:FilterMenu) {
        $m = New-ThemedMenu
        # stays open while you tick things; the search runs again when it closes
        $m.Add_Closing({ param($s, $e) if ($e.CloseReason -eq [System.Windows.Forms.ToolStripDropDownCloseReason]::ItemClicked) { $e.Cancel = $true } })
        $m.Add_Closed({ Update-SearchFilterButton; if ($script:FilterChanged -and $script:SearchNode -and $script:SearchNode.TreeView -and $script:SearchNode.Tag.Query) { $script:FilterChanged = $false; Invoke-SearchAll $script:SearchNode.Tag.Query } })
        $script:FilterMenu = $m
    }
    $m = $script:FilterMenu
    $m.Items.Clear()
    $st = Get-AppSettings
    $head = New-ThemedMenuItem 'Search everything finds'; $head.Enabled = $false; [void]$m.Items.Add($head)
    $flag = {
        param([string] $Text, [string] $Key)
        $i = New-ThemedMenuItem $Text; $i.Checked = [bool]$st.$Key; $i.Tag = $Key
        $i.Add_Click({ $s = Get-AppSettings; $k = [string]$this.Tag; $s.$k = -not [bool]$s.$k; Save-AppSettings $s; $this.Checked = [bool]$s.$k; $script:FilterChanged = $true })
        [void]$m.Items.Add($i)
    }
    & $flag '   TV' 'SearchTv'; & $flag '   Radio' 'SearchRadio'
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    & $flag '   Series and podcasts' 'SearchSeries'; & $flag '   Programmes' 'SearchPrograms'; & $flag '   Episodes' 'SearchEpisodes'
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    & $flag '   Only what can be watched now' 'SearchAvailable'
    $year = New-ThemedMenuItem '   Year'
    foreach ($k in $script:SearchYears.Keys) {
        $y = New-ThemedMenuItem $script:SearchYears[$k].Label; $y.Tag = $k; $y.Checked = ([string]$st.SearchYear -eq $k)
        $y.Add_Click({
            $s = Get-AppSettings; $s.SearchYear = [string]$this.Tag; Save-AppSettings $s; $script:FilterChanged = $true
            foreach ($o in $this.Owner.Items) { $o.Checked = ($o -eq $this) }
        })
        [void]$year.DropDownItems.Add($y)
    }
    if ($script:DarkRenderer) { $year.DropDown.Renderer = $script:DarkRenderer }
    $year.DropDown.BackColor = $T.Surface
    [void]$m.Items.Add($year)
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $reset = New-ThemedMenuItem 'Show everything (no filters)'
    $reset.Add_Click({
        $s = Get-AppSettings
        foreach ($k in 'SearchTv', 'SearchRadio', 'SearchSeries', 'SearchPrograms', 'SearchEpisodes') { $s.$k = $true }
        $s.SearchAvailable = $false; $s.SearchYear = 'any'; Save-AppSettings $s
        $script:FilterChanged = $true; $script:FilterMenu.Close([System.Windows.Forms.ToolStripDropDownCloseReason]::CloseCalled)
    })
    [void]$m.Items.Add($reset)
    $m.Show($btnFilter, (New-Object System.Drawing.Point(0, ($btnFilter.Height + 2))))
}

function Update-SearchFilterButton {
    # teal when a filter is on, so it is clear why some things are missing
    $n = (Get-SearchFilter).Note
    $btnFilter.ForeColor = if ($n) { $T.Accent } else { $T.Text }
    $topTips.SetToolTip($btnFilter, $(if ($n) { "Search filters: $n" } else { 'Search filters (search everything finds everything)' }))
}

# ---- back up and restore your own things (Options > Install & files) ------------------------
$script:BackupFiles = @('settings.json', 'excluded.json', 'favourites.json', 'recent.json', 'downloads.json', 'positions.json')

function Export-AppBackup([string] $Path) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    try { Save-PosMap -Force } catch { }
    try { Save-DownloadQueue } catch { }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
    $n = 0
    try {
        foreach ($f in $script:BackupFiles) {
            $src = Join-Path $script:AppDataDir $f
            if (Test-Path -LiteralPath $src) { [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $src, $f); $n++ }
        }
        $info = [ordered]@{ App = 'NRK Browser'; Version = $script:AppVersion; Created = (Get-Date).ToString('o'); Files = $n } | ConvertTo-Json
        $e = $zip.CreateEntry('backup.json'); $w = New-Object IO.StreamWriter($e.Open(), (New-Object Text.UTF8Encoding($false))); $w.Write($info); $w.Close()
    } finally { $zip.Dispose() }
    Write-Log INFO "Backup: $n file(s) -> $Path"
    return $n
}

function Import-AppBackup([string] $Path) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        if (-not ($zip.Entries | Where-Object FullName -eq 'backup.json')) { throw 'this is not an NRK Browser backup (backup.json is missing)' }
        # what is there now is kept next to it first, in case the backup was the wrong one
        $safety = Join-Path $script:AppDataDir ('backups\before-restore-{0:yyyy-MM-dd_HHmmss}.zip' -f (Get-Date))
        New-Item -ItemType Directory -Path (Split-Path -Parent $safety) -Force | Out-Null
        [void](Export-AppBackup $safety)
        $n = 0
        foreach ($e in $zip.Entries) {
            if ($script:BackupFiles -notcontains $e.FullName) { continue }   # (only our own files, never a path)
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $script:AppDataDir $e.FullName), $true); $n++
        }
    } finally { $zip.Dispose() }
    $script:SettingsMem.Stamp = ''; $script:Favs = $null; $script:PosMap = $null; $script:Excluded = $null; $script:ExcludedVer++
    Write-Log INFO "Restore: $n file(s) from $Path (the previous ones: $safety)"
    return $n
}

# ---- recently played -------------------------------------------------------------------
# The last 50 things played (any folder), newest first, in recent.json. Each entry keeps what
# is needed to play it again straight from the "Recently played" folder.
$script:RecentFile = Join-Path $script:AppDataDir 'recent.json'
$script:RecentMax = 50

function ConvertTo-FileRecord($File) {
    $h = [ordered]@{}
    foreach ($p in $File.PSObject.Properties) {
        if ($p.Name -eq 'Raw') { continue }
        $v = $p.Value
        if ($null -eq $v -or $v -is [string] -or $v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double]) { $h[$p.Name] = $v }
        elseif ($p.Name -eq 'SeriesItem') { $h.SeriesItem = ConvertTo-FileRecord $v }
    }
    return $h
}
function ConvertFrom-FileRecord($Record) {
    $h = [ordered]@{}
    foreach ($p in $Record.PSObject.Properties) {
        if ($p.Name -eq 'SeriesItem' -and $p.Value) { $h.SeriesItem = ConvertFrom-FileRecord $p.Value } else { $h[$p.Name] = $p.Value }
    }
    $h.Raw = $null
    return [pscustomobject]$h
}

function Get-RecentRecords {
    $j = Read-JsonFile $script:RecentFile
    if (-not $j) { return @() }
    return @($j.Items | Where-Object { $_ })
}

function Add-RecentPlayed($File) {
    if (-not $File -or [string]$File.Type -notin 'live', 'radiolive', 'episode', 'program', 'audio') { return }
    try {
        $rec = ConvertTo-FileRecord $File
        $rec.PlayedAt = (Get-Date).ToString('o')
        $list = @($rec) + @(Get-RecentRecords | Where-Object { -not ([string]$_.Type -eq [string]$File.Type -and [string]$_.Id -eq [string]$File.Id) })
        Write-JsonFile $script:RecentFile ([ordered]@{ Items = @($list | Select-Object -First $script:RecentMax) })
    } catch { Write-Log DEBUG "Recently played: $($_.Exception.Message)" }
}

function Get-RecentFiles { @(Get-RecentRecords | ForEach-Object { ConvertFrom-FileRecord $_ }) }

function Clear-RecentPlayed {
    Remove-Item -LiteralPath $script:RecentFile -Force -ErrorAction SilentlyContinue
    Write-Log INFO 'Recently played cleared'
    if ((Get-FolderTag).Kind -eq 'recent') { Open-Folder $folderTree.SelectedNode }
}

# ---- favourites ------------------------------------------------------------------------
# Series and podcasts you star (right-click > Add to favourites) get a folder of their own at the
# top of the tree. favourites.json keeps what is needed to open them again. A favourite can also be
# followed: new episodes are then downloaded by themselves (see "follow series" below).
$script:FavFile = Join-Path $script:AppDataDir 'favourites.json'
$script:Favs = $null
$script:FavNode = $null

function Get-FavMap {
    if ($null -ne $script:Favs) { return $script:Favs }
    $m = [ordered]@{}
    $j = Read-JsonFile $script:FavFile
    if ($j) { foreach ($r in @($j.Items | Where-Object { $_ -and $_.Key -and $_.Item })) { $m[[string]$r.Key] = $r } }
    $script:Favs = $m
    return $m
}

function Save-FavMap { Write-JsonFile $script:FavFile ([ordered]@{ Items = @((Get-FavMap).Values) }) }

function Get-SeriesRef($Thing) {
    # the series (or podcast) behind a folder node or a file: @{ Key; Kind; Item } or $null
    if ($Thing -is [System.Windows.Forms.TreeNode]) {
        $t = $Thing.Tag
        if (-not $t) { return $null }
        if ($t.Kind -in 'season', 'radioseason') { $t = @{ Kind = $(if ($t.Kind -eq 'season') { 'series' } else { 'radioseries' }); Item = $t.Item } }
        if ($t.Kind -eq 'series' -and $t.Item) { return @{ Key = "series|$($t.Item.Id)"; Kind = 'series'; Item = $t.Item } }
        if ($t.Kind -eq 'radioseries' -and $t.Item) { return @{ Key = "radioseries|$($t.Item.Kind)|$($t.Item.Id)"; Kind = 'radioseries'; Item = $t.Item } }
        return $null
    }
    $f = $Thing
    if (-not $f) { return $null }
    if ($f.Type -eq 'episode' -and $f.SeriesItem) { return @{ Key = "series|$($f.SeriesItem.Id)"; Kind = 'series'; Item = $f.SeriesItem } }
    if ($f.Type -eq 'audio' -and $f.SeriesId) {
        $kind = if ($f.Kind -eq 'podcast') { 'podcast' } else { 'series' }
        $web = 'https://radio.nrk.no/{0}/{1}' -f $(if ($kind -eq 'podcast') { 'podkast' } else { 'serie' }), $f.SeriesId
        $it = New-NrkRadioItem -Type radioseries -Kind $kind -Id $f.SeriesId -Title $(if ($f.SeriesTitle) { $f.SeriesTitle } else { $f.SeriesId }) -WebUrl $web
        return @{ Key = "radioseries|$kind|$($f.SeriesId)"; Kind = 'radioseries'; Item = $it }
    }
    return $null
}

function Test-Favourite([string] $Key) { return [bool]($Key -and (Get-FavMap).Contains($Key)) }

function Add-Favourite($Ref) {
    if (-not $Ref) { return }
    $m = Get-FavMap
    if ($m.Contains($Ref.Key)) { return }
    $m[$Ref.Key] = [pscustomobject]@{ Key = $Ref.Key; Kind = $Ref.Kind; Item = (ConvertTo-FileRecord $Ref.Item); Added = (Get-Date).ToString('o'); Follow = $false; FollowLast = 0; Seen = @() }
    Save-FavMap
    Write-Log INFO "Favourite added: $($Ref.Item.Title)"
    Update-FavouritesNode
    Set-Status ("{0} is in Favourites" -f $Ref.Item.Title)
}

function Remove-Favourite([string] $Key) {
    $m = Get-FavMap
    if (-not $m.Contains($Key)) { return }
    $t = $m[$Key].Item.Title
    $m.Remove($Key)
    Save-FavMap
    Write-Log INFO "Favourite removed: $t"
    Update-FavouritesNode
    Set-Status ("{0} is no longer in Favourites" -f $t)
}

function New-FavouriteFolder($Rec) {
    $it = ConvertFrom-FileRecord $Rec.Item
    $kind = if ($Rec.Kind -eq 'radioseries') { 'radioseries' } else { 'series' }
    $title = [string]$it.Title
    if ($Rec.Follow) { $title += '   ' + [char]0x2193 }   # (followed: new episodes download by themselves)
    $n = New-FolderNode $title @{ Kind = $kind; Title = [string]$it.Title; Item = $it; Fav = $true } -Lazy
    return $n
}

function Update-FavouritesNode {
    $fn = $script:FavNode
    if (-not $fn -or -not $fn.TreeView) { return }
    $sel = $folderTree.SelectedNode
    $selKey = if ($sel -and $sel.Parent -eq $fn) { Get-NodeKey $sel } else { '' }
    $folderTree.BeginUpdate()
    $script:SuppressSelect = $true
    try {
        $kids = @(foreach ($r in (Get-FavMap).Values) { New-FavouriteFolder $r })
        Set-NodeChildren $fn $kids
        $fn.Text = 'Favourites   ({0})' -f $kids.Count
        if ($selKey) { foreach ($c in $fn.Nodes) { if ((Get-NodeKey $c) -eq $selKey) { $folderTree.SelectedNode = $c; break } } }
        if ($sel -and -not $sel.TreeView) { $folderTree.SelectedNode = $fn }
    } finally { $script:SuppressSelect = $false; $folderTree.EndUpdate() }
}

# ---- rows of the indexer's list as folders / files (search, new this week, last chance) ----
# search.tsv: type, id, title, subtitle, series id, series title, season, kind, date, from, to, year
function ConvertFrom-SearchRow([string[]] $Row, [hashtable] $SeriesItems) {
    $type, $id, $title, $sub, $sid, $stitle, $season, $kind, $date = $Row[0..8]
    $from = if ($Row.Count -gt 9) { $Row[9] } else { '' }
    $to = if ($Row.Count -gt 10) { $Row[10] } else { '' }
    $year = if ($Row.Count -gt 11) { $Row[11] } else { '' }
    $hiddenKey = switch ($type) { 'tvseries' { "series|$id" } 'tvprogram' { "file|program|$id" } 'tvepisode' { "file|episode|$id" } 'radioseries' { "radioseries|$kind|$id" } 'radioepisode' { "file|audio|$id" } default { '' } }
    if ((Test-Excluded $hiddenKey) -or ($type -eq 'tvepisode' -and (Test-Excluded "series|$sid")) -or ($type -eq 'radioepisode' -and (Test-Excluded "radioseries|$kind|$sid"))) { return $null }
    $f = $null
    switch ($type) {
        'tvseries' {
            $it = New-NrkItem -Type series -Id $id -Title $title -Description $sub -Section 'Search'
            return @{ Folder = (New-FolderNode $title @{ Kind = 'series'; Title = $title; Item = $it } -Lazy) }
        }
        'radioseries' {
            $web = 'https://radio.nrk.no/{0}/{1}' -f $(if ($kind -eq 'podcast') { 'podkast' } else { 'serie' }), $id
            $it = New-NrkRadioItem -Type radioseries -Kind $kind -Id $id -Title $title -Description $sub -Section 'Search' -WebUrl $web
            return @{ Folder = (New-FolderNode $title @{ Kind = 'radioseries'; Title = $title; Item = $it } -Lazy) }
        }
        'tvprogram' { $f = New-NrkItem -Type program -Id $id -Title $title -Description $sub -Section 'Search' }
        'tvepisode' {
            if (-not $SeriesItems.ContainsKey($sid)) { $SeriesItems[$sid] = New-NrkItem -Type series -Id $sid -Title $stitle -Section 'Search' }
            $ep = [pscustomobject]@{ Id = $id; Title = $title; Subtitle = $sub; Duration = ''; Available = ''; ImageUrl = $null; Raw = $null; AvailableFrom = $from; AvailableTo = $to; Year = $year }
            $f = New-EpisodeFile $ep $SeriesItems[$sid] $season
            $f | Add-Member -NotePropertyName ListTitle -NotePropertyValue ('{0}  ·  {1}' -f $stitle, $f.Title)
        }
        'radioepisode' {
            $man = if ($kind -eq 'podcast') { '/playback/manifest/podcast/{0}/{1}' -f $sid, $id } else { '/playback/manifest/program/{0}' -f $id }
            $web = if ($kind -eq 'podcast') { 'https://radio.nrk.no/podkast/{0}/{1}' -f $sid, $id } else { 'https://radio.nrk.no/program/{0}' -f $id }
            $f = New-NrkRadioItem -Type audio -Kind $kind -Id $id -Title $title -Description $sub -Section $stitle -SeriesId $sid -SeriesTitle $stitle -Date $date -ManifestPath $man -WebUrl $web
            if ($stitle -and $stitle -ne $title) { $f | Add-Member -NotePropertyName ListTitle -NotePropertyValue ('{0}  ·  {1}' -f $stitle, $title) }
        }
        default { return $null }
    }
    if ($type -ne 'tvepisode') {
        foreach ($p in @(@('AvailableFrom', $from), @('AvailableTo', $to), @('Year', $year))) { $f | Add-Member -NotePropertyName $p[0] -NotePropertyValue $p[1] -Force }
    }
    return @{ File = $f }
}

function Get-DatedFiles([ValidateSet('new', 'expiring')] [string] $Mode) {
    # New this week: on NRK since 7 days ago. Last chance: gone within 14 days. From the indexer's list.
    if (-not ('NrkSearch' -as [type]) -or -not (Test-Path -LiteralPath $script:SearchFile)) { return $null }
    [void][NrkSearch]::Load($script:SearchFile)
    $now = Get-Date
    $limit = if ($Mode -eq 'new') { $now.AddDays(-7) } else { $now.AddDays(14) }
    $hits = [NrkSearch]::Dated($(if ($Mode -eq 'new') { 0 } else { 1 }), $now.ToString('s'), $limit.ToString('s'), 1500)
    $series = @{}
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($i in $hits) {
        $r = ConvertFrom-SearchRow ([NrkSearch]::Row($i)) $series
        if ($r -and $r.File) { $files.Add($r.File) }
    }
    return ,$files.ToArray()
}

# ---- where you stopped (each programme, episode and radio recording) -----------------------
# The players report the position every few seconds; positions.json keeps it, so playing the same
# thing again (also after a restart, crash or update) continues there. Played to the end = watched:
# a green bar under it in the list, and Options > Playback can hide it.
$script:PosFile = Join-Path $script:AppDataDir 'positions.json'
$script:PosMap = $null
$script:PosDirty = $false
$script:PosSavedAt = [datetime]::MinValue
$script:PosMax = 3000

function Get-PosMap {
    if ($null -ne $script:PosMap) { return $script:PosMap }
    $m = @{}
    $j = Read-JsonFile $script:PosFile
    if ($j) { foreach ($r in @($j.Items | Where-Object { $_ -and $_.Key })) { $m[[string]$r.Key] = $r } }
    $script:PosMap = $m
    return $m
}

function Save-PosMap([switch] $Force) {
    if (-not $script:PosDirty) { return }
    if (-not $Force -and ((Get-Date) - $script:PosSavedAt).TotalSeconds -lt 10) { return }
    $items = @((Get-PosMap).Values | Sort-Object { [string]$_.At } -Descending | Select-Object -First $script:PosMax)
    Write-JsonFile $script:PosFile ([ordered]@{ Items = $items })
    $script:PosDirty = $false; $script:PosSavedAt = Get-Date
}

function Test-PosFile($File) { return [bool]($File -and $File.Id -and [string]$File.Type -in 'episode', 'program', 'audio') }

function Get-PlayRecord($File) { if (Test-PosFile $File) { return (Get-PosMap)[(Get-FileKey $File)] } else { return $null } }

function Test-Watched($File) { $r = Get-PlayRecord $File; return [bool]($r -and $r.Done) }

function Set-PlayPosition($File, [double] $Pos, [double] $Dur, [switch] $Ended) {
    if (-not (Test-PosFile $File)) { return }
    if ([double]::IsNaN($Dur) -or [double]::IsInfinity($Dur)) { $Dur = 0 }
    $m = Get-PosMap; $k = Get-FileKey $File
    $old = $m[$k]
    $nearEnd = ($Dur -gt 0 -and $Pos -ge $Dur - [Math]::Min(60, $Dur * 0.05))   # the last minute (or 5 %): the credits
    $done = [bool]($Ended -or $nearEnd -or ($old -and $old.Done -and $Pos -lt 1))
    $m[$k] = [pscustomobject]@{ Key = $k; Pos = [Math]::Round($Pos, 1); Dur = [Math]::Round($Dur, 1); At = (Get-Date).ToString('o'); Done = $done; Title = [string]$File.Title }
    try { Add-PlayStats $File $old $Pos } catch { }
    try { Update-ContinueRecord $File $Pos $done } catch { }
    $script:PosDirty = $true
    Save-PosMap
    if (-not $old -or [bool]$old.Done -ne $done -or [Math]::Abs([double]$old.Pos - $Pos) -gt 20) { try { $itemsList.Invalidate() } catch { } }
}

function Get-ResumePosition($File) {
    # where to start: a few seconds before where you stopped; 0 for a new, finished or barely started one
    if (-not (Get-AppSettings).ResumePosition) { return 0 }
    $r = Get-PlayRecord $File
    if (-not $r -or $r.Done) { return 0 }
    $p = [double]$r.Pos; $d = [double]$r.Dur
    if ($p -lt 15 -or ($d -gt 0 -and $p -gt $d - 20)) { return 0 }
    return [Math]::Max(0, [Math]::Round($p - 3))
}

function Set-Watched([object[]] $Files, [bool] $On) {
    $m = Get-PosMap; $n = 0
    foreach ($f in $Files) {
        if (-not (Test-PosFile $f)) { continue }
        $k = Get-FileKey $f
        if ($On) { $d = if ($m[$k]) { [double]$m[$k].Dur } else { 0 }; $m[$k] = [pscustomobject]@{ Key = $k; Pos = $d; Dur = $d; At = (Get-Date).ToString('o'); Done = $true; Title = [string]$f.Title } }
        else { [void]$m.Remove($k) }
        $n++
    }
    if (-not $n) { return }
    $script:PosDirty = $true; Save-PosMap -Force
    $script:ShownCache.Key = ''
    Show-Files
    Set-Status ('{0} file(s) marked as {1}' -f $n, $(if ($On) { 'watched' } else { 'not watched' }))
}

# ---- 2.9.0: Continue watching, Watch later, statistics --------------------------------------
# continue.json: what you started (file records, newest first); the "Continue watching" folder
# lists the unfinished ones and, for series you finished an episode of, the next episode.
$script:ContFile = Join-Path $script:AppDataDir 'continue.json'
$script:Cont = $null; $script:ContNext = @(); $script:ContNextAt = [datetime]::MinValue
$script:WatchLaterFile = Join-Path $script:AppDataDir 'watchlater.json'
$script:StatsFile = Join-Path $script:AppDataDir 'stats.json'
$script:Stats = $null; $script:StatsDirty = $false

function Get-ContinueMap {
    if ($null -ne $script:Cont) { return $script:Cont }
    $m = [ordered]@{}
    $j = Read-JsonFile $script:ContFile
    if ($j) { foreach ($r in @($j.Items | Where-Object { $_ -and $_.Key })) { $m[[string]$r.Key] = $r } }
    $script:Cont = $m
    return $m
}

function Update-ContinueRecord($File, [double] $Pos, [bool] $Done) {
    if (-not (Test-PosFile $File) -or ($Pos -lt 15 -and -not $Done)) { return }
    $m = Get-ContinueMap; $k = Get-FileKey $File
    $isNew = -not $m.Contains($k)
    $old = if ($isNew) { $null } else { $m[$k] }
    if ($old -and [bool]$old.Done -eq $Done -and ((Get-Date) - [datetime]$old.At).TotalSeconds -lt 60) { return }   # (at most once a minute)
    $rec = [pscustomobject]@{ Key = $k; At = (Get-Date).ToString('o'); Done = $Done; File = (ConvertTo-FileRecord $File) }
    if (-not $isNew) { $m.Remove($k) }
    $new = [ordered]@{}; $new[$k] = $rec
    $n = 0; foreach ($x in $m.Keys) { if ($n -ge 199) { break }; $new[$x] = $m[$x]; $n++ }
    $script:Cont = $new
    Write-JsonFile $script:ContFile ([ordered]@{ Items = @($new.Values) })
    if ($Done) { $script:ContNextAt = [datetime]::MinValue }   # (the next episode changes)
}

function Get-ContinueFiles {
    # started and not finished (newest first), then the next episode of series you are watching
    $out = @()
    $have = @{}
    foreach ($r in @((Get-ContinueMap).Values)) {
        if (-not $r -or -not $r.File) { continue }
        $f = ConvertFrom-FileRecord $r.File
        $rec = Get-PlayRecord $f
        if ($rec -and -not $rec.Done -and [double]$rec.Pos -ge 15) {
            if ($f.SeriesItem -and $f.SeriesItem.Title -and -not $f.ListTitle) { $f | Add-Member -NotePropertyName ListTitle -NotePropertyValue ('{0}  ·  {1}' -f $f.SeriesItem.Title, $f.Title) -Force }
            $out += $f
            $have[('{0}|{1}' -f $f.Type, $f.Id)] = $true
        }
    }
    foreach ($n in @($script:ContNext)) {
        if (-not $n) { continue }
        $k = '{0}|{1}' -f $n.Type, $n.Id
        if (-not $have.ContainsKey($k) -and -not (Test-Watched $n)) { $out += $n; $have[$k] = $true }
    }
    # (no ",$out": with nothing started that gave the folder one empty "file" - the real cause of
    #  "Argument types do not match"; callers always use @(...))
    return $out
}

function Get-ContinueNextWork {
    # (background job) the episode after the last finished one, for up to 8 series watched lately
    $seen = @{}; $result = @()
    foreach ($r in (Get-ContinueMap).Values) {
        if ($seen.Count -ge 8) { break }
        $f = ConvertFrom-FileRecord $r.File
        if ($f.Type -ne 'episode' -or -not $f.SeriesItem -or -not $f.SeriesItem.Id) { continue }
        $sid = [string]$f.SeriesItem.Id
        if ($seen.ContainsKey($sid)) { continue }
        $seen[$sid] = $true
        if (-not $r.Done) { continue }   # (the newest of this series is not finished: it is listed itself)
        if (((Get-Date) - [datetime]$r.At).TotalDays -gt 60) { continue }
        $eps = @(Get-NrkSeasonEpisodes -SeriesId $sid -Season ([string]$f.Season))
        $i = -1; for ($k = 0; $k -lt $eps.Count; $k++) { if ([string]$eps[$k].Id -eq [string]$f.Id) { $i = $k; break } }
        $next = $null; $season = [string]$f.Season
        if ($i -ge 0 -and $i -lt $eps.Count - 1) { $next = $eps[$i + 1] }
        elseif ($i -ge 0) {
            $info = Get-NrkSeriesInfo -SeriesId $sid
            $names = @($info.Seasons | Where-Object { $_.Name -ne 'ekstramateriale' } | ForEach-Object { [string]$_.Name })
            $si = [array]::IndexOf($names, $season)
            if ($si -ge 0 -and $si -lt $names.Count - 1) { $season = $names[$si + 1]; $first = @(Get-NrkSeasonEpisodes -SeriesId $sid -Season $season) | Select-Object -First 1; if ($first) { $next = $first } }
        }
        if ($next) {
            $nf = New-EpisodeFile $next $f.SeriesItem $season
            $nf | Add-Member -NotePropertyName ListTitle -NotePropertyValue ('{0}  ·  next: {1}' -f $f.SeriesItem.Title, $nf.Title) -Force
            $result += $nf
        }
    }
    return ,@($result)
}

function Start-ContinueNextJob {
    if ($script:ContNextJob -or ((Get-Date) - $script:ContNextAt).TotalMinutes -lt 10) { return }
    $script:ContNextJob = Start-ApiJob 'Continue watching' { Get-ContinueNextWork } {
        param($list)
        $script:ContNextJob = $null; $script:ContNext = @($list); $script:ContNextAt = Get-Date
        if ((Get-FolderTag).Kind -eq 'continue' -and @($list).Count) { Open-Folder $folderTree.SelectedNode }
    } { param($err) $script:ContNextJob = $null; $script:ContNextAt = Get-Date; Write-LogException $err 'Continue watching (next episodes)' }
}

function Get-WatchLaterRecords { $j = Read-JsonFile $script:WatchLaterFile; if ($j) { return @($j.Items | Where-Object { $_ -and $_.Key }) } else { return @() } }
function Get-WatchLaterFiles {
    @(foreach ($r in (Get-WatchLaterRecords)) {
        $f = ConvertFrom-FileRecord $r.File
        if ($f.SeriesItem -and $f.SeriesItem.Title -and -not $f.ListTitle -and $f.Type -eq 'episode') { $f | Add-Member -NotePropertyName ListTitle -NotePropertyValue ('{0}  ·  {1}' -f $f.SeriesItem.Title, $f.Title) -Force }
        $f
    })
}
function Test-WatchLater($File) { if (-not (Test-PosFile $File)) { return $false }; $k = Get-FileKey $File; return [bool]@(Get-WatchLaterRecords | Where-Object { $_.Key -eq $k }).Count }
function Set-WatchLater([object[]] $Files, [bool] $On) {
    $list = New-Object System.Collections.ArrayList; foreach ($r in (Get-WatchLaterRecords)) { [void]$list.Add($r) }
    $n = 0
    foreach ($f in @($Files | Where-Object { Test-PosFile $_ })) {
        $k = Get-FileKey $f
        $had = @($list | Where-Object { $_.Key -eq $k })
        if ($On -and -not $had.Count) { $list.Insert(0, [pscustomobject]@{ Key = $k; Added = (Get-Date).ToString('o'); File = (ConvertTo-FileRecord $f) }); $n++ }
        elseif (-not $On -and $had.Count) { foreach ($h in $had) { [void]$list.Remove($h) }; $n++ }
    }
    if (-not $n) { return }
    Write-JsonFile $script:WatchLaterFile ([ordered]@{ Items = @($list) })
    if ($script:WatchLaterNode) { $script:WatchLaterNode.Text = 'Watch later   ({0})' -f $list.Count }
    Set-Status ('{0} {1} Watch later' -f $n, $(if ($On) { 'added to' } else { 'removed from' }))
    if ((Get-FolderTag).Kind -eq 'watchlater') { Open-Folder $folderTree.SelectedNode }
}

# statistics: content time played, per day, medium and series (stats.json; Options > About > Statistics)
function Get-Stats {
    if ($null -ne $script:Stats) { return $script:Stats }
    $j = Read-JsonFile $script:StatsFile
    $st = @{ Days = @{}; Series = @{}; Since = (Get-Date).ToString('yyyy-MM-dd') }
    if ($j) {
        if ($j.Since) { $st.Since = [string]$j.Since }
        if ($j.Days) { foreach ($p in $j.Days.PSObject.Properties) { $st.Days[$p.Name] = @{ tv = [double]$p.Value.tv; radio = [double]$p.Value.radio } } }
        if ($j.Series) { foreach ($p in $j.Series.PSObject.Properties) { $st.Series[$p.Name] = @{ Title = [string]$p.Value.Title; Medium = [string]$p.Value.Medium; Sec = [double]$p.Value.Sec } } }
    }
    $script:Stats = $st
    return $st
}

function Add-StatSeconds([string] $Medium, [string] $Key, [string] $Title, [double] $Sec) {
    if ($Sec -le 0 -or -not (Get-AppSettings).StatsOn) { return }
    $st = Get-Stats
    $d = (Get-Date).ToString('yyyy-MM-dd')
    if (-not $st.Days.ContainsKey($d)) { $st.Days[$d] = @{ tv = 0.0; radio = 0.0 } }
    $st.Days[$d][$Medium] = [double]$st.Days[$d][$Medium] + $Sec
    if ($Key) {
        if (-not $st.Series.ContainsKey($Key)) { $st.Series[$Key] = @{ Title = $Title; Medium = $Medium; Sec = 0.0 } }
        $st.Series[$Key].Sec = [double]$st.Series[$Key].Sec + $Sec
        if ($Title) { $st.Series[$Key].Title = $Title }
    }
    $script:StatsDirty = $true
}

function Add-PlayStats($File, $Old, [double] $Pos) {
    # the time between two position reports (at most 90 s, forwards only: jumps don't count)
    if (-not $Old -or -not $Old.At) { return }
    $gap = ((Get-Date) - [datetime]$Old.At).TotalSeconds
    $delta = $Pos - [double]$Old.Pos
    if ($gap -gt 120 -or $delta -le 0 -or $delta -gt 90) { return }
    $medium = if ($File.Medium -eq 'radio' -or $File.Type -eq 'audio') { 'radio' } else { 'tv' }
    $key = if ($File.SeriesItem -and $File.SeriesItem.Id) { "series|$($File.SeriesItem.Id)" } elseif ($File.SeriesId) { "radio|$($File.SeriesId)" } else { "file|$($File.Id)" }
    $title = if ($File.SeriesItem -and $File.SeriesItem.Title) { [string]$File.SeriesItem.Title } elseif ($File.SeriesTitle) { [string]$File.SeriesTitle } else { [string]$File.Title }
    Add-StatSeconds $medium $key $title $delta
}

function Save-Stats {
    if (-not $script:StatsDirty -or $null -eq $script:Stats) { return }
    $st = $script:Stats
    Write-JsonFile $script:StatsFile ([ordered]@{ Since = $st.Since; Days = $st.Days; Series = $st.Series })
    $script:StatsDirty = $false
}

function Start-StatsTimer {
    # live TV and radio have no positions: count each minute something live plays; save once a minute
    if ($script:StatsTimer) { return }
    $script:StatsTimer = New-Object System.Windows.Forms.Timer
    $script:StatsTimer.Interval = 60000
    $script:StatsTimer.Add_Tick({
        try {
            $u = $script:AudioUi
            if ($u -and $u.Current -and $u.Current.Type -eq 'radiolive' -and -not $u.Paused) { Add-StatSeconds 'radio' "channel|$($u.Current.Id)" ([string]$u.Current.Title) 60 }
            $pw = $script:PlayerWin
            if ($pw -and -not $pw.Form.IsDisposed -and $pw.Form.Visible -and $pw.Target -and $pw.Target.File -and $pw.Target.File.Type -eq 'live' -and -not $pw.Paused) { Add-StatSeconds 'tv' "channel|$($pw.Target.File.Id)" ([string]$pw.Target.File.Title) 60 }
            Save-Stats
        } catch { }
    })
    $script:StatsTimer.Start()
}

function Show-StatsWindow {
    $st = Get-Stats
    $w = New-Object System.Windows.Forms.Form
    Set-AppIcon $w
    $w.Text = 'Statistics - NRK Browser'; $w.ClientSize = New-Object System.Drawing.Size(620, 520); $w.StartPosition = 'CenterParent'
    $w.FormBorderStyle = 'FixedDialog'; $w.MaximizeBox = $false; $w.MinimizeBox = $false
    $w.Font = $script:FontUi; $w.BackColor = $T.Bg; $w.ForeColor = $T.Text
    $sum = { param([int] $Days) $tv = 0.0; $ra = 0.0; $from = (Get-Date).Date.AddDays(1 - $Days)
             foreach ($k in $st.Days.Keys) { $d = [datetime]::ParseExact($k, 'yyyy-MM-dd', $null); if ($Days -le 0 -or $d -ge $from) { $tv += [double]$st.Days[$k].tv; $ra += [double]$st.Days[$k].radio } }
             @($tv, $ra) }
    $fmtH = { param([double] $s) if ($s -lt 3600) { '{0:N0} min' -f ($s / 60) } else { '{0:N1} h' -f ($s / 3600) } }
    $y = 18
    $hdr = New-Object System.Windows.Forms.Label; $hdr.Text = "What you watched and listened to (since $($st.Since))"; $hdr.Font = $script:FontHeader; $hdr.AutoSize = $true; $hdr.Location = New-Object System.Drawing.Point(20, $y); $w.Controls.Add($hdr)
    $y += 44
    foreach ($row in @(@('Last 7 days', 7), @('Last 30 days', 30), @('All time', 0))) {
        $v = & $sum $row[1]
        $l = New-Object System.Windows.Forms.Label; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(24, $y)
        $l.Text = '{0,-14}   TV {1}    ·    Radio {2}' -f $row[0], (& $fmtH $v[0]), (& $fmtH $v[1])
        $w.Controls.Add($l); $y += 26
    }
    $y += 12
    $h2 = New-Object System.Windows.Forms.Label; $h2.Text = 'Most played series and channels'; $h2.Font = $script:FontBold; $h2.AutoSize = $true; $h2.Location = New-Object System.Drawing.Point(20, $y); $w.Controls.Add($h2)
    $y += 28
    $lv = New-Object System.Windows.Forms.ListView; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HeaderStyle = 'Nonclickable'; $lv.BorderStyle = 'None'
    $lv.Location = New-Object System.Drawing.Point(20, $y); $lv.Size = New-Object System.Drawing.Size(580, (500 - $y - 40)); $lv.BackColor = $T.Surface; $lv.ForeColor = $T.Text
    [void]$lv.Columns.Add('Title', 380); [void]$lv.Columns.Add('', 80); [void]$lv.Columns.Add('Time', 100)
    foreach ($e in @($st.Series.Values | Sort-Object { [double]$_.Sec } -Descending | Select-Object -First 25)) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$e.Title); [void]$it.SubItems.Add($(if ($e.Medium -eq 'radio') { 'Radio' } else { 'TV' })); [void]$it.SubItems.Add((& $fmtH ([double]$e.Sec))); [void]$lv.Items.Add($it)
    }
    $w.Controls.Add($lv)
    $bReset = New-FlatButton 'Start counting again' 200; $bReset.Location = New-Object System.Drawing.Point(20, 478); $bReset.ForeColor = $T.Bad
    $bReset.Add_Click({ if ([System.Windows.Forms.MessageBox]::Show($this.FindForm(), 'Forget everything counted so far?', 'Statistics', 'YesNo', 'Question') -eq 'Yes') { $script:Stats = @{ Days = @{}; Series = @{}; Since = (Get-Date).ToString('yyyy-MM-dd') }; $script:StatsDirty = $true; Save-Stats; $this.FindForm().Close() } })
    $w.Controls.Add($bReset)
    Set-DarkTheme $w; Enable-DarkTitleBar $w
    $lv.BackColor = $T.Surface
    [void]$w.ShowDialog($form)
}

function Export-PodcastOpml {
    # the favourite podcasts as an OPML file (NRK's own RSS feeds) for another podcast app
    $pods = @((Get-FavMap).Values | Where-Object { $_.Item -and $_.Item.Kind -eq 'podcast' -and $_.Item.Id })
    if (-not $pods.Count) { [void][System.Windows.Forms.MessageBox]::Show($form, 'No podcasts among the favourites yet (right-click a podcast > Add to favourites).', 'Export podcasts', 'OK', 'Information'); return }
    $d = New-Object System.Windows.Forms.SaveFileDialog
    $d.Filter = 'OPML (*.opml)|*.opml'; $d.FileName = 'NRK podcasts.opml'
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $x = New-Object System.Text.StringBuilder
    [void]$x.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$x.AppendLine('<opml version="2.0"><head><title>NRK podcasts (NRK Browser)</title><dateCreated>' + (Get-Date).ToUniversalTime().ToString('r') + '</dateCreated></head><body>')
    foreach ($r in $pods) {
        $t = [Security.SecurityElement]::Escape([string]$r.Item.Title)
        $u = [Security.SecurityElement]::Escape((Get-PodcastFeedUrl $r.Item))
        [void]$x.AppendLine(('  <outline type="rss" text="{0}" title="{0}" xmlUrl="{1}" htmlUrl="{2}"/>' -f $t, $u, [Security.SecurityElement]::Escape([string]$r.Item.WebUrl)))
    }
    [void]$x.AppendLine('</body></opml>')
    [IO.File]::WriteAllText($d.FileName, $x.ToString(), (New-Object Text.UTF8Encoding($false)))
    Write-Log INFO "Exported $($pods.Count) podcast(s) to $($d.FileName)"
    Set-Status "Exported $($pods.Count) podcast(s) to $($d.FileName)"
}

function Format-PlayTime([double] $Sec) {
    $t = [TimeSpan]::FromSeconds([Math]::Max(0, $Sec))
    if ($t.TotalHours -ge 1) { return '{0}:{1:mm\:ss}' -f [int][Math]::Floor($t.TotalHours), $t } else { return '{0:m\:ss}' -f $t }
}

# the mark in the files list: a thin bar under the row (accent: started, green: watched)
$script:WatchDraw = {
    param($G, $Row, $File)
    if (-not (Test-PosFile $File)) { return }
    $r = (Get-PosMap)[(Get-FileKey $File)]
    if (-not $r) { return }
    $x0 = $Row.X + 46; $w = $Row.Right - 12 - $x0
    if ($w -le 10) { return }
    $y = $Row.Bottom - 4
    if ($r.Done) { $G.FillRectangle((Get-Brush $T.Ok), $x0, $y, $w, 2); return }
    $d = [double]$r.Dur
    if ($d -le 0 -or [double]$r.Pos -lt 15) { return }
    $G.FillRectangle((Get-Brush $T.Border), $x0, $y, $w, 2)
    $G.FillRectangle((Get-Brush $T.Accent), $x0, $y, [int]($w * [Math]::Min(1, [double]$r.Pos / $d)), 2)
}

# ---- empty folders ---------------------------------------------------------------------
# A folder that turns out to hold nothing is taken out of the tree (Reload brings it back to
# check again). Folders the indexer found empty on its last full walk never appear at all.
# A folder that failed to load is never hidden: it shows "(failed - see Logs)".
$script:KnownEmpty = New-Object 'System.Collections.Generic.HashSet[string]'
$script:EmptyNow = New-Object 'System.Collections.Generic.HashSet[string]'   # found empty this session
$script:HideQueue = New-Object System.Collections.ArrayList
$script:HideTimer = $null

function Read-KnownEmpty {
    $script:KnownEmpty.Clear()
    try { if (Test-Path -LiteralPath $script:EmptyFile) { foreach ($l in [IO.File]::ReadAllLines($script:EmptyFile)) { if ($l.Trim()) { [void]$script:KnownEmpty.Add($l.Trim()) } } } } catch { }
    foreach ($k in $script:EmptyNow) { [void]$script:KnownEmpty.Add($k) }
}

function Test-KnownEmpty($Node) { return $script:KnownEmpty.Contains((Get-NodeKey $Node)) }

function Hide-EmptyNode($Node) {
    # after the current event has finished (the folder may be the one being opened)
    if (-not $Node -or -not $Node.TreeView -or $Node.Tag.Kind -in 'group', 'live', 'radiolive', 'search', 'recent', 'favourites', 'newweek', 'expiring', 'continue', 'watchlater' -or $Node.Tag.Fav) { return }
    $k = Get-NodeKey $Node
    [void]$script:EmptyNow.Add($k); [void]$script:KnownEmpty.Add($k)
    [void]$script:HideQueue.Add($Node)
    if (-not $script:HideTimer) {
        $script:HideTimer = New-Object System.Windows.Forms.Timer
        $script:HideTimer.Interval = 60
        $script:HideTimer.Add_Tick({
            $script:HideTimer.Stop()
            $names = @()
            foreach ($n in @($script:HideQueue)) {
                if (-not $n.TreeView) { continue }
                $parent = $n.Parent
                for ($s = $folderTree.SelectedNode; $s; $s = $s.Parent) { if ($s -eq $n) { if ($parent) { $folderTree.SelectedNode = $parent }; break } }
                $names += $n.Tag.Title
                $n.Remove()
                if ($parent -and $parent.Tag.Kind -in 'series', 'radioseries' -and $parent.Nodes.Count -eq 0) { Hide-EmptyNode $parent }
            }
            $script:HideQueue.Clear()
            if ($names.Count) {
                Write-Log INFO ("Empty folder hidden: {0}" -f ($names -join ', '))
                Set-Status ("'{0}' has nothing in it right now, so it is hidden (Reload checks again)" -f ($names -join "', '"))
            }
            if ($script:HideQueue.Count) { $script:HideTimer.Start() }
        })
    }
    $script:HideTimer.Start()
}

# ---- download queue across restarts ----------------------------------------------------
# The queue is saved to downloads.json whenever it changes, and read back at the next start.
# Nothing starts by itself: unfinished items come back as "Added".
$script:QueueFile = Join-Path $script:AppDataDir 'downloads.json'
$script:QueueSig = ''
$script:QueueSaveTimer = $null

function Request-QueueSave {
    $sig = (@($script:DlQueue | ForEach-Object { '{0}:{1}:{2}' -f $_.Id, $_.Status, $_.Detail }) -join '|')
    if ($sig -eq $script:QueueSig) { return }
    $script:QueueSig = $sig
    if (-not ('System.Windows.Forms.Timer' -as [type])) { Save-DownloadQueue; return }
    if (-not $script:QueueSaveTimer) {
        $script:QueueSaveTimer = New-Object System.Windows.Forms.Timer
        $script:QueueSaveTimer.Interval = 1500
        $script:QueueSaveTimer.Add_Tick({ $script:QueueSaveTimer.Stop(); Save-DownloadQueue })
    }
    $script:QueueSaveTimer.Stop(); $script:QueueSaveTimer.Start()
}

function Save-DownloadQueue {
    try {
        if ($script:DlQueue.Count -eq 0) { Remove-Item -LiteralPath $script:QueueFile -Force -ErrorAction SilentlyContinue; return }
        $items = foreach ($it in $script:DlQueue) {
            [ordered]@{ Title = $it.Title; Kind = $it.Kind; Url = $it.Url; Status = $it.Status; Detail = $it.Detail; Progress = [double]$it.Progress; Files = @($it.Files); Dirs = @($it.Dirs); File = (ConvertTo-FileRecord $it.File) }
        }
        Write-JsonFile $script:QueueFile ([ordered]@{ Saved = (Get-Date).ToString('o'); Items = @($items) })
    } catch { Write-Log DEBUG "Download queue save: $($_.Exception.Message)" }
}

function Restore-DownloadQueue {
    $j = Read-JsonFile $script:QueueFile
    if (-not $j) { return }
    $keepAll = [bool](Get-AppSettings).DlKeepList
    $n = 0; $waiting = 0
    foreach ($r in @($j.Items | Where-Object { $_ })) {
        $file = if ($r.File) { ConvertFrom-FileRecord $r.File } else { $null }
        $status = [string]$r.Status; $detail = [string]$r.Detail
        if (-not $keepAll -and $status -in 'Done', 'Canceled', 'Failed') { continue }   # (Options > Downloads: keep only what is not finished)
        $tmpHas = $false
        if ($file) { $tmpHas = Test-Path -LiteralPath (Get-DownloadTmpDir @{ Kind = [string]$r.Kind; File = $file; Url = [string]$r.Url }) }
        if ($status -in 'Pending', 'Downloading') { if ($tmpHas) { $status = 'Paused'; $detail = 'from last time: Resume continues where it stopped' } else { $status = 'Added'; $detail = 'from last time' } }
        if ($status -notin 'Added', 'Done', 'Failed', 'Canceled', 'Paused') { $status = 'Added' }
        $script:DlNextId++
        [void]$script:DlQueue.Add(@{ Id = $script:DlNextId; Title = [string]$r.Title; Kind = [string]$r.Kind; Url = [string]$r.Url; File = $file; Status = $status
                                     Progress = $(if ($status -eq 'Done') { 100 } elseif ($status -eq 'Paused' -and $null -ne $r.Progress) { [double]$r.Progress } else { -1 }); Detail = $detail; Files = @($r.Files); Dirs = @($r.Dirs); Row = $null; LastLogged = -10 })
        $n++; if ($status -in 'Added', 'Paused') { $waiting++ }
    }
    if ($n) {
        Write-Log INFO "Download queue: restored $n item(s) from last time ($waiting not downloaded yet)"
        if ($waiting) { $script:StartupNote = (@($script:StartupNote, "$waiting download(s) from last time are waiting in Downloads (Ctrl+D)") | Where-Object { $_ }) -join '  ·  ' }
    }
    $script:QueueSig = (@($script:DlQueue | ForEach-Object { '{0}:{1}:{2}' -f $_.Id, $_.Status, $_.Detail }) -join '|')
}

# ---- files list ---------------------------------------------------------------------

function New-EpisodeFile {
    # An episode as a "file": same shape as programme items, plus its series/season.
    param($Episode, $SeriesItem, [string] $Season)
    # NRK titles episodes "3. episode" with the real name in the subtitle
    $label = if ($Episode.Subtitle -and $Episode.Title -match '^(\d+)\. episode$') { '{0}. {1}' -f $Matches[1], ($Episode.Subtitle -replace '^[–-]\s*', '') } else { $Episode.Title }
    [pscustomobject]@{
        Type         = 'episode'
        Id           = $Episode.Id
        Title        = $label
        Description  = ($Episode.Subtitle -replace '^[–-]\s*', '')
        Duration     = $Episode.Duration
        Available    = $Episode.Available
        AvailableFrom = [string]$Episode.AvailableFrom
        AvailableTo  = [string]$Episode.AvailableTo
        AvailableAlways = [bool]$Episode.AvailableAlways
        Year         = [string]$Episode.Year
        Season       = $Season
        SeriesItem   = $SeriesItem
        ImageUrl     = $Episode.ImageUrl
        WebUrl       = '{0}/sesong/{1}/episode/{2}' -f $SeriesItem.WebUrl, $Season, $Episode.Id
        Playable     = $true
        Downloadable = $true
        GeoBlocked   = $null
        Section      = $SeriesItem.Title
        Raw          = $Episode.Raw
    }
}

function Invoke-LoadMore($More) {
    # the next 300 episodes of a long podcast or radio series, added to the list
    $tag = $More.Tag
    $res = @{ Items = @() }
    Invoke-Ui 'Loading more episodes' {
        $res.Items = @(Get-NrkRadioEpisodes -Href $More.Next -Kind $tag.Item.Kind -SeriesId $tag.Item.Id -SeriesTitle $More.SeriesTitle)
    }
    $kept = @($script:Files | Where-Object { $_.Type -ne 'more' })
    $all = @($kept + $res.Items)
    $script:Cache["reps:$($More.Href)"] = $all; $script:CacheAt["reps:$($More.Href)"] = Get-Date   # the folder keeps them when you come back
    $script:RadioMore[$More.Href] = $script:RadioMore[$More.Next]; [void]$script:RadioMore.Remove($More.Next)
    $next = $script:RadioMore[$More.Href]
    if ($next) { $all += [pscustomobject]@{ Type = 'more'; Id = 'more'; Title = 'Load more episodes...'; Description = 'Double-click to load the next episodes'; Playable = $true; Downloadable = $false; Next = $next; Href = $More.Href; Tag = $tag; SeriesTitle = $More.SeriesTitle } }
    else { [void]$script:RadioMore.Remove($More.Href) }
    $script:Files = $all
    Show-Files
    Set-Status ('{0} more episodes  ·  {1} in this folder{2}' -f $res.Items.Count, $kept.Count + $res.Items.Count, $(if ($next) { '  ·  more at the end of the list' } else { '' }))
}

$script:ShownCache = @{ Key = ''; List = @() }
function Get-ShownFiles {
    # $script:Files in display order, sorted once per folder (not on every keystroke of the filter)
    $all = @($script:Files)
    $files = @($all | Where-Object { $_.Type -ne 'more' -and -not (Test-Excluded (Get-FileKey $_)) })
    $tail = @($all | Where-Object { $_.Type -eq 'more' })
    $key = '{0}|{1}|{2}|{3}|{4}' -f [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($script:Files), $files.Count, (Get-SortOrder), [bool]$script:FilesNoSort, $script:ExcludedVer
    if ($script:ShownCache.Key -eq $key) { return ,$script:ShownCache.List }
    $shown = $files
    if (-not $script:FilesNoSort -and $files.Count -gt 1 -and @($files | Where-Object { $_.Type -notin 'live', 'radiolive' }).Count -gt 0) {
        $pos = @{}; for ($i = 0; $i -lt $files.Count; $i++) { $pos[[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($files[$i])] = $i }
        $order = { param($f) $pos[[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($f)] }
        if (@($files | Where-Object { $_.Type -notin 'episode', 'audio' }).Count -eq 0) {
            # episodes: by date (radio) or by NRK's episode order (TV), not by title: Z-A = newest first
            $byDate = @($files | Where-Object { $_.Date -match '^\d\d\.\d\d\.\d{4}$' }).Count -eq $files.Count
            $epKey = if ($byDate) { { param($f) if ($f.Date -match '^(\d\d)\.(\d\d)\.(\d{4})$') { "$($Matches[3])$($Matches[2])$($Matches[1])" } } }   # (same day: NRK's order)
                     else { { param($f) '{0:D6}' -f (& $order $f) } }
            $shown = Sort-ByTitle $files $epKey $order
        } else {
            $shown = Sort-ByTitle $files { param($f) $f.Title } $order
        }
    }
    $script:ShownCache = @{ Key = $key; List = @(@($shown) + $tail) }
    return ,$script:ShownCache.List
}

function Show-Files {
    $q = $search.Text.Trim()
    $itemsList.BeginUpdate()
    $itemsList.Items.Clear()
    $n = 0
    # shown in the chosen sort order; $script:Files keeps NRK's order (so "next episode" stays the next one)
    $shown = Get-ShownFiles
    # Options > General: the description on a second line, like NRK's own lists
    $two = [bool](Get-AppSettings).ListDescriptions
    $wantTall = $false
    foreach ($f in $shown) {
        # (worked out once per file, not on every keystroke in the filter box)
        if (-not $f.PSObject.Properties['ListLine2For'] -or $f.ListLine2For -ne $two) {
            $line2 = ''
            if ($two -and $f.Type -in 'episode', 'audio', 'program') {
                $d = ([string]$f.Description -replace '\s+', ' ').Trim()
                if ($d -and $d -ne $f.Title) { $line2 = $d }
            }
            $f | Add-Member -NotePropertyName ListLine2 -NotePropertyValue $line2 -Force
            $f | Add-Member -NotePropertyName ListLine2For -NotePropertyValue $two -Force
        }
        if ($f.ListLine2) { $wantTall = $true }
    }
    $il = if ($wantTall) { $script:IconsTall } else { $script:Icons }
    if ($itemsList.SmallImageList -ne $il) { $itemsList.SmallImageList = $il }
    Initialize-GridView (Test-GridView)
    $itemsList.Tag = if ($wantTall) { 'two' } else { '' }
    $hideWatched = [bool](Get-AppSettings).HideWatched
    foreach ($f in $shown) {
        if ($hideWatched -and (Test-Watched $f)) { continue }
        $label = if ($f.ListTitle) { [string]$f.ListTitle } else { [string]$f.Title }
        if ($q -and ($label -notmatch [regex]::Escape($q)) -and ($f.Description -notmatch [regex]::Escape($q)) -and ($f.Id -notmatch [regex]::Escape($q))) { continue }
        $icon = switch ($f.Type) { 'program' { 'program' } 'live' { 'live' } 'radiolive' { 'live' } 'episode' { 'episode' } 'audio' { 'episode' } default { 'other' } }
        # going soon (two weeks or less): how long it is still there
        $left = ''
        if ($f.Type -in 'episode', 'audio', 'program') { $dl = Get-DaysLeft ([string]$f.AvailableTo); if ($null -ne $dl -and $dl -ge 0 -and $dl -le 14) { $left = Format-AvailableUntil $f -Short } }
        $second = switch ($f.Type) {
            { $_ -in 'live', 'radiolive' } { if ($f.District) { 'regional' } else { '' } }
            'episode' { (@($f.Duration, $left) | Where-Object { $_ }) -join '  ·  ' }
            'audio' { (@($f.Date, $f.Duration, $left) | Where-Object { $_ }) -join '  ·  ' }
            'program' { $left }
            default { '' }
        }
        $dim = (-not $f.Playable) -or ($f.Type -in 'episode', 'audio' -and -not (Test-FileAvailable $f))
        $row = Add-DarkListRow $itemsList $label ([string]$second) $f $icon -Dim:$dim
        if ($script:SelectedFile -and $f -eq $script:SelectedFile) { $row.Selected = $true }
        $n++
    }
    $itemsList.EndUpdate()
    $total = @($script:Files).Count
    $folder = $folderTree.SelectedNode
    $what = switch (@($script:Files | Select-Object -First 1).Type) { 'live' { 'channels' } 'radiolive' { 'channels' } 'episode' { 'episodes' } 'audio' { 'recordings' } default { 'files' } }
    Set-ItemsHeader $(if ($folder) { '{0}  ·  {1} {2}' -f $folder.Tag.Title, $total, $what } else { 'Pick a folder' })
    if ($q) { Set-Status ('{0} of {1} {2} match "{3}"' -f $n, $total, $what, $q) }
}

function Set-Preview {
    param([string] $Title, [string] $Meta, [string] $Description, [string] $ImageUrl)
    $pTitle.Text = $Title
    $pMeta.Text = $Meta
    $pDesc.Text = $Description
    if ($ImageUrl) { $pic.Image = Get-NrkImage $ImageUrl } else { $pic.Image = $null }
}

function Add-Meta([string] $Key, $Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return }
    [void]$script:MetaPairs.Add(@($Key, ([string]$Value -replace '\s+', ' ')))
    Update-MetaHeight
}
function Clear-Meta { $script:MetaPairs.Clear(); Update-MetaHeight }

function Show-Schedule([bool] $On) {
    # live channels: today's schedule fills the space under the details
    $script:ScheduleOn = $On
    $hdrSchedule.Visible = $On; $scheduleList.Visible = $On
    Update-ContentLayout
    if (-not $On) { $scheduleList.Items.Clear() }
}

# ---- placeholder pictures for folders without one ----------------------------------------
# pictures\<name>.png from the repository (Start-AssetDownload); until it is there, the same
# line drawing is made here: a TV set, a radio set, or the special folders' own picture.
$script:Placeholders = @{}

function Get-PlaceholderImage([ValidateSet('tv', 'radio', 'recent', 'fav', 'new', 'last', 'continue', 'watchlater')] [string] $Kind) {
    $key = "$Kind|$($script:ThemeEffective)"
    if ($script:Placeholders[$key]) { return $script:Placeholders[$key] }
    if ($script:AssetPictures.Contains($Kind)) {
        $png = Get-AssetImage "pictures/$($script:AssetPictures[$Kind]).png"
        if ($png) { $script:Placeholders[$key] = $png; return $png }
    }
    $w = 960; $h = 540
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.TextRenderingHint = 'AntiAliasGridFit'
    # a dark tile in both themes
    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point($w, $h)), [System.Drawing.Color]::FromArgb(12, 24, 32), [System.Drawing.Color]::FromArgb(22, 40, 50))
    $g.FillRectangle($bg, 0, 0, $w, $h); $bg.Dispose()
    if ($true) {
        # a line drawing (white, with a teal detail) on a 170 x 120 grid and the folder's name under it
        $acc = [System.Drawing.Color]::FromArgb(72, 201, 210)
        $light = [System.Drawing.Color]::FromArgb(226, 232, 236)
        $grey = [System.Drawing.Color]::FromArgb(134, 147, 156)
        $k = 1.9; $ox = ($w - 170 * $k) / 2; $oy = 84    # scaled and centred
        $state = $g.Save()
        $g.TranslateTransform([float]$ox, [float]$oy); $g.ScaleTransform([float]$k, [float]$k)
        $mkPen = { param($c, $wd) $pp = New-Object System.Drawing.Pen($c, $wd); $pp.StartCap = 'Round'; $pp.EndCap = 'Round'; $pp.LineJoin = 'Round'; $pp }
        $pt = { param($x, $y) New-Object System.Drawing.PointF([float]$x, [float]$y) }
        $pW = & $mkPen $light 6; $pA = & $mkPen $acc 6
        $bA = New-Object System.Drawing.SolidBrush($acc); $bW = New-Object System.Drawing.SolidBrush($light)
        $quad = { param($gp, $x0, $y0, $cx, $cy, $x1, $y1) $gp.AddBezier([float]$x0, [float]$y0, [float]($x0 + 2 / 3 * ($cx - $x0)), [float]($y0 + 2 / 3 * ($cy - $y0)), [float]($x1 + 2 / 3 * ($cx - $x1)), [float]($y1 + 2 / 3 * ($cy - $y1)), [float]$x1, [float]$y1) }
        $label = switch ($Kind) { 'radio' { 'Radio' } 'recent' { 'Recently played' } 'fav' { 'Favourites' } 'new' { 'New this week' } 'last' { 'Last chance' } 'continue' { 'Continue watching' } 'watchlater' { 'Watch later' } default { 'TV' } }
        switch ($Kind) {
            'recent' {
                # a clock turning back
                $g.DrawArc($pW, 41, 18, 88, 88, 180, -315)
                $g.DrawLines($pA, [System.Drawing.PointF[]]@((& $pt 42 18), (& $pt 54 31), (& $pt 37 37)))
                $g.DrawLines($pA, [System.Drawing.PointF[]]@((& $pt 85 38), (& $pt 85 62), (& $pt 102 74)))
                $g.FillEllipse($bW, 80, 57, 10, 10)
            }
            'fav' {
                # a star with a teal centre
                $big = [System.Drawing.PointF[]]@((& $pt 85 8), (& $pt 99.2 42.4), (& $pt 136.3 45.3), (& $pt 108 69.6), (& $pt 116.7 105.7), (& $pt 85 86.2), (& $pt 53.3 105.7), (& $pt 62 69.6), (& $pt 33.7 45.3), (& $pt 70.8 42.4))
                $g.DrawPolygon($pW, $big)
                $small = [System.Drawing.PointF[]]@((& $pt 85 46), (& $pt 89.7 57.5), (& $pt 102 58.4), (& $pt 92.6 66.5), (& $pt 95.5 78.5), (& $pt 85 72), (& $pt 74.5 78.5), (& $pt 77.4 66.5), (& $pt 68 58.4), (& $pt 80.3 57.5))
                $g.FillPolygon($bA, $small)
            }
            'new' {
                # a calendar with a sparkle
                $box = New-Object System.Drawing.Drawing2D.GraphicsPath; $r = 24
                $box.AddArc(30, 22, $r, $r, 180, 90); $box.AddArc(140 - $r, 22, $r, $r, 270, 90); $box.AddArc(140 - $r, 116 - $r, $r, $r, 0, 90); $box.AddArc(30, 116 - $r, $r, $r, 90, 90); $box.CloseFigure()
                $g.DrawPath($pW, $box); $box.Dispose()
                $g.DrawLine($pW, 30, 48, 140, 48); $g.DrawLine($pW, 60, 10, 60, 32); $g.DrawLine($pW, 110, 10, 110, 32)
                $sp = New-Object System.Drawing.Drawing2D.GraphicsPath
                & $quad $sp 85 58 88 79 106 82; & $quad $sp 106 82 88 85 85 106; & $quad $sp 85 106 82 85 64 82; & $quad $sp 64 82 82 79 85 58
                $sp.CloseFigure(); $g.FillPath($bA, $sp); $sp.Dispose()
            }
            'last' {
                # an hourglass running out
                $g.DrawLine($pW, 48, 8, 122, 8); $g.DrawLine($pW, 48, 114, 122, 114)
                $gl = New-Object System.Drawing.Drawing2D.GraphicsPath
                $gl.AddBezier(58, 8, 58, 42, 80, 48, 80, 61); $gl.AddBezier(80, 61, 80, 74, 58, 80, 58, 114)
                $g.DrawPath($pW, $gl); $gl.Dispose()
                $gr = New-Object System.Drawing.Drawing2D.GraphicsPath
                $gr.AddBezier(112, 8, 112, 42, 90, 48, 90, 61); $gr.AddBezier(90, 61, 90, 74, 112, 80, 112, 114)
                $g.DrawPath($pW, $gr); $gr.Dispose()
                $s1 = New-Object System.Drawing.Drawing2D.GraphicsPath
                $s1.AddLine(70, 30, 100, 30); & $quad $s1 100 30 92 44 85 50; & $quad $s1 85 50 78 44 70 30; $s1.CloseFigure(); $g.FillPath($bA, $s1); $s1.Dispose()
                $s2 = New-Object System.Drawing.Drawing2D.GraphicsPath
                & $quad $s2 85 82 100 92 103 108; $s2.AddLine(103, 108, 67, 108); & $quad $s2 67 108 70 92 85 82; $s2.CloseFigure(); $g.FillPath($bA, $s2); $s2.Dispose()
            }
            'watchlater' {
                # a bookmark with a clock (pictures\watch-later.png)
                $bm = New-Object System.Drawing.Drawing2D.GraphicsPath
                $bm.AddLines([System.Drawing.PointF[]]@((& $pt 52 8), (& $pt 118 8), (& $pt 118 112), (& $pt 85 88), (& $pt 52 112))); $bm.CloseFigure()
                $g.DrawPath($pW, $bm); $bm.Dispose()
                $g.DrawEllipse($pA, 66, 26, 38, 38)
                $pH = & $mkPen $acc 5; $g.DrawLine($pH, 85, 45, 85, 33); $g.DrawLine($pH, 85, 45, 94, 50); $pH.Dispose()
            }
            'continue' {
                # a screen with a play sign and a progress line half way (pictures\continue-watching.png)
                $rr2 = New-Object System.Drawing.Drawing2D.GraphicsPath; $d = 24
                $rr2.AddArc(14, 12, $d, $d, 180, 90); $rr2.AddArc(156 - $d, 12, $d, $d, 270, 90); $rr2.AddArc(156 - $d, 96 - $d, $d, $d, 0, 90); $rr2.AddArc(14, 96 - $d, $d, $d, 90, 90); $rr2.CloseFigure()
                $g.DrawPath($pW, $rr2); $rr2.Dispose()
                $g.FillPolygon($bA, [System.Drawing.PointF[]]@((& $pt 74 34), (& $pt 74 74), (& $pt 106 54)))
                $pG = & $mkPen $grey 6; $g.DrawLine($pG, 20, 112, 150, 112); $pG.Dispose()
                $g.DrawLine($pA, 20, 112, 88, 112); $g.FillEllipse($bA, 82, 106, 12, 12)
            }
            'tv' {
                # an old-style TV set (pictures\tv.png)
                $pAnt = & $mkPen $grey 4; $g.DrawLine($pAnt, 70, 20, 52, 2); $g.DrawLine($pAnt, 70, 20, 90, 4); $pAnt.Dispose()
                $rr = { param($x, $y, $wd, $ht, $r) $gp = New-Object System.Drawing.Drawing2D.GraphicsPath; $d = 2 * $r
                        $gp.AddArc($x, $y, $d, $d, 180, 90); $gp.AddArc($x + $wd - $d, $y, $d, $d, 270, 90); $gp.AddArc($x + $wd - $d, $y + $ht - $d, $d, $d, 0, 90); $gp.AddArc($x, $y + $ht - $d, $d, $d, 90, 90); $gp.CloseFigure(); $gp }
                $box = & $rr 10 20 150 90 14; $g.DrawPath($pW, $box); $box.Dispose()
                $pS = & $mkPen $acc 5; $scr = & $rr 24 34 92 62 8; $g.DrawPath($pS, $scr); $scr.Dispose()
                $g.FillPolygon($bA, [System.Drawing.PointF[]]@((& $pt 62 50), (& $pt 62 80), (& $pt 86 65)))
                $pL = & $mkPen $light 5; $g.DrawEllipse($pL, 130, 40, 16, 16); $g.DrawLine($pL, 128, 72, 148, 72); $g.DrawLine($pL, 128, 86, 148, 86); $pL.Dispose(); $pS.Dispose()
            }
            default {
                # an old-style radio set (B)
                $pAnt = & $mkPen $grey 4; $g.DrawLine($pAnt, 40, 30, 118, 4); $pAnt.Dispose()
                $box = New-Object System.Drawing.Drawing2D.GraphicsPath; $r = 28
                $box.AddArc(10, 30, $r, $r, 180, 90); $box.AddArc(160 - $r, 30, $r, $r, 270, 90); $box.AddArc(160 - $r, 116 - $r, $r, $r, 0, 90); $box.AddArc(10, 116 - $r, $r, $r, 90, 90); $box.CloseFigure()
                $g.DrawPath($pW, $box); $box.Dispose()
                $g.DrawEllipse($pA, 28, 49, 48, 48)
                $g.FillEllipse($bA, 45, 66, 14, 14)
                $pL = & $mkPen $light 5; $g.DrawLine($pL, 96, 58, 142, 58); $g.DrawLine($pL, 96, 74, 142, 74); $g.DrawLine($pL, 96, 90, 128, 90); $pL.Dispose()
            }
        }
        $pW.Dispose(); $pA.Dispose(); $bA.Dispose(); $bW.Dispose()
        $g.Restore($state)
        $font = New-Object System.Drawing.Font('Segoe UI Semibold', 40)
        $sz = $g.MeasureString($label, $font)
        $g.DrawString($label, $font, [System.Drawing.Brushes]::White, [float](($w - $sz.Width) / 2), [float]($oy + 124 * $k + 6))
        $font.Dispose()
    }
    $g.Dispose()
    $script:Placeholders[$key] = $bmp
    return $bmp
}

function Get-FolderPlaceholderKind($Tag) {
    if (-not $Tag) { return $null }
    switch ($Tag.Kind) { 'recent' { return 'recent' } 'favourites' { return 'fav' } 'newweek' { return 'new' } 'expiring' { return 'last' } 'continue' { return 'continue' } 'watchlater' { return 'watchlater' } }
    if ($Tag.Kind -in 'radiolive', 'radiocategory', 'radioletter', 'radioseries', 'radioseason') { return 'radio' }
    if ($Tag.Kind -in 'live', 'category', 'letter', 'series', 'season') { return 'tv' }
    if ($Tag.Kind -eq 'group') { if ([string]$Tag.Title -match '^Radio') { return 'radio' } elseif ([string]$Tag.Title -match '^(TV|Categories|A - )') { return 'tv' } }
    return $null
}

function Show-FolderPreview {
    # Preview + details for the selected folder when no file is selected.
    $node = $folderTree.SelectedNode
    Clear-Meta; Show-Schedule $false
    if (-not $node) { Set-Preview 'NRK Browser' 'Pick a folder on the left.' '' $null; return }
    $tag = $node.Tag
    switch ($tag.Kind) {
        'live' {
            Set-Preview 'LIVE TV' ('{0} channels  ·  pick one to see what is on' -f @($script:Files).Count) 'NRK1, NRK2, NRK3, NRK Super, NRK Tegnspråk and the regional NRK1 channels.' $null
        }
        'radiolive' {
            Set-Preview 'LIVE Radio' ('{0} channels  ·  pick one to see what is on' -f @($script:Files).Count) 'NRK P1, P2, P3, mP3, Klassisk, Jazz, Nyheter and the regional P1 channels. Plays in the audio bar at the bottom.' $null
        }
        { $_ -in 'radioseries', 'radioseason' } {
            $info = $tag.Info; $it = $tag.Item
            $what = if ($it.Kind -eq 'podcast') { 'Podcast' } else { 'Radio series' }
            $meta = @($what, $info.Category, ('{0} seasons' -f @($info.Seasons).Count))
            if ($tag.Kind -eq 'radioseason') { $meta = @($info.Title, $tag.Title, ('{0} episodes' -f @($script:Files).Count)) }
            $desc = if ($it.Description) { $it.Description } else { $info.Subtitle }
            $img = if ($info.ImageUrl) { $info.ImageUrl } else { $it.ImageUrl }
            Set-Preview $(if ($info.Title) { $info.Title } else { $it.Title }) (($meta | Where-Object { $_ }) -join '   ·   ') $desc $img
            Add-Meta 'Type' $what
            Add-Meta 'Id' $it.Id
            Add-Meta 'Series type' $info.SeriesType
            Add-Meta 'Category' $info.Category
            Add-Meta 'Seasons' @($info.Seasons).Count
            if ($tag.Kind -eq 'radioseason') { Add-Meta 'Season' $tag.Title; Add-Meta 'Episodes' @($script:Files).Count }
        }
        { $_ -in 'series', 'season' } {
            $info = $tag.Info; $it = $tag.Item
            $seasons = @($info.Seasons | Where-Object Name -ne 'ekstramateriale').Count
            $meta = @('Series', $info.Category, ('{0} seasons' -f $seasons))
            if ($tag.Kind -eq 'season') { $meta = @($info.Title, $tag.Title, ('{0} episodes' -f @($script:Files).Count)) }
            $desc = if ($it.Description) { $it.Description } else { $info.Subtitle }
            $img = if ($it.ImageUrl) { $it.ImageUrl } else { $info.ImageUrl }
            Set-Preview $(if ($info.Title) { $info.Title } else { $it.Title }) (($meta | Where-Object { $_ }) -join '   ·   ') $desc $img
            Add-Meta 'Type' 'Series'
            Add-Meta 'Id' $it.Id
            Add-Meta 'Series type' $info.SeriesType
            Add-Meta 'Category' $info.Category
            Add-Meta 'Seasons' $seasons
            if ($tag.Kind -eq 'season') { Add-Meta 'Season' $tag.Title; Add-Meta 'Episodes' @($script:Files).Count }
            if ($null -ne $it.GeoBlocked) { Add-Meta 'Region' $(if ($it.GeoBlocked) { 'Norway only' } else { 'Worldwide' }) }
        }
        'favourites' {
            Set-Preview 'Favourites' ('{0} series and podcasts' -f (Get-FavMap).Count) ('Series and podcasts you starred. Right-click one in any folder (or an episode in the list) > Add to favourites. Right-click a favourite > Follow to download new episodes by themselves.') $null
        }
        'newweek' {
            Set-Preview 'New this week' ('{0} programmes and episodes' -f @($script:Files).Count) ('What came on NRK TV and radio in the last 7 days, newest first. Made from the indexer''s list, so it is as fresh as its last run.') $null
        }
        'expiring' {
            Set-Preview 'Last chance' ('{0} programmes and episodes' -f @($script:Files).Count) ('What leaves NRK TV and radio within 14 days, soonest first: watch or download it before it is gone. Made from the indexer''s list.') $null
        }
        'continue' {
            Set-Preview 'Continue watching' ('{0} item(s)' -f @($script:Files).Count) 'What you started and did not finish, newest first, and the next episode of the series you are watching (looked up in the background).' $null
        }
        'watchlater' {
            Set-Preview 'Watch later' ('{0} item(s)  ·  newest first' -f @($script:Files).Count) 'Programmes and episodes you put aside: right-click one in any list > Watch later. Separate from Favourites (which are whole series).' $null
        }
        'recent' {
            Set-Preview 'Recently played' ('{0} item(s)  ·  newest first' -f @($script:Files).Count) 'What you played last, from any folder: double-click to play it again. Right-click this folder to clear the list.' $null
        }
        'search' {
            Set-Preview $tag.Title ('{0} series (folders)  ·  {1} programmes and episodes (files)' -f $node.Nodes.Count, @($script:Files).Count) 'Best matches first, from the indexer''s list of everything on NRK TV and radio. Right-click this folder to close the search.' $null
        }
        default {
            $series = $node.Nodes.Count
            if ($series -eq 1 -and $node.Nodes[0].Tag.Kind -eq 'placeholder') { $series = 0 }
            $sub = if ($tag.Kind -eq 'group') { '{0} folders' -f $node.Nodes.Count } else { '{0} series (folders)  ·  {1} programmes (files)' -f $series, @($script:Files).Count }
            Set-Preview $tag.Title $sub '' $null
        }
    }
    # no picture from NRK: the TV or radio placeholder
    if (-not $pic.Image) { $k = Get-FolderPlaceholderKind $tag; if ($k) { try { $pic.Image = Get-PlaceholderImage $k } catch { Write-Log DEBUG "Placeholder: $($_.Exception.Message)" } } }
}

function Open-Folder {
    # Called when a tree node is selected: loads it and fills the files list.
    param([System.Windows.Forms.TreeNode] $Node)
    $tag = $Node.Tag
    if (-not $tag -or $tag.Kind -eq 'placeholder') { return }
    Write-Log INFO ("UI: folder {0} '{1}'" -f $tag.Kind, $tag.Title)
    $script:SelectedFile = $null
    $script:Files = @()
    $script:FilesNoSort = ($tag.Kind -in $script:MixedKinds)   # newest first / best match first / soonest gone first
    $loaded = @{ Ok = $false }
    switch ($tag.Kind) {
        'recent' {
            $script:Files = @(Get-RecentFiles)
            Set-Status $(if ($script:Files.Count) { 'Recently played: {0}  ·  newest first  ·  double-click to play again' -f $script:Files.Count } else { 'Nothing played yet' })
        }
        'continue' {
            $script:Files = @(Get-ContinueFiles | Where-Object { Test-ChildAllowed $_ -Quiet })
            Set-Status $(if ($script:Files.Count) { 'Continue watching: {0}  ·  started ones first, then the next episode of series you watch' -f $script:Files.Count } else { 'Nothing started yet: what you stop halfway shows up here' })
            Start-ContinueNextJob
        }
        'watchlater' {
            $script:Files = @(Get-WatchLaterFiles)
            Set-Status $(if ($script:Files.Count) { 'Watch later: {0}  ·  right-click > Remove from Watch later' -f $script:Files.Count } else { 'Nothing here yet: right-click a programme or episode > Watch later' })
        }
        'favourites' {
            $script:Files = @()
            $n = (Get-FavMap).Count
            Set-Status $(if ($n) { '{0} favourite(s)  ·  right-click a series to remove it or follow it' -f $n } else { 'No favourites yet: right-click a series or podcast > Add to favourites' })
        }
        { $_ -in 'newweek', 'expiring' } {
            $res = @{ Files = $null }
            Invoke-Ui "Loading $($tag.Title)" { $res.Files = Get-DatedFiles $(if ($tag.Kind -eq 'newweek') { 'new' } else { 'expiring' }) }
            if ($null -eq $res.Files) { $script:Files = @(); Set-Status "$($tag.Title) is made from the indexer's list: start the Indexer (top bar) to fill it" }
            else {
                $script:Files = @($res.Files)
                Set-Status $(if ($tag.Kind -eq 'newweek') { '{0} programmes and episodes came on NRK in the last 7 days  ·  newest first' -f $script:Files.Count } else { '{0} programmes and episodes leave NRK within 14 days  ·  soonest first' -f $script:Files.Count })
            }
        }
        'search' {
            $script:Files = @($tag.Items)
            Set-Status ("Search '{0}': {1} series in the tree, {2} programmes and episodes in the list" -f $tag.Query, $Node.Nodes.Count, $script:Files.Count)
        }
        'live' {
            Invoke-Ui 'Loading live channels' { $script:Files = @(Get-Cached 'live' { Get-NrkLiveChannels }) }
            if (Test-ChildMode) { $script:Files = @($script:Files | Where-Object { Test-ChildFolder $_ }) }   # (child mode: NRK Super)
            Set-Status ('{0} live channels  ·  double-click to watch' -f @($script:Files).Count)
        }
        { $_ -in 'category', 'letter' } {
            if (Expand-FolderNode $Node) {
                $script:Files = @($tag.Items | Where-Object { $_.Type -eq 'program' })
                Set-Status ('{0}: {1} series in the tree, {2} programmes in the list' -f $tag.Title, $Node.Nodes.Count, @($script:Files).Count)
            }
        }
        'series' {
            if (Expand-FolderNode $Node) {
                $Node.Expand()
                # A series holds no files itself: open its first season (not when stepping back via the breadcrumb)
                if (-not $script:CrumbNav -and $Node.Nodes.Count -gt 0 -and $Node.Nodes[0].Tag.Kind -eq 'season') { $folderTree.SelectedNode = $Node.Nodes[0]; return }
            }
        }
        'radiolive' {
            Invoke-Ui 'Loading live radio channels' { $script:Files = @(Get-Cached 'radio:live' { Get-NrkLiveChannels -Medium radio }) }
            if (Test-ChildMode) { $script:Files = @($script:Files | Where-Object { Test-ChildFolder $_ }) }   # (child mode: Radio Super)
            Set-Status ('{0} radio channels  ·  double-click to listen' -f @($script:Files).Count)
        }
        { $_ -in 'radiocategory', 'radioletter' } {
            if (Expand-FolderNode $Node) {
                $script:Files = @($tag.Items | Where-Object { $_.Type -eq 'audio' })
                Set-Status ('Radio - {0}: {1} series/podcasts in the tree, {2} recordings in the list' -f $tag.Title, $Node.Nodes.Count, @($script:Files).Count)
            }
        }
        'radioseries' {
            if (Expand-FolderNode $Node) {
                $Node.Expand()
                if (-not $script:CrumbNav -and $Node.Nodes.Count -gt 0 -and $Node.Nodes[0].Tag.Kind -eq 'radioseason') { $folderTree.SelectedNode = $Node.Nodes[0]; return }
            }
        }
        'radioseason' {
            Invoke-Ui "Loading radio episodes for $($tag.Item.Id) / $($tag.Season.Name)" {
                $sea = $tag.Season
                $title = if ($tag.Info.Title) { $tag.Info.Title } else { $tag.Item.Title }
                $script:Files = @(Get-Cached "reps:$($sea.Href)" { Get-NrkRadioEpisodes -Href $sea.Href -Kind $tag.Item.Kind -SeriesId $tag.Item.Id -SeriesTitle $title -Newest:$sea.Newest })
                $loaded.Ok = $true
                $more = $script:RadioMore[[string]$sea.Href]
                if ($more) { $script:Files += [pscustomobject]@{ Type = 'more'; Id = 'more'; Title = 'Load more episodes...'; Description = 'Double-click to load the next episodes'; Playable = $true; Downloadable = $false; Next = $more; Href = [string]$sea.Href; Tag = $tag; SeriesTitle = $title } }
                Set-Status ('{0} - {1}: {2} episodes  ·  double-click to listen' -f $title, $tag.Title, @($script:Files).Count)
            }
        }
        'season' {
            Invoke-Ui "Loading episodes for $($tag.Item.Id) season $($tag.Season)" {
                $eps = @(Get-Cached "eps:$($tag.Item.Id):$($tag.Season)" { Get-NrkSeasonEpisodes -SeriesId $tag.Item.Id -Season $tag.Season })
                $script:Files = @(foreach ($ep in $eps) { New-EpisodeFile $ep $tag.Item $tag.Season })
                $loaded.Ok = $true
                Set-Status ('{0} - {1}: {2} episodes' -f $tag.Item.Title, $tag.Title, @($script:Files).Count)
            }
        }
    }
    if ($loaded.Ok -and $tag.Kind -in 'season', 'radioseason' -and @($script:Files).Count -eq 0) { Hide-EmptyNode $Node }
    Show-Files
    Show-FolderPreview
    Update-Actions; Update-Crumb
    try { Request-FilesPrefetch } catch { Write-Log DEBUG "Prefetch: $($_.Exception.Message)" }
}

function Show-FileDetails {
    param($File)
    $script:SelectedFile = $File
    Clear-Meta
    Show-Schedule ($File.Type -eq 'live')
    if ($File.Medium -eq 'radio') { Show-RadioFileDetails $File; return }
    $kind = switch ($File.Type) { 'program' { 'Programme' } 'episode' { 'Episode' } 'live' { 'Live channel' } default { $File.Type } }
    $meta = switch ($File.Type) {
        'episode' { (@($File.SeriesItem.Title, $(if ($File.Season -eq 'ekstramateriale') { 'Extra material' } else { "Season $($File.Season)" }), $File.Duration) | Where-Object { $_ }) -join '   ·   ' }
        default { $kind }
    }
    $img = if ($File.ImageUrl) { $File.ImageUrl } elseif ($File.SeriesItem) { $File.SeriesItem.ImageUrl } else { $null }
    Set-Preview $File.Title $meta $File.Description $img
    Add-Meta 'Type' $kind
    if ($File.Type -eq 'episode') { Add-Meta 'Series' $File.SeriesItem.Title; Add-Meta 'Season' $File.Season }
    if ($File.Type -ne 'live') { Add-Meta 'Id' $File.Id }   # (live: shown as Channel id)
    if ($null -ne $File.GeoBlocked) { Add-Meta 'Region' $(if ($File.GeoBlocked) { 'Norway only' } else { 'Worldwide' }) }
    Add-Meta 'Available until' (Format-AvailableUntil $File)
    Update-Actions; Update-Crumb
    if ($File.Type -eq 'live') { Show-LiveDetails $File; Update-Actions; return }
    if (-not $File.Downloadable) { Add-Meta 'Note' 'Not a programme or episode'; return }

    Invoke-Ui "Loading details for $($File.Id)" {
        $info = Get-NrkProgramInfo -ProgramId $File.Id
        Add-Meta 'Year' $info.Year
        Add-Meta 'Duration' $info.Duration
        Add-Meta 'Age rating' $info.AgeRating
        Add-Meta 'Category' $info.Category
        Add-Meta 'Original title' $info.OriginalTitle
        Add-Meta 'Playable' $(if ($info.Playability -eq 'playable') { 'Yes' } else { "No - $($info.NotPlayable)" })
        if ($File.Type -eq 'program') { $pMeta.Text = (@($info.Category, $info.Year, $info.Duration, $info.AgeRating) | Where-Object { $_ }) -join '   ·   ' }
        if (-not $img -and $info.ImageUrl) { $pic.Image = Get-NrkImage $info.ImageUrl }
        if (-not $File.AvailableFrom -and -not $File.AvailableTo) {
            # (programmes from a category page may not say how long they are there: NRK's player data does)
            try {
                $md = Invoke-NrkApi ('/playback/metadata/program/{0}' -f [uri]::EscapeDataString($File.Id))
                Add-RightsInfo $File $md
                Add-Meta 'Available until' (Format-AvailableUntil $File)
            } catch { Write-Log DEBUG "Availability of $($File.Id): $($_.Exception.Message)" }
        }
    }
    Update-Actions
}

function Show-RadioFileDetails {
    param($File)
    Show-Schedule ($File.Type -eq 'radiolive')
    $kind = if ($File.Type -eq 'radiolive') { 'Live radio' } elseif ($File.Kind -eq 'podcast') { 'Podcast episode' } else { 'Radio programme' }
    $meta = if ($File.Type -eq 'radiolive') { 'Live radio' } else { (@($File.SeriesTitle, $File.Date, $File.Duration) | Where-Object { $_ }) -join '   ·   ' }
    if (-not $meta) { $meta = $kind }
    Set-Preview $File.Title $meta $File.Description $File.ImageUrl
    Add-Meta 'Type' $kind
    if ($File.SeriesTitle) { Add-Meta $(if ($File.Kind -eq 'podcast') { 'Podcast' } else { 'Series' }) $File.SeriesTitle }
    Add-Meta 'Date' $File.Date
    Add-Meta 'Duration' $File.Duration
    if (-not (Test-FileAvailable $File)) { Add-Meta 'Availability' $File.Available }
    Add-Meta 'Available until' (Format-AvailableUntil $File)
    Add-Meta 'Id' $File.Id
    if ($null -ne $File.GeoBlocked) { Add-Meta 'Region' $(if ($File.GeoBlocked) { 'Norway only' } else { 'Worldwide' }) }
    Add-Meta 'Plays in' 'Audio bar (bottom of the window)'
    Update-Actions; Update-Crumb
    if ($File.Type -eq 'radiolive') { Show-LiveDetails $File; Update-Actions }
}

function Get-FolderTag {
    $n = $folderTree.SelectedNode
    if ($n) { return $n.Tag }
    return $null
}

function Get-PlayTarget {
    $f = $script:SelectedFile
    if ($f) {
        switch ($f.Type) {
            'live'    { return [pscustomobject]@{ Url = $f.WebUrl; Title = '{0}  ·  LIVE' -f $f.Title; File = $f } }
            { $_ -in 'episode', 'program' } { return (New-VideoTarget $f) }
            { $_ -in 'radiolive', 'audio' } { if ($f.Playable) { return [pscustomobject]@{ Url = $f.WebUrl; Title = $f.Title; Audio = $f } } }
        }
        return $null
    }
    # a radio season: its first episode
    $tag = Get-FolderTag
    if ($tag -and $tag.Kind -eq 'radioseason') {
        $first = $script:Files | Where-Object { $_.Playable -and (Test-FileAvailable $_) } | Select-Object -First 1
        if ($first) { return [pscustomobject]@{ Url = $first.WebUrl; Title = $first.Title; Audio = $first } }
    }
    # no file selected: in a season, play its first available episode
    if ($tag -and $tag.Kind -eq 'season') {
        $first = $script:Files | Where-Object { Test-FileAvailable $_ } | Select-Object -First 1
        if ($first) { return (New-VideoTarget $first) }
    }
    return $null
}

function New-VideoTarget($File) {
    $title = if ($File.Type -eq 'episode' -and $File.SeriesItem) { '{0}  ·  {1}' -f $File.SeriesItem.Title, $File.Title } else { $File.Title }
    return [pscustomobject]@{ Url = Get-NrkPlayUrl $File.Id; Title = $title; File = $File }
}

# ---- previous / next episode in the player window (the list the video was started from)
$script:VideoQueue = @()
$script:VideoIndex = -1

function Set-VideoQueue($File) {
    $script:VideoQueue = @(); $script:VideoIndex = -1
    $script:VideoQueueNode = $folderTree.SelectedNode   # the folder the queue came from (for "continue where you left off")
    if (-not $File -or $File.Type -notin 'episode', 'program') { return }
    if ((Get-FolderTag).Kind -in $script:MixedKinds) { return }   # a mixed list: no "next episode"
    $q = @($script:Files | Where-Object { $_.Type -in 'episode', 'program' -and (Test-FileAvailable $_) })
    for ($i = 0; $i -lt $q.Count; $i++) { if ([object]::ReferenceEquals($q[$i], $File)) { $script:VideoIndex = $i; break } }
    if ($script:VideoIndex -ge 0 -and $q.Count -gt 1) { $script:VideoQueue = $q } else { $script:VideoIndex = -1 }
}

function Update-PlayerNav {
    $pw = $script:PlayerWin
    if (-not $pw -or $pw.Form.IsDisposed) { return }
    $q = $script:VideoQueue; $i = $script:VideoIndex
    $on = (@($q).Count -gt 1 -and $i -ge 0)
    $pw.Prev.Visible = ($on -and -not $pw.Mini); $pw.Next.Visible = ($on -and -not $pw.Mini)
    if (-not $on) { return }
    $pw.Prev.Enabled = ($i -gt 0); $pw.Next.Enabled = ($i -lt $q.Count - 1)
    $pw.Tips.SetToolTip($pw.Prev, $(if ($i -gt 0) { "Previous: $($q[$i - 1].Title)" } else { 'This is the first one' }))
    $pw.Tips.SetToolTip($pw.Next, $(if ($i -lt $q.Count - 1) { "Next: $($q[$i + 1].Title)" } else { 'This is the last one' }))
}

function Start-PlayerStep([int] $Step) {
    $q = $script:VideoQueue
    $i = $script:VideoIndex + $Step
    if ($i -lt 0 -or $i -ge @($q).Count) { return }
    $script:VideoIndex = $i
    $f = $q[$i]
    Write-Log INFO ("Player: {0} -> {1}" -f $(if ($Step -gt 0) { 'next' } else { 'previous' }), $f.Title)
    # keep the main window's list in step (only when it still shows that list)
    foreach ($row in $itemsList.Items) {
        if ([object]::ReferenceEquals($row.Tag, $f)) { $itemsList.SelectedItems.Clear(); $row.Selected = $true; $row.Focused = $true; $row.EnsureVisible(); break }
    }
    Start-Player -Target (New-VideoTarget $f) -FromQueue
}

function Get-DownloadUrl {
    param([ValidateSet('auto', 'episode', 'season', 'series')] [string] $Scope = 'auto')
    $f = $script:SelectedFile
    $tag = Get-FolderTag
    $series = if ($f -and $f.Type -eq 'episode') { $f.SeriesItem } elseif ($tag -and $tag.Kind -in 'series', 'season') { $tag.Item } else { $null }
    $season = if ($f -and $f.Type -eq 'episode') { $f.Season } elseif ($tag -and $tag.Kind -eq 'season') { $tag.Season } else { $null }
    if ($f -and $f.Medium -eq 'radio') { return $f.WebUrl }
    if (-not $f -and $tag -and $tag.Kind -in 'radioseries', 'radioseason') { return $tag.Info.WebUrl }
    switch ($Scope) {
        'episode' { if ($f -and $f.Type -eq 'episode') { return $f.WebUrl } }
        'season'  { if ($series -and $season) { return '{0}/sesong/{1}' -f $series.WebUrl, $season } }
        'series'  { if ($series) { return $series.WebUrl } }
        'auto' {
            if ($f -and $f.Type -eq 'program') { return $f.WebUrl }
            if ($f -and $f.Type -eq 'episode') { return $f.WebUrl }
            if ($series -and $season) { return '{0}/sesong/{1}' -f $series.WebUrl, $season }
            if ($series) { return $series.WebUrl }
        }
    }
    return $null
}

function Update-Actions {
    $f = $script:SelectedFile
    $tag = Get-FolderTag
    $inSeries = [bool]($tag -and $tag.Kind -in 'series', 'season')
    $btnPlay.Enabled = [bool](Get-PlayTarget)
    $btnDownload.Enabled = [bool](($f -and $f.Downloadable) -or (-not $f -and ($inSeries -or ($tag -and $tag.Kind -in 'radioseason', 'radioseries'))) -or ($itemsList.SelectedItems.Count -gt 1))
    $btnOpenWeb.Enabled = [bool](($f -and $f.WebUrl) -or (-not $f -and ($inSeries -or ($tag -and $tag.Kind -in 'radioseries', 'radioseason'))))
    $btnCopyUrl.Enabled = $btnOpenWeb.Enabled
    $btnCast.Enabled = [bool]((Test-CastableFile $f) -or $script:Cast.Session)
    $pt = if ($f -and $f.Type -eq 'live') { 'Watch live' }
          elseif ($f -and $f.Type -eq 'radiolive') { 'Listen live' }
          elseif ($f -and $f.Type -eq 'audio') { 'Listen' }
          elseif (-not $f -and $tag -and $tag.Kind -eq 'radioseason') { 'Listen' }
          elseif ($f -and $f.Type -eq 'episode') { 'Play episode' }
          elseif (-not $f -and $tag -and $tag.Kind -eq 'season') { 'Play season' }
          else { 'Play' }
    $live = [bool]($f -and $f.Type -in 'live', 'radiolive')
    Set-IconText $btnPlay 'play' $pt $(if ($live) { [string][char]0x25CF } else { [string][char]0x25B6 }) -Primary   # (2.9.2: the icon in the chosen look)
    $btnPlay.Width = if ($pt.Length -gt 5) { 150 } else { 120 }
    $btnBack.Enabled = [bool]($f -or ($folderTree.SelectedNode -and $folderTree.SelectedNode.Parent))
}

function Show-LiveDetails {
    # Now / next and today's schedule for a live channel (EPG is not cached: it changes)
    param($Item)
    Add-Meta 'Channel id' $Item.Id
    if ($Item.District) { Add-Meta 'Kind' 'Regional NRK1' }
    $hdrSchedule.Text = 'Schedule today  (loading...)'
    if ($script:EpgJob) { $script:EpgJob.Canceled = $true }
    $script:EpgJob = Start-ApiJob "Schedule for $($Item.Id)" { param($it) ,@(Get-NrkEpg -ChannelId $it.Id) } {
        param($epg, $Item)
        $script:EpgJob = $null
        if (-not $script:SelectedFile -or $script:SelectedFile.Id -ne $Item.Id -or $script:SelectedFile.Type -ne 'live') { return }   # (another file was picked meanwhile)
        Show-LiveSchedule $Item @($epg)
    } { param($err, $Item) $script:EpgJob = $null; Write-LogException $err "Loading schedule for $($Item.Id)"; $hdrSchedule.Text = 'Schedule today  (not available)'; Set-Status "Schedule for $($Item.Title) failed: $($err.Exception.Message)  (details in Logs)" } $Item
}

function Show-LiveSchedule($Item, $epg) {
    & {
        $now = Get-Date
        $cur = $epg | Where-Object { $_.Start -le $now -and $_.End -gt $now } | Select-Object -First 1
        $next = $epg | Where-Object { $_.Start -gt $now } | Select-Object -First 1
        if ($cur) {
            Add-Meta 'Now' ('{0:HH:mm}  {1}' -f $cur.Start, $cur.Title)
            $pMeta.Text = 'LIVE   ·   Now: {0}   ·   until {1:HH:mm}' -f $cur.Title, $cur.End
            $pDesc.Text = $cur.Description
        } else {
            $pMeta.Text = 'LIVE'
        }
        if ($next) { Add-Meta 'Next' ('{0:HH:mm}  {1}' -f $next.Start, $next.Title) }
        $scheduleList.BeginUpdate(); $scheduleList.Items.Clear()
        foreach ($e in $epg) {
            if ($e.End -lt $now.AddHours(-2)) { continue }   # keep the list short: from 2 h ago
            $isNow = ($cur -and $e -eq $cur)
            $second = if ($isNow) { 'on now' } else { '{0} min' -f [Math]::Round($e.Duration.TotalMinutes) }
            [void](Add-DarkListRow $scheduleList ('{0:HH:mm}  {1}' -f $e.Start, $e.Title) $second $e $(if ($isNow) { 'live' } else { 'episode' }) -Dim:($e.End -le $now))
        }
        $scheduleList.EndUpdate()
        $hdrSchedule.Text = 'Schedule today  ({0})' -f $scheduleList.Items.Count
        Set-Status ("{0}: {1}" -f $Item.Title, $(if ($cur) { "now showing $($cur.Title)" } else { 'no schedule information' }))
    }
}

# ---- player window ----------------------------------------------------------------
# Play opens NRK's own player page (tv.nrk.no) in a separate window. A small script is
# injected into the page that finds the video player, makes it fill the window and hides
# the rest of the site ("player only"). "Show full page" turns that off again, e.g. for a
# login prompt, age check or cookie choice that the player-only view would hide.

$script:PlayerOnly = $true
$script:PlayerWin  = $null

$script:PlayerOnlyJs = @'
(() => {
  if (window.__nrkbIso) return;
  if (!/(^|\.)nrk\.no$/.test(location.hostname)) return;
  if (location.pathname.indexOf('/__nrkb/') === 0) return;   // our own built-in player page
  const S = window.__nrkbIso = { enabled: true, root: null, clicks: 0, lastClick: 0, path: location.pathname };
  // Until the player is found and isolated, show a black "Loading player" screen instead of
  // the NRK page building up. Fallback: show the page if no player turns up in time.
  const COVER_ID = 'nrkb-cover';
  function cover() {
    if (document.getElementById(COVER_ID)) return;
    // injected at document creation: there is no <html> element yet, so wait for it
    if (!document.documentElement) {
      const mo = new MutationObserver(() => { if (document.documentElement) { mo.disconnect(); cover(); } });
      mo.observe(document, { childList: true });
      return;
    }
    const st = document.createElement('style'); st.id = COVER_ID;
    st.textContent = 'html{background:#000 !important} body{visibility:hidden !important}' +
      'html::before{content:"Loading player\\2026";position:fixed;left:0;top:0;right:0;bottom:0;display:flex;align-items:center;' +
      'justify-content:center;color:#8a949b;font:16px "Segoe UI",sans-serif;visibility:visible;z-index:2147483647;pointer-events:none}';
    (document.head || document.documentElement).appendChild(st);
    S.coveredAt = Date.now();
  }
  function uncover(why) {
    const st = document.getElementById(COVER_ID);
    if (!st) return;
    st.remove();
    post({ type: 'reveal', why, ms: Date.now() - (S.coveredAt || Date.now()), url: location.href });
  }
  cover();
  const STYLE_ID = 'nrkb-player-only';
  const CSS = `
    html, body { background:#000 !important; overflow:hidden !important; }
    body * { visibility:hidden !important; }
    [data-nrkb-player], [data-nrkb-player] * { visibility:visible !important; }
    [data-nrkb-anc] { transform:none !important; filter:none !important; contain:none !important;
                      perspective:none !important; overflow:visible !important; }
    [data-nrkb-player] { position:fixed !important; left:0 !important; top:0 !important; right:0 !important; bottom:var(--nrkb-ch, 0px) !important;
      width:100vw !important; height:calc(100vh - var(--nrkb-ch, 0px)) !important; max-width:none !important; max-height:none !important;
      margin:0 !important; padding:0 !important; border-radius:0 !important; transform:none !important;
      z-index:2147483646 !important; background:#000 !important; }
    [data-nrkb-player] video { width:100% !important; height:100% !important; object-fit:contain !important; }
    [data-nrkb-chapters] { position:fixed !important; left:0 !important; right:0 !important; bottom:0 !important; top:auto !important;
      width:100vw !important; max-width:none !important; margin:0 !important; box-sizing:border-box !important;
      overflow-x:auto !important; overflow-y:hidden !important; transform:none !important;
      z-index:2147483646 !important; background:#000 !important; padding:6px 8px !important; }
    [data-nrkb-chapters], [data-nrkb-chapters] * { visibility:visible !important; }`;
  const post = m => { try { window.chrome.webview.postMessage(JSON.stringify(m)); } catch (e) {} };

  // NRK's newer player renders inside web components (shadow DOM), where querySelectorAll
  // cannot see the <video>: look inside open shadow roots too.
  function deepAll(sel, root = document, out = []) {
    root.querySelectorAll(sel).forEach(e => out.push(e));
    root.querySelectorAll('*').forEach(e => { if (e.shadowRoot) deepAll(sel, e.shadowRoot, out); });
    return out;
  }
  function videos() {
    let vs = [...document.querySelectorAll('video')];
    if (!vs.length) vs = deepAll('video');
    return vs.map(v => [v, v.getBoundingClientRect()]).filter(([, r]) => r.width > 80 && r.height > 45)
      .sort((a, b) => b[1].width * b[1].height - a[1].width * a[1].height);
  }
  // one step up the page, also out of a shadow root to the element that hosts it
  const up = el => el.parentElement || (el.parentNode && el.parentNode.host) || null;
  function findRoot() {
    // The biggest visible <video>, then climb while the parent is about the same size:
    // that container also holds NRK's controls, subtitles and overlays.
    const vids = videos();
    let video, r;
    if (vids.length) { [video, r] = vids[0]; }
    else {
      // a player in a frame: the frame itself is the player
      const fr = [...document.querySelectorAll('iframe')].map(f => [f, f.getBoundingClientRect()])
        .filter(([f, b]) => b.width > 200 && b.height > 110 && /player|psapi|nrk/i.test(f.src || '') && !/ads?\.|doubleclick/i.test(f.src || ''))
        .sort((a, b) => b[1].width * b[1].height - a[1].width * a[1].height)[0];
      if (!fr) return null;
      return fr[0];
    }
    let root = video;
    for (let el = up(video); el && el !== document.body && el !== document.documentElement; el = up(el)) {
      const b = el.getBoundingClientRect();
      // NRK's controls and subtitles sit on top of the video, so the player is (about) the
      // video's own size; a bigger box also holds page content (titles, buttons below it).
      if (b.width <= r.width + 24 && b.height <= r.height + 24) root = el; else break;
    }
    // our page-level CSS only reaches the normal page: use the outermost shadow host
    while (root.getRootNode && root.getRootNode() !== document) { const h = root.getRootNode().host; if (!h) break; root = h; }
    return root;
  }
  // Chapters ("1. Alex innleder", "2. Jingle ...") sit in a row just under the player. Keep
  // that row, docked under the video, so you can still jump between them.
  const CHAPTER_RE = /^\s*\d{1,3}\.\s+\S/;
  function findChapters(root) {
    const pr = root.getBoundingClientRect();
    const btns = deepAll('button, a, [role="button"], li').filter(el => {
      if (root.contains(el)) return false;
      const b = el.getBoundingClientRect();
      if (b.width < 30 || b.height < 16 || b.height > 120) return false;
      if (b.top < pr.bottom - 8 || b.top > pr.bottom + 220) return false;
      return CHAPTER_RE.test(labelOf(el));
    });
    if (btns.length < 2) return null;
    // the smallest box under the player that holds all of them
    let box = btns[0];
    const holdsAll = el => btns.every(b => el.contains(b) || (el.shadowRoot && el.shadowRoot.contains(b)));
    while (box && !holdsAll(box)) box = up(box);
    if (!box || box === document.body || box === document.documentElement) return null;
    // then up while it is still just that row (not the page below it)
    for (let el = up(box); el && el !== document.body && el !== document.documentElement; el = up(el)) {
      const b = el.getBoundingClientRect();
      if (b.height <= 160 && !el.contains(root) && labelOf(el).length < 2000) box = el; else break;
    }
    while (box.getRootNode && box.getRootNode() !== document) { const h = box.getRootNode().host; if (!h || h.contains(root)) break; box = h; }
    if (box.contains(root) || box.getBoundingClientRect().height > 160) return null;
    return box;
  }
  function placeChapters() {
    const c = S.chapters;
    const h = (c && c.isConnected) ? Math.ceil(c.getBoundingClientRect().height) : 0;
    document.documentElement.style.setProperty('--nrkb-ch', h + 'px');
  }
  window.addEventListener('resize', () => { if (S.root) placeChapters(); });
  function clear() {
    document.getElementById(STYLE_ID)?.remove();
    document.querySelectorAll('[data-nrkb-player]').forEach(e => e.removeAttribute('data-nrkb-player'));
    document.querySelectorAll('[data-nrkb-anc]').forEach(e => e.removeAttribute('data-nrkb-anc'));
    document.querySelectorAll('[data-nrkb-chapters]').forEach(e => e.removeAttribute('data-nrkb-chapters'));
    if (document.documentElement) document.documentElement.style.removeProperty('--nrkb-ch');
    S.root = null; S.chapters = null;
  }
  // Programme pages (e.g. /program/KOID21003526) show a "Begynn å se" button first; the
  // player only appears after it is pressed. Press it for the user (once per page).
  const START_RE = /^(begynn å se|fortsett å se|se fra start|se fra begynnelsen|spill av|se direkte|se nå|start avspilling)(?:\s|$)/i;
  function visible(el) { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; }
  function labelOf(el) {
    const t = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
    return t || (el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title')) || '');
  }
  function pressStart() {
    if (location.pathname !== S.path) { S.path = location.pathname; S.clicks = 0; }   // new page inside NRK's single-page app
    // the page's own scripts must be running first, or the click does nothing; then retry every second
    if (document.readyState === 'loading') return;
    if (S.clicks >= 5 || Date.now() - S.lastClick < 1000) return;
    // Prefer "Begynn/Fortsett å se" over generic play buttons; never start a trailer.
    const rank = l => /^(begynn|fortsett) å se/i.test(l) ? 0 : /^se fra/i.test(l) ? 1 : 2;
    const btn = [...document.querySelectorAll('button, a, [role="button"]')]
      .filter(visible)
      .map(el => [el, labelOf(el)])
      .filter(([, l]) => START_RE.test(l) && !/trailer|smakebit/i.test(l))
      .sort((a, b) => rank(a[1]) - rank(b[1]))
      .map(([el]) => el)[0];
    if (!btn) return;
    S.clicks++; S.lastClick = Date.now();
    post({ type: 'autostart', label: labelOf(btn).slice(0, 60), url: location.href });
    btn.click();
  }

  function markAncestors(el) { for (let a = el.parentElement; a && a !== document.body && a !== document.documentElement; a = a.parentElement) a.setAttribute('data-nrkb-anc', ''); }
  function apply() {
    if (S.root && S.root.isConnected) {
      // chapters often load after the player: pick them up when they appear
      if (S.enabled && !(S.chapters && S.chapters.isConnected) && Date.now() - (S.chLook || 0) > 1000) {
        S.chLook = Date.now();
        const c = findChapters(S.root);
        if (c) { S.chapters = c; c.setAttribute('data-nrkb-chapters', ''); markAncestors(c); placeChapters(); post({ type: 'chapters', n: c.querySelectorAll('button, a, [role="button"]').length, url: location.href }); }
        else if (S.chapters) { S.chapters = null; placeChapters(); }
      }
      return;
    }
    const root = findRoot();
    if (!root) { pressStart(); return; }
    if (!S.enabled) return;
    // find the chapter row before our CSS moves the player (it is located from the page layout)
    const chapters = findChapters(root);
    clear();
    root.setAttribute('data-nrkb-player', '');
    markAncestors(root);
    if (chapters) { chapters.setAttribute('data-nrkb-chapters', ''); markAncestors(chapters); }
    const st = document.createElement('style'); st.id = STYLE_ID; st.textContent = CSS;
    (document.head || document.documentElement || document).appendChild(st);
    S.root = root; S.chapters = chapters; S.chLook = Date.now();
    placeChapters();
    uncover('player');
    post({ type: 'isolated', tag: root.tagName, cls: String(root.className || '').slice(0, 120), chapters: !!chapters, url: location.href });
  }
  // The player often stops at its poster with a big round play button instead of starting.
  // Start it for the user, one step at a time until the video plays: press that button,
  // then call play(), then ask the app for a real (trusted) mouse click on the player.
  function mainVideo() { const v = videos()[0]; return v ? v[0] : null; }
  function ensurePlaying() {
    const key = location.pathname + location.search;
    if (S.playKey !== key) { S.playKey = key; S.played = false; S.since = 0; S.stage = 0; S.hooked = null; }
    if (S.played) return;
    const v = mainVideo();
    if (!v) return;
    if (S.hooked !== v && v.addEventListener) { S.hooked = v; v.addEventListener('playing', () => { S.played = true; }, { once: true }); }
    if (!v.paused || v.currentTime > 0.5) { S.played = true; return; }
    const now = Date.now();
    if (!S.since) { S.since = now; return; }
    const waited = now - S.since;
    const r = v.getBoundingClientRect();
    if (S.stage === 0 && waited > 400) {           // 1) the overlay play button
      S.stage = 1;
      const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
      const btn = [...document.querySelectorAll('button, [role="button"]')]
        .filter(el => { const b = el.getBoundingClientRect(); return b.width > 24 && b.height > 24 &&
          b.left < cx && b.right > cx && b.top < cy && b.bottom > cy; })
        .filter(el => { const l = (labelOf(el) + ' ' + String(el.className || '')).toLowerCase();
          return /spill|play|start|fortsett|begynn|se nå|se direkte/.test(l) && !/trailer|smakebit|pause|fra start|fra begynnelsen/.test(l); })
        .sort((a, b) => { const A = a.getBoundingClientRect(), B = b.getBoundingClientRect(); return B.width * B.height - A.width * A.height; })[0];
      if (btn) { post({ type: 'autoplay', step: 'button', label: labelOf(btn).slice(0, 60), url: location.href }); btn.click(); return; }
    }
    if (S.stage <= 1 && waited > 1200) {           // 2) start the video element directly
      S.stage = 2;
      post({ type: 'autoplay', step: 'play()', url: location.href });
      try { const pr = v.play(); if (pr && pr.catch) pr.catch(e => post({ type: 'autoplay', step: 'play() refused: ' + e.name, url: location.href })); } catch (e) { }
      return;
    }
    if (S.stage === 2 && waited > 2200) {          // 3) a real click in the middle of the player
      S.stage = 3;
      post({ type: 'click', x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2), url: location.href });
      return;
    }
    if (S.stage === 3 && waited > 7000) { S.stage = 4; post({ type: 'autoplay', step: 'gave up', url: location.href }); }
  }

  window.__nrkbSetPlayerOnly = on => { S.enabled = !!on; if (S.enabled) { S.root = null; apply(); } else { clear(); uncover('full page'); } };
  // check often while the page is starting up, then calm down
  let lastTick = 0;
  const tick = () => { const now = Date.now(); if (now - lastTick < 100) return; lastTick = now; apply(); ensurePlaying(); };
  const fast = setInterval(tick, 150);
  setTimeout(() => { clearInterval(fast); setInterval(tick, 600); }, 15000);
  try { new MutationObserver(() => { if (!S.root || !S.played) tick(); }).observe(document, { childList: true, subtree: true }); } catch (e) { }
  document.addEventListener('canplay', tick, true);   // media events don't bubble, but they can be captured
  setTimeout(() => uncover('no player after 8 s'), 8000);
  setTimeout(() => {
    if (S.enabled && !S.root) {
      // what the page has, for the log (helps when NRK changes its player)
      let hosts = 0; try { document.querySelectorAll('*').forEach(e => { if (e.shadowRoot) hosts++; }); } catch (e) { }
      post({ type: 'no-video', url: location.href, videos: deepAll('video').length, iframes: document.querySelectorAll('iframe').length, shadowHosts: hosts });
    }
  }, 20000);
  // Keys never reach the WinForms window while the page has focus; forward the useful ones.
  window.addEventListener('keydown', e => { if (e.key === 'Escape' || e.key === 'F11') post({ type: 'key', key: e.key }); }, true);
  // play/pause/mute state for the tray menu
  for (const n of ['play', 'pause', 'volumechange']) {
    document.addEventListener(n, e => { const v = e.target; if (v && v.tagName === 'VIDEO') post({ type: 'vstate', paused: v.paused, muted: v.muted }); }, true);
  }
})();
'@

function Send-PlayerOnlyMode {
    $pw = $script:PlayerWin
    if (-not $pw -or -not $pw.WebView.CoreWebView2) { return }
    $flag = if ($script:PlayerOnly) { 'true' } else { 'false' }
    try { [void]$pw.WebView.CoreWebView2.ExecuteScriptAsync("window.__nrkbSetPlayerOnly && window.__nrkbSetPlayerOnly($flag)") } catch { }
    Set-IconText $pw.BtnMode 'window' $(if ($script:PlayerOnly) { 'Show full page' } else { 'Player only' })
}

# ---- built-in video player ---------------------------------------------------------------
# Programmes and episodes play in our own page instead of NRK's web page: the stream address,
# subtitles and chapters come from NRK's playback API (the same data NRK's own player loads),
# and hls.js plays the stream. Nothing has to be hidden or clicked, so NRK redesigning its
# website can't break it. The page is served from memory at tv.nrk.no/__nrkb/, so the video
# streams accept it like NRK's own player. Protected (DRM) or unusual streams, and live
# channels, use the NRK web page as before ("Open NRK page" switches any time).
$script:VideoPlayerUrl = 'https://tv.nrk.no/__nrkb/video.html'

function ConvertFrom-IsoDuration([string] $Value) {
    if (-not $Value) { return 0 }
    try { return [Xml.XmlConvert]::ToTimeSpan($Value).TotalSeconds } catch { return 0 }
}

function Get-NrkVideoStream {
    # The playable stream of a programme/episode: url, subtitles, chapters, poster - or why not.
    param([Parameter(Mandatory = $true)] [string] $Id, [string] $Kind = 'program', [string] $Manifest = '')
    $m = if ($Manifest) { Invoke-NrkApi $Manifest } else { Invoke-NrkApi ('/playback/manifest/{0}/{1}' -f $Kind, [uri]::EscapeDataString($Id)) }
    $pl = Get-Prop $m 'playable'
    $assets = @(Get-Prop $pl 'assets') | Where-Object { $_ }
    $asset = @($assets | Where-Object { -not (Get-Prop $_ 'encrypted') -and ((Get-Prop $_ 'mimeType') -match 'mpegurl' -or (Get-Prop $_ 'url') -match '\.m3u8') }) | Select-Object -First 1
    $encrypted = (-not $asset) -and [bool]@($assets | Where-Object { Get-Prop $_ 'encrypted' }).Count
    $reason = $null
    $np = Get-Prop $m 'nonPlayable'
    if ($np) { $reason = (@((Get-Prop $np 'endUserMessage'), (Get-Prop $np 'reason')) | Where-Object { $_ }) -join ' - ' }
    $subs = @(foreach ($s in @(Get-Prop $pl 'subtitles')) {
        if (-not $s) { continue }
        $u = [string](Get-Prop $s 'webVtt'); if (-not $u) { continue }
        [ordered]@{ url = $u; label = [string]$(if (Get-Prop $s 'label') { Get-Prop $s 'label' } else { Get-Prop $s 'language' }); language = [string](Get-Prop $s 'language'); default = [bool](Get-Prop $s 'defaultOn') }
    })
    # chapters, poster and titles are in the metadata (optional: playing works without them)
    $chapters = @(); $poster = $null; $title = $null; $next = $null; $versions = @()
    try {
        $md = Invoke-NrkApi ('/playback/metadata/{0}/{1}' -f $Kind, [uri]::EscapeDataString($Id))
        $pre = Get-Prop $md 'preplay'
        $chapters = @(foreach ($ip in @(Get-Prop $pre 'indexPoints')) { if ($ip) { [ordered]@{ title = [string](Get-Prop $ip 'title'); start = [double](ConvertFrom-IsoDuration (Get-Prop $ip 'startPoint')) } } })
        $imgs = @(Get-Prop (Get-Prop $pre 'poster') 'images') | Where-Object { $_ } | Sort-Object { [int](Get-Prop $_ 'pixelWidth') }
        $poster = [string](@($imgs | Where-Object { [int](Get-Prop $_ 'pixelWidth') -ge 960 }) + @($imgs) | Select-Object -First 1 | ForEach-Object { Get-Prop $_ 'url' })
        $title = [string](Get-Prop (Get-Prop $pre 'titles') 'title')
        # other versions NRK lists for it (sign language, ...): "Version" in the player's Audio menu
        $versions = @(foreach ($mf in @(Get-Prop (Get-Prop $md '_links') 'manifests')) {
            $nm = [string](Get-Prop $mf 'name'); $hr = [string](Get-Prop $mf 'href')
            if (-not $hr -or -not $nm -or $nm -eq 'default') { continue }
            $label = switch -Regex ($nm) { 'tegn|sign' { 'Sign language (tegnspråk)' } 'syn|descr' { 'Audio description (synstolking)' } default { $nm } }
            [pscustomobject]@{ Label = $label; Href = $hr }
        })
        $nx = Get-Prop (Get-Prop (Get-Prop (Get-Prop $md '_embedded') 'next') '_links') 'self'
        if ($nx) { $next = ([string](Get-Prop $nx 'href')) -replace '^.*/', '' }
    } catch { Write-Log DEBUG "Video metadata for ${Id}: $($_.Exception.Message)" }
    $res = [pscustomobject]@{
        Playable  = (([string](Get-Prop $m 'playability') -eq 'playable') -and [bool]$asset)
        Url       = [string](Get-Prop $asset 'url')
        Mime      = [string](Get-Prop $asset 'mimeType')
        Encrypted = $encrypted
        Live      = [bool](Get-Prop $pl 'liveBuffer')
        Duration  = ConvertFrom-IsoDuration ([string](Get-Prop $pl 'duration'))
        Subtitles = $subs
        Chapters  = $chapters
        Poster    = $poster
        Title     = $title
        Next      = $next
        Versions  = $versions
        Reason    = $reason
    }
    Write-Log INFO ("Video stream {0}: playable={1} encrypted={2} subtitles={3} chapters={4} {5}" -f $Id, $res.Playable, $res.Encrypted, $subs.Count, $chapters.Count, $(if ($reason) { "($reason)" } else { $res.Url }))
    return $res
}

function Get-VideoPlayerMode($Target) {
    # 'builtin' or 'web' for this target
    if ($Target.ForceWeb) { return 'web' }
    $f = $Target.File
    if (-not $f -or [string]$f.Type -notin 'program', 'episode', 'live') { return 'web' }   # (live TV too: with its 3-hour buffer)
    if ((Get-AppSettings).VideoPlayer -eq 'web') { return 'web' }
    return 'builtin'
}

function Send-VideoConfig {
    # hands the stream to the page (now if it is ready, else when it says so)
    $pw = $script:PlayerWin
    if (-not $pw -or -not $pw.Pending -or -not $pw.VReady) { return }
    try { [void]$pw.WebView.CoreWebView2.ExecuteScriptAsync("window.nrkb && nrkb.load($($pw.Pending))") } catch { Write-Log WARN "Video player: could not start: $($_.Exception.Message)" }
}

$script:VideoPlayerHtml = @'
<!doctype html><html lang="no"><head><meta charset="utf-8"><title>NRK</title>
<style>
html,body{margin:0;height:100%;background:#000;overflow:hidden;font:14px "Segoe UI",sans-serif;color:#d6dde0}
#wrap{position:fixed;inset:0;display:flex;flex-direction:column}
#stage{position:relative;flex:1 1 auto;min-height:0}
video{position:absolute;inset:0;width:100%;height:100%;background:#000;outline:none}
video::cue{font-size:120%;background:rgba(0,0,0,.72)}
#ch{display:none;gap:8px;overflow-x:auto;padding:8px 10px;background:#070909;flex:0 0 auto;scrollbar-width:thin;scrollbar-color:#3b4a52 #070909}
#ch button{flex:0 0 auto;background:none;color:#c5ced2;border:1px solid #33434b;border-radius:4px;padding:6px 12px;font:inherit;cursor:pointer;white-space:nowrap}
#ch button:hover{border-color:#6b8590;color:#fff}
#ch button.on{border-color:#48c9d2;color:#fff}
#msg{position:absolute;inset:0;display:none;align-items:center;justify-content:center;text-align:center;padding:24px;background:#000;color:#8a949b}
#msg b{display:block;color:#fff;font-size:16px;margin-bottom:8px;font-weight:600}
#up{position:absolute;right:24px;bottom:72px;display:none;background:rgba(14,20,24,.94);border:1px solid #33434b;border-radius:8px;padding:14px 16px;min-width:280px;max-width:420px;color:#d6dde0;box-shadow:0 6px 24px rgba(0,0,0,.5)}
#up .k{font-size:12px;color:#8a949b;margin-bottom:4px}#up .t{font-weight:600;font-size:15px;margin-bottom:12px;color:#fff}
#up button{background:#48c9d2;color:#0a1e22;border:0;border-radius:4px;padding:7px 14px;font:inherit;font-weight:600;cursor:pointer;margin-right:8px}
#up button.c{background:none;color:#c5ced2;border:1px solid #33434b;font-weight:400}
</style></head><body>
<div id="wrap"><div id="stage"><video id="v" controls autoplay playsinline crossorigin="anonymous"></video><div id="msg"></div>
<div id="up"><div class="k" id="upk">Next episode</div><div class="t" id="upt"></div><button id="upgo">Play now</button><button class="c" id="upno">Cancel</button></div></div><div id="ch"></div></div>
<script src="/__nrkb/hls.min.js"></script>
<script>
(() => {
  const v = document.getElementById('v'), ch = document.getElementById('ch'), msg = document.getElementById('msg');
  const post = m => { try { window.chrome.webview.postMessage(JSON.stringify(m)); } catch (e) {} };
  const CDN = 'https://cdn.jsdelivr.net/npm/hls.js@__HLSVER__/dist/hls.min.js';
  let hls = null, cur = null, chapters = [];
  function show(title, text) {
    msg.innerHTML = '<div><b></b><span></span></div>';
    msg.querySelector('b').textContent = title || ''; msg.querySelector('span').textContent = text || '';
    msg.style.display = 'flex';
  }
  function ensureHls(cb) {
    if (window.Hls) return cb();
    const s = document.createElement('script'); s.src = CDN; s.onload = cb; s.onerror = cb; document.head.appendChild(s);
  }
  function stop() {
    if (hls) { try { hls.destroy(); } catch (e) {} hls = null; }
    v.removeAttribute('src'); try { v.load(); } catch (e) {}
  }
  const fmt = s => { s = Math.max(0, Math.floor(s)); const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60;
    return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(x).padStart(2, '0'); };
  function setChapters(list) {
    chapters = (list || []).filter(c => c && c.title != null);
    ch.innerHTML = '';
    ch.style.display = chapters.length ? 'flex' : 'none';
    chapters.forEach((c, i) => {
      const b = document.createElement('button');
      b.textContent = (i + 1) + '. ' + c.title; b.title = fmt(c.start);
      b.onclick = () => { v.currentTime = c.start; const p = v.play(); if (p && p.catch) p.catch(() => {}); v.focus(); };
      ch.appendChild(b);
    });
  }
  v.addEventListener('timeupdate', () => {
    if (!chapters.length) return;
    let k = -1; chapters.forEach((c, i) => { if (v.currentTime >= c.start - 0.5) k = i; });
    [...ch.children].forEach((b, i) => { const on = i === k; if (on !== b.classList.contains('on')) { b.classList.toggle('on', on); if (on) b.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } });
  });
  function start(c) {
    if (/mpegurl/i.test(c.mime || '') || /\.m3u8(\?|$)/i.test(c.url)) {
      if (window.Hls && Hls.isSupported()) {
        hls = new Hls({ enableWorker: true, startPosition: c.start > 0 ? c.start : -1, liveSyncDurationCount: 3, liveMaxLatencyDurationCount: Infinity });
        let netRetry = 0, mediaRetry = 0;
        // the sound tracks (normal / audio description "synstolking" / other languages): to the app's Audio menu
        const tracks = () => {
          if (!hls) return;
          const list = (hls.audioTracks || []).map((t, i) => ({ i, name: t.name || t.lang || ('Track ' + (i + 1)), lang: t.lang || '', def: !!t.default }));
          if (c.preferAd && !c.adDone) {
            c.adDone = true;
            const ad = list.find(t => /synstolk|tolk|description|\bad\b/i.test(t.name));
            if (ad && hls.audioTrack !== ad.i) hls.audioTrack = ad.i;
          }
          post({ type: 'atracks', list, cur: hls.audioTrack });
        };
        hls.on(Hls.Events.AUDIO_TRACKS_UPDATED, tracks);
        hls.on(Hls.Events.AUDIO_TRACK_SWITCHED, tracks);
        // the picture qualities NRK offers: to the app's Quality menu (Auto = hls.js picks)
        const levels = () => {
          if (!hls) return;
          const list = (hls.levels || []).map((l, i) => ({ i, h: l.height || 0, w: l.width || 0, br: l.bitrate || 0 }));
          post({ type: 'levels', list, cur: hls.manualLevel === undefined ? (hls.autoLevelEnabled ? -1 : hls.currentLevel) : hls.manualLevel, now: hls.currentLevel });
        };
        hls.on(Hls.Events.MANIFEST_PARSED, levels);
        hls.on(Hls.Events.LEVEL_SWITCHED, levels);
        hls.on(Hls.Events.ERROR, (e, d) => {
          if (!d.fatal) return;
          if (d.type === Hls.ErrorTypes.NETWORK_ERROR && netRetry < 3) { netRetry++; post({ type: 'verror', retry: netRetry, details: d.details }); setTimeout(() => { if (!hls) return; if (/manifest/i.test(d.details)) hls.loadSource(c.url); else hls.startLoad(); }, 1500 * netRetry); return; }
          if (d.type === Hls.ErrorTypes.MEDIA_ERROR && mediaRetry < 2) { mediaRetry++; post({ type: 'verror', retry: mediaRetry, details: d.details }); hls.recoverMediaError(); return; }
          post({ type: 'verror', fatal: true, details: d.details });
          show('Kan ikke spille av', 'The stream stopped (' + d.details + '). Try Reload, or "Open NRK page".');
        });
        hls.loadSource(c.url); hls.attachMedia(v);
      } else if (v.canPlayType('application/vnd.apple.mpegurl')) { v.src = c.url; }
      else { show('Kan ikke spille av', 'hls.js is missing (Options > Components...).'); post({ type: 'verror', fatal: true, details: 'no hls.js' }); return; }
    } else {
      v.src = c.url;
      if (c.start > 0) v.addEventListener('loadedmetadata', () => { try { v.currentTime = c.start; } catch (e) {} }, { once: true });
    }
    if (c.rate && !c.live) { v.defaultPlaybackRate = v.playbackRate = c.rate; }
    const p = v.play(); if (p && p.catch) p.catch(e => post({ type: 'autoplay', step: 'play() refused: ' + e.name }));
    v.focus();
  }
  // live: how far behind live, so the app can show it (and "Start over" / "LIVE" can move in the buffer)
  const liveEdge = () => { if (hls && hls.liveSyncPosition) return hls.liveSyncPosition; const r = v.seekable; return r.length ? r.end(r.length - 1) : v.currentTime; };
  const liveStart = () => { const r = v.seekable; return r.length ? r.start(0) : 0; };
  setInterval(() => { if (cur && cur.live && v.readyState > 0) post({ type: 'vlive', behind: Math.max(0, liveEdge() - v.currentTime), window: Math.max(0, liveEdge() - liveStart()) }); }, 3000);
  // subtitles: size, colour, background and height on the picture
  let cueStyle = null, sub = { size: 120, color: 'white', bg: 'box', pos: 'bottom' };
  const SUBCOLOR = { white: '#ffffff', yellow: '#ffe14d', cyan: '#7fe6ee', green: '#9be37a' };
  const SUBBG = { none: 'transparent', shadow: 'transparent', box: 'rgba(0,0,0,.72)', solid: '#000' };
  function setSubStyle(o) {
    sub = Object.assign(sub, o || {});
    if (!cueStyle) { cueStyle = document.createElement('style'); document.head.appendChild(cueStyle); }
    const shadow = sub.bg === 'shadow' || sub.bg === 'none' ? 'text-shadow:0 0 4px #000,0 0 2px #000,1px 1px 2px #000;' : '';
    cueStyle.textContent = 'video::cue{font-size:' + (sub.size || 120) + '% !important;color:' + (SUBCOLOR[sub.color] || '#fff') + ' !important;background-color:' + (SUBBG[sub.bg] || SUBBG.box) + ' !important;' + shadow + '}';
    placeCues();
  }
  function setSubSize(pct) { setSubStyle({ size: pct || 120 }); }
  function placeCues() {
    // bottom: where NRK puts them; raised: above the controls; top: at the top of the picture
    const line = sub.pos === 'top' ? 1 : (sub.pos === 'raised' ? -4 : 'auto');
    const tr = v.textTracks;
    for (let k = 0; k < tr.length; k++) { const cs = tr[k].cues; if (!cs) continue; for (let i = 0; i < cs.length; i++) { try { cs[i].snapToLines = true; cs[i].line = line; } catch (e) {} } }
  }
  v.textTracks.addEventListener('addtrack', e => { e.track.addEventListener('cuechange', placeCues); });
  // the next episode: a card at the end that counts down (Play now / Cancel)
  let upTimer = null, upLeft = 0;
  const up = document.getElementById('up');
  function hideUp() { clearInterval(upTimer); upTimer = null; up.style.display = 'none'; }
  function showUp() {
    if (!cur || !cur.next) return false;
    upLeft = cur.nextIn || 10;
    document.getElementById('upt').textContent = cur.next;
    const k = document.getElementById('upk');
    const tick = () => { k.textContent = 'Next episode in ' + upLeft + ' s'; if (upLeft-- <= 0) { hideUp(); post({ type: 'upnext', go: true }); } };
    up.style.display = 'block'; tick(); clearInterval(upTimer); upTimer = setInterval(tick, 1000);
    return true;
  }
  document.getElementById('upgo').onclick = () => { hideUp(); post({ type: 'upnext', go: true }); };
  document.getElementById('upno').onclick = () => { hideUp(); post({ type: 'upnext', go: false }); };
  // a picture of the frame you see (PNG, full size)
  function shot() {
    try {
      if (!v.videoWidth) { post({ type: 'shot', error: 'nothing to save yet' }); return; }
      const c = document.createElement('canvas'); c.width = v.videoWidth; c.height = v.videoHeight;
      c.getContext('2d').drawImage(v, 0, 0, c.width, c.height);
      post({ type: 'shot', data: c.toDataURL('image/png').split(',')[1], t: v.currentTime });
    } catch (e) { post({ type: 'shot', error: String(e && e.message || e) }); }
  }
  // fade out (sleep timer): the volume goes down over sec seconds; unfade() puts it back
  let fadeTimer = null, fadeFrom = null;
  function fade(sec) {
    clearInterval(fadeTimer); if (fadeFrom === null) fadeFrom = v.volume;
    const steps = Math.max(1, Math.round(sec * 4)); let n = 0;
    fadeTimer = setInterval(() => { n++; v.volume = Math.max(0, fadeFrom * (1 - n / steps)); if (n >= steps) clearInterval(fadeTimer); }, 250);
  }
  function unfade() { clearInterval(fadeTimer); if (fadeFrom !== null) { v.volume = fadeFrom; fadeFrom = null; } }
  window.nrkb = {
    load(c) {
      cur = c; msg.style.display = 'none'; stop();
      [...v.querySelectorAll('track')].forEach(t => t.remove());
      (c.subtitles || []).forEach(s => {
        const t = document.createElement('track');
        t.kind = 'subtitles'; t.label = s.label || s.language || 'Undertekster'; t.srclang = s.language || 'no'; t.src = s.url;
        if (s.default) t.default = true;
        v.appendChild(t);
      });
      // a track added from script is not switched on by "default": do it once it exists
      setTimeout(() => { const tr = v.querySelectorAll('track'); (c.subtitles || []).forEach((s, i) => { if (tr[i]) tr[i].track.mode = (c.subIndex === undefined ? s.default : c.subIndex === i) ? 'showing' : 'hidden'; }); }, 0);
      if (c.poster) v.poster = c.poster; else v.removeAttribute('poster');
      hideUp();
      setSubStyle(Object.assign({ size: c.subSize || 120 }, c.subStyle || {}));
      document.title = c.title || 'NRK';
      setChapters(c.chapters);
      ensureHls(() => start(c));
    },
    stop() { stop(); },
    message(t, s) { stop(); show(t, s); },
    rate(r) { v.defaultPlaybackRate = v.playbackRate = r; },
    subs(i) { const tr = v.textTracks; for (let k = 0; k < tr.length; k++) tr[k].mode = (k === i) ? 'showing' : 'hidden'; },
    subSize(p) { setSubSize(p); },
    subStyle(o) { setSubStyle(o); },
    level(i) { if (hls) { hls.currentLevel = i; hls.manualLevel = i; } },
    shot() { shot(); },
    fade(s) { fade(s); }, unfade() { unfade(); },
    setNext(t) { if (cur) cur.next = t; if (!t) hideUp(); },
    audio(i) { if (hls) hls.audioTrack = i; },
    liveBack(sec) { v.currentTime = Math.max(liveStart(), v.currentTime - sec); },
    toLive() { v.currentTime = Math.max(liveStart(), liveEdge() - 1); const p = v.play(); if (p && p.catch) p.catch(() => {}); },
    startOver(sec) { v.currentTime = Math.max(liveStart(), liveEdge() - sec); const p = v.play(); if (p && p.catch) p.catch(() => {}); }
  };
  v.addEventListener('ended', () => post({ type: 'ended', t: v.currentTime, d: v.duration || 0, card: showUp() }));
  v.addEventListener('seeking', () => { if (upTimer && v.currentTime < (v.duration || 0) - 1) hideUp(); });
  v.addEventListener('playing', () => post({ type: 'vplaying' }));
  // where you are, every 5 s (and when you pause or jump), so the app can continue there next time
  let lastPos = 0;
  const pos = force => { const n = Date.now(); if (!cur || !(v.currentTime > 0)) return; if (!force && n - lastPos < 5000) return; lastPos = n; post({ type: 'vpos', t: v.currentTime, d: isFinite(v.duration) ? v.duration : 0 }); };
  v.addEventListener('timeupdate', () => pos(false));
  v.addEventListener('pause', () => pos(true));
  v.addEventListener('seeked', () => pos(true));
  for (const n of ['play', 'pause', 'volumechange']) v.addEventListener(n, () => post({ type: 'vstate', paused: v.paused, muted: v.muted }));
  window.addEventListener('keydown', e => {
    if (e.key === 'Escape' || e.key === 'F11') { post({ type: 'key', key: e.key }); return; }
    if (e.target === v) return;   // the video handles its own keys when it has focus
    if (e.key === ' ' || e.key === 'k') { e.preventDefault(); v.paused ? v.play() : v.pause(); }
    else if (e.key === 'ArrowRight') v.currentTime += 10;
    else if (e.key === 'ArrowLeft') v.currentTime -= 10;
    else if (e.key === 'm') v.muted = !v.muted;
    else if (e.key === 'f') { document.fullscreenElement ? document.exitFullscreen() : v.requestFullscreen(); }
  }, true);
  post({ type: 'ready' });
})();
</script></body></html>
'@

# ---- sound output for this app only ---------------------------------------------------------
# Options > Playback > "Sound output": the radio bar and the video player play on the chosen
# device; Windows and other apps keep their own. The pages send their sound there with the
# browser's setSinkId(). The browser only reveals device names to pages allowed to use audio
# devices, so the app gives tv.nrk.no and radio.nrk.no that permission in its own player
# profile while a device is chosen (nothing is recorded; it is removed again for "Windows default").
if (-not ('NrkAudioDevices' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class NrkAudioDevices {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator { [PreserveSig] int EnumAudioEndpoints(int flow, int mask, out IMMDeviceCollection devices); [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device); }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection { [PreserveSig] int GetCount(out int count); [PreserveSig] int Item(int index, out IMMDevice device); }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice { [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, out IntPtr o); [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store); [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id); }
    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore { [PreserveSig] int GetCount(out int c); [PreserveSig] int GetAt(int i, out PropKey k); [PreserveSig] int GetValue(ref PropKey k, out PropVariant v); }
    [StructLayout(LayoutKind.Sequential)] struct PropKey { public Guid Fmt; public int Pid; }
    [StructLayout(LayoutKind.Explicit, Size = 24)] struct PropVariant { [FieldOffset(0)] public short Vt; [FieldOffset(8)] public IntPtr Ptr; }
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant v);
    // the names of the active playback devices, as Windows shows them ("Speakers (Realtek(R) Audio)")
    public static string[] RenderNames() {
        var list = new List<string>();
        var en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDeviceCollection col;
        if (en.EnumAudioEndpoints(0, 1, out col) != 0) return list.ToArray();   // eRender, ACTIVE
        int n; col.GetCount(out n);
        var key = new PropKey { Fmt = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), Pid = 14 };   // PKEY_Device_FriendlyName
        for (int i = 0; i < n; i++) {
            IMMDevice d; if (col.Item(i, out d) != 0) continue;
            IPropertyStore ps; if (d.OpenPropertyStore(0, out ps) != 0) continue;
            PropVariant v;
            if (ps.GetValue(ref key, out v) == 0) {
                if (v.Vt == 31 && v.Ptr != IntPtr.Zero) list.Add(Marshal.PtrToStringUni(v.Ptr));   // VT_LPWSTR
                PropVariantClear(ref v);
            }
        }
        return list.ToArray();
    }
}
'@ -ErrorAction SilentlyContinue
}

function Get-AudioOutputDevices {
    # playback devices by name: Windows' own list, or (fallback) the device names in the registry
    try { if ('NrkAudioDevices' -as [type]) { $n = @([NrkAudioDevices]::RenderNames() | Where-Object { $_ }); if ($n.Count) { return ,@($n | Sort-Object -Unique) } } } catch { Write-Log DEBUG "Audio devices (COM): $($_.Exception.Message)" }
    $names = @()
    try {
        $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
            $state = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).DeviceState
            if ($state -ne 1) { continue }
            $p = Get-ItemProperty -LiteralPath (Join-Path $k.PSPath 'Properties') -ErrorAction SilentlyContinue
            $desc = $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'; $iface = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
            if ($desc) { $names += $(if ($iface) { "$desc ($iface)" } else { [string]$desc }) }
        }
    } catch { Write-Log DEBUG "Audio devices (registry): $($_.Exception.Message)" }
    return ,@($names | Sort-Object -Unique)
}

# runs in every page of both players: sends all sound to the chosen device (by its name)
$script:AudioSinkJs = @'
(() => {
  if (window.__nrkbSink) return;
  const S = window.__nrkbSink = { name: '', id: '' };
  function media(root = document, out = []) {
    try { root.querySelectorAll('audio, video').forEach(e => out.push(e)); root.querySelectorAll('*').forEach(e => { if (e.shadowRoot) media(e.shadowRoot, out); }); } catch (e) {}
    return out;
  }
  async function resolve(tries = 0) {
    if (!S.name) { S.id = ''; return; }
    try {
      const all = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'audiooutput');
      // no names yet: the permission is being set up; ask again in a moment
      if (all.every(d => !d.label) && tries < 4) { await new Promise(r => setTimeout(r, 800)); return resolve(tries + 1); }
      const n = S.name.toLowerCase();
      const hit = all.find(d => (d.label || '').toLowerCase() === n) || all.find(d => (d.label || '').toLowerCase().includes(n)) || all.find(d => n.includes((d.label || '~').toLowerCase()));
      S.id = hit ? hit.deviceId : '';
      if (!hit) { try { window.chrome.webview.postMessage(JSON.stringify({ type: 'sink', ok: false, name: S.name, seen: all.map(d => d.label).join(' | ') })); } catch (e) {} }
    } catch (e) { S.id = ''; }
  }
  function apply(el) {
    if (!el || typeof el.setSinkId !== 'function' || el.sinkId === S.id) return;
    el.setSinkId(S.id).catch(() => {});
  }
  window.__nrkbSetSink = async name => { S.name = name || ''; await resolve(); media().forEach(apply); };
  // new players / sources: on every play
  document.addEventListener('play', e => apply(e.target), true);
  document.addEventListener('loadstart', e => apply(e.target), true);
  setInterval(() => { if (S.name) media().forEach(apply); }, 3000);
})();
'@

function Set-AudioSinkPermission([bool] $On) {
    # device names need the audio-device permission: only for NRK's pages in the app's own player profile
    foreach ($wv in @($(if ($script:PlayerWin -and -not $script:PlayerWin.Form.IsDisposed) { $script:PlayerWin.WebView }), $script:AudioUi.WebView)) {
        try {
            $core = $wv.CoreWebView2; if (-not $core) { continue }
            foreach ($o in 'https://tv.nrk.no', 'https://radio.nrk.no') {
                [void]$core.Profile.SetPermissionStateAsync([Microsoft.Web.WebView2.Core.CoreWebView2PermissionKind]::Microphone, $o,
                    $(if ($On) { [Microsoft.Web.WebView2.Core.CoreWebView2PermissionState]::Allow } else { [Microsoft.Web.WebView2.Core.CoreWebView2PermissionState]::Default }))
            }
        } catch { Write-Log DEBUG "Sound output permission: $($_.Exception.Message)" }
    }
}

function Send-AudioSink {
    # tells both players which device to use (after a page load, and when the option changes)
    $name = [string](Get-AppSettings).AudioDevice
    $js = 'window.__nrkbSetSink && window.__nrkbSetSink({0})' -f ($name | ConvertTo-Json -Compress)
    if ($name) { Set-AudioSinkPermission $true }
    foreach ($wv in @($(if ($script:PlayerWin -and -not $script:PlayerWin.Form.IsDisposed) { $script:PlayerWin.WebView }), $script:AudioUi.WebView)) {
        try { if ($wv -and $wv.CoreWebView2) { [void]$wv.CoreWebView2.ExecuteScriptAsync($js) } } catch { }
    }
}

function New-WebViewControl {
    $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
    # Default user-data folder would be next to powershell.exe (System32, not writable).
    $props.UserDataFolder = Join-Path $script:AppDataDir 'WebView2Data'
    $props.AdditionalBrowserArguments = '--autoplay-policy=no-user-gesture-required'
    $wv.CreationProperties = $props
    $wv.DefaultBackgroundColor = [System.Drawing.Color]::Black
    $wv.Dock = 'Fill'
    Write-Log INFO "WebView2: creating control, user data folder $($props.UserDataFolder)"

    $wv.Add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if ($e.IsSuccess) {
            $core = $s.CoreWebView2
            Write-Log INFO "WebView2 ready (browser $($core.Environment.BrowserVersionString))"
            $core.Settings.IsStatusBarEnabled = $false
            [void]$core.AddScriptToExecuteOnDocumentCreatedAsync($script:PlayerOnlyJs)
            [void]$core.AddScriptToExecuteOnDocumentCreatedAsync($script:AudioSinkJs)   # sound output (Options > Playback)
            if ((Get-AppSettings).AudioDevice) { Set-AudioSinkPermission $true }
            # the built-in player page, hls.js and subtitles, served from memory
            $core.AddWebResourceRequestedFilter('https://tv.nrk.no/__nrkb/*', [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All)
            $core.add_WebResourceRequested({
                param($c, $a)
                try {
                    $uri = [string]$a.Request.Uri
                    if ($uri -match '/hls\.min\.js(\?|$)') {
                        $hls = Find-HlsJs
                        if ($hls) { $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($hls)); $a.Response = $c.Environment.CreateWebResourceResponse($ms, 200, 'OK', 'Content-Type: application/javascript; charset=utf-8') }
                        else { $a.Response = $c.Environment.CreateWebResourceResponse($null, 404, 'Not Found', '') }
                        return
                    }
                    if ($uri -match '/__nrkb/sub\?u=([^&]+)') {
                        # subtitles fetched here, so the page never depends on NRK's CORS headers for them
                        $src = [uri]::UnescapeDataString($Matches[1])
                        $wc = New-Object System.Net.WebClient; $wc.Headers['User-Agent'] = $script:UserAgent
                        $bytes = try { $wc.DownloadData($src) } catch { Write-Log WARN "Subtitles failed: $src ($($_.Exception.Message))"; $null } finally { $wc.Dispose() }
                        if ($bytes) { $ms = New-Object IO.MemoryStream(, $bytes); $a.Response = $c.Environment.CreateWebResourceResponse($ms, 200, 'OK', 'Content-Type: text/vtt; charset=utf-8') }
                        else { $a.Response = $c.Environment.CreateWebResourceResponse($null, 404, 'Not Found', '') }
                        return
                    }
                    $ms = New-Object IO.MemoryStream(, [Text.Encoding]::UTF8.GetBytes($script:VideoPlayerHtml))
                    $a.Response = $c.Environment.CreateWebResourceResponse($ms, 200, 'OK', "Content-Type: text/html; charset=utf-8`r`nCache-Control: no-store")
                } catch { Write-LogException $_ 'Video player page' }
            })
            $core.add_NavigationStarting({ param($c, $a) if ($script:PlayerWin) { $script:PlayerWin.VReady = $false } })
            # NRK opens some links in new windows; keep them in the player window.
            $core.add_NewWindowRequested({ param($c, $a) Write-Log INFO "WebView2 new-window request kept in view: $($a.Uri)"; $a.Handled = $true; $c.Navigate($a.Uri) })
            $core.add_ContainsFullScreenElementChanged({ param($c, $a) Set-PlayerFullScreen $c.ContainsFullScreenElement })
            $core.add_ProcessFailed({ param($c, $a) Write-Log ERROR "WebView2 process failed: $($a.ProcessFailedKind) reason=$($a.Reason) exit=$($a.ExitCode)" })
            $core.add_WebMessageReceived({
                param($c, $a)
                try { $m = $a.TryGetWebMessageAsString() | ConvertFrom-Json } catch { return }
                switch ($m.type) {
                    'sink' { Write-Log WARN ("Sound output '{0}' not found by the player (it sees: {1}) - using the Windows default" -f $m.name, $m.seen) }
                    'ready' {
                        # the built-in player page is up: give it the stream
                        if ($script:PlayerWin) { $script:PlayerWin.VReady = $true; Send-VideoConfig }
                    }
                    'vplaying' { if ($script:PlayerWin) { $script:PlayerWin.Hint.Text = '' } }
                    'verror' {
                        Write-Log WARN ("Built-in player: {0}{1}" -f $m.details, $(if ($m.retry) { " (retry $($m.retry))" } elseif ($m.fatal) { ' - stopped' } else { '' }))
                        if ($m.fatal -and $script:PlayerWin) { $script:PlayerWin.Hint.Text = 'Playback stopped - try Reload, or "Open NRK page"' }
                    }
                    'vpos' { if ($script:PlayerWin -and $script:PlayerWin.Target) { Set-PlayPosition $script:PlayerWin.Target.File ([double]$m.t) ([double]$m.d) } }
                    'atracks' { if ($script:PlayerWin) { $script:PlayerWin.ATracks = @($m.list); $script:PlayerWin.ATrack = [int]$m.cur; Update-PlayerExtras } }
                    'vlive' {
                        $pw = $script:PlayerWin
                        if ($pw) {
                            $behind = [double]$m.behind
                            $pw.LiveGo.ForeColor = if ($behind -lt 30) { $T.Live } else { $T.Text }
                            $txt = if ($behind -lt 30) { 'Live' } else { '{0} behind live' -f (Format-PlayTime $behind) }
                            if ($pw.Hint.Text -ne $txt -and ($pw.Hint.Text -eq '' -or $pw.Hint.Text -match 'live$|^Live$')) { $pw.Hint.Text = $txt }
                        }
                    }
                    'ended' {
                        if ($script:PlayerWin -and $script:PlayerWin.Target) { Set-PlayPosition $script:PlayerWin.Target.File ([double]$m.t) ([double]$m.d) -Ended }
                        if (Test-SleepAtEnd) { Invoke-PlayerScript 'nrkb.setNext(null)'; return }
                        if (-not (Get-AppSettings).AutoNext) { return }
                        if ($m.card) { Write-Log INFO 'Built-in player: finished, the next-episode card counts down'; return }   # (the card says go or cancel)
                        # next episode, like NRK's own player
                        if (@($script:VideoQueue).Count -gt 1 -and $script:VideoIndex -lt @($script:VideoQueue).Count - 1) { Write-Log INFO 'Built-in player: finished, playing the next episode'; Start-PlayerStep 1 }
                    }
                    'upnext' {
                        if ($m.go -and @($script:VideoQueue).Count -gt 1 -and $script:VideoIndex -lt @($script:VideoQueue).Count - 1) { Write-Log INFO 'Built-in player: next episode (card)'; Start-PlayerStep 1 }
                        elseif (-not $m.go) { Write-Log INFO 'Built-in player: next episode canceled' }
                    }
                    'levels' { if ($script:PlayerWin) { $script:PlayerWin.Levels = @($m.list); $script:PlayerWin.Level = [int]$m.cur; $script:PlayerWin.LevelNow = [int]$m.now; Update-PlayerExtras } }
                    'shot' { Save-PlayerShot $m }
                    'isolated' { Write-Log INFO ("Player only: isolated <{0} class='{1}'>{2} on {3}" -f $m.tag, $m.cls, $(if ($m.chapters) { ' + chapter row' } else { '' }), $m.url) }
                    'chapters' { Write-Log INFO ("Player only: chapter row added ({0} buttons) on {1}" -f $m.n, $m.url) }
                    'autostart' {
                        Write-Log INFO ("Player: pressed '{0}' on {1}" -f $m.label, $m.url)
                        if ($script:PlayerWin) { $script:PlayerWin.Hint.Text = "Started: $($m.label)" }
                    }
                    'reveal' {
                        Write-Log INFO ("Player shown after {0} ms ({1}) on {2}" -f $m.ms, $m.why, $m.url)
                        if ($script:PlayerWin -and $m.why -ne 'player') { $script:PlayerWin.Hint.Text = 'No player found yet - showing the full page' }
                    }
                    'vstate' {
                        if ($script:PlayerWin) { $script:PlayerWin.Paused = [bool]$m.paused; $script:PlayerWin.Muted = [bool]$m.muted }
                        if (-not $m.paused -and $script:PlayerWin) { Set-TrayText (($script:PlayerWin.Form.Text -replace '\s+-\s+NRK$', '')) }
                    }
                    'autoplay' { Write-Log INFO ("Player autoplay: {0} {1} on {2}" -f $m.step, $m.label, $m.url) }
                    'click' {
                        # Trusted mouse click through DevTools: works where a script click() is ignored
                        Write-Log INFO ("Player autoplay: real click at {0},{1} on {2}" -f $m.x, $m.y, $m.url)
                        foreach ($t in 'mousePressed', 'mouseReleased') {
                            $j = '{{"type":"{0}","x":{1},"y":{2},"button":"left","clickCount":1}}' -f $t, [int]$m.x, [int]$m.y
                            try { [void]$c.CallDevToolsProtocolMethodAsync('Input.dispatchMouseEvent', $j) } catch { Write-Log WARN "Player autoplay click failed: $($_.Exception.Message)" }
                        }
                    }
                    'no-video' {
                        Write-Log WARN ("Player only: no video element found after 20 s on {0} (videos {1}, frames {2}, web components {3}) - use 'Show full page'" -f $m.url, $m.videos, $m.iframes, $m.shadowHosts)
                        if ($script:PlayerWin) { $script:PlayerWin.Hint.Text = 'No player found yet - try "Show full page" (login, age check or cookie choice?)' }
                    }
                    'key' {
                        if ($m.key -eq 'Escape' -and $script:PlayerWin.Full) { Set-PlayerFullScreen $false }
                        elseif ($m.key -eq 'F11') { Set-PlayerFullScreen (-not $script:PlayerWin.Full) }
                    }
                }
            })
        } else {
            $ex = $e.InitializationException
            Write-Log ERROR ("WebView2 initialization failed: {0}: {1}" -f $ex.GetType().FullName, $ex.Message)
            Set-Status "Embedded player failed to start: $($ex.Message)  (details in Logs)"
            if ($script:PlayerWin) { $script:PlayerWin.Hint.Text = "Player failed to start: $($ex.Message)" }
        }
    })
    $wv.Add_NavigationStarting({ param($s, $e) Write-Log INFO "WebView2 navigating: $($e.Uri)" })
    $wv.Add_NavigationCompleted({
        param($s, $e)
        $http = try { $e.HttpStatusCode } catch { 'n/a' }
        Write-Log $(if ($e.IsSuccess) { 'INFO' } else { 'WARN' }) ("WebView2 navigation completed: success={0} error={1} http={2} url={3}" -f $e.IsSuccess, $e.WebErrorStatus, $http, $s.Source)
        if ($e.IsSuccess -and (Get-AppSettings).AudioDevice) { Send-AudioSink }
        if ($e.IsSuccess -and [string]$s.Source -like '*/__nrkb/*') {
            Set-Status 'Playing in the built-in player'
        } elseif ($e.IsSuccess) {
            # In case the page loaded before the document-created script was registered
            try { [void]$s.CoreWebView2.ExecuteScriptAsync($script:PlayerOnlyJs) } catch { }
            Send-PlayerOnlyMode
            if ($script:PlayerWin) { $script:PlayerWin.Hint.Text = '' }
            Set-Status "Playing via tv.nrk.no  ·  $($s.Source)"
        } else {
            Set-Status "NRK page failed to load ($($e.WebErrorStatus)). Details in Logs."
            if ($script:PlayerWin) { $script:PlayerWin.Hint.Text = "Page failed to load ($($e.WebErrorStatus))" }
        }
    })
    return $wv
}

function Get-PlayerWindow {
    if ($script:PlayerWin -and -not $script:PlayerWin.Form.IsDisposed) { return $script:PlayerWin }

    $f = New-Object System.Windows.Forms.Form
    Set-AppIcon $f   # window, title bar and taskbar icon
    $f.Text = 'NRK Player'
    $f.Size = New-Object System.Drawing.Size(1280, 790)
    $f.MinimumSize = New-Object System.Drawing.Size(520, 340)
    $f.StartPosition = 'CenterScreen'
    $f.BackColor = [System.Drawing.Color]::Black; $f.ForeColor = $T.Text; $f.Font = $script:FontUi
    $f.Owner = $form   # stays in front of the main window

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Top'; $bar.Height = 46; $bar.WrapContents = $false; $bar.BackColor = $T.Bg
    $bar.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 0)
    $bPrev = New-FlatButton ("{0}  Previous" -f [char]0x2039) 0
    $bNext = New-FlatButton ("Next  {0}" -f [char]0x203A) 0
    $bPrev.Visible = $false; $bNext.Visible = $false
    $navTips = New-Object System.Windows.Forms.ToolTip
    $bMode = New-FlatButton 'Show full page' 0
    $bTop = New-FlatButton 'Keep on top' 0
    $bFull = New-FlatButton 'Fullscreen' 0
    $bReload = New-FlatButton 'Reload' 0
    $bExt = New-FlatButton 'Open in browser' 0
    $bCast = New-FlatButton ("Cast  {0}" -f [char]0x25BE) 0
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $false; $hint.Width = 300; $hint.Height = 34; $hint.TextAlign = 'MiddleLeft'
    $bSpeed = New-FlatButton 'Speed 1x' 0
    $bSubs = New-FlatButton ("Subtitles  {0}" -f [char]0x25BE) 0
    $bAudio = New-FlatButton ("Audio  {0}" -f [char]0x25BE) 0
    $bSleep = New-FlatButton ("Sleep  {0}" -f [char]0x25BE) 0
    $bQual = New-FlatButton ("Quality  {0}" -f [char]0x25BE) 0; $bQual.Visible = $false
    $bShot = New-FlatButton 'Screenshot' 0; $bShot.Visible = $false
    $bMini = New-FlatButton 'Mini' 0
    $bStartOver = New-FlatButton ("{0}  Start over" -f [char]0x21E4) 0
    $bLiveBack = New-FlatButton ("{0} 1 min" -f [char]0x21BA) 0
    $bLiveGo = New-FlatButton ("{0} LIVE" -f [char]0x25CF) 0
    foreach ($x in $bSpeed, $bSubs, $bAudio, $bStartOver, $bLiveBack, $bLiveGo) { $x.Visible = $false }
    $hint.ForeColor = $T.Muted; $hint.AutoEllipsis = $true
    $bar.Controls.AddRange(@($bPrev, $bNext, $bStartOver, $bLiveBack, $bLiveGo, $bSpeed, $bSubs, $bAudio, $bQual, $bSleep, $bMode, $bTop, $bFull, $bMini, $bShot, $bReload, $bExt, $bCast, $hint))
    # 2.9.3: icons in the chosen look (Options > General > Top bar icons); -Plain = the text as before
    Set-IconText $bPrev 'previous' 'Previous' -Plain ("{0}  Previous" -f [char]0x2039)
    Set-IconText $bNext 'next' 'Next' -Plain ("Next  {0}" -f [char]0x203A)
    Set-IconText $bStartOver 'startover' 'Start over' -Plain ("{0}  Start over" -f [char]0x21E4)
    Set-IconText $bLiveBack 'rewind' '1 min' -Plain ("{0} 1 min" -f [char]0x21BA)
    Set-IconText $bLiveGo 'record' 'LIVE' -Plain ("{0} LIVE" -f [char]0x25CF)
    Set-IconText $bSpeed 'speed' $bSpeed.Text -Plain $bSpeed.Text
    Set-IconText $bSubs 'subtitles' ("Subtitles  {0}" -f [char]0x25BE)
    Set-IconText $bAudio 'volume' ("Audio  {0}" -f [char]0x25BE)
    Set-IconText $bQual 'quality' ("Quality  {0}" -f [char]0x25BE)
    Set-IconText $bSleep 'sleep' ("Sleep  {0}" -f [char]0x25BE)
    Set-IconText $bMode 'window' $bMode.Text
    Set-IconText $bTop 'pin' 'Keep on top'
    Set-IconText $bFull 'fullscreen' 'Fullscreen'
    Set-IconText $bMini 'mini' 'Mini'
    Set-IconText $bShot 'camera' 'Screenshot'
    Set-IconText $bReload 'reload' 'Reload'
    Set-IconText $bExt 'web' 'Open in browser'
    Set-IconText $bCast 'cast' ("Cast  {0}" -f [char]0x25BE)
    $navTips.SetToolTip($bQual, 'Picture quality (Auto: picked by your connection)')
    $navTips.SetToolTip($bShot, 'Save the picture you see now (Pictures\NRK-Browser)')
    $navTips.SetToolTip($bMini, 'A small window that stays on top (again: back to normal size)')
    $bQual.Add_Click({ Show-PlayerQualityMenu })
    $bShot.Add_Click({ Invoke-PlayerScript 'nrkb.shot()' })
    $bMini.Add_Click({ Set-PlayerMini (-not $script:PlayerWin.Mini) })
    $navTips.SetToolTip($bStartOver, 'The programme on now, from its beginning (live TV keeps about 3 hours)')
    $navTips.SetToolTip($bLiveGo, 'Back to live')
    $bSpeed.Add_Click({
        $s = Get-AppSettings; $cur = [double]$s.VideoRate
        $i = [array]::IndexOf($script:VideoRates, $cur); $r = $script:VideoRates[($i + 1) % $script:VideoRates.Count]
        $s.VideoRate = $r.ToString([Globalization.CultureInfo]::InvariantCulture); Save-AppSettings $s
        Invoke-PlayerScript ("nrkb.rate({0})" -f $r.ToString([Globalization.CultureInfo]::InvariantCulture))
        Set-IconText $this 'speed' ('Speed ' + (Format-Rate $r)) -Plain ('Speed ' + (Format-Rate $r))
    })
    $bSubs.Add_Click({ Show-PlayerSubsMenu })
    $bAudio.Add_Click({ Show-PlayerAudioMenu })
    $bSleep.Add_Click({ Show-SleepMenu $this })
    $bStartOver.Add_Click({ Invoke-LiveStartOver })
    $bLiveBack.Add_Click({ Invoke-PlayerScript 'nrkb.liveBack(60)' })
    $bLiveGo.Add_Click({ Invoke-PlayerScript 'nrkb.toLive()' })
    $bCast.Add_Click({
        # what is playing here goes to the device (and continues there where it is now)
        $pw = $script:PlayerWin
        $file = if ($pw.Target -and $pw.Target.File) { $pw.Target.File } elseif ($script:SelectedFile -and $script:SelectedFile.Type -eq 'live') { $script:SelectedFile } else { $null }
        Show-CastMenu $this $(if (Test-CastableFile $file) { $file } else { $null })
    })

    $hostPanel = New-Object System.Windows.Forms.Panel
    $hostPanel.Dock = 'Fill'; $hostPanel.BackColor = [System.Drawing.Color]::Black
    $wv = New-WebViewControl
    $hostPanel.Controls.Add($wv)
    $f.Controls.Add($hostPanel)
    $f.Controls.Add($bar)

    $script:PlayerWin = @{ Form = $f; WebView = $wv; Bar = $bar; BtnMode = $bMode; BtnTop = $bTop; Hint = $hint; Full = $null; Url = $null
                           Prev = $bPrev; Next = $bNext; Tips = $navTips; Mode = 'web'; Pending = $null; VReady = $false; Target = $null
                           Speed = $bSpeed; Subs = $bSubs; Audio = $bAudio; Sleep = $bSleep; StartOver = $bStartOver; LiveBack = $bLiveBack; LiveGo = $bLiveGo
                           SubList = @(); SubIndex = -1; ATracks = @(); ATrack = -1; Versions = @()
                           Qual = $bQual; Shot = $bShot; MiniBtn = $bMini; Mini = $null; Levels = @(); Level = -1; LevelNow = -1 }
    $bPrev.Add_Click({ Start-PlayerStep -1 })
    $bNext.Add_Click({ Start-PlayerStep 1 })

    $bMode.Add_Click({
        $pw = $script:PlayerWin
        if ($pw.Mode -eq 'builtin' -and $pw.Target) {
            # the same programme in NRK's own player on the NRK web page
            Write-Log INFO 'Player: switching to the NRK page'
            $t = $pw.Target; $web = [pscustomobject]@{ Url = $t.Url; Title = $t.Title; File = $t.File; ForceWeb = $true }
            Start-Player -Target $web -FromQueue
            return
        }
        $script:PlayerOnly = -not $script:PlayerOnly
        Write-Log INFO "Player: player-only = $script:PlayerOnly"
        Send-PlayerOnlyMode
    })
    $bTop.Add_Click({
        $pw = $script:PlayerWin
        $pw.Form.TopMost = -not $pw.Form.TopMost
        $pw.BtnTop.BackColor = if ($pw.Form.TopMost) { $T.Sel } else { $T.Surface }
        $pw.BtnTop.ForeColor = if ($pw.Form.TopMost) { $T.Accent } else { $T.Text }
        Write-Log INFO "Player: keep on top = $($pw.Form.TopMost)"
    })
    $bFull.Add_Click({ Set-PlayerFullScreen $true })
    $bReload.Add_Click({ try { $script:PlayerWin.WebView.CoreWebView2.Reload() } catch { } })
    $bExt.Add_Click({
        $pw = $script:PlayerWin
        $u = try { [string]$pw.WebView.Source } catch { $null }
        if (-not $u -or $u -eq 'about:blank' -or $u -like '*/__nrkb/*') { $u = $pw.Url }
        if ($u) { Write-Log INFO "Player: open in browser $u"; Start-Process $u }
    })
    # Maximize must respect the taskbar on whichever monitor the window is on
    $f.Add_Shown({ Update-MaxBounds $script:PlayerWin.Form ([bool]$script:PlayerWin.Full) })
    $f.Add_LocationChanged({ if ($script:PlayerWin -and $script:PlayerWin.Form.WindowState -eq 'Normal') { Update-MaxBounds $script:PlayerWin.Form ([bool]$script:PlayerWin.Full) } })
    # (the window is hidden and shown again, so Shown runs only once: check again when it shows)
    $f.Add_VisibleChanged({ $pw = $script:PlayerWin; if ($pw -and $pw.Form.Visible) { Update-MaxBounds $pw.Form ([bool]$pw.Full) } })
    $f.Add_Resize({
        # maximized over the taskbar (bounds from another monitor, or left over from full screen): once more with the right ones
        $pw = $script:PlayerWin
        if (-not $pw -or $pw.Full -or $pw.FixingMax -or $pw.Form.WindowState -ne 'Maximized') { return }
        try {
            $wa = [System.Windows.Forms.Screen]::FromHandle($pw.Form.Handle).WorkingArea
            $slack = [NrkNative]::GetSystemMetrics(33) + [NrkNative]::GetSystemMetrics(92) + 2
            if ($pw.Form.Bounds.Bottom -gt $wa.Bottom + $slack -or $pw.Form.Bounds.Top -lt $wa.Top - $slack) {
                $pw.FixingMax = $true
                Write-Log DEBUG ('Player maximized over the taskbar ({0}); fitting it to the work area {1}' -f $pw.Form.Bounds, $wa)
                $pw.Form.WindowState = 'Normal'; Update-MaxBounds $pw.Form $false; $pw.Form.WindowState = 'Maximized'
            }
        } catch { } finally { $pw.FixingMax = $false }
    })
    $f.Add_FormClosing({
        param($s, $e)
        # Closing the player only hides it (and stops playback); the WebView is reused next time.
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            if ($script:PlayerWin.Full) { Set-PlayerFullScreen $false }   # (next time it opens as a normal window)
            Stop-Player
        }
    })
    Write-Log INFO 'Player window created'
    return $script:PlayerWin
}

function Start-Player {
    param($Target = $null, [switch] $FromQueue)
    # (whether this play came from the selected file in the list)
    $listFile = if (-not $Target) { $script:SelectedFile } else { $null }
    $playTarget = if ($Target) { $Target } else { Get-PlayTarget }
    if ($playTarget -and $playTarget.File -and -not (Test-ChildAllowed $playTarget.File)) { return }   # (child mode: too old for it)
    if ($playTarget -and $playTarget.Audio) { Start-AudioPlayer $playTarget.Audio; return }   # radio: audio bar, no window
    if (-not $FromQueue) { Set-VideoQueue $(if ($playTarget) { $playTarget.File } else { $null }) }
    # one thing at a time: a video closes the radio (another video simply replaces the current one)
    if ($playTarget -and $playTarget.Url -and $script:AudioUi.Current -and (Get-AppSettings).OnePlayer) { Write-Log INFO 'Playback: closing the radio for the video'; Stop-AudioPlayer }
    if (-not $playTarget -or -not $playTarget.Url) { return }
    Write-Log INFO "UI: play $($playTarget.Url)"
    if ($playTarget.File -and $playTarget.File.Type -eq 'live') { try { Add-RecentChannel $playTarget.File } catch { } }   # (2.9.0: jump list, phone remote)
    if (-not (Initialize-WebView2)) {
        $msg = "The embedded player is not available:`n`n$($script:WebView2.Error)`n`nOpen the programme in your web browser instead?"
        if ([System.Windows.Forms.MessageBox]::Show($form, $msg, 'Embedded player', 'YesNo', 'Warning') -eq 'Yes') { Start-Process $playTarget.Url }
        return
    }
    # programmes and episodes: the built-in player, when NRK offers a stream it can play
    $mode = Get-VideoPlayerMode $playTarget
    $config = $null; $note = ''
    if ($mode -eq 'builtin') {
        $res = @{ S = $null }
        $kind = if ($playTarget.File.Type -eq 'live') { 'channel' } else { 'program' }
        Invoke-Ui "Loading the stream for $($playTarget.File.Id)" { $res.S = Get-NrkVideoStream -Id $playTarget.File.Id -Kind $kind -Manifest ([string]$playTarget.Manifest) }
        $st = $res.S
        if ($st -and -not $st.Playable -and $st.Reason -and -not $st.Encrypted) {
            Set-Status "Cannot play $($playTarget.Title): $($st.Reason)"
            [void][System.Windows.Forms.MessageBox]::Show($form, "$($playTarget.Title)`n`n$($st.Reason)", 'Not playable', 'OK', 'Information')
            return
        }
        if ($st -and $st.Playable) {
            $stv = Get-AppSettings
            $config = [ordered]@{
                url = $st.Url; mime = $st.Mime; title = $playTarget.Title; poster = $st.Poster
                subtitles = @($st.Subtitles | ForEach-Object { [ordered]@{ url = '/__nrkb/sub?u=' + [uri]::EscapeDataString($_.url); label = $_.label; language = $_.language; default = $_.default } })
                chapters = @($st.Chapters)
                start = [double](Get-ResumePosition $playTarget.File)
                live = ($playTarget.File.Type -eq 'live'); rate = [double]$stv.VideoRate; subSize = [int]$stv.SubSize; preferAd = [bool]$stv.PreferAD
                subStyle = [ordered]@{ color = [string]$stv.SubColor; bg = [string]$stv.SubBg; pos = [string]$stv.SubPos }
                next = (Get-UpNextTitle $playTarget); nextIn = [Math]::Max(3, [int]$stv.UpNextSeconds)
            }
            if ($stv.SubsOff) { $config.subIndex = -1 }
            $script:PlayerExtra = @{ Subs = @($st.Subtitles); SubIndex = $(if ($stv.SubsOff) { -1 } else { [Math]::Max(-1, [array]::IndexOf(@($st.Subtitles | ForEach-Object { [bool]$_.default }), $true)) }); Versions = @($st.Versions) }
            $config = $config | ConvertTo-Json -Compress -Depth 4
            $resumeAt = Get-ResumePosition $playTarget.File
            if ($resumeAt -gt 0) { $note = 'Continuing at {0}' -f (Format-PlayTime $resumeAt); Write-Log INFO "Player: continuing $($playTarget.File.Id) at $resumeAt s" }
        } else {
            $mode = 'web'
            $note = if ($st -and $st.Encrypted) { 'Protected programme: playing on the NRK page' } else { 'No stream for the built-in player: playing on the NRK page' }
            Write-Log INFO "Player: $note ($($playTarget.File.Id))"
        }
    }
    try {
        $pw = Get-PlayerWindow
        $pw.Url = $playTarget.Url
        $pw.Target = $playTarget; $pw.Mode = $mode
        $x = $script:PlayerExtra; $script:PlayerExtra = $null
        $pw.SubList = if ($mode -eq 'builtin' -and $x) { $x.Subs } else { @() }; $pw.SubIndex = if ($x) { $x.SubIndex } else { -1 }
        $pw.Versions = if ($mode -eq 'builtin' -and $x) { $x.Versions } else { @() }; $pw.ATracks = @(); $pw.ATrack = -1
        Update-PlayerExtras
        $pw.Hint.Text = if ($note) { $note } else { 'Loading...' }
        Set-IconText $pw.BtnMode $(if ($mode -eq 'builtin') { 'web' } else { 'window' }) $(if ($mode -eq 'builtin') { 'Open NRK page' } elseif ($script:PlayerOnly) { 'Show full page' } else { 'Player only' })
        $pw.Form.Text = "$($playTarget.Title)  -  NRK"
        if (-not $pw.Form.Visible) {
            $pw.Form.Show()
            Enable-DarkTitleBar $pw.Form
        }
        if ($pw.Form.WindowState -eq 'Minimized') { $pw.Form.WindowState = 'Normal' }
        $pw.Form.Activate()
        Update-PlayerNav
        $go = if ($mode -eq 'builtin') { $script:VideoPlayerUrl } else { $playTarget.Url }
        $pw.Pending = $config
        if ($mode -eq 'builtin' -and $pw.VReady -and $pw.WebView.CoreWebView2 -and [string]$pw.WebView.Source -eq $script:VideoPlayerUrl) {
            Send-VideoConfig                                    # the page is already up: just switch stream
        } elseif ($pw.WebView.CoreWebView2) { $pw.WebView.CoreWebView2.Navigate($go) }
        else { $pw.WebView.Source = [Uri]$go }                   # first use: also initializes WebView2
        Set-Status $(if ($mode -eq 'builtin') { "Playing $($playTarget.Title) in the built-in player" } else { "Opening NRK player: $($playTarget.Url)" })
        # live channels have no .File; a finished programme from a channel's schedule keeps the channel
        $played = if ($playTarget.File) { $playTarget.File } elseif ($listFile) { $listFile } elseif ($script:SelectedFile -and $script:SelectedFile.Type -eq 'live') { $script:SelectedFile } else { $null }
        Save-LastPlayed $played 'video' $(if ($FromQueue) { $script:VideoQueueNode } else { $null })
        Add-RecentPlayed $played
    } catch {
        Write-LogException $_ 'Start-Player'
        Set-Status "Could not start the embedded player: $($_.Exception.Message)"
    }
}

function Stop-Player([switch] $KeepResume) {
    $pw = $script:PlayerWin
    if (-not $pw -or $pw.Form.IsDisposed) { return }
    if ($pw.Full) { Set-PlayerFullScreen $false }
    try { if ($pw.WebView.CoreWebView2) { $pw.WebView.CoreWebView2.Navigate('about:blank') } } catch { }
    $pw.Form.Hide()
    $pw.Url = $null; $pw.Paused = $true; $pw.Pending = $null; $pw.Target = $null
    try { Save-PosMap -Force } catch { }
    Set-TrayText ''
    if (-not $KeepResume) { Save-LastPlayed $null }          # stopped on purpose: nothing to continue (casting: it goes on)
    Write-Log INFO 'UI: player closed'
}

# ---- continue where you left off (Options): the folder and file that was playing -------
# Saved when something starts playing and cleared when you stop it yourself, so after a
# crash, a restart, an update or Windows shutting down, the app opens that folder again and
# plays the same file from the start (live channels: live). Saved as a JSON string in settings.

function Get-NodeKey($Node) {
    $t = $Node.Tag
    if (-not $t) { return '' }
    switch ($t.Kind) {
        { $_ -in 'category', 'letter', 'radiocategory', 'radioletter' } { return "$($t.Kind)|$($t.Id)" }
        'series'      { return "series|$($t.Item.Id)" }
        'season'      { return "season|$($t.Item.Id)|$($t.Season)" }
        'radioseries' { return "radioseries|$($t.Item.Kind)|$($t.Item.Id)" }
        'radioseason' { return "radioseason|$($t.Item.Id)|$($t.Season.Name)" }
        default       { return "$($t.Kind)|$($t.Title)" }
    }
}

function Save-LastPlayed($File, [string] $Player = '', $Node = $null, $Device = $null) {
    try {
        $s = Get-AppSettings
        if (-not $File) {
            if ($s.LastPlayed) { $s.LastPlayed = ''; Save-AppSettings $s }
            return
        }
        if (-not $s.ResumePlayback) { return }
        $folder = $Node
        if (-not $folder -or -not $folder.TreeView) {
            # only a file from the folder that is open (that is where a restart will look for it)
            $folder = $folderTree.SelectedNode
            $inList = $false; foreach ($f in @($script:Files)) { if ([object]::ReferenceEquals($f, $File)) { $inList = $true; break } }
            if (-not $folder -or -not $inList) { return }
        }
        $path = @(); for ($n = $folder; $n; $n = $n.Parent) { $path = @(Get-NodeKey $n) + $path }
        $rec = [ordered]@{ Path = $path; Id = [string]$File.Id; Type = [string]$File.Type; Title = [string]$File.Title; Player = $Player; Saved = (Get-Date).ToString('o') }
        if ($Device) { $rec.Device = [ordered]@{ Kind = $Device.Kind; Name = $Device.Name; Ip = $Device.Ip; Port = $Device.Port; Avt = $Device.Avt; Rc = $Device.Rc; Model = $Device.Model } }
        $s.LastPlayed = ($rec | ConvertTo-Json -Compress -Depth 4)
        Save-AppSettings $s
    } catch { Write-Log DEBUG "Resume: could not save the last played item: $($_.Exception.Message)" }
}

function Resume-LastPlayed {
    # on startup: open the folder that was playing and play that file again
    $s = Get-AppSettings
    if (-not $s.ResumePlayback -or -not $s.LastPlayed) { return }
    $last = $null; try { $last = $s.LastPlayed | ConvertFrom-Json } catch { }
    if (-not $last -or -not @($last.Path).Count) { return }
    Write-Log INFO ("Resume: opening '{0}' in {1}" -f $last.Title, (@($last.Path) -join ' > '))
    $nodes = $folderTree.Nodes; $target = $null
    # (saved before 2.7.9: the live folders were inside a LIVE folder and named differently)
    $old = @{ 'live|LIVE - TV' = 'live|LIVE TV'; 'radiolive|LIVE - Radio' = 'radiolive|LIVE Radio' }
    foreach ($key in @(@($last.Path) | Where-Object { $_ -ne 'group|LIVE' } | ForEach-Object { if ($old[$_]) { $old[$_] } else { $_ } })) {
        $hit = $null
        foreach ($n in $nodes) { if ((Get-NodeKey $n) -eq $key) { $hit = $n; break } }
        if (-not $hit) { Write-Log WARN "Resume: folder $key is gone"; Set-Status "Could not continue: '$($last.Title)' is no longer where it was"; return }
        $target = $hit
        if ($hit.Tag.Kind -in 'category', 'letter', 'radiocategory', 'radioletter', 'series', 'radioseries' -and -not $hit.Tag.Loaded) {
            if (-not (Expand-FolderNode $hit)) { Set-Status "Could not continue: '$($last.Title)' did not load"; return }
        }
        $hit.Expand()
        $nodes = $hit.Nodes
    }
    $script:CrumbNav = $true
    try { $folderTree.SelectedNode = $target; $target.EnsureVisible() } finally { $script:CrumbNav = $false }
    $file = @($script:Files | Where-Object { [string]$_.Id -eq [string]$last.Id -and [string]$_.Type -eq [string]$last.Type }) | Select-Object -First 1
    if (-not $file) { Write-Log WARN "Resume: $($last.Id) is not in that folder any more"; Set-Status "Continue: opened the folder, but '$($last.Title)' is not in it any more"; return }
    foreach ($row in $itemsList.Items) {
        if ([object]::ReferenceEquals($row.Tag, $file)) { $itemsList.SelectedItems.Clear(); $row.Selected = $true; $row.Focused = $true; $row.EnsureVisible(); break }
    }
    $script:SelectedFile = $file
    Set-Status "Continuing where you left off: $($last.Title)"
    # it was cast: to the same Chromecast or TV again
    if ($last.Player -eq 'cast' -and $last.Device -and $last.Device.Ip) { Write-Log INFO "Resume: casting to $($last.Device.Name) again"; Start-Cast ([pscustomobject]@{ Kind = [string]$last.Device.Kind; Name = [string]$last.Device.Name; Ip = [string]$last.Device.Ip; Port = [int]$last.Device.Port; Avt = [string]$last.Device.Avt; Rc = [string]$last.Device.Rc; Model = [string]$last.Device.Model }) $file; return }
    Start-Player
}

function Sync-PlayerPointer {
    # After the window changes size (full screen on/off) the page still believes the mouse is
    # where it was: now over the progress bar, so the controls and the preview picture stay up.
    # Tell it where the mouse really is (twice: some players re-layout a moment later).
    if (-not $script:PointerTimer) {
        $script:PointerTimer = New-Object System.Windows.Forms.Timer
        $script:PointerTimer.Add_Tick({
            $script:PointerTimer.Stop()
            $pw = $script:PlayerWin
            if (-not $pw -or $pw.Form.IsDisposed -or -not $pw.WebView.CoreWebView2) { return }
            try {
                $wv = $pw.WebView
                $pt = $wv.PointToClient([System.Windows.Forms.Cursor]::Position)
                $scale = ([double]$wv.DeviceDpi / 96.0) * [double]$wv.ZoomFactor
                if ($scale -le 0) { $scale = 1 }
                $x = [Math]::Max(0, [Math]::Min($wv.ClientSize.Width - 1, $pt.X)) / $scale
                $y = [Math]::Max(0, [Math]::Min($wv.ClientSize.Height - 1, $pt.Y)) / $scale
                $j = '{{"type":"mouseMoved","x":{0},"y":{1},"button":"none"}}' -f [int]$x, [int]$y
                [void]$wv.CoreWebView2.CallDevToolsProtocolMethodAsync('Input.dispatchMouseEvent', $j)
            } catch { Write-Log DEBUG "Pointer sync: $($_.Exception.Message)" }
            if ($script:PointerAgain) { $script:PointerAgain = $false; $script:PointerTimer.Interval = 900; $script:PointerTimer.Start() }
        })
    }
    $script:PointerAgain = $true
    $script:PointerTimer.Stop(); $script:PointerTimer.Interval = 350; $script:PointerTimer.Start()
}

function Set-PlayerFullScreen([bool] $On) {
    # NRK's fullscreen button only fills the WebView; make the player window follow it.
    $pw = $script:PlayerWin
    if (-not $pw -or $pw.Form.IsDisposed) { return }
    $f = $pw.Form
    if ($On -and -not $pw.Full) {
        $pw.Full = @{ Border = $f.FormBorderStyle; State = $f.WindowState; TopMost = $f.TopMost }
        $pw.Bar.Visible = $false
        $f.WindowState = 'Normal'
        $f.FormBorderStyle = 'None'
        Update-MaxBounds $f $true
        $f.WindowState = 'Maximized'; $f.TopMost = $true
        Sync-PlayerPointer
        Write-Log INFO 'Player entered full screen (Esc or F11 to leave)'
    } elseif (-not $On -and $pw.Full) {
        $pw.Bar.Visible = $true
        $prev = $pw.Full
        $pw.Full = $null
        # Go through Normal so Windows recomputes the maximized size with the border back on
        $f.WindowState = 'Normal'
        $f.FormBorderStyle = $prev.Border
        Update-MaxBounds $f $false
        $f.WindowState = $prev.State; $f.TopMost = $prev.TopMost
        try { [void]$pw.WebView.CoreWebView2.ExecuteScriptAsync('document.fullscreenElement && document.exitFullscreen()') } catch { }
        Sync-PlayerPointer
        Write-Log INFO 'Player left full screen'
    }
}

# ---- audio bar ---------------------------------------------------------------------
# Radio plays in a bar at the bottom of the main window, modelled on NRK's own web radio
# player: an HTML5 <audio> element fed by HLS (AAC, via hls.js) for programmes and live
# channels, or a plain MP3 file for podcasts. The page is served by the app itself at a
# radio.nrk.no address (intercepted, never fetched), so NRK's CDN treats it like their
# own player.

$script:AudioPlayerUrl = 'https://radio.nrk.no/__nrkb/player.html'
$script:VideoPlayerHtml = $script:VideoPlayerHtml.Replace('__HLSVER__', $script:HlsJsVersion)   # (the fallback link: the same hls.js version as the component)
$script:AudioPlayerHtml = @'
<!doctype html>
<html><head><meta charset="utf-8"><title>NRK audio</title>
<style>
:root { --bg:#1b2228; --surface:#242c33; --text:#e8eef2; --muted:#93a1ab; --accent:#38c6d4; --on:#0a1e22; --border:#2f3a42; --hover:#2a343c; }
* { box-sizing:border-box; }
html, body { margin:0; height:100%; background:var(--bg); color:var(--text); font:13px "Segoe UI", system-ui, sans-serif; overflow:hidden; user-select:none; }
.bar { display:grid; grid-template-columns:minmax(170px,1fr) minmax(300px,2.2fr) minmax(190px,1fr); align-items:center; height:100%; padding:0 18px; gap:18px; }
.info { display:flex; align-items:center; gap:12px; min-width:0; }
.art { width:56px; height:56px; border-radius:6px; background:var(--surface) center/cover no-repeat; flex:none; }
.titles { min-width:0; }
.t1 { font-weight:600; font-size:14px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.t2 { color:var(--muted); font-size:12px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; margin-top:3px; }
.t2.err { color:#ec6a6a; white-space:normal; }
.mid { display:flex; flex-direction:column; gap:2px; min-width:0; }
.ctrls { display:flex; justify-content:center; align-items:center; gap:22px; }
.nav { display:none; } body.has-nav .nav { display:inline-flex; }
button { background:none; border:0; color:var(--text); cursor:pointer; padding:5px; border-radius:50%; display:inline-flex; align-items:center; justify-content:center; font:inherit; }
button:hover { background:var(--hover); }
#sleep.on, #fx.on { color:var(--accent); }
button:disabled { opacity:.35; cursor:default; background:none; }
button svg { width:24px; height:24px; fill:none; stroke:currentColor; stroke-width:1.7; stroke-linecap:round; stroke-linejoin:round; }
button svg text { fill:currentColor; stroke:none; font:700 7px "Segoe UI", sans-serif; }
#play { width:42px; height:42px; background:var(--accent); color:var(--on); }
#play:hover { filter:brightness(1.12); }
#play svg { fill:currentColor; stroke:none; width:20px; height:20px; }
.prog { display:flex; align-items:center; gap:10px; font-size:12px; color:var(--muted); font-variant-numeric:tabular-nums; }
.prog .time { min-width:46px; text-align:center; }
input[type=range] { -webkit-appearance:none; appearance:none; background:transparent; height:16px; margin:0; cursor:pointer; }
input[type=range]:disabled { cursor:default; }
input[type=range]::-webkit-slider-runnable-track { height:3px; border-radius:2px; background:linear-gradient(to right, var(--accent) 0 var(--p,0%), var(--border) var(--p,0%) 100%); }
input[type=range]::-webkit-slider-thumb { -webkit-appearance:none; width:12px; height:12px; border-radius:50%; background:var(--text); margin-top:-4.5px; border:0; }
#seek { flex:1; min-width:60px; }
.right { display:flex; justify-content:flex-end; align-items:center; gap:8px; }
#speed { font-weight:600; border-radius:6px; padding:4px 8px; min-width:46px; }
#vol { width:86px; flex:none; }
.live { display:none; font-size:11px; font-weight:700; letter-spacing:.06em; padding:2px 9px; border-radius:10px; border:1px solid var(--muted); color:var(--muted); cursor:pointer; }
.live.on { border-color:#e85454; background:#e85454; color:#fff; cursor:default; }
body.is-live .live { display:inline-block; }
@media (max-width: 760px) { #vol, #speed { display:none; } .bar { gap:10px; } }
</style></head>
<body>
<div class="bar">
  <div class="info">
    <div class="art" id="art"></div>
    <div class="titles"><div class="t1" id="t1">Nothing playing</div><div class="t2" id="t2"></div></div>
  </div>
  <div class="mid">
    <div class="ctrls">
      <button id="prev" class="nav" title="Previous episode"><svg viewBox="0 0 24 24"><path d="M6 5v14"/><path d="M19 5L9 12l10 7z" fill="currentColor"/></svg></button>
      <button id="back" title="Back 15 seconds (Left)"><svg viewBox="0 0 24 24"><path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3"/><path d="M4.5 3.5v4h4"/><text x="12.2" y="15" text-anchor="middle">15</text></svg></button>
      <button id="play" title="Play / pause (Space)"></button>
      <button id="fwd" title="Forward 15 seconds (Right)"><svg viewBox="0 0 24 24"><path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3"/><path d="M19.5 3.5v4h-4"/><text x="11.8" y="15" text-anchor="middle">15</text></svg></button>
      <button id="next" class="nav" title="Next episode"><svg viewBox="0 0 24 24"><path d="M18 5v14"/><path d="M5 5l10 7-10 7z" fill="currentColor"/></svg></button>
    </div>
    <div class="prog">
      <span class="time" id="cur">0:00</span>
      <input id="seek" type="range" min="0" max="1000" value="0">
      <span class="time" id="dur">0:00</span>
      <span class="live" id="live" title="Jump to live">DIREKTE</span>
    </div>
  </div>
  <div class="right">
    <button id="fx" title="Sound: skip silences, voice boost, settings for this series"><svg viewBox="0 0 24 24"><path d="M4 14v-4M8 17V7M12 20V4M16 16V8M20 13v-2"/></svg></button>
    <button id="mini" title="Small radio window that stays on top"><svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="2"/><rect x="12" y="12" width="7" height="5" rx="1" fill="currentColor"/></svg></button>
    <button id="sleep" title="Sleep timer"><svg viewBox="0 0 24 24"><path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/></svg></button>
    <button id="speed" title="Playback speed">1x</button>
    <button id="mute" title="Mute"></button>
    <input id="vol" type="range" min="0" max="100" value="100" title="Volume">
    <button id="open" title="Open on radio.nrk.no"><svg viewBox="0 0 24 24"><path d="M14 4h6v6"/><path d="M20 4l-9 9"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/></svg></button>
    <button id="close" title="Stop and close"><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
  </div>
</div>
<audio id="a" preload="auto"></audio>
<script src="hls.min.js"></script>
<script>if (!window.Hls) document.write('<script src="https://cdn.jsdelivr.net/npm/hls.js@__HLSVER__/dist/hls.min.js"><\/script>');</script>
<script>
(() => {
  const $ = id => document.getElementById(id);
  let a = $('a');
  const seek = $('seek'), vol = $('vol');
  const post = m => { try { window.chrome.webview.postMessage(JSON.stringify(m)); } catch (e) { } };
  const ICON = {
    play:  '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>',
    pause: '<svg viewBox="0 0 24 24"><path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z"/></svg>',
    vol:   '<svg viewBox="0 0 24 24"><path d="M4 9.5v5h3.5L12 18V6L7.5 9.5z"/><path d="M15.5 9.5a3.5 3.5 0 0 1 0 5"/><path d="M18 7a7 7 0 0 1 0 10"/></svg>',
    muted: '<svg viewBox="0 0 24 24"><path d="M4 9.5v5h3.5L12 18V6L7.5 9.5z"/><path d="M16 9.5l5 5M21 9.5l-5 5"/></svg>'
  };
  const SPEEDS = [1, 1.25, 1.5, 2, 0.75];
  const store = {
    get(k, d) { try { const v = localStorage.getItem('nrkb.' + k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem('nrkb.' + k, JSON.stringify(v)); } catch (e) { } }
  };
  let hls = null, cur = null, live = false, dragging = false, retries = 0, announced = false, reconnects = 0, reconnectTimer = null;
  // 2.9.0: base speed (skip silences speeds up only the quiet parts), sound effects, songs
  let base = 1, outroHit = false, songs = [];
  const fx = { silence: false, boost: false };
  let ctx = null, noFx = false, fast = false, quiet = 0, saved = 0;
  const graphs = new WeakMap();
  a.volume = Math.min(1, Math.max(0, store.get('vol', 1)));
  a.muted = !!store.get('muted', false);

  const fmt = s => {
    if (!isFinite(s) || s < 0) s = 0;
    s = Math.floor(s);
    const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60;
    return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(x).padStart(2, '0');
  };
  const fmtRate = r => (Math.round(r * 100) / 100) + 'x';
  function span() {   // the part that can be played: whole file, or the live buffer
    if (live) return a.seekable.length ? [a.seekable.start(0), a.seekable.end(a.seekable.length - 1)] : [0, 0];
    return [0, isFinite(a.duration) ? a.duration : 0];
  }
  function render() {
    const [s, e] = span(), len = Math.max(0, e - s);
    if (!dragging) seek.value = len ? Math.round(Math.min(Math.max(a.currentTime - s, 0), len) / len * 1000) : (live ? 1000 : 0);
    seek.style.setProperty('--p', (seek.value / 10) + '%');
    if (live) {
      const behind = Math.max(0, e - a.currentTime);
      $('cur').textContent = behind > 25 ? '-' + fmt(behind) : '';
      $('dur').textContent = '';
      $('live').classList.toggle('on', behind <= 25);
    } else {
      $('cur').textContent = fmt(dragging ? seek.value / 1000 * len : a.currentTime);
      $('dur').textContent = fmt(e);
    }
    $('play').innerHTML = a.paused ? ICON.play : ICON.pause;
    $('mute').innerHTML = (a.muted || a.volume === 0) ? ICON.muted : ICON.vol;
    vol.value = a.muted ? 0 : Math.round(a.volume * 100);
    vol.style.setProperty('--p', vol.value + '%');
    seek.disabled = !len;
    $('back').disabled = $('fwd').disabled = !len;
    $('play').disabled = !cur;
  }
  function message(text, isError) {
    const t2 = $('t2');
    if (!isError && songs.length && live) text = (text ? text + '   ·   ' : '') + '\u266a ' + songs[0];
    t2.textContent = text; t2.title = text; t2.classList.toggle('err', !!isError);
  }
  function fail(text) {
    // live radio: the stream sometimes drops (network change, sleep); reconnect a few times
    if (live && cur && reconnects < 6) {
      reconnects++;
      message('Connection lost - reconnecting (' + reconnects + ')...', false);
      post({ type: 'log', msg: 'live stream lost (' + text + '), reconnect ' + reconnects });
      clearTimeout(reconnectTimer);
      const o = cur;
      reconnectTimer = setTimeout(() => { if (cur === o) load(o, true); }, 4000);
      return;
    }
    message(text, true); post({ type: 'error', msg: text }); render();
  }
  function stop() {
    if (hls) { try { hls.destroy(); } catch (e) { } hls = null; }
    a.pause(); a.removeAttribute('src'); try { a.load(); } catch (e) { }
  }
  function skip(sec) {
    const [s, e] = span();
    if (e - s <= 0) return;
    a.currentTime = Math.min(Math.max(a.currentTime + sec, s), e - (live ? 3 : 0.25));
  }
  function play() { const p = a.play(); if (p && p.catch) p.catch(e => { if (e.name !== 'AbortError') post({ type: 'log', msg: 'play() refused: ' + e.name }); }); }   // AbortError: a new source replaced it
  function setSession(o) {
    if (!('mediaSession' in navigator)) return;
    try {
      navigator.mediaSession.metadata = new MediaMetadata({ title: o.title || '', artist: o.subtitle || 'NRK Radio', album: 'NRK Radio',
        artwork: o.image ? [{ src: o.image, sizes: '600x600' }] : [] });
    } catch (e) { }
    const h = (n, f) => { try { navigator.mediaSession.setActionHandler(n, f); } catch (e) { } };
    h('play', play); h('pause', () => a.pause());
    h('seekbackward', () => skip(-15)); h('seekforward', () => skip(15));
    h('nexttrack', () => post({ type: 'next' })); h('previoustrack', () => post({ type: 'prev' }));
  }
  function load(o, again) {
    stop();
    clearTimeout(reconnectTimer);
    if (!again) reconnects = 0;
    cur = o; live = !!o.live; retries = 0; announced = false;
    document.body.classList.toggle('is-live', live);
    $('t1').textContent = o.title || ''; $('t1').title = o.title || '';
    message(o.subtitle || '', false);
    $('art').style.backgroundImage = o.image ? 'url("' + String(o.image).replace(/"/g, '%22') + '")' : 'none';
    base = live ? 1 : (o.rate > 0 ? o.rate : store.get('rate', 1)); fast = false; quiet = 0; outroHit = false;
    if (!o.live) songs = [];
    a.defaultPlaybackRate = a.playbackRate = base;
    $('speed').disabled = live;
    $('speed').textContent = fmtRate(base);
    // skip the intro (this series' setting): start there unless you were further already
    if (!live && o.intro > 0 && !(o.start > o.intro)) { o.start = o.intro; }
    const wantFx = (fx.silence || fx.boost) && !noFx;
    const isHls = /hls|mpegurl/i.test((o.format || '') + ' ' + (o.mime || '')) || /\.m3u8/i.test(o.url || '');
    if (isHls && !a.canPlayType('application/vnd.apple.mpegurl')) {
      if (!window.Hls || !window.Hls.isSupported()) { fail('Could not load the HLS player (hls.js from cdn.jsdelivr.net). Check the internet connection.'); return; }
      hls = new window.Hls({ enableWorker: true, startPosition: o.start || -1 });
      hls.on(window.Hls.Events.ERROR, (ev, d) => {
        if (!d.fatal) return;
        // startLoad() only resumes segment loading; a playlist that never loaded needs a fresh load
        const manifest = /^manifest|^levelLoad/.test(d.details || '');
        if (d.type === window.Hls.ErrorTypes.NETWORK_ERROR && !manifest && retries++ < 3) { post({ type: 'log', msg: 'network error, retrying: ' + d.details }); hls.startLoad(); return; }
        if (d.type === window.Hls.ErrorTypes.MEDIA_ERROR && retries++ < 3) { post({ type: 'log', msg: 'media error, recovering: ' + d.details }); hls.recoverMediaError(); return; }
        fail('Playback failed (' + d.details + ')');
      });
      hls.loadSource(o.url);
      hls.attachMedia(a);
    } else {
      // a plain file from another site: the sound effects need it fetched with CORS. A tiny test
      // request first; if that site says no, it plays without them (and the 'error' handler too)
      const go = cors => {
        if (cur !== o) return;
        if (graphs.has(a) && !cors) renewElement();   // (through Web Audio a no-CORS file would play silent)
        if (cors) a.crossOrigin = 'anonymous'; else a.removeAttribute('crossorigin');
        if (!cors && wantFx) { o.noCors = true; message((o.subtitle ? o.subtitle + '   ·   ' : '') + 'sound effects not available for this file', false); post({ type: 'log', msg: 'no CORS for this file: playing without the sound effects' }); }
        a.src = o.url;
        if (o.start) a.addEventListener('loadedmetadata', () => { try { a.currentTime = o.start; } catch (e) { } }, { once: true });
        if (cors) useFx();
        play(); render();
      };
      if (wantFx && !o.noCors) fetch(o.url, { headers: { Range: 'bytes=0-1' }, mode: 'cors', cache: 'no-store' }).then(r => go(r.ok || r.status === 206)).catch(() => go(false));
      else go(false);
      setSession(o);
      render();
      return;
    }
    if (wantFx) useFx();
    play();
    setSession(o);
    render();
  }

  // ---- sound effects (Web Audio): voice boost (a compressor that lifts quiet speech) and skip
  // silences (the quiet parts play faster; the speed button keeps your own speed)
  function graph() {
    if (graphs.has(a)) return graphs.get(a);
    if (!ctx) { const C = window.AudioContext || window.webkitAudioContext; if (!C) return null; ctx = new C(); }
    const g = { src: ctx.createMediaElementSource(a), comp: ctx.createDynamicsCompressor(), gain: ctx.createGain(), an: ctx.createAnalyser() };
    g.comp.threshold.value = -30; g.comp.knee.value = 12; g.comp.ratio.value = 5; g.comp.attack.value = 0.004; g.comp.release.value = 0.25;
    g.an.fftSize = 2048; g.buf = new Float32Array(g.an.fftSize);
    graphs.set(a, g); sinkSync(true);
    return g;
  }
  function route() {
    const g = graphs.get(a); if (!g) return;
    try { g.src.disconnect(); g.comp.disconnect(); g.gain.disconnect(); g.an.disconnect(); } catch (e) { }
    if (fx.boost) { g.src.connect(g.comp); g.comp.connect(g.gain); g.gain.gain.value = 1.8; g.gain.connect(g.an); }
    else g.src.connect(g.an);
    g.an.connect(ctx.destination);
  }
  function useFx() { try { if (graph()) { route(); if (ctx.state !== 'running') ctx.resume(); } } catch (e) { post({ type: 'log', msg: 'sound effects not available: ' + e }); } }
  function sinkSync(force) {
    // the chosen sound output (Options > Playback) also for the effects' path
    try { const s = window.__nrkbSink; if (ctx && s && typeof ctx.setSinkId === 'function' && (force || ctx.sinkId !== s.id)) ctx.setSinkId(s.id || '').catch(() => { }); } catch (e) { }
  }
  setInterval(() => sinkSync(false), 3000);
  setInterval(() => {
    const g = graphs.get(a);
    if (!fx.silence || live || !g || a.paused || !cur) { if (fast) { fast = false; a.playbackRate = base; } return; }
    g.an.getFloatTimeDomainData(g.buf);
    let sum = 0; for (let i = 0; i < g.buf.length; i++) sum += g.buf[i] * g.buf[i];
    const rms = Math.sqrt(sum / g.buf.length);
    if (rms < 0.008) quiet += 100; else if (rms > 0.012) quiet = 0;
    if (!fast && quiet >= 400) { fast = true; a.playbackRate = Math.min(4, base * 2.5); }
    else if (fast && quiet === 0) { fast = false; a.playbackRate = base; }
    if (fast) saved += 0.1 * (a.playbackRate / base - 1);
    $('fx').title = 'Sound: skip silences' + (fx.boost ? ', voice boost' : '') + (saved >= 1 ? '  (saved ' + fmt(saved) + ')' : '');
  }, 100);
  function renewElement() {
    // a fresh <audio> (one that went through Web Audio can't play a no-CORS file with sound)
    const old = a, n = document.createElement('audio');
    n.preload = 'auto'; n.volume = old.volume; n.muted = old.muted;
    try { old.pause(); old.removeAttribute('src'); old.load(); } catch (e) { }
    old.replaceWith(n); n.id = 'a'; a = n; wire(a);
  }
  let lastPos = 0;
  const pos = force => { const n = Date.now(); if (!cur || live || !(a.currentTime > 0)) return; if (!force && n - lastPos < 5000) return; lastPos = n; post({ type: 'apos', t: a.currentTime, d: isFinite(a.duration) ? a.duration : 0 }); };
  function wire(a) {
  ['timeupdate', 'play', 'pause', 'durationchange', 'progress', 'volumechange', 'ratechange', 'loadedmetadata', 'seeked'].forEach(n => a.addEventListener(n, render));
  a.addEventListener('playing', () => { if (reconnects) { message(cur && cur.subtitle || '', false); reconnects = 0; } if (!announced) { announced = true; post({ type: 'playing' }); } });
  a.addEventListener('ended', () => { render(); post({ type: 'ended', t: a.currentTime, d: a.duration || 0 }); });
  // where you are (not for live radio), every 5 s and on pause/seek, so it continues there next time
  a.addEventListener('timeupdate', () => pos(false));
  // skip the outro (this series' setting): the last N seconds count as the end
  a.addEventListener('timeupdate', () => {
    if (!cur || live || outroHit || !(cur.outro > 0) || !isFinite(a.duration) || a.duration < cur.outro * 2 + 10) return;   // (not on files hardly longer than the part to skip)
    if (a.duration - a.currentTime <= cur.outro) { outroHit = true; a.pause(); render(); post({ type: 'ended', t: a.duration, d: a.duration, outro: true }); }
  });
  a.addEventListener('pause', () => pos(true));
  a.addEventListener('seeked', () => pos(true));
  ['play', 'pause', 'volumechange'].forEach(n => a.addEventListener(n, () => post({ type: 'state', paused: a.paused, muted: a.muted })));
  a.addEventListener('error', () => {
    if (!hls && cur && a.crossOrigin && !cur.noCors) {
      // the file's site doesn't allow the sound effects: play it without them
      post({ type: 'log', msg: 'no CORS for this file: playing without the sound effects' });
      const o = Object.assign({}, cur, { noCors: true, start: a.currentTime || cur.start }); renewElement(); load(o, true);
      message((o.subtitle ? o.subtitle + '   ·   ' : '') + 'sound effects not available for this file', false);
      return;
    }
    if (!hls && cur) fail('Could not play this file (media error ' + (a.error ? a.error.code : '?') + ')');
  });
  }
  wire(a);

  seek.addEventListener('input', () => { dragging = true; render(); });
  seek.addEventListener('change', () => {
    const [s, e] = span();
    a.currentTime = s + seek.value / 1000 * (e - s);
    dragging = false; render();
  });
  $('play').onclick = () => { if (!cur) return; if (a.paused) play(); else a.pause(); };
  $('back').onclick = () => skip(-15);
  $('prev').onclick = () => post({ type: 'prev' });
  $('next').onclick = () => post({ type: 'next' });
  $('fwd').onclick = () => skip(15);
  $('live').onclick = () => { const [, e] = span(); if (e) a.currentTime = e - 3; play(); };
  $('speed').onclick = () => {
    const i = SPEEDS.indexOf(base);
    base = SPEEDS[(i + 1) % SPEEDS.length];
    fast = false; a.playbackRate = base;
    // a series with its own speed keeps it there (the app saves it); otherwise the general one
    if (cur && cur.key) post({ type: 'rate', key: cur.key, rate: base }); else store.set('rate', base);
    $('speed').textContent = fmtRate(base);
  };
  $('fx').onclick = () => { const r = $('fx').getBoundingClientRect(); post({ type: 'fx', x: r.left, y: r.top }); };
  $('mini').onclick = () => post({ type: 'mini' });
  $('mute').onclick = () => { a.muted = !a.muted; if (!a.muted && a.volume === 0) a.volume = 0.5; store.set('muted', a.muted); };
  vol.addEventListener('input', () => { a.volume = vol.value / 100; a.muted = a.volume === 0; store.set('vol', a.volume); store.set('muted', a.muted); });
  $('open').onclick = () => { if (cur && cur.webUrl) post({ type: 'open', url: cur.webUrl }); };
  $('sleep').onclick = () => { const r = $('sleep').getBoundingClientRect(); post({ type: 'sleep', x: r.left, y: r.bottom }); };
  $('close').onclick = () => { stop(); cur = null; post({ type: 'close' }); };
  window.addEventListener('keydown', e => {
    if (e.key === ' ' || e.key === 'k') { e.preventDefault(); $('play').onclick(); }
    else if (e.key === 'ArrowLeft' && e.target !== vol) { e.preventDefault(); skip(-15); }
    else if (e.key === 'ArrowRight' && e.target !== vol) { e.preventDefault(); skip(15); }
  });

  window.nrkb = {
    load,
    stop() { stop(); cur = null; render(); },
    toggle() { $('play').onclick(); },
    setPaused(p) { if (!cur) return; if (p) a.pause(); else play(); },
    setMuted(m) { a.muted = !!m; store.set('muted', a.muted); },
    setNav(n) {
      // previous / next in the list it was started from (titles, or null at either end)
      const on = !!(n && (n.prev !== undefined || n.next !== undefined) && n.count > 1);
      document.body.classList.toggle('has-nav', on);
      $('prev').disabled = !(n && n.prev); $('next').disabled = !(n && n.next);
      $('prev').title = n && n.prev ? 'Previous: ' + n.prev : 'This is the first one';
      $('next').title = n && n.next ? 'Next: ' + n.next : 'This is the last one';
    },
    theme(t) { for (const k in t) document.documentElement.style.setProperty('--' + k, t[k]); },
    setSleep(on, label) { $('sleep').classList.toggle('on', !!on); $('sleep').title = on ? 'Sleep timer: ' + label : 'Sleep timer'; },
    // 2.9.0
    skip(sec) { skip(sec); },
    setFx(o) {
      fx.silence = !!o.silence; fx.boost = !!o.boost;
      $('fx').classList.toggle('on', fx.silence || fx.boost);
      if ((fx.silence || fx.boost) && cur && !hls && !cur.noCors && !a.crossOrigin) { const p = Object.assign({}, cur, { start: a.currentTime }); load(p, true); return; }   // (a plain file needs to be fetched again with CORS)
      if (fx.silence || fx.boost) { if (cur && !(cur.noCors && !hls)) useFx(); } else route();
      if (!fx.silence && fast) { fast = false; a.playbackRate = base; }
    },
    setRate(r) { if (live || !(r > 0)) return; base = r; fast = false; a.playbackRate = r; $('speed').textContent = fmtRate(r); },
    setSkip(o) { if (cur) { cur.intro = +o.intro || 0; cur.outro = +o.outro || 0; } },
    song(list) { songs = list || []; if (cur) message(cur.subtitle || '', false); $('t2').title = songs.length ? 'Played on ' + (cur && cur.title || '') + ':\n' + songs.join('\n') : ''; },
    fade(sec) { if (fadeFrom === null) fadeFrom = a.volume; clearInterval(fadeTimer); const steps = Math.max(1, Math.round(sec * 4)); let n = 0; fadeTimer = setInterval(() => { n++; a.volume = Math.max(0, fadeFrom * (1 - n / steps)); if (n >= steps) clearInterval(fadeTimer); }, 250); },
    unfade() { clearInterval(fadeTimer); if (fadeFrom !== null) { a.volume = fadeFrom; fadeFrom = null; } },
    fadeIn(sec) { const to = a.volume || 1; a.volume = 0; clearInterval(fadeTimer); const steps = Math.max(1, Math.round(sec * 4)); let n = 0; fadeTimer = setInterval(() => { n++; a.volume = Math.min(to, to * n / steps); if (n >= steps) clearInterval(fadeTimer); }, 250); },
    vol(d) { a.muted = false; a.volume = Math.min(1, Math.max(0, a.volume + d)); store.set('vol', a.volume); store.set('muted', false); },
    state() { return JSON.stringify({ title: cur ? cur.title : '', sub: cur ? (live && songs.length ? '\u266a ' + songs[0] : cur.subtitle) : '', paused: a.paused, live: live, t: a.currentTime || 0, d: isFinite(a.duration) ? a.duration : 0 }); }
  };
  let fadeTimer = null, fadeFrom = null;
  render();
  post({ type: 'ready', hls: !!window.Hls });
})();
</script>
</body></html>
'@
$script:AudioPlayerHtml = $script:AudioPlayerHtml.Replace('__HLSVER__', $script:HlsJsVersion)

function ConvertTo-CssColor([System.Drawing.Color] $Color) { '#{0:x2}{1:x2}{2:x2}' -f $Color.R, $Color.G, $Color.B }

function Get-AudioThemeJson {
    [ordered]@{
        bg = ConvertTo-CssColor $T.Panel; surface = ConvertTo-CssColor $T.Surface; text = ConvertTo-CssColor $T.Text
        muted = ConvertTo-CssColor $T.Muted; accent = ConvertTo-CssColor $T.Accent; on = ConvertTo-CssColor $T.OnAccent
        border = ConvertTo-CssColor $T.Border; hover = ConvertTo-CssColor $T.Hover
    } | ConvertTo-Json -Compress
}

$script:AudioUi = @{ WebView = $null; Ready = $false; Last = $null; Current = $null; Queue = @(); Index = -1 }

function Invoke-AudioScript([string] $Js) {
    $u = $script:AudioUi
    if (-not $u.Ready -or -not $u.WebView -or -not $u.WebView.CoreWebView2) { return }
    try { [void]$u.WebView.CoreWebView2.ExecuteScriptAsync($Js) } catch { Write-Log WARN "Audio player script failed: $($_.Exception.Message)" }
}

function Update-AudioTheme {
    if ($script:AudioUi.WebView) { try { $script:AudioUi.WebView.DefaultBackgroundColor = $T.Panel } catch { } }
    Invoke-AudioScript ("window.nrkb && nrkb.theme({0})" -f (Get-AudioThemeJson))
}

function Invoke-AudioMessage {
    param($Message)
    $u = $script:AudioUi
    switch ([string]$Message.type) {
        'ready' {
            $u.Ready = $true
            Write-Log INFO "Audio player page ready (hls.js loaded: $($Message.hls))"
            if ((Get-AppSettings).AudioDevice) { Set-AudioSinkPermission $true; Send-AudioSink }
            Update-AudioTheme
            Send-AudioFx
            if ($u.Last) { Invoke-AudioScript "nrkb.load($($u.Last))"; Invoke-AudioScript "nrkb.setNav($(Get-AudioNavJson))" }
        }
        'playing' { Write-Log INFO "Audio: playing $($u.Current.Title)"; Set-Status "Playing: $($u.Current.Title)"; Set-TrayText $u.Current.Title }
        'state'   { $u.Paused = [bool]$Message.paused; $u.Muted = [bool]$Message.muted }
        'apos'    { Set-PlayPosition $u.Current ([double]$Message.t) ([double]$Message.d) }
        'ended'   {
            Set-PlayPosition $u.Current ([double]$Message.t) ([double]$Message.d) -Ended; Write-Log INFO "Audio: finished $($u.Current.Title)"
            if (Test-SleepAtEnd) { return }
            if ((Get-AppSettings).AutoNext -or ($u.UserQueue -and $u.UserQueue.Count)) { Start-NextAudio 1 }
        }
        'sleep'   { Show-SleepMenu $null }
        'rate'    { if ($Message.key -and $u.Current) { Set-SeriesPref ([string]$Message.key) ([string]$(if ($u.Current.SeriesTitle) { $u.Current.SeriesTitle } else { $u.Current.Title })) @{ Rate = [double]$Message.rate }; Write-Log INFO "Audio: speed $($Message.rate)x kept for $($Message.key)" } }
        'fx'      { Show-AudioFxMenu }
        'mini'    { Show-RadioMini }
        'next'    { Start-NextAudio 1 }
        'prev'    { Start-NextAudio -1 }
        'error'   { Write-Log ERROR "Audio player: $($Message.msg) ($($u.Current.ManifestPath))"; Set-Status "Audio: $($Message.msg)" }
        'log'     { Write-Log INFO "Audio player: $($Message.msg)" }
        'open'    { if ($Message.url) { Write-Log INFO "Audio: open $($Message.url)"; Start-Process ([string]$Message.url) } }
        'close'   { Stop-AudioPlayer }
    }
}

function New-AudioWebView {
    $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
    # same folder and arguments as the video player, so both share one browser process
    $props.UserDataFolder = Join-Path $script:AppDataDir 'WebView2Data'
    $props.AdditionalBrowserArguments = '--autoplay-policy=no-user-gesture-required'
    $wv.CreationProperties = $props
    $wv.DefaultBackgroundColor = $T.Panel
    $wv.Dock = 'Fill'
    $wv.Add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) {
            $ex = $e.InitializationException
            Write-Log ERROR ("Audio player: WebView2 initialization failed: {0}" -f $ex.Message)
            Set-Status "Audio player failed to start: $($ex.Message)  (details in Logs)"
            return
        }
        $core = $s.CoreWebView2
        [void]$core.AddScriptToExecuteOnDocumentCreatedAsync($script:AudioSinkJs)   # sound output (Options > Playback)
        $core.Settings.IsStatusBarEnabled = $false
        $core.Settings.AreDefaultContextMenusEnabled = $false
        $core.Settings.IsZoomControlEnabled = $false
        # serve the player page from memory
        $core.AddWebResourceRequestedFilter('https://radio.nrk.no/__nrkb/*', [Microsoft.Web.WebView2.Core.CoreWebView2WebResourceContext]::All)
        $core.add_WebResourceRequested({
            param($c, $a)
            try {
                $uri = [string]$a.Request.Uri
                if ($uri -match '/hls\.min\.js(\?|$)') {
                    # the locally installed copy (Options > Components...)
                    $hls = Find-HlsJs
                    if ($hls) {
                        $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($hls))
                        $a.Response = $c.Environment.CreateWebResourceResponse($ms, 200, 'OK', 'Content-Type: application/javascript; charset=utf-8')
                    } else {
                        Write-Log WARN 'Audio player: hls.js is not installed locally; falling back to cdn.jsdelivr.net'
                        $a.Response = $c.Environment.CreateWebResourceResponse($null, 404, 'Not Found', '')
                    }
                    return
                }
                $bytes = [Text.Encoding]::UTF8.GetBytes($script:AudioPlayerHtml)
                $ms = New-Object IO.MemoryStream(, $bytes)
                $a.Response = $c.Environment.CreateWebResourceResponse($ms, 200, 'OK', "Content-Type: text/html; charset=utf-8`r`nCache-Control: no-store")
            } catch { Write-LogException $_ 'Audio player page' }
        })
        $core.add_NewWindowRequested({ param($c, $a) $a.Handled = $true; Start-Process ([string]$a.Uri) })
        $core.add_ProcessFailed({
            param($c, $a)
            Write-Log ERROR "Audio player process failed: $($a.ProcessFailedKind) reason=$($a.Reason)"
            $script:AudioUi.Ready = $false
            try { $c.Reload() } catch { }
        })
        $core.add_WebMessageReceived({
            param($c, $a)
            try { $m = $a.TryGetWebMessageAsString() | ConvertFrom-Json } catch { return }
            Invoke-AudioMessage $m
        })
        $core.add_NavigationStarting({ param($c, $a) $script:AudioUi.Ready = $false })
        Write-Log INFO 'Audio player: WebView2 ready, loading player page'
        $core.Navigate($script:AudioPlayerUrl)
    })
    return $wv
}

function Show-AudioBar {
    $u = $script:AudioUi
    $audioBar.Visible = $true
    if (-not $u.WebView) {
        $u.WebView = New-AudioWebView
        $audioHost.Controls.Add($u.WebView)
        [void]$u.WebView.EnsureCoreWebView2Async($null)
    }
}

function Start-AudioPlayer {
    # Plays a radio channel or recording in the audio bar.
    param($File, [switch] $FromQueue)
    if (-not $File -or -not $File.ManifestPath) { return }
    if (-not (Test-ChildAllowed $File)) { return }
    Write-Log INFO "UI: listen $($File.Type) $($File.Id) ($($File.ManifestPath))"
    if (-not (Initialize-WebView2)) {
        $msg = "The audio player needs WebView2, which is not available:`n`n$($script:WebView2.Error)`n`nOpen it on radio.nrk.no in your web browser instead?"
        if ([System.Windows.Forms.MessageBox]::Show($form, $msg, 'Audio player', 'YesNo', 'Warning') -eq 'Yes') { Start-Process $File.WebUrl }
        return
    }
    $res = @{ Stream = $null }
    Invoke-Ui "Loading audio stream for $($File.Id)" { $res.Stream = Get-NrkAudioStream -ManifestPath $File.ManifestPath }
    $st = $res.Stream
    if (-not $st) { return }
    if (-not $st.Playable -or -not $st.Url) {
        $why = if ($st.Reason) { $st.Reason } else { 'NRK does not offer it for playback right now.' }
        Set-Status "Cannot play $($File.Title): $why"
        [void][System.Windows.Forms.MessageBox]::Show($form, "$($File.Title)`n`n$why", 'Not playable', 'OK', 'Information')
        return
    }
    # one thing at a time: radio closes the video player
    $pw = $script:PlayerWin
    if ($pw -and -not $pw.Form.IsDisposed -and $pw.Url -and (Get-AppSettings).OnePlayer) { Write-Log INFO 'Playback: closing the video player for the radio'; Stop-Player }
    $u = $script:AudioUi
    if (-not $FromQueue) {
        # the list it was started from, so the next episode follows automatically
        $u.Queue = @($script:Files | Where-Object { $_.Type -eq 'audio' -and $_.Playable })
        $u.QueueNode = $folderTree.SelectedNode
        if ((Get-FolderTag).Kind -in $script:MixedKinds) { $u.Queue = @() }   # a mixed list: no "next episode"
        $u.Index = -1
        for ($i = 0; $i -lt $u.Queue.Count; $i++) { if ([object]::ReferenceEquals($u.Queue[$i], $File)) { $u.Index = $i; break } }
        if ($File.Type -ne 'audio' -or $u.Index -lt 0) { $u.Queue = @(); $u.Index = -1 }
    }
    $u.Current = $File
    $pref = if ($File.Type -eq 'audio') { Get-SeriesPref (Get-SeriesPrefKey $File) } else { @{ Rate = 0.0; Intro = 0; Outro = 0 } }
    $sub = if ($File.Type -eq 'radiolive') { 'Direkte' } else { (@($File.SeriesTitle, $File.Date) | Where-Object { $_ }) -join '  ·  ' }
    $u.Last = [ordered]@{
        url = $st.Url; format = $st.Format; mime = $st.Mime; live = [bool]$st.Live
        # (live channels: the middle of the wide channel poster, like radio.nrk.no shows it; episodes: the square picture)
        title = $File.Title; subtitle = $sub; image = $(if ($File.Type -eq 'radiolive' -and $File.ImageUrl) { $File.ImageUrl } elseif ($File.SquareUrl) { $File.SquareUrl } else { $File.ImageUrl }); webUrl = $File.WebUrl
        start = $(if ($File.Type -eq 'audio' -and -not $st.Live) { [double](Get-ResumePosition $File) } else { 0 })
        # 2.9.0: this series' own speed and the parts to skip (seriesprefs.json)
        key = $(if ($File.Type -eq 'audio') { Get-SeriesPrefKey $File } else { $null }); rate = [double]$pref.Rate; intro = [int]$pref.Intro; outro = [int]$pref.Outro
    } | ConvertTo-Json -Compress
    Show-AudioBar
    Save-LastPlayed $File 'audio' $(if ($FromQueue) { $u.QueueNode } else { $null })
    Add-RecentPlayed $File
    Send-AudioFx
    Invoke-AudioScript "nrkb.load($($u.Last))"   # not ready yet: sent when the page says 'ready'
    Invoke-AudioScript "nrkb.setNav($(Get-AudioNavJson))"
    if ($File.Type -eq 'radiolive') { try { Add-RecentChannel $File } catch { }; if ((Get-AppSettings).NowPlaying) { Start-NowPlaying } }
    Set-Status "Loading $($File.Title)..."
}

function Get-AudioNavJson {
    $u = $script:AudioUi
    $q = @($u.Queue); $i = $u.Index
    if ($u.UserQueue -and $u.UserQueue.Count) {
        return ([ordered]@{ count = [Math]::Max(2, $q.Count); prev = $(if ($i -gt 0) { [string]$q[$i - 1].Title } else { $null }); next = ('{0}  (your queue: {1})' -f $u.UserQueue[0].Title, $u.UserQueue.Count) } | ConvertTo-Json -Compress)
    }
    if ($q.Count -lt 2 -or $i -lt 0) { return '{"count":0}' }
    [ordered]@{
        count = $q.Count
        prev  = $(if ($i -gt 0) { [string]$q[$i - 1].Title } else { $null })
        next  = $(if ($i -lt $q.Count - 1) { [string]$q[$i + 1].Title } else { $null })
    } | ConvertTo-Json -Compress
}

function Start-NextAudio([int] $Step) {
    $u = $script:AudioUi
    if ($Step -gt 0 -and $u.UserQueue -and $u.UserQueue.Count) {
        # your own queue first (Play next / Add to queue); then the list it was started from goes on
        $f = $u.UserQueue[0]; $u.UserQueue.RemoveAt(0)
        Write-Log INFO "Audio: from your queue: $($f.Title)"
        $u.Current = $f; Start-AudioPlayer $f -FromQueue
        return
    }
    if (@($u.Queue).Count -eq 0) { return }
    $i = $u.Index + $Step
    if ($i -lt 0 -or $i -ge @($u.Queue).Count) { Write-Log INFO 'Audio: end of the list'; Set-Status 'Audio: end of the list'; return }
    $u.Index = $i
    foreach ($row in $itemsList.Items) {
        if ([object]::ReferenceEquals($row.Tag, $u.Queue[$i])) { $itemsList.SelectedItems.Clear(); $row.Selected = $true; $row.Focused = $true; $row.EnsureVisible(); break }
    }
    Start-AudioPlayer $u.Queue[$i] -FromQueue
}

function Stop-AudioPlayer {
    $u = $script:AudioUi
    Invoke-AudioScript 'window.nrkb && nrkb.stop()'
    $u.Last = $null; $u.Current = $null; $u.Queue = @(); $u.Index = -1
    $audioBar.Visible = $false
    Set-TrayText ''
    Save-LastPlayed $null
    Write-Log INFO 'UI: audio player closed'
    Set-Status 'Audio stopped'
}

function Invoke-Back {
    # Top-bar back arrow: file -> its folder, folder -> parent folder
    if ($script:SelectedFile) {
        $script:SelectedFile = $null
        $itemsList.SelectedItems.Clear()
        Show-FolderPreview
    } elseif ($folderTree.SelectedNode -and $folderTree.SelectedNode.Parent) {
        $p = $folderTree.SelectedNode.Parent
        # a TV or radio series opens its first season when you go into it: going back, stay on the
        # series (its seasons), the way the breadcrumb does (it used to jump straight back into the season)
        $script:CrumbNav = $true
        try { $folderTree.SelectedNode = $p } finally { $script:CrumbNav = $false }
    }
    Update-Actions; Update-Crumb
}

#---- Download queue -------------------------------------------------------------
# Every Download (button, right-click, folder) adds files to a queue; nothing starts until
# "Download selected" is pressed in the Downloads window. One file is
# downloaded at a time by a hidden process (FFmpeg, for TV and radio);
# its output is shown in the window and copied to the app log. Each item remembers the
# files it created, so a cancelled download can be cleaned up.

$script:DlQueue = New-Object System.Collections.ArrayList
$script:DlUi = $null
$script:DlNextId = 0
$script:DlLogBuffer = New-Object System.Text.StringBuilder
# ---- casting: Chromecast and TVs (DLNA) -----------------------------------------------------
# "Cast" (main window and player window) finds Chromecasts (mDNS) and TVs that accept media
# (DLNA, found with SSDP) on the network. A Chromecast plays NRK's stream itself, with
# subtitles; a TV gets the stream remuxed by FFmpeg on this PC (TVs rarely play NRK's own
# format). The cast bar at the bottom of the main window controls it. Positions are saved
# like in the built-in player, so casting continues where you stopped.
$script:CastCs = @'
#pragma warning disable 618, 612, SYSLIB0014
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

// Casting for NRK Browser: finding Chromecasts (mDNS) and TVs (SSDP/DLNA), a Chromecast connection
// (the CASTV2 protocol: protobuf messages over TLS on port 8009) and a small HTTP server on this PC
// for what the device fetches from us (subtitles, a proxied stream, a stream remuxed by FFmpeg).
// Written for C# 5 (Windows PowerShell 5.1 compiles it).
public static class NrkCastFind {
    static List<IPAddress> LocalV4() {
        var list = new List<IPAddress>();
        try {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()) {
                if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                    if (ua.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(ua.Address)) list.Add(ua.Address);
            }
        } catch { }
        if (list.Count == 0) list.Add(IPAddress.Any);
        return list;
    }

    // the address of this PC that the device can reach us on
    public static string LocalIpFor(string remote) {
        try {
            using (var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp)) {
                s.Connect(IPAddress.Parse(remote), 9);
                return ((IPEndPoint)s.LocalEndPoint).Address.ToString();
            }
        } catch { return null; }
    }

    // ---- mDNS: _googlecast._tcp.local -> "cast|name|ip|port|model" lines
    static byte[] MdnsQuery() {
        var q = new List<byte>();
        q.AddRange(new byte[] { 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 });
        foreach (var part in "_googlecast._tcp.local".Split('.')) { q.Add((byte)part.Length); q.AddRange(Encoding.ASCII.GetBytes(part)); }
        q.Add(0);
        q.AddRange(new byte[] { 0, 12, 0x80, 1 });   // PTR, class IN with the "unicast response" bit
        return q.ToArray();
    }
    static string ReadName(byte[] b, ref int p) {
        var sb = new StringBuilder(); int jumps = 0; int end = -1;
        while (p < b.Length) {
            int len = b[p];
            if (len == 0) { p++; break; }
            if ((len & 0xC0) == 0xC0) {
                if (p + 1 >= b.Length) break;
                int ptr = ((len & 0x3F) << 8) | b[p + 1];
                if (end < 0) end = p + 2;
                p = ptr; if (++jumps > 20) break;
                continue;
            }
            p++;
            if (p + len > b.Length) break;
            if (sb.Length > 0) sb.Append('.');
            sb.Append(Encoding.UTF8.GetString(b, p, len)); p += len;
        }
        if (end >= 0) p = end;
        return sb.ToString();
    }
    public static void ParseMdns(byte[] b, string from, Dictionary<string, string[]> found) {
        try {
            if (b.Length < 12) return;
            int qd = (b[4] << 8) | b[5], an = (b[6] << 8) | b[7], ns = (b[8] << 8) | b[9], ar = (b[10] << 8) | b[11];
            int p = 12;
            for (int i = 0; i < qd; i++) { ReadName(b, ref p); p += 4; }
            string fn = null, md = null, id = null; int port = 8009; bool isCast = false;
            int total = an + ns + ar;
            for (int i = 0; i < total && p < b.Length; i++) {
                string name = ReadName(b, ref p);
                if (p + 10 > b.Length) break;
                int type = (b[p] << 8) | b[p + 1]; int rdlen = (b[p + 8] << 8) | b[p + 9]; p += 10;
                int rd = p;
                if (name.IndexOf("_googlecast", StringComparison.OrdinalIgnoreCase) >= 0) isCast = true;
                if (type == 33 && rdlen >= 6) port = (b[rd + 4] << 8) | b[rd + 5];   // SRV
                if (type == 16) {   // TXT: fn=friendly name, md=model, id=device id
                    int q = rd;
                    while (q < rd + rdlen) {
                        int l = b[q++]; if (q + l > b.Length) break;
                        string kv = Encoding.UTF8.GetString(b, q, l); q += l;
                        if (kv.StartsWith("fn=")) fn = kv.Substring(3);
                        else if (kv.StartsWith("md=")) md = kv.Substring(3);
                        else if (kv.StartsWith("id=")) id = kv.Substring(3);
                    }
                }
                p = rd + rdlen;
            }
            if (!isCast) return;
            string key = id ?? from;
            found[key] = new[] { "cast", fn ?? ("Chromecast " + from), from, port.ToString(), md ?? "" };
        } catch { }
    }

    // ---- SSDP: TVs and speakers that play media sent to them -> "dlna||ip|location|server" lines
    static byte[] SsdpQuery() {
        string s = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n";
        return Encoding.ASCII.GetBytes(s);
    }
    public static void ParseSsdp(byte[] b, string from, Dictionary<string, string[]> found) {
        string text = Encoding.UTF8.GetString(b);
        string loc = null, server = "", usn = null;
        foreach (var line in text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None)) {
            int c = line.IndexOf(':'); if (c <= 0) continue;
            string k = line.Substring(0, c).Trim().ToUpperInvariant(), v = line.Substring(c + 1).Trim();
            if (k == "LOCATION") loc = v; else if (k == "SERVER") server = v; else if (k == "USN") usn = v;
        }
        if (loc == null) return;
        string key = "dlna|" + (usn != null && usn.IndexOf("::") > 0 ? usn.Substring(0, usn.IndexOf("::")) : loc);
        found[key] = new[] { "dlna", "", from, loc, server };
    }

    // both at once; waits Ms milliseconds for answers (run it on a background task)
    public static string[] Discover(int ms) {
        var found = new Dictionary<string, string[]>();
        var sockets = new List<UdpClient>();
        var mdns = new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353);
        var ssdp = new IPEndPoint(IPAddress.Parse("239.255.255.250"), 1900);
        foreach (var ip in LocalV4()) {
            foreach (int kind in new[] { 0, 1 }) {
                try {
                    var u = new UdpClient(new IPEndPoint(ip, 0));
                    u.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 2);
                    if (!ip.Equals(IPAddress.Any)) u.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, ip.GetAddressBytes());
                    var pkt = kind == 0 ? MdnsQuery() : SsdpQuery();
                    u.Send(pkt, pkt.Length, kind == 0 ? mdns : ssdp);
                    u.Client.ReceiveTimeout = 300;
                    sockets.Add(u);
                    u.Client.Blocking = true;
                    // mark which protocol this socket speaks
                    u.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReceiveBuffer, kind == 0 ? 65536 : 65537);
                } catch { }
            }
        }
        var sw = Stopwatch.StartNew(); int resent = 0;
        while (sw.ElapsedMilliseconds < ms) {
            bool any = false;
            foreach (var u in sockets) {
                try {
                    if (u.Available <= 0) continue;
                    any = true;
                    var ep = new IPEndPoint(IPAddress.Any, 0);
                    var data = u.Receive(ref ep);
                    int rb = (int)u.Client.GetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReceiveBuffer);
                    bool isMdns = data.Length > 0 && data[0] != (byte)'H';   // SSDP answers start with "HTTP/1.1"
                    if (isMdns) ParseMdns(data, ep.Address.ToString(), found); else ParseSsdp(data, ep.Address.ToString(), found);
                } catch { }
            }
            if (!any) Thread.Sleep(40);
            // ask a second time half-way (UDP gets lost)
            if (resent == 0 && sw.ElapsedMilliseconds > ms / 2) {
                resent = 1;
                foreach (var u in sockets) { try { var pkt = MdnsQuery(); u.Send(pkt, pkt.Length, mdns); var s2 = SsdpQuery(); u.Send(s2, s2.Length, ssdp); } catch { } }
            }
        }
        foreach (var u in sockets) { try { u.Close(); } catch { } }
        var res = new List<string>();
        foreach (var v in found.Values) {
            if (v[0] == "dlna") {
                // the TV's description: its name and where to send play/pause/volume
                var d = Describe(v[3]);
                if (d == null) continue;
                res.Add(string.Join("|", new[] { "dlna", d[0], v[2], d[1], d[2], d[3] }));
            } else res.Add(string.Join("|", v));
        }
        return res.ToArray();
    }

    public static System.Threading.Tasks.Task<string[]> DiscoverAsync(int ms) {
        return System.Threading.Tasks.Task.Factory.StartNew(() => Discover(ms));
    }

    static string Tag(string xml, string name) {
        var m = System.Text.RegularExpressions.Regex.Match(xml, "<(?:\\w+:)?" + name + ">([^<]*)</", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        return m.Success ? WebUtilityDecode(m.Groups[1].Value.Trim()) : null;
    }
    static string WebUtilityDecode(string s) { return s.Replace("&amp;", "&").Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", "\"").Replace("&apos;", "'"); }

    // name, AVTransport control URL, RenderingControl control URL (or ""), model; null when it can't play media
    public static string[] Describe(string location) {
        try {
            var wr = (HttpWebRequest)WebRequest.Create(location); wr.Timeout = 2500; wr.ReadWriteTimeout = 2500;
            string xml; using (var r = wr.GetResponse()) using (var sr = new StreamReader(r.GetResponseStream())) xml = sr.ReadToEnd();
            var baseUri = new Uri(location);
            var ub = Tag(xml, "URLBase"); if (!string.IsNullOrEmpty(ub)) { try { baseUri = new Uri(ub); } catch { } }
            string avt = null, rc = "";
            foreach (var block in System.Text.RegularExpressions.Regex.Split(xml, "<(?:\\w+:)?service>", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) {
                var type = Tag(block, "serviceType"); var ctl = Tag(block, "controlURL");
                if (type == null || ctl == null) continue;
                if (type.IndexOf(":AVTransport:", StringComparison.OrdinalIgnoreCase) >= 0 && avt == null) avt = new Uri(baseUri, ctl).ToString();
                else if (type.IndexOf(":RenderingControl:", StringComparison.OrdinalIgnoreCase) >= 0 && rc == "") rc = new Uri(baseUri, ctl).ToString();
            }
            if (avt == null) return null;
            var name = Tag(xml, "friendlyName") ?? baseUri.Host;
            var model = (Tag(xml, "manufacturer") ?? "") + " " + (Tag(xml, "modelName") ?? "");
            return new[] { name.Replace("|", "/"), avt, rc, model.Trim().Replace("|", "/") };
        } catch { return null; }
    }
}

// ---- one Chromecast connection: the app sends JSON on a namespace; what comes back is queued
public class NrkCastLink : IDisposable {
    TcpClient tcp; SslStream ssl; Thread reader, pinger;
    readonly object sendLock = new object();
    volatile bool open;
    public ConcurrentQueue<string> Inbox = new ConcurrentQueue<string>();   // "source\nnamespace\njson"
    public string Error;
    public bool IsOpen { get { return open; } }

    public bool Connect(string host, int port, int timeoutMs) {
        try {
            tcp = new TcpClient();
            var ar = tcp.BeginConnect(host, port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(timeoutMs)) { Error = "no answer from " + host + ":" + port; tcp.Close(); return false; }
            tcp.EndConnect(ar);
            ssl = new SslStream(tcp.GetStream(), false, delegate { return true; });   // (a Chromecast's certificate is its own)
            ssl.ReadTimeout = timeoutMs; ssl.WriteTimeout = timeoutMs;              // (a device that never answers the handshake)
            ssl.AuthenticateAsClient(host);
            ssl.ReadTimeout = Timeout.Infinite;
            open = true;
            reader = new Thread(ReadLoop); reader.IsBackground = true; reader.Start();
            Send("receiver-0", "urn:x-cast:com.google.cast.tp.connection", "{\"type\":\"CONNECT\"}");
            pinger = new Thread(PingLoop); pinger.IsBackground = true; pinger.Start();
            return true;
        } catch (Exception e) { Error = e.Message; open = false; return false; }
    }

    static void Varint(List<byte> b, ulong v) { while (v >= 0x80) { b.Add((byte)(v | 0x80)); v >>= 7; } b.Add((byte)v); }
    static void Str(List<byte> b, int field, string s) {
        var d = Encoding.UTF8.GetBytes(s ?? "");
        b.Add((byte)((field << 3) | 2)); Varint(b, (ulong)d.Length); b.AddRange(d);
    }

    public bool Send(string dest, string ns, string json) {
        if (!open) return false;
        var m = new List<byte>();
        m.Add(0x08); Varint(m, 0);            // protocol_version CASTV2_1_0
        Str(m, 2, "sender-0");                // source_id
        Str(m, 3, dest);                      // destination_id
        Str(m, 4, ns);                        // namespace
        m.Add(0x28); Varint(m, 0);            // payload_type STRING
        Str(m, 6, json);                      // payload_utf8
        var len = m.Count;
        var frame = new byte[4 + len];
        frame[0] = (byte)(len >> 24); frame[1] = (byte)(len >> 16); frame[2] = (byte)(len >> 8); frame[3] = (byte)len;
        m.CopyTo(frame, 4);
        try { lock (sendLock) { ssl.Write(frame); ssl.Flush(); } return true; }
        catch (Exception e) { Error = e.Message; Close(); return false; }
    }

    static ulong ReadVarint(byte[] b, ref int p) { ulong v = 0; int s = 0; while (p < b.Length) { byte x = b[p++]; v |= (ulong)(x & 0x7F) << s; if ((x & 0x80) == 0) break; s += 7; } return v; }

    void ReadExact(byte[] buf, int n) {
        int got = 0;
        while (got < n) { int r = ssl.Read(buf, got, n - got); if (r <= 0) throw new IOException("closed by the device"); got += r; }
    }

    void ReadLoop() {
        try {
            var head = new byte[4];
            while (open) {
                ReadExact(head, 4);
                int len = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
                if (len <= 0 || len > 4 * 1024 * 1024) throw new IOException("bad message size " + len);
                var body = new byte[len]; ReadExact(body, len);
                string src = "", ns = "", payload = "";
                int p = 0;
                while (p < body.Length) {
                    ulong tag = ReadVarint(body, ref p); int field = (int)(tag >> 3), wt = (int)(tag & 7);
                    if (wt == 0) { ReadVarint(body, ref p); continue; }
                    if (wt != 2) break;
                    int l = (int)ReadVarint(body, ref p);
                    if (p + l > body.Length) break;
                    if (field == 2) src = Encoding.UTF8.GetString(body, p, l);
                    else if (field == 4) ns = Encoding.UTF8.GetString(body, p, l);
                    else if (field == 6) payload = Encoding.UTF8.GetString(body, p, l);
                    p += l;
                }
                if (ns == "urn:x-cast:com.google.cast.tp.heartbeat") {
                    if (payload.IndexOf("\"PING\"") >= 0) Send(src, ns, "{\"type\":\"PONG\"}");
                    continue;
                }
                Inbox.Enqueue(src + "\n" + ns + "\n" + payload);
            }
        } catch (Exception e) { if (open) Error = e.Message; }
        open = false;
        Inbox.Enqueue("\n\n{\"type\":\"__CLOSED\"}");
    }

    void PingLoop() {
        while (open) {
            Thread.Sleep(5000);
            if (open) Send("receiver-0", "urn:x-cast:com.google.cast.tp.heartbeat", "{\"type\":\"PING\"}");
        }
    }

    public void Close() {
        open = false;
        try { if (ssl != null) ssl.Close(); } catch { }
        try { if (tcp != null) tcp.Close(); } catch { }
    }
    public void Dispose() { Close(); }
}

// ---- what the device fetches from this PC
//   /sub?u=<url>          subtitles (WebVTT) with the CORS header a Chromecast needs
//   /hls?u=<url>          NRK's playlist / its pieces, passed through (playlist addresses rewritten)
//   /ts/<token>           a stream FFmpeg remuxes on the fly (TVs that can't play NRK's own format)
public class NrkCastServer : IDisposable {
    TcpListener listener; Thread loop; volatile bool running;
    public int Port; public string Error; public string UserAgent = "Mozilla/5.0 NRK-Browser";
    // every address handed to a device carries this key: nobody else on the network can use the server
    public string Key = Guid.NewGuid().ToString("N").Substring(0, 20);
    public string FFmpeg;
    readonly Dictionary<string, string> remux = new Dictionary<string, string>();   // token -> FFmpeg arguments ({START} = seconds)
    readonly Dictionary<string, Process> procs = new Dictionary<string, Process>();
    public ConcurrentQueue<string> Log = new ConcurrentQueue<string>();

    public bool Start() {
        try {
            foreach (int p in new[] { 51791, 51792, 51793, 0 }) {
                try { listener = new TcpListener(IPAddress.Any, p); listener.Start(); break; }
                catch { listener = null; }
            }
            if (listener == null) { Error = "no free port"; return false; }
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            running = true;
            loop = new Thread(AcceptLoop); loop.IsBackground = true; loop.Start();
            return true;
        } catch (Exception e) { Error = e.Message; return false; }
    }

    public void SetRemux(string token, string args) { lock (remux) { remux[token] = args; } }
    public void StopRemux(string token) {
        lock (procs) { Process p; if (procs.TryGetValue(token, out p)) { try { if (!p.HasExited) p.Kill(); } catch { } procs.Remove(token); } }
    }

    void AcceptLoop() {
        while (running) {
            try {
                var c = listener.AcceptTcpClient();
                var t = new Thread(() => Handle(c)); t.IsBackground = true; t.Start();
            } catch { if (!running) break; Thread.Sleep(50); }
        }
    }

    static string Param(string query, string name) {
        foreach (var kv in query.TrimStart('?').Split('&')) {
            int e = kv.IndexOf('='); if (e < 0) continue;
            if (kv.Substring(0, e) == name) return Uri.UnescapeDataString(kv.Substring(e + 1).Replace('+', ' '));
        }
        return null;
    }

    void Head(Stream s, int code, string status, string type, long length, string extra) {
        var sb = new StringBuilder();
        sb.Append("HTTP/1.1 ").Append(code).Append(' ').Append(status).Append("\r\n");
        if (type != null) sb.Append("Content-Type: ").Append(type).Append("\r\n");
        if (length >= 0) sb.Append("Content-Length: ").Append(length).Append("\r\n");
        sb.Append("Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\nAccess-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n");
        sb.Append("Cache-Control: no-store\r\nConnection: close\r\n");
        if (extra != null) sb.Append(extra);
        sb.Append("\r\n");
        var b = Encoding.ASCII.GetBytes(sb.ToString());
        s.Write(b, 0, b.Length);
    }

    void Handle(TcpClient c) {
        Stream s = null;
        try {
            c.NoDelay = true;
            s = c.GetStream();
            var req = new StringBuilder(); var one = new byte[1]; int n = 0;
            while (n < 16384) { int r = s.Read(one, 0, 1); if (r <= 0) break; req.Append((char)one[0]); n++; if (req.Length >= 4 && req.ToString(req.Length - 4, 4) == "\r\n\r\n") break; }
            var first = req.ToString().Split('\n')[0].Trim();
            var parts = first.Split(' ');
            if (parts.Length < 2) return;
            string method = parts[0], target = parts[1];
            string path = target, query = "";
            int qi = target.IndexOf('?'); if (qi >= 0) { path = target.Substring(0, qi); query = target.Substring(qi); }
            Log.Enqueue(method + " " + path + " from " + c.Client.RemoteEndPoint);
            if (method == "OPTIONS") { Head(s, 204, "No Content", null, 0, null); return; }
            bool headOnly = method == "HEAD";
            if (path == "/sub" || path == "/hls") {
                if (Param(query, "k") != Key) { Head(s, 403, "Forbidden", "text/plain", 0, null); return; }
                string u = Param(query, "u");
                if (u == null || !(u.StartsWith("https://") || u.StartsWith("http://"))) { Head(s, 400, "Bad Request", "text/plain", 0, null); return; }
                var wr = (HttpWebRequest)WebRequest.Create(u);
                wr.UserAgent = UserAgent; wr.Timeout = 20000; wr.ReadWriteTimeout = 30000; wr.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
                using (var resp = (HttpWebResponse)wr.GetResponse())
                using (var rs = resp.GetResponseStream()) {
                    string ct = resp.ContentType ?? "application/octet-stream";
                    bool playlist = path == "/hls" && (ct.IndexOf("mpegurl", StringComparison.OrdinalIgnoreCase) >= 0 || u.Split('?')[0].EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase));
                    if (path == "/sub" || playlist) {
                        string text; using (var sr = new StreamReader(rs, Encoding.UTF8)) text = sr.ReadToEnd();
                        if (playlist) text = Rewrite(text, resp.ResponseUri);
                        var bytes = Encoding.UTF8.GetBytes(text);
                        Head(s, 200, "OK", path == "/sub" ? "text/vtt; charset=utf-8" : "application/vnd.apple.mpegurl", bytes.Length, null);
                        if (!headOnly) s.Write(bytes, 0, bytes.Length);
                    } else {
                        Head(s, 200, "OK", ct, resp.ContentLength, null);
                        if (!headOnly) rs.CopyTo(s, 65536);
                    }
                }
                return;
            }
            if (path.StartsWith("/ts/")) {
                string token = path.Substring(4); int dot = token.IndexOf('.'); if (dot > 0) token = token.Substring(0, dot);
                string args; lock (remux) { remux.TryGetValue(token, out args); }
                if (args == null || FFmpeg == null) { Head(s, 404, "Not Found", "text/plain", 0, null); return; }
                string start = Param(query, "t") ?? "0";
                double st; if (!double.TryParse(start, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out st)) st = 0;
                bool audio = args.IndexOf("-f mp3", StringComparison.Ordinal) >= 0;
                string ctype = audio ? "audio/mpeg" : "video/mp2t";
                string dlna = "transferMode.dlna.org: Streaming\r\ncontentFeatures.dlna.org: DLNA.ORG_OP=00;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n";
                if (headOnly) { Head(s, 200, "OK", ctype, -1, dlna); return; }
                StopRemux(token);   // one at a time: a new request (a jump) replaces the old one
                var psi = new ProcessStartInfo(FFmpeg, args.Replace("{START}", st.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)));
                psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true; psi.CreateNoWindow = true;
                var proc = Process.Start(psi);
                lock (procs) { procs[token] = proc; }
                proc.ErrorDataReceived += (o, e) => { if (!string.IsNullOrEmpty(e.Data)) Log.Enqueue("ffmpeg: " + e.Data); };
                proc.BeginErrorReadLine();
                Head(s, 200, "OK", ctype, -1, dlna);
                try { proc.StandardOutput.BaseStream.CopyTo(s, 65536); } catch { }
                try { if (!proc.HasExited) proc.Kill(); } catch { }
                return;
            }
            Head(s, 404, "Not Found", "text/plain", 0, null);
        } catch (Exception e) {
            Log.Enqueue("error: " + e.Message);
            try { if (s != null) Head(s, 502, "Bad Gateway", "text/plain", 0, null); } catch { }
        } finally {
            try { c.Close(); } catch { }
        }
    }

    // every address in an HLS playlist goes through us as well (absolute, then /hls?u=)
    string Rewrite(string text, Uri baseUri) {
        var sb = new StringBuilder();
        foreach (var raw in text.Split('\n')) {
            string line = raw.TrimEnd('\r');
            if (line.Length == 0) { sb.Append('\n'); continue; }
            if (line[0] != '#') { sb.Append(Proxy(new Uri(baseUri, line).ToString())).Append('\n'); continue; }
            int u = line.IndexOf("URI=\"", StringComparison.Ordinal);
            if (u >= 0) {
                int e = line.IndexOf('"', u + 5);
                if (e > u) { string inner = line.Substring(u + 5, e - u - 5); line = line.Substring(0, u + 5) + Proxy(new Uri(baseUri, inner).ToString()) + line.Substring(e); }
            }
            sb.Append(line).Append('\n');
        }
        return sb.ToString();
    }
    string Proxy(string abs) { return "/hls?k=" + Key + "&u=" + Uri.EscapeDataString(abs); }

    public void Dispose() {
        running = false;
        try { if (listener != null) listener.Stop(); } catch { }
        lock (procs) { foreach (var p in procs.Values) { try { if (!p.HasExited) p.Kill(); } catch { } } procs.Clear(); }
    }
}

'@
$script:Cast = @{ Devices = @(); FoundAt = [datetime]::MinValue; Finding = $null; Session = $null; Server = $null; Ok = $null }
$script:CastNs = @{
    Conn = 'urn:x-cast:com.google.cast.tp.connection'; Recv = 'urn:x-cast:com.google.cast.receiver'; Media = 'urn:x-cast:com.google.cast.media'
}
$script:CastAppId = 'CC1AD845'   # Google's Default Media Receiver

function Initialize-Cast {
    if ($null -ne $script:Cast.Ok) { return $script:Cast.Ok }
    try {
        if (-not ('NrkCastLink' -as [type])) { Add-Type -TypeDefinition $script:CastCs -IgnoreWarnings -ErrorAction Stop }
        $script:Cast.Ok = $true
    } catch { Write-LogException $_ 'Cast helper'; $script:Cast.Ok = $false }
    return $script:Cast.Ok
}

function Get-CastServer {
    # the little web server the device fetches subtitles / streams from (started when first needed)
    $c = $script:Cast
    if ($c.Server) { return $c.Server }
    $srv = New-Object NrkCastServer
    $srv.UserAgent = $script:UserAgent
    $ff = Find-FFmpeg; if ($ff -and $ff.Path) { $srv.FFmpeg = $ff.Path }
    if (-not $srv.Start()) { Write-Log WARN "Cast server could not start: $($srv.Error)"; return $null }
    Write-Log INFO "Cast server listening on port $($srv.Port) (Windows may ask to allow it on the network once)"
    $c.Server = $srv
    return $srv
}

function Start-CastDiscovery {
    if (-not (Initialize-Cast)) { return }
    $c = $script:Cast
    if ($c.Finding) { return }
    Write-Log INFO 'Cast: looking for Chromecasts and TVs on the network'
    $c.Finding = [NrkCastFind]::DiscoverAsync(2600)
    if (-not $script:CastFindTimer) {
        $script:CastFindTimer = New-Object System.Windows.Forms.Timer
        $script:CastFindTimer.Interval = 250
        $script:CastFindTimer.Add_Tick({
            $c = $script:Cast
            if (-not $c.Finding -or -not $c.Finding.IsCompleted) { return }
            $script:CastFindTimer.Stop()
            $list = @()
            if (-not $c.Finding.IsFaulted) {
                foreach ($line in @($c.Finding.Result)) {
                    $p = ([string]$line).Split('|')
                    if ($p[0] -eq 'cast') { $list += [pscustomobject]@{ Kind = 'cast'; Name = $p[1]; Ip = $p[2]; Port = [int]$p[3]; Model = $p[4]; Avt = ''; Rc = '' } }
                    elseif ($p[0] -eq 'dlna') { $list += [pscustomobject]@{ Kind = 'dlna'; Name = $p[1]; Ip = $p[2]; Port = 0; Avt = $p[3]; Rc = $p[4]; Model = $p[5] } }
                }
            } else { Write-Log WARN "Cast: search failed: $($c.Finding.Exception.GetBaseException().Message)" }
            # a Chromecast built into a TV answers both ways: keep the Chromecast
            $castIps = @($list | Where-Object Kind -eq 'cast' | ForEach-Object Ip)
            $list = @($list | Where-Object { $_.Kind -eq 'cast' -or $castIps -notcontains $_.Ip } | Sort-Object Kind, Name)
            $c.Devices = $list; $c.FoundAt = Get-Date; $c.Finding = $null
            Write-Log INFO ("Cast: found {0}" -f $(if ($list.Count) { ($list | ForEach-Object { "$($_.Name) ($($_.Kind), $($_.Ip))" }) -join ', ' } else { 'nothing' }))
            if ($script:CastMenu -and $script:CastMenu.Visible) { Update-CastMenu }
        })
    }
    $script:CastFindTimer.Start()
}

# ---- the menu under a Cast button
function Show-CastMenu($Button, $File) {
    if (-not (Initialize-Cast)) { [void][System.Windows.Forms.MessageBox]::Show($form, 'Casting is not available (the cast helper did not load - see Logs).', 'Cast', 'OK', 'Warning'); return }
    if (-not $script:CastMenu) { $script:CastMenu = New-ThemedMenu }
    $script:CastMenuFile = $File
    if (((Get-Date) - $script:Cast.FoundAt).TotalSeconds -gt 90 -or -not $script:Cast.Devices.Count) { Start-CastDiscovery }
    Update-CastMenu
    $script:CastMenu.Show($Button, (New-Object System.Drawing.Point(0, ($Button.Height + 2))))
}

function Update-CastMenu {
    $m = $script:CastMenu; $c = $script:Cast; $f = $script:CastMenuFile
    $m.Items.Clear()
    $head = New-ThemedMenuItem $(if ($f) { 'Cast "{0}" to' -f $(if ($f.ListTitle) { $f.ListTitle } else { $f.Title }) } else { 'Cast to' })
    $head.Enabled = $false; [void]$m.Items.Add($head)
    foreach ($d in $c.Devices) {
        $kind = if ($d.Kind -eq 'cast') { 'Chromecast' } else { 'TV (DLNA)' }
        $i = New-ThemedMenuItem ('   {0}    ·  {1}' -f $d.Name, $kind)
        $i.Tag = $d; $i.ToolTipText = "$($d.Model)  $($d.Ip)".Trim()
        $i.Enabled = [bool]$f
        if ($c.Session -and $c.Session.Device.Ip -eq $d.Ip -and $c.Session.Device.Kind -eq $d.Kind) { $i.Checked = $true }
        $i.Add_Click({ Start-Cast $this.Tag $script:CastMenuFile })
        [void]$m.Items.Add($i)
    }
    if ($c.Finding) { $s = New-ThemedMenuItem '   Looking for devices...'; $s.Enabled = $false; [void]$m.Items.Add($s) }
    elseif (-not $c.Devices.Count) { $s = New-ThemedMenuItem '   Nothing found on this network'; $s.Enabled = $false; [void]$m.Items.Add($s) }
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $again = New-ThemedMenuItem 'Search again'
    $again.Enabled = -not $c.Finding
    $again.Add_Click({ $script:Cast.FoundAt = [datetime]::MinValue; Start-CastDiscovery; Set-Status 'Looking for Chromecasts and TVs... press Cast again in a moment' })
    [void]$m.Items.Add($again)
    if ($c.Session) { $stop = New-ThemedMenuItem ('Stop casting to {0}' -f $c.Session.Device.Name); $stop.Add_Click({ Stop-Cast }); [void]$m.Items.Add($stop) }
}

# ---- what to send
function Get-CastMedia($File) {
    $r = @{ Url = $null; Mime = ''; Live = $false; Audio = $false; Subs = @(); Title = [string]$File.Title; Sub = ''; Image = $null; Duration = 0; Reason = $null }
    switch ($File.Type) {
        { $_ -in 'episode', 'program', 'live' } {
            $kind = if ($File.Type -eq 'live') { 'channel' } else { 'program' }
            $st = Get-NrkVideoStream -Id $File.Id -Kind $kind
            if (-not $st.Playable) { $r.Reason = if ($st.Encrypted) { 'This programme is protected: it can only be played on the NRK page.' } elseif ($st.Reason) { $st.Reason } else { 'NRK offers no stream for it right now.' }; return $r }
            $r.Url = $st.Url; $r.Mime = 'application/x-mpegurl'; $r.Live = ($File.Type -eq 'live' -or $st.Live); $r.Subs = @($st.Subtitles); $r.Image = $st.Poster; $r.Duration = $st.Duration
            if ($File.Type -eq 'episode' -and $File.SeriesItem) { $r.Sub = [string]$File.SeriesItem.Title }
            if (-not $r.Image) { $r.Image = $File.ImageUrl }
        }
        { $_ -in 'audio', 'radiolive' } {
            $st = Get-NrkAudioStream -ManifestPath $File.ManifestPath
            if (-not $st.Playable) { $r.Reason = if ($st.Reason) { $st.Reason } else { 'NRK offers no stream for it right now.' }; return $r }
            $r.Url = $st.Url; $r.Audio = $true; $r.Live = [bool]$st.Live
            $r.Mime = if ($st.Format -match 'MP3' -or $st.Url -match '\.mp3(\?|$)') { 'audio/mpeg' } else { 'application/x-mpegurl' }
            $r.Sub = [string]$File.SeriesTitle; $r.Image = $(if ($File.Type -eq 'radiolive' -and $File.ImageUrl) { $File.ImageUrl } elseif ($File.SquareUrl) { $File.SquareUrl } else { $File.ImageUrl })
            try { if ($st.Duration) { $r.Duration = [Xml.XmlConvert]::ToTimeSpan($st.Duration).TotalSeconds } } catch { }
        }
        default { $r.Reason = 'This can not be cast.' }
    }
    return $r
}

function Test-CastableFile($File) { return [bool]($File -and $File.Type -in 'episode', 'program', 'live', 'audio', 'radiolive' -and (Test-FileAvailable $File)) }

function Start-Cast($Device, $File, [object[]] $Queue = $null, [int] $Index = -1, $QueueNode = $null) {
    if (-not $Device -or -not (Test-CastableFile $File) -or -not (Initialize-Cast)) { return }
    if (-not (Test-ChildAllowed $File)) { return }
    if ($script:Cast.Session) { Stop-Cast -Quiet }
    $res = @{ M = $null }
    Invoke-Ui "Getting the stream for $($File.Title)" { $res.M = Get-CastMedia $File }
    $m = $res.M
    if (-not $m -or -not $m.Url) { [void][System.Windows.Forms.MessageBox]::Show($form, "$($File.Title)`n`n$(if ($m) { $m.Reason } else { 'Could not get the stream.' })", 'Cast', 'OK', 'Information'); return }
    $start = if ($m.Live) { 0 } else { [double](Get-ResumePosition $File) }
    $s = @{ Device = $Device; File = $File; Media = $m; State = 'connecting'; Pos = $start; Dur = [double]$m.Duration; PosAt = Get-Date; Start = $start
            ReqId = 10; Link = $null; TransportId = $null; SessionId = $null; MediaSessionId = $null; Proxied = $false; Loaded = $false
            Volume = 1.0; Muted = $false; SubsOn = $false; LastPoll = Get-Date; LastSave = Get-Date; Token = $null; Http = $null; Msg = ''
            StartedAt = Get-Date; Queue = @(); Index = -1 }
    # the list it came from, so the next episode follows (not for mixed lists: search, recent, new, last chance)
    if ($null -eq $Queue) {
        $QueueNode = $folderTree.SelectedNode
        if ($File.Type -in 'episode', 'program', 'audio' -and (Get-FolderTag).Kind -notin $script:MixedKinds) {
            $Queue = @($script:Files | Where-Object { $_.Type -eq $File.Type -and (Test-FileAvailable $_) })
            $Index = -1; for ($i = 0; $i -lt $Queue.Count; $i++) { if ([object]::ReferenceEquals($Queue[$i], $File)) { $Index = $i; break } }
            if ($Index -lt 0) { $Queue = @() }
        } else { $Queue = @() }
    }
    $s.Queue = @($Queue); $s.Index = $Index; $s.QueueNode = $QueueNode
    $script:Cast.Session = $s
    Write-Log INFO ("Cast: {0} -> {1} ({2}, {3}){4}" -f $File.Title, $Device.Name, $Device.Kind, $Device.Ip, $(if ($start) { ", from $start s" } else { '' }))
    # one thing at a time: the video window and the radio bar stop
    if ($script:PlayerWin -and -not $script:PlayerWin.Form.IsDisposed -and $script:PlayerWin.Url) { Stop-Player -KeepResume }
    if ($script:AudioUi.Current) { Stop-AudioPlayer }
    Show-CastBar
    $ok = if ($Device.Kind -eq 'cast') { Start-ChromecastSession $s } else { Start-DlnaSession $s }
    if (-not $ok) { $script:Cast.Session = $null; Hide-CastBar; return }
    Add-RecentPlayed $File
    Save-LastPlayed $File 'cast' $s.QueueNode $Device   # (continue where you left off: on this device)
    if (-not $script:CastTimer) {
        $script:CastTimer = New-Object System.Windows.Forms.Timer
        $script:CastTimer.Interval = 300
        $script:CastTimer.Add_Tick({ try { Update-CastSession } catch { Write-LogException $_ 'Cast' } })
    }
    $script:CastTimer.Start()
}

# ---- Chromecast
function Send-CastJson([string] $Dest, [string] $Ns, $Object) {
    $s = $script:Cast.Session
    if (-not $s -or -not $s.Link) { return }
    $s.ReqId++
    if ($Object -is [System.Collections.IDictionary] -and -not $Object.Contains('requestId') -and $Ns -ne $script:CastNs.Conn) { $Object['requestId'] = $s.ReqId }
    $json = $Object | ConvertTo-Json -Compress -Depth 8
    if (-not $s.Link.Send($Dest, $Ns, $json)) { Write-Log WARN "Cast: send failed: $($s.Link.Error)" }
}

function Start-ChromecastSession($S) {
    $link = New-Object NrkCastLink
    $ok = $false
    Invoke-Ui "Connecting to $($S.Device.Name)" { $ok = $link.Connect($S.Device.Ip, $S.Device.Port, 5000) }
    if (-not $link.IsOpen) {
        [void][System.Windows.Forms.MessageBox]::Show($form, "Could not connect to $($S.Device.Name):`n$($link.Error)", 'Cast', 'OK', 'Warning')
        return $false
    }
    $S.Link = $link
    $S.Msg = 'Starting the player on the Chromecast...'
    Send-CastJson 'receiver-0' $script:CastNs.Recv ([ordered]@{ type = 'LAUNCH'; appId = $script:CastAppId })
    return $true
}

function Get-CastLoad($S) {
    $m = $S.Media
    $srv = Get-CastServer
    $base = if ($srv) { 'http://{0}:{1}' -f ([NrkCastFind]::LocalIpFor($S.Device.Ip)), $srv.Port } else { $null }
    $url = if ($S.Proxied -and $base) { "$base/hls?k=$($srv.Key)&u=" + [uri]::EscapeDataString($m.Url) } else { $m.Url }
    $tracks = @(); $active = @(); $i = 0
    if ($base) {
        foreach ($sub in $m.Subs) {
            $i++
            $tracks += [ordered]@{ trackId = $i; type = 'TEXT'; trackContentId = "$base/sub?k=$($srv.Key)&u=" + [uri]::EscapeDataString($sub.url); trackContentType = 'text/vtt'; subtype = 'SUBTITLES'; name = [string]$sub.label; language = $(if ($sub.language) { [string]$sub.language } else { 'no' }) }
            if ($sub.default -and -not $active.Count) { $active += $i }
        }
    }
    $S.SubsOn = [bool]$active.Count
    $media = [ordered]@{
        contentId = $url; contentUrl = $url; contentType = $m.Mime; streamType = $(if ($m.Live) { 'LIVE' } else { 'BUFFERED' })
        metadata = [ordered]@{ metadataType = 0; title = $m.Title; subtitle = $m.Sub; images = @($(if ($m.Image) { [ordered]@{ url = [string]$m.Image } })) }
    }
    if ($m.Duration -gt 0 -and -not $m.Live) { $media.duration = [double]$m.Duration }
    if ($tracks.Count) { $media.tracks = $tracks }
    if ($m.Audio -and $m.Mime -match 'mpegurl') { $media.hlsSegmentFormat = 'ts' }   # (audio-only HLS: tell it the pieces are MPEG-TS)
    $load = [ordered]@{ type = 'LOAD'; sessionId = $S.SessionId; media = $media; autoplay = $true; currentTime = [double]$S.Start }
    if ($active.Count) { $load.activeTrackIds = $active }
    return $load
}

function Update-CastSession {
    $s = $script:Cast.Session
    if (-not $s) { $script:CastTimer.Stop(); return }
    if ($s.Device.Kind -eq 'dlna') { Update-DlnaSession $s; Update-CastBar; return }
    $srv = $script:Cast.Server
    if ($srv) { $l = $null; while ($srv.Log.TryDequeue([ref]$l)) { } }   # (a line per stream piece: not kept)
    $msg = $null
    while ($s.Link.Inbox.TryDequeue([ref]$msg)) {
        $parts = $msg.Split("`n", 3)
        $src = $parts[0]; $ns = $parts[1]; $j = $null
        try { $j = $parts[2] | ConvertFrom-Json } catch { continue }
        switch ([string]$j.type) {
            '__CLOSED' { Write-Log INFO "Cast: the connection to $($s.Device.Name) closed ($($s.Link.Error))"; Close-CastSession "Disconnected from $($s.Device.Name)"; return }
            'CLOSE' { if ($src -eq $s.TransportId) { Write-Log INFO 'Cast: the player on the device was closed'; Close-CastSession "Casting ended on $($s.Device.Name)"; return } }
            'RECEIVER_STATUS' {
                $st = $j.status
                if ($st.volume) { if ($null -ne $st.volume.level) { $s.Volume = [double]$st.volume.level }; $s.Muted = [bool]$st.volume.muted }
                $app = @($st.applications | Where-Object { $_.appId -eq $script:CastAppId }) | Select-Object -First 1
                if ($app -and -not $s.TransportId) {
                    $s.TransportId = [string]$app.transportId; $s.SessionId = [string]$app.sessionId
                    Send-CastJson $s.TransportId $script:CastNs.Conn ([ordered]@{ type = 'CONNECT' })
                    $s.Msg = 'Loading...'; $s.State = 'loading'
                    Send-CastJson $s.TransportId $script:CastNs.Media (Get-CastLoad $s)
                } elseif (-not $app -and $s.TransportId) { Close-CastSession "Casting ended on $($s.Device.Name)"; return }
            }
            'MEDIA_STATUS' {
                foreach ($ms in @($j.status)) {
                    if (-not $ms) { continue }
                    if ($ms.mediaSessionId) { $s.MediaSessionId = [int]$ms.mediaSessionId }
                    if ($ms.media -and $ms.media.duration -gt 0) { $s.Dur = [double]$ms.media.duration }
                    if ($null -ne $ms.currentTime) { $s.Pos = [double]$ms.currentTime; $s.PosAt = Get-Date }
                    if ($ms.volume) { if ($null -ne $ms.volume.level) { $s.Volume = [double]$ms.volume.level }; $s.Muted = [bool]$ms.volume.muted }
                    if ($null -ne $ms.activeTrackIds) { $s.SubsOn = [bool]@($ms.activeTrackIds).Count }
                    $state = [string]$ms.playerState
                    if ($state) { $s.State = $state; if ($state -in 'PLAYING', 'PAUSED', 'BUFFERING') { $s.Loaded = $true; $s.Msg = '' } }
                    if ($state -eq 'IDLE') {
                        switch ([string]$ms.idleReason) {
                            'FINISHED' { Set-PlayPosition $s.File $s.Dur $s.Dur -Ended; $s.Msg = 'Finished'; $s.Pos = $s.Dur; Start-CastNext; return }
                            'ERROR'    { if (Retry-CastProxied $s) { return }; $s.Msg = 'The Chromecast could not play it' }
                            'CANCELLED' { $s.Msg = 'Stopped' }
                        }
                    }
                }
                if ($s.Loaded -and -not $s.Media.Live -and ((Get-Date) - $s.LastSave).TotalSeconds -ge 5) { $s.LastSave = Get-Date; Set-PlayPosition $s.File $s.Pos $s.Dur }
            }
            { $_ -in 'LOAD_FAILED', 'LOAD_CANCELLED', 'INVALID_REQUEST' } {
                Write-Log WARN ("Cast: {0} {1}" -f $j.type, $j.reason)
                if ([string]$j.type -eq 'LOAD_FAILED' -and (Retry-CastProxied $s)) { return }
                if ([string]$j.type -ne 'LOAD_CANCELLED') { $s.Msg = "The Chromecast could not play it ($($j.type.ToLower().Replace('_', ' ')))" }
            }
        }
    }
    # no answer: don't wait for ever
    $age = ((Get-Date) - $s.StartedAt).TotalSeconds
    if (-not $s.TransportId -and $age -gt 20) { Write-Log WARN "Cast: $($s.Device.Name) did not start its player"; Close-CastSession "$($s.Device.Name) did not answer: casting stopped"; return }
    if ($s.TransportId -and -not $s.Loaded -and $age -gt 60 -and -not $s.Failed) { $s.Failed = $true; $s.Msg = "$($s.Device.Name) is not starting it - try again, or Stop casting" }
    # ask where it is every few seconds (it only reports changes)
    if ($s.MediaSessionId -and ((Get-Date) - $s.LastPoll).TotalSeconds -ge 4) {
        $s.LastPoll = Get-Date
        Send-CastJson $s.TransportId $script:CastNs.Media ([ordered]@{ type = 'GET_STATUS'; mediaSessionId = $s.MediaSessionId })
    }
    Update-CastBar
}

function Start-CastNext {
    # finished: the next episode in the list, on the same device
    $s = $script:Cast.Session
    if (-not $s -or $s.Ended) { return }
    $s.Ended = $true
    if (Test-SleepAtEnd) { return }
    if (-not (Get-AppSettings).AutoNext) { $s.Msg = 'Finished'; return }
    $q = @($s.Queue); $i = [int]$s.Index + 1
    if ($i -le 0 -or $i -ge $q.Count) { $s.Msg = 'Finished'; return }
    Write-Log INFO "Cast: next episode $($q[$i].Title)"
    Start-Cast $s.Device $q[$i] $q $i $s.QueueNode
}

function Retry-CastProxied($S) {
    # NRK's servers may refuse the Chromecast directly: try once more through this PC
    if ($S.Proxied -or -not (Get-CastServer)) { return $false }
    Write-Log INFO 'Cast: playing it through this PC instead (the Chromecast could not open NRK''s stream directly)'
    $S.Proxied = $true; $S.Msg = 'Trying through this PC...'; $S.Start = [Math]::Max([double]$S.Start, [double]$S.Pos)
    Send-CastJson $S.TransportId $script:CastNs.Media (Get-CastLoad $S)
    return $true
}

# ---- TVs (DLNA)
function Invoke-DlnaAction([string] $Url, [string] $Service, [string] $Action, [string] $ArgsXml, [switch] $Async) {
    $body = '<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>' +
            ('<u:{0} xmlns:u="urn:schemas-upnp-org:service:{1}:1"><InstanceID>0</InstanceID>{2}</u:{0}>' -f $Action, $Service, $ArgsXml) + '</s:Body></s:Envelope>'
    $soapAction = '"urn:schemas-upnp-org:service:{0}:1#{1}"' -f $Service, $Action
    if ($Async) {
        # (status polling: in the background; Update-DlnaSession gives up on it after a few seconds)
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers['Content-Type'] = 'text/xml; charset="utf-8"'; $wc.Headers['SOAPAction'] = $soapAction
        return @{ Client = $wc; Task = $wc.UploadStringTaskAsync([Uri]$Url, 'POST', $body); At = Get-Date }
    }
    # commands: at most 4 s, so a TV that is off or asleep can't freeze the window
    try {
        $rq = [System.Net.HttpWebRequest]::Create($Url)
        $rq.Method = 'POST'; $rq.Timeout = 4000; $rq.ReadWriteTimeout = 4000
        $rq.ContentType = 'text/xml; charset="utf-8"'; $rq.Headers['SOAPAction'] = $soapAction
        $bytes = [Text.Encoding]::UTF8.GetBytes($body); $rq.ContentLength = $bytes.Length
        $st = $rq.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
        $rs = $rq.GetResponse()
        try { return (New-Object IO.StreamReader($rs.GetResponseStream())).ReadToEnd() } finally { $rs.Close() }
    } catch { Write-Log WARN "Cast (TV): $Action failed: $($_.Exception.Message)"; return $null }
}

function ConvertTo-XmlText([string] $Text) { return [Security.SecurityElement]::Escape($Text) }

function Set-DlnaStream($S, [double] $From) {
    # (re)start the stream on the TV at $From seconds: FFmpeg on this PC remuxes NRK's stream for it
    $srv = Get-CastServer
    if (-not $srv) { $S.Msg = 'Could not start the stream server on this PC'; return $false }
    if (-not $srv.FFmpeg) { $S.Msg = 'FFmpeg is needed to cast to a TV (Options > Components...)'; return $false }
    $m = $S.Media
    if (-not $S.Token) {
        $S.Token = [guid]::NewGuid().ToString('N').Substring(0, 12)
        $q = { param($u) '"' + ($u -replace '"', '') + '"' }
        $ss = if ($m.Live) { '' } else { '-ss {START} ' }
        if ($m.Audio) {
            $ffArgs = '-hide_banner -loglevel error -nostdin {0}-i {1} -vn -c:a libmp3lame -b:a 256k -f mp3 pipe:1' -f $ss, (& $q $m.Url)
        } else {
            $v = Select-HlsVariant $m.Url
            $in = ''; for ($i = 0; $i -lt $v.Inputs.Count; $i += 2) { $in += '{0}-i {1} ' -f $ss, (& $q $v.Inputs[$i + 1]) }
            $ffArgs = '-hide_banner -loglevel error -nostdin {0}{1} -c copy -f mpegts pipe:1' -f $in, ($v.Maps -join ' ')
        }
        $srv.SetRemux($S.Token, $ffArgs)
    }
    $ext = if ($m.Audio) { 'mp3' } else { 'ts' }
    $mime = if ($m.Audio) { 'audio/mpeg' } else { 'video/mp2t' }
    $url = 'http://{0}:{1}/ts/{2}.{3}?t={4}' -f ([NrkCastFind]::LocalIpFor($S.Device.Ip)), $srv.Port, $S.Token, $ext, [int]$From
    $cls = if ($m.Audio) { 'object.item.audioItem.musicTrack' } else { 'object.item.videoItem' }
    $didl = ('<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">' +
             '<item id="1" parentID="0" restricted="1"><dc:title>{0}</dc:title><upnp:class>{1}</upnp:class>' +
             '<res protocolInfo="http-get:*:{2}:DLNA.ORG_OP=00;DLNA.ORG_CI=1;DLNA.ORG_FLAGS=01700000000000000000000000000000">{3}</res></item></DIDL-Lite>') -f (ConvertTo-XmlText $m.Title), $cls, $mime, (ConvertTo-XmlText $url)
    [void](Invoke-DlnaAction $S.Device.Avt 'AVTransport' 'Stop' '')
    $r = Invoke-DlnaAction $S.Device.Avt 'AVTransport' 'SetAVTransportURI' ('<CurrentURI>{0}</CurrentURI><CurrentURIMetaData>{1}</CurrentURIMetaData>' -f (ConvertTo-XmlText $url), (ConvertTo-XmlText $didl))
    if ($null -eq $r) { $S.Msg = "$($S.Device.Name) did not accept the stream"; return $false }
    [void](Invoke-DlnaAction $S.Device.Avt 'AVTransport' 'Play' '<Speed>1</Speed>')
    $S.Start = $From; $S.Pos = $From; $S.PosAt = Get-Date; $S.State = 'loading'; $S.Msg = 'Starting on the TV...'
    Write-Log INFO "Cast (TV): $url"
    return $true
}

function Start-DlnaSession($S) {
    $res = @{ Ok = $false }
    Invoke-Ui "Starting on $($S.Device.Name)" { $res.Ok = Set-DlnaStream $S $S.Start }
    $ok = $res.Ok
    if (-not $ok) { [void][System.Windows.Forms.MessageBox]::Show($form, "Could not cast to $($S.Device.Name):`n$($S.Msg)", 'Cast', 'OK', 'Warning') }
    return $ok
}

function Update-DlnaSession($S) {
    $srv = $script:Cast.Server
    if ($srv) { $l = $null; while ($srv.Log.TryDequeue([ref]$l)) { Write-Log DEBUG "Cast server: $l" } }
    if ($S.Http) {
        if (-not $S.Http.Task.IsCompleted) {
            if (((Get-Date) - $S.Http.At).TotalSeconds -gt 6) { try { $S.Http.Client.CancelAsync(); $S.Http.Client.Dispose() } catch { }; $S.Http = $null; $S.Msg = "$($S.Device.Name) is not answering" }
            return
        }
        $h = $S.Http; $S.Http = $null
        try {
            if (-not $h.Task.IsFaulted) {
                $x = [string]$h.Task.Result
                if ($x -match '<CurrentTransportState>([^<]+)<') {
                    $st = $Matches[1]
                    $S.State = switch ($st) { 'PLAYING' { 'PLAYING' } 'PAUSED_PLAYBACK' { 'PAUSED' } 'TRANSITIONING' { 'BUFFERING' } 'STOPPED' { 'IDLE' } 'NO_MEDIA_PRESENT' { 'IDLE' } default { $st } }
                    if ($S.State -in 'PLAYING', 'PAUSED') { $S.Loaded = $true; $S.Msg = '' }
                    elseif ($S.State -eq 'IDLE' -and $S.Loaded) {
                        # stopped by itself near the end: finished, the next episode follows
                        if ($S.Dur -gt 0 -and (Get-CastPosition $S) -ge $S.Dur - 30) { Set-PlayPosition $S.File $S.Dur $S.Dur -Ended; Start-CastNext; return }
                        $S.Msg = 'Stopped on the TV'
                    }
                }
                if ($x -match '<RelTime>(\d+):(\d\d):(\d\d)') {
                    $rel = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]
                    $S.Pos = [double]$S.Start + $rel; $S.PosAt = Get-Date
                    if ($S.Loaded -and -not $S.Media.Live -and ((Get-Date) - $S.LastSave).TotalSeconds -ge 5) { $S.LastSave = Get-Date; Set-PlayPosition $S.File $S.Pos $S.Dur }
                }
            }
        } finally { try { $h.Client.Dispose() } catch { } }
    }
    if (((Get-Date) - $S.LastPoll).TotalSeconds -ge 2) {
        $S.LastPoll = Get-Date
        # ask for both in turn
        $S.PollFlip = -not $S.PollFlip
        $S.Http = if ($S.PollFlip) { Invoke-DlnaAction $S.Device.Avt 'AVTransport' 'GetTransportInfo' '' -Async } else { Invoke-DlnaAction $S.Device.Avt 'AVTransport' 'GetPositionInfo' '' -Async }
    }
}

# ---- controls (cast bar, keyboard, tray)
function Get-CastPosition($S) {
    $p = [double]$S.Pos
    if ($S.State -eq 'PLAYING') { $p += ((Get-Date) - $S.PosAt).TotalSeconds }
    if ($S.Dur -gt 0) { $p = [Math]::Min($p, $S.Dur) }
    return [Math]::Max(0, $p)
}

function Invoke-CastCommand([string] $What, [double] $Value = 0) {
    $s = $script:Cast.Session
    if (-not $s) { return }
    $media = { param($obj) if ($s.MediaSessionId) { $obj['mediaSessionId'] = $s.MediaSessionId; Send-CastJson $s.TransportId $script:CastNs.Media $obj } }
    $isCast = ($s.Device.Kind -eq 'cast')
    switch ($What) {
        'toggle' { if ($s.State -eq 'PLAYING') { Invoke-CastCommand 'pause' } else { Invoke-CastCommand 'play' } }
        'play'   { if ($isCast) { & $media ([ordered]@{ type = 'PLAY' }) } else { [void](Invoke-DlnaAction $s.Device.Avt 'AVTransport' 'Play' '<Speed>1</Speed>') }; $s.PosAt = Get-Date; $s.State = 'PLAYING' }
        'pause'  { $s.Pos = Get-CastPosition $s; $s.PosAt = Get-Date; if ($isCast) { & $media ([ordered]@{ type = 'PAUSE' }) } else { [void](Invoke-DlnaAction $s.Device.Avt 'AVTransport' 'Pause' '') }; $s.State = 'PAUSED'; if (-not $s.Media.Live) { Set-PlayPosition $s.File $s.Pos $s.Dur } }
        'seek'   {
            if ($s.Media.Live) { return }
            $to = [Math]::Max(0, $(if ($s.Dur -gt 0) { [Math]::Min($Value, $s.Dur - 2) } else { $Value }))
            if ($isCast) { & $media ([ordered]@{ type = 'SEEK'; currentTime = $to; resumeState = 'PLAYBACK_START' }) } else { [void](Set-DlnaStream $s $to) }
            $s.Pos = $to; $s.PosAt = Get-Date
        }
        'rel'    { Invoke-CastCommand 'seek' ((Get-CastPosition $s) + $Value) }
        'volume' {
            $v = [Math]::Max(0, [Math]::Min(1, $Value)); $s.Volume = $v
            if ($isCast) { Send-CastJson 'receiver-0' $script:CastNs.Recv ([ordered]@{ type = 'SET_VOLUME'; volume = [ordered]@{ level = $v } }) }
            elseif ($s.Device.Rc) { [void](Invoke-DlnaAction $s.Device.Rc 'RenderingControl' 'SetVolume' ('<Channel>Master</Channel><DesiredVolume>{0}</DesiredVolume>' -f [int]($v * 100))) }
        }
        'mute'   {
            $s.Muted = -not $s.Muted
            if ($isCast) { Send-CastJson 'receiver-0' $script:CastNs.Recv ([ordered]@{ type = 'SET_VOLUME'; volume = [ordered]@{ muted = $s.Muted } }) }
            elseif ($s.Device.Rc) { [void](Invoke-DlnaAction $s.Device.Rc 'RenderingControl' 'SetMute' ('<Channel>Master</Channel><DesiredMute>{0}</DesiredMute>' -f [int]$s.Muted)) }
        }
        'subs'   {
            if (-not $isCast -or -not @($s.Media.Subs).Count) { return }
            $s.SubsOn = -not $s.SubsOn
            & $media ([ordered]@{ type = 'EDIT_TRACKS_INFO'; activeTrackIds = @($(if ($s.SubsOn) { 1 })) })
        }
    }
    Update-CastBar
}

function Close-CastSession([string] $Why, [switch] $Next) {
    $s = $script:Cast.Session
    if (-not $s) { return }
    if ($s.Loaded -and -not $s.Media.Live -and $s.State -ne 'IDLE') { Set-PlayPosition $s.File (Get-CastPosition $s) $s.Dur }
    try { Save-PosMap -Force } catch { }
    try { if ($s.Link) { $s.Link.Close() } } catch { }
    try { if ($s.Token -and $script:Cast.Server) { $script:Cast.Server.StopRemux($s.Token) } } catch { }
    # the little server only runs while something is cast (nothing listens on the network otherwise)
    if (-not $Next) { try { if ($script:Cast.Server) { $script:Cast.Server.Dispose(); $script:Cast.Server = $null; Write-Log INFO 'Cast server stopped' } } catch { } }
    $script:Cast.Session = $null; $script:CastTrayText = $null
    if ($script:CastTimer) { $script:CastTimer.Stop() }
    Hide-CastBar
    if ($Why) { Set-Status $Why }
}

function Stop-Cast([switch] $Quiet, [switch] $LeavePlaying) {
    # stop on the device too (a Chromecast keeps playing by itself unless told)
    $s = $script:Cast.Session
    if (-not $s) { return }
    Write-Log INFO "Cast: stop ($($s.Device.Name))$(if ($LeavePlaying) { ', left playing' })"
    if (-not $LeavePlaying) {
        try {
            if ($s.Device.Kind -eq 'cast') { if ($s.SessionId) { Send-CastJson 'receiver-0' $script:CastNs.Recv ([ordered]@{ type = 'STOP'; sessionId = $s.SessionId }) } }
            else { [void](Invoke-DlnaAction $s.Device.Avt 'AVTransport' 'Stop' '') }
        } catch { }
    }
    if (-not $LeavePlaying -and -not $Quiet) { Save-LastPlayed $null }   # stopped on purpose: nothing to continue
    Close-CastSession $(if ($Quiet) { '' } else { "Stopped casting to $($s.Device.Name)" })
}

# ---- the cast bar (bottom of the main window)
function New-CastBar {
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = 60; $bar.BackColor = $T.Panel; $bar.Visible = $false
    $line = New-Object System.Windows.Forms.Panel; $line.Dock = 'Top'; $line.Height = 1; $line.BackColor = $T.Border
    $info = New-Object System.Windows.Forms.Label
    $info.Dock = 'Left'; $info.Width = 330; $info.Padding = New-Object System.Windows.Forms.Padding(16, 6, 8, 6); $info.ForeColor = $T.Text; $info.AutoEllipsis = $true
    $right = New-Object System.Windows.Forms.FlowLayoutPanel
    $right.Dock = 'Right'; $right.Width = 560; $right.WrapContents = $false; $right.BackColor = $T.Panel; $right.Padding = New-Object System.Windows.Forms.Padding(0, 12, 12, 0)
    $mk = { param([string] $t, [int] $w) $b = New-FlatButton $t $w; $b.Height = 34; $b.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 0); $b }
    $bBack = & $mk ('{0} 30' -f [char]0x21BA) 62
    $bPlay = & $mk ([string][char]0x2016) 46
    $bFwd = & $mk ('30 {0}' -f [char]0x21BB) 62
    $time = New-Object System.Windows.Forms.Label; $time.Width = 120; $time.Height = 34; $time.TextAlign = 'MiddleCenter'; $time.ForeColor = $T.Muted
    $bSubs = & $mk 'CC' 46
    $bMute = & $mk ([string][char]0x266A) 40
    $vol = New-Object System.Windows.Forms.TrackBar; $vol.Minimum = 0; $vol.Maximum = 100; $vol.TickStyle = 'None'; $vol.Width = 90; $vol.AutoSize = $false; $vol.Height = 30; $vol.BackColor = $T.Panel
    $bStop = & $mk ('{0}  Stop casting' -f [char]0x25A0) 140; $bStop.ForeColor = $T.Bad
    # 2.9.2: icons in the chosen look
    Set-IconText $bBack 'rewind' '30' -Plain ('{0} 30' -f [char]0x21BA)
    Set-IconText $bFwd 'forward' '30' -Plain ('30 {0}' -f [char]0x21BB)
    Set-IconText $bPlay 'pause' '' ([string][char]0x2016) -IconOnly
    Set-IconText $bMute 'volume' '' ([string][char]0x266A) -IconOnly
    Set-IconText $bStop 'stop' 'Stop casting' ([string][char]0x25A0)
    $right.Controls.AddRange(@($bBack, $bPlay, $bFwd, $time, $bSubs, $bMute, $vol, $bStop))
    $mid = New-Object System.Windows.Forms.Panel; $mid.Dock = 'Fill'; $mid.BackColor = $T.Panel; $mid.Padding = New-Object System.Windows.Forms.Padding(4, 16, 8, 0)
    $seek = New-Object System.Windows.Forms.TrackBar; $seek.Minimum = 0; $seek.Maximum = 1000; $seek.TickStyle = 'None'; $seek.Dock = 'Top'; $seek.AutoSize = $false; $seek.Height = 30; $seek.BackColor = $T.Panel
    $mid.Controls.Add($seek)
    $bar.Controls.Add($mid); $bar.Controls.Add($right); $bar.Controls.Add($info); $bar.Controls.Add($line)
    $tips = New-Object System.Windows.Forms.ToolTip
    $tips.SetToolTip($bBack, 'Back 30 seconds'); $tips.SetToolTip($bFwd, 'Forward 30 seconds'); $tips.SetToolTip($bSubs, 'Subtitles on/off (Chromecast)'); $tips.SetToolTip($bMute, 'Mute on the device')
    $script:CastUi = @{ Bar = $bar; Stop = $bStop; Info = $info; Play = $bPlay; Time = $time; Subs = $bSubs; Mute = $bMute; Vol = $vol; Seek = $seek; Dragging = $false; Tips = $tips; Back = $bBack; Fwd = $bFwd }
    $bBack.Add_Click({ Invoke-CastCommand 'rel' -30 })
    $bFwd.Add_Click({ Invoke-CastCommand 'rel' 30 })
    $bPlay.Add_Click({ Invoke-CastCommand 'toggle' })
    $bSubs.Add_Click({ Invoke-CastCommand 'subs' })
    $bMute.Add_Click({ Invoke-CastCommand 'mute' })
    $bStop.Add_Click({ Stop-Cast })
    $vol.Add_MouseUp({ Invoke-CastCommand 'volume' ($this.Value / 100.0) })
    $vol.Add_KeyUp({ Invoke-CastCommand 'volume' ($this.Value / 100.0) })
    $seek.Add_MouseDown({ $script:CastUi.Dragging = $true })
    $seek.Add_MouseUp({
        $script:CastUi.Dragging = $false
        $s = $script:Cast.Session
        if ($s -and $s.Dur -gt 0) { Invoke-CastCommand 'seek' ($this.Value / 1000.0 * $s.Dur) }
    })
    return $bar
}

function Show-CastBar {
    if (-not $script:CastUi) {
        # made the first time it is needed; placed between the radio bar and the status bar
        $bar = New-CastBar
        $form.Controls.Add($bar)
        $form.Controls.SetChildIndex($bar, $form.Controls.GetChildIndex($audioBar))
        Set-DarkTheme $bar
        foreach ($c in @($bar) + @($bar.Controls)) { if ($c -is [System.Windows.Forms.Panel] -and $c.Height -ne 1) { $c.BackColor = $T.Panel } }
        $script:CastUi.Stop.ForeColor = $T.Bad   # (the theme pass made it plain)
    }
    $script:CastUi.Bar.Visible = $true; Update-CastBar
}
function Hide-CastBar { if ($script:CastUi) { $script:CastUi.Bar.Visible = $false } }

function Update-CastBar {
    $u = $script:CastUi; $s = $script:Cast.Session
    if (-not $u -or -not $s) { return }
    $kind = if ($s.Device.Kind -eq 'cast') { 'Chromecast' } else { 'TV' }
    $title = if ($s.File.ListTitle) { $s.File.ListTitle } elseif ($s.Media.Sub -and $s.File.Type -eq 'episode') { '{0}  ·  {1}' -f $s.Media.Sub, $s.File.Title } else { $s.File.Title }
    $set = { param($c, [string] $v) if ($c.Text -ne $v) { $c.Text = $v } }   # (only what changed: no flicker, 3 times a second)
    & $set $u.Info "Casting to $($s.Device.Name)  ($kind)`n$(if ($s.Msg) { $s.Msg } else { $title })"
    $playing = ($s.State -eq 'PLAYING' -or $s.State -eq 'BUFFERING')
    if ($u.PlayState -ne $playing) { $u.PlayState = $playing; if ($playing) { Set-IconText $u.Play 'pause' '' ([string][char]0x2016) -IconOnly } else { Set-IconText $u.Play 'play' '' ([string][char]0x25B6) -IconOnly } }
    $live = [bool]$s.Media.Live
    $u.Back.Enabled = -not $live; $u.Fwd.Enabled = -not $live; $u.Seek.Enabled = (-not $live -and $s.Dur -gt 0)
    $p = Get-CastPosition $s
    & $set $u.Time $(if ($live) { 'LIVE' } elseif ($s.Dur -gt 0) { '{0} / {1}' -f (Format-PlayTime $p), (Format-PlayTime $s.Dur) } else { Format-PlayTime $p })
    if (-not $u.Dragging -and $s.Dur -gt 0) { $sv = [int][Math]::Max(0, [Math]::Min(1000, $p / $s.Dur * 1000)); if ($u.Seek.Value -ne $sv) { $u.Seek.Value = $sv } }
    $u.Subs.Visible = ($s.Device.Kind -eq 'cast' -and @($s.Media.Subs).Count -gt 0)
    $u.Subs.ForeColor = if ($s.SubsOn) { $T.Accent } else { $T.Muted }
    $u.Mute.ForeColor = if ($s.Muted) { $T.Bad } else { $T.Text }
    $u.Mute.Enabled = ($s.Device.Kind -eq 'cast' -or [bool]$s.Device.Rc); $u.Vol.Enabled = $u.Mute.Enabled
    if (-not $u.Vol.Focused -and -not $u.Vol.Capture) { $u.Vol.Value = [int][Math]::Max(0, [Math]::Min(100, $s.Volume * 100)) }
    $tt = "Casting: {0}" -f $s.File.Title
    if ($script:CastTrayText -ne $tt) { $script:CastTrayText = $tt; Set-TrayText $tt }
}

# ---- sleep timer (player window, radio bar, tray) -------------------------------------------
$script:Sleep = @{ Until = $null; EndOfItem = $false; Timer = $null }

function Get-SleepLabel {
    $z = $script:Sleep
    if ($z.EndOfItem) { return 'after this one' }
    if ($z.Until) { $m = [Math]::Ceiling(($z.Until - (Get-Date)).TotalMinutes); return "$m min left" }
    return ''
}

function Set-SleepTimer([int] $Minutes = 0, [switch] $EndOfItem) {
    $z = $script:Sleep
    $z.EndOfItem = [bool]$EndOfItem
    $z.Until = if ($Minutes -gt 0) { (Get-Date).AddMinutes($Minutes) } else { $null }
    Stop-SleepFade; if ($z.Timer) { $z.Timer.Interval = 15000 }
    if (-not $z.Timer) {
        $z.Timer = New-Object System.Windows.Forms.Timer; $z.Timer.Interval = 15000
        $z.Timer.Add_Tick({
            $z = $script:Sleep
            if ($z.Until -and (Get-Date) -ge $z.Until) { Invoke-SleepNow }
            else {
                # 2.9.0: the last minute gets quieter (Options > Listening); the timer looks every second then
                $left = if ($z.Until) { ($z.Until - (Get-Date)).TotalSeconds } else { 999 }
                if ($left -le 75) { $z.Timer.Interval = 1000 }
                if ($left -le 60 -and (Get-AppSettings).SleepFade) { Start-SleepFade ([Math]::Max(1, $left)) }
                Update-SleepUi
            }
        })
    }
    if ($z.Until -or $z.EndOfItem) { $z.Timer.Start(); Write-Log INFO "Sleep timer: $(Get-SleepLabel)"; Set-Status "Sleep timer: $(Get-SleepLabel)" }
    else { $z.Timer.Stop(); Write-Log INFO 'Sleep timer: off'; Set-Status 'Sleep timer off' }
    Update-SleepUi
}

function Update-SleepUi {
    $on = [bool]($script:Sleep.Until -or $script:Sleep.EndOfItem); $label = Get-SleepLabel
    try { Invoke-AudioScript ("nrkb.setSleep({0}, '{1}')" -f $on.ToString().ToLower(), $label) } catch { }
    $pw = $script:PlayerWin
    if ($pw -and $pw.Sleep -and -not $pw.Form.IsDisposed) { $st = if ($on) { "Sleep: $label" } else { 'Sleep  ' + [char]0x25BE }; Set-IconText $pw.Sleep 'sleep' $st -Plain $st; $pw.Sleep.ForeColor = if ($on) { $T.Accent } else { $T.Text } }
}

function Invoke-SleepNow {
    # time is up: pause whatever plays (video, radio, the cast device)
    $script:Sleep.Until = $null; $script:Sleep.EndOfItem = $false
    if ($script:Sleep.Timer) { $script:Sleep.Timer.Stop() }
    Write-Log INFO 'Sleep timer: pausing'
    if ($script:Cast.Session) { Invoke-CastCommand 'pause' }
    else { $m = Get-MediaState; if ($m.Playing) { Invoke-MediaCommand 'pause' } }
    Stop-SleepFade   # (paused: the volume back for next time)
    if ($script:Sleep.Timer) { $script:Sleep.Timer.Interval = 15000 }
    Update-SleepUi
    Set-Status 'Sleep timer: paused'
    if ($script:TrayUi -and $script:TrayUi.Icon.Visible) { $script:TrayUi.Icon.ShowBalloonTip(3000, 'NRK Browser', 'Sleep timer: paused', [System.Windows.Forms.ToolTipIcon]::None) }
}

function Test-SleepAtEnd {
    # "after this one": called when something ends; $true = don't start the next one
    if (-not $script:Sleep.EndOfItem) { return $false }
    Invoke-SleepNow
    return $true
}

function Show-SleepMenu($Control, $Point = $null) {
    if (-not $script:SleepMenu) { $script:SleepMenu = New-ThemedMenu }
    $m = $script:SleepMenu; $m.Items.Clear()
    $head = New-ThemedMenuItem $(if (Get-SleepLabel) { "Sleep timer: $(Get-SleepLabel)" } else { 'Pause after' }); $head.Enabled = $false; [void]$m.Items.Add($head)
    foreach ($min in 15, 30, 45, 60, 90, 120) {
        $i = New-ThemedMenuItem ("   {0} minutes" -f $min); $i.Tag = $min
        $i.Add_Click({ Set-SleepTimer ([int]$this.Tag) }); [void]$m.Items.Add($i)
    }
    $e = New-ThemedMenuItem '   The end of this episode'; $e.Checked = [bool]$script:Sleep.EndOfItem
    $e.Add_Click({ Set-SleepTimer -EndOfItem }); [void]$m.Items.Add($e)
    if (Get-SleepLabel) { [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); $o = New-ThemedMenuItem 'Turn the sleep timer off'; $o.Add_Click({ Set-SleepTimer 0 }); [void]$m.Items.Add($o) }
    if ($Control) { $m.Show($Control, (New-Object System.Drawing.Point(0, ($Control.Height + 2)))) }
    else { $m.Show($(if ($Point) { $Point } else { [System.Windows.Forms.Cursor]::Position })) }
}

# ---- radio: your own queue ("Play next" / "Add to queue" in the files list) ------------------
function Add-AudioQueue([object[]] $Files, [switch] $Next) {
    $u = $script:AudioUi
    if (-not $u.UserQueue) { $u.UserQueue = New-Object System.Collections.ArrayList }
    $list = @($Files | Where-Object { $_ -and $_.Type -eq 'audio' -and $_.Playable })
    if (-not $list.Count) { return }
    if ($Next) { for ($i = $list.Count - 1; $i -ge 0; $i--) { $u.UserQueue.Insert(0, $list[$i]) } } else { foreach ($f in $list) { [void]$u.UserQueue.Add($f) } }
    Write-Log INFO ("Radio queue: {0} {1} (now {2})" -f $(if ($Next) { 'next:' } else { 'added' }), (($list | ForEach-Object Title) -join ', '), $u.UserQueue.Count)
    # nothing playing: start it
    if (-not $u.Current) { $f = $u.UserQueue[0]; $u.UserQueue.RemoveAt(0); Start-AudioPlayer $f; return }
    try { Invoke-AudioScript "nrkb.setNav($(Get-AudioNavJson))" } catch { }
    Set-Status ('Radio queue: {0} waiting  ·  "{1}" plays next' -f $u.UserQueue.Count, $u.UserQueue[0].Title)
}

function Clear-AudioQueue { if ($script:AudioUi.UserQueue) { $script:AudioUi.UserQueue.Clear() }; try { Invoke-AudioScript "nrkb.setNav($(Get-AudioNavJson))" } catch { }; Set-Status 'Radio queue cleared' }

# ---- player window: speed, subtitles, sound track, live buffer --------------------------------
$script:VideoRates = @(0.75, 1, 1.25, 1.5, 1.75, 2)
$script:SubSizes = [ordered]@{ '90' = 'Small'; '120' = 'Normal'; '150' = 'Large'; '190' = 'Very large' }

function Invoke-PlayerScript([string] $Js) {
    $pw = $script:PlayerWin
    if ($pw -and $pw.WebView.CoreWebView2) { try { [void]$pw.WebView.CoreWebView2.ExecuteScriptAsync("window.nrkb && $Js") } catch { } }
}

function Get-UpNextTitle($Target) {
    # the title for the "next episode" card, or $null (no card: off, live, last one, or not from a list)
    $st = Get-AppSettings
    if (-not $st.UpNextCard -or -not $st.AutoNext -or -not $Target -or -not $Target.File -or $Target.File.Type -eq 'live') { return $null }
    $q = @($script:VideoQueue); $i = $script:VideoIndex
    if ($q.Count -lt 2 -or $i -lt 0 -or $i -ge $q.Count - 1) { return $null }
    return [string]$q[$i + 1].Title
}

function Show-PlayerQualityMenu {
    $pw = $script:PlayerWin
    if (-not $script:QualMenu) { $script:QualMenu = New-ThemedMenu }
    $m = $script:QualMenu; $m.Items.Clear()
    $now = @($pw.Levels | Where-Object { [int]$_.i -eq [int]$pw.LevelNow }) | Select-Object -First 1
    $auto = New-ThemedMenuItem $(if ($now -and $now.h) { 'Auto  (now {0}p)' -f $now.h } else { 'Auto' }); $auto.Tag = -1; $auto.Checked = ($pw.Level -lt 0)
    $auto.Add_Click({ Invoke-PlayerScript 'nrkb.level(-1)'; $script:PlayerWin.Level = -1 }); [void]$m.Items.Add($auto)
    foreach ($l in @($pw.Levels | Sort-Object { [int]$_.h }, { [int]$_.br } -Descending)) {
        $label = if ($l.h) { '{0}p' -f $l.h } else { 'Level {0}' -f ([int]$l.i + 1) }
        if ($l.br) { $label += '   ({0:N1} Mbit/s)' -f ([double]$l.br / 1e6) }
        $it = New-ThemedMenuItem $label; $it.Tag = [int]$l.i; $it.Checked = ([int]$pw.Level -eq [int]$l.i)
        $it.Add_Click({ Invoke-PlayerScript "nrkb.level($($this.Tag))"; $script:PlayerWin.Level = [int]$this.Tag; Write-Log INFO "Player: quality $($this.Text)" }); [void]$m.Items.Add($it)
    }
    $m.Show($pw.Qual, (New-Object System.Drawing.Point(0, ($pw.Qual.Height + 2))))
}

function Save-PlayerShot($M) {
    # the picture from the page (PNG, base64) into Pictures\NRK-Browser
    if ($M.error) { Set-Status "Screenshot not saved: $($M.error)"; Write-Log WARN "Screenshot: $($M.error)"; return }
    try {
        $dir = Join-Path ([Environment]::GetFolderPath('MyPictures')) 'NRK-Browser'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $pw = $script:PlayerWin
        $title = if ($pw.Target -and $pw.Target.Title) { [string]$pw.Target.Title } else { 'NRK' }
        $f = Join-Path $dir ('{0} {1}.png' -f (Get-SafeFileName $title), (Format-PlayTime ([double]$M.t)).Replace(':', '.'))
        [IO.File]::WriteAllBytes($f, [Convert]::FromBase64String([string]$M.data))
        Write-Log INFO "Screenshot saved: $f"
        Set-Status "Screenshot saved: $f"
        if ($pw.Hint) { $pw.Hint.Text = 'Screenshot saved in Pictures\NRK-Browser' }
    } catch { Write-LogException $_ 'Screenshot' }
}

function Set-PlayerMini([bool] $On) {
    # a small player that stays on top in the corner (again: back to how it was)
    $pw = $script:PlayerWin
    if (-not $pw -or $pw.Form.IsDisposed) { return }
    $f = $pw.Form
    if ($On -and -not $pw.Mini) {
        if ($pw.Full) { Set-PlayerFullScreen $false }
        $pw.Mini = @{ Bounds = $(if ($f.WindowState -eq 'Normal') { $f.Bounds } else { $f.RestoreBounds }); State = $f.WindowState; TopMost = $f.TopMost; Border = $f.FormBorderStyle; Min = $f.MinimumSize }
        $f.WindowState = 'Normal'
        $f.FormBorderStyle = 'SizableToolWindow'; $f.MinimumSize = New-Object System.Drawing.Size(320, 220)
        $wa = [System.Windows.Forms.Screen]::FromHandle($f.Handle).WorkingArea
        $w = 520; $h = 340
        $f.Bounds = New-Object System.Drawing.Rectangle(($wa.Right - $w - 16), ($wa.Bottom - $h - 16), $w, $h)
        $f.TopMost = $true
        Set-IconText $pw.MiniBtn 'mini' 'Normal size'
        Write-Log INFO 'Player: mini player'
    } elseif (-not $On -and $pw.Mini) {
        $prev = $pw.Mini; $pw.Mini = $null
        $f.FormBorderStyle = $prev.Border; $f.MinimumSize = $prev.Min; $f.TopMost = $prev.TopMost
        $f.Bounds = $prev.Bounds
        if ($prev.State -eq 'Maximized') { $f.WindowState = 'Maximized' }
        Set-IconText $pw.MiniBtn 'mini' 'Mini'
        foreach ($c in $pw.Bar.Controls) { $c.Visible = $true }
        Update-PlayerNav
        Write-Log INFO 'Player: normal size'
    }
    Update-PlayerExtras
}

function Format-Rate([double] $R) { return ('{0}x' -f $R.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)) }

function Update-PlayerExtras {
    # which of the extra buttons apply to what is playing now
    $pw = $script:PlayerWin
    if (-not $pw -or -not $pw.Speed) { return }
    $b = ($pw.Mode -eq 'builtin'); $live = [bool]($pw.Target -and $pw.Target.File -and $pw.Target.File.Type -eq 'live')
    $pw.Speed.Visible = ($b -and -not $live)
    $sp = 'Speed ' + (Format-Rate ([double](Get-AppSettings).VideoRate)); Set-IconText $pw.Speed 'speed' $sp -Plain $sp
    $pw.Subs.Visible = ($b -and @($pw.SubList).Count -gt 0)
    $pw.Audio.Visible = ($b -and (@($pw.ATracks).Count -gt 1 -or @($pw.Versions).Count -gt 0))
    foreach ($x in $pw.StartOver, $pw.LiveBack, $pw.LiveGo) { $x.Visible = ($b -and $live) }
    if ($pw.Qual) { $pw.Qual.Visible = ($b -and @($pw.Levels).Count -gt 1); $pw.Shot.Visible = $b }
    if ($pw.Mini) { foreach ($c in $pw.Bar.Controls) { if ($c -ne $pw.MiniBtn) { $c.Visible = $false } } }   # (mini: only the way back)
    Update-SleepUi
}

function Show-PlayerSubsMenu {
    $pw = $script:PlayerWin
    if (-not $script:SubsMenu) { $script:SubsMenu = New-ThemedMenu }
    $m = $script:SubsMenu; $m.Items.Clear()
    $st = Get-AppSettings
    $off = New-ThemedMenuItem 'Off'; $off.Checked = ($pw.SubIndex -lt 0); $off.Tag = -1
    $off.Add_Click({ Set-PlayerSubs ([int]$this.Tag) }); [void]$m.Items.Add($off)
    for ($i = 0; $i -lt @($pw.SubList).Count; $i++) {
        $it = New-ThemedMenuItem ([string]$pw.SubList[$i].label); $it.Tag = $i; $it.Checked = ($pw.SubIndex -eq $i)
        $it.Add_Click({ Set-PlayerSubs ([int]$this.Tag) }); [void]$m.Items.Add($it)
    }
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $h = New-ThemedMenuItem 'Text size'; $h.Enabled = $false; [void]$m.Items.Add($h)
    foreach ($k in $script:SubSizes.Keys) {
        $z = New-ThemedMenuItem ('   ' + $script:SubSizes[$k]); $z.Tag = $k; $z.Checked = ([string]$st.SubSize -eq $k)
        $z.Add_Click({ $s = Get-AppSettings; $s.SubSize = [int]$this.Tag; Save-AppSettings $s; Invoke-PlayerScript "nrkb.subSize($($this.Tag))" }); [void]$m.Items.Add($z)
    }
    # colour, background and height (kept for every programme)
    foreach ($grp in @(@('Colour', 'SubColor', 'color', [ordered]@{ white = 'White'; yellow = 'Yellow'; cyan = 'Light blue'; green = 'Green' }),
                       @('Background', 'SubBg', 'bg', [ordered]@{ box = 'Dark box (as NRK)'; solid = 'Black box'; shadow = 'No box, shadow' }),
                       @('Position', 'SubPos', 'pos', [ordered]@{ bottom = 'Bottom'; raised = 'A bit higher'; top = 'Top' }))) {
        [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $h = New-ThemedMenuItem $grp[0]; $h.Enabled = $false; [void]$m.Items.Add($h)
        foreach ($k in $grp[3].Keys) {
            $z = New-ThemedMenuItem ('   ' + $grp[3][$k]); $z.Tag = @{ Key = $grp[1]; Js = $grp[2]; Val = $k }; $z.Checked = ([string]$st.($grp[1]) -eq $k)
            $z.Add_Click({ $t = $this.Tag; $s = Get-AppSettings; $s.($t.Key) = $t.Val; Save-AppSettings $s; Invoke-PlayerScript ("nrkb.subStyle({{""{0}"":""{1}""}})" -f $t.Js, $t.Val) }); [void]$m.Items.Add($z)
        }
    }
    $m.Show($pw.Subs, (New-Object System.Drawing.Point(0, ($pw.Subs.Height + 2))))
}

function Set-PlayerSubs([int] $Index) {
    $pw = $script:PlayerWin
    $pw.SubIndex = $Index
    Invoke-PlayerScript "nrkb.subs($Index)"
    $s = Get-AppSettings; $s.SubsOff = ($Index -lt 0); Save-AppSettings $s   # (remembered for the next programme)
    $pw.Subs.ForeColor = if ($Index -ge 0) { $T.Accent } else { $T.Text }
}

function Show-PlayerAudioMenu {
    $pw = $script:PlayerWin
    if (-not $script:AudioMenuV) { $script:AudioMenuV = New-ThemedMenu }
    $m = $script:AudioMenuV; $m.Items.Clear()
    if (@($pw.ATracks).Count -gt 1) {
        $h = New-ThemedMenuItem 'Sound'; $h.Enabled = $false; [void]$m.Items.Add($h)
        foreach ($t in $pw.ATracks) {
            $name = [string]$t.name; if ($name -match 'synstolk') { $name += '  (audio description)' }
            $it = New-ThemedMenuItem ('   ' + $name); $it.Tag = [int]$t.i; $it.Checked = ([int]$t.i -eq [int]$pw.ATrack)
            $it.Add_Click({ Invoke-PlayerScript "nrkb.audio($($this.Tag))" }); [void]$m.Items.Add($it)
        }
    }
    if (@($pw.Versions).Count) {
        # other versions of the programme NRK lists (sign language, ...)
        if ($m.Items.Count) { [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }
        $h = New-ThemedMenuItem 'Version'; $h.Enabled = $false; [void]$m.Items.Add($h)
        $d = New-ThemedMenuItem '   Standard'; $d.Checked = -not $pw.Target.Manifest; $d.Tag = ''
        $d.Add_Click({ Start-PlayerVersion '' }); [void]$m.Items.Add($d)
        foreach ($v in $pw.Versions) {
            $it = New-ThemedMenuItem ('   ' + $v.Label); $it.Tag = $v.Href; $it.Checked = ($pw.Target.Manifest -eq $v.Href)
            $it.Add_Click({ Start-PlayerVersion ([string]$this.Tag) }); [void]$m.Items.Add($it)
        }
    }
    $m.Show($pw.Audio, (New-Object System.Drawing.Point(0, ($pw.Audio.Height + 2))))
}

function Start-PlayerVersion([string] $Href) {
    $t = $script:PlayerWin.Target
    if (-not $t) { return }
    Write-Log INFO "Player: version $(if ($Href) { $Href } else { 'standard' })"
    Start-Player -Target ([pscustomobject]@{ Url = $t.Url; Title = $t.Title; File = $t.File; Manifest = $Href }) -FromQueue
}

function Invoke-LiveStartOver {
    # the programme on now, from its beginning (as far back as NRK's live buffer goes, about 3 hours)
    $pw = $script:PlayerWin
    $f = $pw.Target.File
    if (-not $f) { return }
    $res = @{ Sec = 0; Title = '' }
    Invoke-Ui 'Reading the programme guide' {
        $now = Get-Date
        $e = @(Get-NrkEpg -ChannelId $f.Id) | Where-Object { $_.Start -le $now -and $_.End -gt $now } | Select-Object -First 1
        if ($e) { $res.Sec = [int]($now - $e.Start).TotalSeconds; $res.Title = $e.Title }
    }
    if ($res.Sec -le 0) { Set-Status 'Start over: no programme guide for this channel right now'; return }
    Invoke-PlayerScript "nrkb.startOver($($res.Sec + 5))"
    Set-Status ("Start over: {0}, from {1} ago" -f $res.Title, (Format-PlayTime $res.Sec))
}

# ---- download history: what was downloaded before, even if the file was moved or deleted ------
$script:DlHistFile = Join-Path $script:AppDataDir 'dlhistory.json'
$script:DlHist = $null

function Get-DlHistory {
    if ($null -ne $script:DlHist) { return $script:DlHist }
    $m = @{}
    $j = Read-JsonFile $script:DlHistFile
    if ($j) { foreach ($r in @($j.Items | Where-Object { $_ -and $_.Key })) { $m[[string]$r.Key] = $r } }
    $script:DlHist = $m
    return $m
}

function Add-DlHistory($Item) {
    if (-not $Item.File -or -not $Item.File.Id) { return }
    $m = Get-DlHistory; $k = Get-FileKey $Item.File
    $m[$k] = [pscustomobject]@{ Key = $k; Title = [string]$Item.Title; File = [string](@($Item.Files)[0]); At = (Get-Date).ToString('o') }
    Write-JsonFile $script:DlHistFile ([ordered]@{ Items = @($m.Values | Sort-Object { [string]$_.At } -Descending | Select-Object -First 20000) })
}

function Clear-DlHistory { $script:DlHist = @{}; Remove-Item -LiteralPath $script:DlHistFile -Force -ErrorAction SilentlyContinue; Write-Log INFO 'Download history cleared' }

# ---- download hours, speed, space, a note when the queue is done -----------------------------
function Test-DownloadWindow {
    # Options > Download rules > "Only download between": '' = any time; '01:00-07:00' (may pass midnight)
    $w = [string](Get-AppSettings).DlWindow
    if ($w -notmatch '^\s*(\d{1,2}):(\d\d)\s*-\s*(\d{1,2}):(\d\d)\s*$') { return $true }
    $a = [int]$Matches[1] * 60 + [int]$Matches[2]; $b = [int]$Matches[3] * 60 + [int]$Matches[4]
    $n = (Get-Date).Hour * 60 + (Get-Date).Minute
    if ($a -eq $b) { return $true }
    if ($a -lt $b) { return ($n -ge $a -and $n -lt $b) }
    return ($n -ge $a -or $n -lt $b)
}

function Start-DownloadWindowWait {
    if ($script:DlWindowTimer) { return }
    $script:DlWindowTimer = New-Object System.Windows.Forms.Timer
    $script:DlWindowTimer.Interval = 60000
    $script:DlWindowTimer.Add_Tick({
        if (-not (Test-DownloadWindow)) { return }
        $script:DlWindowTimer.Stop(); $script:DlWindowTimer.Dispose(); $script:DlWindowTimer = $null
        Write-DownloadLog 'Download hours have started: continuing the queue'
        Step-DownloadQueue
    })
    $script:DlWindowTimer.Start()
}

function Test-DownloadSpace($Item, [string] $Dir, [double] $Seconds) {
    # enough room on the drive? (about 2 MB per second of TV, 0.3 MB of radio, and 1 GB to spare)
    try {
        $root = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Dir).Path)
        $free = (New-Object IO.DriveInfo($root)).AvailableFreeSpace
        $need = 1GB + [double]$Seconds * $(if ($Item.Kind -eq 'tv') { 2MB } else { 0.3MB })
        if ($free -ge $need) { return $true }
        $msg = 'Not enough disk space on {0}: {1:N1} GB free, about {2:N1} GB needed' -f $root, ($free / 1GB), ($need / 1GB)
        Write-DownloadLog "$msg - the queue is paused"
        $Item.Status = 'Paused'; $Item.Detail = 'not enough disk space'
        $script:DlPaused = $true
        Show-AppNotification 'Downloads paused' $msg 'Warning'
        return $false
    } catch { return $true }
}

function Show-AppNotification([string] $Title, [string] $Text, [string] $Icon = 'Info') {
    # a Windows notification (the tray icon's; a short-lived one when the tray icon is off)
    if (-not (Get-AppSettings).DlNotify) { return }
    try {
        $ni = if ($script:TrayUi -and $script:TrayUi.Icon.Visible) { $script:TrayUi.Icon } else { $null }
        if (-not $ni) {
            $ni = New-Object System.Windows.Forms.NotifyIcon
            $ni.Icon = if ($script:AppIconSmall) { $script:AppIconSmall } else { [System.Drawing.SystemIcons]::Application }
            $ni.Visible = $true
            $t = New-Object System.Windows.Forms.Timer; $t.Interval = 8000; $t.Tag = $ni
            $t.Add_Tick({ $this.Stop(); try { $this.Tag.Visible = $false; $this.Tag.Dispose() } catch { }; $this.Dispose() }); $t.Start()
        }
        $ni.ShowBalloonTip(6000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::$Icon)
    } catch { Write-Log DEBUG "Notification: $($_.Exception.Message)" }
}

# ---- whole series: only the newest N / only after a date (Options > Download rules) ---------------
function Select-SeriesFiles([object[]] $Files) {
    $st = Get-AppSettings
    $list = @($Files)
    $after = $null; if ([string]$st.DlSeriesAfter -match '^\d{4}-\d\d-\d\d$') { $after = [datetime]::ParseExact($st.DlSeriesAfter, 'yyyy-MM-dd', $null) }
    $dateOf = {
        param($f)
        if ($f.AvailableFrom) { try { return [datetime]::Parse([string]$f.AvailableFrom, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
        if ($f.Date -match '^(\d\d)\.(\d\d)\.(\d{4})$') { return [datetime]::new([int]$Matches[3], [int]$Matches[2], [int]$Matches[1]) }
        return $null
    }
    if ($after) { $list = @($list | Where-Object { $d = & $dateOf $_; -not $d -or $d -ge $after }) }
    $n = [int]$st.DlSeriesNewest
    if ($n -gt 0 -and $list.Count -gt $n) {
        $dated = @($list | Where-Object { & $dateOf $_ })
        $list = if ($dated.Count -eq $list.Count) { @($list | Sort-Object { & $dateOf $_ } -Descending | Select-Object -First $n) } else { @($list | Select-Object -Last $n) }   # (no dates: NRK's order, newest last)
    }
    return ,$list
}

# ---- Kodi / Jellyfin / Plex: .nfo files and pictures next to the video ------------------------
function ConvertTo-NfoText([string] $Text) { return [Security.SecurityElement]::Escape([string]$Text) }

function Save-WebFile([string] $Url, [string] $Path) {
    if (-not $Url -or (Test-Path -LiteralPath $Path)) { return }
    try {
        $rq = [System.Net.HttpWebRequest]::Create($Url); $rq.UserAgent = $script:UserAgent; $rq.Timeout = 15000
        $rs = $rq.GetResponse(); $fs = [IO.File]::Create($Path)
        try { $rs.GetResponseStream().CopyTo($fs) } finally { $fs.Close(); $rs.Close() }
    } catch { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Write-DownloadNfo($Plan, $Item) {
    $t = $Plan.Tags; $f = $Item.File
    $plot = ConvertTo-NfoText $t.description
    if ($f.Type -eq 'episode' -and $f.SeriesItem) {
        $x = "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?>`n<episodedetails>`n  <title>$(ConvertTo-NfoText $t.title)</title>`n  <showtitle>$(ConvertTo-NfoText $t.show)</showtitle>`n"
        if ($t.season_number) { $x += "  <season>$($t.season_number)</season>`n" }
        if ($t.episode_sort) { $x += "  <episode>$($t.episode_sort)</episode>`n" }
        if ($f.AvailableFrom) { $x += "  <aired>$(([string]$f.AvailableFrom).Substring(0, 10))</aired>`n" }
        $x += "  <plot>$plot</plot>`n  <uniqueid type=""nrk"" default=""true"">$(ConvertTo-NfoText $f.Id)</uniqueid>`n  <studio>NRK</studio>`n</episodedetails>`n"
        [IO.File]::WriteAllText("$($Plan.Base).nfo", $x, (New-Object Text.UTF8Encoding($false)))
        Save-WebFile $Plan.Poster "$($Plan.Base)-thumb.jpg"
        # the series: tvshow.nfo, poster and fanart in its folder (once)
        $showDir = Split-Path -Parent $Plan.Folder
        if ((Split-Path -Leaf $Plan.Folder) -notmatch '^(Season|Sesong) ') { $showDir = $Plan.Folder }
        $show = Join-Path $showDir 'tvshow.nfo'
        if (-not (Test-Path -LiteralPath $show)) {
            $sx = "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?>`n<tvshow>`n  <title>$(ConvertTo-NfoText $t.show)</title>`n  <plot>$(ConvertTo-NfoText $f.SeriesItem.Description)</plot>`n  <uniqueid type=""nrk"" default=""true"">$(ConvertTo-NfoText $f.SeriesItem.Id)</uniqueid>`n  <studio>NRK</studio>`n</tvshow>`n"
            [IO.File]::WriteAllText($show, $sx, (New-Object Text.UTF8Encoding($false)))
        }
        $img = $f.SeriesItem.ImageUrl; if (-not $img) { $img = $Plan.Poster }
        Save-WebFile $img (Join-Path $showDir 'poster.jpg'); Save-WebFile $img (Join-Path $showDir 'fanart.jpg')
    } else {
        $x = "<?xml version=""1.0"" encoding=""UTF-8"" standalone=""yes""?>`n<movie>`n  <title>$(ConvertTo-NfoText $t.title)</title>`n"
        if ($t.date) { $x += "  <year>$($t.date)</year>`n" }
        $x += "  <plot>$plot</plot>`n  <uniqueid type=""nrk"" default=""true"">$(ConvertTo-NfoText $f.Id)</uniqueid>`n  <studio>NRK</studio>`n</movie>`n"
        [IO.File]::WriteAllText("$($Plan.Base).nfo", $x, (New-Object Text.UTF8Encoding($false)))
        Save-WebFile $Plan.Poster "$($Plan.Base)-poster.jpg"; Save-WebFile $Plan.Poster "$($Plan.Base)-fanart.jpg"
    }
    Write-DownloadLog '   .nfo and pictures saved for Kodi / Jellyfin / Plex'
}

# ---- radio in pieces (pause/resume like TV), then one pass: format, tags, cover ----------------
function Wait-FinishProcess($Proc, [string] $OutFile) {
    # The finishing FFmpeg (subtitles, chapters, cover; radio format): no fixed time limit - a long
    # film on a slow disk may take a while - but stopped when its output has not grown for 3 minutes.
    # The window stays usable meanwhile; Exit, Cancel and the queue know a file is being finished
    # ($script:DlRun.Finishing) and Exit may stop it ($script:DlRun.FinishProc).
    $script:DlRun.FinishProc = $Proc
    try {
        $ui = [bool]('System.Windows.Forms.Application' -as [type])
        $lastLen = -1L; $still = [Diagnostics.Stopwatch]::StartNew()
        while (-not $Proc.HasExited) {
            if ($ui) { [System.Windows.Forms.Application]::DoEvents() }
            Start-Sleep -Milliseconds 50
            if ($still.Elapsed.TotalSeconds -ge 5) {
                $len = try { (New-Object IO.FileInfo($OutFile)).Length } catch { 0L }
                if ($len -ne $lastLen) { $lastLen = $len; $still.Restart() }
                elseif ($still.Elapsed.TotalSeconds -ge 180) { try { $Proc.Kill() } catch { }; throw 'FFmpeg stopped writing for 3 minutes' }
            }
        }
        if ($script:DlRun.FinishStop) { throw 'stopped (the app is closing)' }
    } finally { $script:DlRun.FinishProc = $null }
}

function Complete-RadioDownload($Plan, $Item) {
    $ff = (Find-FFmpeg).Path
    $work = Join-Path $script:AppDataDir 'dltmp'; New-Item -ItemType Directory -Path $work -Force | Out-Null
    $argv = @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-i', $Plan.Part)
    $cover = $null
    if ($Plan.Poster) { $cover = Join-Path $work "rcover.$PID.jpg"; Save-WebFile $Plan.Poster $cover; if (-not (Test-Path -LiteralPath $cover) -or (Get-Item -LiteralPath $cover).Length -lt 200) { $cover = $null } }
    if ($cover) { $argv += @('-i', $cover, '-map', '0:a:0', '-map', '1:0', '-c:v', $(if ($Plan.Ext -eq 'flac') { 'copy' } else { 'mjpeg' }), '-disposition:v:0', 'attached_pic') } else { $argv += @('-map', '0:a:0') }
    $argv += $Plan.Codec + $Plan.Meta
    if ($Plan.Ext -eq 'm4a') { $argv += @('-movflags', '+faststart') }
    $argv += $Plan.Out
    $ok = $false
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ff; $psi.Arguments = ConvertTo-ArgString $argv
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi); Add-ProcessToJob $p
        $err = $p.StandardError.ReadToEndAsync()
        Wait-FinishProcess $p ([string]$argv[-1])
        if ($p.ExitCode -ne 0) { throw ("ffmpeg exit {0}: {1}" -f $p.ExitCode, (($err.Result -split "`n" | Select-Object -First 3) -join ' ')) }
        Remove-Item -LiteralPath $Plan.Part -Force; $ok = $true
    } catch {
        Write-DownloadLog "   finishing failed ($($_.Exception.Message)): keeping the audio as .m4a"
        Remove-Item -LiteralPath $Plan.Out -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $Plan.Part -Destination "$($Plan.Base).m4a" -Force
    }
    if ($cover) { Remove-Item -LiteralPath $cover -Force -ErrorAction SilentlyContinue }
    return $(if ($ok) { $(if ($cover) { 'tags, cover' } else { 'tags' }) } else { '' })
}

# ---- update the tags and cover of a finished TV download ------------------------------------
function Update-DownloadTags([object[]] $Items) {
    $n = 0
    if ($script:DlRun.Finishing) { Write-DownloadLog 'Update tags: wait until the file being finished is done'; return }
    foreach ($it in @($Items | Where-Object { $_.Kind -eq 'tv' -and $_.Status -eq 'Done' })) {
        $file = @(Get-DownloadedFileSet $it | Where-Object { $_ -match '\.(mp4|mkv)$' }) | Select-Object -First 1
        if (-not $file) { Write-DownloadLog "Update tags: the file of $($it.Title) is not there"; continue }
        try {
            $it.Detail = 'Updating tags and cover'; Update-DownloadRow $it
            $plan = Get-TvDownloadPlan $it.File (Get-CurrentDownloadDir)
            $plan.Out = $file; $plan.Base = [IO.Path]::Combine([IO.Path]::GetDirectoryName($file), [IO.Path]::GetFileNameWithoutExtension($file)); $plan.Folder = [IO.Path]::GetDirectoryName($file)
            $plan.Part = "$($plan.Base).part$([IO.Path]::GetExtension($file))"
            Move-Item -LiteralPath $file -Destination $plan.Part -Force
            $script:DlRun.Finishing = $it
            try { $note = Complete-TvDownload $plan $it } finally { $script:DlRun.Finishing = $null }
            if ((Get-AppSettings).DlNfo) { try { Write-DownloadNfo $plan $it } catch { } }
            $it.Detail = if ($note) { "tags updated: $note" } else { 'tags updated' }; $n++
        } catch { Write-LogException $_ "Update tags $($it.Title)"; $it.Detail = "tags not updated: $($_.Exception.Message)" }
        Update-DownloadRow $it
    }
    if ($n) { Write-DownloadLog "Updated the tags and cover of $n file(s)" }
}

# ---- follow a series: new episodes download by themselves ----------------------------------
function Get-FollowFiles($Rec) {
    # every episode NRK has of a followed series / podcast now
    $it = ConvertFrom-FileRecord $Rec.Item
    $files = @()
    if ($Rec.Kind -eq 'radioseries') {
        $info = Get-NrkRadioSeriesInfo -Kind $it.Kind -Id $it.Id
        $title = if ($info.Title) { $info.Title } else { $it.Title }
        foreach ($sea in @($info.Seasons)) { $files += @(Get-NrkRadioEpisodes -Href $sea.Href -Kind $it.Kind -SeriesId $it.Id -SeriesTitle $title -Newest:$sea.Newest) }
    } else {
        $info = Get-NrkSeriesInfo -SeriesId $it.Id
        foreach ($sea in @($info.Seasons | Where-Object { $_.Name -ne 'ekstramateriale' })) {
            foreach ($ep in @(Get-NrkSeasonEpisodes -SeriesId $it.Id -Season $sea.Name)) { $files += New-EpisodeFile $ep $it $sea.Name }
        }
    }
    return ,@($files | Where-Object { $_ -and $_.Id })
}

function Set-FollowSeries([string] $Key, [bool] $On, [ValidateSet('download', 'notify')] [string] $Mode = 'download') {
    $m = Get-FavMap
    if (-not $m.Contains($Key)) { return }
    $r = $m[$Key]
    if ($On -and $Mode -eq 'notify') {
        # only tell: what NRK has now counts as seen; later ones give a notification (nothing is downloaded)
        $res = @{ Files = @() }
        Invoke-Ui "Reading the episodes of $($r.Item.Title)" { $res.Files = Get-FollowFiles $r }
        $r.Seen = @($res.Files | ForEach-Object { [string]$_.Id }); $r.Follow = $true
        $r | Add-Member -NotePropertyName FollowMode -NotePropertyValue 'notify' -Force
        Save-FavMap; Update-FavouritesNode
        Write-Log INFO "Follow (tell only): $($r.Item.Title)"
        Set-Status "Following $($r.Item.Title): you get a notification when new episodes come (nothing is downloaded)"
        return
    }
    if ($On) {
        $r | Add-Member -NotePropertyName FollowMode -NotePropertyValue 'download' -Force
        $res = @{ Files = @() }
        Invoke-Ui "Reading the episodes of $($r.Item.Title)" { $res.Files = Get-FollowFiles $r }
        $q = [System.Windows.Forms.MessageBox]::Show($form, ("Follow {0}: new episodes are downloaded by themselves.`n`nAlso download the {1} episode(s) NRK has now?" -f $r.Item.Title, $res.Files.Count), 'Follow', 'YesNoCancel', 'Question')
        if ($q -eq 'Cancel') { return }
        $r.Seen = if ($q -eq 'Yes') { @() } else { @($res.Files | ForEach-Object { [string]$_.Id }) }
        $r.Follow = $true
        Save-FavMap; Update-FavouritesNode
        Write-Log INFO "Follow: $($r.Item.Title) ($(if ($q -eq 'Yes') { 'with' } else { 'without' }) the existing episodes)"
        if ($q -eq 'Yes') { Invoke-FollowCheck -Only $Key }
    } else {
        $r.Follow = $false; Save-FavMap; Update-FavouritesNode
        Write-Log INFO "Follow: stopped for $($r.Item.Title)"
    }
}

function Invoke-FollowCheck([string] $Only = '', [switch] $Background) {
    # every followed series: episodes not seen before go to the download queue and start.
    # -Background (the 6-hourly check): the pages are fetched without the window waiting.
    $favs = @((Get-FavMap).Values | Where-Object { $_.Follow -and (-not $Only -or $_.Key -eq $Only) })
    if (-not $favs.Count) { return }
    if ($Background) {
        if ($script:FollowRun -and $script:FollowRun.Left -gt 0) { return }   # (still busy with the last one)
        $script:FollowRun = @{ Left = $favs.Count; Total = 0 }
        foreach ($r in $favs) {
            [void](Start-ApiJob "Follow $($r.Item.Title)" { param($rec) ,@(Get-FollowFiles $rec) } {
                param($files, $rec)
                $script:FollowRun.Total += (Add-FollowNew $rec @($files))
                Complete-FollowRun
            } { param($err, $rec) Write-LogException $err "Follow $($rec.Item.Title)"; Complete-FollowRun } $r)
        }
        return
    }
    $total = 0
    foreach ($r in $favs) {
        try { $total += (Add-FollowNew $r @(Get-FollowFiles $r)) } catch { Write-LogException $_ "Follow $($r.Item.Title)" }
    }
    Save-FavMap
    if ($total) { Show-AppNotification 'New episodes' ('{0} new episode(s) of followed series are downloading' -f $total) }
}

function Add-FollowNew($r, $files) {
    # the episodes of one followed series not seen before: into the queue, started; returns how many
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($x in @($r.Seen)) { [void]$seen.Add([string]$x) }
    $new = @($files | Where-Object { $_ -and -not $seen.Contains([string]$_.Id) -and (Test-FileAvailable $_) })
    $n = 0
    if ($new.Count -and [string]$r.FollowMode -eq 'notify') {
        Write-Log INFO "Follow (tell only): $($new.Count) new in $($r.Item.Title)"
        Show-AppNotification "New in $($r.Item.Title)" ('{0} new episode(s): {1}' -f $new.Count, (($new | Select-Object -First 3 | ForEach-Object { $_.Title }) -join ', '))
    } elseif ($new.Count) {
        Write-Log INFO "Follow: $($new.Count) new in $($r.Item.Title)"
        $added = Add-ToDownloadQueue -Files $new -Quiet
        $go = @($added | Where-Object { $_.Status -eq 'Added' })
        if ($go.Count) { Start-DownloadQueue -Items $go; $n = $go.Count }
    }
    $r.Seen = @($files | Where-Object { $_ } | ForEach-Object { [string]$_.Id }); $r.LastCheck = (Get-Date).ToString('o')
    return $n
}

function Complete-FollowRun {
    $f = $script:FollowRun
    $f.Left--
    if ($f.Left -gt 0) { return }
    Save-FavMap
    if ($f.Total) { Show-AppNotification 'New episodes' ('{0} new episode(s) of followed series are downloading' -f $f.Total) }
}

function Start-FollowTimer {
    # 2 minutes after start, then every 6 hours
    if ($script:FollowTimer) { return }
    $script:FollowTimer = New-Object System.Windows.Forms.Timer
    $script:FollowTimer.Interval = 120000
    $script:FollowTimer.Add_Tick({ $script:FollowTimer.Interval = 6 * 3600000; try { Invoke-FollowCheck -Background } catch { Write-LogException $_ 'Follow' } })
    $script:FollowTimer.Start()
}

# ---- podcasts: NRK's own feed address (for podcast apps) -------------------------------------
function Get-PodcastFeedUrl($Item) { if ($Item -and $Item.Kind -eq 'podcast' -and $Item.Id) { return 'https://podkast.nrk.no/program/{0}.rss' -f $Item.Id } else { return $null } }

# ---- thumbnail grid for the files list (Options > General, right-click, Ctrl+G) --------------
if (-not ('NrkGrid' -as [type])) {
    try { Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class NrkGrid { [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l); public static void Spacing(IntPtr h, int cx, int cy) { SendMessage(h, 0x1000 + 53, IntPtr.Zero, (IntPtr)((cy << 16) | (cx & 0xFFFF))); } }' -ErrorAction Stop } catch { }
}
$script:GridW = 224; $script:GridImgH = 126; $script:GridH = 196
$script:GridIL = New-Object System.Windows.Forms.ImageList
$script:GridIL.ImageSize = New-Object System.Drawing.Size(220, 150)
$script:Thumbs = @{}           # url -> picture, cut to the tile (16:9)
$script:ThumbLoads = @{}       # url -> download running in the background

function Test-GridView { return ([string](Get-AppSettings).FilesView -eq 'grid') }

function Set-FilesView([ValidateSet('list', 'grid')] [string] $View) {
    $s = Get-AppSettings; if ($s.FilesView -ne $View) { $s.FilesView = $View; Save-AppSettings $s; Write-Log INFO "Option FilesView = $View" }
    Show-Files
}

function Initialize-GridView([bool] $On) {
    # switches the files list between rows and tiles
    if ($On) {
        if ($itemsList.View -ne 'LargeIcon') {
            $itemsList.View = 'LargeIcon'; $itemsList.LargeImageList = $script:GridIL
            try { [NrkGrid]::Spacing($itemsList.Handle, $script:GridW, $script:GridH) } catch { }
        }
    } elseif ($itemsList.View -ne 'Details') { $itemsList.View = 'Details' }
}

function Get-GridThumb([string] $Url) {
    # the tile picture: from memory, else from the disk cache, else fetched in the background (drawn when it arrives)
    if (-not $Url) { return $null }
    if ($script:Thumbs.ContainsKey($Url)) { return $script:Thumbs[$Url] }
    $file = Get-CacheFile $Url 'img' '.img'
    if (Test-Path -LiteralPath $file) {
        try {
            $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($file)); $src = [System.Drawing.Image]::FromStream($ms)
            $bmp = New-Object System.Drawing.Bitmap($script:GridW - 4, $script:GridImgH)
            $g = [System.Drawing.Graphics]::FromImage($bmp); $g.InterpolationMode = 'HighQualityBicubic'
            # cover: fill the 16:9 tile, cut what sticks out (centre)
            $tw = $bmp.Width; $th = $bmp.Height; $sc = [Math]::Max($tw / $src.Width, $th / $src.Height)
            $dw = $src.Width * $sc; $dh = $src.Height * $sc
            $g.DrawImage($src, [float](($tw - $dw) / 2), [float](($th - $dh) / 2), [float]$dw, [float]$dh)
            $g.Dispose(); $src.Dispose(); $ms.Dispose()
            if ($script:Thumbs.Count -gt 400) { foreach ($k in @($script:Thumbs.Keys | Select-Object -First 100)) { try { $script:Thumbs[$k].Dispose() } catch { }; $script:Thumbs.Remove($k) } }
            $script:Thumbs[$Url] = $bmp
            return $bmp
        } catch { $script:Thumbs[$Url] = $null; return $null }
    }
    if (-not $script:ThumbLoads.ContainsKey($Url) -and $script:ThumbLoads.Count -lt 6) {
        try {
            $wc = New-Object System.Net.WebClient; $wc.Headers['User-Agent'] = $script:UserAgent
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            $script:ThumbLoads[$Url] = @{ Client = $wc; Task = $wc.DownloadFileTaskAsync([Uri]$Url, "$file.part"); File = $file }
            if (-not $script:ThumbTimer) {
                $script:ThumbTimer = New-Object System.Windows.Forms.Timer; $script:ThumbTimer.Interval = 150
                $script:ThumbTimer.Add_Tick({
                    $any = $false
                    foreach ($u in @($script:ThumbLoads.Keys)) {
                        $j = $script:ThumbLoads[$u]
                        if (-not $j.Task.IsCompleted) { continue }
                        $script:ThumbLoads.Remove($u); try { $j.Client.Dispose() } catch { }
                        if (-not $j.Task.IsFaulted -and (Test-Path -LiteralPath "$($j.File).part")) { try { Move-Item -LiteralPath "$($j.File).part" -Destination $j.File -Force } catch { } } else { $script:Thumbs[$u] = $null }
                        $any = $true
                    }
                    if ($any) { $itemsList.Invalidate() }
                    if (-not $script:ThumbLoads.Count) { $script:ThumbTimer.Stop() }
                })
            }
            $script:ThumbTimer.Start()
        } catch { }
    }
    return $null
}

$script:SmallPlaceholders = @{}
function Get-SmallPlaceholder([string] $Kind, [int] $W, [int] $H) {
    # the 960x540 placeholder scaled once to the tile size (drawing the big one for every tile is slow)
    $key = "$Kind|$($script:ThemeEffective)|$W|$H"
    if ($script:SmallPlaceholders[$key]) { return $script:SmallPlaceholders[$key] }
    $big = Get-PlaceholderImage $Kind
    if (-not $big) { return $null }
    $sm = New-ScaledImage $big $W $H
    $script:SmallPlaceholders[$key] = $sm
    return $sm
}

function Invoke-DrawGridItem($E) {
    $item = $E.Item; $f = $item.Tag; $g = $E.Graphics
    $r = $E.Bounds
    $box = New-Object System.Drawing.Rectangle(($r.X + 2), ($r.Y + 2), ($script:GridW - 4), ($script:GridH - 8))
    $g.FillRectangle((Get-Brush $(if ($item.Selected) { $T.Sel } else { $itemsList.BackColor })), $box)
    $img = New-Object System.Drawing.Rectangle($box.X, $box.Y, $box.Width, $script:GridImgH)
    $url = if ($f -and $f.PSObject) { if ($f.Medium -eq 'radio' -and $f.SquareUrl -and $f.Type -ne 'radiolive') { [string]$f.SquareUrl } elseif ($f.ImageUrl) { [string]$f.ImageUrl } elseif ($f.SeriesItem -and $f.SeriesItem.ImageUrl) { [string]$f.SeriesItem.ImageUrl } else { '' } } else { '' }
    $th = Get-GridThumb $url
    if ($th) { $g.DrawImage($th, $img.X, $img.Y, $img.Width, $img.Height) }
    else {
        $ph = try { Get-SmallPlaceholder $(if ($f.Medium -eq 'radio') { 'radio' } else { 'tv' }) $img.Width $img.Height } catch { $null }
        if ($ph) { $g.DrawImageUnscaled($ph, $img.X, $img.Y) } else { $g.FillRectangle((Get-Brush $T.Surface), $img) }
    }
    if ($item.Selected) { $pen = New-Object System.Drawing.Pen($T.Accent, 2); $g.DrawRectangle($pen, ($img.X + 1), ($img.Y + 1), ($img.Width - 2), ($img.Height - 2)); $pen.Dispose() }
    # how far you got / watched
    $rec = if (Test-PosFile $f) { (Get-PosMap)[(Get-FileKey $f)] } else { $null }
    if ($rec) {
        $yb = $img.Bottom - 4
        if ($rec.Done) { $g.FillRectangle((Get-Brush $T.Ok), $img.X, $yb, $img.Width, 4) }
        elseif ([double]$rec.Dur -gt 0 -and [double]$rec.Pos -ge 15) { $g.FillRectangle((Get-Brush $T.Border), $img.X, $yb, $img.Width, 4); $g.FillRectangle((Get-Brush $T.Accent), $img.X, $yb, [int]($img.Width * [Math]::Min(1, [double]$rec.Pos / [double]$rec.Dur)), 4) }
    }
    $fore = if ($item.ForeColor -eq $T.Muted) { $T.Muted } else { $T.Text }
    $t1 = New-Object System.Drawing.Rectangle(($box.X + 4), ($img.Bottom + 4), ($box.Width - 8), 36)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $item.Text, $script:FontUi, $t1, $fore, [System.Windows.Forms.TextFormatFlags]'Left, Top, WordBreak, EndEllipsis, NoPrefix')
    $sec = if ($item.SubItems.Count -gt 1) { $item.SubItems[1].Text } else { '' }
    if ($sec) {
        $t2 = New-Object System.Drawing.Rectangle(($box.X + 4), ($box.Bottom - 18), ($box.Width - 8), 16)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $sec, $script:FontSmall, $t2, $T.Muted, [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, SingleLine, NoPrefix')
    }
}

# ---- child mode: only NRK Super, nothing above the chosen age, leaving it needs a PIN -------
$script:AgeCache = @{}
$script:AgeOrder = @('A', '6', '9', '12', '15', '18')

function Test-ChildMode { return [bool](Get-AppSettings).ChildMode }

function Test-ChildFolder($Item) { return ([string]$Item.Id -match 'barn|super|nrksuper' -or [string]$Item.Title -match '^(Barn|NRK Super|Super)\b|Radio ?Super') }

function Get-AgeRating($File) {
    # NRK's age rating (A = for everyone, 6, 9, 12, 15, 18) from the player data; cached per programme
    $k = Get-FileKey $File
    if ($script:AgeCache.ContainsKey($k)) { return $script:AgeCache[$k] }
    $path = switch ($File.Type) {
        { $_ -in 'episode', 'program' } { '/playback/metadata/program/{0}' -f [uri]::EscapeDataString($File.Id) }
        'live' { '/playback/metadata/channel/{0}' -f [uri]::EscapeDataString($File.Id) }
        { $_ -in 'audio', 'radiolive' } { [string]$File.ManifestPath -replace '^/playback/manifest/', '/playback/metadata/' }
        default { $null }
    }
    $age = ''
    if ($path) {
        try {
            $md = Invoke-NrkApi $path
            $body = Get-Prop (Get-Prop $md 'legalAge') 'body'
            $age = if ([string](Get-Prop $body 'status') -eq 'exempt') { 'A' } else { [string](Get-Prop (Get-Prop $body 'rating') 'displayAge') }
        } catch { }
    }
    $script:AgeCache[$k] = $age
    return $age
}

function Test-ChildAllowed($File, [switch] $Quiet) {
    # $true when it may be played; child mode: only up to the chosen age (unknown = not allowed)
    # -Quiet: no message (filtering a list)
    if (-not (Test-ChildMode) -or -not $File) { return $true }
    $max = [string](Get-AppSettings).ChildMaxAge
    $age = Get-AgeRating $File
    $ok = ($age -and [array]::IndexOf($script:AgeOrder, $age) -ge 0 -and [array]::IndexOf($script:AgeOrder, $age) -le [Math]::Max(0, [array]::IndexOf($script:AgeOrder, $max)))
    if (-not $ok -and -not $Quiet) {
        Write-Log INFO "Child mode: $($File.Title) blocked (age $(if ($age) { $age } else { 'unknown' }), allowed up to $max)"
        [void][System.Windows.Forms.MessageBox]::Show($form, ("{0}`n`nNot in child mode: {1}." -f $File.Title, $(if ($age) { "rated $age" } else { 'NRK gives no age rating for it' })), 'Child mode', 'OK', 'Information')
    }
    return $ok
}

function Get-PinHash([string] $Pin) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("nrkb|$Pin"))) -replace '-', '') } finally { $sha.Dispose() }
}

function Read-Pin([string] $Title, [string] $Text) {
    $w = New-Object System.Windows.Forms.Form
    $w.Text = $Title; $w.ClientSize = New-Object System.Drawing.Size(360, 150); $w.FormBorderStyle = 'FixedDialog'; $w.MaximizeBox = $false; $w.MinimizeBox = $false
    $w.StartPosition = 'CenterParent'; $w.BackColor = $T.Bg; $w.ForeColor = $T.Text; $w.Font = $script:FontUi
    $l = New-Object System.Windows.Forms.Label; $l.Text = $Text; $l.Location = New-Object System.Drawing.Point(16, 14); $l.Size = New-Object System.Drawing.Size(330, 40)
    $tb = New-Object System.Windows.Forms.TextBox; $tb.UseSystemPasswordChar = $true; $tb.Location = New-Object System.Drawing.Point(16, 60); $tb.Width = 200; $tb.MaxLength = 12
    $tb.BackColor = $T.Surface; $tb.ForeColor = $T.Text
    $ok = New-FlatButton 'OK' 90 -Primary; $ok.Location = New-Object System.Drawing.Point(160, 104); $ok.DialogResult = 'OK'
    $cancel = New-FlatButton 'Cancel' 90; $cancel.Location = New-Object System.Drawing.Point(256, 104); $cancel.DialogResult = 'Cancel'
    $w.Controls.AddRange(@($l, $tb, $ok, $cancel)); $w.AcceptButton = $ok; $w.CancelButton = $cancel
    Enable-DarkTitleBar $w
    $r = $w.ShowDialog($form); $pin = $tb.Text; $w.Dispose()
    if ($r -ne 'OK') { return $null }
    return $pin
}

function Set-ChildMode([bool] $On) {
    $s = Get-AppSettings
    if ($On) {
        $pin = Read-Pin 'Child mode' 'Choose a PIN (4 digits or more). It is needed to leave child mode.'
        if ($null -eq $pin) { return $false }
        if ($pin.Length -lt 4) { [void][System.Windows.Forms.MessageBox]::Show($form, 'The PIN needs at least 4 characters.', 'Child mode', 'OK', 'Information'); return $false }
        $s.ChildPin = Get-PinHash $pin; $s.ChildMode = $true
    } else {
        $pin = Read-Pin 'Child mode' 'The PIN to leave child mode:'
        if ($null -eq $pin) { return $false }
        if ((Get-PinHash $pin) -ne [string]$s.ChildPin) { Write-Log WARN 'Child mode: wrong PIN'; [void][System.Windows.Forms.MessageBox]::Show($form, 'Wrong PIN.', 'Child mode', 'OK', 'Warning'); return $false }
        $s.ChildMode = $false
    }
    Save-AppSettings $s
    Write-Log INFO "Child mode: $(if ($On) { 'on' } else { 'off' })"
    $form.Text = "NRK Browser $($script:AppVersion)$(if ($On) { '  ·  Child mode' })"
    $btnReload.PerformClick()   # the folders again, with or without the grown-up parts
    return $true
}

# ---- cleanup on any exit ---------------------------------------------------------------
# Download tools run inside a Windows job object that is closed when this process ends, so
# ffmpeg never keeps running on its own: not after Exit, an update, Windows
# shutting down, Task Manager or a crash. The download in progress is written down in
# download-running.json; if the app did not get to clean up, the next start removes that
# download's unfinished files.
if (-not ('NrkJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NrkJob {
    [StructLayout(LayoutKind.Sequential)] struct BASIC { public long a, b; public uint LimitFlags; public UIntPtr c, d; public uint e; public UIntPtr f; public uint g, h; }
    [StructLayout(LayoutKind.Sequential)] struct IOC { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)] struct EXT { public BASIC Basic; public IOC Io; public UIntPtr p, j, pp, jp; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int cls, ref EXT info, uint len);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    static IntPtr handle = IntPtr.Zero;
    // the job lives as long as this process: when it ends, Windows ends every process in it
    public static bool Add(IntPtr process) {
        if (handle == IntPtr.Zero) {
            IntPtr h = CreateJobObject(IntPtr.Zero, null);
            if (h == IntPtr.Zero) return false;
            EXT info = new EXT(); info.Basic.LimitFlags = 0x2000;   // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(h, 9, ref info, (uint)Marshal.SizeOf(typeof(EXT)))) return false;
            handle = h;
        }
        return AssignProcessToJobObject(handle, process);
    }
}
'@ -ErrorAction SilentlyContinue
}
$script:DlRunningFile = Join-Path $script:AppDataDir 'download-running.json'

function Add-ProcessToJob($Process) {
    try { if (-not [NrkJob]::Add($Process.Handle)) { Write-Log WARN "Could not tie $($Process.ProcessName) to the app (it may outlive a crash)" } }
    catch { Write-Log DEBUG "Job object: $($_.Exception.Message)" }
}

function Set-DownloadRunning($Item, [string] $Dir) {
    if (-not $Item) { Remove-Item -LiteralPath $script:DlRunningFile -Force -ErrorAction SilentlyContinue; return }
    Write-JsonFile $script:DlRunningFile ([ordered]@{ Title = $Item.Title; Dir = $Dir; Started = (Get-Date).AddSeconds(-2).ToString('o'); Pid = $PID })
}

function Clear-UnfinishedDownload {
    # at startup: the last run ended while downloading, without its cleanup
    $r = Read-JsonFile $script:DlRunningFile
    if (-not $r) { return }
    $alive = $false
    try { $p = Get-Process -Id ([int]$r.Pid) -ErrorAction Stop; $alive = ($p.ProcessName -match 'powershell|pwsh') -and $r.Pid -ne $PID } catch { }
    if ($alive) { return }   # (another copy is still downloading)
    $since = [datetime]$r.Started
    $n = 0
    if ($r.Dir -and (Test-Path -LiteralPath $r.Dir)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $r.Dir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            if ($f.CreationTime -ge $since -and $f.Extension -match '^\.(m4v|mp4|mkv|m4a|mp3|flac|aac|ts|nfo|srt|vtt|jpg|jpeg|png|part|tmp|ytdl)$') {
                try { Remove-Item -LiteralPath $f.FullName -Force; $n++; Write-Log INFO "Removed unfinished download file: $($f.FullName)" } catch { }
            }
        }
        foreach ($d in @(Get-ChildItem -LiteralPath $r.Dir -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
            if ($d.CreationTime -ge $since -and -not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)) { try { Remove-Item -LiteralPath $d.FullName -Force } catch { } }
        }
    }
    Write-Log WARN ("The last session ended during the download of '{0}': removed {1} unfinished file(s)" -f $r.Title, $n)
    $script:StartupNote = "The last session ended during a download: the unfinished files of '$($r.Title)' were removed"
    Remove-Item -LiteralPath $script:DlRunningFile -Force -ErrorAction SilentlyContinue
}

function Clear-Leftovers {
    # temporary files a killed process could leave behind
    $old = (Get-Date).AddHours(-1)
    foreach ($d in @((Join-Path $script:AppDataDir 'cache'), $script:IndexDir, $script:AppDataDir)) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $rec = ($d -ne $script:AppDataDir)
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.tmp' -File -Recurse:$rec -ErrorAction SilentlyContinue)) {
            if ($f.LastWriteTime -lt $old) { try { Remove-Item -LiteralPath $f.FullName -Force } catch { } }
        }
    }
    # update work folders in %TEMP% (the helper deletes its own; a crash may not)
    foreach ($d in @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'NRK-Browser-update-*' -ErrorAction SilentlyContinue)) {
        if ($d.LastWriteTime -lt (Get-Date).AddDays(-1)) { try { Remove-Item -LiteralPath $d.FullName -Recurse -Force } catch { } }
    }
}

$script:DlRun = @{ Finishing = $null; FinishProc = $null; FinishStop = $false; Item = $null; Proc = $null; Out = $null; Err = $null; OutTask = $null; ErrTask = $null; Before = $null
                   Cancel = $null; Timer = $null; Py = $null; Duration = 0 }

function Get-SafeFileName([string] $Name) {
    $n = ($Name -replace '[\\/:*?"<>|\x00-\x1f]', '_').Trim(' ', '.')
    if ($n.Length -gt 120) { $n = $n.Substring(0, 120).Trim(' ', '.') }
    if (-not $n) { $n = 'NRK' }
    return $n
}

function ConvertTo-ArgString([string[]] $Arguments) {
    # Windows command-line quoting (CommandLineToArgvW rules)
    ($Arguments | ForEach-Object {
        if ($_ -match '^[\w\-\.:/=\\]+$' -and $_ -notmatch '\\$') { $_ }
        else { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }) -join ' '
}

function Get-DownloadDir([switch] $Radio) {
    # TV: Videos\NRK-Browser, radio: Music\NRK-Browser, unless the user chose another folder
    # ('' when Windows has no Videos/Music folder: the user is asked to choose one)
    $st = Get-AppSettings
    if ($Radio) {
        if ($st.RadioDownloadDir) { return [string]$st.RadioDownloadDir }
        $base = [Environment]::GetFolderPath('MyMusic')
    } else {
        $old = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\NRK'   # the default before 2.6.8: not a choice
        if ($st.DownloadDir -and $st.DownloadDir -ne $old) { return [string]$st.DownloadDir }
        $base = [Environment]::GetFolderPath('MyVideos')
    }
    if (-not $base) { return '' }
    return (Join-Path $base 'NRK-Browser')
}

function Get-CurrentDownloadDir([switch] $Radio) {
    # what the Downloads window shows (it may have been edited), else the setting
    return (Get-DownloadDir -Radio:$Radio)
}

function Set-DownloadDirSetting([string] $Dir, [switch] $Radio) {
    $key = if ($Radio) { 'RadioDownloadDir' } else { 'DownloadDir' }
    $st = Get-AppSettings
    if ($st.$key -eq $Dir) { return }
    if (-not $st.$key -and $Dir -eq (Get-DownloadDir -Radio:$Radio)) { return }   # the default: nothing to save
    $st.$key = $Dir; Save-AppSettings $st; Write-Log INFO "Option $key = $Dir"
}

function Resolve-DownloadFolder([switch] $Radio, $Owner) {
    # the TV or radio download folder, ready to use. If it is gone (removed, renamed, a drive that is not
    # connected, no Videos/Music folder) the user is asked to choose one; $null when they cancel.
    $what = if ($Radio) { 'radio' } else { 'TV' }
    $d = Get-CurrentDownloadDir -Radio:$Radio
    if ($d) {
        if (Test-Path -LiteralPath $d -PathType Container) { return $d }
        $parent = Split-Path -Parent $d
        if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
            # (only our own NRK-Browser folder is missing: made here)
            try { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null; return $d } catch { }
        }
    }
    if (-not $Owner) { $Owner = $form }
    $msg = if ($d) { "The $what download folder is not available:`n$d`n`nIt may have been removed, renamed or be on a drive that is not connected. Choose a folder for $what downloads." }
           else { "Windows has no $(if ($Radio) { 'Music' } else { 'Videos' }) folder here. Choose a folder for $what downloads." }
    if ([System.Windows.Forms.MessageBox]::Show($Owner, $msg, 'Download folder', 'OKCancel', 'Warning') -ne 'OK') { return $null }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Choose where $what downloads are saved"
    if ($dlg.ShowDialog($Owner) -ne 'OK') { return $null }
    $d = $dlg.SelectedPath
    Set-DownloadDirSetting $d -Radio:$Radio
    if ($script:OptUi -and -not $script:OptUi.Form.IsDisposed) { if ($Radio) { $script:OptUi.RadioDir.Text = $d } else { $script:OptUi.DlDir.Text = $d } }
    return $d
}

function Write-DownloadLog([string] $Text) {
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Text
    Write-Log 'DL' $Text
    [void]$script:DlLogBuffer.AppendLine($line)
    if ($script:DlLogBuffer.Length -gt 600000) { [void]$script:DlLogBuffer.Remove(0, 200000) }
    $ui = $script:DlUi
    if ($ui -and -not $ui.Form.IsDisposed) {
        if ($ui.Log.TextLength -gt 500000) { $ui.Log.Text = $script:DlLogBuffer.ToString() }
        else { $ui.Log.AppendText($line + "`r`n") }
    }
}

function Get-DownloadStatusText($Item) {
    switch ($Item.Status) {
        'Added'       { 'Not started' }
        'Pending'     { 'Waiting' }
        'Downloading' { if ($Item.Detail) { $Item.Detail } else { 'Downloading' } }
        'Done'        { if ($Item.Detail) { "Done - $($Item.Detail)" } else { 'Done' } }
        'Failed'      { if ($Item.Detail) { "Failed - $($Item.Detail)" } else { 'Failed' } }
        'Canceled'    { if ($Item.Detail) { "Canceled - $($Item.Detail)" } else { 'Canceled' } }
        'Paused'      { if ($Item.Detail) { "Paused - $($Item.Detail)" } else { 'Paused' } }
        default       { [string]$Item.Status }
    }
}

# ---- building queue items from files and folders

function New-DownloadItem($File) {
    $kind = $null; $url = $null; $title = $File.Title
    switch ($File.Type) {
        'program' { $kind = 'tv'; $url = $File.WebUrl }
        'episode' { $kind = 'tv'; $url = $File.WebUrl; $title = '{0}  ·  {1}' -f $File.SeriesItem.Title, $File.Title }
        'audio'   { $kind = 'radio'; $url = $File.ManifestPath; if ($File.SeriesTitle) { $title = '{0}  ·  {1}' -f $File.SeriesTitle, $File.Title } }
        default   { return $null }
    }
    if (-not $url) { return $null }
    $script:DlNextId++
    return @{ Id = $script:DlNextId; Title = $title; Kind = $kind; Url = $url; File = $File; Status = 'Added'; Progress = -1
              Detail = ''; Files = @(); Dirs = @(); Row = $null; LastLogged = -10 }
}

function Get-NodeFiles {
    # Every downloadable file under a folder (loads seasons/episodes as needed).
    param([System.Windows.Forms.TreeNode] $Node)
    $tag = $Node.Tag
    switch ($tag.Kind) {
        'season' {
            $eps = @(Get-Cached "eps:$($tag.Item.Id):$($tag.Season)" { Get-NrkSeasonEpisodes -SeriesId $tag.Item.Id -Season $tag.Season })
            foreach ($ep in $eps) { New-EpisodeFile $ep $tag.Item $tag.Season }
        }
        'series' {
            if (Expand-FolderNode $Node) {
                # NRK's order (season 1 first), not the sort order of the tree
                foreach ($c in @($Node.Nodes | Sort-Object { [int]$_.Tag.Order })) { if ($c.Tag.Kind -eq 'season' -and $c.Tag.Season -ne 'ekstramateriale') { Get-NodeFiles $c } }
            }
        }
        'radioseason' {
            $sea = $tag.Season
            $title = if ($tag.Info.Title) { $tag.Info.Title } else { $tag.Item.Title }
            @(Get-Cached "reps:$($sea.Href)" { Get-NrkRadioEpisodes -Href $sea.Href -Kind $tag.Item.Kind -SeriesId $tag.Item.Id -SeriesTitle $title -Newest:$sea.Newest })
        }
        'radioseries' {
            if (Expand-FolderNode $Node) { foreach ($c in @($Node.Nodes | Sort-Object { [int]$_.Tag.Order })) { if ($c.Tag.Kind -eq 'radioseason') { Get-NodeFiles $c } } }
        }
        'search' { @($tag.Items | Where-Object { $_.Downloadable }) }
        'recent' { @(Get-RecentFiles | Where-Object { $_.Downloadable }) }
        'continue' { @(Get-ContinueFiles | Where-Object { $_.Downloadable }) }
        'watchlater' { @(Get-WatchLaterFiles | Where-Object { $_.Downloadable }) }
        { $_ -in 'newweek', 'expiring' } { @(@(Get-DatedFiles $tag.Kind.Replace('newweek', 'new')) | Where-Object { $_ -and $_.Downloadable }) }
        { $_ -in 'category', 'letter', 'radiocategory', 'radioletter' } {
            # the programmes/recordings listed in the folder (not every series inside it)
            if (Expand-FolderNode $Node) { @($tag.Items | Where-Object { $_.Type -in 'program', 'audio' }) }
        }
    }
}

function Test-NodeDownloadable($Node) {
    return [bool]($Node -and $Node.Tag -and $Node.Tag.Kind -in 'season', 'series', 'radioseason', 'radioseries', 'category', 'letter', 'radiocategory', 'radioletter', 'search', 'recent', 'newweek', 'expiring', 'continue', 'watchlater')
}

function Add-ToDownloadQueue {
    # -Quiet (followed series): no windows or questions; returns the items it added
    param([object[]] $Files = @(), [object[]] $Nodes = @(), [switch] $Quiet)
    $res = @{ Files = New-Object System.Collections.ArrayList }
    Invoke-Ui 'Collecting files to download' {
        foreach ($f in $Files) { if ($f) { [void]$res.Files.Add($f) } }
        foreach ($n in $Nodes) {
            if (-not (Test-NodeDownloadable $n)) { continue }
            Set-Status "Collecting files in $($n.Text)..."
            $nf = @(Get-NodeFiles $n | Where-Object { $_ })
            # a whole series or season: Options > Download rules > only the newest N / only after a date
            if ($n.Tag.Kind -in 'series', 'season', 'radioseries', 'radioseason') { $nf = Select-SeriesFiles $nf }
            foreach ($f in $nf) { [void]$res.Files.Add($f) }
        }
    }
    $new = New-Object System.Collections.ArrayList
    $skipped = 0; $dupes = 0
    $active = @{}
    foreach ($q in $script:DlQueue) { if ($q.Status -in 'Added', 'Pending', 'Downloading') { $active[$q.Url] = $true } }
    $dlDir = Get-CurrentDownloadDir
    $already = 0
    $inList = @{}; foreach ($q in $script:DlQueue) { $inList[$q.Url] = $true }
    foreach ($f in $res.Files) {
        if (-not (Test-FileAvailable $f)) { $skipped++; continue }
        # already in the download folder: back in the list as done (100 %), nothing to download
        $have = Find-ExistingDownload $f $dlDir
        if ($have) {
            $it = New-DownloadItem $f
            if ($it -and -not $inList.ContainsKey($it.Url)) {
                $it.Status = 'Done'; $it.Progress = 100; $it.Detail = 'already downloaded'; $it.Files = @($have)
                $inList[$it.Url] = $true
                [void]$new.Add($it)
            }
            $already++
            continue
        }
        # downloaded before (and moved or deleted since): listed as done, not fetched again (Options > Download rules)
        if ((Get-AppSettings).DlSkipHistory -and (Get-DlHistory).ContainsKey((Get-FileKey $f))) {
            $it = New-DownloadItem $f
            if ($it -and -not $inList.ContainsKey($it.Url)) { $it.Status = 'Done'; $it.Progress = 100; $it.Detail = 'downloaded before (right-click > Download again)'; $inList[$it.Url] = $true; [void]$new.Add($it) }
            $already++
            continue
        }
        if ($Nodes.Count -and (Test-Excluded (Get-FileKey $f))) { $skipped++; continue }   # hidden episodes stay out of folder downloads
        $it = New-DownloadItem $f
        if (-not $it) { $skipped++; continue }
        if ($active.ContainsKey($it.Url)) { $dupes++; continue }
        $active[$it.Url] = $true
        [void]$new.Add($it)
    }
    if ($already) { Write-DownloadLog ("{0} file(s) are already in {1}: listed as done, nothing to download" -f $already, $dlDir) }
    if ($Quiet) {
        foreach ($it in $new) { [void]$script:DlQueue.Add($it) }
        if ($new.Count) { Request-QueueSave; Update-DownloadList }
        return ,@($new)
    }
    if ($new.Count -eq 0) {
        # (files that are already downloaded and already listed: nothing to say)
        if ($already -and -not $dupes -and -not $skipped) { Show-DownloadsWindow; Set-Status "$already file(s) are already downloaded"; return }
        $msg = 'Nothing to add to the download queue.'
        if ($dupes) { $msg += " $dupes file(s) are already in the queue." }
        if ($skipped) { $msg += " $skipped item(s) can't be downloaded (live channels, unavailable episodes)." }
        Set-Status $msg
        if ($dupes) { Show-DownloadsWindow }
        else { [void][System.Windows.Forms.MessageBox]::Show($form, $msg, 'Download', 'OK', 'Information') }
        return
    }
    $toGet = @($new | Where-Object { $_.Status -ne 'Done' }).Count
    if ($toGet -gt 40) {
        $q = [System.Windows.Forms.MessageBox]::Show($form, ("Add {0} files to the download queue?" -f $toGet), 'Download', 'YesNo', 'Question')
        if ($q -ne 'Yes') { return }
    }
    foreach ($it in $new) { [void]$script:DlQueue.Add($it) }
    Request-QueueSave
    $note = (@($(if ($dupes) { "$dupes already queued" }), $(if ($already) { "$already already downloaded" }), $(if ($skipped) { "$skipped skipped" })) | Where-Object { $_ }) -join ', '
    if ($toGet) { Write-DownloadLog ("Added {0} file(s) to the queue{1}. Select them (or Select all) and press 'Download selected' to start." -f $toGet, $(if ($note) { " ($note)" } else { '' })) }
    foreach ($it in $new) { Write-Log INFO "Download queue: + $($it.Title)  [$($it.Url)]" }
    Show-DownloadsWindow
    Update-DownloadList -Select @($new | ForEach-Object { $_.Id })
    Set-Status $(if ($toGet) { '{0} file(s) added to the download queue' -f $toGet } else { '{0} file(s) are already downloaded' -f $already })
}

# ---- queue list (owner-drawn, several columns, progress bars)

function Invoke-DrawQueueCell {
    param($List, $E)
    $g = $E.Graphics; $it = $E.Item.Tag; $col = $E.ColumnIndex
    $b = $E.Bounds
    if ($col -eq 0) { $b = New-Object System.Drawing.Rectangle($b.X, $b.Y, $List.Columns[0].Width, $b.Height) }
    $sel = $E.Item.Selected
    $g.FillRectangle((Get-Brush $(if ($sel) { $T.Sel } else { $List.BackColor })), $b)
    if ($col -eq 0 -and $sel) { $g.FillRectangle((Get-Brush $T.Accent), $b.X, $b.Y + 5, 3, $b.Height - 10) }
    $flags = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, SingleLine, NoPrefix'
    if ($col -eq 4) {
        if ($it.Progress -ge 0) {
            $w = [Math]::Max(20, $b.Width - 62)
            $y = $b.Y + [int]($b.Height / 2) - 3
            $g.FillRectangle((Get-Brush $T.Border), ($b.X + 8), $y, $w, 6)
            $c = switch ($it.Status) { 'Done' { $T.Ok } 'Failed' { $T.Bad } 'Canceled' { $T.Muted } 'Paused' { $T.Muted } default { $T.Accent } }
            $g.FillRectangle((Get-Brush $c), ($b.X + 8), $y, [int]($w * [Math]::Min(100, $it.Progress) / 100), 6)
            $tr = New-Object System.Drawing.Rectangle(($b.X + 14 + $w), $b.Y, 48, $b.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($g, ('{0}%' -f [int]$it.Progress), $script:FontSmall, $tr, $T.Muted, $flags)
        } elseif ($it.Status -eq 'Downloading') {
            $tr = New-Object System.Drawing.Rectangle(($b.X + 8), $b.Y, ($b.Width - 10), $b.Height)
            [System.Windows.Forms.TextRenderer]::DrawText($g, 'working...', $script:FontSmall, $tr, $T.Muted, $flags)
        }
        return
    }
    $color = $T.Text
    if ($col -eq 0) { $color = $T.Muted }
    elseif ($col -eq 3) { $color = switch ($it.Status) { 'Downloading' { $T.Accent } 'Done' { $T.Ok } 'Failed' { $T.Bad } default { $T.Muted } } }
    elseif ($col -eq 2) { $color = $T.Muted }
    elseif ($it.Status -in 'Done', 'Canceled') { $color = $T.Muted }
    $tr = New-Object System.Drawing.Rectangle(($b.X + 10), $b.Y, [Math]::Max(10, $b.Width - 14), $b.Height)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $E.SubItem.Text, $(if ($col -eq 1) { $List.Font } else { $script:FontSmall }), $tr, $color, $flags)
    if ($col -eq 1 -and $it.Status -eq 'Downloading' -and $it.Progress -ge 0) {
        # a thin progress line under the file name
        $w = [Math]::Max(10, $b.Width - 20)
        $g.FillRectangle((Get-Brush $T.Border), ($b.X + 10), ($b.Bottom - 5), $w, 3)
        $g.FillRectangle((Get-Brush $T.Accent), ($b.X + 10), ($b.Bottom - 5), [int]($w * [Math]::Min(100, $it.Progress) / 100), 3)
    }
}

# ---- TV downloads: our own pipeline (FFmpeg only, no Python) ----------------------------
# 1) FFmpeg copies NRK's best stream (highest resolution and best audio from the HLS master
#    playlist, chosen by FFmpeg itself) into an MP4: the picture and sound are exactly NRK's,
#    nothing is re-encoded, so there is no quality loss and no extra time.
# 2) A quick second pass (local, seconds) adds what makes it a good file: the subtitles as a
#    track, NRK's chapters, the title/series/season/episode/description/year tags, and the
#    cover picture. "+faststart" puts the index first, so it starts at once and streams well.
# Layout like nrkdownload's (media servers recognise it):
#   <folder>\<Series>\Season 01\<Series> - s01e02 - <Title>.mp4   (+ .no.srt, .jpg if kept)
#   <folder>\<Title> (<year>).mp4                                    (single programmes)
function Select-HlsVariant([string] $Url) {
    # NRK's master playlist lists the same programme in several qualities. Pick the best one
    # ourselves (highest resolution, then bit rate) and its main audio, so FFmpeg reads just
    # that: faster than letting it open every quality, and no stray streams.
    $res = [pscustomobject]@{ Inputs = @('-i', $Url); Maps = @('-map', '0:v:0', '-map', '0:a:0?'); Label = 'master playlist'; VideoUrl = $Url; AudioUrl = $null; Master = $false }
    try {
        $wc = New-Object System.Net.WebClient; $wc.Headers['User-Agent'] = $script:UserAgent; $wc.Encoding = [Text.Encoding]::UTF8
        $text = $wc.DownloadString($Url); $wc.Dispose()
        if ($text -notmatch '#EXT-X-STREAM-INF') { return $res }   # already a single quality
        $base = [Uri]$Url
        $attr = { param([string] $line, [string] $name) if ($line -match ('(?:^|[:,])' + $name + '=("([^"]*)"|[^,]*)')) { if ($Matches[2]) { $Matches[2] } else { $Matches[1] } } else { $null } }
        $lines = $text -split "`r?`n"
        $vars = @(); $audio = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            if ($l -like '#EXT-X-STREAM-INF:*') {
                $uri = $null; for ($j = $i + 1; $j -lt $lines.Count; $j++) { if ($lines[$j] -and -not $lines[$j].StartsWith('#')) { $uri = $lines[$j].Trim(); break } }
                if (-not $uri) { continue }
                $h = 0; $r = & $attr $l 'RESOLUTION'; if ($r -match 'x(\d+)$') { $h = [int]$Matches[1] }
                $bw = 0; [void][long]::TryParse([string](& $attr $l 'BANDWIDTH'), [ref]$bw)
                $vars += [pscustomobject]@{ Uri = [string](New-Object Uri($base, $uri)); Height = $h; Bw = $bw; Audio = (& $attr $l 'AUDIO') }
            } elseif ($l -like '#EXT-X-MEDIA:*' -and (& $attr $l 'TYPE') -eq 'AUDIO' -and (& $attr $l 'URI')) {
                $audio += [pscustomobject]@{ Group = (& $attr $l 'GROUP-ID'); Uri = [string](New-Object Uri($base, (& $attr $l 'URI'))); Default = ((& $attr $l 'DEFAULT') -eq 'YES'); Name = [string](& $attr $l 'NAME') }
            }
        }
        # Options > Download rules > Quality: the best one up to the chosen height (or the smallest when none is that low)
        $maxH = 0; [void][int]::TryParse([string](Get-AppSettings).DlQuality, [ref]$maxH)
        $pool = if ($maxH -gt 0) { @($vars | Where-Object { $_.Height -gt 0 -and $_.Height -le $maxH }) } else { @($vars) }
        if (-not $pool.Count) { $pool = @($vars | Sort-Object Height, Bw | Select-Object -First 1) }
        $best = $pool | Sort-Object Height, Bw -Descending | Select-Object -First 1
        if (-not $best) { return $res }
        $res.Inputs = @('-i', $best.Uri); $res.Maps = @('-map', '0:v:0', '-map', '0:a:0?'); $res.VideoUrl = $best.Uri; $res.Master = $true
        $res.Label = '{0}p, {1:N0} kbit/s' -f $best.Height, ($best.Bw / 1000)
        if ($best.Audio) {
            # separate audio: the default track of its group (not audio description / "synstolk")
            $wantAd = [bool](Get-AppSettings).DlAudioDescription   # (Options > Downloads: the audio-described version when there is one)
            $a = @($audio | Where-Object { $_.Group -eq $best.Audio }) | Sort-Object @{ e = { ($_.Name -match 'synstolk|tolk|description') -ne $wantAd } }, @{ e = { -not $_.Default } } | Select-Object -First 1
            if ($a) { $res.Inputs += @('-i', $a.Uri); $res.Maps = @('-map', '0:v:0', '-map', '1:a:0'); $res.Label += ', separate audio'; $res.AudioUrl = $a.Uri }
        }
        Write-Log INFO "Download quality: $($res.Label) ($($vars.Count) qualities offered)"
    } catch { Write-Log WARN "Could not read the playlist, letting FFmpeg choose: $($_.Exception.Message)" }
    return $res
}

function Get-EpisodeNaming($File) {
    # folder and file name of an episode (no NRK lookup needed): "19\Season 01", "19 - s01e02 - 15 dager igjen"
    $series = [string]$File.SeriesItem.Title
    $title = [string]$File.Title
    $sea = [string]$File.Season
    $epNo = $null
    $seq = Get-Prop $File.Raw 'sequenceNumber'; if ($seq) { $epNo = [int]$seq }
    if (-not $epNo -and $title -match '^(\d{1,3})\.\s') { $epNo = [int]$Matches[1] }
    $cleanTitle = ($title -replace '^\d{1,3}\.\s*', '').Trim(); if (-not $cleanTitle) { $cleanTitle = $title }
    $seaDir = if ($sea -eq 'ekstramateriale') { 'Ekstramateriale' } elseif ($sea -match '^\d{1,2}$') { 'Season {0:D2}' -f [int]$sea } elseif ($sea) { "Season $sea" } else { 'Season 01' }
    $name = if ($sea -match '^\d{1,2}$' -and $epNo) { '{0} - s{1:D2}e{2:D2} - {3}' -f $series, [int]$sea, $epNo, $cleanTitle } else { '{0} - {1}' -f $series, $title }
    # 2.9.0: your own file name (Options > Download rules), when everything it uses is known
    $tpl = [string](Get-AppSettings).DlNameTv
    if ($tpl) {
        $vals = @{ series = $series; title = $cleanTitle; id = [string]$File.Id; season = $(if ($sea -match '^\d{1,2}$') { '{0:D2}' -f [int]$sea } else { '' }); episode = $(if ($epNo) { '{0:D2}' -f [int]$epNo } else { '' }) }
        $own = Format-NameTemplate $tpl $vals
        if ($own) { $name = $own }
    }
    [pscustomobject]@{ Series = $series; Season = $sea; EpNo = $epNo; CleanTitle = $cleanTitle; SubDir = (Join-Path (Get-SafeFileName $series) $seaDir); Name = (Get-SafeFileName $name) }
}

function Find-ExistingDownload($File, [string] $Dir) {
    # the file this would be saved as, when it is already there (checked before it goes in the queue)
    if (-not $Dir -or -not $File) { return $null }
    try {
        switch ($File.Type) {
            'episode' {
                if (-not $File.SeriesItem) { return $null }
                $nm = Get-EpisodeNaming $File
                $base = Join-Path (Join-Path $Dir $nm.SubDir) $nm.Name
                foreach ($x in "$base.mp4", "$base.mkv", "$base.m4v") { if (Test-Path -LiteralPath $x) { return $x } }
            }
            'program' {
                $t = Get-SafeFileName ([string]$File.Title)
                if (Test-Path -LiteralPath $Dir) {
                    foreach ($f in [IO.Directory]::EnumerateFiles($Dir)) {
                        $n = [IO.Path]::GetFileName($f)
                        if ($n -match ('^{0}( \(\d{{4}}\))?\.(mp4|mkv|m4v)$' -f [regex]::Escape($t))) { return $f }
                    }
                }
            }
            'audio' {
                $ser = Get-SafeFileName $(if ($File.SeriesTitle) { $File.SeriesTitle } else { 'NRK Radio' })
                $name = Get-RadioFileName $File
                $rd = Get-CurrentDownloadDir -Radio
                foreach ($folder in @($(if ($rd) { Join-Path $rd $ser }), (Join-Path (Join-Path $Dir 'Radio') $ser))) {   # (before 2.6.8: <download folder>\Radio)
                    if (-not $folder) { continue }
                    $base = Join-Path $folder $name
                    foreach ($x in "$base.m4a", "$base.mp3", "$base.flac") { if (Test-Path -LiteralPath $x) { return $x } }
                }
            }
        }
    } catch { }
    return $null
}

function Get-TvDownloadPlan {
    param($File, [string] $Dir)
    $st = Get-NrkVideoStream -Id $File.Id
    if (-not $st.Playable -or -not $st.Url) { throw ("not available: {0}" -f $(if ($st.Reason) { $st.Reason } elseif ($st.Encrypted) { 'copy-protected (DRM)' } else { 'no stream' })) }
    $info = $null; try { $info = Get-NrkProgramInfo -ProgramId $File.Id } catch { }
    $pinf = if ($info) { Get-Prop $info.Raw 'programInformation' } else { $null }
    $desc = [string](Get-Prop $pinf 'description'); if (-not $desc) { $desc = [string]$File.Description }
    $year = if ($info -and $info.Year) { [string]$info.Year } else { '' }
    $tags = [ordered]@{ comment = 'NRK TV  ·  downloaded with NRK Browser'; copyright = 'NRK' }
    if ($File.Type -eq 'episode' -and $File.SeriesItem) {
        $nm = Get-EpisodeNaming $File
        $series = $nm.Series; $sea = $nm.Season; $epNo = $nm.EpNo; $cleanTitle = $nm.CleanTitle
        $folder = Join-Path $Dir $nm.SubDir
        $name = $nm.Name
        $tags.title = $cleanTitle; $tags.show = $series; $tags.album = $series; $tags.artist = $series
        if ($sea -match '^\d{1,2}$') { $tags.season_number = [int]$sea }
        if ($epNo) { $tags.episode_sort = $epNo; $tags.track = $epNo; $tags.episode_id = [string]$File.Id }
        $tags.media_type = 10   # (TV show, for Apple/iTunes-style players)
    } else {
        $title = [string]$File.Title
        $folder = $Dir
        $name = if ($year) { '{0} ({1})' -f $title, $year } else { $title }
        $tags.title = $title; $tags.media_type = 9
    }
    if ($desc) { $tags.description = $desc; $tags.synopsis = $desc }
    if ($year) { $tags.date = $year }
    $base = Join-Path $folder $(if ($File.Type -eq 'episode' -and $File.SeriesItem) { $name } else { Get-SafeFileName $name })
    $src = Select-HlsVariant $st.Url
    $ext = if ((Get-AppSettings).DlContainer -eq 'mkv') { 'mkv' } else { 'mp4' }
    [pscustomobject]@{ Kind = 'tv'; Stream = $st; Source = $src; Folder = $folder; Base = $base; Out = "$base.$ext"; Part = "$base.part.mp4"; Tags = $tags
                       Poster = $(if ($st.Poster) { $st.Poster } elseif ($info) { $info.ImageUrl } else { $null }) }
}

function Complete-TvDownload($Plan, $Item) {
    # second pass: subtitles, chapters, tags, cover. Returns a note for the row.
    $st = Get-AppSettings
    $ff = (Find-FFmpeg).Path
    $work = Join-Path $script:AppDataDir 'dltmp'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $notes = @()
    $inputs = @('-i', $Plan.Part); $maps = @('-map', '0:v:0', '-map', '0:a?'); $meta = @(); $n = 1
    # subtitles (NRK's WebVTT, read by FFmpeg directly)
    $subs = @($Plan.Stream.Subtitles)
    $si = 0
    if ($st.DlEmbedSubs) {
        foreach ($s in $subs) {
            $inputs += @('-i', $s.url); $maps += @('-map', "$($n):0")
            $lang = switch ([string]$s.language) { { $_ -in 'no', 'nb', 'nor', 'nob', '' } { 'nor' } 'nn' { 'nno' } 'en' { 'eng' } 'se' { 'sme' } default { [string]$s.language } }
            $label = if ($s.label) { [string]$s.label } else { 'Norsk' }
            $meta += @("-metadata:s:s:$si", "language=$lang", "-metadata:s:s:$si", "title=$label", "-metadata:s:s:$si", "handler_name=$label", "-disposition:s:$si", $(if ($si -eq 0) { 'default' } else { '0' }))
            $n++; $si++
        }
        if ($si) { $notes += 'subtitles' }
    }
    # chapters (NRK's index points)
    $chap = @($Plan.Stream.Chapters | Where-Object { $_ -and $null -ne $_.start })
    $chapIdx = $null
    if ($chap.Count) {
        $dur = [double]$Plan.Stream.Duration
        $sb = New-Object Text.StringBuilder; [void]$sb.Append(";FFMETADATA1`n")
        for ($i = 0; $i -lt $chap.Count; $i++) {
            $a = [long]([double]$chap[$i].start * 1000)
            $b = if ($i -lt $chap.Count - 1) { [long]([double]$chap[$i + 1].start * 1000) } elseif ($dur -gt 0) { [long]($dur * 1000) } else { $a + 1000 }
            if ($b -le $a) { continue }
            $t = ([string]$chap[$i].title) -replace '([=;#\\])', '\$1' -replace "`r?`n", ' '
            [void]$sb.Append("[CHAPTER]`nTIMEBASE=1/1000`nSTART=$a`nEND=$b`ntitle=$t`n")
        }
        $cf = Join-Path $work "chapters.$PID.txt"
        [IO.File]::WriteAllText($cf, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
        $inputs += @('-i', $cf); $chapIdx = $n; $n++
        $notes += "$($chap.Count) chapters"
    }
    # cover picture
    $cover = $null
    if ($Plan.Poster) {
        try {
            $cover = Join-Path $work "cover.$PID.jpg"
            $wc = New-Object System.Net.WebClient; $wc.Headers['User-Agent'] = $script:UserAgent
            $wc.DownloadFile($Plan.Poster, $cover); $wc.Dispose()
            if ((Get-Item -LiteralPath $cover).Length -lt 200) { $cover = $null }
        } catch { $cover = $null }
        if ($cover) { $inputs += @('-i', $cover); $maps += @('-map', "$($n):0"); $coverIdx = $n; $n++; $notes += 'cover' }
    }
    $mkv = ($Plan.Out -like '*.mkv')
    if ($mkv -and $cover) {
        # MKV keeps the cover as an attachment, not as a picture stream
        $maps = @($maps | Select-Object -First ($maps.Count - 2)); $inputs = @($inputs | Select-Object -First ($inputs.Count - 2))
    }
    $argv = @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error') + $inputs + $maps + @('-c', 'copy', '-c:s', $(if ($mkv) { 'srt' } else { 'mov_text' }))
    if ($cover -and -not $mkv) { $argv += @('-disposition:v:1', 'attached_pic') }
    if ($cover -and $mkv) { $argv += @('-attach', $cover, '-metadata:s:t', 'mimetype=image/jpeg', '-metadata:s:t', 'filename=cover.jpg') }
    # tags only from us; chapters (with their titles) from the chapter file
    if ($null -ne $chapIdx) { $argv += @('-map_metadata', "$chapIdx", '-map_chapters', "$chapIdx") } else { $argv += @('-map_metadata', '-1') }
    foreach ($k in $Plan.Tags.Keys) { $argv += @('-metadata', ('{0}={1}' -f $k, $Plan.Tags[$k])) }
    $argv += $meta
    $argv += @('-metadata:s:v:0', 'language=nor', '-metadata:s:a:0', 'language=nor')
    if (-not $mkv) { $argv += @('-movflags', '+faststart') }
    $argv += $Plan.Out
    $ok = $false
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ff; $psi.Arguments = ConvertTo-ArgString $argv
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi); Add-ProcessToJob $p
        $err = $p.StandardError.ReadToEndAsync()
        Wait-FinishProcess $p ([string]$Plan.Out)
        if ($p.ExitCode -ne 0) { throw ("ffmpeg exit {0}: {1}" -f $p.ExitCode, (($err.Result -split "`n" | Select-Object -First 3) -join ' ')) }
        if ((Get-Item -LiteralPath $Plan.Out).Length -lt 0.9 * (Get-Item -LiteralPath $Plan.Part).Length) { throw 'the finished file looks too small' }
        Remove-Item -LiteralPath $Plan.Part -Force
        $ok = $true
    } catch {
        Write-DownloadLog "   finishing failed ($($_.Exception.Message)): keeping the plain video"
        Remove-Item -LiteralPath $Plan.Out -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $Plan.Part -Destination $Plan.Out -Force
        $notes = @()
    }
    # the extras next to the video (the subtitles as .srt, the picture as .jpg) when wanted
    if ($subs.Count -and (-not $st.DlEmbedSubs -or $st.DlKeepSrt)) {
        $k = 0
        foreach ($s in $subs) {
            $code = if ($s.language) { ([string]$s.language).Substring(0, [Math]::Min(2, ([string]$s.language).Length)) } else { 'no' }
            if ($code -eq 'nb') { $code = 'no' }
            $srt = '{0}.{1}{2}.srt' -f $Plan.Base, $code, $(if ($k) { ".$k" } else { '' })
            try { & $ff -hide_banner -nostdin -y -loglevel error -i $s.url -c:s srt $srt 2>$null | Out-Null } catch { }
            $k++
        }
    }
    if ($cover -and $st.DlKeepSrt) { try { Copy-Item -LiteralPath $cover -Destination "$($Plan.Base).jpg" -Force } catch { } }
    foreach ($x in @((Join-Path $work "chapters.$PID.txt"), $cover)) { if ($x) { Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue } }
    if ($ok) { Write-DownloadLog ("   finished: {0}" -f $(if ($notes.Count) { ($notes -join ', ') + ' added' } else { 'plain MP4' })) }
    return ($notes -join ', ')
}

function Get-DownloadedFileSet($Item) {
    # the video/audio of a finished download plus what belongs to it (.srt, .jpg)
    $main = @(@($Item.Files) | Where-Object { $_ -and $_ -match '\.(mp4|mkv|m4v|m4a|mp3|flac)$' -and (Test-Path -LiteralPath $_) })
    if (-not $main.Count -and $Item.File) { $x = Find-ExistingDownload $Item.File (Get-CurrentDownloadDir); if ($x) { $main = @($x) } }
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($m in $main) {
        $all.Add($m)
        $base = [IO.Path]::Combine([IO.Path]::GetDirectoryName($m), [IO.Path]::GetFileNameWithoutExtension($m))
        foreach ($f in [IO.Directory]::EnumerateFiles([IO.Path]::GetDirectoryName($m))) {
            if ($f -ne $m -and $f.StartsWith("$base.", [StringComparison]::OrdinalIgnoreCase) -and $f -match '\.(srt|vtt|jpg|png)$') { $all.Add($f) }
        }
    }
    return @($all | Select-Object -Unique)
}

function Remove-DownloadedFiles([object[]] $Items) {
    # right-click > Delete downloaded file: the files on disk, then the row
    $sets = @(foreach ($it in $Items) { [pscustomobject]@{ Item = $it; Files = @(Get-DownloadedFileSet $it) } })
    $files = @($sets | ForEach-Object { $_.Files })
    if (-not $files.Count) { [void][System.Windows.Forms.MessageBox]::Show($script:DlUi.Form, 'The downloaded file is not there any more.', 'Delete downloaded file', 'OK', 'Information'); return }
    $list = ($files | Select-Object -First 8 | ForEach-Object { '  ' + (Split-Path -Leaf $_) }) -join "`n"
    if ($files.Count -gt 8) { $list += "`n  ... and $($files.Count - 8) more" }
    $q = [System.Windows.Forms.MessageBox]::Show($script:DlUi.Form, "Delete these files from your computer?`n`n$list`n`nThey go to the Recycle Bin.", 'Delete downloaded file', 'YesNo', 'Warning')
    if ($q -ne 'Yes') { return }
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
    $n = 0
    foreach ($f in $files) {
        try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, 'OnlyErrorDialogs', 'SendToRecycleBin'); $n++ }
        catch { try { Remove-Item -LiteralPath $f -Force; $n++ } catch { Write-DownloadLog "Could not delete ${f}: $($_.Exception.Message)" } }
    }
    foreach ($s in $sets) {
        # empty season / series folders go too
        foreach ($d in @($s.Files | ForEach-Object { Split-Path -Parent $_ } | Select-Object -Unique)) {
            # (only below the download folder the file is in: never the folder itself or anything above it)
            $root = (Get-CurrentDownloadDir -Radio:($s.Item.Kind -eq 'radio')).TrimEnd('\')
            for ($x = $d; $x -and $root -and $x.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase); $x = Split-Path -Parent $x) {
                if ((Test-Path -LiteralPath $x) -and -not (Get-ChildItem -LiteralPath $x -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue } else { break }
            }
        }
        [void]$script:DlQueue.Remove($s.Item)
    }
    Write-DownloadLog ("Deleted {0} file(s) (Recycle Bin)" -f $n)
    Request-QueueSave
    Update-DownloadList -Select @()
}

function Open-DownloadedFile($Item) {
    # Explorer with the downloaded video/audio selected (or its folder)
    $files = @($Item.Files | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    $main = @($files | Where-Object { $_ -match '\.(m4v|mp4|mkv|m4a|mp3|flac|aac)$' }) + $files | Select-Object -First 1
    if (-not $main -and $Item.Dir -and (Test-Path -LiteralPath $Item.Dir)) { Start-Process $Item.Dir; return }
    if (-not $main) {
        # "already downloaded" (nothing new this time): the download folder
        $d = Get-CurrentDownloadDir -Radio:($Item.Kind -eq 'radio')
        if ($Item.Kind -eq 'radio' -and $Item.File.SeriesTitle) { $sub = Join-Path $d (Get-SafeFileName $Item.File.SeriesTitle); if (Test-Path -LiteralPath $sub) { $d = $sub } }
        elseif ($Item.File.SeriesItem.Title) { $sub = Join-Path $d ($Item.File.SeriesItem.Title -replace '[/\\?<>:*|!"'']', ''); if (Test-Path -LiteralPath $sub) { $d = $sub } }   # nrkdownload's series folder
        if ($d -and (Test-Path -LiteralPath $d)) { Start-Process $d } else { Set-Status 'The download folder does not exist (any more)' }
        return
    }
    Write-Log INFO "Downloads: show $main"
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $main)
}

function Update-DownloadNow {
    # the "now downloading" strip above the output
    $ui = $script:DlUi
    if (-not $ui -or $ui.Form.IsDisposed -or -not $ui.Now) { return }
    $show = [bool]$script:DlRun.Item
    if ($ui.Now.Visible -ne $show) { $ui.Now.Visible = $show }
    if ($show) { $ui.Now.Invalidate() }
}

function Invoke-DrawDownloadNow($G, $Box) {
    $it = $script:DlRun.Item
    $G.Clear($T.Bg)
    if (-not $it) { return }
    $flags = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, SingleLine, NoPrefix'
    $right = [System.Windows.Forms.TextFormatFlags]'Right, VerticalCenter, SingleLine, NoPrefix'
    $num = $script:DlQueue.IndexOf($it) + 1
    $pct = if ($it.Progress -ge 0) { [Math]::Min(100, $it.Progress) } else { -1 }
    $info = if ($pct -ge 0) { '{0}%{1}' -f [int]$pct, $(if ($it.Eta) { "  ·  $($it.Eta) left" } else { '' }) } else { 'starting...' }
    $w = $Box.ClientSize.Width
    [System.Windows.Forms.TextRenderer]::DrawText($G, $info, $script:FontUi, (New-Object System.Drawing.Rectangle(($w - 220), 4, 216, 24)), $T.Muted, $right)
    [System.Windows.Forms.TextRenderer]::DrawText($G, ('Now  #{0}  {1}' -f $num, $it.Title), $script:FontBold, (New-Object System.Drawing.Rectangle(0, 4, [Math]::Max(10, $w - 230), 24)), $T.Text, $flags)
    $G.FillRectangle((Get-Brush $T.Border), 0, 34, $w, 8)
    if ($pct -ge 0) { $G.FillRectangle((Get-Brush $T.Accent), 0, 34, [int]($w * $pct / 100), 8) }
}

function New-QueueList {
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $true; $lv.HideSelection = $false
    $lv.BorderStyle = 'None'; $lv.HeaderStyle = 'Nonclickable'
    $lv.BackColor = $T.Bg; $lv.ForeColor = $T.Text; $lv.Font = $script:FontUi; $lv.OwnerDraw = $true
    $il = New-Object System.Windows.Forms.ImageList; $il.ImageSize = New-Object System.Drawing.Size(1, 32); $lv.SmallImageList = $il
    foreach ($c in @(@('#', 48), @('File', 420), @('Type', 70), @('Status', 200), @('Progress', 170))) { [void]$lv.Columns.Add($c[0], $c[1]) }
    $lv.Add_DrawColumnHeader({
        $l = $args[0]; $e = $args[1]
        $w = if ($e.ColumnIndex -eq $l.Columns.Count - 1) { [Math]::Max($e.Bounds.Width, $l.ClientSize.Width - $e.Bounds.X) } else { $e.Bounds.Width }
        $r = New-Object System.Drawing.Rectangle($e.Bounds.X, $e.Bounds.Y, $w, $e.Bounds.Height)
        $e.Graphics.FillRectangle((Get-Brush $l.BackColor), $r)
        $e.Graphics.FillRectangle((Get-Brush $T.Border), $r.X, $r.Bottom - 1, $r.Width, 1)
        $tr = New-Object System.Drawing.Rectangle(($r.X + 10), $r.Y, ($r.Width - 12), $r.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text.ToUpper(), $script:FontSmall, $tr, $T.Muted,
            [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, SingleLine, NoPrefix')
    })
    $lv.Add_DrawItem({ })
    $lv.Add_DrawSubItem({ Invoke-DrawQueueCell $args[0] $args[1] })
    $lv.Add_Resize({
        $l = $args[0]
        $other = 0; for ($i = 0; $i -lt $l.Columns.Count; $i++) { if ($i -ne 1) { $other += $l.Columns[$i].Width } }
        $l.Columns[1].Width = [Math]::Max(160, $l.ClientSize.Width - $other - 2)
    })
    $lv.Add_HandleCreated({ Enable-DarkScrollbars $args[0] })
    return $lv
}

function Update-DownloadRow($Item) {
    $row = $Item.Row
    if (-not $row -or -not $row.ListView) { return }
    $row.SubItems[3].Text = Get-DownloadStatusText $Item
    $row.ListView.Invalidate($row.Bounds)
    Update-DownloadNow
    Update-DownloadSummary
}

function Update-DownloadList {
    param([int[]] $Select = $null)
    $ui = $script:DlUi
    if (-not $ui -or $ui.Form.IsDisposed) { return }
    $ids = if ($null -ne $Select) { $Select } else { @($ui.List.SelectedItems | ForEach-Object { $_.Tag.Id }) }
    $top = if ($ui.List.TopItem) { $ui.List.TopItem.Index } else { 0 }
    $ui.List.BeginUpdate()
    $ui.List.Items.Clear()
    $i = 0
    foreach ($it in $script:DlQueue) {
        $i++
        $row = New-Object System.Windows.Forms.ListViewItem([string]$i)
        [void]$row.SubItems.Add([string]$it.Title)
        [void]$row.SubItems.Add($(if ($it.Kind -eq 'radio') { 'Radio' } else { 'TV' }))
        [void]$row.SubItems.Add((Get-DownloadStatusText $it))
        [void]$row.SubItems.Add('')
        $row.Tag = $it
        $row.ToolTipText = $it.Url
        $it.Row = $row
        [void]$ui.List.Items.Add($row)
        if ($ids -contains $it.Id) { $row.Selected = $true }
    }
    $ui.List.EndUpdate()
    if ($ui.List.Items.Count -gt 0) {
        try { $ui.List.TopItem = $ui.List.Items[[Math]::Min($top, $ui.List.Items.Count - 1)] } catch { }
        $firstSel = @($ui.List.SelectedItems)[0]
        if ($firstSel) { $firstSel.EnsureVisible() }
    }
    Update-DownloadSummary
}

function Update-DownloadSummary {
    Request-QueueSave
    $ui = $script:DlUi
    if (-not $ui -or $ui.Form.IsDisposed) { return }
    $c = @{}; foreach ($it in $script:DlQueue) { $c[$it.Status] = 1 + [int]$c[$it.Status] }
    $parts = @('{0} in queue' -f $script:DlQueue.Count)
    if ($c.Done) { $parts += '{0} done' -f $c.Done }
    if ($c.Failed) { $parts += '{0} failed' -f $c.Failed }
    if ($c.Pending) { $parts += '{0} waiting' -f $c.Pending }
    $run = $script:DlRun.Item
    if ($run) { $parts += 'now: #{0} {1}{2}' -f ($script:DlQueue.IndexOf($run) + 1), $run.Title, $(if ($run.Progress -ge 0) { " ($([int]$run.Progress)%)" } else { '' }) }
    $ui.Summary.Text = $parts -join '   ·   '
    $busy = [bool]($script:DlRun.Proc -or $script:DlRun.Fetch -or $script:DlRun.Finishing)
    # the folder can't change while files are being saved into it
    $ui.Cancel.Enabled = ($busy -or [bool]($c.Pending -or $c.Added -or $c.Paused))
    $ui.Clear.Enabled = [bool]($c.Done -or $c.Failed -or $c.Canceled)
    if ($ui.ClearNew) { $ui.ClearNew.Enabled = [bool](@($script:DlQueue | Where-Object { $_ -ne $script:DlRun.Item -and ($_.Status -eq 'Added' -or ($_.Status -in 'Canceled', 'Failed', 'Paused' -and $_.Progress -le 0)) }).Count) }
    $ui.SelAll.Enabled = [bool]$script:DlQueue.Count
    if ($ui.Start) { $ui.Start.Enabled = [bool]($c.Added -or $c.Failed -or $c.Canceled -or $c.Paused) }   # (something that can be started)
    if ($c.Paused) { $parts += '{0} paused' -f $c.Paused }
    if ($ui.Pause) {
        $resume = [bool]($script:DlPaused -or ($c.Paused -and -not $busy))
        $ui.Pause.Tag = if ($resume) { 'resume' } else { 'pause' }
        if ($resume) { Set-IconText $ui.Pause 'play' 'Resume' ([string][char]0x25B6) } else { Set-IconText $ui.Pause 'pause' 'Pause' ([string][char]0x2016) }
        $ui.Pause.Enabled = ($busy -or [bool]$c.Pending -or [bool]$c.Paused)
        $ui.Summary.Text = $parts -join '   ·   '
    }
    $ui.Form.Text = if ($run) { 'Downloads - {0}%  {1}' -f $(if ($run.Progress -ge 0) { [int]$run.Progress } else { '...' }), $run.Title } else { 'Downloads - NRK Browser' }
}

function Get-SelectedDownloadItems {
    $ui = $script:DlUi
    if (-not $ui) { return @() }
    return @($ui.List.SelectedItems | ForEach-Object { $_.Tag })
}

function Move-DownloadItems {
    param([ValidateSet('up', 'down', 'top', 'bottom')] [string] $Direction)
    $sel = Get-SelectedDownloadItems
    if ($sel.Count -eq 0) { return }
    $q = $script:DlQueue
    switch ($Direction) {
        'up' {
            for ($i = 1; $i -lt $q.Count; $i++) {
                if (($sel -contains $q[$i]) -and -not ($sel -contains $q[$i - 1])) { $t = $q[$i]; $q[$i] = $q[$i - 1]; $q[$i - 1] = $t }
            }
        }
        'down' {
            for ($i = $q.Count - 2; $i -ge 0; $i--) {
                if (($sel -contains $q[$i]) -and -not ($sel -contains $q[$i + 1])) { $t = $q[$i]; $q[$i] = $q[$i + 1]; $q[$i + 1] = $t }
            }
        }
        { $_ -in 'top', 'bottom' } {
            $picked = @($q | Where-Object { $sel -contains $_ })
            $rest = @($q | Where-Object { $sel -notcontains $_ })
            $q.Clear()
            $order = if ($Direction -eq 'top') { $picked + $rest } else { $rest + $picked }
            foreach ($x in $order) { [void]$q.Add($x) }
        }
    }
    Update-DownloadList -Select @($sel | ForEach-Object { $_.Id })
}

function Remove-DownloadItems {
    $sel = Get-SelectedDownloadItems
    if ($sel.Count -eq 0) { return }
    if ($sel -contains $script:DlRun.Item) {
        [void][System.Windows.Forms.MessageBox]::Show($script:DlUi.Form, 'One of the selected files is downloading right now. Cancel it first.', 'Remove from list', 'OK', 'Information')
        return
    }
    if ($script:DlRun.Finishing -and ($sel -contains $script:DlRun.Finishing)) {
        [void][System.Windows.Forms.MessageBox]::Show($script:DlUi.Form, "One of the selected files is being finished (subtitles, chapters, cover). Wait a moment until it says Done.", 'Remove from list', 'OK', 'Information')
        return
    }
    foreach ($it in $sel) {
        $script:DlQueue.Remove($it); Write-Log INFO "Download queue: - $($it.Title)"
        if ($it.Status -ne 'Done') { Remove-Item -LiteralPath (Get-DownloadTmpDir $it) -Recurse -Force -ErrorAction SilentlyContinue }   # its saved pieces
    }
    Request-QueueSave
    Write-DownloadLog ('Removed {0} file(s) from the queue' -f $sel.Count)
    Update-DownloadList -Select @()
}

function Clear-NotStartedDownloads {
    # everything that has not got anywhere yet: not started, or stopped at 0 %
    $gone = @($script:DlQueue | Where-Object { $_ -ne $script:DlRun.Item -and ($_.Status -eq 'Added' -or ($_.Status -in 'Canceled', 'Failed', 'Paused' -and $_.Progress -le 0)) })
    if (-not $gone.Count) { return }
    foreach ($it in $gone) {
        $script:DlQueue.Remove($it)
        Remove-Item -LiteralPath (Get-DownloadTmpDir $it) -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-DownloadLog ('Cleared {0} file(s) that had not started' -f $gone.Count)
    Request-QueueSave
    Update-DownloadList
}

function Clear-FinishedDownloads {
    $gone = @($script:DlQueue | Where-Object { $_.Status -in 'Done', 'Failed', 'Canceled' })
    foreach ($it in $gone) { $script:DlQueue.Remove($it) }
    Request-QueueSave
    if ($gone.Count) { Write-DownloadLog ('Cleared {0} finished file(s) from the list (files on disk are kept)' -f $gone.Count) }
    Update-DownloadList
}

# ---- running the queue

function Test-DownloadTools {
    # Returns $true when everything needed for these items is installed.
    param([object[]] $Items)
    $missing = @()
    $ff = Find-FFmpeg
    if (-not $ff.Found) { $missing += 'FFmpeg' }
    if ($missing.Count -eq 0) { return $true }
    $owner = if ($script:DlUi -and -not $script:DlUi.Form.IsDisposed -and $script:DlUi.Form.Visible) { $script:DlUi.Form } else { $form }   # (a followed series may start it with the window closed)
    $q = [System.Windows.Forms.MessageBox]::Show($owner, ("Downloading needs: {0}.`n`nOpen Components to install it now?" -f ($missing -join ', ')), 'Missing components', 'YesNo', 'Warning')
    if ($q -eq 'Yes') { [void](Show-DependencyDialog -Status (Get-DependencyStatus) -Owner $owner -IncludeSkipped) }
    return $false
}

function Start-DownloadQueue {
    # Marks the given items (or every item not done yet) as waiting and starts the runner.
    param([object[]] $Items = $null, [switch] $All)
    $ui = $script:DlUi
    $owner = if ($ui -and -not $ui.Form.IsDisposed) { $ui.Form } else { $form }   # (followed series: the window may not be open)
    $script:DlPaused = $false
    $targets = if ($All) { @($script:DlQueue | Where-Object { $_.Status -in 'Added', 'Failed', 'Canceled', 'Paused' }) }
               else { @($Items | Where-Object { $_ -and $_.Status -in 'Added', 'Failed', 'Canceled', 'Paused' }) }
    if ($targets.Count -eq 0) {
        if (-not $All -and @($Items).Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($owner, "Select files in the queue first (Shift/Ctrl+click for several, or Select all).", 'Download', 'OK', 'Information') }
        return
    }
    # download folders (TV: Videos\NRK-Browser, radio: Music\NRK-Browser): asks for one when it is gone
    $dirs = @()
    foreach ($radio in @($false, $true)) {
        if (-not @($targets | Where-Object { ($_.Kind -eq 'radio') -eq $radio }).Count) { continue }
        $d = Resolve-DownloadFolder -Radio:$radio -Owner $owner
        if (-not $d) { return }
        Set-DownloadDirSetting $d -Radio:$radio
        $dirs += $d
    }
    $dir = $dirs -join ', '
    if (-not (Test-DownloadTools $targets)) { return }
    foreach ($it in $targets) { $it.Status = 'Pending'; $it.Progress = -1; $it.Detail = ''; $it.LastLogged = -10 }
    Write-DownloadLog ('Starting {0} download(s) into {1}' -f $targets.Count, $dir)
    Update-DownloadList
    Step-DownloadQueue
}

function Step-DownloadQueue {
    if ($script:DlRun.Proc -or $script:DlRun.Fetch -or $script:DlRun.Finishing -or $script:DlPaused) { return }   # (finishing: the next starts after it, from Complete-DownloadItem)
    $next = $script:DlQueue | Where-Object { $_.Status -eq 'Pending' } | Select-Object -First 1
    if (-not $next) {
        $done = @($script:DlQueue | Where-Object Status -eq 'Done').Count
        $failed = @($script:DlQueue | Where-Object Status -eq 'Failed').Count
        Write-DownloadLog ('Queue finished: {0} done, {1} failed' -f $done, $failed)
        Set-Status ('Downloads finished: {0} done, {1} failed' -f $done, $failed)
        if ($script:DlRanSome) { $script:DlRanSome = $false; Show-AppNotification 'Downloads finished' ('{0} done, {1} failed' -f $done, $failed) $(if ($failed) { 'Warning' } else { 'Info' }) }
        Update-DownloadSummary
        return
    }
    # Options > Download rules > "Only download between": wait for it
    if (-not (Test-DownloadWindow)) {
        $w = (Get-AppSettings).DlWindow
        Write-DownloadLog "Waiting for the download hours ($w): $(@($script:DlQueue | Where-Object Status -eq 'Pending').Count) waiting"
        $next.Detail = "waits for $w"; Update-DownloadRow $next
        Start-DownloadWindowWait
        return
    }
    Start-DownloadItem $next
}

function Get-DownloadSnapshot([string] $Dir) {
    # every file and folder under the download folder (to tell what a download created)
    $h = @{}
    if ($Dir -and (Test-Path -LiteralPath $Dir)) {
        try {
            # .NET directly: about ten times faster than Get-ChildItem on a big library
            foreach ($x in (New-Object IO.DirectoryInfo($Dir)).EnumerateFileSystemInfos('*', [IO.SearchOption]::AllDirectories)) {
                $h[$x.FullName] = (($x.Attributes -band [IO.FileAttributes]::Directory) -ne 0)
            }
        } catch {
            # (a folder it may not read): the slow way, which skips it
            $h = @{}
            foreach ($x in Get-ChildItem -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue) { $h[$x.FullName] = [bool]$x.PSIsContainer }
        }
    }
    return $h
}

# ---- TV downloads in parts: pause, resume, and riding out a lost connection ----------------
# NRK's streams are made of short pieces (segments, a few seconds each). The app fetches them
# itself, a few at a time, into dltmp\<programme>, and checks each one. That makes a download
# resumable at any point: Pause keeps what is there, a dropped connection pauses it and it
# carries on by itself when the network is back (also after a restart), and a piece that
# arrives damaged is fetched again instead of ending up in the file. When all pieces are
# there, FFmpeg joins them into the MP4 (seconds, nothing re-encoded) and the usual finishing
# pass adds subtitles, chapters and the cover.
$script:DlTmpRoot = Join-Path $script:AppDataDir 'dltmp'
$script:DlPaused = $false          # the queue is paused (Pause button)
$script:DlResumeTimer = $null

function Get-DownloadTmpDir($Item) {
    $id = if ($Item.File -and $Item.File.Id) { [string]$Item.File.Id } else { [string]$Item.Url }
    return Join-Path $script:DlTmpRoot ('{0}-{1}' -f $Item.Kind, ((Get-SafeFileName $id) -replace '\s', '_'))
}

function Read-MediaPlaylist([string] $Url) {
    # the list of pieces of one quality: @{ Segments; Init; Target; Unsupported }
    $wc = New-Object System.Net.WebClient; $wc.Headers['User-Agent'] = $script:UserAgent; $wc.Encoding = [Text.Encoding]::UTF8
    try { $text = $wc.DownloadString($Url) } finally { $wc.Dispose() }
    $res = @{ Segments = New-Object System.Collections.Generic.List[object]; Init = $null; Target = 10; Unsupported = $null }
    if ($text -match '#EXT-X-STREAM-INF') { $res.Unsupported = 'a list of qualities, not pieces'; return $res }
    if ($text -match '#EXT-X-KEY:METHOD=(?!NONE)') { $res.Unsupported = 'encrypted pieces'; return $res }
    if ($text -match '#EXT-X-BYTERANGE') { $res.Unsupported = 'byte ranges'; return $res }
    $base = [Uri]$Url
    $dur = 0.0
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match '^#EXT-X-TARGETDURATION:(\d+)') { $res.Target = [int]$Matches[1] }
        elseif ($l -match '^#EXT-X-MAP:.*URI="([^"]+)"') { $res.Init = [string](New-Object Uri($base, $Matches[1])) }
        elseif ($l -match '^#EXTINF:([\d.]+)') { $dur = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
        elseif ($l -and -not $l.StartsWith('#')) { $res.Segments.Add([pscustomobject]@{ Uri = [string](New-Object Uri($base, $l.Trim())); Dur = $dur }); $dur = 0.0 }
    }
    if ($res.Segments.Count -eq 0) { $res.Unsupported = 'no pieces listed' }
    return $res
}

function Test-SegmentFile([string] $Path, [string] $Ext) {
    # a whole transport-stream piece: a multiple of 188 bytes, each starting with the sync byte 0x47
    try {
        $fi = New-Object IO.FileInfo($Path)
        if (-not $fi.Exists -or $fi.Length -lt 188) { return $false }
        if ($Ext -ne '.ts') { return $true }
        if ($fi.Length % 188 -ne 0) { return $false }
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 1
            foreach ($pos in @(0L, [long](188 * [Math]::Floor($fi.Length / 188 / 2)), ($fi.Length - 188))) {
                [void]$fs.Seek($pos, 'Begin'); if ($fs.Read($buf, 0, 1) -ne 1 -or $buf[0] -ne 0x47) { return $false }
            }
        } finally { $fs.Dispose() }
        return $true
    } catch { return $false }
}

function Start-SegmentFetch($Item, $Plan) {
    # returns $true when the download runs in pieces, $false to let FFmpeg read the stream itself
    $src = $Plan.Source
    if (-not $src.VideoUrl) { return $false }
    $tracks = if ($Plan.AudioOnly) { @(@{ Name = 'a'; Url = $src.VideoUrl }) } else { @(@{ Name = 'v'; Url = $src.VideoUrl }) }   # (radio: the one track is sound)
    if ($src.AudioUrl -and -not $Plan.AudioOnly) { $tracks += @{ Name = 'a'; Url = $src.AudioUrl } }
    foreach ($t in $tracks) {
        $t.List = Read-MediaPlaylist $t.Url
        if ($t.List.Unsupported) { Write-Log INFO "Download in pieces not possible ($($t.List.Unsupported)): FFmpeg reads the stream"; return $false }
    }
    $dir = Get-DownloadTmpDir $Item
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # pieces from an earlier try are kept only if they belong to the same list
    $sig = ($tracks | ForEach-Object { '{0}:{1}' -f $_.Name, $_.List.Segments.Count }) -join ','
    $state = Read-JsonFile (Join-Path $dir 'state.json')
    if ($state -and [string]$state.Sig -ne $sig) { Get-ChildItem -LiteralPath $dir -File | Remove-Item -Force -ErrorAction SilentlyContinue }
    Write-JsonFile (Join-Path $dir 'state.json') ([ordered]@{ Sig = $sig; Title = $Item.Title; Started = (Get-Date).ToString('o') })
    $jobs = New-Object System.Collections.Generic.List[object]
    $have = 0; $total = 0
    foreach ($t in $tracks) {
        $ext = '.ts'
        $first = [string]$t.List.Segments[0].Uri
        if ($first -match '\.(m4s|mp4|aac|m4a)(\?|$)') { $ext = '.' + $Matches[1] }
        $t.Ext = $ext
        $t.Files = New-Object System.Collections.Generic.List[string]
        if ($t.List.Init) {
            $f = Join-Path $dir ('{0}_init.mp4' -f $t.Name); $t.InitFile = $f; $total++
            if (Test-Path -LiteralPath $f) { $have++ } else { $jobs.Add(@{ Uri = $t.List.Init; File = $f; Ext = '.mp4'; Tries = 0; NotBefore = [datetime]::MinValue }) }
        }
        for ($i = 0; $i -lt $t.List.Segments.Count; $i++) {
            $f = Join-Path $dir ('{0}_{1:D5}{2}' -f $t.Name, $i, $ext); $t.Files.Add($f); $total++
            if (Test-SegmentFile $f $ext) { $have++ } else { $jobs.Add(@{ Uri = $t.List.Segments[$i].Uri; File = $f; Ext = $ext; Tries = 0; NotBefore = [datetime]::MinValue }) }
        }
    }
    $run = $script:DlRun
    $par = [Math]::Max(1, [Math]::Min(6, [int](Get-AppSettings).DlParallel))
    $run.Fetch = @{ Item = $Item; Plan = $Plan; Dir = $dir; Tracks = $tracks; Jobs = $jobs; Active = New-Object System.Collections.ArrayList
                    Done = $have; Total = $total; Bytes = 0L; StartBytes = 0L; Parallel = $par; Started = (Get-Date); StartDone = $have }
    if ($have) { Write-DownloadLog ("Resuming: {0} of {1} pieces were already here" -f $have, $total) }
    else { Write-DownloadLog ("Downloading {0} pieces, {1} at a time" -f $total, $par) }
    return $true
}

function Update-SegmentFetch {
    $run = $script:DlRun; $f = $run.Fetch; $it = $f.Item
    $now = Get-Date
    foreach ($j in @($f.Active)) {
        $t = $j.Task
        if (-not $t.IsCompleted) {
            if (($now - $j.Since).TotalSeconds -gt 60) { try { $j.Client.CancelAsync() } catch { } }   # no answer: try again
            continue
        }
        [void]$f.Active.Remove($j)
        try { $j.Client.Dispose() } catch { }
        $part = "$($j.File).part"
        if (-not $t.IsFaulted -and -not $t.IsCanceled -and (Test-SegmentFile $part $j.Ext)) {
            Move-Item -LiteralPath $part -Destination $j.File -Force
            $f.Done++; try { $f.Bytes += (New-Object IO.FileInfo($j.File)).Length } catch { }
            $f.LastOk = $now
            continue
        }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        $why = if ($t.IsFaulted) { $t.Exception.GetBaseException().Message } elseif ($t.IsCanceled) { 'no answer for 60 s' } else { 'damaged piece' }
        $j.Tries++
        if ($j.Tries -le 5) {
            $wait = @(2, 5, 10, 20, 30)[$j.Tries - 1]
            $j.NotBefore = $now.AddSeconds($wait)
            Write-Log WARN ("Download piece {0}: {1} - trying again in {2} s" -f (Split-Path -Leaf $j.File), $why, $wait)
            $f.Jobs.Insert(0, $j)
        } else {
            # five times in a row: the connection is gone (or NRK is) - pause, keep everything
            Write-DownloadLog "Connection problem ($why): pausing; it continues by itself when the connection is back"
            Suspend-SegmentFetch -Reason 'connection lost' -Auto
            return
        }
    }
    # start more pieces (Options > Download rules > speed limit: one at a time, and only while under the limit)
    $limit = [int](Get-AppSettings).DlSpeedKB
    $par = $f.Parallel
    if ($limit -gt 0) {
        $par = 1
        $secs = [Math]::Max(1, ($now - $f.Started).TotalSeconds)
        if ((($f.Bytes - [double]$f.StartBytes) / $secs) -gt $limit * 1KB) { $par = 0 }
    }
    while ($f.Active.Count -lt $par -and $f.Jobs.Count -gt 0) {
        $next = $null
        for ($k = 0; $k -lt $f.Jobs.Count; $k++) { if ($f.Jobs[$k].NotBefore -le $now) { $next = $f.Jobs[$k]; $f.Jobs.RemoveAt($k); break } }
        if (-not $next) { break }
        $wc = New-Object System.Net.WebClient; $wc.Headers['User-Agent'] = $script:UserAgent
        $next.Client = $wc; $next.Since = $now
        $next.Task = $wc.DownloadFileTaskAsync([Uri]$next.Uri, "$($next.File).part")
        [void]$f.Active.Add($next)
    }
    # progress (the last 3 % are joining and finishing)
    $it.Progress = [Math]::Min(97, 97.0 * $f.Done / [Math]::Max(1, $f.Total))
    $el = ($now - $f.Started).TotalSeconds; $got = $f.Done - $f.StartDone
    if ($got -gt 2 -and $el -gt 3) { $left = $el / $got * ($f.Total - $f.Done); $it.Eta = '{0}:{1:D2}:{2:D2}' -f [int][Math]::Floor($left / 3600), ([int][Math]::Floor($left / 60) % 60), ([int]$left % 60) }
    $it.Detail = '{0} of {1} pieces  ·  {2:N0} MB' -f $f.Done, $f.Total, ($f.Bytes / 1MB)
    Update-DownloadRow $it
    if ($f.Active.Count -eq 0 -and $f.Jobs.Count -eq 0) { Start-SegmentJoin }
}

function Start-SegmentJoin {
    # every piece is here: FFmpeg joins them (local files, seconds) into the .part.mp4
    $run = $script:DlRun; $f = $run.Fetch; $it = $f.Item; $plan = $f.Plan
    $inputs = @(); $maps = @()
    $idx = 0
    foreach ($t in $f.Tracks) {
        $pl = Join-Path $f.Dir ('{0}.m3u8' -f $t.Name)
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append("#EXTM3U`n#EXT-X-VERSION:7`n#EXT-X-PLAYLIST-TYPE:VOD`n#EXT-X-TARGETDURATION:$($t.List.Target)`n")
        if ($t.InitFile) { [void]$sb.Append(('#EXT-X-MAP:URI="{0}"' -f (Split-Path -Leaf $t.InitFile)) + "`n") }
        for ($i = 0; $i -lt $t.Files.Count; $i++) {
            [void]$sb.Append(('#EXTINF:{0},' -f ([double]$t.List.Segments[$i].Dur).ToString([Globalization.CultureInfo]::InvariantCulture)) + "`n" + (Split-Path -Leaf $t.Files[$i]) + "`n")
        }
        [void]$sb.Append("#EXT-X-ENDLIST`n")
        [IO.File]::WriteAllText($pl, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
        $inputs += @('-allowed_extensions', 'ALL', '-protocol_whitelist', 'file,crypto,data', '-i', $pl)
        $maps += @('-map', $(if ($t.Name -eq 'v') { "$($idx):v:0" } else { "$($idx):a:0" }))
        if ($t.Name -eq 'v' -and $f.Tracks.Count -eq 1) { $maps += @('-map', "$($idx):a:0?") }
        $idx++
    }
    $run.Fetch = $null; $run.Joining = $true
    Write-DownloadLog $(if ($plan.Kind -eq 'radio') { 'All pieces are here: joining them' } else { 'All pieces are here: joining them into the MP4' })
    $argv = @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error') + $inputs + $maps + @('-c', 'copy', '-movflags', '+faststart', '-f', 'mp4', $plan.Part)
    try {
        Start-DownloadProcess $it (Find-FFmpeg).Path $argv $run.Dir
        $run.Joining = $true
        $it.Detail = 'Joining the pieces'; $it.Progress = 97; Update-DownloadRow $it
    } catch {
        # the pieces stay: Download again joins them without fetching anything
        Write-LogException $_ 'Joining the pieces'
        $it.Status = 'Failed'; $it.Detail = "joining failed: $($_.Exception.Message)"
        $run.Item = $null; $run.Joining = $false; Set-DownloadRunning $null
        Update-DownloadRow $it; Step-DownloadQueue
    }
}

function Suspend-SegmentFetch {
    # stops fetching but keeps every piece: Resume (or a restart) continues from there
    param([string] $Reason = 'paused', [switch] $Auto, [switch] $Quiet)
    $run = $script:DlRun; $f = $run.Fetch
    if (-not $f) { return }
    foreach ($j in @($f.Active)) { try { $j.Client.CancelAsync() } catch { }; try { $j.Client.Dispose() } catch { }; Remove-Item -LiteralPath "$($j.File).part" -Force -ErrorAction SilentlyContinue }
    $it = $f.Item
    $it.Status = 'Paused'; $it.AutoResume = [bool]$Auto
    $it.Detail = '{0}  ·  {1} of {2} pieces kept' -f $Reason, $f.Done, $f.Total
    $run.Fetch = $null; $run.Item = $null
    if ($run.Timer) { $run.Timer.Stop() }
    Set-DownloadRunning $null
    if (-not $Quiet) { Write-DownloadLog ("Paused: {0} ({1})" -f $it.Title, $Reason) }
    Update-DownloadRow $it
    Update-DownloadSummary
    if ($Auto) { Start-DownloadAutoResume } elseif (-not $script:DlPaused) { Step-DownloadQueue }
}

function Start-DownloadAutoResume {
    # every 30 s: is the connection back? then carry on
    if (-not (Get-AppSettings).DlAutoResume) { return }
    if (-not $script:DlResumeTimer) {
        $script:DlResumeTimer = New-Object System.Windows.Forms.Timer
        $script:DlResumeTimer.Interval = 30000
        $script:DlResumeTimer.Add_Tick({
            $waiting = @($script:DlQueue | Where-Object { $_.Status -eq 'Paused' -and $_.AutoResume })
            if (-not $waiting.Count) { $script:DlResumeTimer.Stop(); return }
            if ($script:DlRun.Proc -or $script:DlRun.Fetch -or $script:DlRun.Finishing -or $script:DlPaused) { return }
            if (-not [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) { return }
            Write-DownloadLog 'The connection seems to be back: continuing'
            foreach ($w in $waiting) { $w.Status = 'Pending'; $w.AutoResume = $false }
            Update-DownloadList
            Step-DownloadQueue
        })
    }
    $script:DlResumeTimer.Start()
}

function Suspend-DownloadQueue {
    # Pause button: the current download keeps its pieces, nothing new starts
    $script:DlPaused = $true
    $run = $script:DlRun
    if ($run.Fetch) { Suspend-SegmentFetch -Reason 'paused' }
    elseif ($run.Proc) { Write-DownloadLog 'This download cannot be paused half-way (it is being joined, or is a podcast MP3): the queue pauses after it' }
    Write-DownloadLog 'Queue paused'
    Update-DownloadSummary
}

function Resume-DownloadQueue {
    $script:DlPaused = $false
    foreach ($q in $script:DlQueue) { if ($q.Status -eq 'Paused') { $q.Status = 'Pending'; $q.AutoResume = $false } }
    Write-DownloadLog 'Queue resumed'
    Update-DownloadList
    Step-DownloadQueue
}

function Start-DownloadProcess($Item, [string] $exe, [string[]] $argv, [string] $dir, [string] $RecordDir = $dir) {
    # runs FFmpeg hidden; its output is read by Update-DownloadRun
    $run = $script:DlRun
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = ConvertTo-ArgString $argv
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $psi.WorkingDirectory = $dir
        Write-DownloadLog ('> "{0}" {1}' -f $exe, $psi.Arguments)
        $p = [System.Diagnostics.Process]::Start($psi)
        Add-ProcessToJob $p           # ends with the app, however the app ends
        Set-DownloadRunning $Item $RecordDir
        $run.Item = $Item; $run.Proc = $p; $run.Cancel = $null; $run.CancelAt = $null; $run.Noise = 0
        $run.Out = $p.StandardOutput; $run.Err = $p.StandardError
        $run.OutTask = $run.Out.ReadLineAsync(); $run.ErrTask = $run.Err.ReadLineAsync()
        $Item.Detail = ''
        Update-DownloadRow $Item
        if (-not $run.Timer) {
            $run.Timer = New-Object System.Windows.Forms.Timer
            $run.Timer.Interval = 200
            $run.Timer.Add_Tick({ Update-DownloadRun })
        }
        $run.Timer.Start()
}

function Start-DownloadItem($Item) {
    $run = $script:DlRun
    $dir = Get-CurrentDownloadDir -Radio:($Item.Kind -eq 'radio')
    $num = $script:DlQueue.IndexOf($Item) + 1
    $Item.Status = 'Downloading'; $Item.Progress = -1; $Item.Detail = 'Starting'
    Update-DownloadRow $Item
    Write-DownloadLog ('---- #{0} {1}' -f $num, $Item.Title)
    $run.Duration = 0
    $run.Dir = $dir                  # this download's folder, whatever the box says later
    $run.Started = Get-Date; $Item.Eta = $null
    $run.Before = Get-DownloadSnapshot $dir
    try {
        $run.Plan = $null
        if ($Item.Kind -eq 'tv') {
            $plan = Get-TvDownloadPlan $Item.File $dir
            foreach ($done in @($plan.Out, "$($plan.Base).mp4", "$($plan.Base).mkv", "$($plan.Base).m4v")) {   # (either format; .m4v: downloaded by an older version)
                if (-not $Item.Force -and (Test-Path -LiteralPath $done)) {
                    Write-DownloadLog "Already downloaded: $done"
                    $Item.Status = 'Done'; $Item.Progress = 100; $Item.Detail = 'already downloaded'; $Item.Files = @($done)
                    Update-DownloadRow $Item
                    Step-DownloadQueue
                    return
                }
            }
            New-Item -ItemType Directory -Path $plan.Folder -Force | Out-Null
            if (-not (Test-DownloadSpace $Item $plan.Folder ([double]$plan.Stream.Duration))) { Update-DownloadRow $Item; Update-DownloadSummary; return }
            $run.Plan = $plan; $run.Duration = [double]$plan.Stream.Duration
            Write-DownloadLog "Quality: $($plan.Source.Label)"
            $piecesOk = $false
            try { $piecesOk = Start-SegmentFetch $Item $plan } catch { Write-Log WARN "Download in pieces: $($_.Exception.Message) - FFmpeg reads the stream" }
            if ($piecesOk) {
                # pieces: fetched by the app (pause/resume); FFmpeg only joins them at the end
                Set-DownloadRunning $Item $dir
                $run.Item = $Item; $run.Cancel = $null; $run.CancelAt = $null; $run.Noise = 0; $run.Joining = $false
                if (-not $run.Timer) { $run.Timer = New-Object System.Windows.Forms.Timer; $run.Timer.Interval = 200; $run.Timer.Add_Tick({ Update-DownloadRun }) }
                $run.Timer.Start()
                return
            }
            $exe = (Find-FFmpeg).Path
            # NRK's best quality, copied as it is (no re-encoding): FFmpeg picks the highest resolution and best audio
            # (-loglevel error -stats: only real problems and the progress line)
            $argv = @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-stats') + $plan.Source.Inputs + $plan.Source.Maps + @('-c', 'copy', '-movflags', '+faststart', '-f', 'mp4', $plan.Part)
        } else {
            $f = $Item.File
            $stream = Get-NrkAudioStream -ManifestPath $Item.Url
            if (-not $stream.Playable -or -not $stream.Url) { throw ("not available: {0}" -f $(if ($stream.Reason) { $stream.Reason } else { 'no stream' })) }
            try { if ($stream.Duration) { $run.Duration = [Xml.XmlConvert]::ToTimeSpan($stream.Duration).TotalSeconds } } catch { }
            $srcExt = if ($stream.Format -match 'MP3' -or $stream.Url -match '\.mp3(\?|$)') { 'mp3' } else { 'm4a' }
            # Options > Downloads > Radio format: as NRK sends it (no quality loss), MP3 or FLAC
            $fmt = [string](Get-AppSettings).RadioFormat
            $ext = switch ($fmt) { 'mp3' { 'mp3' } 'flac' { 'flac' } default { $srcExt } }
            $codec = if ($ext -eq $srcExt) { @('-c', 'copy') }
                     elseif ($ext -eq 'mp3') { @('-c:a', 'libmp3lame', '-b:a', '320k', '-id3v2_version', '3') }   # (converted: the highest MP3 bitrate)
                     else { @('-c:a', 'flac', '-compression_level', '8') }
            $folder = Join-Path $dir (Get-SafeFileName $(if ($f.SeriesTitle) { $f.SeriesTitle } else { 'NRK Radio' }))
            $out = Join-Path $folder ((Get-RadioFileName $f) + ".$ext")   # (2.9.0: the name template, Options > Download rules)
            $had = if ($Item.Force) { $null } else { Find-ExistingDownload $f (Get-CurrentDownloadDir) }   # (in any of the formats; "Download again": fetch it anyway)
            if ($had) { $out = $had }
            if (-not $Item.Force -and (Test-Path -LiteralPath $out)) {
                Write-DownloadLog "Already downloaded: $out"
                $Item.Status = 'Done'; $Item.Progress = 100; $Item.Detail = 'already downloaded'; $Item.Files = @($out)
                Update-DownloadRow $Item
                Step-DownloadQueue
                return
            }
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            if (-not (Test-DownloadSpace $Item $folder ([double]$run.Duration))) { Update-DownloadRow $Item; Update-DownloadSummary; return }
            $exe = (Find-FFmpeg).Path
            if ($ext -ne $srcExt) { Write-DownloadLog ("Converting to {0} (Options > Downloads > Radio format)" -f $ext.ToUpper()) }
            $meta = @('-metadata', "title=$($f.Title)", '-metadata', "album=$($f.SeriesTitle)", '-metadata', "artist=$(if ($f.SeriesTitle) { $f.SeriesTitle } else { 'NRK' })",
                      '-metadata', 'comment=NRK Radio  ·  downloaded with NRK Browser', '-metadata', 'copyright=NRK')
            if ($f.Date -match '^(\d\d)\.(\d\d)\.(\d{4})$') { $meta += @('-metadata', ('date={0}-{1}-{2}' -f $Matches[3], $Matches[2], $Matches[1])) }
            if ($f.Description) { $meta += @('-metadata', "description=$($f.Description)") }
            if ($srcExt -eq 'm4a') {
                # NRK's HLS radio: in pieces like TV (Pause / Resume, continues after a lost connection or a restart)
                $base = [IO.Path]::Combine([IO.Path]::GetDirectoryName($out), [IO.Path]::GetFileNameWithoutExtension($out))
                $rplan = [pscustomobject]@{ Kind = 'radio'; Source = (Select-HlsVariant $stream.Url); Folder = $folder; Base = $base; Out = $out; Part = "$base.part.m4a"; Ext = $ext
                                            Codec = $(if ($ext -eq 'm4a') { @('-c:a', 'copy') } else { $codec }); Meta = $meta; Poster = $(if ($f.SquareUrl) { $f.SquareUrl } else { $f.ImageUrl })
                                            Stream = [pscustomobject]@{ Duration = $run.Duration; Subtitles = @(); Chapters = @() }; AudioOnly = $true }
                $rplan.Source.AudioUrl = $null
                $piecesOk = $false
                try { $piecesOk = Start-SegmentFetch $Item $rplan } catch { Write-Log WARN "Radio in pieces: $($_.Exception.Message) - FFmpeg reads the stream" }
                if ($piecesOk) {
                    $run.Plan = $rplan
                    Set-DownloadRunning $Item $dir
                    $run.Item = $Item; $run.Cancel = $null; $run.CancelAt = $null; $run.Noise = 0; $run.Joining = $false
                    if (-not $run.Timer) { $run.Timer = New-Object System.Windows.Forms.Timer; $run.Timer.Interval = 200; $run.Timer.Add_Tick({ Update-DownloadRun }) }
                    $run.Timer.Start()
                    return
                }
            }
            # -loglevel error -stats: the progress line and real problems only (not a line for every piece of the stream)
            $argv = @('-hide_banner', '-nostdin', $(if ($Item.Force) { '-y' } else { '-n' }), '-loglevel', 'error', '-stats', '-i', $stream.Url, '-vn') + $codec + @(
                      '-metadata', "title=$($f.Title)", '-metadata', "album=$($f.SeriesTitle)", '-metadata', "artist=$(if ($f.SeriesTitle) { $f.SeriesTitle } else { 'NRK' })",
                      '-metadata', 'comment=NRK Radio  ·  downloaded with NRK Browser', '-metadata', 'copyright=NRK')
            if ($f.Date -match '^(\d\d)\.(\d\d)\.(\d{4})$') { $argv += @('-metadata', ('date={0}-{1}-{2}' -f $Matches[3], $Matches[2], $Matches[1])) }
            if ($f.Description) { $argv += @('-metadata', "description=$($f.Description)") }
            if ($ext -eq 'm4a') { $argv += @('-movflags', '+faststart') }
            $argv += $out
        }
        Start-DownloadProcess $Item $exe $argv $dir $(if ($Item.Kind -eq 'tv') { $dir } else { $folder })
    } catch {
        Write-LogException $_ "Download #$num"
        Write-DownloadLog "Could not start: $($_.Exception.Message)"
        $Item.Status = 'Failed'; $Item.Detail = $_.Exception.Message
        $run.Item = $null; $run.Proc = $null
        Update-DownloadRow $Item
        Step-DownloadQueue
    }
}

function Add-DownloadOutput([string] $Line) {
    $run = $script:DlRun; $it = $run.Item
    $clean = ($Line -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', '' -replace '\x1b[()][0-9A-B]', '' -replace '[\x00-\x08\x0b-\x1f]', '').Trim()
    if (-not $clean) { return }
    # FFmpeg's notes about single damaged packets in NRK's stream: harmless, counted instead of shown
    # ("Opening ... for reading" is FFmpeg fetching the next piece: not damage, and not worth a log line)
    if ($clean -match 'Opening .* for reading') { return }
    if ($clean -match 'Packet corrupt|corrupt input packet|corrupt decoded frame|non-existing PPS|PES packet size mismatch|Skip \(|Invalid timestamp|DTS .* out of order|discarding') { $run.Noise++; Write-Log DEBUG "ffmpeg: $clean"; return }
    $pct = $null
    # (from versions that downloaded TV with nrkdownload: its progress bar "<name> ━━━━╸---  8% 0:00:57")
    $bar = $null
    if ($it.Kind -eq 'tv' -and $clean -match '(\d{1,3}(?:\.\d)?)\s*%(?:\s+(\d+:\d\d(?::\d\d)?|-:--:--))?\s*$') { $bar = @($Matches[1], $Matches[2]) }   # (copy: the next -match replaces $Matches)
    if ($bar -and ($bar[1] -or $clean -match '[━─╸╺\-=#|]{3,}')) {
        $pct = [double]$bar[0]
        if ($bar[1] -match '^\d+:\d\d(:\d\d)?$') { $it.Eta = $bar[1] }
    }
    elseif ($it.Kind -eq 'tv' -and $clean -match '(?:━|─|╸|╺|\|).*?(\d{1,3}(?:\.\d)?)\s*%') { $pct = [double]$Matches[1] }
    elseif ($it.Kind -eq 'tv' -and $clean -match '^\S.{0,40}\s(\d{1,3})%\s') { $pct = [double]$Matches[1] }
    elseif ($run.Joining -and $clean -match 'time=') { return }   # (joining local pieces: the bar stays at 97 %)
    elseif ($clean -match 'time=(\d+):(\d\d):(\d\d(?:\.\d+)?)') {
        $secs = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [double]$Matches[3]
        if ($run.Duration -gt 0) {
            $pct = [Math]::Min(99.9, $secs / $run.Duration * 100)
            # time left from the speed so far
            $el = ((Get-Date) - $run.Started).TotalSeconds
            # (brackets: in PowerShell the comma binds before %, so "a, b % 60" would break the format)
            if ($pct -gt 1 -and $el -gt 3) { $left = $el / $pct * (100 - $pct); $it.Eta = '{0}:{1:D2}:{2:D2}' -f [int][Math]::Floor($left / 3600), ([int][Math]::Floor($left / 60) % 60), ([int]$left % 60) }
        } else { $it.Detail = 'Downloading  ' + $Matches[0] }
        if ($null -eq $pct) { Update-DownloadRow $it; return }
    }
    if ($null -ne $pct) {
        $it.Progress = [Math]::Min(100, $pct)
        # (the bars show the progress; the log only notes every 25 %)
        if ($it.Progress - $it.LastLogged -ge 25 -or ($it.Progress -ge 100 -and $it.LastLogged -lt 100)) {
            $it.LastLogged = [Math]::Floor($it.Progress / 25) * 25
            if ($it.LastLogged -gt 0) { Write-Log DL ('{0}: {1:N0}%' -f $it.Title, $it.Progress) }
        }
        Update-DownloadRow $it
        return
    }
    Write-DownloadLog ('   ' + $clean)
}

function Update-DownloadRun {
    $run = $script:DlRun
    if ($run.Fetch) { try { Update-SegmentFetch } catch { Write-LogException $_ 'Download in pieces' }; return }
    if (-not $run.Proc) { $run.Timer.Stop(); return }
    foreach ($k in 'Out', 'Err') {
        $n = 0
        while ($run["${k}Task"] -and $run["${k}Task"].IsCompleted -and $n -lt 400) {
            $line = $null
            try { $line = $run["${k}Task"].Result } catch { $line = $null }
            if ($null -eq $line) { $run["${k}Task"] = $null; break }   # end of stream
            # read on first, then handle the line: a line that can't be handled must never stall the reading
            # (FFmpeg would stop when its output is not read, and Cancel would never finish)
            $run["${k}Task"] = $run[$k].ReadLineAsync()
            $n++
            try { Add-DownloadOutput $line } catch { Write-Log WARN "Download output line not understood ($($_.Exception.Message)): $line" }
        }
    }
    if ($run.Cancel -and $run.CancelAt) {
        # canceling must always finish: end the tool again if it is still there, and stop waiting
        # for its output once it has gone (a pipe can stay open after the process ended)
        $age = ((Get-Date) - $run.CancelAt).TotalSeconds
        $gone = $true; try { $gone = $run.Proc.HasExited } catch { }
        if (-not $gone -and $age -gt 3 -and -not $run.KilledAgain) {
            $run.KilledAgain = $true
            Write-DownloadLog 'Still running: ending it again'
            try { Stop-Process -Id $run.Proc.Id -Force -ErrorAction Stop } catch { }
            try { $run.Proc.Kill() } catch { }
        }
        if (($gone -and $age -gt 2) -or $age -gt 12) {
            if (-not $gone) { Write-DownloadLog 'The download tool did not answer; letting go of it' }
            $run.OutTask = $null; $run.ErrTask = $null
            Complete-DownloadItem
            return
        }
    }
    if ($run.OutTask -or $run.ErrTask -or -not $run.Proc.HasExited) { return }
    Complete-DownloadItem
}

function Complete-DownloadItem {
    $run = $script:DlRun; $it = $run.Item; $p = $run.Proc
    $run.Timer.Stop()
    $code = try { $p.ExitCode } catch { -1 }
    try { $p.Dispose() } catch { }
    $run.Proc = $null; $run.Item = $null; $run.OutTask = $null; $run.ErrTask = $null; $run.Joining = $false
    # TV: the quick second pass (subtitles, chapters, tags, cover) before counting the files
    $finishNote = $null
    if ($code -eq 0 -and -not $run.Cancel -and $run.Plan -and (Test-Path -LiteralPath $run.Plan.Part)) {
        $it.Detail = if ($run.Plan.Kind -eq 'radio') { 'Finishing (format, tags, cover)' } else { 'Finishing (subtitles, chapters, cover)' }; Update-DownloadRow $it
        $run.Finishing = $it; $run.FinishStop = $false; Update-DownloadSummary
        try {
            if ($run.Plan.Kind -eq 'radio') { $finishNote = Complete-RadioDownload $run.Plan $it }
            else { $finishNote = Complete-TvDownload $run.Plan $it; if ((Get-AppSettings).DlNfo -and -not $run.FinishStop) { try { Write-DownloadNfo $run.Plan $it } catch { Write-LogException $_ 'NFO' } } }
        } catch { Write-LogException $_ 'Finishing the download' }
        finally { $run.Finishing = $null }
    }
    Set-DownloadRunning $null

    # what did this download create?
    $after = Get-DownloadSnapshot $run.Dir
    $newFiles = @(); $newDirs = @()
    foreach ($k in $after.Keys) { if (-not $run.Before.ContainsKey($k)) { if ($after[$k]) { $newDirs += $k } else { $newFiles += $k } } }
    $it.Files = $newFiles; $it.Dirs = $newDirs

    if ($run.Cancel) {
        $it.Status = 'Canceled'
        Write-DownloadLog ('Canceled #{0} {1} ({2} partial file(s))' -f ($script:DlQueue.IndexOf($it) + 1), $it.Title, $newFiles.Count)
        $mode = $run.Cancel; $run.Cancel = $null
        Remove-Item -LiteralPath (Get-DownloadTmpDir $it) -Recurse -Force -ErrorAction SilentlyContinue
        # stop the rest of the queue
        foreach ($q in $script:DlQueue) { if ($q.Status -eq 'Pending') { $q.Status = 'Added' } }
        Update-DownloadList
        if ($mode -eq 'exit') { Remove-DownloadFiles $newFiles $newDirs; return }
        Invoke-DownloadCleanup $it
        return
    }
    if ($code -eq 0) { Remove-Item -LiteralPath (Get-DownloadTmpDir $it) -Recurse -Force -ErrorAction SilentlyContinue }   # the pieces are in the file now
    if ($code -eq 0) {
        $it.Status = 'Done'; $it.Progress = 100
        $it.Detail = if ($newFiles.Count -eq 0) { 'already downloaded' } elseif ($finishNote) { $finishNote } else { '' }
        Write-DownloadLog ('Done: {0}{1}' -f $it.Title, $(if ($newFiles.Count) { " ($($newFiles.Count) file(s))" } else { ' (nothing new: already downloaded)' }))
        if ($newFiles.Count) { try { Add-DlHistory $it } catch { } }
        $script:DlRanSome = $true
        if ($run.Noise -gt 0) { Write-DownloadLog ("   (FFmpeg skipped {0} damaged packet(s) in NRK's stream; this is normal and rarely visible)" -f $run.Noise) }
    } else {
        $it.Status = 'Failed'; $it.Detail = "exit code $code"
        Write-DownloadLog ('FAILED: {0} (exit code {1}) - see the output above' -f $it.Title, $code)
        # a half-written video would make the next try say "already downloaded"
        if ($newFiles.Count) { Write-DownloadLog 'Removing the unfinished files of this attempt'; Remove-DownloadFiles $newFiles $newDirs; $it.Files = @() }
    }
    Update-DownloadRow $it
    Step-DownloadQueue
}

function Remove-DownloadFiles([string[]] $Files, [string[]] $Dirs) {
    $n = 0
    foreach ($f in @($Files)) {
        if (-not $f) { continue }
        for ($try = 0; $try -lt 6; $try++) {
            try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction Stop; $n++ }; break }
            catch { if ($try -eq 5) { Write-DownloadLog "Could not delete ${f}: $($_.Exception.Message)" } else { Start-Sleep -Milliseconds 300 } }
        }
    }
    # folders this download created, deepest first, only when empty
    foreach ($d in @($Dirs | Sort-Object Length -Descending)) {
        try { if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $d -Force } } catch { }
    }
    if ($n) { Write-DownloadLog ('Deleted {0} file(s)' -f $n) }
}

function Show-ChoiceDialog {
    param($Owner, [string] $Title, [string] $Text, [string[]] $Buttons)
    $d = New-Object System.Windows.Forms.Form
    Set-AppIcon $d   # window, title bar and taskbar icon
    $d.Text = $Title; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'; $d.ClientSize = New-Object System.Drawing.Size(560, 210)
    $d.BackColor = $T.Bg; $d.ForeColor = $T.Text; $d.Font = $script:FontUi; $d.ShowInTaskbar = $false
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point(20, 18); $l.Size = New-Object System.Drawing.Size(520, 120)
    $d.Controls.Add($l)
    $result = @{ Index = -1 }
    $x = 540
    for ($i = $Buttons.Count - 1; $i -ge 0; $i--) {
        $b = New-FlatButton $Buttons[$i] 0 -Primary:($i -eq 0)
        $b.AutoSize = $true; $b.Tag = $i
        $d.Controls.Add($b)
        $b.Location = New-Object System.Drawing.Point(($x - $b.PreferredSize.Width), 156)
        $x -= $b.PreferredSize.Width + 10
        $b.Add_Click({ $script:ChoiceResult = [int]$this.Tag; $this.FindForm().Close() })
    }
    $script:ChoiceResult = -1
    Enable-DarkTitleBar $d
    if ($Owner) { [void]$d.ShowDialog($Owner) } else { $d.StartPosition = 'CenterScreen'; $d.TopMost = $true; [void]$d.ShowDialog() }
    $d.Dispose()
    $result.Index = $script:ChoiceResult
    return $result.Index
}

function Invoke-DownloadCleanup($Item) {
    # After a cancel: always remove the partial files, optionally everything this queue downloaded.
    $done = @($script:DlQueue | Where-Object { $_.Status -eq 'Done' -and @($_.Files).Count -gt 0 })
    $doneFiles = 0; foreach ($d in $done) { $doneFiles += @($d.Files).Count }
    $text = "The download of`n`n    $($Item.Title)`n`nwas canceled. What should happen with the downloaded files?`n`n" +
            "Keep completed: removes only the unfinished files of this download ($(@($Item.Files).Count)).`n" +
            "Remove all: also deletes the $doneFiles file(s) from the $($done.Count) completed download(s) in the queue."
    $choice = Show-ChoiceDialog -Owner $script:DlUi.Form -Title 'Download canceled' -Text $text -Buttons @('Keep completed', 'Remove all downloaded files')
    Write-Log INFO "Download cleanup choice: $choice"
    $files = @($Item.Files); $dirs = @($Item.Dirs)
    if ($choice -eq 1) {
        foreach ($d in $done) { $files += @($d.Files); $dirs += @($d.Dirs); $d.Status = 'Canceled'; $d.Progress = -1; $d.Detail = 'files removed'; $d.Files = @() }
    }
    # one pass, so folders shared by several downloads are removed once they are empty
    Remove-DownloadFiles $files $dirs
    $Item.Progress = -1; $Item.Detail = 'partial files removed'; $Item.Files = @()
    if ($choice -eq 1) { Write-DownloadLog 'Removed all files downloaded by this queue' }
    Update-DownloadList
}

function Stop-CurrentDownload([string] $Mode = 'ask') {
    $run = $script:DlRun
    if ($run.Fetch) {
        $it = $run.Fetch.Item
        if ($Mode -eq 'exit') { Suspend-SegmentFetch -Reason 'paused when the app closed' -Quiet; return }   # resumes next time
        # canceled while fetching pieces: nothing is in the download folder yet; drop the pieces
        Suspend-SegmentFetch -Reason 'canceled' -Quiet
        $it.Status = 'Canceled'; $it.Detail = ''; $it.Progress = -1
        Remove-Item -LiteralPath (Get-DownloadTmpDir $it) -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($q in $script:DlQueue) { if ($q.Status -eq 'Pending') { $q.Status = 'Added' } }
        Write-DownloadLog "Canceled: $($it.Title)"
        Update-DownloadList
        return
    }
    $p = $run.Proc
    if (-not $p) { return }
    if ($run.Cancel) { Write-DownloadLog 'Already canceling...'; return }   # (a second click changes nothing)
    $run.Cancel = $Mode; $run.CancelAt = Get-Date; $run.KilledAgain = $false
    Write-DownloadLog "Canceling #$($script:DlQueue.IndexOf($run.Item) + 1) $($run.Item.Title)..."
    $run.Item.Detail = 'Canceling'; Update-DownloadRow $run.Item
    # the whole process tree
    try { Start-Process -FilePath 'taskkill.exe' -ArgumentList '/PID', $p.Id, '/T', '/F' -WindowStyle Hidden -Wait } catch { }
    try { if (-not $p.HasExited) { $p.Kill() } } catch { }
    if ($Mode -eq 'exit') {
        try { [void]$p.WaitForExit(5000) } catch { }
        # drain synchronously; the timer won't run again
        while ($run.OutTask -or $run.ErrTask) { Update-DownloadRun; if ($run.Proc) { Start-Sleep -Milliseconds 50 } else { break } }
    }
}

function Stop-DownloadItems {
    # Cancel for the selected queue items
    $sel = Get-SelectedDownloadItems
    if ($script:DlRun.Finishing -and ($sel -contains $script:DlRun.Finishing)) {
        Write-DownloadLog "$($script:DlRun.Finishing.Title) is being finished (the download itself is done): it can't be canceled now"
        $sel = @($sel | Where-Object { $_ -ne $script:DlRun.Finishing })
    }
    $n = 0
    foreach ($it in $sel) {
        if ($it.Status -in 'Added', 'Pending') { $it.Status = 'Canceled'; $it.Detail = ''; $n++ }
        elseif ($it.Status -eq 'Paused' -and $it -ne $script:DlRun.Item) {
            Remove-Item -LiteralPath (Get-DownloadTmpDir $it) -Recurse -Force -ErrorAction SilentlyContinue   # what it saved so far
            $it.Status = 'Canceled'; $it.Detail = ''; $it.Progress = -1; $n++
        }
    }
    if ($n) { Write-DownloadLog ('Canceled {0} file(s) that were not downloading' -f $n); Request-QueueSave }
    Update-DownloadList
    if ($script:DlRun.Item -and ($sel -contains $script:DlRun.Item)) { Stop-CurrentDownload }
}

function Show-DownloadsWindow {
    $ui = $script:DlUi
    if ($ui -and -not $ui.Form.IsDisposed) {
        if (-not $ui.Form.Visible) { $ui.Form.Show($form); Enable-DarkTitleBar $ui.Form }
        if ($ui.Form.WindowState -eq 'Minimized') { $ui.Form.WindowState = 'Normal' }
        $ui.Form.Activate()
        return
    }
    Write-Log INFO 'UI: opened Downloads window'
    $w = New-Object System.Windows.Forms.Form
    Set-AppIcon $w   # window, title bar and taskbar icon
    $w.Text = 'Downloads - NRK Browser'
    $w.Size = New-Object System.Drawing.Size(1080, 720)
    $w.MinimumSize = New-Object System.Drawing.Size(760, 480)
    $w.StartPosition = 'CenterParent'
    $w.Font = $script:FontUi; $w.BackColor = $T.Bg; $w.ForeColor = $T.Text
    $w.KeyPreview = $true

    # side panel (like the Logs window): the buttons. The download folders are set in Options > Downloads.
    $side = New-Object System.Windows.Forms.Panel
    $side.Dock = 'Left'; $side.Width = 210; $side.BackColor = $T.Panel
    $side.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)
    $sideItems = New-Object System.Collections.Generic.List[object]
    $mk = {
        param([string] $Text, [switch] $Primary)
        $b = New-FlatButton $Text 0 -Primary:$Primary
        $b.AutoSize = $false; $b.Dock = 'Top'; $b.Height = 36; $b.TextAlign = 'MiddleLeft'
        $b.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
        $sideItems.Add($b)
        $gap = New-Object System.Windows.Forms.Panel; $gap.Dock = 'Top'; $gap.Height = 8; $gap.BackColor = $T.Panel
        $sideItems.Add($gap)
        return $b
    }
    $sepMk = { param([int] $H = 14) $sp = New-Object System.Windows.Forms.Panel; $sp.Dock = 'Top'; $sp.Height = $H; $sp.BackColor = $T.Panel; $sideItems.Add($sp) }
    $bSelAll = & $mk ("{0}  Select all" -f [char]0x2611)
    $bStart = & $mk ("{0}  Download selected" -f [char]0x2193) -Primary
    $bPause = & $mk ("{0}  Pause" -f [char]0x2016); $bPause.Tag = 'pause'
    & $sepMk
    $bCancel = & $mk ("{0}  Cancel selected" -f [char]0x2715); $bCancel.ForeColor = $T.Bad
    & $sepMk
    $bClear = & $mk ("{0}  Clear finished" -f [char]0x2713)
    $bClearNew = & $mk ("{0}  Clear not started" -f [char]0x2212)
    & $sepMk
    $bOpenTv = & $mk ("{0}  Open TV folder" -f [char]0x2197)
    $bOpenRadio = & $mk ("{0}  Open radio folder" -f [char]0x2197)
    # 2.9.2: icons in the chosen look
    Set-IconText $bSelAll 'selectall' 'Select all' ([string][char]0x2611)
    Set-IconText $bStart 'down' 'Download selected' ([string][char]0x2193) -Primary
    Set-IconText $bPause 'pause' 'Pause' ([string][char]0x2016)
    Set-IconText $bCancel 'cancel' 'Cancel selected' ([string][char]0x2715)
    Set-IconText $bClear 'check' 'Clear finished' ([string][char]0x2713)
    Set-IconText $bClearNew 'minus' 'Clear not started' ([string][char]0x2212)
    Set-IconText $bOpenTv 'folder' 'Open TV folder' ([string][char]0x2197)
    Set-IconText $bOpenRadio 'folder' 'Open radio folder' ([string][char]0x2197)
    $folderNote = New-Object System.Windows.Forms.Label; $folderNote.Dock = 'Top'; $folderNote.Height = 46; $folderNote.ForeColor = $T.Muted
    $folderNote.Text = 'The folders are set in Options > Downloads.'; $sideItems.Add($folderNote)
    # (Dock=Top stacks in reverse order of adding)
    for ($i = $sideItems.Count - 1; $i -ge 0; $i--) { $side.Controls.Add($sideItems[$i]) }

    # summary line above the queue
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Top'; $bar.Height = 40; $bar.BackColor = $T.Bg; $bar.Padding = New-Object System.Windows.Forms.Padding(16, 6, 16, 2)
    $summary = New-Object System.Windows.Forms.Label
    $summary.Dock = 'Fill'; $summary.TextAlign = 'MiddleLeft'; $summary.ForeColor = $T.Muted; $summary.AutoEllipsis = $true
    $bar.Controls.Add($summary)
    $line = New-Object System.Windows.Forms.Panel; $line.Dock = 'Top'; $line.Height = 1; $line.BackColor = $T.Border

    # queue (top) and output (bottom)
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'; $split.SplitterWidth = 5; $split.BackColor = $T.Border
    $split.Panel1.BackColor = $T.Bg; $split.Panel2.BackColor = $T.Bg
    $split.Panel1.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
    $split.Panel2.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 12)
    $list = New-QueueList
    $list.Dock = 'Fill'; $list.ShowItemToolTips = $true
    $split.Panel1.Controls.Add($list)
    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Dock = 'Fill'; $logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'; $logBox.WordWrap = $true
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9); $logBox.BackColor = $T.Surface; $logBox.ForeColor = $T.Text; $logBox.BorderStyle = 'None'
    $logBox.MaxLength = 0
    $logHdr = New-SectionLabel 'Output'
    # what is downloading now: name, a progress bar and the time left (PictureBox: drawn without flicker)
    $now = New-Object System.Windows.Forms.PictureBox
    $now.Dock = 'Top'; $now.Height = 50; $now.BackColor = $T.Bg; $now.Visible = $false
    $now.Add_Paint({ Invoke-DrawDownloadNow $args[1].Graphics $args[0] })
    $now.Add_Resize({ $args[0].Invalidate() })
    $split.Panel2.Controls.Add($logBox); $split.Panel2.Controls.Add($logHdr); $split.Panel2.Controls.Add($now)

    $w.Controls.Add($split); $w.Controls.Add($line); $w.Controls.Add($bar); $w.Controls.Add($side)

    # right-click menu for the queue
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Font = $script:FontUi; $menu.ShowImageMargin = $false
    if ($script:DarkRenderer) { $menu.Renderer = $script:DarkRenderer }
    $menu.BackColor = $T.Surface; $menu.ForeColor = $T.Text
    $mi = @{}
    foreach ($def in @(@('Download', 'Download'), @('Open', 'Open folder'), @('-', ''), @('Up', 'Move up    (Ctrl+Up)'), @('Down', 'Move down    (Ctrl+Down)'), @('Top', 'Move to top'), @('Bottom', 'Move to bottom'),
                       @('-', ''), @('Again', 'Download again'), @('Tags', 'Update tags and cover'),
                       @('-', ''), @('Cancel', 'Cancel'), @('Remove', 'Remove from list (keeps files)    (Del)'), @('Delete', 'Delete downloaded file...'))) {
        if ($def[0] -eq '-') { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); continue }
        $m = New-Object System.Windows.Forms.ToolStripMenuItem($def[1]); $m.ForeColor = $T.Text
        $m.Padding = New-Object System.Windows.Forms.Padding(4, 3, 4, 3)
        [void]$menu.Items.Add($m); $mi[$def[0]] = $m
    }
    $list.ContextMenuStrip = $menu

    $script:DlUi = @{ Form = $w; List = $list; Log = $logBox; Summary = $summary; Start = $bStart; SelAll = $bSelAll; Side = $side
                      Cancel = $bCancel; Clear = $bClear; Menu = $menu; MenuItems = $mi; Split = $split; Now = $now; Pause = $bPause; ClearNew = $bClearNew }

    $menu.Add_Opening({
        $sel = Get-SelectedDownloadItems
        $m = $script:DlUi.MenuItems
        $n = $sel.Count
        $m.Download.Text = if ($n -gt 1) { "Download ($n)" } else { 'Download' }
        $m.Download.Enabled = [bool](@($sel | Where-Object { $_.Status -in 'Added', 'Failed', 'Canceled', 'Paused' }).Count)
        $m.Download.Text = if (@($sel | Where-Object { $_.Status -eq 'Paused' }).Count -eq $n -and $n) { 'Resume' } elseif ($n -gt 1) { "Download ($n)" } else { 'Download' }
        $m.Open.Visible = ($n -eq 1 -and $sel[0].Status -eq 'Done')
        foreach ($k in 'Up', 'Down', 'Top', 'Bottom') { $m[$k].Enabled = ($n -gt 0) }
        $m.Cancel.Text = if ($n -gt 1) { "Cancel ($n)" } else { 'Cancel' }
        $m.Cancel.Enabled = [bool](@($sel | Where-Object { $_.Status -in 'Added', 'Pending', 'Downloading', 'Paused' }).Count)
        $m.Remove.Text = if ($n -gt 1) { "Remove $n from list (keeps files)    (Del)" } else { 'Remove from list (keeps files)    (Del)' }
        $doneSel = @($sel | Where-Object { $_.Status -eq 'Done' })
        $m.Again.Visible = ($doneSel.Count -gt 0); $m.Again.Text = if ($doneSel.Count -gt 1) { "Download $($doneSel.Count) again" } else { 'Download again' }
        $m.Tags.Visible = [bool]@($doneSel | Where-Object { $_.Kind -eq 'tv' }).Count
        $m.Delete.Visible = ($doneSel.Count -gt 0)
        $m.Delete.Text = if ($doneSel.Count -gt 1) { "Delete $($doneSel.Count) downloaded files..." } else { 'Delete downloaded file...' }
        $m.Remove.Enabled = ($n -gt 0)
        if ($n -eq 0) { $args[1].Cancel = $true }
    })
    $mi.Download.Add_Click({ Start-DownloadQueue -Items (Get-SelectedDownloadItems) })
    $mi.Again.Add_Click({
        # finished (or downloaded before): fetch it once more
        $sel = @(Get-SelectedDownloadItems | Where-Object { $_.Status -eq 'Done' })
        foreach ($it in $sel) { $it.Status = 'Added'; $it.Progress = -1; $it.Detail = ''; $it.Files = @(); $it.Force = $true }
        Update-DownloadList; Start-DownloadQueue -Items $sel
    })
    $mi.Tags.Add_Click({ Update-DownloadTags @(Get-SelectedDownloadItems) })
    $mi.Open.Add_Click({ $sel = Get-SelectedDownloadItems; if ($sel.Count -eq 1) { Open-DownloadedFile $sel[0] } })
    $mi.Up.Add_Click({ Move-DownloadItems up })
    $mi.Down.Add_Click({ Move-DownloadItems down })
    $mi.Top.Add_Click({ Move-DownloadItems top })
    $mi.Bottom.Add_Click({ Move-DownloadItems bottom })
    $mi.Cancel.Add_Click({ Stop-DownloadItems })
    $mi.Remove.Add_Click({ Remove-DownloadItems })
    $mi.Delete.Add_Click({ Remove-DownloadedFiles @(Get-SelectedDownloadItems | Where-Object { $_.Status -eq 'Done' }) })
    $bStart.Add_Click({
        $sel = @(Get-SelectedDownloadItems | Where-Object { $_.Status -in 'Added', 'Failed', 'Canceled', 'Paused' })
        if (-not $sel.Count) { [void][System.Windows.Forms.MessageBox]::Show($script:DlUi.Form, 'Select the downloads to start first (Shift/Ctrl+click, or Select all).', 'Download selected', 'OK', 'Information'); return }
        Start-DownloadQueue -Items $sel
    })
    # the teal button looks switched off like the others when there is nothing to start
    $bStart.Add_EnabledChanged({
        if ($this.Enabled) { $this.BackColor = $T.Accent; $this.ForeColor = $T.OnAccent; $this.FlatAppearance.MouseOverBackColor = $T.AccentHover }
        else { $this.BackColor = $T.Surface; $this.ForeColor = $T.Muted; $this.FlatAppearance.MouseOverBackColor = $T.Surface }
    })
    $bSelAll.Add_Click({ $l = $script:DlUi.List; $l.BeginUpdate(); foreach ($r in $l.Items) { $r.Selected = $true }; $l.EndUpdate(); $l.Focus() })
    $bCancel.Add_Click({
        # the same as right-click > Cancel: the selected downloads (the running one too, when it is selected)
        if (-not @(Get-SelectedDownloadItems).Count) { [void][System.Windows.Forms.MessageBox]::Show($script:DlUi.Form, 'Select the downloads to cancel first (Shift/Ctrl+click, or Select all).', 'Cancel selected', 'OK', 'Information'); return }
        Stop-DownloadItems
    })
    $bPause.Add_Click({ if ($this.Tag -eq 'pause') { Suspend-DownloadQueue } else { Resume-DownloadQueue } })
    $bClear.Add_Click({ Clear-FinishedDownloads })
    $bClearNew.Add_Click({ Clear-NotStartedDownloads })
    $bOpenTv.Add_Click({ $d = Resolve-DownloadFolder -Owner $script:DlUi.Form; if ($d) { Start-Process $d } })
    $bOpenRadio.Add_Click({ $d = Resolve-DownloadFolder -Radio -Owner $script:DlUi.Form; if ($d) { Start-Process $d } })
    $list.Add_DoubleClick({
        $sel = Get-SelectedDownloadItems
        if ($sel.Count -ne 1) { return }
        if ($sel[0].Status -eq 'Done') { Open-DownloadedFile $sel[0] }                       # finished: show it in its folder
        elseif ($sel[0].Status -in 'Added', 'Failed', 'Canceled', 'Paused') { Start-DownloadQueue -Items $sel }
    })
    $w.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Delete' -and $script:DlUi.List.Focused) { Remove-DownloadItems; $e.Handled = $true }
        elseif ($e.Control -and $e.KeyCode -eq 'Up') { Move-DownloadItems up; $e.Handled = $true }
        elseif ($e.Control -and $e.KeyCode -eq 'Down') { Move-DownloadItems down; $e.Handled = $true }
        elseif ($e.Control -and $e.KeyCode -eq 'A' -and $script:DlUi.List.Focused) { foreach ($r in $script:DlUi.List.Items) { $r.Selected = $true }; $e.Handled = $true }
    })
    $w.Add_FormClosing({
        param($s, $e)
        # closing only hides the window: downloads keep running, the queue is kept
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) { $e.Cancel = $true; $s.Hide() }
    })
    $w.Add_Shown({
        $ui = $script:DlUi
        try { $ui.Split.SplitterDistance = [int]($ui.Split.Height * 0.58) } catch { }
        $ui.Log.Text = $script:DlLogBuffer.ToString()
        $ui.Log.SelectionStart = $ui.Log.TextLength; $ui.Log.ScrollToCaret()
    })

    Update-DownloadList
    Enable-DarkTitleBar $w
    $w.Show($form)
    $side.BackColor = $T.Panel; foreach ($c in $side.Controls) { if ($c -is [System.Windows.Forms.Panel]) { $c.BackColor = $T.Panel } }
}

function Get-SelectedFiles {
    return @($itemsList.SelectedItems | ForEach-Object { $_.Tag } | Where-Object { $_ -and $_ -isnot [string] })
}

function Start-DownloadChecked {
    # Download button / menu: add the chosen scope to the download queue
    param([ValidateSet('auto', 'episode', 'season', 'series')] [string] $Scope = 'auto')
    $f = $script:SelectedFile
    $node = $folderTree.SelectedNode
    switch ($Scope) {
        'episode' { if ($f) { Add-ToDownloadQueue -Files @($f) } }
        'season'  { if ($node -and $node.Tag.Kind -in 'season', 'radioseason') { Add-ToDownloadQueue -Nodes @($node) } }
        'series'  {
            for ($n = $node; $n; $n = $n.Parent) { if ($n.Tag.Kind -in 'series', 'radioseries') { Add-ToDownloadQueue -Nodes @($n); return } }
        }
        'auto' {
            $sel = Get-SelectedFiles
            if ($sel.Count -gt 1) { Add-ToDownloadQueue -Files $sel }
            elseif ($f) { Add-ToDownloadQueue -Files @($f) }
            elseif ($node) { Add-ToDownloadQueue -Nodes @($node) }
        }
    }
}

#---- Logs window --------------------------------------------------------------
# Window state lives in script scope: WinForms event handlers run long after the
# function that built the window has returned, so they cannot see its locals.

$script:LogsUi = $null

$script:LogsAllDays = 'All days (merged)'
$script:LogsSession = 'This session'

function Get-LogsSelection {
    # the selected entry: 'session', 'merged' or a file path (the list shows only names; the path is in the title)
    $ui = $script:LogsUi
    $sel = [string]$ui.Combo.SelectedItem
    if ($sel -eq $script:LogsSession) { return 'session' }
    if ($sel -eq $script:LogsAllDays) { return 'merged' }
    if ($sel -and $ui.Paths.ContainsKey($sel)) { return $ui.Paths[$sel] }
    return $null
}

function Get-DayLogFiles {
    # this app's day-files, oldest first
    if (-not $script:LogDir -or -not (Test-Path -LiteralPath $script:LogDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:LogDir -Filter 'NRK-Browser_*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name)
}

function Read-MergedLog([int] $MaxBytes = 3MB) {
    # all days as one text, a marker line between days; only the newest $MaxBytes are read
    $files = Get-DayLogFiles
    $parts = New-Object System.Collections.Generic.List[string]
    $left = $MaxBytes
    for ($i = $files.Count - 1; $i -ge 0 -and $left -gt 0; $i--) {
        $f = $files[$i]
        $text = Read-LogTail -Path $f.FullName -MaxBytes $left
        $left -= $f.Length
        $day = if ($f.Name -match '_(\d{4}-\d{2}-\d{2})\.log$') { [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) } else { $f.LastWriteTime.Date }
        $parts.Insert(0, ('===== {0:yyyy-MM-dd} {1} =====' -f $day, $day.DayOfWeek) + "`r`n" + $text.TrimEnd() + "`r`n")
    }
    return ($parts -join "`r`n")
}

function Update-LogsView {
    # Only what is new is added (the text is not rebuilt every refresh); paused: nothing changes
    # until Resume, while the app keeps logging.
    param([bool] $Force)
    $ui = $script:LogsUi
    if (-not $ui -or $ui.Form.IsDisposed) { return }
    if ($ui.Paused -and -not $Force) { Update-LogsPauseButton; return }
    $sel = Get-LogsSelection
    if (-not $sel) { $ui.Box.Text = '(no log files found)'; return }
    $append = { param([string] $Text) if ($Text) { $ui.Box.AppendText($(if ($ui.Box.TextLength) { "`r`n" } else { '' }) + $Text.TrimEnd("`r", "`n")) } }
    try {
        if ($sel -ne $ui.ShownSel) { $Force = $true; $ui.ShownSel = $sel }
        if ($sel -eq 'session') {
            $mem = $script:LogMem
            $new = [int]$script:LogCount - [int]$ui.ShownCount
            if (-not $Force -and $new -le 0) { return }
            if ($Force -or $new -gt $mem.Count -or $ui.Box.Lines.Count -gt 7000) { $ui.Box.Text = ($mem -join "`r`n") }   # (all again: the first time, or when it got too long)
            else { & $append (($mem.GetRange($mem.Count - $new, $new)) -join "`r`n") }
            $ui.ShownCount = [int]$script:LogCount
            $ui.Form.Text = 'Logs - this session ({0} lines){1}' -f $mem.Count, $(if ($script:LogToDisk) { "  ·  saved in $($script:LogDir)" } else { '  ·  in memory only, not saved' })
        } elseif ($sel -eq 'merged') {
            # Only the newest day grows (also when the indexer writes to it): its new part is added.
            # An older day that changes (the indexer running past midnight) is shown again only when
            # the set of days changes or on Refresh, so the window doesn't reload megabytes every 1.5 s.
            $files = @(Get-DayLogFiles)
            $last = if ($files.Count) { $files[-1] } else { $null }
            $sig = ($files | ForEach-Object { $_.Name }) -join ';'
            $grew = [bool]($last -and $ui.LastFile -eq $last.FullName -and $last.Length -gt $ui.LastFileLen)
            if (-not $Force -and $sig -eq $ui.LastLength -and -not $grew) { return }
            if (-not $Force -and $sig -eq $ui.LastLength -and $grew -and $ui.LastFileLen -gt 0) { & $append (Read-LogFrom $last.FullName $ui.LastFileLen) }
            else { $ui.Box.Text = Read-MergedLog }
            $ui.LastLength = $sig; if ($last) { $ui.LastFile = $last.FullName; $ui.LastFileLen = $last.Length }
            $total = ($files | Measure-Object Length -Sum).Sum
            $ui.Form.Text = 'Logs - all days ({0} file(s), {1:N0} KB)  ·  {2}' -f $files.Count, ($total / 1KB), $script:LogDir
        } else {
            $len = (Get-Item -LiteralPath $sel).Length
            if (-not $Force -and "$len" -eq "$($ui.LastLength)") { return }
            $prev = 0L; [void][long]::TryParse([string]$ui.LastLength, [ref]$prev)
            if (-not $Force -and $prev -gt 0 -and $len -gt $prev) { & $append (Read-LogFrom $sel $prev) }
            else { $ui.Box.Text = Read-LogTail -Path $sel }
            $ui.LastLength = "$len"
            $ui.Form.Text = 'Logs - {0} ({1:N0} KB)' -f $sel, ($len / 1KB)
        }
        $ui.Box.SelectionStart = $ui.Box.TextLength
        $ui.Box.ScrollToCaret()
    } catch { $ui.Box.Text = "Could not read ${sel}: $($_.Exception.Message)" }
}

function Read-LogFrom([string] $Path, [long] $Offset) {
    # the part of a log file written after $Offset bytes
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$fs.Seek($Offset, 'Begin')
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        return $sr.ReadToEnd()
    } finally { $fs.Dispose() }
}

function Update-LogsPauseButton {
    $ui = $script:LogsUi
    if (-not $ui -or -not $ui.Pause) { return }
    if ($ui.Paused) {
        $waiting = [int]$script:LogCount - [int]$ui.PausedAt
        Set-IconText $ui.Pause 'play' ('Resume{0}' -f $(if ($waiting -gt 0) { "  ($waiting new)" } else { '' })) ([string][char]0x25B6)
        $ui.Pause.ForeColor = $T.Accent
    } else { Set-IconText $ui.Pause 'pause' 'Pause' ([string][char]0x2016); $ui.Pause.ForeColor = $T.Text }
}


function Update-LogsFileList {
    $ui = $script:LogsUi
    if (-not $ui -or $ui.Form.IsDisposed) { return }
    $current = [string]$ui.Combo.SelectedItem
    $files = @()
    foreach ($d in @($script:LogDir, (Join-Path $script:ScriptDir 'logs')) | Where-Object { $_ } | Select-Object -Unique) {   # older versions wrote next to the script
        if ($d -and (Test-Path -LiteralPath $d)) { $files += Get-ChildItem -LiteralPath $d -Filter '*.log' -File -ErrorAction SilentlyContinue }
    }
    $files = @($files | Sort-Object FullName -Unique | Sort-Object LastWriteTime -Descending)
    $ui.Paths = @{}
    $ui.Combo.BeginUpdate(); $ui.Combo.Items.Clear()
    [void]$ui.Combo.Items.Add($script:LogsSession)
    if ($files.Count) { [void]$ui.Combo.Items.Add($script:LogsAllDays) }
    foreach ($f in $files) {
        $name = $f.Name; $k = 2
        while ($ui.Paths.ContainsKey($name)) { $name = '{0} ({1})' -f $f.Name, $k; $k++ }   # (same name in two folders)
        $ui.Paths[$name] = $f.FullName
        [void]$ui.Combo.Items.Add($name)
    }
    $ui.Combo.EndUpdate()
    $ui.Combo.SelectedItem = if ($current -and $ui.Combo.Items.Contains($current)) { $current } elseif ($script:LogToDisk -and $files.Count) { $script:LogsAllDays } else { $script:LogsSession }
}

function Clear-LogFile {
    # Clear log: "All days (merged)" deletes every log file in the log folder; a single file
    # selected deletes just that one. The window is emptied as well.
    $ui = $script:LogsUi
    if (-not $ui) { return }
    $p = Get-LogsSelection
    if (-not $p) { return }
    if ($p -eq 'session') {
        if ([System.Windows.Forms.MessageBox]::Show($ui.Form, "Clear this session's log lines from memory?", 'Clear log', 'YesNo', 'Question') -ne 'Yes') { return }
        $script:LogMem.Clear(); $script:LogPending.Clear(); $ui.Box.Text = ''; $ui.ShownCount = [int]$script:LogCount; $ui.PausedAt = [int]$script:LogCount
        return
    }
    $all = ($p -eq 'merged')
    $targets = if ($all) {
        @(foreach ($d in @($script:LogDir, (Join-Path $script:ScriptDir 'logs')) | Where-Object { $_ } | Select-Object -Unique) {
            if (Test-Path -LiteralPath $d) { Get-ChildItem -LiteralPath $d -Filter '*.log' -File -ErrorAction SilentlyContinue | ForEach-Object FullName }
        })
    } else { @($p) }
    $targets = @($targets | Select-Object -Unique)
    if (-not $targets.Count) { $ui.Box.Text = ''; return }
    $what = if ($all) { "all {0} log file(s)" -f $targets.Count } else { "this log file`n`n$p" }
    $q = [System.Windows.Forms.MessageBox]::Show($ui.Form, "Delete ${what}?`n`nThis cannot be undone.", 'Clear log', 'YesNo', 'Warning')
    if ($q -ne 'Yes') { return }
    Close-LogWriter   # (what is collected goes in first, then the file goes)
    $gone = 0; $busy = @()
    foreach ($f in $targets) {
        try { [IO.File]::Delete($f); $gone++ }
        catch {
            # in use (the indexer or an installer writing to it): empty it instead
            try { $fs = New-Object IO.FileStream($f, 'Open', 'Write', 'ReadWrite'); $fs.SetLength(0); $fs.Dispose(); $gone++ } catch { $busy += (Split-Path -Leaf $f) }
        }
    }
    if ($all) { foreach ($d in @((Join-Path $script:LogDir 'responses'))) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } } }
    # empty window; it fills again only with what is logged from now on
    $ui.Suppress = $true
    try { Update-LogsFileList } finally { $ui.Suppress = $false }
    $ui.Box.Text = ''
    $files = Get-DayLogFiles
    $ui.ShownSel = Get-LogsSelection; $ui.LastFile = $null; $ui.LastFileLen = 0
    $ui.LastLength = if ($ui.ShownSel -eq 'merged') { ($files | ForEach-Object { $_.Name }) -join ';' } else { '0' }
    if ($ui.ShownSel -eq 'merged' -and @($files).Count) { $ui.LastFile = @($files)[-1].FullName; $ui.LastFileLen = @($files)[-1].Length }
    $ui.Form.Text = 'Logs - cleared'
    if ($busy.Count) { [void][System.Windows.Forms.MessageBox]::Show($ui.Form, "Could not delete (in use):`n`n$($busy -join "`n")", 'Clear log', 'OK', 'Information') }
}

function Show-LogsWindow {
    if ($script:LogsUi -and -not $script:LogsUi.Form.IsDisposed) { $script:LogsUi.Form.Activate(); return }
    Write-Log INFO 'UI: opened Logs window'

    $w = New-Object System.Windows.Forms.Form
    Set-AppIcon $w   # window, title bar and taskbar icon
    $w.Text = 'Logs - NRK Browser'
    $w.Size = New-Object System.Drawing.Size(1100, 680)
    $w.MinimumSize = New-Object System.Drawing.Size(700, 420)
    $w.StartPosition = 'CenterParent'
    $w.Font = $form.Font

    # top: which log; left: the actions; right: the log itself
    $top = New-Object System.Windows.Forms.FlowLayoutPanel
    $top.Dock = 'Top'; $top.Height = 44; $top.WrapContents = $false
    $top.Padding = New-Object System.Windows.Forms.Padding(12, 8, 8, 0)
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = 'Log'; $lbl.AutoSize = $true
    $lbl.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 0)
    $combo = New-Object System.Windows.Forms.ComboBox; $combo.DropDownStyle = 'DropDownList'; $combo.Width = 360
    $top.Controls.AddRange(@($lbl, $combo))

    $side = New-Object System.Windows.Forms.Panel
    $side.Dock = 'Left'; $side.Width = 190; $side.BackColor = $T.Panel
    $side.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 12)
    $sideItems = New-Object System.Collections.Generic.List[object]
    $mk = {
        param([string] $Text, [switch] $Primary)
        $b = New-FlatButton $Text 0 -Primary:$Primary
        $b.AutoSize = $false; $b.Dock = 'Top'; $b.Height = 36; $b.TextAlign = 'MiddleLeft'
        $b.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
        $sideItems.Add($b)
        $gap = New-Object System.Windows.Forms.Panel; $gap.Dock = 'Top'; $gap.Height = 8; $gap.BackColor = $T.Panel
        $sideItems.Add($gap)
        return $b
    }
    $bPause = & $mk ("{0}  Pause" -f [char]0x2016)
    $bRefresh = & $mk ("{0}  Refresh" -f [char]0x27F3)
    $bCopy = & $mk ("{0}  Copy all" -f [char]0x29C9)
    $bEditor = & $mk ("{0}  Open in editor" -f [char]0x270E)
    $bFolder = & $mk ("{0}  Open folder" -f [char]0x2197)
    $sep = New-Object System.Windows.Forms.Panel; $sep.Dock = 'Top'; $sep.Height = 14; $sep.BackColor = $T.Panel; $sideItems.Add($sep)
    $bClear = & $mk ("{0}  Clear log" -f [char]0x2715)
    Set-IconText $bRefresh 'reload' 'Refresh' ([string][char]0x27F3)
    Set-IconText $bCopy 'copy' 'Copy all' ([string][char]0x29C9)
    Set-IconText $bEditor 'edit' 'Open in editor' ([string][char]0x270E)
    Set-IconText $bFolder 'folder' 'Open folder' ([string][char]0x2197)
    Set-IconText $bClear 'trash' 'Clear log' ([string][char]0x2715)
    $bClear.ForeColor = $T.Bad
    $sep2 = New-Object System.Windows.Forms.Panel; $sep2.Dock = 'Top'; $sep2.Height = 18; $sep2.BackColor = $T.Panel; $sideItems.Add($sep2)
    $disk = New-Object System.Windows.Forms.CheckBox; $disk.Text = 'Save logs to disk'; $disk.Checked = [bool]$script:LogToDisk
    $disk.Dock = 'Top'; $disk.Height = 28; $disk.ForeColor = $T.Text; $sideItems.Add($disk)
    $diskNote = New-Object System.Windows.Forms.Label; $diskNote.Dock = 'Top'; $diskNote.Height = 52; $diskNote.ForeColor = $T.Muted
    $diskNote.Text = 'Off: this session only, in memory. On: day-files, kept 3 days.'; $sideItems.Add($diskNote)
    # (Dock=Top stacks in reverse order of adding)
    for ($i = $sideItems.Count - 1; $i -ge 0; $i--) { $side.Controls.Add($sideItems[$i]) }

    $box = New-Object System.Windows.Forms.TextBox
    $box.Dock = 'Fill'; $box.Multiline = $true; $box.ReadOnly = $true; $box.WordWrap = $false
    $box.ScrollBars = 'Both'; $box.Font = New-Object System.Drawing.Font('Consolas', 9)
    $box.MaxLength = 0

    $w.Controls.Add($box)
    $w.Controls.Add($side)
    $w.Controls.Add($top)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1500
    $script:LogsUi = @{ Form = $w; Combo = $combo; Box = $box; Pause = $bPause; Paused = $false; PausedAt = 0; ShownCount = 0; ShownSel = $null; Timer = $timer; LastLength = -1; Paths = @{}; Disk = $disk }
    $logTipsP = New-Object System.Windows.Forms.ToolTip
    $logTipsP.SetToolTip($bPause, 'Stop the view from moving while you read. The app keeps logging; Resume shows what came meanwhile.')
    $bPause.Add_Click({
        $u = $script:LogsUi
        $u.Paused = -not $u.Paused
        if ($u.Paused) { $u.PausedAt = [int]$script:LogCount } else { Update-LogsView $false }
        Update-LogsPauseButton
    })
    $logTips = New-Object System.Windows.Forms.ToolTip
    $logTips.SetToolTip($disk, "Off: this session's log is only kept in memory (shown here as 'This session'). On: also written to day-files in the logs folder, kept for 3 days.")
    $disk.Add_CheckedChanged({
        $s = Get-AppSettings; $s.Logging = $this.Checked; Save-AppSettings $s
        Set-LogToDisk $this.Checked
        Update-LogsFileList; Update-LogsView $true
    })

    $timer.Add_Tick({ if ($script:LogsUi) { Update-LogsView $false } })
    $combo.Add_SelectedIndexChanged({ if (-not $script:LogsUi.Suppress) { Update-LogsView $true } })
    $bRefresh.Add_Click({ Update-LogsFileList; Update-LogsView $true })
    $bCopy.Add_Click({ if ($script:LogsUi.Box.Text) { [System.Windows.Forms.Clipboard]::SetText($script:LogsUi.Box.Text) } })
    $bEditor.Add_Click({
        $p = Get-LogsSelection
        if ($p -eq 'session') {
            # not saved anywhere: open a copy
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ('NRK-Browser-session-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
            [IO.File]::WriteAllText($tmp, ($script:LogMem -join "`r`n"), (New-Object Text.UTF8Encoding($false))); Start-Process $tmp; return
        }
        if ($p -eq 'merged') { $p = $script:LogFile }
        if ($p -and (Test-Path -LiteralPath $p)) { Start-Process $p }
    })
    $bFolder.Add_Click({ if ($script:LogDir) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null; Start-Process $script:LogDir } })
    $bClear.Add_Click({ Clear-LogFile })
    $w.Add_FormClosed({ $script:LogsUi.Timer.Stop(); $script:LogsUi.Timer.Dispose(); $script:LogsUi = $null })

    Set-DarkTheme $w
    $box.BackColor = $T.Surface
    # the side panel keeps its own shade, Clear its warning colour
    $side.BackColor = $T.Panel; foreach ($c in $side.Controls) { if ($c -is [System.Windows.Forms.Panel]) { $c.BackColor = $T.Panel } }
    $bClear.ForeColor = $T.Bad
    Update-LogsFileList
    Update-LogsView $true
    $timer.Start()
    Enable-DarkTitleBar $w
    $w.Show($form)   # non-modal: it can stay open while you browse or install
}



#---- Indexer window ----------------------------------------------------------------
# Shows the indexer's status.json, and starts / pauses / stops it (control.json). The indexer
# itself is a separate windowless process (-Index), so it keeps going when this window or
# the app is closed. The daily run is a Windows scheduled task in your own account.

$script:IndexUi = $null
# (string keys: an [ordered] dictionary indexed with a number picks by position, not by key)
$script:IndexPaces = [ordered]@{ '250' = '0.25 s (fast)'; '500' = '0.5 s'; '1000' = '1 s (default)'; '2000' = '2 s'; '5000' = '5 s'; '10000' = '10 s (very gentle)' }

function Get-IndexScriptPath {
    # the copy the scheduled task runs: the installed one when installed, else this file
    if (Test-Path -LiteralPath $script:InstalledScript) { return $script:InstalledScript }
    return $PSCommandPath
}

function Get-IndexerState {
    # status.json plus whether that indexer process is really still there
    $s = Read-JsonFile $script:IndexStatusFile
    $alive = $false
    if ($s -and $s.State -in 'running', 'paused', 'stopping' -and $s.Pid) {
        try {
            $p = Get-Process -Id ([int]$s.Pid) -ErrorAction Stop
            $fresh = $true
            try { $fresh = ((Get-Date) - [datetime]$s.Updated).TotalSeconds -lt 120 } catch { }
            $alive = ($p.ProcessName -match 'powershell|pwsh') -and $fresh
        } catch { $alive = $false }
    }
    [pscustomobject]@{ Status = $s; Running = $alive }
}

function Start-Indexer {
    $st = Get-IndexerState
    if ($st.Running) { Set-Status 'The indexer is already running'; return }
    $hostExe = Get-LaunchHost
    $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Index' -f $PSCommandPath
    Write-Log INFO "Indexer: starting $hostExe $argLine"
    Remove-Item -LiteralPath $script:IndexControlFile -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $hostExe -ArgumentList $argLine -WindowStyle Hidden | Out-Null
    Set-Status 'Indexer started: it walks every folder slowly in the background'
}

function Invoke-IndexAuto {
    # while the app is open: refresh the saved data in the background once it is a day old
    $s = Get-AppSettings
    if (-not $s.IndexAuto -or $script:CacheMode -eq 'Off') { return }
    $st = Get-IndexerState
    if ($st.Running) { return }
    $x = $st.Status
    $ago = { param($iso) if (-not $iso) { return [double]::MaxValue }; try { ((Get-Date) - [datetime]$iso).TotalHours } catch { [double]::MaxValue } }
    if ($x -and $x.State -eq 'stopped' -and (& $ago $x.Finished) -lt 12) { return }   # you stopped it: not again today
    if ($x -and $x.State -eq 'failed' -and (& $ago $x.Finished) -lt 1) { return }
    if ((& $ago $(if ($x) { $x.LastFull } else { $null })) -lt 20) { return }
    Write-Log INFO 'Indexer: starting by itself - the saved NRK data is more than a day old'
    Start-Indexer
    Set-Status 'Refreshing the saved NRK data in the background (Indexer)'
}

function Send-IndexerCommand([string] $Command) {
    Write-JsonFile $script:IndexControlFile ([ordered]@{ Command = $Command; PaceMs = [int](Get-AppSettings).IndexPaceMs; Sent = (Get-Date).ToString('o') })
    Write-Log INFO "Indexer: sent '$Command'"
}

function Get-IndexSchedule {
    # the scheduled task, or $null
    try {
        $t = Get-ScheduledTask -TaskName $script:IndexTaskName -ErrorAction Stop
        $at = ''
        try { $at = ([datetime]@($t.Triggers)[0].StartBoundary).ToString('HH:mm') } catch { }
        $info = $null; try { $info = Get-ScheduledTaskInfo -TaskName $script:IndexTaskName -ErrorAction Stop } catch { }
        return [pscustomobject]@{ Time = $at; Arguments = [string]@($t.Actions)[0].Arguments; State = [string]$t.State
                                  LastRun = $(if ($info) { $info.LastRunTime }); NextRun = $(if ($info) { $info.NextRunTime }) }
    } catch { return $null }
}

function Set-IndexSchedule([bool] $On, [string] $Time = '03:00') {
    # daily scheduled task in this user's account (no administrator rights); missed runs start later
    if (-not $On) {
        try { Unregister-ScheduledTask -TaskName $script:IndexTaskName -Confirm:$false -ErrorAction Stop } catch {
            try { & schtasks.exe /Delete /TN $script:IndexTaskName /F 2>&1 | Out-Null } catch { }
        }
        Write-Log INFO 'Indexer: daily schedule removed'
        return
    }
    $hostExe = Get-LaunchHost
    $psLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Index' -f (Get-IndexScriptPath)
    # started through a tiny hidden launcher, so no console window flashes up at 03:00
    $vbs = Join-Path $script:IndexDir 'run-indexer.vbs'
    New-Item -ItemType Directory -Path $script:IndexDir -Force | Out-Null
    $cmd = ('"{0}" {1}' -f $hostExe, $psLine) -replace '"', '""'
    [IO.File]::WriteAllText($vbs, "' NRK Browser: starts the indexer without a window`r`nCreateObject(""WScript.Shell"").Run ""$cmd"", 0, False`r`n", [Text.Encoding]::Unicode)
    $wscript = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\wscript.exe' } else { 'wscript.exe' }
    $hostExe = $wscript; $argLine = '//B //NoLogo "{0}"' -f $vbs
    $at = [datetime]::ParseExact($Time, 'HH:mm', $null)
    try {
        $action = New-ScheduledTaskAction -Execute $hostExe -Argument $argLine
        $trigger = New-ScheduledTaskTrigger -Daily -At $at
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 20) -MultipleInstances IgnoreNew -Priority 7
        Register-ScheduledTask -TaskName $script:IndexTaskName -Action $action -Trigger $trigger -Settings $set `
            -Description 'NRK Browser: refreshes the saved NRK catalogue once a day, slowly, so folders open instantly.' -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Log WARN "Register-ScheduledTask failed ($($_.Exception.Message)); trying schtasks.exe"
        $tr = '"{0}" {1}' -f $hostExe, $argLine
        $out = & schtasks.exe /Create /F /SC DAILY /ST $Time /TN $script:IndexTaskName /TR $tr 2>&1
        if ($LASTEXITCODE -ne 0) { throw "schtasks: $($out -join ' ')" }
    }
    Write-Log INFO "Indexer: runs every day at $Time ($hostExe $argLine)"
}

function Update-IndexSchedulePath {
    # after an install or a move: point the daily task at the right copy of the script
    $s = Get-AppSettings
    if (-not $s.IndexSchedule) { return }
    $t = Get-IndexSchedule
    $want = Get-IndexScriptPath
    $vbs = Join-Path $script:IndexDir 'run-indexer.vbs'
    $runs = if ($t -and $t.Arguments -like '*run-indexer.vbs*' -and (Test-Path -LiteralPath $vbs)) { [IO.File]::ReadAllText($vbs) } elseif ($t) { $t.Arguments } else { '' }
    if (-not $t -or $runs -notlike "*$want*" -or $t.Arguments -notlike '*run-indexer.vbs*') {
        try { Set-IndexSchedule $true $s.IndexTime } catch { Write-LogException $_ 'Indexer schedule' }
    }
}

function Format-Span([double] $Seconds) {
    if ($Seconds -lt 60) { return '{0:N0} s' -f $Seconds }
    $t = [TimeSpan]::FromSeconds($Seconds)
    if ($t.TotalHours -ge 1) { return '{0} h {1} min' -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
    return '{0} min' -f [int][Math]::Ceiling($t.TotalMinutes)
}

function Update-IndexerView {
    $ui = $script:IndexUi
    if (-not $ui -or $ui.Form.IsDisposed) { return }
    $st = Get-IndexerState
    $s = $st.Status
    $fmt = { param($iso) if (-not $iso) { return '' }; try { ([datetime]$iso).ToString('dd.MM.yyyy HH:mm') } catch { '' } }
    $last = if ($s -and $s.LastFull) { 'Last full run: {0}{1}' -f (& $fmt $s.LastFull), $(if ($s.LastFullSeconds) { " (took $(Format-Span $s.LastFullSeconds))" } else { '' }) } else { 'No full run yet' }
    if ($st.Running) {
        $word = switch ($s.State) { 'paused' { 'Paused' } 'stopping' { 'Stopping...' } default { 'Running' } }
        $ui.State.Text = '{0}  ·  step {1} of {2}: {3}' -f $word, $s.PhaseNo, $s.PhaseCount, $s.Phase
        $ui.State.ForeColor = if ($s.State -eq 'paused') { $T.Muted } else { $T.Accent }
        $tot = [int]$s.PhaseTotal; $done = [Math]::Min([int]$s.PhaseDone, $tot)
        $ui.Bar.Maximum = [Math]::Max(1, $tot); $ui.Bar.Value = $done
        $what = if ($s.PhaseNo -ge 5) { 'series' } else { 'folders' }
        $ui.Progress.Text = '{0:N0} / {1:N0} {2}{3}' -f $done, $tot, $what, $(if ($null -ne $s.EtaSeconds -and $s.State -eq 'running') { "  ·  about $(Format-Span $s.EtaSeconds) left in this step" } else { '' })
        $ui.Current.Text = if ($s.Current) { "Now: $($s.Current)" } else { '' }
    } else {
        $ui.Bar.Value = 0
        $ui.State.ForeColor = $T.Text
        $ui.State.Text = if (-not $s) { 'Not running' } else {
            switch ($s.State) {
                'done'    { 'Finished {0}' -f (& $fmt $s.Finished) }
                'stopped' { 'Stopped {0}  ·  Run now continues where it stopped' -f (& $fmt $s.Finished) }
                'failed'  { 'Failed {0}' -f (& $fmt $s.Finished) }
                default   { 'Not running (the last run ended unexpectedly)' }
            }
        }
        $ui.Progress.Text = $last
        $ui.Current.Text = ''
    }
    if ($s) {
        $ui.Counts.Text = 'Found {0:N0} TV series, {1:N0} programmes, {2:N0} radio series and podcasts, {3:N0} episodes' -f [int]$s.TvSeries, [int]$s.Programs, [int]$s.RadioSeries, [int]$s.Episodes
        $ui.Requests.Text = 'Requests to NRK: {0:N0}  ·  already up to date: {1:N0}  ·  errors: {2:N0}' -f [int]$s.Requests, [int]$s.Skipped, [int]$s.Errors
        $ui.Error.Text = if ($s.LastError) { "Last error: $($s.LastError)" } else { '' }
        if ($st.Running) { $ui.Last.Text = $last } else { $ui.Last.Text = '' }
    } else { $ui.Counts.Text = 'The indexer has not run yet.'; $ui.Requests.Text = ''; $ui.Error.Text = ''; $ui.Last.Text = '' }
    if ($script:CacheMode -eq 'Off') { $ui.Error.Text = 'Note: Options > "Refresh saved NRK data" is set to "Always fetch from NRK", so the app does not use what the indexer saves.' }
    $ui.Run.Enabled = -not $st.Running
    $ui.Pause.Enabled = $st.Running -and $s.State -ne 'stopping'
    if ($st.Running -and $s.State -eq 'paused') { Set-IconText $ui.Pause 'play' 'Resume' } else { Set-IconText $ui.Pause 'pause' 'Pause' }   # (2.9.3: icons)
    $ui.Stop.Enabled = $st.Running -and $s.State -ne 'stopping'
    # the indexer's own log, newest lines last
    if (-not $script:LogToDisk) { if ($ui.Log.Text -notlike '(Logs are not saved*') { $ui.Log.Text = "(Logs are not saved to disk, so the indexer's log is not shown. Switch on 'Save logs to disk' in Logs or Options to see it here.)" }; return }
    try {
        $log = Join-Path $script:LogDir ('NRK-Indexer_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
        if (-not (Test-Path -LiteralPath $log)) { $log = @(Get-ChildItem -LiteralPath $script:LogDir -Filter 'NRK-Indexer_*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1).FullName }
        if ($log -and (Test-Path -LiteralPath $log)) {
            $len = (Get-Item -LiteralPath $log).Length
            if ("$log|$len" -ne $ui.LogSig) {
                $ui.LogSig = "$log|$len"
                $lines = @((Read-LogTail -Path $log -MaxBytes 48KB) -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 200)
                $ui.Log.Text = ($lines -join "`r`n"); $ui.Log.SelectionStart = $ui.Log.TextLength; $ui.Log.ScrollToCaret()
            }
        }
    } catch { }
}

function Open-IndexerWindow {
    # never fail silently: say what went wrong
    try { Show-IndexerWindow }
    catch {
        Write-LogException $_ 'Indexer window'
        try { if ($script:IndexUi -and $script:IndexUi.Form -and -not $script:IndexUi.Form.Visible) { $script:IndexUi.Form.Dispose(); $script:IndexUi = $null } } catch { }
        [void][System.Windows.Forms.MessageBox]::Show($form, "The Indexer window could not open:`n`n$($_.Exception.Message)`n`n(line $($_.InvocationInfo.ScriptLineNumber); details in Logs)", 'Indexer', 'OK', 'Error')
    }
}

function Show-IndexerWindow {
    if ($script:IndexUi -and -not $script:IndexUi.Form.IsDisposed) { $script:IndexUi.Form.Activate(); return }
    Write-Log INFO 'UI: opened Indexer window'
    $st = Get-AppSettings
    $w = New-Object System.Windows.Forms.Form
    Set-AppIcon $w
    $w.Text = 'Indexer - NRK Browser'
    $w.ClientSize = New-Object System.Drawing.Size(720, 600)
    $w.MinimumSize = New-Object System.Drawing.Size(600, 520)
    $w.StartPosition = 'CenterParent'
    $w.Font = $script:FontUi; $w.BackColor = $T.Bg; $w.ForeColor = $T.Text
    $ui = @{ Form = $w; LogSig = '' }
    $script:IndexUi = $ui
    $add = { param($c, [int] $x, [int] $y) $c.Location = New-Object System.Drawing.Point($x, $y); [void]$w.Controls.Add($c); $c }
    $label = {
        param([string] $text, [int] $y, [switch] $Muted, [switch] $Big)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.AutoSize = $false; $l.Width = 680; $l.Height = $(if ($Big) { 26 } else { 20 }); $l.AutoEllipsis = $true; $l.UseMnemonic = $false
        $l.Anchor = 'Top, Left, Right'
        if ($Big) { $l.Font = $script:FontHeader }
        $l.ForeColor = if ($Muted) { $T.Muted } else { $T.Text }
        & $add $l 20 $y
    }
    [void](& $label 'Walks every TV and radio folder slowly, one request at a time, and saves it on this computer, so folders open instantly. It runs as its own background process: you can close this window and the app.' 12 -Muted)
    $ui.Intro = $w.Controls[$w.Controls.Count - 1]; $ui.Intro.Height = 36
    $ui.State = & $label '' 56 -Big
    $ui.Bar = New-Object System.Windows.Forms.ProgressBar
    $ui.Bar.Width = 680; $ui.Bar.Height = 10; $ui.Bar.Anchor = 'Top, Left, Right'; $ui.Bar.Style = 'Continuous'
    [void](& $add $ui.Bar 20 88)
    $ui.Progress = & $label '' 104
    $ui.Current = & $label '' 126 -Muted
    $ui.Counts = & $label '' 152
    $ui.Requests = & $label '' 174 -Muted
    $ui.Last = & $label '' 196 -Muted
    $ui.Error = & $label '' 218 -Muted

    $ui.Run = New-FlatButton 'Run now' 120 -Primary
    [void](& $add $ui.Run 20 248)
    $ui.Pause = New-FlatButton 'Pause' 110
    [void](& $add $ui.Pause 150 248)
    $ui.Stop = New-FlatButton 'Stop' 100
    [void](& $add $ui.Stop 270 248)
    $bFolder = New-FlatButton 'Open folder' 130
    Set-IconText $ui.Run 'play' 'Run now' -Primary; Set-IconText $ui.Pause 'pause' 'Pause'; Set-IconText $ui.Stop 'stop' 'Stop'; Set-IconText $bFolder 'folder' 'Open folder'   # (2.9.3)
    [void](& $add $bFolder 380 248)

    $lblPace = New-Object System.Windows.Forms.Label; $lblPace.Text = 'Pause between requests'; $lblPace.AutoSize = $true
    [void](& $add $lblPace 22 304)
    $ui.Pace = New-Object System.Windows.Forms.ComboBox
    $ui.Pace.DropDownStyle = 'DropDownList'; $ui.Pace.FlatStyle = 'Flat'; $ui.Pace.Width = 200
    $ui.Pace.BackColor = $T.Surface; $ui.Pace.ForeColor = $T.Text
    foreach ($k in @($script:IndexPaces.Keys)) { [void]$ui.Pace.Items.Add([string]$script:IndexPaces[[string]$k]) }
    $keys = @($script:IndexPaces.Keys | ForEach-Object { [int]$_ })
    $i = [array]::IndexOf($keys, [int]$st.IndexPaceMs); if ($i -lt 0) { $i = 2 }
    $ui.Pace.SelectedIndex = $i
    [void](& $add $ui.Pace 200 300)
    [void](& $label 'Slower is kinder to NRK and your connection; the whole catalogue takes several hours at 1 s.' 330 -Muted)

    $ui.Daily = New-Object System.Windows.Forms.CheckBox
    $ui.Daily.Text = 'Run every day at'; $ui.Daily.AutoSize = $true; $ui.Daily.ForeColor = $T.Text
    $ui.Daily.Checked = [bool]$st.IndexSchedule
    [void](& $add $ui.Daily 22 364)
    $ui.Time = New-Object System.Windows.Forms.DateTimePicker
    $ui.Time.Format = 'Custom'; $ui.Time.CustomFormat = 'HH:mm'; $ui.Time.ShowUpDown = $true; $ui.Time.Width = 80
    try { $ui.Time.Value = [datetime]::Today.Add([TimeSpan]::Parse([string]$st.IndexTime)) } catch { $ui.Time.Value = [datetime]::Today.AddHours(3) }
    [void](& $add $ui.Time 160 361)
    $ui.Auto = New-Object System.Windows.Forms.CheckBox
    $ui.Auto.Text = 'Run by itself while the app is open, when the saved data is more than a day old'; $ui.Auto.AutoSize = $true; $ui.Auto.ForeColor = $T.Text
    $ui.Auto.Checked = [bool]$st.IndexAuto
    [void](& $add $ui.Auto 22 392)
    $ui.Sched = & $label '' 420 -Muted

    $ui.Log = New-Object System.Windows.Forms.TextBox
    $ui.Log.Multiline = $true; $ui.Log.ReadOnly = $true; $ui.Log.WordWrap = $false; $ui.Log.ScrollBars = 'Both'
    $ui.Log.Font = New-Object System.Drawing.Font('Consolas', 8.5); $ui.Log.BorderStyle = 'FixedSingle'
    $ui.Log.Width = 680; $ui.Log.Height = 142; $ui.Log.Anchor = 'Top, Bottom, Left, Right'
    $ui.Log.BackColor = $T.Surface; $ui.Log.ForeColor = $T.Text
    [void](& $add $ui.Log 20 448)

    $ui.Timer = New-Object System.Windows.Forms.Timer
    $ui.Timer.Interval = 1000
    $ui.Timer.Add_Tick({ Update-IndexerView })

    $script:IndexShowSchedule = {
        $u = $script:IndexUi
        if (-not $u) { return }
        $t = Get-IndexSchedule
        $u.Sched.Text = if ($t) {
            $next = if ($t.NextRun -and $t.NextRun.Year -gt 2000) { 'next run ' + $t.NextRun.ToString('dd.MM HH:mm') } else { '' }
            ('Scheduled task "{0}" {1}. A run missed while the PC was off starts when it is next on.' -f $script:IndexTaskName, $next)
        } elseif ($u.Daily.Checked) { 'The scheduled task is missing: untick and tick again to create it.' }
        else { 'Not scheduled. Run now whenever you like.' }
    }

    $ui.Run.Add_Click({ Start-Indexer; Start-Sleep -Milliseconds 300; Update-IndexerView })
    $ui.Pause.Add_Click({
        $s = (Get-IndexerState).Status
        Send-IndexerCommand $(if ($s -and $s.State -eq 'paused') { 'resume' } else { 'pause' })
    })
    $ui.Stop.Add_Click({ Send-IndexerCommand 'stop' })
    $ui.Auto.Add_CheckedChanged({ $s = Get-AppSettings; $s.IndexAuto = $this.Checked; Save-AppSettings $s; Write-Log INFO "Option IndexAuto = $($this.Checked)" })
    $bFolder.Add_Click({ New-Item -ItemType Directory -Path $script:IndexDir -Force | Out-Null; Start-Process $script:IndexDir })
    $ui.Pace.Add_SelectedIndexChanged({
        $ms = [int]@($script:IndexPaces.Keys)[$this.SelectedIndex]
        $s = Get-AppSettings; if ([int]$s.IndexPaceMs -eq $ms) { return }
        $s.IndexPaceMs = $ms; Save-AppSettings $s
        Write-Log INFO "Option IndexPaceMs = $ms"
        $cur = (Get-IndexerState).Status
        if ((Get-IndexerState).Running) { Send-IndexerCommand $(if ($cur.State -eq 'paused') { 'pause' } else { 'resume' }) }   # carries the new pace
    })
    $applySchedule = {
        $u = $script:IndexUi
        $on = $u.Daily.Checked; $time = $u.Time.Value.ToString('HH:mm')
        $u.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            Set-IndexSchedule $on $time
            $s = Get-AppSettings; $s.IndexSchedule = $on; $s.IndexTime = $time; Save-AppSettings $s
        } catch {
            Write-LogException $_ 'Indexer schedule'
            [void][System.Windows.Forms.MessageBox]::Show($u.Form, "Could not change the scheduled task:`n$($_.Exception.Message)", 'Indexer', 'OK', 'Error')
        } finally { $u.Form.Cursor = [System.Windows.Forms.Cursors]::Default }
        & $script:IndexShowSchedule
    }
    $script:IndexApplySchedule = $applySchedule
    $ui.Daily.Add_CheckedChanged({ & $script:IndexApplySchedule })
    $ui.Time.Add_ValueChanged({ if ($script:IndexUi.Daily.Checked) { $script:IndexUi.TimeDirty = $true } })
    $ui.Time.Add_Leave({ if ($script:IndexUi.TimeDirty) { $script:IndexUi.TimeDirty = $false; & $script:IndexApplySchedule } })
    $w.Add_FormClosing({ $u = $script:IndexUi; if ($u -and $u.TimeDirty) { $u.TimeDirty = $false; & $script:IndexApplySchedule } })
    $w.Add_FormClosed({ $script:IndexUi.Timer.Stop(); $script:IndexUi.Timer.Dispose(); $script:IndexUi = $null })

    Set-DarkTheme $w
    $ui.Log.BackColor = $T.Surface
    try { Update-IndexSchedulePath } catch { }
    & $script:IndexShowSchedule
    Update-IndexerView
    $ui.Timer.Start()
    Enable-DarkTitleBar $w
    $w.Show($form)
}

#---- App: icon, install, tray, single instance, updates ------------------------------

# App icon: the purple video icon in SHELL32.dll (index 129, else 241), loaded from Windows itself.
# Overrides, in this order:
#   NRK-Browser.ico next to the script, or custom-icon.ico in the app data folder
#   "AppIcon": "C:\\Windows\\System32\\SHELL32.dll,<index>" in settings.json
if (-not ('NrkIcons' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NrkIcons {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHSTOCKICONINFO {
        public uint cbSize; public IntPtr hIcon; public int iSysImageIndex; public int iIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szPath;
    }
    [DllImport("shell32.dll")] static extern int SHGetStockIconInfo(uint siid, uint flags, ref SHSTOCKICONINFO info);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHDefExtractIcon(string file, int index, uint flags, out IntPtr large, out IntPtr small, uint sizes);
    // "path,index" of a stock icon (SIID_VIDEOFILES = 72), or null
    public static string StockLocation(uint siid) {
        var i = new SHSTOCKICONINFO(); i.cbSize = (uint)Marshal.SizeOf(typeof(SHSTOCKICONINFO));
        if (SHGetStockIconInfo(siid, 0, ref i) != 0 || string.IsNullOrEmpty(i.szPath)) return null;
        return i.szPath + "," + i.iIcon;
    }
    // large (e.g. 48 px) and small (16 px) icon handles from a DLL/EXE/ICO
    public static IntPtr[] Extract(string file, int index, int large, int small) {
        IntPtr l, s;
        int hr = SHDefExtractIcon(file, index, 0, out l, out s, (uint)((small << 16) | large));
        return hr == 0 ? new[] { l, s } : null;
    }
}
'@
}

function Get-AppIconLocation {
    foreach ($c in @((Join-Path $script:ScriptDir 'NRK-Browser.ico'), (Join-Path $script:AppDataDir 'custom-icon.ico'))) {
        if (Test-Path -LiteralPath $c) { return "$c,0" }
    }
    try {
        $sf = Join-Path $script:AppDataDir 'settings.json'
        if (Test-Path -LiteralPath $sf) {
            $v = (Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json).AppIcon
            if ($v) { return [Environment]::ExpandEnvironmentVariables([string]$v) }
        }
    } catch { }
    # the purple video icon: icon 129 in SHELL32.dll
    $shell32 = Join-Path ([Environment]::GetFolderPath('System')) 'SHELL32.dll'
    if (Test-Path -LiteralPath $shell32) { return "$shell32,129" }
    try { $loc = [NrkIcons]::StockLocation(72) } catch { $loc = $null }   # fallback: Windows' "video files" icon
    if ($loc) { return [Environment]::ExpandEnvironmentVariables($loc) }
    return $null
}

$script:AppIconLocation = Get-AppIconLocation
try { $cm = (Get-AppSettings).CacheRefresh; if ($script:CacheModes.Contains($cm)) { $script:CacheMode = $cm } } catch { }
try { $so = [string](Get-AppSettings).SortOrder; if ($so -in 'desc', 'asc', 'nrk') { $script:SortOrder = $so } } catch { }
Write-Log INFO "Cache refresh: $($script:CacheMode)"
$script:AppIcon = $null; $script:AppIconSmall = $null
try {
    if ($script:AppIconLocation -match '^(.*),(-?\d+)$') {
        $h = [NrkIcons]::Extract($Matches[1], [int]$Matches[2], 48, 16)
        # Not there on this Windows build? Try SHELL32.dll,241, then Windows' stock video icon.
        $fallbacks = @((Join-Path ([Environment]::GetFolderPath('System')) 'SHELL32.dll') + ',241')
        try { $fallbacks += [Environment]::ExpandEnvironmentVariables([NrkIcons]::StockLocation(72)) } catch { }
        foreach ($fb in $fallbacks) {
            if ($h -and $h[0] -ne [IntPtr]::Zero) { break }
            if (-not $fb -or $fb -notmatch '^(.*),(-?\d+)$') { continue }
            Write-Log WARN "App icon $($script:AppIconLocation) could not be loaded; trying $fb"
            $script:AppIconLocation = $fb
            $h = [NrkIcons]::Extract($Matches[1], [int]$Matches[2], 48, 16)
        }
        if ($h -and $h[0] -ne [IntPtr]::Zero) { $script:AppIcon = [System.Drawing.Icon]::FromHandle($h[0]) }
        if ($h -and $h[1] -ne [IntPtr]::Zero) { $script:AppIconSmall = [System.Drawing.Icon]::FromHandle($h[1]) }
    }
    Write-Log INFO "App icon: $($script:AppIconLocation)"
} catch { Write-Log WARN "App icon could not be loaded from $($script:AppIconLocation): $($_.Exception.Message)" }
if (-not $script:AppIconSmall) { $script:AppIconSmall = $script:AppIcon }
function Set-AppIcon($Window) { if ($script:AppIcon -and $Window) { try { $Window.Icon = $script:AppIcon } catch { } } }

# ---- install

$script:InstallDir = $script:AppDataDir
$script:InstalledScript = Join-Path $script:InstallDir 'NRK-Browser.ps1'

function Get-FullPath([string] $Path) { if (-not $Path) { return '' }; try { return [IO.Path]::GetFullPath($Path) } catch { return $Path } }

function Get-ScriptVersionFromText([string] $Text) {
    if ($Text -match "(?m)^\s*\`$script:AppVersion\s*=\s*'([0-9]+(?:\.[0-9]+){0,3})'") { return ConvertTo-AppVersion $Matches[1] }
    return $null
}
function ConvertTo-AppVersion([string] $Value) {
    $p = @($Value.Trim().Split('.') | Where-Object { $_ -ne '' } | Select-Object -First 4)
    while ($p.Count -lt 4) { $p += '0' }   # 2.1 == 2.1.0 == 2.1.0.0
    return [version]($p -join '.')
}

function Get-InstallInfo {
    $installed = Test-Path -LiteralPath $script:InstalledScript
    $ver = $null
    if ($installed) { try { $ver = Get-ScriptVersionFromText ([IO.File]::ReadAllText($script:InstalledScript)) } catch { } }
    [pscustomobject]@{
        Dir       = $script:InstallDir
        Script    = $script:InstalledScript
        Installed = $installed
        Version   = $ver
        Running   = ($PSCommandPath -and ((Get-FullPath $PSCommandPath) -eq (Get-FullPath $script:InstalledScript)))
        StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'NRK Browser.lnk'
        Desktop   = Join-Path ([Environment]::GetFolderPath('Desktop')) 'NRK Browser.lnk'
        Startup   = Join-Path ([Environment]::GetFolderPath('Startup')) 'NRK Browser (tray).lnk'
    }
}

function Get-LaunchHost {
    # pwsh when this runs in PowerShell 7, otherwise Windows PowerShell
    $cur = (Get-Process -Id $PID).Path
    if ($cur -match 'pwsh(\.exe)?$') { return $cur }
    $winPs = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { $null }
    if ($winPs -and (Test-Path -LiteralPath $winPs)) { return $winPs }
    return $cur
}

function New-AppShortcut([string] $Path, [string] $ScriptPath, [string] $ExtraArgs = '') {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($Path)
    $lnk.TargetPath = Get-LaunchHost
    $lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{0}" {1}' -f $ScriptPath, $ExtraArgs).Trim()
    $lnk.WorkingDirectory = Split-Path -Parent $ScriptPath
    if ($script:AppIconLocation) { $lnk.IconLocation = $script:AppIconLocation }
    $lnk.Description = 'Watch, listen to and download from NRK TV and NRK Radio'
    $lnk.WindowStyle = 7   # start minimized: no console flash
    $lnk.Save()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh)
    Write-Log INFO "Shortcut: $Path -> $ScriptPath $ExtraArgs"
}

function Install-App {
    # Copies this script to %LOCALAPPDATA%\NRK-Browser and creates the launchers.
    param([bool] $StartMenu = $true, [bool] $Desktop = $true)
    if (-not $PSCommandPath) { throw 'This copy is not running from a file, so it cannot be installed.' }
    New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
    if ((Get-FullPath $PSCommandPath) -ne (Get-FullPath $script:InstalledScript)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $script:InstalledScript -Force
        Write-Log INFO "Installed $PSCommandPath -> $($script:InstalledScript)"
    }
    $i = Get-InstallInfo
    foreach ($pair in @(@($StartMenu, $i.StartMenu), @($Desktop, $i.Desktop))) {
        if ($pair[0]) { New-AppShortcut $pair[1] $script:InstalledScript }
        elseif (Test-Path -LiteralPath $pair[1]) { Remove-Item -LiteralPath $pair[1] -Force; Write-Log INFO "Removed shortcut $($pair[1])" }
    }
    if ((Get-AppSettings).StartWithWindows) { Set-StartWithWindows $true }   # point it at the installed copy
    try { Update-IndexSchedulePath } catch { Write-Log WARN "Indexer schedule: $($_.Exception.Message)" }
}

function Uninstall-App {
    $i = Get-InstallInfo
    foreach ($p in $i.StartMenu, $i.Desktop, $i.Startup) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Log INFO "Removed shortcut $p" }
    }
    if ($i.Installed) { Remove-Item -LiteralPath $i.Script -Force; Write-Log INFO "Removed $($i.Script)" }   # a running script file is not locked
    foreach ($bak in @("$($i.Script).bak")) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
    $st = Get-AppSettings; $st.StartWithWindows = $false
    if ($st.IndexSchedule) { try { Set-IndexSchedule $false } catch { }; $st.IndexSchedule = $false }
    Save-AppSettings $st
}

function Set-StartWithWindows([bool] $On) {
    $i = Get-InstallInfo
    if ($On) {
        $target = if ($i.Installed) { $i.Script } else { $PSCommandPath }
        New-AppShortcut $i.Startup $target '-Tray'
    } elseif (Test-Path -LiteralPath $i.Startup) {
        Remove-Item -LiteralPath $i.Startup -Force
        Write-Log INFO "Removed startup shortcut $($i.Startup)"
    }
}

function Start-AppDetached {
    # Starts a script after this process has exited (single instance, file replacement).
    param([string] $ScriptPath = $PSCommandPath, [string] $ExtraArgs = '')
    $hostExe = Get-LaunchHost
    $argLine = ('-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" {1}' -f $ScriptPath, $ExtraArgs).Trim()
    $cmd = "Wait-Process -Id $PID -Timeout 90 -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 300; " +
           "Start-Process -FilePath '$($hostExe -replace "'", "''")' -ArgumentList '$($argLine -replace "'", "''")' -WindowStyle Hidden"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Write-Log INFO "Restart scheduled: $hostExe $argLine"
    Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $enc) -WindowStyle Hidden | Out-Null
}

function Optimize-Logs {
    # keep LogDays days: delete whole day-files (and old saved API responses); today's file stays
    $days = [Math]::Max(1, [int](Get-AppSettings).LogDays)
    $cutoff = (Get-Date).Date.AddDays(1 - $days)      # 3 days = today and the two days before
    if (-not $script:LogDir -or -not (Test-Path -LiteralPath $script:LogDir)) { return }
    $n = 0
    foreach ($f in Get-ChildItem -LiteralPath $script:LogDir -Recurse -File -ErrorAction SilentlyContinue) {
        if ($f.FullName -eq $script:LogFile) { continue }
        $day = if ($f.Name -match '(\d{4}-\d{2}-\d{2})') { try { [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) } catch { $f.LastWriteTime.Date } } else { $f.LastWriteTime.Date }
        if ($day -lt $cutoff) { try { Remove-Item -LiteralPath $f.FullName -Force; $n++ } catch { } }
    }
    if ($n) { Write-Log INFO "Logs: removed $n file(s) older than $days day(s)" }
}

function Invoke-LegacyMigration {
    # After the rename to "NRK Browser": the installed script and the shortcuts still have the
    # old names. Rename the script (the install check then compares versions as usual) and
    # replace the old shortcuts with new ones.
    try {
        $oldScript = Join-Path $script:InstallDir 'NRK-TV-Browser.ps1'
        if ((Test-Path -LiteralPath $oldScript) -and -not (Test-Path -LiteralPath $script:InstalledScript)) {
            Move-Item -LiteralPath $oldScript -Destination $script:InstalledScript -Force
            Remove-Item -LiteralPath "$oldScript.bak" -Force -ErrorAction SilentlyContinue
            Write-Log INFO "Rename: installed script moved to $($script:InstalledScript)"
        }
        $i = Get-InstallInfo
        $target = if ($i.Installed) { $i.Script } else { $PSCommandPath }
        foreach ($pair in @(@('Programs', 'NRK TV Browser.lnk', $i.StartMenu, ''), @('Desktop', 'NRK TV Browser.lnk', $i.Desktop, ''), @('Startup', 'NRK TV Browser (tray).lnk', $i.Startup, '-Tray'))) {
            $old = Join-Path ([Environment]::GetFolderPath($pair[0])) $pair[1]
            if (-not (Test-Path -LiteralPath $old)) { continue }
            Remove-Item -LiteralPath $old -Force
            if ($target) { New-AppShortcut $pair[2] $target $pair[3] }
            Write-Log INFO "Rename: replaced shortcut $old -> $($pair[2])"
        }
    } catch { Write-LogException $_ 'Rename migration' }
}

function Invoke-InstallCheck {
    # At startup: when an installed copy exists and this is a different file, compare versions.
    # Newer here -> offer to upgrade the installed copy and run that; newer installed -> offer to
    # run the installed one. Returns $true when this process should exit.
    if ($Tray -or -not $PSCommandPath) { return $false }
    $i = Get-InstallInfo
    if (-not $i.Installed -or $i.Running) { return $false }
    $mine = ConvertTo-AppVersion $script:AppVersion
    $theirs = $i.Version
    Write-Log INFO "Install check: running $mine from $PSCommandPath; installed $theirs in $($i.Dir)"
    if ($theirs -and $mine -eq $theirs) { return $false }
    if (-not $theirs -or $mine -gt $theirs) {
        $text = "NRK Browser is installed in`n$($i.Dir)`n`nThe installed copy is version $(if ($theirs) { $theirs } else { 'unknown' }); this file is version ${mine}:`n$PSCommandPath`n`n" +
                "Upgrade the installed copy to $mine and run it from the install folder? (The old copy is kept as .bak.)"
        $choice = Show-ChoiceDialog -Owner $null -Title 'Upgrade installed version' -Text $text -Buttons @('Upgrade and start', 'Run this copy only')
        if ($choice -ne 0) { Write-Log INFO 'Install check: user runs this copy without upgrading'; return $false }
        try {
            Copy-Item -LiteralPath $i.Script -Destination "$($i.Script).bak" -Force -ErrorAction SilentlyContinue
            $st = Get-AppSettings
            Install-App -StartMenu $st.StartMenuShortcut -Desktop $st.DesktopShortcut   # copies this file over the installed one, refreshes shortcuts
            Write-Log INFO "Install check: upgraded $($i.Script) from $theirs to $mine"
        } catch {
            Write-LogException $_ 'Upgrade installed copy'
            [void][System.Windows.Forms.MessageBox]::Show("Could not upgrade the installed copy:`n$($_.Exception.Message)`n`nThis copy starts instead.", 'Upgrade', 'OK', 'Warning')
            return $false
        }
    } else {
        $text = "A newer version ($theirs) is installed in`n$($i.Dir)`n`nThis file is the older version ${mine}:`n$PSCommandPath`n`nStart the installed version instead?"
        $choice = Show-ChoiceDialog -Owner $null -Title 'Newer version installed' -Text $text -Buttons @('Start installed version', 'Run this older copy')
        if ($choice -ne 0) { return $false }
    }
    Start-AppDetached -ScriptPath $i.Script
    Show-AppConsole
    Write-Log INFO "===== this copy exits; starting the installed copy $($i.Script) ====="
    return $true
}


# ---- instance pipe (server side of the single-instance IPC, see the startup section)

$script:PipeListen = $null
$script:PipeConns = New-Object System.Collections.ArrayList
function Start-InstancePipe {
    # a listener is always waiting, so a request is never lost while the previous one is answered
    try {
        $srv = New-Object System.IO.Pipes.NamedPipeServerStream($script:PipeName, [System.IO.Pipes.PipeDirection]::InOut,
            [System.IO.Pipes.NamedPipeServerStream]::MaxAllowedServerInstances, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::Asynchronous)
        $script:PipeListen = @{ Stream = $srv; Wait = $srv.WaitForConnectionAsync() }
    } catch { Write-Log WARN "Instance pipe could not start: $($_.Exception.Message)"; $script:PipeListen = $null }
}
function Update-InstancePipe {
    $l = $script:PipeListen
    if ($l -and $l.Wait.IsCompleted) {
        if ($l.Wait.IsFaulted) { try { $l.Stream.Dispose() } catch { } }
        else {
            $r = New-Object System.IO.StreamReader($l.Stream)
            $w = New-Object System.IO.StreamWriter($l.Stream); $w.AutoFlush = $true
            [void]$script:PipeConns.Add(@{ Stream = $l.Stream; Reader = $r; Writer = $w; Read = $r.ReadLineAsync(); Since = Get-Date })
        }
        Start-InstancePipe
    }
    $exit = $false
    foreach ($c in @($script:PipeConns)) {
        if (-not $c.Read.IsCompleted) {
            if (((Get-Date) - $c.Since).TotalSeconds -gt 10) { try { $c.Stream.Dispose() } catch { }; $script:PipeConns.Remove($c) }
            continue
        }
        try {
            $cmd = if ($c.Read.IsFaulted) { '' } else { [string]$c.Read.Result }
            Write-Log INFO "Instance pipe: '$cmd' from another start"
            switch -Regex ($cmd.Trim()) {
                '^INFO$' { $c.Writer.WriteLine(("OK {0}|{1}|{2}" -f $script:AppVersion, $PID, $PSCommandPath)) }
                '^SHOW$' { $c.Writer.WriteLine('OK'); Show-MainWindow }
                '^PLAY (\S+)$' { $c.Writer.WriteLine('OK'); $what = $Matches[1]; try { Invoke-PlayCommand $what } catch { Write-LogException $_ "Play $what" } }
                '^EXIT$' {
                    if ($script:DlRun.Proc -or $script:DlRun.Finishing) { $c.Writer.WriteLine("BUSY downloading $(if ($script:DlRun.Item) { $script:DlRun.Item.Title } else { $script:DlRun.Finishing.Title })") }
                    else { $c.Writer.WriteLine('OK'); $exit = $true }
                }
                default { $c.Writer.WriteLine('ERR unknown command') }
            }
            try { $c.Stream.WaitForPipeDrain() } catch { }
        } catch { Write-Log DEBUG "Instance pipe: $($_.Exception.Message)" }
        try { $c.Stream.Dispose() } catch { }
        $script:PipeConns.Remove($c)
    }
    if ($exit) { Write-Log INFO 'A newer version asked this copy to close'; Exit-App }
}
function Stop-InstancePipe {
    foreach ($c in @($script:PipeConns)) { try { $c.Stream.Dispose() } catch { } }
    $script:PipeConns.Clear()
    if ($script:PipeListen) { try { $script:PipeListen.Stream.Dispose() } catch { }; $script:PipeListen = $null }
}

function Exit-App {
    # Really close (not to the tray)
    $script:ReallyExit = $true
    $form.Close()
}

# ---- system tray

$script:TrayUi = $null
$script:ReallyExit = $false
$script:InTray = $false
$script:LastWindowState = 'Normal'

function Initialize-Tray {
    if ($script:TrayUi) { return }
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = if ($script:AppIconSmall) { $script:AppIconSmall } else { [System.Drawing.SystemIcons]::Application }
    $ni.Text = "NRK Browser $($script:AppVersion)"
    $menu = New-ThemedMenu
    $miOpen = New-ThemedMenuItem 'Show NRK Browser'; $miOpen.Font = $script:FontBold
    $miPause = New-ThemedMenuItem 'Pause'
    $miMute = New-ThemedMenuItem 'Mute'
    $miSleep = New-ThemedMenuItem 'Sleep timer...'
    $miUpdate = New-ThemedMenuItem 'Check for updates'
    $miExit = New-ThemedMenuItem 'Exit'
    $miRadioMini = New-ThemedMenuItem 'Small radio window'; $miRadioMini.Add_Click({ Show-RadioMini })
    $miRecs = New-ThemedMenuItem 'Recordings...'; $miRecs.Add_Click({ Show-RecordingsWindow })
    [void]$menu.Items.AddRange(@($miOpen, (New-Object System.Windows.Forms.ToolStripSeparator), $miPause, $miMute, $miSleep, $miRadioMini, $miRecs, (New-Object System.Windows.Forms.ToolStripSeparator), $miUpdate, $miExit))
    $ni.ContextMenuStrip = $menu
    $script:TrayUi = @{ Icon = $ni; Menu = $menu; Open = $miOpen; Pause = $miPause; Mute = $miMute; Sleep = $miSleep; Exit = $miExit; Told = $false }
    $menu.Add_Opening({ Update-TrayMenu })
    $miOpen.Add_Click({ if ($form.Visible -and $form.WindowState -ne 'Minimized') { Hide-ToTray } else { Show-MainWindow } })
    $miPause.Add_Click({ Invoke-MediaCommand 'pause' })
    $miMute.Add_Click({ Invoke-MediaCommand 'mute' })
    $miExit.Add_Click({ Write-Log INFO 'UI: Exit from the tray'; Exit-App })
    $miUpdate.Add_Click({ Write-Log INFO 'UI: check for updates from the tray'; Start-UpdateCheck -Manual -FromTray })
    $miSleep.Add_Click({ Show-SleepMenu $null })
    $ni.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-MainWindow } })
}

function Update-TrayVisibility {
    $want = [bool]((Get-AppSettings).TrayIcon -or $script:InTray -or $Tray)
    if ($want) { Initialize-Tray }
    if ($script:TrayUi) { $script:TrayUi.Icon.Visible = $want }
}

function Set-TrayText([string] $Text) {
    if (-not $script:TrayUi) { return }
    $t = if ($Text) { "NRK Browser - $Text" } else { "NRK Browser $($script:AppVersion)" }
    if ($t.Length -gt 63) { $t = $t.Substring(0, 60) + '...' }   # Windows limit
    $script:TrayUi.Icon.Text = $t
}

function Hide-ToTray([switch] $Quiet) {
    Initialize-Tray
    $script:TrayUi.Icon.Visible = $true
    $pw = $script:PlayerWin
    $script:PlayerHiddenByTray = [bool]($pw -and -not $pw.Form.IsDisposed -and $pw.Form.Visible)
    if ($script:PlayerHiddenByTray) { $pw.Form.Hide() }
    $form.Hide()
    $form.Opacity = 1
    $script:InTray = $true
    Write-Log INFO 'UI: hidden to the tray (playback continues)'
    if (-not $Quiet -and -not $script:TrayUi.Told) {
        $script:TrayUi.Told = $true
        $script:TrayUi.Icon.ShowBalloonTip(4000, 'NRK Browser', 'Still running here - playback continues. Click the icon to open it again.', [System.Windows.Forms.ToolTipIcon]::None)
    }
}

function Show-MainWindow {
    $form.Opacity = 1
    if (-not $form.Visible) { $form.Show() }
    if ($form.WindowState -eq 'Minimized') { $form.WindowState = $script:LastWindowState }
    $form.Activate()
    $pw = $script:PlayerWin
    if ($script:PlayerHiddenByTray -and $pw -and -not $pw.Form.IsDisposed) { $pw.Form.Show() }
    $script:PlayerHiddenByTray = $false
    $script:InTray = $false
    Update-TrayVisibility
    if ($script:ResumePending) { $script:ResumePending = $false; try { Resume-LastPlayed } catch { Write-LogException $_ 'Resume' } }
}

function Get-MediaState {
    $a = $script:AudioUi
    $audioOn = [bool]($a.Current -and $audioBar.Visible)
    $pw = $script:PlayerWin
    $videoOn = [bool]($pw -and -not $pw.Form.IsDisposed -and $pw.Url)
    [pscustomobject]@{
        Audio   = $audioOn; Video = $videoOn
        Playing = (($audioOn -and -not $a.Paused) -or ($videoOn -and -not $pw.Paused))
        Muted   = $(if ($audioOn) { [bool]$a.Muted } elseif ($videoOn) { [bool]$pw.Muted } else { $false })
    }
}

function Update-TrayMenu {
    $m = Get-MediaState
    $u = $script:TrayUi
    $any = ($m.Audio -or $m.Video)
    $u.Pause.Enabled = $any; $u.Mute.Enabled = $any
    $u.Pause.Text = if ($m.Playing) { 'Pause' } else { 'Play' }
    $u.Mute.Text = if ($m.Muted) { 'Unmute' } else { 'Mute' }
    $zl = Get-SleepLabel
    if ($u.Sleep) { $u.Sleep.Text = if ($zl) { "Sleep timer: $zl..." } else { 'Sleep timer...' } }
    $u.Open.Text = if ($form.Visible -and $form.WindowState -ne 'Minimized') { 'Hide NRK Browser' } else { 'Show NRK Browser' }
}

function Invoke-MediaCommand([ValidateSet('pause', 'mute')] [string] $Command) {
    # Tray controls: act on the radio bar and the video player alike
    if ($script:Cast.Session) { Invoke-CastCommand $(if ($Command -eq 'pause') { 'toggle' } else { 'mute' }); return }   # casting: the device
    $m = Get-MediaState
    $pw = $script:PlayerWin
    switch ($Command) {
        'pause' {
            $pause = $m.Playing
            if ($m.Audio) { Invoke-AudioScript ("nrkb.setPaused({0})" -f $pause.ToString().ToLower()); $script:AudioUi.Paused = $pause }
            if ($m.Video) {
                $js = if ($pause) { "document.querySelectorAll('video').forEach(v => v.pause())" } else { "document.querySelectorAll('video').forEach(v => { const p = v.play(); if (p && p.catch) p.catch(() => {}); })" }
                try { [void]$pw.WebView.CoreWebView2.ExecuteScriptAsync($js) } catch { }
                $pw.Paused = $pause
            }
            Write-Log INFO "Tray: $(if ($pause) { 'pause' } else { 'play' })"
        }
        'mute' {
            $mute = -not $m.Muted
            if ($m.Audio) { Invoke-AudioScript ("nrkb.setMuted({0})" -f $mute.ToString().ToLower()); $script:AudioUi.Muted = $mute }
            if ($m.Video) {
                try { [void]$pw.WebView.CoreWebView2.ExecuteScriptAsync(("document.querySelectorAll('video').forEach(v => v.muted = {0})" -f $mute.ToString().ToLower())) } catch { }
                $pw.Muted = $mute
            }
            Write-Log INFO "Tray: $(if ($mute) { 'mute' } else { 'unmute' })"
        }
    }
}

# ---- updates

function Test-WriteAccess([string] $Dir) {
    try {
        $p = Join-Path $Dir ('.nrkb-write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($p, 'x'); Remove-Item -LiteralPath $p -Force
        return $true
    } catch { return $false }
}

function Test-UpdateFile([string] $Path, [version] $Expect) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 50KB) { throw "the downloaded script is too small ($($bytes.Length) bytes)" }
    # Windows PowerShell 5.1 needs the UTF-8 BOM for æ/ø/å (and to parse the file correctly)
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
        $bytes = [byte[]](0xEF, 0xBB, 0xBF) + $bytes
        [IO.File]::WriteAllBytes($Path, $bytes)
        Write-Log INFO 'Update: added the UTF-8 BOM'
    }
    $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$err)
    if (@($err).Count -gt 0) { throw "the downloaded script has syntax errors: $(@($err)[0].Message)" }
    $v = Get-ScriptVersionFromText ([Text.Encoding]::UTF8.GetString($bytes))
    if (-not $v) { throw 'no version line in the downloaded script' }
    if ($Expect -and $v -lt $Expect) { throw "the downloaded script is version $v, expected $Expect" }
    return $v
}

$script:UpdateHelperScript = @'
# Replaces NRK-Browser.ps1 after the app has closed (used when it could not be done in place).
# Everything it needs comes as launch options; it reports back through -ResultFile, which the
# restarted app reads (-UpdateResult) to show whether the update worked.
param([string] $Source, [string] $Target, [int] $ParentPid, [string] $HostExe, [string] $ResultFile, [string] $FromVersion, [switch] $Restart)
try { Wait-Process -Id $ParentPid -Timeout 120 -ErrorAction SilentlyContinue } catch { }
$ok = $false
for ($i = 0; $i -lt 40 -and -not $ok; $i++) {
    try {
        if (Test-Path -LiteralPath $Target) { Copy-Item -LiteralPath $Target -Destination "$Target.bak" -Force }
        Copy-Item -LiteralPath $Source -Destination $Target -Force
        $ok = $true
    } catch { $why = $_.Exception.Message; Start-Sleep -Milliseconds 500 }
}
if ($ResultFile) { try { Set-Content -LiteralPath $ResultFile -Value $(if ($ok) { "ok|$Target" } else { "failed|$why" }) -Encoding UTF8 } catch { } }
if ($Restart) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$Target`"", '-UpdatedFrom', $FromVersion)
    if ($ResultFile) { $a += @('-UpdateResult', "`"$ResultFile`"") }
    Start-Process -FilePath $HostExe -ArgumentList $a -WindowStyle Hidden
}
if (-not $ok) { exit 1 }
'@

function Update-ScriptFile([string] $Source, [string] $Target, [string] $Work, [switch] $RestartAfter) {
    # In place when possible (a running .ps1 is not locked); otherwise a helper after we exit.
    try {
        if (Test-Path -LiteralPath $Target) { Copy-Item -LiteralPath $Target -Destination "$Target.bak" -Force -ErrorAction Stop }
        Copy-Item -LiteralPath $Source -Destination $Target -Force -ErrorAction Stop
        Write-Log INFO "Update: replaced $Target (backup: $Target.bak)"
        return 'replaced'
    } catch {
        Write-Log WARN "Update: could not replace $Target directly ($($_.Exception.Message)); using a helper"
        $helper = Join-Path $Work 'apply-update.ps1'
        [IO.File]::WriteAllText($helper, $script:UpdateHelperScript, (New-Object Text.UTF8Encoding($true)))
        $hostExe = Get-LaunchHost
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$helper`"",
                  '-Source', "`"$Source`"", '-Target', "`"$Target`"", '-ParentPid', $PID, '-HostExe', "`"$hostExe`"",
                  '-ResultFile', "`"$(Join-Path $Work 'result.txt')`"", '-FromVersion', $script:AppVersion)
        if ($RestartAfter) { $argv += '-Restart' }
        $admin = -not (Test-WriteAccess (Split-Path -Parent $Target))
        if ($admin) { Write-Log INFO 'Update: the folder needs administrator rights; asking Windows for approval' }
        $sp = @{ FilePath = $hostExe; ArgumentList = $argv; WindowStyle = 'Hidden' }
        if ($admin) { $sp.Verb = 'RunAs' }
        Start-Process @sp | Out-Null
        return 'helper'
    }
}

function Install-Update {
    param([byte[]] $RemoteBytes, [version] $Version)
    if ($script:DlRun.Finishing) { Set-Status "Update to $Version postponed: a download is being finished - try again in a moment"; return }
    if ($script:DlRun.Proc) {
        $q = [System.Windows.Forms.MessageBox]::Show($form, "A download is running:`n`n$($script:DlRun.Item.Title)`n`nUpdating restarts the app. Stop the download and update now? Its unfinished file is removed; finished downloads are kept.`n`nNo: update later (Options > Check for updates now).", 'Update', 'YesNo', 'Question')
        if ($q -ne 'Yes') { Set-Status "Update to $Version postponed: a download is running"; return }
        $script:ForceExit = $true
    }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('NRK-Browser-update-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $res = @{ File = (Join-Path $work 'NRK-Browser.ps1'); Version = $null }
    Invoke-Ui "Installing version $Version" {
        # the script downloaded for the version check is the update
        [IO.File]::WriteAllBytes($res.File, $RemoteBytes)
        $res.Version = Test-UpdateFile $res.File $Version
    }
    if (-not $res.Version) { Set-Status 'Update failed - details in Logs'; return }

    $targets = @($PSCommandPath)
    $inst = Get-InstallInfo
    if ($inst.Installed -and -not $inst.Running) { $targets += $inst.Script }   # keep the installed copy current too
    $helperUsed = $false
    foreach ($t in ($targets | Where-Object { $_ } | Select-Object -Unique)) {
        $isRunning = ((Get-FullPath $t) -eq (Get-FullPath $PSCommandPath))
        if ((Update-ScriptFile $res.File $t $work -RestartAfter:$isRunning) -eq 'helper' -and $isRunning) { $helperUsed = $true }
    }
    Write-Log INFO "Update to $($res.Version) prepared (helper: $helperUsed)"
    if ($helperUsed) {
        [void][System.Windows.Forms.MessageBox]::Show($form, "NRK Browser will now close, update itself to $($res.Version) and start again.", 'Update', 'OK', 'Information')
        Exit-App
        return
    }
    $q = [System.Windows.Forms.MessageBox]::Show($form, "Updated to version $($res.Version).`n`nRestart now to use it?", 'Update installed', 'YesNo', 'Question')
    if ($q -eq 'Yes') { Start-AppDetached -ExtraArgs "-UpdatedFrom $($script:AppVersion)"; Exit-App }
    else { Set-Status "Version $($res.Version) is installed and starts next time." }
}

function Format-AppVersion($Version) {
    # 2.7.4.0 -> 2.7.4 (the way the version line is written)
    try { $v = [version]"$Version" } catch { return "$Version" }
    if ($v.Revision -gt 0) { return '{0}.{1}.{2}.{3}' -f $v.Major, $v.Minor, $v.Build, $v.Revision }
    return '{0}.{1}.{2}' -f $v.Major, $v.Minor, [Math]::Max(0, $v.Build)
}

function Resolve-Update {
    param([byte[]] $Bytes, [switch] $Manual, [switch] $FromTray)
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $remote = Get-ScriptVersionFromText $text
    $local = ConvertTo-AppVersion $script:AppVersion
    $st = Get-AppSettings; $st.LastUpdateCheck = (Get-Date).ToString('o'); Save-AppSettings $st
    if (-not $remote) {
        Write-Log WARN "Update check: no version line found in $($script:UpdateScriptUrl)"
        if ($Manual) { [void][System.Windows.Forms.MessageBox]::Show($form, "Could not read the version from GitHub:`n$($script:UpdateScriptUrl)", 'Updates', 'OK', 'Warning') }
        return
    }
    Write-Log INFO "Update check: GitHub has $(Format-AppVersion $remote), this is $(Format-AppVersion $local)"
    $script:LastUpdateResult = if ($remote -le $local) { 'latest' } else { "$remote" }
    if ($remote -le $local) {
        if ($FromTray -and $script:TrayUi) { $script:TrayUi.Icon.ShowBalloonTip(4000, 'NRK Browser', "You have the latest version ($(Format-AppVersion $local)).", [System.Windows.Forms.ToolTipIcon]::None) }
        elseif ($Manual) { [void][System.Windows.Forms.MessageBox]::Show($form, "You have the latest version ($(Format-AppVersion $local)).", 'Updates', 'OK', 'Information') }
        return
    }
    $remote = [version](Format-AppVersion $remote); $local = [version](Format-AppVersion $local)   # (shown as 2.7.4, not 2.7.4.0)
    if ($FromTray) { Show-MainWindow }
    if (-not $Manual -and $st.SkippedVersion -eq "$remote") { Write-Log INFO "Update check: $remote was skipped by the user"; return }
    if (-not $Manual -and -not $form.Visible) {
        # in the tray: just tell, don't pop up a dialog
        if ($script:TrayUi) { $script:TrayUi.Icon.ShowBalloonTip(6000, 'NRK Browser', "Version $remote is available. Open the app and go to Options > Updates.", [System.Windows.Forms.ToolTipIcon]::None) }
        return
    }
    $buttons = @('Update now', 'Later'); if (-not $Manual) { $buttons += 'Skip this version' }
    $choice = Show-ChoiceDialog -Owner $form -Title 'Update available' -Buttons $buttons -Text ("NRK Browser {0} is available (you have {1}).`n`nThe new version is downloaded from github.com/{2} and replaces`n{3}`nThe old file is kept as .bak next to it." -f $remote, $local, $script:UpdateRepo, $PSCommandPath)
    if ($choice -eq 2) { $st = Get-AppSettings; $st.SkippedVersion = "$remote"; Save-AppSettings $st; Write-Log INFO "Update: skipping $remote"; return }
    if ($choice -ne 0) { return }
    Install-Update -RemoteBytes $Bytes -Version $remote
}

function Start-UpdateCheck([switch] $Manual, [switch] $FromTray) {
    if ($Manual) {
        # pressed by hand (Options or the tray): at most once a minute, so it can't hammer GitHub
        $ago = if ($script:LastManualCheck) { ((Get-Date) - $script:LastManualCheck).TotalSeconds } else { 9999 }
        if ($ago -lt 60) {
            $wait = [int][Math]::Ceiling(60 - $ago)
            $msg = if ($script:LastUpdateResult -eq 'latest') { "You have the latest version ($($script:AppVersion)). Checked $([int]$ago) s ago: you can check again in $wait s." } else { "Checked $([int]$ago) s ago: you can check again in $wait s." }
            if ($FromTray -and $script:TrayUi) { $script:TrayUi.Icon.ShowBalloonTip(4000, 'NRK Browser', $msg, [System.Windows.Forms.ToolTipIcon]::None) }
            else { [void][System.Windows.Forms.MessageBox]::Show($form, $msg, 'Updates', 'OK', 'Information') }
            return
        }
        $script:LastManualCheck = Get-Date
        $res = @{ Bytes = $null }
        Invoke-Ui 'Checking for updates' {
            $r = Invoke-WebRequest -Uri $script:UpdateScriptUrl -UseBasicParsing -TimeoutSec 20 -UserAgent $script:UserAgent -Headers @{ 'Cache-Control' = 'no-cache' }
            $res.Bytes = $r.RawContentStream.ToArray()
        }
        if ($res.Bytes) { Resolve-Update $res.Bytes -Manual -FromTray:$FromTray }
        elseif ($FromTray -and $script:TrayUi) { $script:TrayUi.Icon.ShowBalloonTip(4000, 'NRK Browser', 'Could not reach GitHub to check for updates.', [System.Windows.Forms.ToolTipIcon]::Warning) }
        return
    }
    # automatic: in the background, so a slow or missing network never blocks the window
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = $script:UserAgent
        $wc.Headers['Cache-Control'] = 'no-cache'
        $script:UpdateJob = @{ Client = $wc; Task = $wc.DownloadDataTaskAsync($script:UpdateScriptUrl); Timer = (New-Object System.Windows.Forms.Timer) }
        $script:UpdateJob.Timer.Interval = 500
        $script:UpdateJob.Timer.Add_Tick({
            $j = $script:UpdateJob
            if (-not $j.Task.IsCompleted) { return }
            $j.Timer.Stop(); $j.Timer.Dispose()
            if ($j.Task.IsFaulted) { Write-Log WARN "Automatic update check failed: $($j.Task.Exception.GetBaseException().Message)" }
            else { try { Resolve-Update $j.Task.Result } catch { Write-LogException $_ 'Update check' } }
            $j.Client.Dispose(); $script:UpdateJob = $null
        })
        $script:UpdateJob.Timer.Start()
        Write-Log INFO "Automatic update check: $($script:UpdateScriptUrl)"
    } catch { Write-Log WARN "Automatic update check could not start: $($_.Exception.Message)" }
}

function Test-UpdateDue {
    $st = Get-AppSettings
    if (-not $st.CheckUpdates) { return $false }
    try { if ($st.LastUpdateCheck -and ((Get-Date) - [datetime]$st.LastUpdateCheck).TotalHours -lt 12) { return $false } } catch { }
    return $true
}


$script:WinHelpersCs = @'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// 2.9.0: Windows integration for NRK Browser (C# 5, compiled by Windows PowerShell 5.1 and PowerShell 7).
//   NrkHotkeys  - global hotkeys (RegisterHotKey on a hidden message window)
//   NrkTaskbar  - buttons in the taskbar preview (ITaskbarList3) and the taskbar jump list (ICustomDestinationList)
//   NrkRemote   - the phone remote: a tiny web server on the home network (commands are queued for the app)

public class NrkHotkeys : NativeWindow, IDisposable {
    [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    readonly Action<int> onKey;
    readonly List<int> ids = new List<int>();
    public NrkHotkeys(Action<int> onKey) {
        this.onKey = onKey;
        var cp = new CreateParams(); cp.Parent = new IntPtr(-3);   // HWND_MESSAGE: a window nobody sees
        CreateHandle(cp);
    }
    // mods: 1 Alt, 2 Ctrl, 4 Shift, 8 Win (0x4000 = no repeat is added). false = taken by another app
    public bool Add(int id, uint mods, uint vk) {
        bool ok = RegisterHotKey(Handle, id, mods | 0x4000, vk);
        if (ok) ids.Add(id);
        return ok;
    }
    public void Clear() { foreach (int id in ids) UnregisterHotKey(Handle, id); ids.Clear(); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) { try { onKey(m.WParam.ToInt32()); } catch { } return; }
        base.WndProc(ref m);
    }
    public void Dispose() { Clear(); DestroyHandle(); }
}

[ComImport, Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITaskbarList3 {
    void HrInit(); void AddTab(IntPtr h); void DeleteTab(IntPtr h); void ActivateTab(IntPtr h); void SetActiveAlt(IntPtr h);
    void MarkFullscreenWindow(IntPtr h, [MarshalAs(UnmanagedType.Bool)] bool full);
    void SetProgressValue(IntPtr h, ulong done, ulong total); void SetProgressState(IntPtr h, int flags);
    void RegisterTab(IntPtr tab, IntPtr main); void UnregisterTab(IntPtr tab); void SetTabOrder(IntPtr tab, IntPtr before);
    void SetTabActive(IntPtr tab, IntPtr main, uint res);
    [PreserveSig] int ThumbBarAddButtons(IntPtr h, uint count, [MarshalAs(UnmanagedType.LPArray)] ThumbButton[] buttons);
    [PreserveSig] int ThumbBarUpdateButtons(IntPtr h, uint count, [MarshalAs(UnmanagedType.LPArray)] ThumbButton[] buttons);
    void ThumbBarSetImageList(IntPtr h, IntPtr list);
    void SetOverlayIcon(IntPtr h, IntPtr icon, [MarshalAs(UnmanagedType.LPWStr)] string text);
    void SetThumbnailTooltip(IntPtr h, [MarshalAs(UnmanagedType.LPWStr)] string tip);
    void SetThumbnailClip(IntPtr h, IntPtr rect);
}
[ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090"), ClassInterface(ClassInterfaceType.None)] class CTaskbarList { }

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
struct ThumbButton {
    public uint Mask; public uint Id; public uint Bitmap; public IntPtr Icon;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Tip;
    public uint Flags;
}

[ComImport, Guid("6332DEBF-87B5-4670-90C0-5E57B408A49E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICustomDestinationList {
    void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string id);
    void BeginList(out uint minSlots, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object removed);
    void AppendCategory([MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.Interface)] IObjectArray items);
    void AppendKnownCategory(int category);
    void AddUserTasks([MarshalAs(UnmanagedType.Interface)] IObjectArray tasks);
    void CommitList();
    void GetRemovedDestinations(ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object removed);
    void DeleteList([MarshalAs(UnmanagedType.LPWStr)] string id);
    void AbortList();
}
[ComImport, Guid("77f10cf0-3db5-4966-b520-b7c54fd35ed6"), ClassInterface(ClassInterfaceType.None)] class CDestinationList { }
[ComImport, Guid("92CA9DCD-5622-4bba-A805-5E9F541BD8C9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IObjectArray { void GetCount(out uint n); void GetAt(uint i, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object o); }
[ComImport, Guid("5632b1a4-e38a-400a-928a-d4cd63230295"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IObjectCollection {
    void GetCount(out uint n); void GetAt(uint i, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object o);
    void AddObject([MarshalAs(UnmanagedType.Interface)] object o); void AddFromArray([MarshalAs(UnmanagedType.Interface)] IObjectArray a);
    void RemoveObjectAt(uint i); void Clear();
}
[ComImport, Guid("2d3468c1-36a7-43b6-ac24-d3f02fd9607a"), ClassInterface(ClassInterfaceType.None)] class CEnumerableObjectCollection { }
[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellLinkW {
    void GetPath(IntPtr a, int b, IntPtr c, int d); void GetIDList(out IntPtr p); void SetIDList(IntPtr p);
    void GetDescription(IntPtr a, int b); void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string s);
    void GetWorkingDirectory(IntPtr a, int b); void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string s);
    void GetArguments(IntPtr a, int b); void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string s);
    void GetHotkey(out short k); void SetHotkey(short k); void GetShowCmd(out int c); void SetShowCmd(int c);
    void GetIconLocation(IntPtr a, int b, out int c); void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string s, int i);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string s, int r); void Resolve(IntPtr h, int f);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string s);
}
[ComImport, Guid("00021401-0000-0000-C000-000000000046"), ClassInterface(ClassInterfaceType.None)] class CShellLink { }
[StructLayout(LayoutKind.Sequential, Pack = 4)] struct PropKey { public Guid Fmt; public uint Pid; }
[StructLayout(LayoutKind.Explicit)] struct PropVariant { [FieldOffset(0)] public ushort Vt; [FieldOffset(8)] public IntPtr Ptr; }
[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore {
    void GetCount(out uint n); void GetAt(uint i, out PropKey k); void GetValue(ref PropKey k, out PropVariant v);
    void SetValue(ref PropKey k, ref PropVariant v); void Commit();
}

public class NrkTaskbar : NativeWindow {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessage(string s);
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant v);
    readonly Action<int> onButton;
    readonly uint createdMsg;
    ITaskbarList3 bar;
    bool added;
    ThumbButton[] buttons;
    public NrkTaskbar(IntPtr form, Action<int> onButton) {
        this.onButton = onButton;
        createdMsg = RegisterWindowMessage("TaskbarButtonCreated");
        AssignHandle(form);
    }
    // the buttons: Previous (1), Play/Pause (2), Next (3); icons drawn by the app
    public void SetButtons(Icon prev, Icon play, Icon next, string tipPrev, string tipPlay, string tipNext) {
        buttons = new ThumbButton[] { Btn(1, prev, tipPrev), Btn(2, play, tipPlay), Btn(3, next, tipNext) };
        Push();   // (the taskbar button usually exists already; if not, TaskbarButtonCreated adds them)
    }
    static ThumbButton Btn(uint id, Icon ic, string tip) {
        ThumbButton b = new ThumbButton(); b.Id = id; b.Icon = ic == null ? IntPtr.Zero : ic.Handle; b.Tip = tip ?? ""; b.Mask = 0x2 | 0x4 | 0x8; b.Flags = 0;   // icon | tooltip | flags
        return b;
    }
    public void Update(int id, Icon ic, string tip, bool enabled) {
        if (buttons == null) return;
        for (int i = 0; i < buttons.Length; i++) if (buttons[i].Id == id) { if (ic != null) buttons[i].Icon = ic.Handle; buttons[i].Tip = tip ?? buttons[i].Tip; buttons[i].Flags = enabled ? 0u : 1u; }
        if (bar != null && added) { try { bar.ThumbBarUpdateButtons(Handle, (uint)buttons.Length, buttons); } catch { } }
    }
    void Push() {
        try {
            if (bar == null) { bar = (ITaskbarList3)new CTaskbarList(); bar.HrInit(); }
            if (!added) { if (bar.ThumbBarAddButtons(Handle, (uint)buttons.Length, buttons) == 0) added = true; }
            else bar.ThumbBarUpdateButtons(Handle, (uint)buttons.Length, buttons);
        } catch { }
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == (int)createdMsg && buttons != null) { added = false; bar = null; Push(); }
        else if (m.Msg == 0x0111 && ((m.WParam.ToInt64() >> 16) & 0xFFFF) == 0x1800) { try { onButton((int)(m.WParam.ToInt64() & 0xFFFF)); } catch { } }
        base.WndProc(ref m);
    }
    // the jump list: right-click the taskbar button -> these channels start straight away
    public static string SetJumpList(string appId, string category, string exe, string[] titles, string[] args, string icon, int iconIndex) {
        try {
            ICustomDestinationList list = (ICustomDestinationList)new CDestinationList();
            list.SetAppID(appId);
            uint slots; object removed; Guid g = typeof(IObjectArray).GUID;
            list.BeginList(out slots, ref g, out removed);
            IObjectCollection items = (IObjectCollection)new CEnumerableObjectCollection();
            Guid title = new Guid("F29F85E0-4FF9-1068-AB91-08002B27B3D9");
            for (int i = 0; i < titles.Length; i++) {
                IShellLinkW link = (IShellLinkW)new CShellLink();
                link.SetPath(exe); link.SetArguments(args[i]); link.SetDescription(titles[i]);
                if (!string.IsNullOrEmpty(icon)) link.SetIconLocation(icon, iconIndex);
                link.SetShowCmd(7);   // minimized: the console never shows
                IPropertyStore ps = (IPropertyStore)link;
                PropKey k = new PropKey(); k.Fmt = title; k.Pid = 2;
                PropVariant v = new PropVariant(); v.Vt = 31; v.Ptr = Marshal.StringToCoTaskMemUni(titles[i]);   // VT_LPWSTR
                ps.SetValue(ref k, ref v); ps.Commit(); PropVariantClear(ref v);
                items.AddObject(link);
            }
            if (titles.Length > 0) list.AppendCategory(category, (IObjectArray)items);
            list.CommitList();
            return "";
        } catch (Exception e) { return e.Message; }
    }
}

public class NrkRemote {
    TcpListener listener; Thread loop; volatile bool running;
    public string Key = ""; public string Page = ""; public volatile string State = "{}";
    public int Port;
    public readonly ConcurrentQueue<string> Commands = new ConcurrentQueue<string>();
    public readonly ConcurrentQueue<string> Log = new ConcurrentQueue<string>();
    public int Start(int first) {
        for (int p = first; p < first + 10; p++) {
            try { listener = new TcpListener(IPAddress.Any, p); listener.Start(); Port = p; break; } catch { listener = null; }
        }
        if (listener == null) return 0;
        running = true;
        loop = new Thread(Run); loop.IsBackground = true; loop.Start();
        return Port;
    }
    public void Stop() { running = false; try { listener.Stop(); } catch { } }
    static bool Local(IPAddress a) {
        if (IPAddress.IsLoopback(a)) return true;
        if (a.IsIPv4MappedToIPv6) a = a.MapToIPv4();
        if (a.AddressFamily == AddressFamily.InterNetworkV6) return a.IsIPv6LinkLocal || a.IsIPv6SiteLocal || (a.GetAddressBytes()[0] & 0xFE) == 0xFC;
        byte[] b = a.GetAddressBytes();
        return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254);
    }
    void Run() {
        while (running) {
            TcpClient c = null;
            try { c = listener.AcceptTcpClient(); } catch { if (!running) return; continue; }
            ThreadPool.QueueUserWorkItem(o => Serve((TcpClient)o), c);
        }
    }
    void Serve(TcpClient c) {
        try {
            using (c) {
                c.ReceiveTimeout = 5000; c.SendTimeout = 5000;
                NetworkStream s = c.GetStream();
                StreamReader r = new StreamReader(s, Encoding.ASCII);
                string line = r.ReadLine(); if (line == null) return;
                string h; while (!string.IsNullOrEmpty(h = r.ReadLine())) { }
                string[] parts = line.Split(' ');
                string path = parts.Length > 1 ? parts[1] : "/";
                IPAddress from = ((IPEndPoint)c.Client.RemoteEndPoint).Address;
                if (!Local(from)) { Send(s, 403, "text/plain", "home network only"); return; }
                string q = path.Contains("?") ? path.Substring(path.IndexOf('?') + 1) : "";
                string p = path.Contains("?") ? path.Substring(0, path.IndexOf('?')) : path;
                Dictionary<string, string> args = new Dictionary<string, string>();
                foreach (string kv in q.Split('&')) { int i = kv.IndexOf('='); if (i > 0) args[kv.Substring(0, i)] = Uri.UnescapeDataString(kv.Substring(i + 1).Replace('+', ' ')); }
                string k; args.TryGetValue("k", out k);
                if (string.IsNullOrEmpty(Key) || k != Key) { Send(s, 403, "text/plain", "wrong or missing key: open the address shown in NRK Browser (Options > Phone remote)"); return; }
                if (p == "/" || p == "/remote") { Send(s, 200, "text/html; charset=utf-8", Page); return; }
                if (p == "/state") { Send(s, 200, "application/json; charset=utf-8", State); return; }
                if (p == "/cmd") { string cmd; if (args.TryGetValue("c", out cmd) && cmd.Length < 200) { Commands.Enqueue(cmd); Log.Enqueue(from + " " + cmd); } Send(s, 200, "application/json", "{\"ok\":true}"); return; }
                Send(s, 404, "text/plain", "not found");
            }
        } catch { }
    }
    static void Send(Stream s, int code, string type, string body) {
        byte[] b = Encoding.UTF8.GetBytes(body ?? "");
        string head = "HTTP/1.1 " + code + (code == 200 ? " OK" : code == 403 ? " Forbidden" : " Not Found") + "\r\nContent-Type: " + type + "\r\nContent-Length: " + b.Length +
                      "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
        byte[] hb = Encoding.ASCII.GetBytes(head);
        s.Write(hb, 0, hb.Length); s.Write(b, 0, b.Length); s.Flush();
    }
}
'@

#region ---------- 2.9.0 features (see CHANGES-2.9.0.md) -------------------------------------
# Everything new in 2.9.0 that is not inside an existing function lives here, so it is easy to
# find (and to take out again). Settings: $script:SettingDefaults, the "2.9.0" block.

# ---- per series: speed, skip the intro / the outro (seriesprefs.json) --------------------------
$script:SeriesPrefsFile = Join-Path $script:AppDataDir 'seriesprefs.json'
$script:SeriesPrefs = $null

function Get-SeriesPrefKey($File) {
    # radio series / podcasts: "radio|<series id>"; TV series: "series|<id>"; otherwise none
    if (-not $File) { return $null }
    if ($File.Type -eq 'audio' -and $File.SeriesId) { return "radio|$($File.SeriesId)" }
    if ($File.SeriesItem -and $File.SeriesItem.Id) { return "series|$($File.SeriesItem.Id)" }
    return $null
}

function Get-SeriesPrefs {
    if ($null -ne $script:SeriesPrefs) { return $script:SeriesPrefs }
    $m = @{}
    $j = Read-JsonFile $script:SeriesPrefsFile
    if ($j) { foreach ($p in $j.PSObject.Properties) { $m[$p.Name] = @{ Title = [string]$p.Value.Title; Rate = [double]$p.Value.Rate; Intro = [int]$p.Value.Intro; Outro = [int]$p.Value.Outro } } }
    $script:SeriesPrefs = $m
    return $m
}

function Get-SeriesPref([string] $Key) {
    if (-not $Key) { return @{ Rate = 0.0; Intro = 0; Outro = 0 } }
    $m = Get-SeriesPrefs
    if ($m.ContainsKey($Key)) { return $m[$Key] }
    return @{ Rate = 0.0; Intro = 0; Outro = 0 }
}

function Set-SeriesPref([string] $Key, [string] $Title, [hashtable] $Values) {
    if (-not $Key) { return }
    $m = Get-SeriesPrefs
    $r = if ($m.ContainsKey($Key)) { $m[$Key] } else { @{ Title = $Title; Rate = 0.0; Intro = 0; Outro = 0 } }
    foreach ($k in $Values.Keys) { $r[$k] = $Values[$k] }
    if ($Title) { $r.Title = $Title }
    if ([double]$r.Rate -le 0 -and [int]$r.Intro -le 0 -and [int]$r.Outro -le 0) { $m.Remove($Key) } else { $m[$Key] = $r }   # (all default: forget it)
    $o = [ordered]@{}; foreach ($k in ($m.Keys | Sort-Object)) { $o[$k] = $m[$k] }
    Write-JsonFile $script:SeriesPrefsFile $o
}

function Send-AudioFx {
    # skip silences / voice boost (Options > Listening, or the bars button in the radio bar)
    $st = Get-AppSettings
    Invoke-AudioScript ("nrkb.setFx({{""silence"":{0},""boost"":{1}}})" -f ([bool]$st.SkipSilence).ToString().ToLower(), ([bool]$st.VoiceBoost).ToString().ToLower())
}

function Show-AudioFxMenu {
    if (-not $script:FxMenu) { $script:FxMenu = New-ThemedMenu }
    $m = $script:FxMenu; $m.Items.Clear()
    $st = Get-AppSettings
    $a = New-ThemedMenuItem 'Skip silences (quiet parts play faster)'; $a.Checked = [bool]$st.SkipSilence
    $a.Add_Click({ $s = Get-AppSettings; $s.SkipSilence = -not [bool]$s.SkipSilence; Save-AppSettings $s; Send-AudioFx; Write-Log INFO "Option SkipSilence = $($s.SkipSilence)" })
    $b = New-ThemedMenuItem 'Voice boost (clearer, more even speech)'; $b.Checked = [bool]$st.VoiceBoost
    $b.Add_Click({ $s = Get-AppSettings; $s.VoiceBoost = -not [bool]$s.VoiceBoost; Save-AppSettings $s; Send-AudioFx; Write-Log INFO "Option VoiceBoost = $($s.VoiceBoost)" })
    [void]$m.Items.AddRange(@($a, $b))
    $cur = $script:AudioUi.Current
    $key = Get-SeriesPrefKey $cur
    if ($key) {
        [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $title = if ($cur.SeriesTitle) { [string]$cur.SeriesTitle } else { [string]$cur.Title }
        $c = New-ThemedMenuItem ("Settings for {0}..." -f $title); $c.Tag = @{ Key = $key; Title = $title }
        $c.Add_Click({ Show-SeriesPrefsDialog $this.Tag.Key $this.Tag.Title })
        [void]$m.Items.Add($c)
    }
    $m.Show([System.Windows.Forms.Cursor]::Position)
}

function Show-SeriesPrefsDialog([string] $Key, [string] $Title) {
    # speed, skip the first / the last seconds - for one series or podcast
    $p = Get-SeriesPref $Key
    $d = New-Object System.Windows.Forms.Form
    Set-AppIcon $d
    $d.Text = "Listening settings - $Title"; $d.ClientSize = New-Object System.Drawing.Size(440, 236); $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.Font = $script:FontUi; $d.BackColor = $T.Bg; $d.ForeColor = $T.Text
    $mk = { param($t, $x, $y) $l = New-Object System.Windows.Forms.Label; $l.Text = $t; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point($x, $y); $d.Controls.Add($l); $l }
    [void](& $mk $Title 18 14); $d.Controls[0].Font = $script:FontBold
    [void](& $mk 'Speed' 20 56)
    $rates = @(0, 0.75, 1, 1.25, 1.5, 1.75, 2)
    $cb = New-Object System.Windows.Forms.ComboBox; $cb.DropDownStyle = 'DropDownList'; $cb.FlatStyle = 'Flat'; $cb.Width = 200; $cb.Location = New-Object System.Drawing.Point(200, 52)
    [void]$cb.Items.AddRange(@('The general speed', '0.75x', '1x', '1.25x', '1.5x', '1.75x', '2x'))
    $cb.SelectedIndex = [Math]::Max(0, [array]::IndexOf($rates, [double]$p.Rate)); $d.Controls.Add($cb)
    [void](& $mk 'Skip the first (seconds)' 20 96)
    $n1 = New-Object System.Windows.Forms.NumericUpDown; $n1.Minimum = 0; $n1.Maximum = 900; $n1.Value = [Math]::Min(900, [int]$p.Intro); $n1.Width = 80; $n1.Location = New-Object System.Drawing.Point(200, 92); $d.Controls.Add($n1)
    [void](& $mk 'Skip the last (seconds)' 20 134)
    $n2 = New-Object System.Windows.Forms.NumericUpDown; $n2.Minimum = 0; $n2.Maximum = 900; $n2.Value = [Math]::Min(900, [int]$p.Outro); $n2.Width = 80; $n2.Location = New-Object System.Drawing.Point(200, 130); $d.Controls.Add($n2)
    $note = & $mk 'Skipping the first part: only when it starts from the beginning.' 20 166; $note.ForeColor = $T.Muted
    $ok = New-FlatButton 'Save' 90 -Primary; $ok.Location = New-Object System.Drawing.Point(236, 194); $ok.DialogResult = 'OK'; $d.Controls.Add($ok)
    $no = New-FlatButton 'Cancel' 90; $no.Location = New-Object System.Drawing.Point(334, 194); $no.DialogResult = 'Cancel'; $d.Controls.Add($no)
    $d.AcceptButton = $ok; $d.CancelButton = $no
    Set-DarkTheme $d; Enable-DarkTitleBar $d
    if ($d.ShowDialog($form) -ne 'OK') { return }
    Set-SeriesPref $Key $Title @{ Rate = [double]$rates[$cb.SelectedIndex]; Intro = [int]$n1.Value; Outro = [int]$n2.Value }
    Write-Log INFO ("Series settings {0}: speed {1}, skip first {2} s, last {3} s" -f $Key, $rates[$cb.SelectedIndex], $n1.Value, $n2.Value)
    # playing now: at once
    if ((Get-SeriesPrefKey $script:AudioUi.Current) -eq $Key) {
        if ($rates[$cb.SelectedIndex] -gt 0) { Invoke-AudioScript ("nrkb.setRate({0})" -f ([double]$rates[$cb.SelectedIndex]).ToString([Globalization.CultureInfo]::InvariantCulture)) }
        Invoke-AudioScript ("nrkb.setSkip({{""intro"":{0},""outro"":{1}}})" -f [int]$n1.Value, [int]$n2.Value)
    }
}

# ---- live radio: the song playing now (NRK: /channels/<id>/liveelements/now) ------------------
function Start-NowPlaying {
    if (-not $script:NowTimer) {
        $script:NowTimer = New-Object System.Windows.Forms.Timer
        $script:NowTimer.Interval = 30000
        $script:NowTimer.Add_Tick({ Update-NowPlaying })
    }
    $script:NowLast = ''
    $script:NowTimer.Start()
    Update-NowPlaying
}

function Update-NowPlaying {
    $u = $script:AudioUi
    if (-not $u.Current -or $u.Current.Type -ne 'radiolive' -or -not (Get-AppSettings).NowPlaying) { if ($script:NowTimer) { $script:NowTimer.Stop() }; return }
    if ($script:NowJob) { return }
    $id = [string]$u.Current.Id
    $script:NowJob = Start-ApiJob "Now playing on $id" { param($cid) Invoke-NrkApi ('/channels/{0}/liveelements/now' -f [uri]::EscapeDataString($cid)) } {
        param($j, $cid)
        $script:NowJob = $null
        if (-not $script:AudioUi.Current -or [string]$script:AudioUi.Current.Id -ne $cid) { return }
        $els = @(if ($j -is [array]) { $j } else { foreach ($n in 'liveElements', 'elements', 'items') { $v = Get-Prop $j $n; if ($v) { $v; break } } }) | Where-Object { $_ }
        $songs = New-Object System.Collections.Generic.List[string]
        $nowSong = $null
        foreach ($e in @($els)) {
            if ([string](Get-Prop $e 'type') -ne 'Music') { continue }
            $when = [string](Get-Prop $e 'relativeTimeType')
            if ($when -notin 'Past', 'Present') { continue }
            $t = [string](Get-Prop $e 'title'); $a = [string](Get-Prop $e 'description')
            $txt = if ($a) { "$a - $t" } else { $t }
            if ($when -eq 'Present') { $nowSong = $txt } else { $songs.Insert(0, "(earlier) $txt") }
        }
        if ($nowSong) { $songs.Insert(0, $nowSong) }
        $list = @($songs | Select-Object -First 6)
        Invoke-AudioScript ("nrkb.song({0})" -f (ConvertTo-Json -InputObject @($list) -Compress))
        if ($nowSong -and $nowSong -ne $script:NowLast) {
            $script:NowLast = $nowSong
            Write-Log INFO "Now playing on $($cid): $nowSong"
            Set-TrayText ("{0}  {1} {2}" -f $script:AudioUi.Current.Title, [char]0x266A, $nowSong)
        }
    } { param($err, $cid) $script:NowJob = $null; Write-Log DEBUG "Now playing on $($cid): $($err.Exception.Message)" } $id
}

# ---- a small radio window that stays on top ----------------------------------------------------
function Show-RadioMini {
    if ($script:RadioMini -and -not $script:RadioMini.Form.IsDisposed) { $script:RadioMini.Form.Close(); return }
    $w = New-Object System.Windows.Forms.Form
    Set-AppIcon $w
    $w.Text = 'NRK Radio'; $w.FormBorderStyle = 'FixedToolWindow'; $w.TopMost = $true; $w.ShowInTaskbar = $false
    $w.ClientSize = New-Object System.Drawing.Size(380, 92); $w.StartPosition = 'Manual'
    $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $w.Location = New-Object System.Drawing.Point(($wa.Right - 400), ($wa.Bottom - 140))
    $w.Font = $script:FontUi; $w.BackColor = $T.Panel; $w.ForeColor = $T.Text
    $t1 = New-Object System.Windows.Forms.Label; $t1.Location = New-Object System.Drawing.Point(12, 8); $t1.Size = New-Object System.Drawing.Size(356, 20); $t1.Font = $script:FontBold; $t1.AutoEllipsis = $true; $t1.UseMnemonic = $false
    $t2 = New-Object System.Windows.Forms.Label; $t2.Location = New-Object System.Drawing.Point(12, 28); $t2.Size = New-Object System.Drawing.Size(356, 18); $t2.ForeColor = $T.Muted; $t2.AutoEllipsis = $true; $t2.UseMnemonic = $false
    $w.Controls.AddRange(@($t1, $t2))
    $x = 12
    $btns = @{}
    $tips = New-Object System.Windows.Forms.ToolTip
    foreach ($b in @(@('prev', [string][char]0x23EE, 'Previous'), @('back', '-15', 'Back 15 seconds'), @('play', [string][char]0x23EF, 'Play / pause'), @('fwd', '+15', 'Forward 15 seconds'), @('next', [string][char]0x23ED, 'Next'), @('show', 'Open', 'Show NRK Browser'))) {
        $bt = New-FlatButton $b[1] $(if ($b[0] -eq 'show') { 70 } else { 50 }); $bt.Location = New-Object System.Drawing.Point($x, 52); $bt.Height = 32; $bt.Tag = $b[0]
        $tips.SetToolTip($bt, $b[2])
        # 2.9.2: icons in the chosen look (the -15 / +15 keep their numbers)
        switch ($b[0]) {
            'prev' { Set-IconText $bt 'previous' '' $b[1] -IconOnly }
            'next' { Set-IconText $bt 'next' '' $b[1] -IconOnly }
            'play' { Set-IconText $bt 'pause' '' ([string][char]0x2016) -IconOnly }
            'back' { Set-IconText $bt 'rewind' '15' -Plain '-15' }
            'fwd' { Set-IconText $bt 'forward' '15' -Plain '+15' }
            'show' { Set-IconText $bt 'window' 'Open' '' }
        }
        $bt.Add_Click({ switch ($this.Tag) { 'prev' { Start-NextAudio -1 } 'next' { Start-NextAudio 1 } 'back' { Invoke-AudioScript 'nrkb.skip(-15)' } 'fwd' { Invoke-AudioScript 'nrkb.skip(15)' } 'play' { Invoke-AudioScript 'nrkb.toggle()' } 'show' { Show-MainWindow } } })
        $w.Controls.Add($bt); $btns[$b[0]] = $bt; $x += $bt.Width + 6
    }
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000
    $script:RadioMini = @{ Form = $w; T1 = $t1; T2 = $t2; Btn = $btns; Timer = $timer; Task = $null }
    $timer.Add_Tick({
        $r = $script:RadioMini
        if (-not $r -or $r.Form.IsDisposed) { return }
        $u = $script:AudioUi
        if ($r.Task -and $r.Task.IsCompleted) {
            try {
                $s = ([string]$r.Task.Result | ConvertFrom-Json) | ConvertFrom-Json; $r.T1.Text = [string]$s.title; $r.T2.Text = [string]$s.sub
                if ($r.Paused -ne [bool]$s.paused) { $r.Paused = [bool]$s.paused; if ($s.paused) { Set-IconText $r.Btn.play 'play' '' ([string][char]0x25B6) -IconOnly } else { Set-IconText $r.Btn.play 'pause' '' ([string][char]0x2016) -IconOnly } }
            } catch { }
            $r.Task = $null
        }
        if (-not $u.Current) { $r.T1.Text = 'Nothing playing'; $r.T2.Text = ''; return }
        if (-not $r.Task -and $u.Ready -and $u.WebView -and $u.WebView.CoreWebView2) { try { $r.Task = $u.WebView.CoreWebView2.ExecuteScriptAsync('window.nrkb ? nrkb.state() : "{}"') } catch { } }
    })
    $w.Add_FormClosed({ $script:RadioMini.Timer.Stop(); $script:RadioMini.Timer.Dispose(); $script:RadioMini = $null })
    Set-DarkTheme $w; Enable-DarkTitleBar $w
    $w.BackColor = $T.Panel
    $timer.Start()
    $w.Show()
    Write-Log INFO 'Radio: small window'
}

# ---- sleep timer: fade out --------------------------------------------------------------------
function Invoke-PlayerFade([double] $Seconds) {
    # $Seconds > 0: the video goes quiet over that time; 0: the volume back (built-in player or NRK's page)
    $pw = $script:PlayerWin
    if (-not $pw -or -not $pw.WebView -or -not $pw.WebView.CoreWebView2) { return }
    $s = $Seconds.ToString([Globalization.CultureInfo]::InvariantCulture)
    $js = "(function(s){ if (window.nrkb && nrkb.fade) { if (s > 0) nrkb.fade(s); else nrkb.unfade(); return; } document.querySelectorAll('video').forEach(function(v){ if (s > 0) { if (v.__nf == null) v.__nf = v.volume; var st = Math.max(1, Math.round(s * 4)), n = 0; clearInterval(v.__nt); v.__nt = setInterval(function(){ n++; v.volume = Math.max(0, v.__nf * (1 - n / st)); if (n >= st) clearInterval(v.__nt); }, 250); } else { clearInterval(v.__nt); if (v.__nf != null) { v.volume = v.__nf; v.__nf = null; } } }); })($s)"
    try { [void]$pw.WebView.CoreWebView2.ExecuteScriptAsync($js) } catch { }
}

function Start-SleepFade([double] $Seconds) {
    $z = $script:Sleep
    if ($z.Fading) { return }
    $z.Fading = $true
    Write-Log INFO ("Sleep timer: fading out over {0:N0} s" -f $Seconds)
    $s = $Seconds.ToString([Globalization.CultureInfo]::InvariantCulture)
    Invoke-AudioScript "nrkb.fade($s)"
    Invoke-PlayerFade $Seconds
}

function Stop-SleepFade {
    $z = $script:Sleep
    if (-not $z.Fading) { return }
    $z.Fading = $false
    Invoke-AudioScript 'nrkb.unfade()'
    Invoke-PlayerFade 0
}

# ---- wake to radio ----------------------------------------------------------------------------
function Start-AlarmTimer {
    if ($script:AlarmTimer) { return }
    $script:AlarmTimer = New-Object System.Windows.Forms.Timer
    $script:AlarmTimer.Interval = 20000
    $script:AlarmTimer.Add_Tick({ try { Test-Alarm } catch { Write-LogException $_ 'Wake to radio' } })
    $script:AlarmTimer.Start()
}

function Get-NextAlarm {
    # the next time the alarm goes off, or $null (off / no days)
    $st = Get-AppSettings
    if (-not $st.AlarmOn -or [string]$st.AlarmTime -notmatch '^(\d{1,2}):(\d\d)$') { return $null }
    $h = [int]$Matches[1]; $mi = [int]$Matches[2]
    $days = @([string]$st.AlarmDays -split ',' | Where-Object { $_ -match '^[1-7]$' } | ForEach-Object { [int]$_ })
    if (-not $days.Count) { return $null }
    for ($i = 0; $i -le 7; $i++) {
        $d = (Get-Date).Date.AddDays($i).AddHours($h).AddMinutes($mi)
        $dow = [int]$d.DayOfWeek; if ($dow -eq 0) { $dow = 7 }
        if ($days -contains $dow -and $d -gt (Get-Date).AddMinutes(-2) -and $st.AlarmLast -ne $d.ToString('yyyy-MM-dd')) { return $d }
    }
    return $null
}

function Test-Alarm {
    $next = Get-NextAlarm
    if (-not $next -or (Get-Date) -lt $next -or ((Get-Date) - $next).TotalMinutes -gt 2) { return }
    $s = Get-AppSettings; $s.AlarmLast = $next.ToString('yyyy-MM-dd'); Save-AppSettings $s
    Write-Log INFO "Wake to radio: $($s.AlarmChannelTitle) ($($s.AlarmChannel))"
    Invoke-PlayCommand ("radio:{0}" -f $s.AlarmChannel) -Alarm
    Show-AppNotification 'Good morning' ("{0} is on (wake to radio)" -f $s.AlarmChannelTitle)
}

# ---- start a channel from outside (jump list, phone remote, alarm): "radio:p1", "tv:nrk1" ------
function Invoke-PlayCommand([string] $What, [switch] $Alarm) {
    if ($What -notmatch '^(radio|tv):([\w\-]+)$') { Write-Log WARN "Play: not understood: $What"; return }
    $medium = $Matches[1]; $id = $Matches[2]
    $chs = @()
    try { $chs = @(Get-Cached "$($medium):live" { Get-NrkLiveChannels -Medium $medium }) } catch { Write-LogException $_ "Play $What"; return }
    $ch = @($chs | Where-Object { [string]$_.Id -eq $id }) | Select-Object -First 1
    if (-not $ch) { Write-Log WARN "Play: no channel '$id' in $medium"; Set-Status "Channel $id not found"; return }
    Write-Log INFO "Play from outside: $($ch.Title)"
    if ($medium -eq 'radio') {
        Start-AudioPlayer $ch
        if ($Alarm) { Invoke-AudioScript 'nrkb.fadeIn && nrkb.fadeIn(45)' }   # (gently louder over 45 s)
        try { Add-RecentChannel $ch } catch { }
    } else {
        Show-MainWindow
        Start-Player -Target (New-VideoTarget $ch)
        try { Add-RecentChannel $ch } catch { }
    }
}

# ---- recording live TV and radio (recordings.json; FFmpeg copies the live stream as it is) -------
$script:RecFile = Join-Path $script:AppDataDir 'recordings.json'
$script:Recs = $null

function Get-Recordings {
    if ($null -ne $script:Recs) { return $script:Recs }
    $l = New-Object System.Collections.ArrayList   # (hashtables: see $script:ApiJobs)
    $j = Read-JsonFile $script:RecFile
    if ($j) {
        foreach ($r in @($j.Items | Where-Object { $_ })) {
            $h = @{}; foreach ($p in $r.PSObject.Properties) { $h[$p.Name] = $p.Value }
            if ($h.Status -eq 'Recording') { $h.Status = 'Stopped'; $h.Note = 'the app was closed while recording' }
            [void]$l.Add($h)
        }
    }
    $script:Recs = $l
    return $l
}

function Save-Recordings {
    $items = @(foreach ($r in (Get-Recordings)) { $o = [ordered]@{}; foreach ($k in 'Id', 'Title', 'Medium', 'ChannelId', 'ChannelTitle', 'Manifest', 'Start', 'End', 'Status', 'File', 'Note') { $o[$k] = $r[$k] }; $o })
    Write-JsonFile $script:RecFile ([ordered]@{ Items = @($items) })
}

function Get-RecordDir([string] $Medium) {
    $d = [string](Get-AppSettings).RecordDir
    if ($d) { return $d }
    return (Join-Path (Get-DownloadDir -Radio:($Medium -eq 'radio')) 'Recordings')
}

function Add-Recording($Channel, [datetime] $Start, [datetime] $End, [string] $Title = '') {
    # $Channel: a live TV or radio channel file; Start/End: local time
    $medium = if ($Channel.Type -eq 'radiolive') { 'radio' } else { 'tv' }
    $r = @{ Id = [guid]::NewGuid().ToString('N').Substring(0, 10); Title = $(if ($Title) { $Title } else { [string]$Channel.Title }); Medium = $medium
            ChannelId = [string]$Channel.Id; ChannelTitle = [string]$Channel.Title; Manifest = [string]$Channel.ManifestPath
            Start = $Start.ToString('o'); End = $End.ToString('o'); Status = 'Scheduled'; File = ''; Note = '' }
    [void](Get-Recordings).Add($r)
    Save-Recordings
    Write-Log INFO ("Recording planned: {0} on {1}, {2:dd.MM HH:mm}-{3:HH:mm}" -f $r.Title, $r.ChannelTitle, $Start, $End)
    Start-RecordTimer
    Update-RecordingsList
    Set-Status ("Recording planned: {0}, {1:HH:mm}-{2:HH:mm}" -f $r.Title, $Start, $End)
}

function Start-RecordTimer {
    if (-not $script:RecTimer) {
        $script:RecTimer = New-Object System.Windows.Forms.Timer
        $script:RecTimer.Interval = 5000
        $script:RecTimer.Add_Tick({ try { Update-Recordings } catch { Write-LogException $_ 'Recordings' } })
    }
    $script:RecTimer.Start()
}

function Update-Recordings {
    $now = Get-Date; $busy = $false; $changed = $false
    foreach ($r in @(Get-Recordings)) {
        $start = [datetime]$r.Start; $end = [datetime]$r.End
        switch ($r.Status) {
            'Scheduled' {
                $busy = $true
                if ($now -ge $end) { $r.Status = 'Missed'; $r.Note = 'the app was not running at the time'; $changed = $true }
                elseif ($now -ge $start -and -not $r.Resolving) { Start-RecordingNow $r; $changed = $true }
            }
            'Recording' {
                $busy = $true
                $p = $r.Proc
                if (-not $p -or $p.HasExited) {
                    $len = try { (Get-Item -LiteralPath $r.File).Length } catch { 0 }
                    $r.Status = if ($len -gt 100KB -and ($now -ge $end.AddSeconds(-30) -or $r.StopAsked)) { 'Done' } elseif ($len -gt 100KB) { 'Stopped' } else { 'Failed' }
                    if ($r.Status -eq 'Failed' -and $r.Err -and $r.Err.IsCompleted) { $r.Note = (([string]$r.Err.Result) -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' ' }
                    elseif ($r.Status -ne 'Failed') { $r.Note = '{0:N0} MB' -f ($len / 1MB) }
                    Write-Log INFO "Recording $($r.Status.ToLower()): $($r.Title) -> $($r.File) $($r.Note)"
                    if ($r.Status -eq 'Done') { Show-AppNotification 'Recording done' $r.Title }
                    $r.Proc = $null; $changed = $true
                } elseif ($now -ge $end -and -not $r.StopAsked) { Stop-RecordingNow $r }
                elseif ($r.StopAsked -and $r.StopAt -and ($now - $r.StopAt).TotalSeconds -gt 10) { try { $p.Kill() } catch { } }
            }
        }
    }
    if ($changed) { Save-Recordings; Update-RecordingsList }
    if (-not $busy -and $script:RecTimer) { $script:RecTimer.Stop() }
}

function Start-RecordingNow($r) {
    # the stream address is looked up in the background, then FFmpeg starts
    $ff = Find-FFmpeg
    if (-not $ff.Found) { $r.Status = 'Failed'; $r.Note = 'FFmpeg is not installed (Options > Updates > Components)'; return }
    $r.Resolving = $true
    [void](Start-ApiJob "Recording $($r.Title)" {
        param($rec)
        if ($rec.Medium -eq 'radio') { $s = Get-NrkAudioStream -ManifestPath $rec.Manifest; return @{ Url = $s.Url; Ok = $s.Playable; Why = $s.Reason } }
        $s = Get-NrkVideoStream -Id $rec.ChannelId -Kind channel
        return @{ Url = $s.Url; Ok = $s.Playable; Why = $s.Reason }
    } {
        param($res, $rec)
        $rec.Resolving = $false
        if ($rec.Status -ne 'Scheduled') { return }
        if (-not $res.Ok -or -not $res.Url) { $rec.Status = 'Failed'; $rec.Note = $(if ($res.Why) { [string]$res.Why } else { 'no stream' }); Save-Recordings; Update-RecordingsList; return }
        $end = [datetime]$rec.End
        $secs = [Math]::Max(30, [int]($end - (Get-Date)).TotalSeconds)
        $dir = Get-RecordDir $rec.Medium
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $ext = if ($rec.Medium -eq 'radio') { 'm4a' } else { 'mp4' }
        $name = Get-SafeFileName ('{0} {1:yyyy-MM-dd HH.mm} {2}' -f $rec.ChannelTitle, (Get-Date), $(if ($rec.Title -ne $rec.ChannelTitle) { $rec.Title } else { '' })).Trim()
        $out = Join-Path $dir "$name.$ext"
        # fragmented MP4: what is recorded stays playable even if the recording is cut off
        $argv = @('-hide_banner', '-loglevel', 'error', '-y', '-user_agent', $script:UserAgent, '-i', $res.Url, '-t', "$secs")
        if ($rec.Medium -eq 'radio') { $argv += @('-vn', '-c:a', 'copy') } else { $argv += @('-c', 'copy') }
        $argv += @('-movflags', '+frag_keyframe+empty_moov+default_base_moof', '-f', 'mp4', $out)
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = (Find-FFmpeg).Path; $psi.Arguments = ConvertTo-ArgString $argv
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
            $p = [System.Diagnostics.Process]::Start($psi); Add-ProcessToJob $p
            $rec.Proc = $p; $rec.Err = $p.StandardError.ReadToEndAsync(); $rec.File = $out; $rec.Status = 'Recording'; $rec.Note = ''
            Write-Log INFO ("Recording started: {0} ({1} s) -> {2}" -f $rec.Title, $secs, $out)
        } catch { $rec.Status = 'Failed'; $rec.Note = $_.Exception.Message }
        Save-Recordings; Update-RecordingsList
    } { param($err, $rec) $rec.Resolving = $false; $rec.Status = 'Failed'; $rec.Note = $err.Exception.Message; Save-Recordings; Update-RecordingsList } $r)
}

function Stop-RecordingNow($r) {
    # FFmpeg finishes the file when it gets "q"
    if ($r.Status -eq 'Scheduled') { $r.Status = 'Canceled'; Save-Recordings; Update-RecordingsList; return }
    if ($r.Status -ne 'Recording' -or -not $r.Proc) { return }
    $r.StopAsked = $true; $r.StopAt = Get-Date
    try { $r.Proc.StandardInput.Write('q'); $r.Proc.StandardInput.Flush() } catch { try { $r.Proc.Kill() } catch { } }
    Write-Log INFO "Recording: stopping $($r.Title)"
}

function Stop-AllRecordings {
    # exit: what is being recorded is finished properly (at most 3 s)
    foreach ($r in @(Get-Recordings | Where-Object { $_.Status -eq 'Recording' -and $_.Proc })) {
        Stop-RecordingNow $r
        try { [void]$r.Proc.WaitForExit(3000) } catch { }
        $r.Status = 'Stopped'; $r.Note = 'stopped when the app closed'; $r.Proc = $null
    }
    if ($null -ne $script:Recs) { Save-Recordings }
}

function Show-RecordDialog($Channel) {
    # live channel > Record...: now for N minutes, or from a time of day
    $d = New-Object System.Windows.Forms.Form
    Set-AppIcon $d
    $d.Text = "Record - $($Channel.Title)"; $d.ClientSize = New-Object System.Drawing.Size(440, 230); $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.Font = $script:FontUi; $d.BackColor = $T.Bg; $d.ForeColor = $T.Text
    $rNow = New-Object System.Windows.Forms.RadioButton; $rNow.Text = 'Start now'; $rNow.Checked = $true; $rNow.AutoSize = $true; $rNow.Location = New-Object System.Drawing.Point(20, 18)
    $rAt = New-Object System.Windows.Forms.RadioButton; $rAt.Text = 'Start at (hh:mm)'; $rAt.AutoSize = $true; $rAt.Location = New-Object System.Drawing.Point(20, 52)
    $tAt = New-Object System.Windows.Forms.TextBox; $tAt.Width = 70; $tAt.Location = New-Object System.Drawing.Point(200, 50); $tAt.Text = (Get-Date).AddMinutes(30).ToString('HH:mm'); $tAt.BorderStyle = 'FixedSingle'
    $lLen = New-Object System.Windows.Forms.Label; $lLen.Text = 'For (minutes)'; $lLen.AutoSize = $true; $lLen.Location = New-Object System.Drawing.Point(20, 92)
    $nLen = New-Object System.Windows.Forms.NumericUpDown; $nLen.Minimum = 1; $nLen.Maximum = 720; $nLen.Value = 60; $nLen.Width = 70; $nLen.Location = New-Object System.Drawing.Point(200, 88)
    $note = New-Object System.Windows.Forms.Label; $note.AutoSize = $false; $note.Size = New-Object System.Drawing.Size(400, 54); $note.Location = New-Object System.Drawing.Point(20, 124); $note.ForeColor = $T.Muted
    $note.Text = "Saved in $(Get-RecordDir $(if ($Channel.Type -eq 'radiolive') { 'radio' } else { 'tv' })). The app must be running (it may be in the tray). TV programmes: right-click one in the schedule > Record this programme."
    $ok = New-FlatButton 'Record' 100 -Primary; $ok.Location = New-Object System.Drawing.Point(110, 186); $ok.DialogResult = 'OK'
    $lst = New-FlatButton 'Recordings...' 130; $lst.Location = New-Object System.Drawing.Point(216, 186); $lst.Add_Click({ Show-RecordingsWindow })
    $no = New-FlatButton 'Cancel' 80; $no.Location = New-Object System.Drawing.Point(352, 186); $no.DialogResult = 'Cancel'
    Set-IconText $ok 'record' 'Record' ([string][char]0x25CF) -Primary   # (2.9.2)
    Set-IconText $lst 'window' 'Recordings...' ''
    $d.Controls.AddRange(@($rNow, $rAt, $tAt, $lLen, $nLen, $note, $ok, $lst, $no))
    $d.AcceptButton = $ok; $d.CancelButton = $no
    Set-DarkTheme $d; Enable-DarkTitleBar $d
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $start = Get-Date
    if ($rAt.Checked) {
        if ($tAt.Text.Trim() -notmatch '^(\d{1,2}):(\d\d)$') { [void][System.Windows.Forms.MessageBox]::Show($form, 'Write the time as hh:mm, for example 20:15.', 'Record', 'OK', 'Information'); return }
        $start = (Get-Date).Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
        if ($start -lt (Get-Date).AddMinutes(-1)) { $start = $start.AddDays(1) }
    }
    Add-Recording $Channel $start ($start.AddMinutes([int]$nLen.Value))
}

function Show-RecordingsWindow {
    if ($script:RecUi -and -not $script:RecUi.Form.IsDisposed) { $script:RecUi.Form.Activate(); Update-RecordingsList; return }
    $w = New-Object System.Windows.Forms.Form
    Set-AppIcon $w
    $w.Text = 'Recordings - NRK Browser'; $w.ClientSize = New-Object System.Drawing.Size(860, 380); $w.StartPosition = 'CenterParent'
    $w.Font = $script:FontUi; $w.BackColor = $T.Bg; $w.ForeColor = $T.Text
    $lv = New-Object System.Windows.Forms.ListView; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.BorderStyle = 'None'; $lv.Dock = 'Fill'; $lv.HideSelection = $false
    foreach ($c in @(@('Title', 250), @('Channel', 130), @('When', 170), @('Status', 90), @('', 200))) { [void]$lv.Columns.Add($c[0], $c[1]) }
    $side = New-Object System.Windows.Forms.FlowLayoutPanel; $side.Dock = 'Bottom'; $side.Height = 52; $side.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 0); $side.BackColor = $T.Panel
    $bNew = New-FlatButton 'Record...' 120 -Primary
    $bStop = New-FlatButton 'Stop / cancel' 140; $bRemove = New-FlatButton 'Remove from list' 160; $bPlay = New-FlatButton 'Show file' 120; $bDir = New-FlatButton 'Open folder' 130
    $side.Controls.AddRange(@($bNew, $bStop, $bRemove, $bPlay, $bDir))
    # 2.9.2: icons in the chosen look
    Set-IconText $bNew 'record' 'Record...' ([string][char]0x25CF) -Primary
    Set-IconText $bStop 'stop' 'Stop / cancel' ([string][char]0x25A0)
    Set-IconText $bRemove 'trash' 'Remove from list' ([string][char]0x2715)
    Set-IconText $bPlay 'web' 'Show file' ([string][char]0x2197)
    Set-IconText $bDir 'folder' 'Open folder' ([string][char]0x2197)
    $bNew.Add_Click({
        # record a live channel: the one selected in the main window, or pick from the channels you played
        $ch = if ($script:SelectedFile -and $script:SelectedFile.Type -in 'live', 'radiolive') { $script:SelectedFile } else { $null }
        if (-not $ch) { [void][System.Windows.Forms.MessageBox]::Show($script:RecUi.Form, 'Select a live TV or radio channel in the main window first (LIVE TV / LIVE Radio), then press Record... again - or right-click the channel > Record...', 'Record', 'OK', 'Information'); return }
        Show-RecordDialog $ch
    })
    $w.Controls.Add($lv); $w.Controls.Add($side)
    $script:RecUi = @{ Form = $w; List = $lv }
    $sel = { @($script:RecUi.List.SelectedItems | ForEach-Object { $_.Tag }) }
    $bStop.Add_Click({ foreach ($r in (& $sel)) { Stop-RecordingNow $r }; Update-RecordingsList })
    $bRemove.Add_Click({ foreach ($r in (& $sel)) { if ($r.Status -ne 'Recording') { [void](Get-Recordings).Remove($r) } }; Save-Recordings; Update-RecordingsList })
    $bPlay.Add_Click({ $r = @(& $sel) | Select-Object -First 1; if ($r -and $r.File -and (Test-Path -LiteralPath $r.File)) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($r.File)`"" } })
    $bDir.Add_Click({ $d = Get-RecordDir 'tv'; New-Item -ItemType Directory -Path $d -Force | Out-Null; Start-Process $d })
    $w.Add_FormClosed({ $script:RecUi = $null })
    Set-DarkTheme $w; Enable-DarkTitleBar $w
    $lv.BackColor = $T.Surface; $lv.ForeColor = $T.Text
    Update-RecordingsList
    $w.Show($form)
}

function Update-RecordingsList {
    $u = $script:RecUi
    if (-not $u -or $u.Form.IsDisposed) { return }
    $u.List.BeginUpdate(); $u.List.Items.Clear()
    foreach ($r in @(Get-Recordings) | Sort-Object { [datetime]$_.Start } -Descending) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$r.Title)
        [void]$it.SubItems.Add([string]$r.ChannelTitle)
        [void]$it.SubItems.Add(('{0:ddd dd.MM HH:mm}-{1:HH:mm}' -f [datetime]$r.Start, [datetime]$r.End))
        [void]$it.SubItems.Add([string]$r.Status)
        [void]$it.SubItems.Add($(if ($r.Note) { [string]$r.Note } else { [string]$r.File }))
        $it.Tag = $r
        if ($r.Status -eq 'Recording') { $it.ForeColor = $T.Live }
        [void]$u.List.Items.Add($it)
    }
    $u.List.EndUpdate()
}

# ---- file-name templates (Options > Download rules) -------------------------------------------
function Format-NameTemplate([string] $Template, [hashtable] $Values) {
    # {series} {season} {episode} {title} {date} {id}; returns $null when a used value is missing
    $missing = $false
    $out = [regex]::Replace($Template, '\{(\w+)\}', {
        param($m)
        $k = $m.Groups[1].Value.ToLower()
        if ($Values.ContainsKey($k) -and "$($Values[$k])" -ne '') { return [string]$Values[$k] }
        $script:NameTplMissing = $true; return ''
    })
    if ($script:NameTplMissing) { $script:NameTplMissing = $false; return $null }
    $out = ($out -replace '\s{2,}', ' ' -replace '^[\s\-_.]+|[\s\-_.]+$', '').Trim()
    if (-not $out) { return $null }
    return (Get-SafeFileName $out)
}

function Get-RadioFileName($File) {
    # radio episode file name (without extension): the template, or "2026-10-20 - Title"
    $date = ''; if ($File.Date -match '^(\d\d)\.(\d\d)\.(\d{4})$') { $date = '{0}-{1}-{2}' -f $Matches[3], $Matches[2], $Matches[1] }
    $tpl = [string](Get-AppSettings).DlNameRadio
    if ($tpl) {
        $n = Format-NameTemplate $tpl @{ series = [string]$File.SeriesTitle; title = [string]$File.Title; date = $date; id = [string]$File.Id }
        if ($n) { return $n }
    }
    return (Get-SafeFileName ($(if ($date) { "$date - " } else { '' }) + $File.Title))
}

# ---- Windows: global hotkeys, shortcuts, taskbar buttons, jump list ------------------------------
$script:AppActions = [ordered]@{
    playpause = 'Play / pause'; next = 'Next'; prev = 'Previous'; back = 'Back 15 seconds'; fwd = 'Forward 15 seconds'
    volup = 'Volume up'; voldown = 'Volume down'; mute = 'Mute'; stop = 'Stop'; show = 'Show NRK Browser'
}
$script:HotkeyDefaults = [ordered]@{ playpause = 'Ctrl+Alt+P'; next = 'Ctrl+Alt+Right'; prev = 'Ctrl+Alt+Left'; back = ''; fwd = ''; volup = 'Ctrl+Alt+Up'; voldown = 'Ctrl+Alt+Down'; mute = 'Ctrl+Alt+M'; stop = ''; show = 'Ctrl+Alt+N' }
$script:KeyActions = [ordered]@{ options = 'Options'; logs = 'Logs'; downloads = 'Downloads'; indexer = 'Indexer'; filter = 'Search / filter box'; grid = 'Thumbnails / list'; later = 'Watch later (selected)'; recordings = 'Recordings' }
$script:KeyDefaults = [ordered]@{ options = 'Ctrl+Oemcomma'; logs = 'Ctrl+L'; downloads = 'Ctrl+D'; indexer = 'Ctrl+I'; filter = 'Ctrl+F'; grid = 'Ctrl+G'; later = 'Ctrl+W'; recordings = 'Ctrl+R' }

function Get-KeyMapSetting([string] $Name, $Defaults) {
    # the saved map (JSON in settings) over the defaults
    $m = [ordered]@{}; foreach ($k in $Defaults.Keys) { $m[$k] = $Defaults[$k] }
    $raw = [string](Get-AppSettings).$Name
    if ($raw) { try { $j = $raw | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { if ($m.Contains($p.Name)) { $m[$p.Name] = [string]$p.Value } } } catch { } }
    return $m
}

function ConvertTo-KeyText([System.Windows.Forms.Keys] $KeyData) {
    # Keys (with Ctrl/Alt/Shift) -> "Ctrl+Alt+P"
    $k = $KeyData -band [System.Windows.Forms.Keys]::KeyCode
    if ($k -in [System.Windows.Forms.Keys]::ControlKey, [System.Windows.Forms.Keys]::Menu, [System.Windows.Forms.Keys]::ShiftKey, [System.Windows.Forms.Keys]::LWin, [System.Windows.Forms.Keys]::RWin) { return '' }
    $p = @()
    if ($KeyData -band [System.Windows.Forms.Keys]::Control) { $p += 'Ctrl' }
    if ($KeyData -band [System.Windows.Forms.Keys]::Alt) { $p += 'Alt' }
    if ($KeyData -band [System.Windows.Forms.Keys]::Shift) { $p += 'Shift' }
    $p += [string]$k
    return ($p -join '+')
}

function ConvertFrom-KeyText([string] $Text) {
    # "Ctrl+Alt+P" -> @{ Mods = 3; Vk = 80; Keys = <Keys> } or $null
    if (-not $Text) { return $null }
    $mods = 0; $keys = [System.Windows.Forms.Keys]::None; $vk = 0
    foreach ($part in ($Text -split '\+')) {
        switch ($part.Trim()) {
            'Ctrl' { $mods = $mods -bor 2; $keys = $keys -bor [System.Windows.Forms.Keys]::Control }
            'Alt' { $mods = $mods -bor 1; $keys = $keys -bor [System.Windows.Forms.Keys]::Alt }
            'Shift' { $mods = $mods -bor 4; $keys = $keys -bor [System.Windows.Forms.Keys]::Shift }
            'Win' { $mods = $mods -bor 8 }
            default { try { $kc = [System.Windows.Forms.Keys]$part.Trim(); $vk = [int]$kc; $keys = $keys -bor $kc } catch { return $null } }
        }
    }
    if (-not $vk) { return $null }
    return @{ Mods = $mods; Vk = $vk; Keys = $keys }
}

function Invoke-AppAction([string] $Action) {
    # one action for hotkeys, taskbar buttons and the phone remote: on what plays (radio, video, cast)
    $u = $script:AudioUi; $pw = $script:PlayerWin
    $audio = [bool]($u.Current -and $audioBar.Visible)
    $video = [bool]($pw -and -not $pw.Form.IsDisposed -and $pw.Url -and $pw.Form.Visible)
    $vjs = { param($js) try { [void]$pw.WebView.CoreWebView2.ExecuteScriptAsync("(function(){ var v = document.querySelector('video'); if (!v) return; $js })()") } catch { } }
    switch ($Action) {
        'playpause' { Invoke-MediaCommand 'pause' }
        'mute' { Invoke-MediaCommand 'mute' }
        'next' { if ($audio) { Start-NextAudio 1 } elseif ($video) { Start-PlayerStep 1 } }
        'prev' { if ($audio) { Start-NextAudio -1 } elseif ($video) { Start-PlayerStep -1 } }
        'back' { if ($script:Cast.Session) { Invoke-CastCommand 'rel' -15 } elseif ($audio) { Invoke-AudioScript 'nrkb.skip(-15)' } elseif ($video) { & $vjs 'v.currentTime = Math.max(0, v.currentTime - 15);' } }
        'fwd' { if ($script:Cast.Session) { Invoke-CastCommand 'rel' 15 } elseif ($audio) { Invoke-AudioScript 'nrkb.skip(15)' } elseif ($video) { & $vjs 'v.currentTime = v.currentTime + 15;' } }
        'volup' { if ($audio) { Invoke-AudioScript 'nrkb.vol(0.1)' } elseif ($video) { & $vjs 'v.muted = false; v.volume = Math.min(1, v.volume + 0.1);' } }
        'voldown' { if ($audio) { Invoke-AudioScript 'nrkb.vol(-0.1)' } elseif ($video) { & $vjs 'v.volume = Math.max(0, v.volume - 0.1);' } }
        'stop' { if ($audio) { Stop-AudioPlayer } elseif ($video) { Stop-Player } }
        'show' { Show-MainWindow }
        default { if ($Action -match '^(radio|tv):') { Invoke-PlayCommand $Action } }
    }
}

function Initialize-WinHelpers {
    # compiles the C# helpers once (hotkeys, taskbar, phone remote); $false when not possible
    if ('NrkHotkeys' -as [type]) { return $true }
    if ($script:WinHelpersFailed) { return $false }
    try {
        $refs = if ($PSVersionTable.PSEdition -eq 'Desktop') { @('System', 'System.Drawing', 'System.Windows.Forms') }
                else { [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { -not $_.IsDynamic -and $_.Location -and $_.GetName().Name -match '^System\.(Windows\.Forms(\.Primitives)?|Drawing(\.Common|\.Primitives)?|ComponentModel\.Primitives)$' } | ForEach-Object Location }   # (the rest: PowerShell's own default references, as for the dark menus)
        Add-Type -ReferencedAssemblies $refs -ErrorAction Stop -TypeDefinition $script:WinHelpersCs
        return $true
    } catch { $script:WinHelpersFailed = $true; Write-Log WARN "Hotkeys / taskbar buttons / phone remote not available: $($_.Exception.Message)"; return $false }
}

function Register-AppHotkeys {
    # Options > Shortcuts > global hotkeys (work while the app is in the background)
    if (-not (Initialize-WinHelpers)) { return }
    if (-not $script:Hotkeys) { $script:Hotkeys = New-Object NrkHotkeys([Action[int]]{ param($id) try { $a = $script:HotkeyIds[$id]; if ($a) { Write-Log DEBUG "Hotkey: $a"; Invoke-AppAction $a } } catch { Write-LogException $_ 'Hotkey' } }) }
    $script:Hotkeys.Clear(); $script:HotkeyIds = @{}; $script:HotkeyFailed = @()
    if (-not (Get-AppSettings).Hotkeys) { return }
    $map = Get-KeyMapSetting 'HotkeyMap' $script:HotkeyDefaults
    $id = 100
    foreach ($a in $map.Keys) {
        $k = ConvertFrom-KeyText $map[$a]
        if (-not $k) { continue }
        $id++
        if ($script:Hotkeys.Add($id, [uint32]$k.Mods, [uint32]$k.Vk)) { $script:HotkeyIds[$id] = $a }
        else { $script:HotkeyFailed += "$($map[$a]) ($($script:AppActions[$a]))" }
    }
    Write-Log INFO ("Global hotkeys: {0} on{1}" -f $script:HotkeyIds.Count, $(if ($script:HotkeyFailed.Count) { "; taken by another app: $($script:HotkeyFailed -join ', ')" } else { '' }))
}

function Invoke-AppShortcut($E) {
    # the main window's own shortcuts (Options > Shortcuts); $true when one matched
    $txt = ConvertTo-KeyText $E.KeyData
    if (-not $txt) { return $false }
    if (-not $script:KeyMapCache -or $script:KeyMapCacheAt -ne (Get-AppSettings).KeyMap) { $script:KeyMapCache = Get-KeyMapSetting 'KeyMap' $script:KeyDefaults; $script:KeyMapCacheAt = (Get-AppSettings).KeyMap }
    foreach ($a in $script:KeyMapCache.Keys) {
        if ($script:KeyMapCache[$a] -ne $txt) { continue }
        switch ($a) {
            'options' { Show-OptionsWindow }
            'logs' { Show-LogsWindow }
            'downloads' { Show-DownloadsWindow }
            'indexer' { Open-IndexerWindow }
            'filter' { $search.Focus() }
            'grid' { Set-FilesView $(if (Test-GridView) { 'list' } else { 'grid' }) }
            'later' { $sel = @(Get-SelectedFiles | Where-Object { Test-PosFile $_ }); if ($sel.Count) { Set-WatchLater $sel (-not (@($sel | Where-Object { -not (Test-WatchLater $_) }).Count -eq 0)) } }
            'recordings' { Show-RecordingsWindow }
        }
        return $true
    }
    return $false
}

function New-TaskbarIcon([string] $Kind) {
    # small white symbols for the taskbar preview buttons
    $b = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'
    $br = [System.Drawing.Brushes]::White
    $P = { param([float[]] $xy) $pts = for ($i = 0; $i -lt $xy.Count; $i += 2) { New-Object System.Drawing.PointF($xy[$i], $xy[$i + 1]) }; $g.FillPolygon($br, [System.Drawing.PointF[]]$pts) }
    switch ($Kind) {
        'prev' { $g.FillRectangle($br, 2, 3, 2, 10); & $P @(13, 3, 13, 13, 5, 8) }
        'next' { $g.FillRectangle($br, 12, 3, 2, 10); & $P @(3, 3, 3, 13, 11, 8) }
        'play' { & $P @(4, 2, 4, 14, 14, 8) }
        'pause' { $g.FillRectangle($br, 3, 2, 4, 12); $g.FillRectangle($br, 9, 2, 4, 12) }
    }
    $g.Dispose()
    $ic = [System.Drawing.Icon]::FromHandle($b.GetHicon())
    return $ic
}

function Initialize-Taskbar {
    # Previous / Play-Pause / Next under the taskbar preview of the main window, and the jump list
    if (-not (Initialize-WinHelpers)) { return }
    try {
        $script:TbIcons = @{ prev = (New-TaskbarIcon 'prev'); next = (New-TaskbarIcon 'next'); play = (New-TaskbarIcon 'play'); pause = (New-TaskbarIcon 'pause') }
        $script:Taskbar = New-Object NrkTaskbar($form.Handle, [Action[int]]{ param($id) try { switch ($id) { 1 { Invoke-AppAction 'prev' } 2 { Invoke-AppAction 'playpause' } 3 { Invoke-AppAction 'next' } } } catch { Write-LogException $_ 'Taskbar button' } })
        $script:Taskbar.SetButtons($script:TbIcons.prev, $script:TbIcons.play, $script:TbIcons.next, 'Previous', 'Play / pause', 'Next')
        $script:TbTimer = New-Object System.Windows.Forms.Timer; $script:TbTimer.Interval = 1000
        $script:TbTimer.Add_Tick({ Update-TaskbarButtons })
        $script:TbTimer.Start()
    } catch { Write-Log WARN "Taskbar buttons: $($_.Exception.Message)" }
    Update-JumpList
}

function Update-TaskbarButtons {
    if (-not $script:Taskbar) { return }
    $m = Get-MediaState
    $any = [bool]($m.Audio -or $m.Video)
    $state = "$any|$($m.Playing)"
    if ($state -eq $script:TbState) { return }
    $script:TbState = $state
    try {
        $script:Taskbar.Update(1, $null, 'Previous', $any)
        $script:Taskbar.Update(2, $(if ($m.Playing) { $script:TbIcons.pause } else { $script:TbIcons.play }), $(if ($m.Playing) { 'Pause' } else { 'Play' }), $any)
        $script:Taskbar.Update(3, $null, 'Next', $any)
    } catch { }
}

$script:RecentChFile = Join-Path $script:AppDataDir 'recentchannels.json'
$script:JumpScript = $PSCommandPath   # (the jump list starts this script with -Play <channel>)
function Add-RecentChannel($Channel) {
    # live channels you played, newest first (for the jump list and the phone remote)
    $medium = if ($Channel.Type -eq 'radiolive') { 'radio' } else { 'tv' }
    $key = "$($medium):$($Channel.Id)"
    $list = New-Object System.Collections.ArrayList
    $j = Read-JsonFile $script:RecentChFile
    if ($j) { foreach ($x in @($j.Items)) { if ($x -and $x.Key -ne $key) { [void]$list.Add($x) } } }
    $list.Insert(0, [pscustomobject]@{ Key = $key; Title = [string]$Channel.Title })
    while ($list.Count -gt 8) { $list.RemoveAt($list.Count - 1) }
    Write-JsonFile $script:RecentChFile ([ordered]@{ Items = @($list) })
    Update-JumpList
}

function Get-RecentChannels {
    $j = Read-JsonFile $script:RecentChFile
    $l = @(if ($j) { @($j.Items | Where-Object { $_ -and $_.Key }) })
    if (-not $l.Count) { $l = @([pscustomobject]@{ Key = 'radio:p1'; Title = 'NRK P1' }, [pscustomobject]@{ Key = 'radio:p3'; Title = 'NRK P3' }, [pscustomobject]@{ Key = 'radio:mp3'; Title = 'NRK mP3' }, [pscustomobject]@{ Key = 'tv:nrk1'; Title = 'NRK1' }) }
    return $l
}

function Update-JumpList {
    # right-click the taskbar button: the channels you played lately start straight away
    if (-not ('NrkTaskbar' -as [type]) -or -not $script:JumpScript) { return }
    try {
        $ch = @(Get-RecentChannels)
        $exe = (Get-Process -Id $PID).Path
        $argsFor = { param($k) '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Play {1}' -f $script:JumpScript, $k }
        $icon = ''; $iconIx = 0
        if ($script:AppIconLocation -match '^(.*),(-?\d+)$') { $icon = $Matches[1]; $iconIx = [int]$Matches[2] }
        $err = [NrkTaskbar]::SetJumpList('NRK.Browser', 'Channels', $exe, [string[]]@($ch | ForEach-Object { [string]$_.Title }), [string[]]@($ch | ForEach-Object { & $argsFor $_.Key }), $icon, $iconIx)
        if ($err) { Write-Log DEBUG "Jump list: $err" }
    } catch { Write-Log DEBUG "Jump list: $($_.Exception.Message)" }
}

# ---- the phone remote ---------------------------------------------------------------------------
$script:RemotePage = @'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NRK Browser remote</title>
<style>
:root{--bg:#10171c;--s:#1c252b;--t:#e2e8ec;--m:#86939c;--a:#48c9d2}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--t);font:16px system-ui,sans-serif;padding:16px;max-width:520px;margin:auto}
h1{font-size:15px;color:var(--m);font-weight:500;margin:4px 0 14px}
#t1{font-size:20px;font-weight:600;min-height:26px}#t2{color:var(--m);min-height:22px;margin:4px 0 18px}
.row{display:flex;gap:10px;margin-bottom:10px}.row button{flex:1}
button{background:var(--s);color:var(--t);border:0;border-radius:12px;padding:16px 0;font:600 18px system-ui;cursor:pointer}
button:active{filter:brightness(1.3)}#pp{background:var(--a);color:#0a1e22;font-size:22px}
h2{font-size:14px;color:var(--m);margin:22px 0 8px;font-weight:500}
.ch{display:grid;grid-template-columns:1fr 1fr;gap:8px}.ch button{font-size:15px;padding:12px 6px}
</style></head><body>
<h1>NRK Browser</h1>
<div id="t1">...</div><div id="t2"></div>
<div class="row"><button data-c="prev">&#x23EE;</button><button data-c="back">-15</button><button id="pp" data-c="playpause">&#x23EF;</button><button data-c="fwd">+15</button><button data-c="next">&#x23ED;</button></div>
<div class="row"><button data-c="voldown">Vol &minus;</button><button data-c="mute">Mute</button><button data-c="volup">Vol +</button></div>
<div class="row"><button data-c="stop">Stop</button></div>
<h2>Channels</h2><div class="ch" id="ch"></div>
<script>
const k = new URLSearchParams(location.search).get('k') || '';
const send = c => fetch('cmd?k=' + encodeURIComponent(k) + '&c=' + encodeURIComponent(c)).then(() => setTimeout(poll, 400));
document.querySelectorAll('button[data-c]').forEach(b => b.onclick = () => send(b.dataset.c));
let chs = '';
function poll() {
  fetch('state?k=' + encodeURIComponent(k)).then(r => r.json()).then(s => {
    document.getElementById('t1').textContent = s.title || 'Nothing playing';
    document.getElementById('t2').textContent = s.sub || '';
    document.getElementById('pp').innerHTML = s.playing ? '&#x2016;' : '&#x25B6;';
    const j = JSON.stringify(s.channels || []);
    if (j !== chs) { chs = j; const el = document.getElementById('ch'); el.innerHTML = '';
      (s.channels || []).forEach(c => { const b = document.createElement('button'); b.textContent = c.title; b.onclick = () => send(c.key); el.appendChild(b); }); }
  }).catch(() => { document.getElementById('t2').textContent = 'Not connected (is NRK Browser running?)'; });
}
poll(); setInterval(poll, 3000);
</script></body></html>
'@

function Get-RemoteUrls {
    # the addresses the phone can use (this PC's addresses on the home network)
    if (-not $script:Remote) { return @() }
    $ips = @()
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback') { continue }
            foreach ($ua in $ni.GetIPProperties().UnicastAddresses) { if ($ua.Address.AddressFamily -eq 'InterNetwork') { $ips += $ua.Address.ToString() } }
        }
    } catch { }
    return @($ips | Select-Object -Unique | ForEach-Object { 'http://{0}:{1}/?k={2}' -f $_, $script:Remote.Port, $script:Remote.Key })
}

function Start-PhoneRemote {
    if ($script:Remote) { return $true }
    if (-not (Initialize-WinHelpers)) { return $false }
    $st = Get-AppSettings
    if (-not $st.RemoteKey) { $st.RemoteKey = -join ((1..16) | ForEach-Object { 'abcdefghijkmnpqrstuvwxyz23456789'[(Get-Random -Maximum 32)] }); Save-AppSettings $st }
    $r = New-Object NrkRemote
    $r.Key = [string]$st.RemoteKey; $r.Page = $script:RemotePage
    $port = $r.Start(51792)
    if (-not $port) { Write-Log WARN 'Phone remote: no free port (51792-51801)'; return $false }
    $script:Remote = $r
    $script:RemoteTimer = New-Object System.Windows.Forms.Timer; $script:RemoteTimer.Interval = 300
    $script:RemoteTimer.Add_Tick({ Update-PhoneRemote })
    $script:RemoteTimer.Start()
    Write-Log INFO "Phone remote on port $port (home network only)"
    return $true
}

function Stop-PhoneRemote {
    if (-not $script:Remote) { return }
    try { $script:RemoteTimer.Stop(); $script:RemoteTimer.Dispose() } catch { }
    try { $script:Remote.Stop() } catch { }
    $script:Remote = $null
    Write-Log INFO 'Phone remote off'
}

function Update-PhoneRemote {
    $r = $script:Remote
    if (-not $r) { return }
    $c = $null
    while ($r.Commands.TryDequeue([ref]$c)) { try { Invoke-AppAction $c } catch { Write-LogException $_ "Remote $c" } }
    $l = $null; while ($r.Log.TryDequeue([ref]$l)) { Write-Log INFO "Phone remote: $l" }
    $script:RemoteTick = 1 + [int]$script:RemoteTick
    if ($script:RemoteTick % 3) { return }   # (the state about once a second)
    $u = $script:AudioUi; $pw = $script:PlayerWin; $m = Get-MediaState
    $title = ''; $sub = ''
    if ($m.Audio) { $title = [string]$u.Current.Title; $sub = if ($u.Current.Type -eq 'radiolive' -and $script:NowLast) { [string][char]0x266A + ' ' + $script:NowLast } else { [string]$u.Current.SeriesTitle } }
    elseif ($m.Video -and $pw.Target) { $title = [string]$pw.Target.Title }
    $chs = @(Get-RecentChannels | ForEach-Object { [ordered]@{ key = [string]$_.Key; title = [string]$_.Title } })
    $r.State = [ordered]@{ title = $title; sub = $sub; playing = [bool]$m.Playing; channels = $chs } | ConvertTo-Json -Compress -Depth 4
}

#endregion


#---- Options window ---------------------------------------------------------------

function Get-OptionTexts($Control) {
    # every label, check box and button under $Control (not what is typed in boxes)
    foreach ($c in $Control.Controls) {
        if ($c -is [System.Windows.Forms.Label] -or $c -is [System.Windows.Forms.CheckBox] -or $c -is [System.Windows.Forms.RadioButton] -or $c -is [System.Windows.Forms.Button]) { if ($c.Text) { $c } }
        if ($c.Controls.Count) { Get-OptionTexts $c }
    }
}

function Update-OptionsFind([switch] $Next) {
    $u = $script:OptUi
    if (-not $u -or -not $u.Find) { return }
    $term = $u.Find.Text.Trim()
    # undo the last highlight
    foreach ($c in @($u.FindColors.Keys)) { try { $c.ForeColor = $u.FindColors[$c] } catch { } }
    $u.FindColors = @{}
    $hitPages = New-Object System.Collections.Generic.List[string]
    foreach ($name in $u.Pages.Keys) {
        $b = $u.NavButtons[$name]
        $hits = if ($term.Length -ge 2) { @(Get-OptionTexts $u.Pages[$name] | Where-Object { $_.Text -like "*$term*" }) } else { @() }
        foreach ($c in $hits) { $u.FindColors[$c] = $c.ForeColor; $c.ForeColor = $T.Accent }
        $b.Text = '   ' + $name + $(if ($hits.Count) { "  ($($hits.Count))" } else { '' })
        if ($term.Length -ge 2 -and -not $hits.Count) { $b.ForeColor = $T.Muted } elseif ($u.Current -ne $name) { $b.ForeColor = $T.Text }
        if ($hits.Count) { $hitPages.Add($name) }
        $u.Pages[$name].Tag = if ($hits.Count) { $hits[0] } else { $null }
    }
    if (-not $hitPages.Count) { return }
    $go = $hitPages[0]
    if ($Next -and $hitPages.Contains($u.Current)) { $go = $hitPages[($hitPages.IndexOf($u.Current) + 1) % $hitPages.Count] }
    elseif ($hitPages.Contains($u.Current) -and -not $Next) { $go = $u.Current }
    & $script:OptShowPage $go
    $first = $u.Pages[$go].Tag
    if ($first) { try { $u.Pages[$go].ScrollControlIntoView($first) } catch { } }
    foreach ($name in $u.Pages.Keys) { if ($term.Length -ge 2 -and -not $hitPages.Contains($name)) { $u.NavButtons[$name].ForeColor = $T.Muted } }
}

function Show-OptionsWindow {
    Write-Log INFO 'UI: opened Options window'
    $w = New-Object System.Windows.Forms.Form
    Set-AppIcon $w   # window, title bar and taskbar icon
    $w.Text = 'Options - NRK Browser'
    $w.ClientSize = New-Object System.Drawing.Size(860, 620)   # (2.9.0: taller for the new pages)
    $w.StartPosition = 'CenterParent'
    $w.FormBorderStyle = 'FixedDialog'; $w.MaximizeBox = $false; $w.MinimizeBox = $false
    $w.Font = $script:FontUi; $w.BackColor = $T.Bg; $w.ForeColor = $T.Text
    $st = Get-AppSettings
    $script:OptUi = @{ Form = $w }
    $ui = $script:OptUi

    # Pages: a menu on the left, one page of settings on the right
    $nav = New-Object System.Windows.Forms.Panel
    $nav.Dock = 'Left'; $nav.Width = 200; $nav.BackColor = $T.Panel
    $nav.Padding = New-Object System.Windows.Forms.Padding(0, 14, 0, 0)
    $pageHost = New-Object System.Windows.Forms.Panel
    $pageHost.Dock = 'Fill'; $pageHost.BackColor = $T.Bg
    $w.Controls.Add($pageHost); $w.Controls.Add($nav)
    $ui.Pages = [ordered]@{}; $ui.NavButtons = @{}
    # Find setting: the pages with a match show how many, the first one opens, the words light up
    $findPanel = New-Object System.Windows.Forms.Panel; $findPanel.Dock = 'Top'; $findPanel.Height = 44; $findPanel.BackColor = $T.Panel
    $findPanel.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 12)
    $find = New-Object System.Windows.Forms.TextBox; $find.Dock = 'Fill'; $find.BorderStyle = 'FixedSingle'
    $find.BackColor = $T.Surface; $find.ForeColor = $T.Text
    $findPanel.Controls.Add($find); $nav.Controls.Add($findPanel)
    $ui.Find = $find; $ui.FindColors = @{}
    $find.Add_HandleCreated({ try { [NrkNative]::Placeholder($this.Handle, 'Find setting') } catch { } })
    $find.Add_TextChanged({ Update-OptionsFind })
    $find.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { Update-OptionsFind -Next; $e.SuppressKeyPress = $true } elseif ($e.KeyCode -eq 'Escape' -and $this.Text) { $this.Text = ''; $e.SuppressKeyPress = $true } })
    $newPage = {
        param([string] $Name)
        $pg = New-Object System.Windows.Forms.Panel
        $pg.Dock = 'Fill'; $pg.BackColor = $T.Bg; $pg.Visible = $false; $pg.AutoScroll = $true
        [void]$pageHost.Controls.Add($pg)
        $ui.Pages[$Name] = $pg
        $b = New-Object System.Windows.Forms.Button
        $b.Text = '   ' + $Name; $b.TextAlign = 'MiddleLeft'; $b.Dock = 'Top'; $b.Height = 40
        $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.UseVisualStyleBackColor = $false
        $b.BackColor = $T.Panel; $b.ForeColor = $T.Text; $b.Font = $script:FontUi; $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $b.FlatAppearance.MouseOverBackColor = $T.Hover; $b.Tag = $Name
        $b.Add_Click({ & $script:OptShowPage $this.Tag })
        $nav.Controls.Add($b); $b.BringToFront()   # (Dock=Top: the newest goes last)
        $ui.NavButtons[$Name] = $b
        return $pg
    }
    $script:OptShowPage = {
        param([string] $Name)
        $u = $script:OptUi
        foreach ($k in $u.Pages.Keys) {
            $on = ($k -eq $Name)
            $u.Pages[$k].Visible = $on
            $u.NavButtons[$k].BackColor = if ($on) { $T.Sel } else { $T.Panel }
            $u.NavButtons[$k].ForeColor = if ($on) { $T.Accent } else { $T.Text }
        }
        $u.Current = $Name
    }

    $page = $null
    $add = {   # small helper: add a control at x,y on the current page
        param($c, [int] $x, [int] $y)
        $c.Location = New-Object System.Drawing.Point($x, $y); [void]$page.Controls.Add($c); $c
    }
    $header = {
        param([string] $text, [int] $y)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Font = $script:FontHeader; $l.AutoSize = $true
        [void](& $add $l 24 $y)
        $line = New-Object System.Windows.Forms.Panel; $line.Height = 1; $line.Width = 610; $line.BackColor = $T.Border
        [void](& $add $line 24 ($y + 28))
    }
    $check = {
        param([string] $text, [bool] $value, [int] $x, [int] $y)
        $c = New-Object System.Windows.Forms.CheckBox
        $c.Text = $text; $c.Checked = $value; $c.AutoSize = $true; $c.ForeColor = $T.Text
        $c.MaximumSize = New-Object System.Drawing.Size(600, 0)
        & $add $c $x $y
    }
    $muted = {
        param([string] $text, [int] $x, [int] $y, [int] $wd = 600, [int] $ht = 20)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.ForeColor = $T.Muted; $l.AutoSize = $false; $l.Width = $wd; $l.Height = $ht; $l.AutoEllipsis = $true
        & $add $l $x $y
    }
    $optTips = New-Object System.Windows.Forms.ToolTip

    # ---- General
    $page = & $newPage 'General'
    & $header 'Appearance' 18
    $lblTheme = New-Object System.Windows.Forms.Label; $lblTheme.Text = 'Theme'; $lblTheme.AutoSize = $true
    [void](& $add $lblTheme 26 64)
    $cbTheme = New-Object System.Windows.Forms.ComboBox
    $cbTheme.DropDownStyle = 'DropDownList'; $cbTheme.FlatStyle = 'Flat'; $cbTheme.Width = 300
    $cbTheme.BackColor = $T.Surface; $cbTheme.ForeColor = $T.Text
    [void]$cbTheme.Items.AddRange(@('Follow Windows (System)', 'Light', 'Dark'))
    $cbTheme.SelectedIndex = [array]::IndexOf(@('System', 'Light', 'Dark'), $script:ThemeMode)
    [void](& $add $cbTheme 120 60)
    [void](& $muted "Windows is set to $((Get-SystemTheme).ToLower()) mode" 432 64 200)
    $lblIcons = New-Object System.Windows.Forms.Label; $lblIcons.Text = 'Top bar icons'; $lblIcons.AutoSize = $true
    [void](& $add $lblIcons 26 102)
    $ui.TopIcons = New-Object System.Windows.Forms.ComboBox
    $ui.TopIcons.DropDownStyle = 'DropDownList'; $ui.TopIcons.FlatStyle = 'Flat'; $ui.TopIcons.Width = 300
    $ui.TopIcons.BackColor = $T.Surface; $ui.TopIcons.ForeColor = $T.Text
    foreach ($k in $script:TopIconStyles.Keys) { [void]$ui.TopIcons.Items.Add($script:TopIconStyles[$k]) }
    $ui.TopIcons.SelectedIndex = [Math]::Max(0, @($script:TopIconStyles.Keys).IndexOf([string]$st.TopIcons))
    [void](& $add $ui.TopIcons 120 98)
    $ui.TopIcons.Add_SelectedIndexChanged({
        $v = @($script:TopIconStyles.Keys)[$this.SelectedIndex]
        $s = Get-AppSettings; if ($s.TopIcons -eq $v) { return }
        $s.TopIcons = $v; Save-AppSettings $s; Write-Log INFO "Option TopIcons = $v"
        Set-TopBarIcons
    })
    & $header 'Folders and files' 150
    $lblSort = New-Object System.Windows.Forms.Label; $lblSort.Text = 'Sort'; $lblSort.AutoSize = $true
    [void](& $add $lblSort 26 196)
    $ui.Sort = New-Object System.Windows.Forms.ComboBox
    $ui.Sort.DropDownStyle = 'DropDownList'; $ui.Sort.FlatStyle = 'Flat'; $ui.Sort.Width = 300
    $ui.Sort.BackColor = $T.Surface; $ui.Sort.ForeColor = $T.Text
    [void]$ui.Sort.Items.AddRange(@('Z - A (descending)', 'A - Z', "NRK's own order"))
    $ui.Sort.SelectedIndex = [array]::IndexOf(@('desc', 'asc', 'nrk'), (Get-SortOrder))
    [void](& $add $ui.Sort 120 192)
    [void](& $muted 'Episodes sort by date or episode number. Live channels keep their own order.' 26 230)
    $bHidden = New-FlatButton ('Hidden items ({0})...' -f (Get-ExcludedMap).Count) 210
    [void](& $add $bHidden 24 266)
    [void](& $muted "What you hid with right-click > Hide: not shown, not indexed." 246 274 380)
    $optTips.SetToolTip($bHidden, 'Open the list to show hidden things again.')
    $bHidden.Add_Click({ Show-ExcludedWindow -Owner $script:OptUi.Form; $this.Text = ('Hidden items ({0})...' -f (Get-ExcludedMap).Count) })
    $lblView = New-Object System.Windows.Forms.Label; $lblView.Text = 'Show files as'; $lblView.AutoSize = $true
    [void](& $add $lblView 26 318)
    $ui.FilesView = New-Object System.Windows.Forms.ComboBox
    $ui.FilesView.DropDownStyle = 'DropDownList'; $ui.FilesView.FlatStyle = 'Flat'; $ui.FilesView.Width = 300
    $ui.FilesView.BackColor = $T.Surface; $ui.FilesView.ForeColor = $T.Text
    [void]$ui.FilesView.Items.AddRange(@('A list (rows)', 'Thumbnails (pictures)'))
    $ui.FilesView.SelectedIndex = $(if ([string]$st.FilesView -eq 'grid') { 1 } else { 0 })
    [void](& $add $ui.FilesView 120 314)
    $ui.FilesView.Add_SelectedIndexChanged({ Set-FilesView $(if ($this.SelectedIndex -eq 1) { 'grid' } else { 'list' }) })
    & $header 'Child mode' 366
    [void](& $muted 'Only NRK Super and children''s categories, nothing rated above the age you choose, no search. Leaving it needs a PIN.' 26 404 600 36)
    $lblAge = New-Object System.Windows.Forms.Label; $lblAge.Text = 'Up to'; $lblAge.AutoSize = $true
    [void](& $add $lblAge 26 452)
    $ui.ChildAge = New-Object System.Windows.Forms.ComboBox
    $ui.ChildAge.DropDownStyle = 'DropDownList'; $ui.ChildAge.FlatStyle = 'Flat'; $ui.ChildAge.Width = 200
    $ui.ChildAge.BackColor = $T.Surface; $ui.ChildAge.ForeColor = $T.Text
    [void]$ui.ChildAge.Items.AddRange(@('A (for everyone)', '6 years', '9 years', '12 years'))
    $ui.ChildAge.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@('A', '6', '9', '12'), [string]$st.ChildMaxAge))
    $ui.ChildAge.Enabled = -not $st.ChildMode
    [void](& $add $ui.ChildAge 120 448)
    $ui.ChildAge.Add_SelectedIndexChanged({ $s = Get-AppSettings; $s.ChildMaxAge = @('A', '6', '9', '12')[$this.SelectedIndex]; Save-AppSettings $s })
    $ui.ChildBtn = New-FlatButton $(if ($st.ChildMode) { 'Turn child mode off...' } else { 'Turn child mode on...' }) 220 -Primary
    [void](& $add $ui.ChildBtn 340 444)
    $ui.ChildBtn.Add_Click({
        $on = -not (Test-ChildMode)
        if (Set-ChildMode $on) {
            $this.Text = if ($on) { 'Turn child mode off...' } else { 'Turn child mode on...' }
            $script:OptUi.ChildAge.Enabled = -not $on
        }
    })


    # ---- Playback
    $page = & $newPage 'Playback'
    & $header 'Playback' 18
    $ui.WebPlayer = & $check "Play programmes and live TV on NRK's web page instead of the built-in player" ($st.VideoPlayer -eq 'web') 26 60
    $optTips.SetToolTip($ui.WebPlayer, "The built-in player plays NRK's stream directly, with subtitles and chapters. Tick this to use NRK's own player inside the NRK web page instead (the way it was before). 'Open NRK page' in the player does the same for one programme. Live channels always use NRK's page.")
    $ui.OnePlayer = & $check 'Play one thing at a time (a video closes the radio, the radio closes the video)' $st.OnePlayer 26 92
    $ui.Resume = & $check 'Continue where you left off' $st.ResumePlayback 26 124
    [void](& $muted 'After a restart, crash or update the app opens what was playing again (live: live).' 46 150 580 22)
    $ui.ResumePos = & $check 'Continue each programme, episode and recording where you stopped' ([bool]$st.ResumePosition) 26 178
    $ui.HideWatched = & $check 'Hide what you have watched in the files list' ([bool]$st.HideWatched) 26 210
    $ui.ListDesc = & $check 'Show the description under each title in the files list' ([bool]$st.ListDescriptions) 26 242
    $ui.AutoNext = & $check 'Play the next episode when one ends (video, radio and casting)' ([bool]$st.AutoNext) 26 274
    $ui.PreferAD = & $check 'Prefer audio description (synstolking) when a programme has it' ([bool]$st.PreferAD) 26 306
    $ui.AutoNext.Add_CheckedChanged({ & $script:OptSaveFlag 'AutoNext' $this.Checked })
    $ui.PreferAD.Add_CheckedChanged({ & $script:OptSaveFlag 'PreferAD' $this.Checked })
    $ui.ResumePos.Add_CheckedChanged({ & $script:OptSaveFlag 'ResumePosition' $this.Checked })
    $ui.HideWatched.Add_CheckedChanged({ & $script:OptSaveFlag 'HideWatched' $this.Checked; Show-Files })
    $ui.ListDesc.Add_CheckedChanged({ & $script:OptSaveFlag 'ListDescriptions' $this.Checked; Show-Files })
    $optTips.SetToolTip($ui.ResumePos, 'Played to the end counts as watched (a green line under it). Right-click a file > Mark as watched / not watched.')
    & $header 'Sound output' 354
    $lblOut = New-Object System.Windows.Forms.Label; $lblOut.Text = 'Play sound on'; $lblOut.AutoSize = $true
    [void](& $add $lblOut 26 400)
    $ui.AudioOut = New-Object System.Windows.Forms.ComboBox
    $ui.AudioOut.DropDownStyle = 'DropDownList'; $ui.AudioOut.FlatStyle = 'Flat'; $ui.AudioOut.Width = 360
    $ui.AudioOut.BackColor = $T.Surface; $ui.AudioOut.ForeColor = $T.Text
    [void](& $add $ui.AudioOut 140 396)
    $bOutRefresh = New-FlatButton 'Refresh' 90
    [void](& $add $bOutRefresh 510 392)
    [void](& $muted "Only this app: the radio bar and the video player. Windows and other apps keep their own output." 26 436 600 36)
    $script:OptFillAudio = {
        $u = $script:OptUi; $cur = [string](Get-AppSettings).AudioDevice
        $u.AudioFilling = $true
        $u.AudioOut.Items.Clear(); [void]$u.AudioOut.Items.Add('Windows default')
        $devs = @(Get-AudioOutputDevices | ForEach-Object { $_ })   # (the function returns the list as one object: unroll it)
        foreach ($d in $devs) { [void]$u.AudioOut.Items.Add($d) }
        if ($cur -and -not ($devs -contains $cur)) { [void]$u.AudioOut.Items.Add("$cur  (not connected)") ; $u.AudioOut.SelectedIndex = $u.AudioOut.Items.Count - 1 }
        elseif ($cur) { $u.AudioOut.SelectedItem = $cur } else { $u.AudioOut.SelectedIndex = 0 }
        $u.AudioFilling = $false
    }
    & $script:OptFillAudio
    $bOutRefresh.Add_Click({ & $script:OptFillAudio })
    $ui.AudioOut.Add_SelectedIndexChanged({
        $u = $script:OptUi; if ($u.AudioFilling) { return }
        $v = if ($this.SelectedIndex -le 0) { '' } else { ([string]$this.SelectedItem) -replace '\s+\(not connected\)$', '' }
        $s = Get-AppSettings; if ([string]$s.AudioDevice -eq $v) { return }
        $s.AudioDevice = $v; Save-AppSettings $s
        Write-Log INFO "Option AudioDevice = $(if ($v) { $v } else { 'Windows default' })"
        if (-not $v) { Send-AudioSink; Set-AudioSinkPermission $false } else { Send-AudioSink }
    })
    $optTips.SetToolTip($ui.Resume, 'Stopping playback yourself clears it.')

    # ---- Downloads
    $page = & $newPage 'Downloads'
    & $header 'Where' 18
    $optDirRow = {
        param([string] $Text, [bool] $Radio, [int] $Y)
        $l = New-Object System.Windows.Forms.Label; $l.Text = $Text; $l.AutoSize = $true
        [void](& $add $l 26 ($Y + 4))
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Width = 330; $tb.BackColor = $T.Surface; $tb.ForeColor = $T.Text; $tb.BorderStyle = 'FixedSingle'
        $tb.Text = Get-DownloadDir -Radio:$Radio
        [void](& $add $tb 150 $Y)
        $b = New-FlatButton 'Browse...' 100; $b.Tag = $Radio
        [void](& $add $b 490 ($Y - 4))
        $b.Add_Click({
            $r = [bool]$this.Tag
            $box = if ($r) { $script:OptUi.RadioDir } else { $script:OptUi.DlDir }
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = "Choose where $(if ($r) { 'radio' } else { 'TV' }) downloads are saved"
            if ($box.Text -and (Test-Path -LiteralPath $box.Text)) { $dlg.SelectedPath = $box.Text }
            if ($dlg.ShowDialog($script:OptUi.Form) -eq 'OK') { $box.Text = $dlg.SelectedPath; & $script:OptSaveDlDir }
        })
        $tb.Add_Leave({ & $script:OptSaveDlDir })
        $tb
    }
    $ui.DlDir = & $optDirRow 'TV folder' $false 58
    $ui.RadioDir = & $optDirRow 'Radio folder' $true 98
    [void](& $muted 'Defaults: Videos\NRK-Browser and Music\NRK-Browser. If a folder is gone when a download starts, you are asked to choose one.' 26 132 600 20)
    & $header 'Files' 158
    $ui.DlSubs = & $check 'Subtitles inside the video (players list them in their subtitle menu)' ([bool]$st.DlEmbedSubs) 26 200
    $ui.DlSrt = & $check 'Also save the subtitles as .srt and the cover as .jpg next to the video' ([bool]$st.DlKeepSrt) 26 232
    [void](& $muted "TV is saved as MP4 in NRK's best quality, copied as it is (never re-encoded), with chapters, cover and tags." 26 264 600 36)
    $lblRf = New-Object System.Windows.Forms.Label; $lblRf.Text = 'Radio format'; $lblRf.AutoSize = $true
    [void](& $add $lblRf 26 308)
    $ui.RadioFmt = New-Object System.Windows.Forms.ComboBox
    $ui.RadioFmt.DropDownStyle = 'DropDownList'; $ui.RadioFmt.FlatStyle = 'Flat'; $ui.RadioFmt.Width = 420
    $ui.RadioFmt.BackColor = $T.Surface; $ui.RadioFmt.ForeColor = $T.Text
    [void]$ui.RadioFmt.Items.AddRange(@('As NRK sends it: M4A (AAC) or MP3, no quality loss (default)', 'MP3: plays everywhere (converted, 320 kbps)', 'FLAC: lossless copy of what NRK sends (large files)'))
    $ui.RadioFmt.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@('original', 'mp3', 'flac'), [string]$st.RadioFormat))
    [void](& $add $ui.RadioFmt 150 304)
    $ui.RadioFmt.Add_SelectedIndexChanged({
        $v = @('original', 'mp3', 'flac')[$this.SelectedIndex]
        $s = Get-AppSettings; if ($s.RadioFormat -ne $v) { $s.RadioFormat = $v; Save-AppSettings $s; Write-Log INFO "Option RadioFormat = $v" }
    })
    $optTips.SetToolTip($ui.RadioFmt, "NRK sends radio as AAC (or MP3). Converting can't add quality: MP3 loses a little, FLAC keeps it but is about 5 times bigger.")
    & $header 'Connection' 356
    $lblPar = New-Object System.Windows.Forms.Label; $lblPar.Text = 'Pieces at a time'; $lblPar.AutoSize = $true
    [void](& $add $lblPar 26 400)
    $ui.DlPar = New-Object System.Windows.Forms.ComboBox
    $ui.DlPar.DropDownStyle = 'DropDownList'; $ui.DlPar.FlatStyle = 'Flat'; $ui.DlPar.Width = 200
    $ui.DlPar.BackColor = $T.Surface; $ui.DlPar.ForeColor = $T.Text
    [void]$ui.DlPar.Items.AddRange(@('1 (slow connection)', '2', '3 (default)', '4', '6 (fast connection)'))
    $ui.DlPar.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@(1, 2, 3, 4, 6), [int]$st.DlParallel))
    [void](& $add $ui.DlPar 170 396)
    $ui.DlAuto = & $check 'If the connection drops: pause, and continue by itself when it is back' ([bool]$st.DlAutoResume) 26 438
    [void](& $muted 'Pause / Resume in the Downloads window keeps what is downloaded; it also continues after a restart.' 26 468 600 36)
    $ui.DlKeep = & $check 'Keep the whole download list after a restart (off: only what is not finished yet)' ([bool]$st.DlKeepList) 26 508
    $ui.DlKeep.Add_CheckedChanged({ & $script:OptSaveFlag 'DlKeepList' $this.Checked })
    $ui.DlAd = & $check 'Download the audio-described version (synstolking) when there is one' ([bool]$st.DlAudioDescription) 26 540
    $ui.DlAd.Add_CheckedChanged({ & $script:OptSaveFlag 'DlAudioDescription' $this.Checked })
    $combo = {
        param([string] $Label, [int] $Y, [string[]] $Items, [string[]] $Values, [string] $Key, [int] $Width = 260)
        $l = New-Object System.Windows.Forms.Label; $l.Text = $Label; $l.AutoSize = $true
        [void](& $add $l 26 ($Y + 4))
        $c = New-Object System.Windows.Forms.ComboBox
        $c.DropDownStyle = 'DropDownList'; $c.FlatStyle = 'Flat'; $c.Width = $Width; $c.BackColor = $T.Surface; $c.ForeColor = $T.Text
        [void]$c.Items.AddRange($Items); $c.Tag = @{ Key = $Key; Values = $Values }
        $c.SelectedIndex = [Math]::Max(0, [array]::IndexOf($Values, [string](Get-AppSettings).$Key))
        $c.Add_SelectedIndexChanged({ $s = Get-AppSettings; $k = $this.Tag.Key; $v = $this.Tag.Values[$this.SelectedIndex]; if ([string]$s.$k -ne $v) { $s.$k = $v; Save-AppSettings $s; Write-Log INFO "Option $k = $v" } })
        [void](& $add $c 220 $Y)
        $c
    }
    [void](& $muted ("Quality, file type, whole series, speed limit, download hours and history: see the Download rules page.") 26 576 600 20)
    # ---- Download rules (what and when; the Downloads page has folders and connection)
    $page = & $newPage 'Download rules'
    & $header 'Quality and format' 18
    [void](& $combo 'TV quality' 58 @('Best NRK has', 'Up to 1080p', 'Up to 720p', 'Up to 480p (small files)', 'Up to 360p (smallest)') @('best', '1080', '720', '480', '360') 'DlQuality')
    [void](& $combo 'TV file type' 96 @('MP4 (plays everywhere)', 'MKV (Matroska)') @('mp4', 'mkv') 'DlContainer')
    $ui.DlNfo = & $check 'Save .nfo files and pictures for Kodi, Jellyfin and Plex' ([bool]$st.DlNfo) 26 136
    $ui.DlNfo.Add_CheckedChanged({ & $script:OptSaveFlag 'DlNfo' $this.Checked })
    & $header 'Whole series' 184
    [void](& $combo 'Download' 224 @('Every episode', 'Only the newest 1', 'Only the newest 3', 'Only the newest 5', 'Only the newest 10', 'Only the newest 25') @('0', '1', '3', '5', '10', '25') 'DlSeriesNewest')
    $lblAfter = New-Object System.Windows.Forms.Label; $lblAfter.Text = 'Only published after'; $lblAfter.AutoSize = $true
    [void](& $add $lblAfter 26 266)
    $ui.DlAfter = New-Object System.Windows.Forms.TextBox; $ui.DlAfter.Width = 120; $ui.DlAfter.BackColor = $T.Surface; $ui.DlAfter.ForeColor = $T.Text; $ui.DlAfter.BorderStyle = 'FixedSingle'
    $ui.DlAfter.Text = [string]$st.DlSeriesAfter
    [void](& $add $ui.DlAfter 220 262)
    [void](& $muted 'yyyy-mm-dd, empty = any date' 350 266 280)
    $ui.DlAfter.Add_Leave({ $v = $this.Text.Trim(); if ($v -and $v -notmatch '^\d{4}-\d\d-\d\d$') { $this.Text = [string](Get-AppSettings).DlSeriesAfter; return }; $s = Get-AppSettings; if ($s.DlSeriesAfter -ne $v) { $s.DlSeriesAfter = $v; Save-AppSettings $s } })
    & $header 'When and how fast' 310
    [void](& $combo 'Speed limit' 350 @('No limit', '500 KB/s', '1 MB/s', '2 MB/s', '5 MB/s') @('0', '500', '1000', '2000', '5000') 'DlSpeedKB')
    $lblWin = New-Object System.Windows.Forms.Label; $lblWin.Text = 'Only download between'; $lblWin.AutoSize = $true
    [void](& $add $lblWin 26 392)
    $ui.DlWin = New-Object System.Windows.Forms.TextBox; $ui.DlWin.Width = 120; $ui.DlWin.BackColor = $T.Surface; $ui.DlWin.ForeColor = $T.Text; $ui.DlWin.BorderStyle = 'FixedSingle'
    $ui.DlWin.Text = [string]$st.DlWindow
    [void](& $add $ui.DlWin 220 388)
    [void](& $muted 'for example 01:00-07:00, empty = any time' 350 392 280)
    $ui.DlWin.Add_Leave({ $v = $this.Text.Trim(); if ($v -and $v -notmatch '^\d{1,2}:\d\d\s*-\s*\d{1,2}:\d\d$') { $this.Text = [string](Get-AppSettings).DlWindow; return }; $s = Get-AppSettings; if ($s.DlWindow -ne $v) { $s.DlWindow = $v; Save-AppSettings $s } })
    $ui.DlNotify = & $check 'Tell me (Windows notification) when downloads finish or new episodes arrive' ([bool]$st.DlNotify) 26 432
    $ui.DlNotify.Add_CheckedChanged({ & $script:OptSaveFlag 'DlNotify' $this.Checked })
    & $header 'History' 480
    $ui.DlHist = & $check "Don't download again what was downloaded before (also after it was moved or deleted)" ([bool]$st.DlSkipHistory) 26 520
    $ui.DlHist.Add_CheckedChanged({ & $script:OptSaveFlag 'DlSkipHistory' $this.Checked })
    $bHist = New-FlatButton ('Clear download history ({0})' -f (Get-DlHistory).Count) 260
    [void](& $add $bHist 24 554)
    $bHist.Add_Click({ if ([System.Windows.Forms.MessageBox]::Show($script:OptUi.Form, 'Forget what was downloaded before?', 'Download history', 'YesNo', 'Question') -eq 'Yes') { Clear-DlHistory; $this.Text = 'Clear download history (0)' } })
    # 2.9.0: file names
    & $header 'File names' 616
    $lblNt = New-Object System.Windows.Forms.Label; $lblNt.Text = 'TV episodes'; $lblNt.AutoSize = $true
    [void](& $add $lblNt 26 660)
    $ui.NameTv = New-Object System.Windows.Forms.TextBox; $ui.NameTv.Width = 380; $ui.NameTv.BackColor = $T.Surface; $ui.NameTv.ForeColor = $T.Text; $ui.NameTv.BorderStyle = 'FixedSingle'
    $ui.NameTv.Text = [string]$st.DlNameTv; [void](& $add $ui.NameTv 220 656)
    $lblNr = New-Object System.Windows.Forms.Label; $lblNr.Text = 'Radio and podcasts'; $lblNr.AutoSize = $true
    [void](& $add $lblNr 26 700)
    $ui.NameRadio = New-Object System.Windows.Forms.TextBox; $ui.NameRadio.Width = 380; $ui.NameRadio.BackColor = $T.Surface; $ui.NameRadio.ForeColor = $T.Text; $ui.NameRadio.BorderStyle = 'FixedSingle'
    $ui.NameRadio.Text = [string]$st.DlNameRadio; [void](& $add $ui.NameRadio 220 696)
    [void](& $muted 'Empty = as before ("Series - s01e02 - Title", "2026-10-20 - Title"). You can use {series} {season} {episode} {title} {date} {id}, for example {series} - S{season}E{episode} - {title}. The folders stay the same. If something the name uses is not known (no episode number), the built-in name is used.' 26 734 600 74)
    foreach ($tb in @($ui.NameTv, $ui.NameRadio)) {
        $tb.Add_HandleCreated({ try { [NrkNative]::Placeholder($this.Handle, 'built-in name') } catch { } })
        $tb.Add_Leave({
            $s = Get-AppSettings; $k = if ($this -eq $script:OptUi.NameTv) { 'DlNameTv' } else { 'DlNameRadio' }
            $v = $this.Text.Trim(); if ([string]$s.$k -ne $v) { $s.$k = $v; Save-AppSettings $s; Write-Log INFO "Option $k = $v" }
        })
    }
    [void](& $muted '' 26 820 10 10)   # (room at the bottom when scrolled)
    $script:OptSaveDlDir = {
        # both download folders (a download that is running keeps the folder it started in)
        foreach ($r in @($false, $true)) {
            $box = if ($r) { $script:OptUi.RadioDir } else { $script:OptUi.DlDir }
            $d = $box.Text.Trim()
            if (-not $d) { $box.Text = Get-DownloadDir -Radio:$r; continue }
            Set-DownloadDirSetting $d -Radio:$r
        }
    }
    $ui.DlSubs.Add_CheckedChanged({ & $script:OptSaveFlag 'DlEmbedSubs' $this.Checked })
    $ui.DlSrt.Add_CheckedChanged({ & $script:OptSaveFlag 'DlKeepSrt' $this.Checked })
    $ui.DlAuto.Add_CheckedChanged({ & $script:OptSaveFlag 'DlAutoResume' $this.Checked })
    $ui.DlPar.Add_SelectedIndexChanged({ $s = Get-AppSettings; $s.DlParallel = @(1, 2, 3, 4, 6)[$this.SelectedIndex]; Save-AppSettings $s; Write-Log INFO "Option DlParallel = $($s.DlParallel)" })

    # ---- System tray
    $page = & $newPage 'System tray'
    & $header 'System tray' 18
    $ui.Tray = & $check 'Show an icon in the system tray' $st.TrayIcon 26 60
    $ui.MinTray = & $check 'Minimize to the tray (radio and video keep playing in the background)' $st.MinimizeToTray 26 92
    $ui.CloseTray = & $check 'The close button hides to the tray instead of exiting' $st.CloseToTray 26 124
    $ui.Startup = & $check 'Start with Windows, in the tray' $st.StartWithWindows 26 156
    [void](& $muted 'The tray menu has Open, Pause / Play, Mute and Exit.' 26 196)

    # ---- Updates
    $page = & $newPage 'Updates'
    & $header 'Updates' 18
    [void](& $muted ("This is version {0}  ·  updates come from github.com/{1}" -f $script:AppVersion, $script:UpdateRepo) 26 58)
    $ui.AutoUpd = & $check 'Check for updates when the app starts (at most twice a day)' $st.CheckUpdates 26 88
    $bCheck = New-FlatButton 'Check for updates now' 226
    [void](& $add $bCheck 24 126)
    $last = if ($st.LastUpdateCheck) { try { 'Last check: ' + ([datetime]$st.LastUpdateCheck).ToString('dd.MM.yyyy HH:mm') } catch { '' } } else { 'Not checked yet' }
    [void](& $muted $last 262 134 360)
    & $header 'Components' 190
    [void](& $muted 'WebView2, FFmpeg and hls.js: check them, install what is missing, or reinstall one.' 26 230)
    $bComponents = New-FlatButton 'Components...' 186
    [void](& $add $bComponents 24 262)

    # ---- Install & files
    $page = & $newPage 'Install & files'
    & $header 'Install' 18
    $ui.InstallInfo = & $muted '' 26 56 600 58
    $ui.StartMenu = & $check 'Start menu shortcut' $st.StartMenuShortcut 26 118
    $ui.Desktop = & $check 'Desktop shortcut' $st.DesktopShortcut 220 118
    $ui.Install = New-FlatButton 'Install' 170 -Primary
    [void](& $add $ui.Install 24 150)
    $ui.Uninstall = New-FlatButton 'Uninstall' 146
    [void](& $add $ui.Uninstall 204 150)
    & $header 'Local files' 204
    [void](& $muted ("Everything is stored in {0}: the installed copy, settings, saved NRK data, logs and components." -f $script:AppDataDir) 26 242 600 40)
    $bLocal = New-FlatButton 'View local files' 186 -Primary
    [void](& $add $bLocal 24 286)
    $optTips.SetToolTip($bLocal, $script:AppDataDir)
    $sizeMb = [Math]::Round((Get-CacheSize) / 1MB, 1)
    $ui.ClearCache = New-FlatButton ("Clear saved NRK data ({0} MB)" -f $sizeMb) 260
    [void](& $add $ui.ClearCache 220 286)
    $optTips.SetToolTip($ui.ClearCache, 'Saved NRK pages and images, so folders open instantly. They are refreshed in the background.')
    $lblCache = New-Object System.Windows.Forms.Label; $lblCache.Text = 'Refresh saved NRK data'; $lblCache.AutoSize = $true
    [void](& $add $lblCache 26 342)
    $ui.CacheMode = New-Object System.Windows.Forms.ComboBox
    $ui.CacheMode.DropDownStyle = 'DropDownList'; $ui.CacheMode.FlatStyle = 'Flat'; $ui.CacheMode.Width = 340
    $ui.CacheMode.BackColor = $T.Surface; $ui.CacheMode.ForeColor = $T.Text
    foreach ($k in $script:CacheModes.Keys) { [void]$ui.CacheMode.Items.Add($script:CacheModes[$k].Label) }
    $ui.CacheMode.SelectedIndex = [Math]::Max(0, @($script:CacheModes.Keys).IndexOf($script:CacheMode))
    [void](& $add $ui.CacheMode 220 338)
    $ui.LogDisk = & $check 'Save logs to disk (kept for 3 days; the Logs window always shows this session)' ([bool]$st.Logging) 26 386
    & $header 'Back up' 432
    [void](& $muted 'Your settings, favourites, hidden items, what you have watched (and where you stopped), recently played and the download list, in one file.' 26 470 600 36)
    $bBackup = New-FlatButton 'Back up...' 140 -Primary
    [void](& $add $bBackup 24 512)
    $bRestore = New-FlatButton 'Restore...' 140
    [void](& $add $bRestore 176 512)
    $bBackup.Add_Click({
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Filter = 'NRK Browser backup (*.zip)|*.zip'; $dlg.FileName = 'NRK-Browser-backup-{0:yyyy-MM-dd}.zip' -f (Get-Date)
        $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
        if ($dlg.ShowDialog($script:OptUi.Form) -ne 'OK') { return }
        try { $n = Export-AppBackup $dlg.FileName; [void][System.Windows.Forms.MessageBox]::Show($script:OptUi.Form, "Saved $n file(s) in`n$($dlg.FileName)", 'Back up', 'OK', 'Information') }
        catch { Write-LogException $_ 'Backup'; [void][System.Windows.Forms.MessageBox]::Show($script:OptUi.Form, "Could not save the backup:`n$($_.Exception.Message)", 'Back up', 'OK', 'Error') }
    })
    $bRestore.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'NRK Browser backup (*.zip)|*.zip'; $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
        if ($dlg.ShowDialog($script:OptUi.Form) -ne 'OK') { return }
        $q = [System.Windows.Forms.MessageBox]::Show($script:OptUi.Form, "Replace your settings, favourites, hidden items, watched list, recently played and download list with the ones in`n$($dlg.FileName)?`n`nWhat you have now is kept in the app's backups folder first.", 'Restore', 'YesNo', 'Warning')
        if ($q -ne 'Yes') { return }
        try { $n = Import-AppBackup $dlg.FileName }
        catch { Write-LogException $_ 'Restore'; [void][System.Windows.Forms.MessageBox]::Show($script:OptUi.Form, "Could not restore:`n$($_.Exception.Message)", 'Restore', 'OK', 'Error'); return }
        if ([System.Windows.Forms.MessageBox]::Show($script:OptUi.Form, "Restored $n file(s). NRK Browser restarts now to use them.", 'Restore', 'OKCancel', 'Information') -eq 'OK') {
            $script:ForceExit = $true; $script:OptUi.Form.Close(); Start-AppDetached; Exit-App
        }
    })
    $ui.LogDisk.Add_CheckedChanged({
        $s = Get-AppSettings; $s.Logging = $this.Checked; Save-AppSettings $s; Set-LogToDisk $this.Checked
        if ($script:LogsUi -and $script:LogsUi.Disk) { $script:LogsUi.Disk.Checked = $this.Checked }
    })

    # ---- 2.9.0: Listening
    $page = & $newPage 'Listening'
    & $header 'Radio bar' 18
    $ui.Silence = & $check 'Skip silences: the quiet parts of programmes and podcasts play faster' ([bool]$st.SkipSilence) 26 60
    $ui.Silence.Add_CheckedChanged({ & $script:OptSaveFlag 'SkipSilence' $this.Checked; Send-AudioFx })
    $ui.Boost = & $check 'Voice boost: clearer, more even speech (quiet voices louder)' ([bool]$st.VoiceBoost) 26 92
    $ui.Boost.Add_CheckedChanged({ & $script:OptSaveFlag 'VoiceBoost' $this.Checked; Send-AudioFx })
    $ui.NowPl = & $check 'Live radio: show the song that is playing (when NRK says)' ([bool]$st.NowPlaying) 26 124
    $ui.NowPl.Add_CheckedChanged({ & $script:OptSaveFlag 'NowPlaying' $this.Checked })
    [void](& $muted 'Also the bars button in the radio bar. Speed and skipping the start / end for one series: that button > Settings for <series>. A podcast file from another site may not allow the sound effects; it then plays without them.' 26 154 600 52)
    & $header 'Sleep timer and next episode' 218
    $ui.Fade = & $check 'Sleep timer: lower the volume over the last minute' ([bool]$st.SleepFade) 26 260
    $ui.Fade.Add_CheckedChanged({ & $script:OptSaveFlag 'SleepFade' $this.Checked })
    $ui.UpCard = & $check 'Built-in player: a card with a countdown before the next episode (Play now / Cancel)' ([bool]$st.UpNextCard) 26 292
    $ui.UpCard.Add_CheckedChanged({ & $script:OptSaveFlag 'UpNextCard' $this.Checked })
    [void](& $combo 'Countdown' 326 @('5 seconds', '10 seconds', '15 seconds', '20 seconds', '30 seconds') @('5', '10', '15', '20', '30') 'UpNextSeconds' 160)
    & $header 'Statistics' 380
    $ui.Stats = & $check 'Count what I watch and listen to (only on this PC)' ([bool]$st.StatsOn) 26 422
    $ui.Stats.Add_CheckedChanged({ & $script:OptSaveFlag 'StatsOn' $this.Checked })
    $bStats = New-FlatButton 'Show statistics...' 170; [void](& $add $bStats 24 454)
    $bStats.Add_Click({ Show-StatsWindow })
    & $header 'Recordings (live TV and radio)' 512
    $lblRd = New-Object System.Windows.Forms.Label; $lblRd.Text = 'Folder'; $lblRd.AutoSize = $true
    [void](& $add $lblRd 26 556)
    $ui.RecDir = New-Object System.Windows.Forms.TextBox; $ui.RecDir.Width = 360; $ui.RecDir.BackColor = $T.Surface; $ui.RecDir.ForeColor = $T.Text; $ui.RecDir.BorderStyle = 'FixedSingle'
    $ui.RecDir.Text = [string]$st.RecordDir; [void](& $add $ui.RecDir 120 552)
    $ui.RecDir.Add_HandleCreated({ try { [NrkNative]::Placeholder($this.Handle, 'the download folders \ Recordings') } catch { } })
    $ui.RecDir.Add_Leave({ $s = Get-AppSettings; $v = $this.Text.Trim(); if ([string]$s.RecordDir -ne $v) { $s.RecordDir = $v; Save-AppSettings $s; Write-Log INFO "Option RecordDir = $v" } })
    $bRecs = New-FlatButton 'Recordings...' 130; [void](& $add $bRecs 490 549)
    $bRecs.Add_Click({ Show-RecordingsWindow })
    [void](& $muted 'Right-click a live channel > Record..., or a programme in the TV schedule > Record this programme. Needs FFmpeg; the app must be running (the tray is fine).' 26 588 600 40)
    [void](& $muted '' 26 640 10 10)

    # ---- 2.9.0: Wake to radio
    $page = & $newPage 'Wake to radio'
    & $header 'Wake to radio' 18
    $ui.Alarm = & $check 'Start a radio channel at this time' ([bool]$st.AlarmOn) 26 60
    $ui.Alarm.Add_CheckedChanged({ & $script:OptSaveFlag 'AlarmOn' $this.Checked; & $script:OptAlarmNext })
    $lblAt = New-Object System.Windows.Forms.Label; $lblAt.Text = 'Time (hh:mm)'; $lblAt.AutoSize = $true
    [void](& $add $lblAt 26 104)
    $ui.AlarmTime = New-Object System.Windows.Forms.TextBox; $ui.AlarmTime.Width = 80; $ui.AlarmTime.BackColor = $T.Surface; $ui.AlarmTime.ForeColor = $T.Text; $ui.AlarmTime.BorderStyle = 'FixedSingle'
    $ui.AlarmTime.Text = [string]$st.AlarmTime; [void](& $add $ui.AlarmTime 220 100)
    $ui.AlarmTime.Add_Leave({ $v = $this.Text.Trim(); if ($v -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { $this.Text = [string](Get-AppSettings).AlarmTime; return }; $s = Get-AppSettings; if ($s.AlarmTime -ne $v) { $s.AlarmTime = $v; $s.AlarmLast = ''; Save-AppSettings $s; Write-Log INFO "Option AlarmTime = $v" }; & $script:OptAlarmNext })
    $lblDays = New-Object System.Windows.Forms.Label; $lblDays.Text = 'Days'; $lblDays.AutoSize = $true
    [void](& $add $lblDays 26 144)
    $ui.AlarmDays = @()
    $dx = 220
    foreach ($d in @(@(1, 'Mon'), @(2, 'Tue'), @(3, 'Wed'), @(4, 'Thu'), @(5, 'Fri'), @(6, 'Sat'), @(7, 'Sun'))) {
        $c = New-Object System.Windows.Forms.CheckBox; $c.Text = $d[1]; $c.AutoSize = $true; $c.ForeColor = $T.Text; $c.Tag = $d[0]
        $c.Checked = (@([string]$st.AlarmDays -split ',') -contains [string]$d[0])
        [void](& $add $c $dx 142); $dx += 56; $ui.AlarmDays += $c
        $c.Add_CheckedChanged({ $s = Get-AppSettings; $s.AlarmDays = (@($script:OptUi.AlarmDays | Where-Object { $_.Checked } | ForEach-Object { [string]$_.Tag }) -join ','); Save-AppSettings $s; & $script:OptAlarmNext })
    }
    $lblCh = New-Object System.Windows.Forms.Label; $lblCh.Text = 'Channel'; $lblCh.AutoSize = $true
    [void](& $add $lblCh 26 188)
    $ui.AlarmCh = New-Object System.Windows.Forms.ComboBox; $ui.AlarmCh.DropDownStyle = 'DropDownList'; $ui.AlarmCh.FlatStyle = 'Flat'; $ui.AlarmCh.Width = 260; $ui.AlarmCh.BackColor = $T.Surface; $ui.AlarmCh.ForeColor = $T.Text
    [void](& $add $ui.AlarmCh 220 184)
    $ui.AlarmChIds = @()
    $chs = @(); try { $chs = @(Get-Cached 'radio:live' { Get-NrkLiveChannels -Medium radio }) } catch { }
    if (-not $chs.Count) { $chs = @([pscustomobject]@{ Id = [string]$st.AlarmChannel; Title = [string]$st.AlarmChannelTitle }) }
    foreach ($c in $chs) { [void]$ui.AlarmCh.Items.Add([string]$c.Title); $ui.AlarmChIds += [string]$c.Id }
    $ui.AlarmCh.SelectedIndex = [Math]::Max(0, [array]::IndexOf($ui.AlarmChIds, [string]$st.AlarmChannel))
    $ui.AlarmCh.Add_SelectedIndexChanged({ $s = Get-AppSettings; $s.AlarmChannel = $script:OptUi.AlarmChIds[$this.SelectedIndex]; $s.AlarmChannelTitle = [string]$this.SelectedItem; Save-AppSettings $s; Write-Log INFO "Option AlarmChannel = $($s.AlarmChannel)" })
    $ui.AlarmNext = & $muted '' 26 228 600 20
    [void](& $muted 'The PC must be on and NRK Browser running (in the tray is fine). The volume rises gently over 45 seconds. Sleep mode: Windows does not wake the PC for this.' 26 258 600 40)
    $bTry = New-FlatButton 'Try it now' 120; [void](& $add $bTry 24 306)
    $bTry.Add_Click({ $s = Get-AppSettings; Invoke-PlayCommand ("radio:{0}" -f $s.AlarmChannel) -Alarm })
    $script:OptAlarmNext = {
        $n = Get-NextAlarm
        $script:OptUi.AlarmNext.Text = if ($n) { 'Next time: {0:dddd dd.MM HH:mm}' -f $n } else { 'Off' }
    }
    & $script:OptAlarmNext

    # ---- 2.9.0: Shortcuts
    $page = & $newPage 'Shortcuts'
    & $header 'Hotkeys (work also when NRK Browser is in the background)' 18
    $ui.HkOn = & $check 'Use these hotkeys' ([bool]$st.Hotkeys) 26 56
    $ui.HkOn.Add_CheckedChanged({ & $script:OptSaveFlag 'Hotkeys' $this.Checked; Register-AppHotkeys; & $script:OptHkNote })
    $mkKeyRow = {
        param([string] $Setting, $Defaults, [string] $Action, [string] $Label, [int] $Y)
        $l = New-Object System.Windows.Forms.Label; $l.Text = $Label; $l.AutoSize = $true
        [void](& $add $l 26 ($Y + 4))
        $tb = New-Object System.Windows.Forms.TextBox; $tb.Width = 200; $tb.ReadOnly = $true; $tb.BackColor = $T.Surface; $tb.ForeColor = $T.Text; $tb.BorderStyle = 'FixedSingle'
        $tb.Text = (Get-KeyMapSetting $Setting $Defaults)[$Action]; $tb.Tag = @{ Setting = $Setting; Defaults = $Defaults; Action = $Action }
        [void](& $add $tb 240 $Y)
        $tb.Add_KeyDown({
            param($s, $e)
            $e.SuppressKeyPress = $true; $e.Handled = $true
            $txt = if ($e.KeyCode -in 'Back', 'Delete' -and -not ($e.Control -or $e.Alt -or $e.Shift)) { '' } else { ConvertTo-KeyText $e.KeyData }
            if ($txt -eq '' -and $e.KeyCode -notin 'Back', 'Delete') { return }   # (Ctrl / Alt / Shift alone: wait for the key)
            if ($txt -and $txt -notmatch '\+' -and $this.Tag.Setting -eq 'HotkeyMap' -and $txt -notmatch '^(F\d+|Media\w+|Volume\w+)$') { return }   # (a hotkey needs Ctrl / Alt / Shift)
            $this.Text = $txt
            $m = Get-KeyMapSetting $this.Tag.Setting $this.Tag.Defaults; $m[$this.Tag.Action] = $txt
            $s2 = Get-AppSettings; $s2.($this.Tag.Setting) = ($m | ConvertTo-Json -Compress); Save-AppSettings $s2
            if ($this.Tag.Setting -eq 'HotkeyMap') { Register-AppHotkeys; & $script:OptHkNote }
        })
        $tb
    }
    $y = 90
    foreach ($a in $script:AppActions.Keys) { [void](& $mkKeyRow 'HotkeyMap' $script:HotkeyDefaults $a $script:AppActions[$a] $y); $y += 32 }
    $ui.HkNote = & $muted '' 26 ($y + 2) 600 36
    $script:OptHkNote = { $script:OptUi.HkNote.Text = if (@($script:HotkeyFailed).Count) { 'Taken by another app: ' + ($script:HotkeyFailed -join ', ') } else { 'Click a box and press the keys; Backspace = none. Media keys on the keyboard work as before.' } }
    & $script:OptHkNote
    $y += 48
    & $header 'In the main window' $y
    $y += 42
    foreach ($a in $script:KeyActions.Keys) { [void](& $mkKeyRow 'KeyMap' $script:KeyDefaults $a $script:KeyActions[$a] $y); $y += 32 }
    $bKeyReset = New-FlatButton 'Back to the defaults' 180; [void](& $add $bKeyReset 24 ($y + 8))
    $bKeyReset.Add_Click({ $s = Get-AppSettings; $s.HotkeyMap = ''; $s.KeyMap = ''; Save-AppSettings $s; Register-AppHotkeys; [void][System.Windows.Forms.MessageBox]::Show($script:OptUi.Form, 'The default shortcuts are back (open Options again to see them).', 'Shortcuts', 'OK', 'Information') })
    $y += 64
    & $header 'Taskbar' $y
    $ui.Tb = & $check 'Previous / Play / Next under the taskbar preview, and recent channels when you right-click the taskbar button (after a restart)' ([bool]$st.TaskbarButtons) 26 ($y + 42)
    $ui.Tb.Add_CheckedChanged({ & $script:OptSaveFlag 'TaskbarButtons' $this.Checked })
    [void](& $muted '' 26 ($y + 100) 10 10)

    # ---- 2.9.0: Phone remote
    $page = & $newPage 'Phone remote'
    & $header 'Phone remote' 18
    $ui.RemOn = & $check 'Control NRK Browser from a phone on the same network' ([bool]$st.RemoteOn) 26 60
    $ui.RemUrls = New-Object System.Windows.Forms.TextBox; $ui.RemUrls.Multiline = $true; $ui.RemUrls.ReadOnly = $true; $ui.RemUrls.Width = 600; $ui.RemUrls.Height = 70
    $ui.RemUrls.BackColor = $T.Surface; $ui.RemUrls.ForeColor = $T.Text; $ui.RemUrls.BorderStyle = 'FixedSingle'
    [void](& $add $ui.RemUrls 26 100)
    $bRemCopy = New-FlatButton 'Copy the address' 160; [void](& $add $bRemCopy 24 182)
    $bRemKey = New-FlatButton 'New key' 110; [void](& $add $bRemKey 194 182)
    [void](& $muted 'Open the address in the phone''s browser (the key in it is the password: only share it with people in your home). Only devices on your home network get in. The first time, Windows may ask whether PowerShell may use the network: allow it on private networks.' 26 228 600 74)
    $script:OptRemShow = {
        $u = $script:OptUi
        $u.RemUrls.Text = if ($script:Remote) { (Get-RemoteUrls) -join "`r`n" } else { '(off)' }
    }
    $ui.RemOn.Add_CheckedChanged({
        & $script:OptSaveFlag 'RemoteOn' $this.Checked
        if ($this.Checked) { if (-not (Start-PhoneRemote)) { [void][System.Windows.Forms.MessageBox]::Show($script:OptUi.Form, 'The phone remote could not start (see Logs).', 'Phone remote', 'OK', 'Warning') } } else { Stop-PhoneRemote }
        & $script:OptRemShow
    })
    $bRemCopy.Add_Click({ $u = @(Get-RemoteUrls); if ($u.Count) { [System.Windows.Forms.Clipboard]::SetText($u[0]); Set-Status 'Phone remote address copied' } })
    $bRemKey.Add_Click({ $s = Get-AppSettings; $s.RemoteKey = ''; Save-AppSettings $s; $on = [bool]$script:Remote; Stop-PhoneRemote; if ($on) { [void](Start-PhoneRemote) } else { $s = Get-AppSettings; $s.RemoteKey = -join ((1..16) | ForEach-Object { 'abcdefghijkmnpqrstuvwxyz23456789'[(Get-Random -Maximum 32)] }); Save-AppSettings $s }; & $script:OptRemShow })
    & $script:OptRemShow

    # ---- About
    $page = & $newPage 'About'
    $lblName = New-Object System.Windows.Forms.Label; $lblName.Text = 'NRK Browser'; $lblName.Font = New-Object System.Drawing.Font($script:FontUi.FontFamily, 18, [System.Drawing.FontStyle]::Bold); $lblName.AutoSize = $true
    [void](& $add $lblName 24 18)
    [void](& $muted ("Version {0}  ·  PowerShell {1}  ·  {2}" -f $script:AppVersion, $PSVersionTable.PSVersion, $(if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' })) 26 60)
    [void](& $muted 'Browse, watch, listen to and download NRK TV and NRK Radio from one Windows app: folders for every category and series, a built-in video player and radio bar, search, favourites, and a download queue with subtitles, chapters and covers.' 26 92 600 56)
    & $header 'Project' 160
    $lnk = New-Object System.Windows.Forms.LinkLabel
    $lnk.Text = "github.com/$($script:UpdateRepo)"; $lnk.AutoSize = $true
    $lnk.LinkColor = $T.Accent; $lnk.ActiveLinkColor = $T.AccentHover; $lnk.VisitedLinkColor = $T.Accent
    [void](& $add $lnk 26 202)
    $lnk.Add_LinkClicked({ Start-Process "https://github.com/$($script:UpdateRepo)" })
    [void](& $muted 'Source, new versions and the README. Updates are installed from here (Options > Updates).' 26 228)
    $bIssues = New-FlatButton 'Report a problem' 170
    [void](& $add $bIssues 24 258)
    $bIssues.Add_Click({ Start-Process "https://github.com/$($script:UpdateRepo)/issues" })
    $optTips.SetToolTip($bIssues, 'Opens the issue list on GitHub. Attach the log (Logs > Copy all) if you can.')
    & $header 'Not affiliated with NRK' 316
    [void](& $muted 'Unofficial. Not made, endorsed or supported by NRK (Norsk rikskringkasting AS). All programmes, images and trademarks belong to NRK. Downloads are for personal use; some content is only available in Norway.' 26 356 600 56)
    & $header 'Built with' 426
    [void](& $muted 'NRK''s public programme data (psapi.nrk.no)  ·  Microsoft Edge WebView2  ·  hls.js (Apache-2.0)  ·  FFmpeg' 26 466 600 36)
    $bStatsA = New-FlatButton 'Statistics...' 130; [void](& $add $bStatsA 24 510)
    $bStatsA.Add_Click({ Show-StatsWindow })

    # Close, under the pages
    $foot = New-Object System.Windows.Forms.Panel
    $foot.Dock = 'Bottom'; $foot.Height = 56; $foot.BackColor = $T.Bg
    $bClose = New-FlatButton 'Close' 100 -Primary
    $bClose.DialogResult = 'OK'
    $bClose.Location = New-Object System.Drawing.Point(540, 10)
    $foot.Controls.Add($bClose)
    $pageHost.Controls.Add($foot)
    & $script:OptShowPage 'General'
    $w.CancelButton = $bClose

    $script:OptRefreshInstall = {
        $u = $script:OptUi
        $i = Get-InstallInfo
        $u.InstallInfo.Text = if ($i.Running) { "Installed in $($i.Dir), and this is the installed copy." }
            elseif ($i.Installed) { "Installed in $($i.Dir) (version $($i.Version)). You are running a different copy:`n$PSCommandPath" }
            else { "Not installed. Running from:`n$PSCommandPath`nInstall copies it to $($i.Dir) and adds shortcuts." }
        $u.Install.Text = if ($i.Installed) { 'Update shortcuts' } else { 'Install' }
        if ($i.Installed -and -not $i.Running) { $u.Install.Text = 'Install this copy' }
        $u.Uninstall.Enabled = ($i.Installed -or (Test-Path -LiteralPath $i.StartMenu) -or (Test-Path -LiteralPath $i.Desktop) -or (Test-Path -LiteralPath $i.Startup))
    }
    & $script:OptRefreshInstall

    # ---- events
    $cbTheme.Add_SelectedIndexChanged({
        $mode = @('System', 'Light', 'Dark')[$args[0].SelectedIndex]
        if ($mode -eq $script:ThemeMode) { return }
        Write-Log INFO "UI: theme setting changed to $mode"
        $s = Get-AppSettings; $s.Theme = $mode; Save-AppSettings $s
        Set-AppTheme $mode -Force
    })
    $ui.Sort.Add_SelectedIndexChanged({
        $k = @('desc', 'asc', 'nrk')[$this.SelectedIndex]
        if ($k -eq $script:SortOrder) { return }
        $script:SortOrder = $k
        $s = Get-AppSettings; $s.SortOrder = $k; Save-AppSettings $s
        Write-Log INFO "Option SortOrder = $k"
        Update-TreeSort
    })
    $saveFlag = {
        param([string] $Name, [bool] $Value)
        $s = Get-AppSettings; $s.$Name = $Value; Save-AppSettings $s
        Write-Log INFO "Option $Name = $Value"
    }
    $script:OptSaveFlag = $saveFlag
    $ui.Tray.Add_CheckedChanged({ & $script:OptSaveFlag 'TrayIcon' $this.Checked; Update-TrayVisibility })
    $ui.OnePlayer.Add_CheckedChanged({ & $script:OptSaveFlag 'OnePlayer' $this.Checked })
    $ui.Resume.Add_CheckedChanged({ & $script:OptSaveFlag 'ResumePlayback' $this.Checked })
    $ui.WebPlayer.Add_CheckedChanged({ $s = Get-AppSettings; $s.VideoPlayer = $(if ($this.Checked) { 'web' } else { 'builtin' }); Save-AppSettings $s; Write-Log INFO "Option VideoPlayer = $($s.VideoPlayer)" })
    $ui.MinTray.Add_CheckedChanged({ & $script:OptSaveFlag 'MinimizeToTray' $this.Checked })
    $ui.CloseTray.Add_CheckedChanged({ & $script:OptSaveFlag 'CloseToTray' $this.Checked })
    $ui.Startup.Add_CheckedChanged({
        try { Set-StartWithWindows $this.Checked; & $script:OptSaveFlag 'StartWithWindows' $this.Checked }
        catch { Write-LogException $_ 'Start with Windows'; [void][System.Windows.Forms.MessageBox]::Show($script:OptUi.Form, "Could not change the startup shortcut:`n$($_.Exception.Message)", 'Start with Windows', 'OK', 'Error') }
        & $script:OptRefreshInstall
    })
    $ui.StartMenu.Add_CheckedChanged({ & $script:OptSaveFlag 'StartMenuShortcut' $this.Checked })
    $ui.Desktop.Add_CheckedChanged({ & $script:OptSaveFlag 'DesktopShortcut' $this.Checked })
    $ui.AutoUpd.Add_CheckedChanged({ & $script:OptSaveFlag 'CheckUpdates' $this.Checked })
    $ui.Install.Add_Click({
        $u = $script:OptUi
        try {
            Install-App -StartMenu $u.StartMenu.Checked -Desktop $u.Desktop.Checked
        } catch {
            Write-LogException $_ 'Install'
            [void][System.Windows.Forms.MessageBox]::Show($u.Form, "Install failed:`n$($_.Exception.Message)", 'Install', 'OK', 'Error'); return
        }
        & $script:OptRefreshInstall
        $i = Get-InstallInfo
        $where = @($(if ($u.StartMenu.Checked) { 'Start menu' }), $(if ($u.Desktop.Checked) { 'desktop' })) | Where-Object { $_ }
        $msg = "NRK Browser is installed in`n$($i.Dir)" + $(if ($where) { "`n`nShortcuts: $($where -join ' and ')." } else { '' })
        if (-not $i.Running) {
            $q = [System.Windows.Forms.MessageBox]::Show($u.Form, "$msg`n`nSwitch to the installed copy now? (This window closes and the installed copy starts.)", 'Installed', 'YesNo', 'Information')
            if ($q -eq 'Yes') { $u.Form.Close(); Start-AppDetached -ScriptPath $i.Script; Exit-App }
        } else { [void][System.Windows.Forms.MessageBox]::Show($u.Form, $msg, 'Installed', 'OK', 'Information') }
    })
    $ui.Uninstall.Add_Click({
        $u = $script:OptUi
        $q = [System.Windows.Forms.MessageBox]::Show($u.Form, "Remove the installed copy and the Start menu, desktop and startup shortcuts?`n`nSettings, downloaded components and your downloads are kept.", 'Uninstall', 'YesNo', 'Question')
        if ($q -ne 'Yes') { return }
        try { Uninstall-App } catch { Write-LogException $_ 'Uninstall'; [void][System.Windows.Forms.MessageBox]::Show($u.Form, "Uninstall failed:`n$($_.Exception.Message)", 'Uninstall', 'OK', 'Error') }
        $u.Startup.Checked = $false
        & $script:OptRefreshInstall
    })
    $bLocal.Add_Click({ New-Item -ItemType Directory -Path $script:AppDataDir -Force | Out-Null; Write-Log INFO "UI: view local files $($script:AppDataDir)"; Start-Process $script:AppDataDir })
    $bCheck.Add_Click({ Start-UpdateCheck -Manual })
    $ui.CacheMode.Add_SelectedIndexChanged({
        $k = @($script:CacheModes.Keys)[$this.SelectedIndex]
        if ($k -eq $script:CacheMode) { return }
        $script:CacheMode = $k
        $s = Get-AppSettings; $s.CacheRefresh = $k; Save-AppSettings $s
        Write-Log INFO "Option CacheRefresh = $k"
    })
    $ui.ClearCache.Add_Click({
        Clear-AppCache
        $script:OptUi.ClearCache.Text = 'Clear saved NRK data (0 MB)'
        Set-Status 'Cache cleared - pages are fetched from NRK again as you open them'
    })
    $bComponents.Add_Click({
        Write-Log INFO 'UI: opened Components window from Options'
        $f = $script:OptUi.Form
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try { $status = Get-DependencyStatus } finally { $f.Cursor = [System.Windows.Forms.Cursors]::Default }
        [void](Show-DependencyDialog -Status $status -Owner $f -IncludeSkipped)
    })

    Enable-DarkTitleBar $w
    [void]$w.ShowDialog($form)
    try { & $script:OptSaveDlDir } catch { }
    $script:OptUi = $null
    $w.Dispose()
}

# ---- events -------------------------------------------------------------------------

$crumb.Add_Resize({ Update-Crumb })

$folderTree.Add_BeforeExpand({
    param($s, $e)
    $n = $e.Node
    if ($n.Tag.Kind -in 'category', 'letter', 'series', 'radiocategory', 'radioletter', 'radioseries' -and -not $n.Tag.Loaded) {
        [void](Expand-FolderNode $n)
    }
})
$folderTree.Add_HandleCreated({ Enable-DarkScrollbars $args[0] })

$itemsList.Add_SelectedIndexChanged({
    $n = $itemsList.SelectedItems.Count
    if ($n -eq 0) { return }
    if ($n -gt 1) {
        # several files: keep the details of the first one, don't reload on every Shift+click step
        Set-Status ('{0} files selected  ·  right-click or Download to add them to the download queue' -f $n)
        Update-Actions
        return
    }
    Show-FileDetails $itemsList.SelectedItems[0].Tag
})
$itemsList.Add_MouseUp({
    param($s, $e)
    if ($e.Button -ne 'Right') { return }
    $hit = $itemsList.GetItemAt($e.X, $e.Y)
    if (-not $hit) {
        # empty space: just the view switch
        if (-not $script:ViewMenu) {
            $script:ViewMenu = New-ThemedMenu
            $vi = New-ThemedMenuItem 'Show as a list    (Ctrl+G)'
            $vi.Add_Click({ Set-FilesView $(if (Test-GridView) { 'list' } else { 'grid' }) })
            [void]$script:ViewMenu.Items.Add($vi)
        }
        $script:ViewMenu.Items[0].Text = if (Test-GridView) { 'Show as a list    (Ctrl+G)' } else { 'Show as thumbnails    (Ctrl+G)' }
        if ($script:DarkRenderer) { $script:ViewMenu.Renderer = $script:DarkRenderer }
        $script:ViewMenu.BackColor = $T.Surface; $script:ViewMenu.Items[0].ForeColor = $T.Text
        $script:ViewMenu.Show($itemsList, $e.Location)
        return
    }
    if (-not $hit.Selected) { $itemsList.SelectedItems.Clear(); $hit.Selected = $true; $hit.Focused = $true }
    $sel = Get-SelectedFiles
    $dl = @($sel | Where-Object { $_.Downloadable })
    $miFPlay.Enabled = ($sel.Count -eq 1 -and $sel[0].Playable)
    $miFPlay.Text = if ($sel.Count -eq 1 -and $sel[0].Type -in 'radiolive', 'audio') { 'Listen' } else { 'Play' }
    $miFDownload.Text = if ($dl.Count -gt 1) { 'Download ({0} files)' -f $dl.Count } else { 'Download' }
    $miFDownload.Enabled = ($dl.Count -gt 0)
    $miFWeb.Enabled = ($sel.Count -eq 1 -and [bool]$sel[0].WebUrl)
    $miFCopy.Enabled = $miFWeb.Enabled
    $hideable = @($sel | Where-Object { $_.Id -and $_.Type -ne 'more' })
    $miFHide.Enabled = ($hideable.Count -gt 0)
    $fref = if ($sel.Count -eq 1) { Get-SeriesRef $sel[0] } else { $null }
    $script:FilesMenuRef = $fref
    $miFFav.Visible = [bool]$fref
    $aud = @($sel | Where-Object { $_.Type -eq 'audio' -and $_.Playable })
    $miFPlayNext.Visible = [bool]$aud.Count; $miFQueue.Visible = [bool]$aud.Count
    $miFQueue.Text = if ($aud.Count -gt 1) { "Add $($aud.Count) to the queue" } else { 'Add to queue' }
    $qn = if ($script:AudioUi.UserQueue) { $script:AudioUi.UserQueue.Count } else { 0 }
    $miFQueueClear.Visible = ($aud.Count -and $qn -gt 0); $miFQueueClear.Text = "Clear the radio queue ($qn)"
    $miFView.Text = if (Test-GridView) { 'Show as a list    (Ctrl+G)' } else { 'Show as thumbnails    (Ctrl+G)' }
    $posable = @($sel | Where-Object { Test-PosFile $_ })
    $miFWatched.Visible = [bool]@($posable | Where-Object { -not (Test-Watched $_) }).Count
    $laterAll = ($posable.Count -and @($posable | Where-Object { -not (Test-WatchLater $_) }).Count -eq 0)
    $miFLater.Visible = [bool]$posable.Count
    $miFLater.Text = if ($laterAll) { 'Remove from Watch later' } else { 'Watch later' }
    $miFRecord.Visible = ($sel.Count -eq 1 -and $sel[0].Type -in 'live', 'radiolive')
    $miFUnwatched.Visible = [bool]@($posable | Where-Object { Get-PlayRecord $_ }).Count
    $miFFav.Text = if ($fref -and (Test-Favourite $fref.Key)) { 'Remove the series from favourites' } else { 'Add the series to favourites' }
    $miFHide.Text = if ($hideable.Count -gt 1) { "Hide {0} files (don't show or index)" -f $hideable.Count } else { "Hide (don't show or index)" }
    $filesMenu.Show($itemsList, $e.Location)
})
$miFPlay.Add_Click({ Start-Player })
$miFDownload.Add_Click({ Add-ToDownloadQueue -Files @(Get-SelectedFiles | Where-Object { $_.Downloadable }) })
$miFWeb.Add_Click({ $f = @(Get-SelectedFiles)[0]; if ($f.WebUrl) { Start-Process $f.WebUrl } })
$miFHide.Add_Click({ Add-Excluded -Files @(Get-SelectedFiles) })
$miFWatched.Add_Click({ Set-Watched @(Get-SelectedFiles) $true })
$miFLater.Add_Click({ $sel = @(Get-SelectedFiles | Where-Object { Test-PosFile $_ }); Set-WatchLater $sel (-not ($sel.Count -and @($sel | Where-Object { -not (Test-WatchLater $_) }).Count -eq 0)) })
$miFRecord.Add_Click({ $sel = @(Get-SelectedFiles); if ($sel.Count -eq 1) { Show-RecordDialog $sel[0] } })
$miFView.Add_Click({ Set-FilesView $(if (Test-GridView) { 'list' } else { 'grid' }) })
$miFPlayNext.Add_Click({ Add-AudioQueue @(Get-SelectedFiles) -Next })
$miFQueue.Add_Click({ Add-AudioQueue @(Get-SelectedFiles) })
$miFQueueClear.Add_Click({ Clear-AudioQueue })
$miFUnwatched.Add_Click({ Set-Watched @(Get-SelectedFiles) $false })
$miFFav.Add_Click({ $r = $script:FilesMenuRef; if (-not $r) { return }; if (Test-Favourite $r.Key) { Remove-Favourite $r.Key } else { Add-Favourite $r } })
$miFCopy.Add_Click({ $f = @(Get-SelectedFiles)[0]; if ($f.WebUrl) { [System.Windows.Forms.Clipboard]::SetText($f.WebUrl); Set-Status "Copied $($f.WebUrl)" } })

# ---- folder tree: Shift/Ctrl+click selects several folders (a TreeView can't do that itself)
$script:TreeMulti = New-Object System.Collections.ArrayList
$script:TreeAnchor = $null
$script:TreeMenuNodes = @()
function Clear-TreeMulti {
    foreach ($n in @($script:TreeMulti)) { $n.BackColor = [System.Drawing.Color]::Empty; $n.ForeColor = [System.Drawing.Color]::Empty }
    $script:TreeMulti.Clear()
}
function Add-TreeMulti($Node) {
    if (-not $Node -or $script:TreeMulti.Contains($Node)) { return }
    [void]$script:TreeMulti.Add($Node); $Node.BackColor = $T.Sel; $Node.ForeColor = $T.Text
}
function Select-TreeRange($From, $To) {
    # every visible node between two nodes, inclusive
    $vis = New-Object System.Collections.ArrayList
    for ($n = $folderTree.Nodes[0]; $n; $n = $n.NextVisibleNode) { [void]$vis.Add($n) }
    $a = $vis.IndexOf($From); $b = $vis.IndexOf($To)
    if ($a -lt 0) { $a = $b }
    Clear-TreeMulti
    for ($i = [Math]::Min($a, $b); $i -le [Math]::Max($a, $b); $i++) { Add-TreeMulti $vis[$i] }
}
$folderTree.Add_BeforeSelect({
    param($s, $e)
    $mk = [System.Windows.Forms.Control]::ModifierKeys
    if ($e.Action -eq 'ByMouse' -and (($mk -band [System.Windows.Forms.Keys]::Shift) -or ($mk -band [System.Windows.Forms.Keys]::Control))) { $e.Cancel = $true }
})
$folderTree.Add_NodeMouseClick({
    param($s, $e)
    $mk = [System.Windows.Forms.Control]::ModifierKeys
    $shift = [bool]($mk -band [System.Windows.Forms.Keys]::Shift)
    $ctrl = [bool]($mk -band [System.Windows.Forms.Keys]::Control)
    if ($e.Button -eq 'Left') {
        if ($shift) {
            $anchor = if ($script:TreeAnchor -and $script:TreeAnchor.TreeView) { $script:TreeAnchor } else { $folderTree.SelectedNode }
            Select-TreeRange $anchor $e.Node
        } elseif ($ctrl) {
            if ($script:TreeMulti.Count -eq 0 -and $folderTree.SelectedNode) { Add-TreeMulti $folderTree.SelectedNode }
            if ($script:TreeMulti.Contains($e.Node)) { [void]$script:TreeMulti.Remove($e.Node); $e.Node.BackColor = [System.Drawing.Color]::Empty; $e.Node.ForeColor = [System.Drawing.Color]::Empty }
            else { Add-TreeMulti $e.Node }
            $script:TreeAnchor = $e.Node
        }
        if ($shift -or $ctrl) {
            $n = $script:TreeMulti.Count
            Set-Status ('{0} folders selected  ·  right-click to download them' -f $n)
        }
        return
    }
    if ($e.Button -eq 'Right') {
        $nodes = if ($script:TreeMulti.Count -gt 0 -and $script:TreeMulti.Contains($e.Node)) { @($script:TreeMulti) } else { Clear-TreeMulti; @($e.Node) }
        $script:TreeMenuNodes = $nodes
        $ok = @($nodes | Where-Object { Test-NodeDownloadable $_ })
        $miTDownload.Enabled = ($ok.Count -gt 0)
        $miTDownload.Text = if ($ok.Count -gt 1) { 'Download ({0} folders)' -f $ok.Count }
                            elseif ($ok.Count -eq 1 -and $ok[0].Tag.Kind -in 'category', 'letter', 'radiocategory', 'radioletter') { 'Download the programmes listed here' }
                            elseif ($ok.Count -eq 1) { 'Download all episodes' }
                            else { 'Download (nothing to download here)' }
        $miTOpen.Visible = ($nodes.Count -eq 1)
        $ref = if ($nodes.Count -eq 1) { Get-SeriesRef $nodes[0] } else { $null }
        $script:TreeMenuRef = $ref
        $miTFav.Visible = [bool]$ref
        $isFav = [bool]($ref -and (Test-Favourite $ref.Key))
        $miTFav.Text = if ($isFav) { 'Remove from favourites' } else { 'Add to favourites' }
        $miTFollow.Visible = $isFav; $miTFollowNotify.Visible = $isFav
        $miTOpml.Visible = ($nodes.Count -eq 1 -and $nodes[0].Tag.Kind -eq 'favourites')
        $miTCheckFollow.Visible = ($nodes.Count -eq 1 -and $nodes[0].Tag.Kind -eq 'favourites' -and [bool]@((Get-FavMap).Values | Where-Object { $_.Follow }).Count)
        $feedItem = if ($nodes.Count -eq 1 -and $nodes[0].Tag.Kind -eq 'radioseries') { $nodes[0].Tag.Item } else { $null }
        $script:TreeMenuFeed = Get-PodcastFeedUrl $feedItem
        $miTFeed.Visible = [bool]$script:TreeMenuFeed
        $frec = if ($isFav) { (Get-FavMap)[$ref.Key] } else { $null }
        $miTFollow.Checked = [bool]($frec -and $frec.Follow -and [string]$frec.FollowMode -ne 'notify')
        $miTFollowNotify.Checked = [bool]($frec -and $frec.Follow -and [string]$frec.FollowMode -eq 'notify')
        $miTClearRecent.Visible = ($nodes.Count -eq 1 -and $nodes[0].Tag.Kind -eq 'recent')
        $miTCloseSearch.Visible = ($nodes.Count -eq 1 -and $nodes[0].Tag.Kind -eq 'search')
        $hideNodes = @($nodes | Where-Object { $_.Tag.Kind -in 'category', 'letter', 'radiocategory', 'radioletter', 'series', 'season', 'radioseries', 'radioseason' })
        $miTHide.Visible = ($hideNodes.Count -gt 0)
        $miTHide.Text = if ($hideNodes.Count -gt 1) { "Hide {0} folders (don't show or index)" -f $hideNodes.Count } else { "Hide (don't show or index)" }
        $treeMenu.Show($folderTree, $e.Location)
    }
})
$miTOpen.Add_Click({ $n = @($script:TreeMenuNodes)[0]; if ($n) { $folderTree.SelectedNode = $n } })
$miTFav.Add_Click({ $r = $script:TreeMenuRef; if (-not $r) { return }; if (Test-Favourite $r.Key) { Remove-Favourite $r.Key } else { Add-Favourite $r } })
$miTFollow.Add_Click({ $r = $script:TreeMenuRef; if ($r) { $x = (Get-FavMap)[$r.Key]; $on = -not ($x.Follow -and [string]$x.FollowMode -ne 'notify'); Set-FollowSeries $r.Key $on -Mode 'download' } })
$miTFollowNotify.Add_Click({ $r = $script:TreeMenuRef; if ($r) { $x = (Get-FavMap)[$r.Key]; $on = -not ($x.Follow -and [string]$x.FollowMode -eq 'notify'); Set-FollowSeries $r.Key $on -Mode 'notify' } })
$miTOpml.Add_Click({ Export-PodcastOpml })
$miTCheckFollow.Add_Click({ Invoke-Ui 'Checking followed series' { Invoke-FollowCheck }; Set-Status 'Followed series checked' })
$miTFeed.Add_Click({ if ($script:TreeMenuFeed) { [System.Windows.Forms.Clipboard]::SetText($script:TreeMenuFeed); Set-Status "Copied $($script:TreeMenuFeed)  ·  paste it into a podcast app" } })
$miTDownload.Add_Click({ Add-ToDownloadQueue -Nodes @($script:TreeMenuNodes) })
$miTHide.Add_Click({ Add-Excluded -Nodes @($script:TreeMenuNodes | Where-Object { $_.Tag.Kind -in 'category', 'letter', 'radiocategory', 'radioletter', 'series', 'season', 'radioseries', 'radioseason' }) })
$miTClearRecent.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show($form, 'Clear the list of recently played programmes?', 'Recently played', 'YesNo', 'Question') -eq 'Yes') { Clear-RecentPlayed }
})
$miTCloseSearch.Add_Click({
    $n = $script:SearchNode
    if (-not $n) { return }
    if ($folderTree.SelectedNode -and ($folderTree.SelectedNode -eq $n -or $folderTree.SelectedNode.FullPath.StartsWith($n.FullPath))) { $folderTree.SelectedNode = $script:RecentNode }
    $n.Remove(); $script:SearchNode = $null
})
$folderTree.Add_AfterSelect({
    param($s, $e)
    if ($script:SuppressSelect) { return }
    Clear-TreeMulti
    $script:TreeAnchor = $e.Node
    Open-Folder $e.Node
})
$itemsList.Add_DoubleClick({
    if ($script:SelectedFile -and $script:SelectedFile.Type -eq 'more') { Invoke-LoadMore $script:SelectedFile; return }
    if ($script:SelectedFile -and $script:SelectedFile.Playable) { Start-Player }
})

$scheduleList.Add_SelectedIndexChanged({
    if ($scheduleList.SelectedItems.Count -eq 0 -or -not $script:SelectedFile) { return }
    # schedule entry: show it, but Play keeps meaning "watch live"
    $e = $scheduleList.SelectedItems[0].Tag
    $pTitle.Text = $e.Title
    $pMeta.Text = '{0}   ·   {1:HH:mm} - {2:HH:mm}{3}' -f $script:SelectedFile.Title, $e.Start, $e.End, $(if ($e.HasRights -and $e.End -le (Get-Date)) { '   ·   double-click to {0} from the start' -f $(if ($script:SelectedFile.Medium -eq 'radio') { 'listen' } else { 'watch' }) } else { '' })
    $pDesc.Text = $e.Description
    if ($e.ImageUrl) { $pic.Image = Get-NrkImage $e.ImageUrl }
})
$scheduleList.Add_DoubleClick({
    if ($scheduleList.SelectedItems.Count -eq 0) { return }
    $e = $scheduleList.SelectedItems[0].Tag
    if ($e.ProgramId -and $e.HasRights -and $e.End -le (Get-Date)) {
        if ($script:SelectedFile -and $script:SelectedFile.Medium -eq 'radio') {
            # a finished radio programme: play the recording in the audio bar
            $rec = New-NrkRadioItem -Type 'audio' -Kind 'series' -Id $e.ProgramId -Title $e.Title -Description $e.Description -ImageUrl $e.ImageUrl `
                -WebUrl ('https://radio.nrk.no/program/{0}' -f $e.ProgramId) -ManifestPath ('/playback/manifest/program/{0}' -f $e.ProgramId) -SeriesTitle $script:SelectedFile.Title
            Start-Player -Target ([pscustomobject]@{ Url = $rec.WebUrl; Title = $e.Title; Audio = $rec })
            return
        }
        # a finished TV programme: as a programme, so it plays in the built-in player (continues where you stopped)
        $prog = New-NrkItem -Type 'program' -Id $e.ProgramId -Title $e.Title -Description $e.Description -ImageUrl $e.ImageUrl -Section $script:SelectedFile.Title
        Start-Player -Target (New-VideoTarget $prog)
    } else { Start-Player }   # on now / upcoming: watch the channel live
})

$search.Add_TextChanged({ Show-Files })
$search.Add_HandleCreated({ try { [NrkNative]::Placeholder($search.Handle, 'Filter files  ·  Enter: search everything') } catch { } })
$search.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Return') { $e.Handled = $true; $e.SuppressKeyPress = $true; Invoke-SearchAll $search.Text }
    elseif ($e.KeyCode -eq 'Escape' -and $search.Text) { $e.Handled = $true; $e.SuppressKeyPress = $true; $search.Text = '' }
})
$topTips.SetToolTip($search, 'Type to filter the files in this folder. Press Enter to search all of NRK TV and radio (needs the Indexer).')

$btnReload.Add_Click({
    Write-Log INFO 'UI: reload requested - fetching fresh data from NRK (the saved copies are updated too)'
    $script:Cache = @{}; $script:CacheAt = @{}
    $script:EmptyNow.Clear()                 # look again at folders that were empty
    $script:ImageFailed = @{}
    $script:CacheBypassUntil = (Get-Date).AddMinutes(3)
    $script:Files = @(); $script:SelectedFile = $null
    Show-Files
    Initialize-Tree
    Show-FolderPreview; Update-Actions; Update-Crumb
})
$btnBack.Add_Click({ Invoke-Back })
$btnSettings.Add_Click({ Show-OptionsWindow })
$btnFilter.Add_Click({ Show-SearchFilterMenu })
$btnLogs.Add_Click({ Show-LogsWindow })
$btnIndexer.Add_Click({ Open-IndexerWindow })
$btnDownloads.Add_Click({ Show-DownloadsWindow })

$btnPlay.Add_Click({ Start-Player })
$btnCast.Add_Click({ Show-CastMenu $btnCast $(if (Test-CastableFile $script:SelectedFile) { $script:SelectedFile } else { $null }) })
$pic.Add_Click({ if ($btnPlay.Enabled) { Start-Player } })
$btnDownload.Add_Click({
    $f = $script:SelectedFile
    $tagKind = (Get-FolderTag).Kind
    if ((Get-SelectedFiles).Count -gt 1 -or ($f -and $f.Type -in 'program', 'audio') -or (-not $f -and $tagKind -in 'radioseason', 'radioseries')) { Start-DownloadChecked 'auto'; return }
    $isEpisode = [bool]($f -and $f.Type -eq 'episode')
    $season = Get-DownloadUrl -Scope 'season'
    $miDlEpisode.Visible = $isEpisode
    $miDlEpisode.Text = if ($isEpisode) { "This episode ($($f.Title))" } else { 'This episode' }
    $miDlSeason.Enabled = [bool]$season
    $seasonName = if ($isEpisode) { $f.Season } else { (Get-FolderTag).Season }
    $miDlSeason.Text = if ($seasonName) { "This season ($seasonName)" } else { 'This season' }
    $downloadMenu.Show($btnDownload, (New-Object System.Drawing.Point(0, ($btnDownload.Height + 2))))
})
$miDlEpisode.Add_Click({ Start-DownloadChecked 'episode' })
$miDlSeason.Add_Click({ Start-DownloadChecked 'season' })
$miDlSeries.Add_Click({ Start-DownloadChecked 'series' })
$btnOpenWeb.Add_Click({
    $target = Get-PlayTarget
    $u = if ($target -and $target.Url) { $target.Url } else { Get-DownloadUrl -Scope 'auto' }
    if ($u) { Write-Log INFO "UI: open $u"; Start-Process $u }
})
$btnCopyUrl.Add_Click({
    $u = if ($script:SelectedFile -and $script:SelectedFile.Type -eq 'live') { $script:SelectedFile.WebUrl } else { Get-DownloadUrl -Scope 'auto' }
    if ($u) { [System.Windows.Forms.Clipboard]::SetText($u); Set-Status "Copied $u" }
})

$form.Add_KeyDown({
    param($s, $e)
    # the shortcuts can be changed (Options > Shortcuts)
    if (Invoke-AppShortcut $e) { $e.Handled = $true; $e.SuppressKeyPress = $true }
    elseif ($e.KeyCode -eq 'Back' -and -not $search.Focused) { Invoke-Back; $e.Handled = $true }
})

$center.Add_Resize({ Update-ContentLayout })
$pDesc.Add_TextChanged({ Update-ContentLayout })

$form.Add_LocationChanged({ if ($form.WindowState -eq 'Normal') { Update-MaxBounds $form } })

# Follow Windows' light/dark setting while the app runs (only when the theme setting is System)
# Windows says when the setting changes (no polling); if that can't be set up, look every 3 s.
$themeTimer = New-Object System.Windows.Forms.Timer
$themeTimer.Interval = 3000
$themeTimer.Add_Tick({ if ($script:ThemeMode -eq 'System') { Set-AppTheme 'System' } })
function Start-ThemeWatch {
    try {
        if (-not ('NrkThemeWatch' -as [type])) {
            $refs = if ($PSVersionTable.PSEdition -eq 'Desktop') { @('System', 'System.Windows.Forms') }
                    else { [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { -not $_.IsDynamic -and $_.Location -and $_.GetName().Name -match '^(System\.(Windows\.Forms(\.Primitives)?|Runtime|ComponentModel\.Primitives|ComponentModel\.TypeConverter|Private\.CoreLib)|Microsoft\.Win32\.SystemEvents)$' } | ForEach-Object Location }
            Add-Type -ReferencedAssemblies $refs -ErrorAction Stop -TypeDefinition @'
using System;
using System.Windows.Forms;
using Microsoft.Win32;
// Windows' "light/dark" change arrives on its own thread: hand it to the window's thread.
public static class NrkThemeWatch {
    static Control target; static MethodInvoker action;
    public static void Start(Control c, MethodInvoker a) {
        target = c; action = a;
        SystemEvents.UserPreferenceChanged += OnChange;
    }
    public static void Stop() { SystemEvents.UserPreferenceChanged -= OnChange; target = null; }
    static void OnChange(object s, UserPreferenceChangedEventArgs e) {
        if (e.Category != UserPreferenceCategory.General && e.Category != UserPreferenceCategory.Color && e.Category != UserPreferenceCategory.VisualStyle) return;
        var t = target;
        try { if (t != null && t.IsHandleCreated && !t.IsDisposed) t.BeginInvoke(action); } catch { }
    }
}
'@
        }
        [NrkThemeWatch]::Start($form, [System.Windows.Forms.MethodInvoker]{ if ($script:ThemeMode -eq 'System') { try { Set-AppTheme 'System' } catch { } } })
        Write-Log DEBUG 'Theme: following Windows by its change notice'
        return $true
    } catch { Write-Log DEBUG "Theme change notice not available, checking every 3 s: $($_.Exception.Message)"; return $false }
}
$form.Add_Resize({
    if ($form.WindowState -eq 'Minimized') {
        if (-not $script:InTray -and (Get-AppSettings).MinimizeToTray) { Hide-ToTray }
    } else { $script:LastWindowState = $form.WindowState }
})
# a second start of the app asks this one to show itself
$showTimer = New-Object System.Windows.Forms.Timer
$showTimer.Interval = 400
$showTimer.Add_Tick({
    try { if ($script:ShowEvent -and $script:ShowEvent.WaitOne(0)) { Write-Log INFO 'Another start of the app: showing this window'; Show-MainWindow } } catch { }
    Update-InstancePipe
})
$form.Add_Shown({
    Enable-DarkTitleBar $form
    try { Start-LogFlushTimer } catch { }
    try { Start-AssetDownload } catch { Write-LogException $_ 'Assets' }
    try { Set-TopBarIcons } catch { Write-LogException $_ 'Top bar icons' }
    try { Update-SearchFilterButton } catch { }
    if (Test-ChildMode) { $form.Text = "NRK Browser $($script:AppVersion)  ·  Child mode" }
    try { Start-FollowTimer } catch { Write-LogException $_ 'Follow timer' }
    # 2.9.0
    try { Start-StatsTimer } catch { Write-LogException $_ 'Statistics' }
    try { Start-AlarmTimer } catch { Write-LogException $_ 'Wake to radio' }
    try { if (@(Get-Recordings | Where-Object { $_.Status -eq 'Scheduled' }).Count) { Start-RecordTimer } } catch { Write-LogException $_ 'Recordings' }
    try { Register-AppHotkeys } catch { Write-LogException $_ 'Hotkeys' }
    try { if ((Get-AppSettings).TaskbarButtons) { Initialize-Taskbar } } catch { Write-LogException $_ 'Taskbar' }
    try { if ((Get-AppSettings).RemoteOn) { [void](Start-PhoneRemote) } } catch { Write-LogException $_ 'Phone remote' }
    if ($Play) { $script:PlayAtStart = $Play }
    Update-MaxBounds $form
    Set-PaneLayout (Get-AppSettings).Layout
    if (-not (Start-ThemeWatch)) { $themeTimer.Start() }
    Update-Actions
    Initialize-Tree
    Show-FolderPreview
    Start-InstancePipe
    $showTimer.Start()
    Update-TrayVisibility
    if ($Tray) { Hide-ToTray -Quiet }                     # started with Windows
    if ($UpdatedFrom) {
        $msg = "Updated from $UpdatedFrom to $($script:AppVersion)"
        if ($UpdateResult -and (Test-Path -LiteralPath $UpdateResult)) {
            $r = (Get-Content -LiteralPath $UpdateResult -Raw).Trim()
            if ($r -like 'failed|*') { $msg = "The update could not replace the file: $($r.Substring(7))  (details in Logs)" }
        }
        Write-Log INFO $msg; Set-Status $msg
        if ($script:TrayUi -and $script:TrayUi.Icon.Visible) { $script:TrayUi.Icon.ShowBalloonTip(4000, 'NRK Browser', $msg, [System.Windows.Forms.ToolTipIcon]::None) }
    }
    if ($script:StartupNote) { Set-Status $script:StartupNote }
    if (Test-UpdateDue) { Start-UpdateCheck }
    # cache clean-up: once a day, a few minutes after start (it reads every saved file)
    $script:CacheCleanTimer = New-Object System.Windows.Forms.Timer
    $script:CacheCleanTimer.Interval = 180000
    $script:CacheCleanTimer.Add_Tick({
        $script:CacheCleanTimer.Stop()
        try {
            $s = Get-AppSettings
            $last = try { [datetime]$s.LastCacheClean } catch { [datetime]::MinValue }
            if (((Get-Date) - $last).TotalHours -ge 24) {
                $sw = [Diagnostics.Stopwatch]::StartNew(); Optimize-AppCache
                $s = Get-AppSettings; $s.LastCacheClean = (Get-Date).ToString('o'); Save-AppSettings $s
                Write-Log INFO "Cache clean-up took $($sw.ElapsedMilliseconds) ms"
            }
        } catch { Write-Log DEBUG "Cache clean-up: $($_.Exception.Message)" }
    })
    $script:CacheCleanTimer.Start()
    # the indexer by itself (Indexer > "Run by itself"): first look after 90 s, then every 30 min
    $script:IndexAutoTimer = New-Object System.Windows.Forms.Timer
    $script:IndexAutoTimer.Interval = 90000
    $script:IndexAutoTimer.Add_Tick({ $script:IndexAutoTimer.Interval = 1800000; try { Invoke-IndexAuto } catch { Write-LogException $_ 'Indexer (automatic)' } })
    $script:IndexAutoTimer.Start()
    # continue where you left off: shortly after the window is up
    if ((Get-AppSettings).ResumePlayback) {
        $script:ResumeTimer = New-Object System.Windows.Forms.Timer
        $script:ResumeTimer.Interval = 600
        $script:ResumeTimer.Add_Tick({
            $script:ResumeTimer.Stop(); $script:ResumeTimer.Dispose()
            # started with Windows (in the tray): a video waits until you open the app; radio starts
            $lp = $null; try { $lp = (Get-AppSettings).LastPlayed | ConvertFrom-Json } catch { }
            if ($script:InTray -and $lp -and $lp.Player -eq 'video') { $script:ResumePending = $true; Write-Log INFO 'Resume: video waits until the window is opened'; return }
            try { Resume-LastPlayed } catch { Write-LogException $_ 'Resume' }
        })
        $script:ResumeTimer.Start()
    }
    if ($script:PlayAtStart) {
        # 2.9.0: started from the jump list (-Play radio:p1)
        $script:PlayStartTimer = New-Object System.Windows.Forms.Timer; $script:PlayStartTimer.Interval = 1200
        $script:PlayStartTimer.Add_Tick({ $script:PlayStartTimer.Stop(); $script:PlayStartTimer.Dispose(); try { Invoke-PlayCommand $script:PlayAtStart } catch { Write-LogException $_ 'Play at start' } })
        $script:PlayStartTimer.Start()
    }
})
# 2.9.0: right-click a programme in the schedule > Record this programme
$script:SchedMenu = New-ThemedMenu
$miSRecord = New-ThemedMenuItem 'Record this programme'
$miSRecList = New-ThemedMenuItem 'Recordings...'
[void]$script:SchedMenu.Items.AddRange(@($miSRecord, $miSRecList))
$miSRecord.Add_Click({
    $e = if ($scheduleList.SelectedItems.Count) { $scheduleList.SelectedItems[0].Tag } else { $null }
    if (-not $e -or -not $script:SelectedFile) { return }
    # a minute early and three late (NRK is rarely exactly on time)
    $start = $e.Start.AddMinutes(-1); if ($start -lt (Get-Date)) { $start = Get-Date }
    Add-Recording $script:SelectedFile $start $e.End.AddMinutes(3) ([string]$e.Title)
})
$miSRecList.Add_Click({ Show-RecordingsWindow })
$scheduleList.Add_MouseUp({
    param($s, $e)
    if ($e.Button -ne 'Right' -or -not $script:SelectedFile -or $script:SelectedFile.Type -ne 'live') { return }
    $hit = $scheduleList.GetItemAt($e.X, $e.Y)
    if (-not $hit) { return }
    $scheduleList.SelectedItems.Clear(); $hit.Selected = $true
    $miSRecord.Enabled = ($hit.Tag.End -gt (Get-Date))
    if ($script:DarkRenderer) { $script:SchedMenu.Renderer = $script:DarkRenderer }
    $script:SchedMenu.Show($scheduleList, $e.Location)
})
$form.Add_FormClosing({
    param($s, $e)
    # "closing keeps it running in the tray"
    if (-not $script:ReallyExit -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing -and (Get-AppSettings).CloseToTray) {
        $e.Cancel = $true
        Hide-ToTray
    }
})
$form.Add_FormClosing({ param($s, $e); if ($e.Cancel) { return }; try { if ($form.WindowState -eq 'Normal' -or $form.WindowState -eq 'Maximized') { Save-PaneLayout } } catch { } })
$form.Add_FormClosing({
    param($s, $e)
    if ($e.Cancel) { $script:ReallyExit = $false; return }
    if ($script:DlRun.Fetch) { Stop-CurrentDownload 'exit'; return }   # in pieces: just paused, it continues next time
    if ($script:DlRun.Finishing -and $script:DlRun.FinishProc) {
        # the download is done, only the finishing pass runs: stopping it keeps the plain file
        $quiet = $script:ForceExit -or $e.CloseReason -in [System.Windows.Forms.CloseReason]::WindowsShutDown, [System.Windows.Forms.CloseReason]::TaskManagerClosing
        if (-not $quiet) {
            $q = [System.Windows.Forms.MessageBox]::Show($form, "A download is being finished (subtitles, chapters, cover):`n`n$($script:DlRun.Finishing.Title)`n`nExit anyway? The file is kept, but without those.", 'Download being finished', 'YesNo', 'Warning')
            if ($q -ne 'Yes') { $e.Cancel = $true; $script:ReallyExit = $false; return }
        }
        Write-Log INFO 'Exit: stopping the finishing pass (the plain file is kept)'
        $script:DlRun.FinishStop = $true
        try { $script:DlRun.FinishProc.Kill() } catch { }
        return
    }
    if (-not $script:DlRun.Proc) { return }
    # Windows shutting down / restarting for updates, Task Manager, or an update that was already
    # confirmed: no question (it would hold up Windows), just stop and remove the unfinished file
    if ($script:ForceExit -or $e.CloseReason -in [System.Windows.Forms.CloseReason]::WindowsShutDown, [System.Windows.Forms.CloseReason]::TaskManagerClosing) {
        Write-Log INFO "Exit ($($e.CloseReason)): stopping the running download"
        Stop-CurrentDownload 'exit'; return
    }
    $q = [System.Windows.Forms.MessageBox]::Show($form, "A download is still running:`n`n$($script:DlRun.Item.Title)`n`nExit anyway? The unfinished file is deleted; completed downloads are kept.", 'Download running', 'YesNo', 'Warning')
    if ($q -ne 'Yes') { $e.Cancel = $true; $script:ReallyExit = $false; return }
    Stop-CurrentDownload 'exit'
})
$form.Add_FormClosed({
    $themeTimer.Stop(); $showTimer.Stop(); try { if ('NrkThemeWatch' -as [type]) { [NrkThemeWatch]::Stop() } } catch { }
    # any exit (also an update, or a newer copy asking this one to close): the download list as it is now
    # (settings are saved the moment they change; the window layout in FormClosing)
    try { if ($script:QueueSaveTimer) { $script:QueueSaveTimer.Stop() }; Save-DownloadQueue } catch { }
    # casting: a Chromecast plays on by itself; a TV gets its stream from this PC, so it stops
    try { if ($script:Cast.Session) { if ($script:Cast.Session.Device.Kind -eq 'cast') { Stop-Cast -Quiet -LeavePlaying } else { Stop-Cast -Quiet } }; if ($script:Cast.Server) { $script:Cast.Server.Dispose() } } catch { }
    try { Save-PosMap -Force } catch { }   # where you stopped
    Stop-InstancePipe
    try { if ($script:TrayUi) { $script:TrayUi.Icon.Visible = $false; $script:TrayUi.Icon.Dispose() } } catch { }
    try { if ($script:PlayerWin -and -not $script:PlayerWin.Form.IsDisposed) { $script:PlayerWin.WebView.Dispose(); $script:PlayerWin.Form.Dispose() } } catch { }
    try { if ($script:AudioUi.WebView) { $script:AudioUi.WebView.Dispose() } } catch { }
    Show-AppConsole
    Write-Log INFO '===== NRK-Browser closed ====='
})

#endregion

#region ---------- Startup ----------------------------------------------------------

# 0) Old logs out, then: installed somewhere else? Offer to upgrade it / run it from there.
try { Optimize-Logs } catch { }
try { Clear-UnfinishedDownload } catch { Write-LogException $_ 'Unfinished download cleanup' }
try { Restore-DownloadQueue } catch { Write-LogException $_ 'Download queue restore' }
try { Clear-Leftovers } catch { }
Invoke-LegacyMigration
$switchToInstalled = $false
try { $switchToInstalled = [bool](@(Invoke-InstallCheck)[-1]) } catch { Write-LogException $_ 'Install check' }
if ($switchToInstalled) { return }

# 1) Check every component before the main window opens; ask before installing anything.
$startupChoice = 'continue'
try {
    $startupDeps = Get-DependencyStatus
    $startupChoice = Show-DependencyDialog -Status $startupDeps -Startup
} catch {
    Write-LogException $_ 'Startup dependency check'
}
if (@($startupChoice)[-1] -eq 'exit') {   # [-1]: ignore any stray pipeline output
    Show-AppConsole
    Write-Log INFO '===== NRK-Browser closed from the component check (Exit) ====='
    return
}

# 2) Main window (started with Windows: invisible until it has moved to the tray)
if ($Tray) { $form.Opacity = 0 }
Set-AppIcon $form
try {
    [void][System.Windows.Forms.Application]::Run($form)
} finally {
    # however the message loop ended: nothing may be left running or locked
    try { if ($script:DlRun.Fetch -or ($script:DlRun.Proc -and -not $script:DlRun.Proc.HasExited)) { Stop-CurrentDownload 'exit' } } catch { }
    try { Save-DownloadQueue } catch { }
    try { Save-PosMap -Force } catch { }
    try { Stop-InstancePipe } catch { }
    try { if ($script:TrayUi) { $script:TrayUi.Icon.Visible = $false; $script:TrayUi.Icon.Dispose() } } catch { }
    try { if ($script:InstanceMutex) { $script:InstanceMutex.ReleaseMutex() } } catch { }
    try { Stop-AllRecordings } catch { }
    try { Stop-PhoneRemote } catch { }
    try { if ($script:Hotkeys) { $script:Hotkeys.Dispose() } } catch { }
    try { Save-Stats } catch { }
    try { if ($script:LogFlushTimer) { $script:LogFlushTimer.Stop() }; Close-LogWriter } catch { }
}

#endregion
