#!/usr/bin/env bash
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "@ZIG_BIN@" rc "$@"
