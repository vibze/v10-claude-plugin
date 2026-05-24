#!/bin/bash
# Hook: Stop (sibling to stop.sh)
# Emits a cumulative token-usage frame on the "usage" channel by
# re-scanning the session transcript JSONL on every turn.
#
# Must never block Claude. Always exit 0.

set +e
source "$(dirname "$0")/_lib.sh"

payload=$(cat)

transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)

# Nothing to do if we can't find the transcript.
[[ -z "$transcript_path" ]] && exit 0
[[ ! -s "$transcript_path" ]] && exit 0

# One-pass jq:
#   - Filter assistant lines that carry .message.usage.
#   - Sum the four token counts.
#   - Record the latest model seen and a turn count.
#   - Emit {model, tokens, turns}.
agg=$(jq -s '
  map(select(.message.usage)) as $rows
  | {
      model: ( ($rows | last | .message.model) // "unknown" ),
      turns: ($rows | length),
      tokens: {
        input:          ($rows | map(.message.usage.input_tokens // 0)               | add // 0),
        output:         ($rows | map(.message.usage.output_tokens // 0)              | add // 0),
        cache_creation: ($rows | map(.message.usage.cache_creation_input_tokens // 0)| add // 0),
        cache_read:     ($rows | map(.message.usage.cache_read_input_tokens // 0)    | add // 0)
      }
    }
' "$transcript_path" 2>/dev/null)

[[ -z "$agg" ]] && exit 0

# Compute cost using an embedded price table (USD per million tokens).
# Falls back to Sonnet pricing for unknown models and notes the substitution.
data=$(printf '%s' "$agg" | jq '
  . as $a
  | ($a.model // "unknown") as $m
  | {
      "claude-opus-4":   {input:15,   output:75,   cache_creation:18.75, cache_read:1.50},
      "claude-sonnet-4": {input:3,    output:15,   cache_creation:3.75,  cache_read:0.30},
      "claude-haiku-4":  {input:1,    output:5,    cache_creation:1.25,  cache_read:0.10}
    } as $prices
  | (
      if   ($m | test("^claude-opus-4"))   then {family:"claude-opus-4",   sub:false}
      elif ($m | test("^claude-sonnet-4")) then {family:"claude-sonnet-4", sub:false}
      elif ($m | test("^claude-haiku-4"))  then {family:"claude-haiku-4",  sub:false}
      else {family:"claude-sonnet-4", sub:true}
      end
    ) as $pick
  | $prices[$pick.family] as $p
  | ( ($a.tokens.input          * $p.input
       + $a.tokens.output         * $p.output
       + $a.tokens.cache_creation * $p.cache_creation
       + $a.tokens.cache_read     * $p.cache_read) / 1000000.0
    ) as $cost
  | {
      model:    $a.model,
      tokens:   $a.tokens,
      cost_usd: ($cost | . * 1000000 | round / 1000000),
      turns:    $a.turns
    }
  + (if $pick.sub then {model_priced_as: "sonnet"} else {} end)
' 2>/dev/null)

[[ -z "$data" ]] && exit 0

send_frame "usage" "Update" "$data"
exit 0
