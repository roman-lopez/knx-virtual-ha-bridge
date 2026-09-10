# KNX Virtual to Home Assistant UDP Gateway

Bidirectional Application-Level Gateway (ALG) written in PowerShell to interconnect 
**KNX Virtual** (locked to loopback `127.0.0.1:3671`) with **Home Assistant OS** running in a bridged Virtual Machine.

## Features
- Dynamic HPAI structure inspection and rewriting.
- IP Whitelisting for authorized VM access.
- Transparent tunneling for KNXnet/IP Tunneling v1.
- Open-source under MIT License.
