"""MaluDB external MCP broker.

A stdio JSON-RPC server that exposes non-database tools to MCP
clients. The contract is documented in
`docs/mcp-broker-design.md`. v1 supports the `shell` tool kind
only; `http` and `mcp_proxy` land in v2.
"""

__version__ = "0.1.0"
PROTOCOL_VERSION = "2025-11-25"
