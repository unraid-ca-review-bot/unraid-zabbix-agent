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

*Settings* → *Network Services* → *Zabbix Agent*:

| Field | Agent option | |
|---|---|---|
| Zabbix server | `Server` | Servers allowed to poll the agent (passive checks) |
| Active checks server | `ServerActive` | Server the agent sends active checks to; empty = passive only |
| Hostname | `Hostname` | Must match the host name in Zabbix; empty = the Unraid server name |
| Host metadata | `HostMetadata` | Lets the Zabbix server add the host by itself ([autoregistration](https://www.zabbix.com/documentation/7.0/en/manual/discovery/auto_registration)) |
| Advanced | anything else | Any other agent option, one per line |

The options are those of the Zabbix agent, described in the
[Zabbix documentation](https://www.zabbix.com/documentation/7.0/en/manual/appendix/config/zabbix_agentd).
*Apply* checks the settings with the agent first: if it rejects them, nothing is saved and the error is shown.
Otherwise the agent restarts with them.

Everything is stored in one file, `/boot/config/plugins/zabbix-agent/zabbix_agentd.conf`, which survives
plugin updates and removal. You can also edit it by hand and run `/etc/rc.d/rc.zabbix-agent restart`.

On the Zabbix server, add the host with the "Linux by Zabbix agent" template.

The static agent from Zabbix is built without TLS, so the traffic between agent and server is not encrypted.

## Security

The agent runs as root, because SMART needs it. To keep a compromised Zabbix server from using it against
Unraid, only the keys of the "Linux by Zabbix agent" template and the Unraid keys below are allowed;
everything else (`system.run`, reading arbitrary files, web requests, port checks, ...) is denied, and
no allowed key accepts `..` in its parameters. The rules are in `/etc/zabbix/` and are replaced on every
update. To allow more keys, add `AllowKey=` lines under *Advanced*: your settings are read before the plugin's
rules, so they win. Keys with `..` in a parameter stay denied whatever you allow.

`./test.sh` checks this against the real agent: every template key works, the dangerous ones are denied.

## Unraid keys

| Key | Value |
|---|---|
| `unraid.array.state` | Array state: `STARTED`, `STOPPED`, ... |
| `unraid.disks` | All disks as JSON (status, temperature, errors, spun down), read from Unraid without waking disks |
| `unraid.smart.health[sdX]` | SMART health: `PASSED`, `FAILED`, or `STANDBY` (a sleeping disk is not woken) |

## License

Zabbix is licensed under the AGPL-3.0; the plugin files in this repository are under the same licence.
