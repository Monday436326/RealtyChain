# RealtyChain
A comprehensive DeFi system for tokenizing real estate properties using ERC1155 tokens with integrated Chainlink oracles for automated valuation, yield distribution, and cross-chain functionality.

A fully decentralized real estate tokenization system that fractionalizes properties as ERC1155 tokens. The protocol integrates advanced DeFi primitives such as yield distribution, automated property valuation, and cross-chain transfers. Built on Solidity, it leverages Chainlink's suite of services — Functions, VRF, Automation, and CCIP — to enable secure, scalable, and intelligent property-backed investment opportunities across chains.

Deployed Addresses (Sepolia):

Property Token: 0x4E232889A8be96B5b328B1A7466eF1931541Cbd2

Property Vault: 0xAc8d72994d3075367B15894e5dF2c0af6be11FCc

CrossChain Manager: 0xf01eEC8715591EAFadb3631A17c3e217dcbCe3F1

---

## 🧱 Tech Stack & Architecture

- **Smart Contract Language**: Solidity ^0.8.20
- **Token Standard**: ERC1155 (multi-token standard for fractional ownership)
- **Security**: OpenZeppelin Contracts v5 (Ownable, ReentrancyGuard, Pausable)
- **Chainlink Integrations**:
  - [Chainlink Functions](https://docs.chain.link/chainlink-functions) — external valuation oracles
  - [Chainlink VRF](https://docs.chain.link/vrf) — randomness for lottery/fair launches
  - [Chainlink Automation](https://docs.chain.link/automation) — scheduled distributions and valuations
  - [Chainlink CCIP](https://docs.chain.link/ccip) — cross-chain token movement

### 🔌 Chainlink-Integrated Contract Files
- [`contracts/PropVault.sol`](contracts/PropVault.sol) — Functions, VRF, Automation
- [`contracts/Cross-Chain.sol`](contracts/Cross-Chain.sol) — CCIP
- [`contracts/PropToken.sol`](contracts/PropToken.sol) — Token registry, integrates with Vault and Manager

---

## 🏗️ Core Architecture

The system consists of three modular smart contracts:

### 1. `PropertyToken.sol`
- ERC1155-compliant contract for fractional property ownership.
- Allows tokenization of real estate assets with associated metadata.
- Tracks ownership, share price, and allows secure transfer of shares.
- Implements pausable functionality and admin controls.

Key Functions:
- `tokenizeProperty()`: Tokenizes a new property.
- `purchaseShares()`: Public sale of fractional property shares.
- `getSharePrice()`: Computes price per share based on latest valuation.
- `updatePropertyValuation()`: Updates valuation (via Chainlink Functions).

---

### 2. `PropertyVault.sol`
- Manages rental income, yield distribution, ROI tracking, and fee collection.
- Chainlink Functions: Fetches live market data to update property values.
- Chainlink VRF: Generates randomness for fair-launch and investor lotteries.
- Chainlink Automation: Handles monthly yield distributions on-chain.

Key Functions:
- `depositRent()`: Property owner deposits monthly rent.
- `distributeYield()`: Distributes rental income proportionally.
- `claimYield()`: Allows investors to claim accrued yield.
- `requestPropertyValuation()`: Requests up-to-date valuation via Functions.

---

### 3. `CrossChainManager.sol`
- Enables cross-chain transfer of property tokens using Chainlink CCIP.
- Facilitates multi-chain property portfolios and token liquidity.
- Manages trusted remotes and calculates CCIP gas fees.

Key Functions:
- `initiateCrossChainTransfer()`: Sends fractional tokens to another chain.
- `getCCIPFee()`: Calculates CCIP cost for a transaction.
- `setTrustedRemote()`: Admin function to link remote contract addresses.

---

## 💰 Tokenomics

Each property is divided into **10,000 shares**:

| Allocation | Description |
|------------|-------------|
| **87%**    | Public investors (8,700 shares)  
| **10%**    | Property owner (1,000 shares)  
| **3%**     | Platform treasury (300 shares)  

### Fee Breakdown
- **Platform Fee**: 2% on share purchases
- **Management Fee**: 1% on rent collected
- **Performance Fee**: 10% on distributed yield

---

## 🔗 Chainlink Utilities Overview

| Integration       | Purpose                                                      |
|-------------------|--------------------------------------------------------------|
| **Functions**     | Oracle-based valuation updates from external APIs            |
| **VRF**           | Random property selection for gamification/fair access       |
| **Automation**    | Periodic tasks like rent distribution or valuation refresh   |
| **CCIP**          | Cross-chain share transfers & inter-chain token registry     |

---

## 📊 Yield Distribution Lifecycle

1. Owner deposits rent using `depositRent()`
2. Vault deducts platform fees and calculates net distribution
3. Monthly yield is stored and can be claimed by investors
4. Automation triggers yield distribution if enabled
5. Investors call `claimYield()` to receive their yield

---

## 🌐 Cross-Chain Property Management

- Transfer property shares between EVM-compatible chains.
- Maintains consistent token ID and metadata on destination chain.
- Supports multi-chain investment portfolios and decentralized ownership.

Setup:
1. Deploy all contracts on each target chain.
2. Link contracts via `setTrustedRemote(chainSelector, remoteAddress)`.
3. Fund CCIP with LINK and native gas tokens.
4. Use `initiateCrossChainTransfer()` to move fractional tokens.

---

## 📈 Usage Examples

### Tokenizing a Property
```solidity
uint256 propertyId = token.tokenizeProperty(
    "123 Main St, New York, NY",
    "10001",
    1000000e18,
    5000e18,
    PropertyToken.PropertyType.Residential,
    "https://api.example.com/property/1",
    propertyOwnerAddress
);
````

### Purchasing Shares

```solidity
uint256 cost = token.getSharePrice(propertyId) * 100;
token.purchaseShares{value: cost}(propertyId, 100);
```

### Claiming Yield

```solidity
uint256 yield = vault.calculateClaimableYield(investor, propertyId);
vault.claimYield(propertyId);
```

---

## 🛡️ Security & Safeguards

* **Access Control**: Role-based restrictions for sensitive operations
* **Circuit Breakers**: Emergency `pause()`/`unpause()` controls
* **Reentrancy Protection**: All payable or state-mutating functions
* **Oracle Verification**: Only responses from verified Chainlink nodes are accepted
* **Cross-Chain Trust**: Validated source/destination via `trustedRemotes`
