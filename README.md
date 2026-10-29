# Cool AMM

A smart contract implementation of an Automated Market Maker (AMM) with step liquidity model.

## Requirements

- Node.js 22.0.0 or higher
- Forge

## Installation & Compilation

```bash
npm install
forge install
```

## Build

```bash
npx hardhat compile
```

## Usage

The project implements a simple example of executing buy orders using a step liquidity model. The `CoolAmm` contract provides:

- `buy(uint256 amount)` - Buys a up to amount of token0, returns the amount of token1 spent and bought amount of token0
- `getAskLiquidityDistribution()` - Returns current liquidity distribution across price ranges

The AMM uses a step-based pricing model following: https://hackmd.io/@pycX1lsLTNKAKg_m4dVO1w/HJxBj3vnlg
