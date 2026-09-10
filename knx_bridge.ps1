<#
.SYNOPSIS
    Bidirectional Application-Level Gateway (ALG) for KNXnet/IP Tunneling.
.DESCRIPTION
    Interconnects KNX Virtual (bound exclusively to loopback 127.0.0.1:3671)
    with Home Assistant OS running in a bridged virtual machine.
    Rewrites HPAI (Host Protocol Address Information) headers in real time.
.LICENSE
    MIT License
    Copyright (c) 2026 Román López Pérez
#>

# ==============================================================================
# USER CONFIGURATION - UPDATE ACCORDING TO YOUR NETWORK SETUP
# ==============================================================================

# IP address of the Home Assistant OS Virtual Machine (Bridged Adapter)
$HomeAssistantIP = "192.168.1.69"   # <-- Replace with your HA VM IP

# Physical IPv4 address of the Windows Host running KNX Virtual.
# Leave empty ("") to automatically detect the host's active local IP address.
$HostIPOverride = ""               # <-- (Optional) e.g., "192.168.1.98"

# ==============================================================================
# INITIALIZATION & NETWORK RESOLUTION
# ==============================================================================

$client = New-Object System.Net.Sockets.UdpClient(3672)
$target = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse("127.0.0.1"), 3671)
$sender = New-Object System.Net.Sockets.UdpClient(0)
$senderPort = ([System.Net.IPEndPoint]$sender.Client.LocalEndPoint).Port

# Resolve host physical IP (custom override or automatic detection)
if (-not [string]::IsNullOrWhiteSpace($HostIPOverride)) {
    $hostIP = $HostIPOverride
} else {
    $hostIP = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
               Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
               Select-Object -ExpandProperty IPAddress -First 1)
}

if (-not $hostIP) {
    Write-Error "Could not resolve host physical IPv4 address. Please specify `$HostIPOverride manually."
    exit 1
}

$hostBytes = [System.Net.IPAddress]::Parse($hostIP).GetAddressBytes()
$haEndpoint = $null
$tempEndpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "KNX UDP NAT APPLICATION GATEWAY ACTIVE (3672 <-> 3671)" -ForegroundColor Cyan
Write-Host "Host IP: $hostIP | Authorized HA VM: $HomeAssistantIP" -ForegroundColor Yellow
Write-Host "Local ephemeral port to simulator: $senderPort" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# ==============================================================================
# MAIN ROUTING & TRANSLATION LOOP
# ==============================================================================

while ($true) {
    # 1. Inbound traffic: Home Assistant -> KNX Virtual
    try {
        if ($client.Available -gt 0) {
            $data = $client.Receive([ref]$tempEndpoint)
            
            # Whitelist verification: accept packets only from authorized HA VM
            if ($tempEndpoint.Address.ToString() -ne $HomeAssistantIP) { continue }
            $haEndpoint = $tempEndpoint

            $svc = "{0:X2}{1:X2}" -f $data[2], $data[3]

            # 0x0205: CONNECT_REQUEST -> Rewrite HPAI to 127.0.0.1:$senderPort
            if ($data.Length -ge 26 -and $data[2] -eq 0x02 -and $data[3] -eq 0x05) {
                $data[8] = 127; $data[9] = 0; $data[10] = 0; $data[11] = 1
                $data[12] = [byte]($senderPort -shr 8); $data[13] = [byte]($senderPort -band 0xFF)
                $data[16] = 127; $data[17] = 0; $data[18] = 0; $data[19] = 1
                $data[20] = [byte]($senderPort -shr 8); $data[21] = [byte]($senderPort -band 0xFF)
                Write-Host "-> HA: CONNECT_REQUEST (HPAI translated to 127.0.0.1:$senderPort)" -ForegroundColor Green
            }
            # 0x0203: DESCRIPTION_REQUEST
            elseif ($data.Length -ge 14 -and $data[2] -eq 0x02 -and $data[3] -eq 0x03) {
                $data[8] = 127; $data[9] = 0; $data[10] = 0; $data[11] = 1
                $data[12] = [byte]($senderPort -shr 8); $data[13] = [byte]($senderPort -band 0xFF)
                Write-Host "-> HA: DESCRIPTION_REQUEST" -ForegroundColor Green
            }
            # 0x0207: CONNECTIONSTATE_REQUEST (Heartbeat) or 0x0209: DISCONNECT_REQUEST
            elseif ($data.Length -ge 16 -and $data[2] -eq 0x02 -and ($data[3] -eq 0x07 -or $data[3] -eq 0x09)) {
                $data[10] = 127; $data[11] = 0; $data[12] = 0; $data[13] = 1
                $data[14] = [byte]($senderPort -shr 8); $data[15] = [byte]($senderPort -band 0xFF)
                Write-Host "-> HA: Heartbeat/Disconnect (0x$svc)" -ForegroundColor DarkGreen
            }
            # 0x0420: TUNNELING_REQUEST (Payload data from Home Assistant)
            elseif ($data.Length -ge 10 -and $data[2] -eq 0x04 -and $data[3] -eq 0x20) {
                Write-Host "-> HA: DATA TELEGRAM TUNNELING_REQUEST ($($data.Length) bytes)" -ForegroundColor Magenta
            }
            else {
                Write-Host "-> HA: Service 0x$svc ($($data.Length) bytes)" -ForegroundColor Green
            }

            $sender.Send($data, $data.Length, $target) | Out-Null
        }
    } catch {
        Write-Host "[ERROR HA]: $($_.Exception.Message)" -ForegroundColor Red
    }

    # 2. Outbound traffic: KNX Virtual -> Home Assistant
    try {
        if ($sender.Available -gt 0) {
            $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $reply = $sender.Receive([ref]$remote)

            $respSvc = "{0:X2}{1:X2}" -f $reply[2], $reply[3]

            # 0x0206: CONNECT_RESPONSE (Critical rewrite of Server Data Endpoint)
            if ($reply.Length -ge 20 -and $reply[2] -eq 0x02 -and $reply[3] -eq 0x06) {
                $reply[10] = $hostBytes[0]
                $reply[11] = $hostBytes[1]
                $reply[12] = $hostBytes[2]
                $reply[13] = $hostBytes[3]
                $reply[14] = [byte](3672 -shr 8)
                $reply[15] = [byte](3672 -band 0xFF)
                Write-Host "<- KNX: CONNECT_RESPONSE (Data Endpoint translated to $hostIP`:3672)" -ForegroundColor Cyan
            }
            # 0x0420: TUNNELING_REQUEST (State telegrams from simulator)
            elseif ($reply.Length -ge 10 -and $reply[2] -eq 0x04 -and $reply[3] -eq 0x20) {
                Write-Host "<- KNX: STATE TELEGRAM ($($reply.Length) bytes)" -ForegroundColor Yellow
            }
            # 0x0421: TUNNELING_ACK (Command acknowledge)
            elseif ($reply.Length -ge 10 -and $reply[2] -eq 0x04 -and $reply[3] -eq 0x21) {
                Write-Host "<- KNX: TUNNELING_ACK (Command confirmed by actuator)" -ForegroundColor Green
            }
            else {
                Write-Host "<- KNX: Service 0x$respSvc ($($reply.Length) bytes)" -ForegroundColor DarkYellow
            }

            if ($null -ne $haEndpoint) {
                $client.Send($reply, $reply.Length, $haEndpoint) | Out-Null
            }
        }
    } catch {
        Write-Host "[ERROR KNX]: $($_.Exception.Message)" -ForegroundColor Red
    }

    Start-Sleep -Milliseconds 2
}
