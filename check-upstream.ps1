# Checks for new commits on upstream/main (or upstream/master), posts a summary
# to Discord if there are any. Detection-only — does not merge, build, or deploy.

$ErrorActionPreference = "Stop"
$repoDir = $PSScriptRoot
$logFile = Join-Path $repoDir ".upstream-check.log"

# Files we've patched. Update if you patch more.
$patchedFiles = @(
    "src/main/java/dev/saseq/services/ForumService.java"
)

# Where to post the report
$REPORT_CHANNEL_ID = "1498291758843564172"  # #integrations

function Log($msg) {
    "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $msg" | Add-Content -Path $logFile
}

try {
    # Read token
    $envPath = "$env:USERPROFILE\.claude\channels\discord\.env"
    $tokenLine = Select-String -Path $envPath -Pattern '^DISCORD_BOT_TOKEN=' | Select-Object -First 1
    if (-not $tokenLine) { Log "ERROR: DISCORD_BOT_TOKEN not found"; exit 1 }
    $token = ($tokenLine.Line -replace '^DISCORD_BOT_TOKEN=', '')

    # Fetch upstream silently
    git -C $repoDir fetch upstream 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Log "ERROR: git fetch upstream failed"; exit 1 }

    # Find upstream HEAD branch — try main, then master
    $upstreamRef = $null
    git -C $repoDir rev-parse --verify upstream/main 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $upstreamRef = "upstream/main" }
    else {
        git -C $repoDir rev-parse --verify upstream/master 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $upstreamRef = "upstream/master" }
    }
    if (-not $upstreamRef) { Log "ERROR: no upstream/main or upstream/master found"; exit 1 }

    # Commits we don't have yet
    $newCommits = @(git -C $repoDir log "HEAD..$upstreamRef" --oneline 2>$null)
    if ($newCommits.Count -eq 0) {
        Log "Up to date with $upstreamRef"
        exit 0
    }

    # Files changed in upstream we don't have
    $changedFiles = @(git -C $repoDir diff --name-only HEAD $upstreamRef 2>$null) | Sort-Object -Unique

    # Did upstream touch any of our patched files?
    $touchedPatched = @($changedFiles | Where-Object { $patchedFiles -contains $_ })
    $hasConflictRisk = $touchedPatched.Count -gt 0

    # Simulate the merge (clean working tree assumed — script never runs while you're editing)
    $mergeStatus = "clean"
    git -C $repoDir merge --no-commit --no-ff $upstreamRef 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $mergeStatus = "CONFLICT"
    }
    git -C $repoDir merge --abort 2>&1 | Out-Null

    # Build the report
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("**Upstream MCP check — $((Get-Date).ToString('yyyy-MM-dd HH:mm'))**")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("$($newCommits.Count) new commit(s) on ``$upstreamRef``:")
    [void]$sb.AppendLine("``````")
    foreach ($c in $newCommits | Select-Object -First 10) { [void]$sb.AppendLine($c) }
    if ($newCommits.Count -gt 10) { [void]$sb.AppendLine("... and $($newCommits.Count - 10) more") }
    [void]$sb.AppendLine("``````")
    [void]$sb.AppendLine("Files changed: $($changedFiles.Count)")

    if ($hasConflictRisk) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("**Heads up:** upstream touched our patched file(s):")
        foreach ($f in $touchedPatched) { [void]$sb.AppendLine("- ``$f``") }
        [void]$sb.AppendLine("Review the diff before merging — possible duplicate features (e.g. tag tools).")
    } else {
        [void]$sb.AppendLine("No patched files touched.")
    }

    [void]$sb.AppendLine("Merge simulation: **$mergeStatus**")
    [void]$sb.AppendLine("")
    if ($mergeStatus -eq "clean" -and -not $hasConflictRisk) {
        [void]$sb.AppendLine("Safe to pull:")
        [void]$sb.AppendLine("``````")
        [void]$sb.AppendLine("cd E:\Tools\discord-mcp")
        [void]$sb.AppendLine("git merge $upstreamRef && git push origin")
        [void]$sb.AppendLine("docker compose up -d --build")
        [void]$sb.AppendLine("``````")
    } else {
        [void]$sb.AppendLine("Review manually. Then:")
        [void]$sb.AppendLine("``````")
        [void]$sb.AppendLine("cd E:\Tools\discord-mcp")
        [void]$sb.AppendLine("git merge $upstreamRef   # resolve any conflicts")
        [void]$sb.AppendLine("git push origin")
        [void]$sb.AppendLine("docker compose up -d --build")
        [void]$sb.AppendLine("``````")
    }

    # Truncate to Discord 2000-char limit
    $content = $sb.ToString()
    if ($content.Length -gt 1900) {
        $content = $content.Substring(0, 1900) + "`n... (truncated)"
    }

    # Post
    $body = @{ content = $content } | ConvertTo-Json -Compress
    $headers = @{ "Authorization" = "Bot $token"; "Content-Type" = "application/json" }
    Invoke-RestMethod -Uri "https://discord.com/api/v10/channels/$REPORT_CHANNEL_ID/messages" -Method Post -Headers $headers -Body $body -UseBasicParsing | Out-Null

    Log "Posted: $($newCommits.Count) commits, conflict-risk=$hasConflictRisk, merge=$mergeStatus"
} catch {
    Log "ERROR: $_"
    exit 1
}
