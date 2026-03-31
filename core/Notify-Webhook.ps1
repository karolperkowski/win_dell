#Requires -Version 5.1
<#
.SYNOPSIS
    Sends deployment notifications to a webhook URL (Slack/Teams compatible).
.DESCRIPTION
    Called by the Orchestrator at key lifecycle points: start, stage failure, completion.
    Sends a JSON payload via Invoke-RestMethod. Non-fatal --- failures are logged but
    never block deployment.
#>

Set-StrictMode -Version Latest

function Send-DeployNotification {
    param(
        [string]$WebhookUrl,
        [string]$Event,        # 'Start' | 'StageFailure' | 'Complete'
        [string]$MachineName,
        [string]$Message,
        [string]$StageName = '',
        [string]$ErrorDetail = ''
    )

    if (-not $WebhookUrl) { return }

    $colour = switch ($Event) {
        'Start'        { '#60A5FA' }  # blue
        'StageFailure' { '#F87171' }  # red
        'Complete'     { '#4ADE80' }  # green
        default        { '#888888' }
    }

    $title = switch ($Event) {
        'Start'        { "WinDeploy started on $MachineName" }
        'StageFailure' { "Stage '$StageName' failed on $MachineName" }
        'Complete'     { "Deployment complete on $MachineName" }
        default        { "WinDeploy: $Event" }
    }

    # Slack-compatible payload (also works with many webhook services)
    $payload = @{
        text = $title
        attachments = @(
            @{
                color = $colour
                title = $title
                text  = $Message
                fields = @(
                    @{ title = 'Machine'; value = $MachineName; short = $true }
                    @{ title = 'Event';   value = $Event;       short = $true }
                )
                ts = [int][double]::Parse((Get-Date -UFormat %s))
            }
        )
    }

    if ($StageName) {
        $payload.attachments[0].fields += @{ title = 'Stage'; value = $StageName; short = $true }
    }
    if ($ErrorDetail) {
        $payload.attachments[0].fields += @{ title = 'Error'; value = $ErrorDetail; short = $false }
    }

    try {
        $json = $payload | ConvertTo-Json -Depth 5 -Compress
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $json -ContentType 'application/json' -TimeoutSec 10 | Out-Null
    } catch {
        # Non-fatal --- log but never block deployment
        Write-Warning "[Webhook] Failed to send notification: $($_.Exception.Message)"
    }
}
