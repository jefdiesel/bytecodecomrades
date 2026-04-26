# Bytecode Comrades — viewer

Pure static page. Reads a Comrade from any deployed `Comrade404` contract.

- Asks for an Alchemy API key on first visit (stored in `localStorage`, never committed)
- Calls `tokenURI(uint256)` via JSON-RPC `eth_call`
- Decodes the data URI and renders the SVG inline

## Deploy

```
vercel deploy --prod
```

Or push to the connected GitHub repo and Vercel auto-deploys.

## Structure

- `index.html` — single-file UI + JS
- `vercel.json` — security headers, clean URLs
