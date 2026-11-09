# Stoxes.fun

A token launchpad built and deployed on **BNB Smart Chain (BSC)** that connects new token launches to native BNB burns, a reserve with burn-to-redeem, bStock-paired (tokenized equity) launches, and contributions to BNC that the platform tracks.

This repository contains the official smart contracts for Stoxes.fun. All production contracts are deployed on **BNB Smart Chain Mainnet (chain ID 56)**, and their source code is verified on BscScan. Live app: [stoxes.fun](https://stoxes.fun)

## Technology Stack

- **Blockchain**: BNB Smart Chain (BSC)
- **Smart Contracts**: Solidity ^0.8.26 (solc 0.8.26, optimizer 200 runs, EVM `cancun`)
- **DEX Integration**: PancakeSwap V2 and V3 on BNB Smart Chain, WBNB
- **Frontend**: React + Vite + viem (live at [stoxes.fun](https://stoxes.fun))
- **Development**: Foundry (forge), forge-std, OpenZeppelin Contracts Upgradeable 4.9.6
- **Verification**: BscScan (Exact Match source verification)

## Supported Networks

- **BNB Smart Chain Mainnet** (Chain ID: 56). Production deployment.
- **BNB Smart Chain Testnet** (Chain ID: 97). Used for development and testing only; there is no public testnet deployment.

Network configuration lives in [`bnbconfig.json`](bnbconfig.json) and [`foundry.toml`](foundry.toml). The only configured networks are BSC and BSC Testnet.

## Contract Addresses

All addresses below are on **BNB Smart Chain Mainnet (Chain ID 56)** and are verified on BscScan as Exact Match. The machine-readable list is in [`deployments/bsc-mainnet.json`](deployments/bsc-mainnet.json).

### Core

| Contract | Role | BNB Mainnet Address |
|----------|------|---------------------|
| StoxesBnbFactory | Launch entry point and token deployment | [`0xdfb1afc6dabcbc23e5a3fd09c8a0137112f58f96`](https://bscscan.com/address/0xdfb1afc6dabcbc23e5a3fd09c8a0137112f58f96#code) |
| StoxesBnbPortal | Bonding curve trading in BNB or a bStock | [`0xbe446b5baaaa003121b1196b01a1476a1ccaacc0`](https://bscscan.com/address/0xbe446b5baaaa003121b1196b01a1476a1ccaacc0#code) |
| StoxesBnbPortalMath | Linked library for tax and price math | [`0x73889a4fe8dc506493066bf3208386b59e7bdf10`](https://bscscan.com/address/0x73889a4fe8dc506493066bf3208386b59e7bdf10#code) |
| StoxesBnbGraduator | Graduation to PancakeSwap liquidity | [`0xa9f53edfa4b7445ef40e7b12a17733080efc200d`](https://bscscan.com/address/0xa9f53edfa4b7445ef40e7b12a17733080efc200d#code) |
| StoxesBnbV3Locker | Permanent custody of PancakeSwap V3 LP positions | [`0xa4e73d18e0e9d241aa6851c46053e22941b03903`](https://bscscan.com/address/0xa4e73d18e0e9d241aa6851c46053e22941b03903#code) |
| StoxesBnbTaxProcessor | Trading-fee harvest and routing | [`0xfebd1f41fcd25212b43d3d8710e2ea0824e57962`](https://bscscan.com/address/0xfebd1f41fcd25212b43d3d8710e2ea0824e57962#code) |
| StoxesBnbLens | Read-only token state for apps and indexers | [`0x1fcc878aa095a8a33c67b2397330e5ffb00213f6`](https://bscscan.com/address/0x1fcc878aa095a8a33c67b2397330e5ffb00213f6#code) |

### Token Implementations

| Contract | Role | BNB Mainnet Address |
|----------|------|---------------------|
| StoxesBnbRenounceableTaxToken | Implementation for tax launches | [`0x06238d098a29c34a992e678733e86d25c5602046`](https://bscscan.com/address/0x06238d098a29c34a992e678733e86d25c5602046#code) |
| StoxesBnbSimpleToken | Implementation for simple launches | [`0x201F2230015D9d99293555EcB9A8887cc4963D97`](https://bscscan.com/address/0x201F2230015D9d99293555EcB9A8887cc4963D97#code) |

### Vault Factories

| Contract | Role | BNB Mainnet Address |
|----------|------|---------------------|
| StoxesBnbNativeBurnVaultFactory | Native BNB Burn vaults | [`0xF79e18AC2A766a7E9D1Cd513C24B32f54CFb2A38`](https://bscscan.com/address/0xF79e18AC2A766a7E9D1Cd513C24B32f54CFb2A38#code) |
| StoxesBnbAdminFloorReserveVaultFactory | Floor Reserve vaults | [`0x1d1a1ae8782f502f55a9fe0eb95b87fc8f14fd99`](https://bscscan.com/address/0x1d1a1ae8782f502f55a9fe0eb95b87fc8f14fd99#code) |
| StoxesBnbRoutedStocksVaultFactory | bStocks holder-reward vaults | [`0x51c6f2f6c438d1264a8ec0b43ec385214112c1c9`](https://bscscan.com/address/0x51c6f2f6c438d1264a8ec0b43ec385214112c1c9#code) |
| StoxesBnbBuybackBurnVaultFactory | Token buyback and burn vaults | [`0x77e535f92635616a848d0cc2584d6cb430a03cf2`](https://bscscan.com/address/0x77e535f92635616a848d0cc2584d6cb430a03cf2#code) |
| StoxesBnbSplitVaultFactory | Fee split vaults | [`0xc8f5fef467e58f64380712a4cebbaa89ceef7ac6`](https://bscscan.com/address/0xc8f5fef467e58f64380712a4cebbaa89ceef7ac6#code) |
| StoxesBnbGiftVaultFactory | Social-handle gift vaults | [`0x3e3b96daecba4cb478f0cd2ed9c74e1728baadba`](https://bscscan.com/address/0x3e3b96daecba4cb478f0cd2ed9c74e1728baadba#code) |

### BNB Chain Dependencies

| Contract | BNB Mainnet Address |
|----------|---------------------|
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| PancakeSwap V2 Factory | `0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73` |
| PancakeSwap V3 Factory | `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865` |
| PancakeSwap V3 Position Manager | `0x46A15B0b27311cedF172AB29E4f4766fbE7F4364` |
| PancakeSwap V3 Smart Router | `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` |

## Features

- **Native BNB Burn**: launches that use a Native BNB Burn vault send their allocated trading fees to burns of native BNB at the dead address (`0x000000000000000000000000000000000000dEaD`). Every burn is visible on BscScan.
- **Floor Reserve**: allocated trading fees build a separate reserve held in a vault. Holders can burn tokens to redeem against that reserve, which gives them an exit route alongside the main PancakeSwap pool. Redemption is limited to the reserve available at the time.
- **bStocks on BNB Chain**: a launch can use a registered bStock (tokenized equity on BNB Smart Chain) as its quote asset, and Stocks vaults convert fees into a bStock through PancakeSwap V3 and distribute it to holders.
- **BNB-quoted bonding curve to PancakeSwap**: tokens trade on a bonding curve priced in BNB (wrapped as WBNB) or a bStock, then graduate to PancakeSwap V2 or V3 liquidity. V3 LP positions are held permanently by the locker.
- **Ownerless tokens**: launched tokens have a fixed supply of 1,000,000,000 (18 decimals). `owner()` and `getOwner()` return the zero address.
- **Measurable BNC contributions**: the Stoxes.fun landing page shows the platform's total launch contributions to BNC.
- **Gas-efficient design**: tokens and vaults are deployed as minimal-proxy clones (EIP-1167), and the curve math is in a linked library.

## Repository Layout

```
src/bnb/            BNB Smart Chain launchpad contracts (factory, portal, graduator, locker, tokens)
src/bnb/vaults/     Vaults and vault factories (Native BNB Burn, Floor Reserve, bStocks, buyback, split, gift)
src/bnb/libraries/  Portal math and PancakeSwap V3 liquidity helpers
src/                Shared base contracts, interfaces and vendored math libraries
test/bnb/           Unit, integration and BSC mainnet fork tests
script/             Foundry deployment script for BNB Smart Chain
deployments/        BNB Smart Chain mainnet addresses
verification/       Standard JSON inputs accepted by BscScan for every deployed contract
bnbconfig.json      BNB Chain network, RPC and dependency configuration
```

## Getting Started

Install [Foundry](https://book.getfoundry.sh/getting-started/installation), then:

```bash
cp .env.example .env       # BSC_RPC_URL, BSC_TESTNET_RPC_URL, BSCSCAN_API_KEY
forge build
forge test
```

Fork tests against BNB Smart Chain mainnet state are skipped by default. Each one is turned on by a `RUN_BNB_*_FORK=true` variable documented in its test file. Most of them read from a local BSC mainnet fork node, for example:

```bash
anvil --fork-url $BSC_RPC_URL --chain-id 56 --port 18546
```

### Deploying to BNB Smart Chain

```bash
# Simulation against BSC (no transactions sent)
forge script script/DeployBnbV2.s.sol --rpc-url bsc

# Broadcast to BSC Testnet
BROADCAST=1 forge script script/DeployBnbV2.s.sol --rpc-url bsc_testnet --broadcast
```

### Verifying on BscScan

```bash
forge verify-contract <address> src/bnb/StoxesBnbPortal.sol:StoxesBnbPortal --chain bsc
```

## Source Verification

Every contract in the table above is verified on BscScan as **Exact Match**. The files in [`verification/bsc-mainnet/`](verification/bsc-mainnet) are the standard JSON compiler inputs that BscScan accepted. Each source file they contain is byte-identical to the file in this repository, with one exception: `StoxesBnbSimpleToken` was deployed with an earlier revision of `src/bnb/IStoxesBnb.sol`, and that revision is kept in its verification input. Some deployments used extra Foundry remappings that affect only the metadata hash. To reproduce a deployed bytecode exactly, compile from its verification input.

Source verification is not a security audit.

## Links

- Website: [stoxes.fun](https://stoxes.fun)
- Documentation: [stoxes.fun/bnb/docs](https://stoxes.fun/bnb/docs)
- Explorer: [BscScan](https://bscscan.com/address/0xdfb1afc6dabcbc23e5a3fd09c8a0137112f58f96)

## License

[MIT](LICENSE)
