# Islamic Gold Dollar (IGD) Treasury Protocol 🌟

An algorithmic, dynamic-supply Real-World Asset (RWA) protocol that establishes a secure, share-based commodity savings matrix natively on public EVM Layer-2 ledgers. 

## 💡 The Core Innovation

Most traditional tokenized gold instruments (such as Tether Gold - XAUT) require managing complex, fractional decimal assets (e.g., `0.0114 XAUT`) and enforce massive financial thresholds ($200,000+ min.) to exit into physical gold. 

**IGD disrupts this friction.** It acts like a decentralized, gold-indexed dollar checking account. Users deposit a standard stablecoin (USDT) and mint tokens. However, instead of a standard rebasing mechanism that physically removes or adds token numbers to a wallet (causing user friction), IGD uses a **Share-Based Value-Accruing Engine**. The number of tokens in the user's wallet stays fixed, while the individual unit price of the token appreciates based on a dual-growth driver: the live global price of gold + the platform's transaction velocity.

---

## ⚙️ Architecture & Technical Features

### 1. Elastic Supply Mint/Burn Mechanism (0 to Infinity)
The protocol initializes on the public ledger with a circulating supply of exactly **0 tokens**. Tokens are only generated via instant spot transactions when real USDT capital enters the contract, and they are permanently burned out of existence upon redemption. This guarantees that the protocol is 100% asset-backed from block zero.

### 2. Solution 1: Zero-Loss DEX Aggregator Routing
To prevent frontrunning bots (MEV exploits) and capital slippage deficits, the smart contract does not rely on a standalone liquidity pool. The protocol automatically connects with **DEX Aggregators (like the 1inch Router)** to dynamically split, route, and execute market purchases of underlying XAUT across the deepest public liquidity pools simultaneously.

### 3. Solution 3: Velocity Perimeter Cap Control
The contract logic contains a strict single-transaction speed-bump parameter (e.g., maximum 5,000 USDT per block swap). This insulates the protocol vault from massive whale price impact distortions and secures the collateral backing ratio during intense market volatility.

### 4. Dual-Directional Algorithmic Spread Capture
The protocol features a **0% visible front-end transaction fee structure** to maximize retail user marketing adoption. Instead, the contract embeds a tight **0.25% algorithmic spread** directly into both the buy (mint) and sell (burn) execution layers. 

---

## 📊 The Math: Dual-Value Accrual Formula

When a transaction executes, the contract automatically slices away the 0.25% spread surplus and traps it natively inside the `protocolTreasuryVault` as a permanent capital buffer. 

The live chart price of an individual token is calculated dynamically using this structural formula:

$$\text{Individual IGD Price} = \text{Current Gold Spot Price} \times \left( \frac{\text{Total USDT Value inside Protocol Treasury Vault}}{\text{Total Supply of Circulating IGD Tokens}} \right)$$

### Real-World Example:
1. **Day 1:** Users deposit **5,000 USDT**. The contract extracts a 0.25% spread ($12.50) into the treasury vault, and swaps the remaining $4,987.50 for **1.1418 XAUT** gold backing tokens on a DEX aggregator. The contract mints **5,000 IGD tokens**. Starting unit price is **$1.00**.
2. **Day 30 (Gold Flat at $4,368):** High platform trading volume takes place throughout the month, generating **$50,000 in total swap volume**. The algorithmic spread engine automatically captures 0.25% across this volume, adding **$125.00 USDT** in cash straight to the protocol treasury buffer.
3. **The New Price Calculation:**
$$\text{Individual Price} = \frac{\text{Gold Assets } (\$4,987.50) + \text{Treasury Cash } (\$12.50 + \$125.00)}{5,000 \text{ Circulating Tokens}} = \mathbf{\$1.025 \text{ USDT}}$$

*Even though the global spot price of gold did not move by a single penny, individual token value rose independently to $1.025 purely driven by the processing velocity of the protocol.*

---

## 🏛️ Shariah Compliance Matrix (Islamic Mu'amalat)

The system operates strictly within the boundaries of Islamic Finance jurisprudence:
* **Bay' al-Sarf (Spot Exchange):** Transactions settle instantly on-chain. No forward contracts, deferred payments, or margin loans are permitted.
* **Elimination of Riba & Gharar:** Bypasses interest, debt metrics, and speculative betting structures entirely.
* **Wakalah (Non-Custodial Agency):** The smart contract functions completely transparently as an automated non-custodial agent (*Wakeel*) executing trades on behalf of the user.

---

## 🚀 Current Project Status & Roadmap

This project is currently **under active development**. 
* **Phase 1 (Current):** Core smart contract logic completed. Sandbox testing underway on the **Arbitrum Sepolia** public testnet.
* **Phase 2:** Finalizing frontend dApp injection parameters using EIP-747 `wallet_watchAsset` standards for wallet UI displays.
* **Phase 3:** Third-party smart contract security auditing and formal Shariah Board *Fatwa* application review.

### 🛠️ Developer Installation & Local Testnet Run
To compile and test the contract parameters inside a local workspace:
```bash
npm install @openzeppelin/contracts
npx hardhat compile
```

## 📄 License
This project is open-source software licensed under the [MIT License](LICENSE).
