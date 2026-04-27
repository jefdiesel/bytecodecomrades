# Bytecode Comrades

**On-chain pixel art. Procedurally generated. Born from Uniswap v4 swaps.**

A 10,000-piece NFT collection that lives entirely inside Ethereum. No IPFS, no servers, no CDN. Every pixel of every Comrade is rendered from sprite data stored directly in deployed contracts. If Ethereum exists, the art exists.

The collection is built as an **ERC-20/ERC-721 hybrid (404)** so each whole COMRADE token doubles as a Comrade NFT — they're joined at the hip. You can trade Comrades fluidly via Uniswap, OR claim them into a permanent ERC-721 form for OpenSea listings. Each holder picks the mode that fits.

A homage to [Call Data Comrades](https://callcomrades.xyz/) (CC0): we use the original CDC trait sprite library, with rarity weights matching CDC's actual distribution from 9,962 items.

---

## How a Comrade gets its art

1. You buy 1 COMRADE on Uniswap.
2. The v4 hook fires `afterSwap` — increments a seed counter, mixes in `block.prevrandao` + your address, derives a fresh seed.
3. The Comrade404 contract mints a new 404 NFT to your wallet with that seed.
4. `tokenURI(id)` reads the seed → picker derives 5–9 trait sprite IDs (BG, Type, Skin, Cloths, Audio, Mouth, Eyes, Head, Relics) weighted by CDC frequency → renderer composites them with Porter-Duff alpha blending into a 32×32 SVG → wrapped in JSON metadata.

**Bloom filter dedup at mint:** every roll is fingerprinted and rejected if it would clone an existing CDC or CRC piece. False-positive rate ≈ 10⁻⁹.

---

## The three modes

| Mode | Cost | Behavior |
|---|---|---|
| **Speculator** | nothing beyond Uniswap fees | Trade COMRADE on Uniswap, ignore the NFT side. Each buy mints fresh art, each sell burns it. |
| **Hodler** | nothing | Buy 1 COMRADE, get a random Comrade. Hold forever. The art lives in your wallet as long as you hold the token. |
| **Collector** | 0.001111 ETH (~$3.50) per claim | Claim a Comrade you love into a permanent ERC-721. List it on OpenSea / Blur. Stable forever. |

A holder can switch modes at any time. Nothing is locked in.

---

## Claim / unclaim

```
Claim:    pay 0.001111 ETH → 404 NFT burns, 1 BCC locks in contract,
          a new ERC-721 with frozen seed mints to your wallet
Unclaim:  pay 0.0069 ETH → ERC-721 burns, 1 BCC released, fresh 404 NFT
          minted to you with the same original seed (art preserved)
```

**Why the asymmetry?** Cheap to enter the stable side, expensive to leave. The unclaim fee is a moat against destroying art for short-term arb, and revenue for the treasury. Most claimed NFTs accrete and stay claimed; the floor stays liquid for traders.

When a Claimed NFT is sold on OpenSea, the underlying 1 BCC stays locked. The new owner can hold the NFT or unclaim to recover the BCC.

---

## A seed's possible lifespans

```
swap-mint → new seed S generated
   ↓
holder might claim → S frozen into a Claimed ERC-721 (permanent)
   ↓
buyer on OpenSea takes the Claimed NFT
   ↓
buyer might unclaim → S resurrected as a 404 NFT
   ↓
buyer might sell BCC on Uniswap → 404 NFT burned, S DIES
```

- **1 life:** bought-then-sold without claiming. Common case.
- **2 lives:** claimed once. Lives forever as long as the Claimed NFT exists.
- **3+ lives:** claimed → unclaimed → sold. Last life is short.

---

## Genesis

A single soulbound NFT (`ComradeGenesis`), auto-minted at deploy to the wallet that owned **CDC #1** at the snapshot. Same Background, Mouth, and Eyes as the original (Sir Pinkalot, Beard of the Gods, Aviators), with Alien People type + Hardbass Uniform — a tribute to the OG CDC holder. Cannot be transferred, sold, or burned. One forever.

---

## The Uniswap v4 hook

The pool is COMRADE/WETH at the 0.3% tier. The hook (`ComradeHook`) implements `afterSwap` with `RETURNS_DELTA`:

- Re-rolls the on-chain seed every swap (every transaction drives entropy)
- Skims **0.1%** of the swap output as protocol fee, accumulated as ERC-6909 claim tokens
- Owner sweeps via `withdrawFees(currency, recipient, amount)`

The `afterSwap` call mints its 6909 claim in-line so the unlock closes cleanly with zero unsettled deltas. Caught and fixed before mainnet during e2e testing on Sepolia.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                  Uniswap v4 PoolManager                  │
│                          │                               │
│                  Comrade/WETH pool                       │
│                          │                               │
│                  ComradeHook ──── seed source            │
└──────────────────────────┬───────────────────────────────┘
                           │ afterSwap
                           ▼
┌──────────────────────────────────────────────────────────┐
│                      Comrade404                          │
│   ERC-20 + ERC-721 hybrid. Holds the canonical seeds.    │
│       ↓ tokenURI(id)                ↑ claim() / unclaim()│
└──────────────────────────┬───────────┬───────────────────┘
                           │           │
                  ┌────────┴───┐   ┌───┴──────────────┐
                  │            │   │                  │
                  ▼            ▼   ▼                  ▼
           ComradeRenderer   ComradeBloom    ComradeClaimed (ERC-721)
                  │              │
       ┌──────────┴────────┐    ┌┴───────────┐
       │                   │    │            │
       ▼                   ▼    ▼            ▼
ComradeSpriteData   ComradeTaxonomy  BloomChunk0  BloomChunk1
       │
   ┌───┴────┐
   ▼   ...  ▼
 SpriteChunk0..4
```

- **Sprite chunks (5):** ~18 KB each. Their bytecode IS the RLE-encoded pixel data.
- **Bloom chunks (2):** ~18 KB each. Hold the 9962 CDC + 1366 CRC trait fingerprints.
- **SpriteData / Taxonomy / Renderer:** pure-logic contracts that read the chunks.
- **Comrade404:** the hybrid token. ERC-20 transfers auto-mint/burn 404 NFTs on whole-token boundaries.
- **ComradeClaimed:** standard ERC-721 (`name = "Bytecode Comrades"`, `symbol = "BCC"`). Mint via `Comrade404.claim()`. Renderer pointer is mutable (gated to Comrade404 owner).
- **ComradeGenesis:** single-token soulbound. CDC #1 homage.

---

## On-chain art guarantee

When OpenSea pulls a token's metadata, the call chain is:

```
OpenSea → ComradeClaimed.tokenURI(id)
       → ComradeRenderer.tokenURI(id, seed)
       → reads sprite chunks, composites SVG
       → returns "data:application/json;utf8,{...,\"image\":\"data:image/svg+xml;utf8,<svg>...</svg>\",...}"
```

No `ipfs://`, no `https://`, no off-chain calls. The art renders from a single `eth_call`. If every CDN on the planet went dark tomorrow, every Comrade would still render correctly to anyone with an Ethereum RPC.

---

## Inheritance from CDC

We use CDC's actual trait frequencies as picker weights — Sir Pinkalot is common because it was common in CDC, Royal Purple is rare because it was rare in CDC. Same for Type, Cloths, Mouth, Eyes, Head, Audio, Skin Stuff, Relics.

7 of CDC's animated/special traits aren't included (Matrix Animated, Lava, Rainbow Mayhem, Jazz, Nyan Goggles, Genuine Unjaw, Floored Ape Theory) — we don't have static sprite frames for them. Their CDC frequencies were small (combined < 0.5%), so the impact is minimal.

CDC has no mutual-exclusion rules between traits — every trait can co-occur with every other (verified empirically from 9962 items). We mirror that: independent sampling, no exclusions, full combinatorial freedom.

---

## Fees

| Fee | Default | Recipient | Purpose |
|---|---|---|---|
| Swap (afterSwap hook) | 0.1% of output | Hook owner | Per-swap protocol fee |
| Claim | 0.001111 ETH | Treasury | Wrap into permanent ERC-721 |
| Unclaim | 0.0069 ETH | Treasury | Unwrap back to 404 (moat against art destruction) |

All fees adjustable by owner via setter functions.

---

## Local development

```bash
# Build + test
forge build
forge test

# Render a sample Comrade locally (writes samples/comrade_0.svg)
forge test --match-test test_render_item_zero_to_disk -vv

# Regenerate sprite contracts from data/sprite_blob.hex (only if you tweak the encoder)
python3 data/gen_sprite_sol.py
```

### Deploy

```bash
# Full stack — sprite chunks, taxonomy, renderer, bloom, hook (CREATE2 salt-mined),
# Comrade404, Genesis. Deploys defensively: reverts if BCC's predicted address >= WETH.
forge script script/DeployComrade.s.sol \
  --rpc-url $RPC --private-key $DEPLOY_PRIVATE_KEY --broadcast

# Initialize the v4 pool with the weighted-curve LP plan ($1 → $1111).
# PAIR must be WETH (not native ETH) so BCC = token0.
COMRADE=<bcc-addr> PAIR=<weth-addr> POOL_MANAGER=<v4-pm> HOOK=<hook-addr> ETH_USD=3000 \
forge script script/InitComradePool.s.sol \
  --rpc-url $RPC --private-key $DEPLOY_PRIVATE_KEY --broadcast

# Add LP positions via Uniswap UI using the printed (tickLower, tickUpper, BCC amount).
```

### Site

The viewer is a static HTML/JS app served by Vercel. Read RPC calls go through `site/api/rpc.js` (Alchemy key in env vars, never exposed to the browser). Wallet writes use `window.ethereum` directly.

```bash
cd site && vercel deploy --prod
```

Live: https://site-nine-ashy-38.vercel.app

---

## License

CC0 — same as the CDC trait library this is built on. Public domain. Do whatever you want.
