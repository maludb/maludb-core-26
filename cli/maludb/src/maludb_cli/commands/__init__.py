"""Subcommand modules for the maludb CLI.

Each module exports a `register(subparsers)` function that adds its
top-level parser, wires sub-subparsers if applicable, and binds
args.handler to a function `fn(args) -> int`.
"""
