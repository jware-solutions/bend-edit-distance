#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=$(tr -d '\r\n' < "$root/version.txt")
[[ -n $version ]] || { echo 'version.txt is empty.' >&2; exit 2; }

cd "$root"
exec bend lib.bend --publish "bend-edlib@$version"
