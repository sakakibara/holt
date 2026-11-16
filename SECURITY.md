# Security

## Supported versions

| Version | Zig | Security and data-loss fixes |
| --- | --- | --- |
| 0.11.x | 0.17 | Yes |
| 0.10.x | 0.16 | Yes, through the date in the README's [Compatibility](README.md#compatibility) section |
| Earlier | | No |

## Reporting a vulnerability

Report it privately: on this repository's Security tab, choose "Report a
vulnerability". Please do not open a public issue for it.

A vulnerability is a way for input holt does not control - a marker, config
file, remote URL, repository, or file in the synced folder - to make holt
read, write, or run anything its documentation does not describe, expose a
credential, or run without bound. Data loss is holt destroying or silently
corrupting what it manages: clones, hubs, kept files, or the synced folder.
