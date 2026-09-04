#!/usr/bin/env bash
# ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
# ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
# └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
# https://github.com/kbuckleys/
#
# One-shot privacy/status probe. Emits a single JSON line:
#   {"mic":0,"screen":0,"recording":0}
#
# mic       an application is actively capturing audio
# screen    a screencast pipeline is live (portal share, browser call, ...)
# recording wf-recorder is running — the same process the hypr bind toggles

mic=0
screen=0
recording=0

# One pw-dump serves both stream checks. Only nodes in the `running` state
# count; apps that merely hold a stream open sit at idle/suspended and must
# not light the indicator.
if dump="$(pw-dump 2>/dev/null)"; then
  read -r mic screen <<<"$(
    printf '%s' "$dump" | jq -r '
      [ .[]
        | select(.type == "PipeWire:Interface:Node")
        | select(.info.state == "running")
        | .info.props["media.class"] // ""
      ] as $live
      | [ ($live | map(select(. == "Stream/Input/Audio")) | length | if . > 0 then 1 else 0 end),
          ($live | map(select(startswith("Stream/") and endswith("/Video"))) | length | if . > 0 then 1 else 0 end)
        ] | @tsv
    ' 2>/dev/null
  )"
  mic=${mic:-0}
  screen=${screen:-0}
fi

pgrep -x wf-recorder >/dev/null 2>&1 && recording=1

printf '{"mic":%d,"screen":%d,"recording":%d}\n' "$mic" "$screen" "$recording"
