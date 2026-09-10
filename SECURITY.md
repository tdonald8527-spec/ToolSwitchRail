# Security Policy

Tool Switch Rail interacts with macOS application windows and may inspect local runtime signals for optional status detection. Security and privacy issues are therefore taken seriously.

## Supported code

Security fixes target the current `main` branch and the latest published release when releases are available.

## Reporting a vulnerability

Do not post credentials, private logs, exploit details, personal chat content, or other sensitive information in a public GitHub issue.

If GitHub private vulnerability reporting is available for this repository, use it. Otherwise, open a minimal public issue stating that you have a security concern and need a private contact channel, without including exploit details or sensitive data.

Please include only the minimum information necessary to reproduce and assess the issue once a private channel is established.

## Security boundaries

Tool Switch Rail is designed to:

- avoid modifying or injecting code into third-party applications;
- avoid storing third-party credentials for ordinary window coordination;
- keep optional status probes local and read-only;
- fail conservatively when third-party state cannot be determined reliably.

Third-party application formats and undocumented local signals can change without notice. Users should review permissions and source code before enabling integrations in environments containing sensitive information.