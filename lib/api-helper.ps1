# Shared API helper functions for Windows batch scripts
# Usage: powershell -NoProfile -File lib\api-helper.ps1 -Action <action> [params]
#
# Actions:
#   call     -ApiBase <url> -ApiKey <key> -Model <model> -PromptFile <path> -OutputFile <path>
#   mask-key -ApiKey <key>

param(
    [Parameter(Mandatory)]
    [ValidateSet('call', 'mask-key')]
    [string]$Action,

    [string]$ApiBase,
    [string]$ApiKey,
    [string]$Model,
    [string]$PromptFile,
    [string]$OutputFile
)

function Get-MaskedKey {
    param([string]$Key)
    if (-not $Key) { return '(none)' }
    if ($Key.Length -le 8) { return '****' }
    return $Key.Substring(0, 4) + '...' + $Key.Substring($Key.Length - 4)
}

function Invoke-ApiCall {
    param(
        [string]$ApiBase,
        [string]$ApiKey,
        [string]$Model,
        [string]$PromptFile,
        [string]$OutputFile
    )

    $usageFile = "$OutputFile.usage"
    $url = "$ApiBase/chat/completions"

    try {
        $prompt = Get-Content -Raw $PromptFile -Encoding UTF8
        $body = @{
            model    = $Model
            messages = @(@{ role = 'user'; content = $prompt })
        } | ConvertTo-Json -Depth 5 -Compress

        $headers = @{ 'Content-Type' = 'application/json' }
        if ($ApiKey) {
            $headers['Authorization'] = "Bearer $ApiKey"
        }

        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec 600

        # Check for error in response
        if ($response.error) {
            $errMsg = $response.error.message
            Write-Error "API error: $errMsg"
            [System.IO.File]::WriteAllText($OutputFile, "API error: $errMsg", [System.Text.Encoding]::UTF8)
            '{}' | Out-File -Encoding utf8 $usageFile -NoNewline
            exit 1
        }

        # Extract content
        $content = $response.choices[0].message.content
        [System.IO.File]::WriteAllText($OutputFile, $content, [System.Text.Encoding]::UTF8)

        # Extract usage
        $inputTokens  = if ($response.usage.prompt_tokens)     { $response.usage.prompt_tokens }     else { 0 }
        $outputTokens = if ($response.usage.completion_tokens) { $response.usage.completion_tokens } else { 0 }
        $usage = @{
            input_tokens   = $inputTokens
            output_tokens  = $outputTokens
            cache_creation = 0
            cache_read     = 0
            cost_usd       = 0
        } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($usageFile, $usage, [System.Text.Encoding]::UTF8)

    } catch {
        $errMsg = $_.Exception.Message
        Write-Error "API connection failed: $errMsg"
        [System.IO.File]::WriteAllText($OutputFile, "API connection failed: $errMsg", [System.Text.Encoding]::UTF8)
        '{}' | Out-File -Encoding utf8 $usageFile -NoNewline
        exit 1
    }
}

switch ($Action) {
    'call' {
        Invoke-ApiCall -ApiBase $ApiBase -ApiKey $ApiKey -Model $Model -PromptFile $PromptFile -OutputFile $OutputFile
    }
    'mask-key' {
        Get-MaskedKey -Key $ApiKey
    }
}
