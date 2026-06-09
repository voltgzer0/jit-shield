# JITShield Landing Page

Single-file static landing. No build step. No deps. Open `index.html` and it works.

## Local preview

```bash
# inside WSL or any *nix
cd landing && python3 -m http.server 8765
# → open http://localhost:8765
```

Or just double-click `index.html`.

## Deploy to GitHub Pages (free, recommended)

Once the repo is pushed to `github.com/voltgzer0/jit-shield`:

1. Repo → Settings → Pages
2. Source: **Deploy from a branch**
3. Branch: `main` · folder: `/landing`
4. Save. The URL appears within 30 s as `https://voltgzer0.github.io/jit-shield/`.

Custom domain (optional): add a `CNAME` file in `landing/` with the domain, point its DNS
CNAME record to `voltgzer0.github.io`.

## Deploy to Vercel (also free)

```bash
# from project root
npx vercel deploy landing/ --prod
```

## Updating

Edit `index.html`. Push to `main`. GitHub Pages re-publishes within a minute.

## What to change for new deploys

When the hook moves from Sepolia to mainnet, search-replace in `index.html`:

- `0xca2f96f95c9E7a2109ecbD64bf80F7Cf77d86ac8` → new hook address
- `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` → mainnet PoolManager address
- `sepolia.etherscan.io` → `etherscan.io`
- `Sepolia · chain 11155111` → `Ethereum · chain 1`
- token addresses + tx hashes in the Live card and the proof section

## License

The landing markup is MIT, same as the rest of the repo.
