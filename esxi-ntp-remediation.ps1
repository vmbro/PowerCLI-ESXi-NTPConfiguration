$vcenter = "vCenterFQDN" # Your vCenter name -  vcenter.domain.local
$user = "username" # Your vCenter username - administrator@vsphere.local or domain\username
$password = "password" # Your vCenter password
$NTPAddr = "0.tr.pool.org", "8.8.8.8" # Your Primary and Secondary NTP server
$uriSlack = "https://..." # Your Slack URI
$locationText = $emoji + "Location: HQ - Production vCenter" + "`n"; # Your Location Title
$remediateNTP = $false ### If you do not want to auto remediate please keep this value as $false.
$emoji = ':information_source: '
$emojiRemediate = ':white_check_mark: ' 
try {
    Disconnect-VIServer -server * -confirm:$false
}
catch {
    #"Could not find any of the servers specified by name."
}

function restartNTPService {
    param([string]$currentHost)
    $hostService = Get-VMHost -name $currentHost | Select-Object Name, @{N = "NTPServiceStatus"; E = { ($_ | Get-VmHostService | Where-Object { $_.key -eq "ntpd" }) } }
    if ($hostService.NTPServiceStatus.Running -eq "True") {
        Get-VMHost -Name $hostService.Name | Get-VMHostService | Where-Object { $_.key -eq 'ntpd' } | Stop-VMHostService -confirm:$false | Out-Null
        Get-VMHost -Name $hostService.Name | Get-VMHostService | Where-Object { $_.key -eq 'ntpd' } | Start-VMHostService -confirm:$false | Out-Null
        write-host $hostService.Name " NTP settings updated. Service restarted" -ForegroundColor Green
    }
    else {
        Get-VMHost -Name $hostService.Name | Get-VMHostService | Where-Object { $_.key -eq 'ntpd' } | Start-VMHostService -confirm:$false | Out-Null
        write-host $hostService.Name " NTP settings updated. Service started" -ForegroundColor Green
    }
}

function remediateControl {
    param([string]$currentHost, [array]$currentNTPServer, [string]$NTPState)  
    if ($remediateNTP -eq $true) {
        Write-Host "Remediations will be applied to" $currentHost -ForegroundColor Cyan
        $action = ' *has been successfully remediated with expected NTP configurations!*' + "`n" ;
        switch ($NTPState) {
            'null' { 
                Add-VmHostNtpServer -NtpServer $NTPAddr -VMHost $currentHost | Out-Null
                $remediationText = $emojiRemediate + '*' + $currentHost + '*' + $action 
            }
            'update-array-ntp' {
                Get-VMHost -Name $currentHost | Remove-VMHostNtpServer -NtpServer $currentNTPServer -confirm:$false | Out-Null
                Add-VmHostNtpServer -NtpServer $NTPAddr -VMHost $currentHost | Out-Null
                $remediationText = $emojiRemediate + '*' + $currentHost + '*' + $action    
            }
            'update-string-ntp' { 
                Get-VMHost -Name $currentHost | Remove-VMHostNtpServer -NtpServer $currentNTPServer -confirm:$false | Out-Null
                Add-VmHostNtpServer -NtpServer $NTPAddr -VMHost $currentHost | Out-Null
                $remediationText = $emojiRemediate + '*' + $currentHost + '*' + $action       
            }
            'update-string-ntp-secondary' { 
                Add-VmHostNtpServer -NtpServer $NTPAddr[1] -VMHost $currentHost | Out-Null
                $remediationText = $emojiRemediate + '*' + $currentHost + '*' + $action    
            }
        }
        restartNTPService $currentHost
        sendSlack $remediationText
    }
}

function sendSlack {
    param([string]$slackTitle, [string]$slackText, [string]$slackAction)
    $body = ConvertTo-Json @{
        text = $slackTitle + $slackText + $slackAction
    }
    Invoke-RestMethod -uri $uriSlack -Method Post -body $body -ContentType 'application/json' | Out-Null
    Write-Host "You can check your Slack." $currentHost -ForegroundColor Cyan
}
$HostNTPNullText = ""
$HostNTPArrayText = ""
$HostNTPStringText = ""
$HostNTPStringSecondaryText = ""
$HostNTPNull = ""
$HostNTPArray = ""
$HostNTPString = ""
$HostNTPStringSecondary = ""
Connect-VIServer -Server $vcenter -User $user -Password $password | out-null
$NTPSettings = Get-VMHost | Select-Object Name, @{N = "NTPServers"; E = { $_ | Get-VMHostNtpServer } }
foreach ($esxi in $NTPSettings) {
    if ($null -eq $esxi.NTPServers) {
        $NTPState = "null"
        $HostNTPNull += $esxi.Name + "`n"
        remediateControl $esxi.Name $esxi.NTPServers $NTPState
    }
    elseif ($esxi.NTPServers -is [array]) {
        if (($esxi.NTPServers[0] -ne $NTPAddr[0]) -or ($esxi.NTPServers[1] -ne $NTPAddr[1]) ) {
            $NTPState = "update-array-ntp"
            $HostNTPArray += $esxi.Name + " : Current: " + $esxi.NTPServers[0] + "," + $esxi.NTPServers[1] + " > Expected : " + $NTPAddr[0] , $NTPAddr[1] + "`n"
            remediateControl $esxi.Name $esxi.NTPServers $NTPState
        }
        else {
            Write-Host "NTP settings are OK for" $esxi.Name -ForegroundColor Cyan
        }  
    }
    else {
        if ($esxi.NTPServers -ne $NTPAddr[0]) {
            $NTPState = "update-string-ntp"
            $HostNTPString += $esxi.Name + " : Current: " + $esxi.NTPServers + " > Expected : " + $NTPAddr[0], $NTPAddr[1] + "`n"
            remediateControl $esxi.Name $esxi.NTPServers $NTPState
        }
        else {
            $NTPState = "update-string-ntp-secondary"
            $HostNTPStringSecondary += $esxi.Name + " : Current: " + $esxi.NTPServers + " > Expected : " + $NTPAddr[0], $NTPAddr[1] + "`n"
            remediateControl $esxi.Name $esxi.NTPServers $NTPState
        }
    }
}

if (![string]::IsNullOrEmpty($HostNTPNull) -and $remediateNTP -eq $false) {
    $HostNTPNullText += $locationText + '```' + $HostNTPNull + '```';
    $title = $emoji + 'ESXi missing NTP Servers' + "`n";
    $action = $emoji + '*Action *: ' + "Add primary and secondary NTP Server on the ESXi." + "`n" ;
    sendSlack $title $HostNTPNullText $action
}
if (![string]::IsNullOrEmpty($HostNTPArray) -and $remediateNTP -eq $false) {
    $HostNTPArrayText += $locationText + '```' + $HostNTPArray + '```';
    $title = $emoji + 'ESXi NTP Server Consistency' + "`n";
    $action = $emoji + '*Action *: ' + "NTP address is not expected. Please make sure NTP Servers are correct." + "`n" ;
    sendSlack $title $HostNTPArrayText $action
}
if (![string]::IsNullOrEmpty($HostNTPString) -and $remediateNTP -eq $false) {
    $HostNTPStringText += $locationText + '```' + $HostNTPString + '```';
    $title = $emoji + 'ESXi has wrong NTP address' + "`n";
    $action = $emoji + '*Action *: ' + "Primary NTP address is not expected and add secondary NTP Server on the ESXi." + "`n" ;
    sendSlack $title $HostNTPStringText $action
}
if (![string]::IsNullOrEmpty($HostNTPStringSecondary) -and $remediateNTP -eq $false) {
    $HostNTPStringSecondaryText += $locationText + '```' + $HostNTPStringSecondary + '```';
    $title = $emoji + 'ESXi missing secondary NTP address' + "`n";
    $action = $emoji + '*Action *: ' + "Add secondary NTP Server on the ESXi." + "`n" ;
    sendSlack $title $HostNTPStringSecondaryText $action
}
Disconnect-VIServer -Server * -Confirm:$false | out-null 
