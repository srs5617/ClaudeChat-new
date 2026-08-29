# Security policy

## Reporting a vulnerability

Please do not publish credentials, exported conversations, diagnostics, signing material, or a working exploit in a public issue. Open a minimal issue asking for a private contact channel, without including sensitive details.

## Local data and external providers

ClaudeChat stores its canonical data locally. Content is transmitted externally only when a user configures and invokes an API provider, opens an external link, or explicitly exports/shares data. Provider privacy terms and retention policies are outside this project’s control.

## Secrets that must remain private

- API keys and authorization headers
- Android keystores and `key.properties`
- Apple certificates, provisioning profiles, and signing keys
- GitHub deploy keys and personal access tokens
- `.claudechat` backups, diagnostic exports, and local SQLite databases

The repository ignores common forms of these files, but contributors should review every commit before publishing it.
