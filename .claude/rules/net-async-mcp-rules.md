# Net::Async::MCP House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

Async MCP (Model Context Protocol) client for IO::Async with three pluggable transports
(InProcess, Stdio, HTTP).

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug / test anything under `lib/` | `net-async-mcp-worker` (default) |
| POD | `net-async-mcp-doc-writer` |
| Commits, `Changes`, card → done, pre-release audit | `net-async-mcp-release-manager` |
| Read-only research, audit, gap analysis | `net-async-mcp-worker` ("read-only, change nothing") |

Behavior-relevant = runtime behavior of the three transports (InProcess, Stdio, HTTP), the
public API, MCP protocol handling, error handling, tests, performance.

## Deviations from the house rules

- **karr is rarely needed here.** A small, single-distribution repo with no driver family and
  typically one agent at a time: reach for the board when work genuinely spans multiple
  sessions or subagents and must survive a context reset, not for routine single-session
  tasks. The board is already initialized (`karr board`) — never run `karr init`.

## Perl / IO::Async / MCP specifics — reference, don't restate

The architecture — the InProcess-embeds-a-server concern, the pure-client transport boundary,
the known gaps, the single-`$VERSION` `:MainModule` style — lives in skill
`net-async-mcp-core`; Perl, IO::Async and MCP conventions in the skills force-loaded for
`net-async-mcp-*` agents.
