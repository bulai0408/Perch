# Security Policy / 安全策略

## Reporting a vulnerability / 报告漏洞

**Please do not report security vulnerabilities in public issues, pull requests or discussions.**
**请不要在公开的 Issue、PR 或讨论里报告安全漏洞。**

Use GitHub's private vulnerability reporting instead:
请使用 GitHub 的私密漏洞报告：

👉 <https://github.com/bulai0408/Perch/security/advisories/new>

(Repository → **Security** tab → **Report a vulnerability**.)

Please include:

- what the issue is and its impact;
- steps to reproduce, or a proof of concept;
- the Perch version or commit, iOS version and magpie version.

Leave out real gateway keys, addresses and account data. Use placeholders.

We aim to acknowledge reports within 7 days and keep you updated until the issue is resolved. If you want credit, it will be given in the advisory.

## Supported versions

Perch is distributed as source only. Security fixes land on the `main` branch; please build from the latest `main`.

## Scope

In scope: the Perch app and the scripts in this repository, for example:

- gateway keys leaking (logs, screenshots, UI, backups, Keychain handling);
- Perch sending a key somewhere other than the configured magpie address;
- issues in how Perch parses responses from magpie.

Out of scope: vulnerabilities in magpie itself. Please report those to the [magpie project](https://github.com/yetone/magpie). Perch talks to magpie over plain HTTP on your local network or VPN (such as Tailscale) by design (see README). Running magpie on an untrusted network, or exposing it to the internet, is not a Perch vulnerability.
