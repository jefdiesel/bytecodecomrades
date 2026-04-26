#!/usr/bin/env bash
# Extract CryptoPunksData palette + assets + names from mainnet storage via cast.
set -uo pipefail

RPC="https://ethereum-rpc.publicnode.com"
ADDR="0x16F5A35647D6F03D5D3da7b35409D65ba03aF3B2"
OUT="$(dirname "$0")"

# add integer N to a 64-hex-char slot value
add_hex() {
  local hex=${1#0x}
  local n=$2
  local sum
  sum=$(echo "ibase=16; obase=16; $(echo "$hex" | tr 'a-f' 'A-F') + $n" | bc | tr -d '\\\n' | tr 'A-F' 'a-f')
  printf "0x%064s" "$sum" | tr ' ' '0'
}

mapping_slot() {
  local key=$1 mslot=$2
  cast keccak "0x$(printf "%064x" "$key")$(printf "%064x" "$mslot")"
}

read_bytes() {
  local hdr_slot=$1
  local raw last2 last_byte len len_enc data_start n_slots out i slot val
  raw=$(cast storage "$ADDR" "$hdr_slot" --rpc-url "$RPC" 2>/dev/null)
  raw=${raw#0x}
  if [[ -z "$raw" || "$raw" == "0000000000000000000000000000000000000000000000000000000000000000" ]]; then
    echo ""
    return
  fi
  last2=${raw:62:2}
  last_byte=$((16#$last2))
  if (( last_byte % 2 == 0 )); then
    len=$((last_byte / 2))
    if (( len == 0 )); then echo ""; return; fi
    echo "${raw:0:$((len*2))}"
  else
    len_enc=$((16#${raw:48:16}))
    len=$(( (len_enc - 1) / 2 ))
    data_start=$(cast keccak "$hdr_slot")
    n_slots=$(( (len + 31) / 32 ))
    out=""
    for ((i=0; i<n_slots; i++)); do
      slot=$(add_hex "$data_start" "$i")
      val=$(cast storage "$ADDR" "$slot" --rpc-url "$RPC" 2>/dev/null)
      out="${out}${val#0x}"
    done
    echo "${out:0:$((len*2))}"
  fi
}

# 1. Palette (slot 0)
echo "[*] palette ..." >&2
PALETTE=$(read_bytes "0x0000000000000000000000000000000000000000000000000000000000000000")
echo "$PALETTE" > "$OUT/palette.hex"
echo "    $((${#PALETTE} / 2)) bytes" >&2

# 2. Assets (mapping slot 1) + names (mapping slot 2)
echo "[*] assets + names ..." >&2
echo "{" > "$OUT/assets.json"
FIRST=1
EMPTY_RUN=0
for i in $(seq 0 174); do
  ASSET_SLOT=$(mapping_slot "$i" 1)
  NAME_SLOT=$(mapping_slot "$i" 2)
  ASSET=$(read_bytes "$ASSET_SLOT")
  NAME=$(read_bytes "$NAME_SLOT")
  if [[ -z "$ASSET" && -z "$NAME" ]]; then
    EMPTY_RUN=$((EMPTY_RUN + 1))
    if (( EMPTY_RUN > 5 && i > 100 )); then
      echo "    stopping after $EMPTY_RUN empties at index $i" >&2
      break
    fi
    continue
  fi
  EMPTY_RUN=0
  NAME_ASCII=$(echo -n "$NAME" | xxd -r -p 2>/dev/null || echo "?")
  if (( FIRST == 0 )); then echo "," >> "$OUT/assets.json"; fi
  FIRST=0
  printf '  "%d": {"name": %s, "hex": "%s"}' "$i" "$(printf '%s' "$NAME_ASCII" | jq -Rs .)" "$ASSET" >> "$OUT/assets.json"
  echo "    [$i] $((${#ASSET} / 2))b '$NAME_ASCII'" >&2
done
echo "" >> "$OUT/assets.json"
echo "}" >> "$OUT/assets.json"

ENTRIES=$(grep -c '"name":' "$OUT/assets.json" || echo 0)
echo "[*] done. $ENTRIES asset entries written." >&2
