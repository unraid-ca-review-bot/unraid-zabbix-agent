# Zabbix Agent for Unraid

The official static [Zabbix](https://www.zabbix.com) 7.0 LTS agent (`zabbix_agentd`) as a native Unraid plugin.
It sees the host directly — CPU, memory, disks, filesystems, network, the array — without a container
or bind mounts.

The plugin downloads the agent from `cdn.zabbix.com` and checks its SHA256; nothing is rebuilt.
Agent 7.0 works with Zabbix server 7.0 and newer.

## Install

Unraid → *Plugins* → *Install Plugin*, paste:

```
https://github.com/vrx-666/unraid-zabbix-agent/releases/latest/download/zabbix-agent.plg
```

## Configuration

On first install the plugin writes `/boot/config/plugins/zabbix-agent/zabbix_agentd.conf` and a random
pre-shared key next to it, and prints the PSK identity and key. Set `Server` (and `ServerActive` for active
checks) to your Zabbix server, then `/etc/rc.d/rc.zabbix-agent restart`. The file survives plugin updates
and removal.

On the Zabbix server, add the host with the "Linux by Zabbix agent" template and, under *Encryption*,
PSK with the identity and key printed at install.

## Security

The agent runs as root, because SMART needs it. To keep a compromised Zabbix server from using it against
Unraid, only the keys of the "Linux by Zabbix agent" template and the Unraid keys below are allowed;
everything else (`system.run`, reading arbitrary files, web requests, port checks, ...) is denied, and
no allowed key accepts `..` in its parameters. The rules are in `/etc/zabbix/` and are replaced on every
update. Rules you add to your own config file come before them, so you can allow more keys there.

`./test.sh` checks this against the real agent: every template key works, the dangerous ones are denied.

## Unraid keys

| Key | Value |
|---|---|
| `unraid.array.state` | Array state: `STARTED`, `STOPPED`, ... |
| `unraid.disks` | All disks as JSON (status, temperature, errors, spun down), read from Unraid without waking disks |
| `unraid.smart.health[sdX]` | SMART health: `PASSED`, `FAILED`, or `STANDBY` (a sleeping disk is not woken) |

## License

Zabbix is licensed under the AGPL-3.0; the plugin files in this repository are under the same licence.
