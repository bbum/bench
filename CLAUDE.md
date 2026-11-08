# CLAUDE.md

Tools for driving lab instruments from the CLI and from LLMs over MCP, so an
agent can inspect hardware in real time. Organized by vendor under `devices/`.
Each vendor directory is self-contained, with its own build and docs.

| Directory         | Hardware                  | Status                                        |
|-------------------|---------------------------|-----------------------------------------------|
| `devices/owon/`   | Owon SDS-series scopes    | Working `ow` CLI + MCP server. See its CLAUDE.md. |
| `devices/saleae/` | Saleae logic analyzers    | Not started. Logic Pro 8 is first.            |

Run build and test commands from the vendor directory, not the repo root.
