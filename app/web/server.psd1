@{
    # Pode server configuration.
    #
    # Request.Timeout: Pode's default is 30 seconds. The Veeam add-on's "all jobs" view queries the
    # backup server over WinRM and can take ~30s for wide windows (30/60/90 days), which races the
    # default and produces intermittent HTTP 408 (Request Timeout). Raise it so slow admin queries
    # finish. Normal pages (login, dashboard, run-scripts) return in milliseconds and are unaffected.
    # Kept in line with the Veeam query's own bounds (WinRM OperationTimeout 120s, inner pwsh 90s).
    Server = @{
        Request = @{
            Timeout = 120
        }
    }
}
