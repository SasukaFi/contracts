# Sasuka — Contracts

Smart contracts for [Sasuka](https://github.com/SasukaFi), the frost battle royale on Avalanche.

## How It Works

Players stake AVAX to enter a room. Each tick, they pick one of three abilities:

| Ability | Effect |
|---------|--------|
| **Ice Shield** | Blocks all damage |
| **Blizzard** | 10 dmg to all. 20 to exposed Avalanche users |
| **Avalanche** | 40 dmg to one target. Blocked by Shield |

Moves are committed as hashes, then revealed. No front-running. No cheating.

Last one standing claims the pot minus 3% protocol fee.

## Contracts

- **SasukaGame.sol** — Room creation, join, commit-reveal, tick resolution, damage calc, winner payout
- **SasukaTreasury.sol** — Collects protocol fees. Owner-withdrawable

## Stack

- Solidity 0.8.24
- Hardhat + TypeScript
- OpenZeppelin (Ownable, ReentrancyGuard)
- Avalanche C-Chain (Fuji testnet)

## Get Started

```bash
npm install
npx hardhat compile
npx hardhat test
```

## Deploy

```bash
export PRIVATE_KEY=your_private_key
npm run deploy:fuji
```

## License

MIT
