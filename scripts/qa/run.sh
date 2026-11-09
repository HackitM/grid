#!/bin/zsh
# QA helpers for a DEBUG build launched with `open build/GRID.app --args --qa`.
# Build the controller first: swiftc -O -o build/gridctl scripts/qa/gridctl.swift
# Source this file: `source scripts/qa/run.sh`
GRIDCTL="$(dirname ${(%):-%x})/../../build/gridctl"
QA_OUT="${QA_OUT:-/tmp/grid-qa}"
mkdir -p "$QA_OUT"
g()     { "$GRIDCTL" "$1"; }
gtype() { python3 -c 'import json,sys; print(json.dumps({"cmd":"type","text":sys.argv[1]}))' "$1" | xargs -0 "$GRIDCTL"; }
gsnap() { "$GRIDCTL" "{\"cmd\":\"screen\",\"path\":\"$QA_OUT/$1.png\"}"; sleep 0.6; echo "$QA_OUT/$1.png"; }
gstate(){ "$GRIDCTL" "{\"cmd\":\"state\",\"path\":\"$QA_OUT/state.json\"}"; sleep 0.5; cat "$QA_OUT/state.json"; }
gscreen(){ "$GRIDCTL" "{\"cmd\":\"state\",\"path\":\"$QA_OUT/state.json\"}"; sleep 0.5; python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); a=[x for x in s["sessions"] if x["number"]==s["active"]][0]; print("\n".join(l for l in a["screen"] if l.strip()))' "$QA_OUT/state.json"; }
