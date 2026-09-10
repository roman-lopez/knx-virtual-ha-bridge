# KNX Virtual to Home Assistant UDP Gateway

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://microsoft.com/powershell)
[![Home Assistant](https://img.shields.io/badge/Home%20Assistant-Compatible-brightgreen.svg)](https://www.home-assistant.io/)

A lightweight, bidirectional **Application-Level Gateway (ALG)** written in PowerShell to bridge **KNX Virtual** with **Home Assistant OS** running inside a virtualized environment (VirtualBox, VMware) using a Bridged Network Adapter.

---

## The Problem

When setting up a simulated smart home / yacht automation testbed with **KNX Virtual** and a virtualized **Home Assistant OS**, communication fails due to several constraints:

1. **Loopback Exclusive Binding:** KNX Virtual binds strictly to `127.0.0.1:3671 UDP`. While a virtual machine with a bridged network adapter can reach the host's physical LAN IP, the Windows TCP/IP stack drops incoming UDP packets destined for loopback.
2. **Inadequacy of Native Port Proxies:** Tools like `netsh interface portproxy` operate strictly on TCP and cannot route UDP datagrams used by KNXnet/IP Tunneling v1.
3. **Application-Layer HPAI Headers:** KNXnet/IP control frames (`CONNECT_REQUEST`, `CONNECTIONSTATE_REQUEST`) embed the client's IP and ephemeral port inside the binary payload (**HPAI** - *Host Protocol Address Information*). When Home Assistant transmits its bridged IP (e.g., `192.168.1.69`), KNX Virtual fails to respond to external sockets from loopback.
4. **Server Data Endpoint Mismatch:** In the connection response (`0x0206 CONNECT_RESPONSE`), KNX Virtual tells the client to send all subsequent tunneling data (`0x0420 TUNNELING_REQUEST`) back to `127.0.0.1:3671`. If uncorrected, Home Assistant sends packets to its own local loopback, dropping the tunnel.

---

## Architecture & How It Works

This gateway operates on Windows host as an active **Application-Level Gateway**:
+---------------------------+              +-------------------------------------+
|  Home Assistant OS (VM)   |              |         Windows Host System         |
|   Bridged Adapter         |              |                                     |
|   (e.g., 192.168.1.69)    |              |  +-------------------------------+  |
|                           |              |  |   knx_bridge.ps1 (Port 3672)  |  |
|                           | UDP 3672     |  +-------------------------------+  |
|                           |=>|   • Inspects & translates HPAI      |
|                           |              |   • Filters VM via Whitelist        |
|                           |              |   • Rewrites Data Endpoints         |
|                           |<=|                  │                  |
|                           | UDP Reply    |                  │ Loopback UDP     |
|                           |              |                  ▼ (Port 3671)      |
|                           |              |  +-------------------------------+  |
|                           |              |  |     KNX Virtual Simulator     |  |
|                           |              |  |        (127.0.0.1:3671)       |  |
|                           |              |  +-------------------------------+  |
+---------------------------+              +-------------------------------------+

* **Upstream Translation (HA $\rightarrow$ KNX Virtual):** Rewrites the HPAI structures of `CONNECT_REQUEST` and `DESCRIPTION_REQUEST` from the VM's IP to `127.0.0.1` and points to an ephemeral host sender port.
* **Downstream Translation (KNX Virtual $\rightarrow$ HA):** Rewrites the *Server Data Endpoint* inside `CONNECT_RESPONSE` to the Windows physical LAN IP and port `3672`, ensuring Home Assistant directs future telegrams to this proxy.
* **Security Whitelist:** Silently drops any datagram not originating from the authorized Home Assistant VM IP before parsing memory.

---

## Prerequisites

* Windows 10 or Windows 11 (Host machine).
* [KNX Virtual](https://support.knx.org/hc/en-us/sections/360003367780-KNX-Virtual) (Installed and running).
* Home Assistant OS running inside VirtualBox / VMware configured with **Bridged Networking**.
* PowerShell 5.1 or later.

---

## Quick Start Guide

### 1. Configure Host Firewall & Network Profile
Run PowerShell as **Administrator** on the host machine to allow incoming UDP traffic on port `3672`:

```powershell
# Set network profile to Private (required for custom firewall routing)
Set-NetConnectionProfile -NetworkCategory Private

# Allow UDP port 3672 inbound
New-NetFirewallRule -DisplayName "KNX Virtual Bridge" -Direction Inbound -LocalPort 3672 -Protocol UDP -Action Allow
