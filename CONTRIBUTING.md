# Contributing to Tool Switch Rail

Thanks for considering a contribution.

Tool Switch Rail is intentionally a thin native macOS coordination layer. Contributions should preserve that boundary: avoid embedding or patching third-party clients, avoid turning the project into a general-purpose agent orchestrator, and prefer small changes that keep existing behavior stable.

## Good contribution areas

- macOS compatibility fixes
- window positioning and switching reliability
- accessibility and keyboard behavior
- status-probe reliability
- support for additional local-only, read-only status signals
- performance improvements
- documentation and setup fixes

## Before opening an issue

Please include:

- macOS version
- Mac architecture
- Tool Switch Rail commit or release
- affected third-party application and version, when relevant
- expected behavior
- actual behavior
- minimal reproduction steps

Do not upload private conversations, API keys, access tokens, complete personal log files, or other confidential data.

## Pull requests

Keep pull requests focused. Explain what changes, why it is needed, and how you verified it. Avoid unrelated refactors in bug-fix pull requests.

For status probes, prefer conservative detection and graceful fallback over aggressive heuristics that create false working/approval states.

## Build verification

At minimum, verify that the project still builds using:

```bash
./build.command
```

When the change affects window control or a status integration, also verify the behavior manually on macOS and describe the test in the pull request.

## Third-party application boundaries

Integrations must not require modifying third-party app bundles, injecting code, bypassing security controls, or writing to third-party application data. Read-only inspection of locally available state may be acceptable when documented and implemented conservatively.