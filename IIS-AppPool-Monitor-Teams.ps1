$servers = Get-Content -Path "C:\Your Server.txt"
$username = "your-username"
$credential = Get-StoredCredential -Target "IISAppPoolMonitor" 

if (-not $credential) {
    Write-Output "No stored credential found. Please save credentials using cmdkey."
    exit 1
}

$webhookUrl = "your webhook URL"
$stateFile = "C:\IISAppPoolState.json"
$logFilePath = "C:\IISPoolAlert-Teams\Logs\IISAppPoolMonitoringLog_$(Get-Date -Format 'yyyy-MM-dd').txt"
$templatePath = "C:\TeamsMessageTemplate.json"

if (Test-Path $stateFile) {
    $prevState = Get-Content $stateFile | ConvertFrom-Json
} else {
    $prevState = @{ }
}

$currentState = @{ }
$stoppedPools = @{ }


if (-Not (Test-Path $templatePath)) {
    Write-Output "Teams message template not found at $templatePath"
    exit 1
}
$template = Get-Content $templatePath -Raw

function Send-TeamsMessage {
    param (
        [string]$message,
        [string]$title,
        [string]$server,
        [string]$serverIP,
        [string]$poolName,
        [string]$state
    )

    $adaptiveCard = $template -replace '\{title\}', $title \
                              -replace '\{message\}', $message \
                              -replace '\{server\}', $server \
                              -replace '\{serverIP\}', $serverIP \
                              -replace '\{poolName\}', $poolName \
                              -replace '\{state\}', $state \
                              -replace '\{timestamp\}', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

    try {
        Invoke-RestMethod -Uri $webhookUrl -Method Post -ContentType 'application/json' -Body $adaptiveCard
        Write-Output "Alert sent to Teams: $title"
        Log-Alert "Alert sent to Teams: $title"
    } catch {
        Write-Output "Failed to send alert to Teams. Error: $_"
        Log-Alert "Failed to send alert to Teams. Error: $_"
    }
}

function Log-Alert {
    param ([string]$logMessage)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "$timestamp - $logMessage"
    Add-Content -Path $logFilePath -Value $logEntry
}

foreach ($server in $servers) {

    if (-Not (Test-Connection -ComputerName $server -Count 2 -Quiet)) {
        Write-Output "Server $server is unreachable. Skipping."
        Log-Alert "Server $server is unreachable."
        continue
    }

    try {
        $serverIP = (Resolve-DnsName -Name $server -ErrorAction SilentlyContinue).IPAddress
        if (-not $serverIP) { $serverIP = $server }

        $pools = Invoke-Command -ComputerName $server -Credential $credential -ScriptBlock {
            Import-Module WebAdministration
            Get-ChildItem IIS:\AppPools | Select-Object @{Name="Server"; Expression={$env:COMPUTERNAME}}, Name, State
        }

        foreach ($pool in $pools) {
            $poolKey = "$($pool.Server)_$($pool.Name)"
            $currentState[$poolKey] = $pool.State


            if ($pool.State -eq "Stopped" -and -not $stoppedPools.ContainsKey($poolKey)) {
                $message = "Critical Alert: The Application Pool '$($pool.Name)' has STOPPED on the server '$($pool.Server)'. Immediate action required!"
                Send-TeamsMessage -message $message -title "Critical Alert: IIS Application Pool Stopped" -server $pool.Server -serverIP $serverIP -poolName $pool.Name -state $pool.State
                Log-Alert "Critical Alert: IIS Application Pool '$($pool.Name)' on Server '$($pool.Server)' has STOPPED"
                $stoppedPools[$poolKey] = $pool.State
            }


            if ($pool.State -eq "Started" -and $stoppedPools.ContainsKey($poolKey)) {
                $message = "Service Restored: The Application Pool '$($pool.Name)' has STARTED on the server '$($pool.Server)'."
                Send-TeamsMessage -message $message -title "Service Restored: IIS Application Pool Started" -server $pool.Server -serverIP $serverIP -poolName $pool.Name -state $pool.State
                Log-Alert "Service Restored: IIS Application Pool '$($pool.Name)' on Server '$($pool.Server)' has STARTED"
                $stoppedPools.Remove($poolKey)
            }
        }
    } catch {
        Write-Output "Error: Failed to connect to the server '$server'. Error: $_"
        Log-Alert "Error: Failed to connect to the server '$server'. Error: $_"
    }
}

$currentState | ConvertTo-Json | Set-Content -Path $stateFile
Write-Output "State saved to $stateFile"
Log-Alert "State saved to $stateFile"

   Write-Output "Waiting for 60 seconds before the next check..."
   Start-Sleep -Seconds 60
}
