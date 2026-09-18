#!/bin/sh
# Thin wrapper kept for existing CI scripts; the flow lives in `mix test.qlover`.
exec mix test.qlover "$@"
