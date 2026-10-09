# Swarm Bee (SBEE)

A fixed-supply ERC-20 launch token for Robinhood Chain (chain id 4663) with a 2% creator tax on
buys from the Uniswap v4 pool. No owner, no admin functions, no upgradeability.

## Contract

`src/SBEEToken.sol`, Solidity identifier `SBEEToken` (OpenZeppelin ERC20 v5.7.0, vendored under
`lib/`).

| Parameter | Value |
| --- | --- |
| Name / symbol / decimals | Swarm Bee / SBEE / 18 |
| Total supply | 1,000,000,000 SBEE = `1000000000000000000000000000` minor units, minted once to `msg.sender` in the constructor |
| Constructor arguments | none |
| PoolManager (Uniswap v4, Robinhood Chain) | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| Creator tax wallet | `0xF74C1a2e29169A06d2f785bC440ee3725A5DD965` |
| Buy tax | 200 bps (2%) of every transfer sent by the PoolManager |
| Pool fee | 12500 (1.25%), fixed by the launch policy; `POOL_FEE` is informational |

### Transfer rules

- **Buy** (sender is the PoolManager): 2% of the amount goes to the tax wallet, 98% to the
  recipient. The PoolManager is debited the full amount, so Uniswap v4 accounting is unaffected.
- **Sell or seed** (recipient is the PoolManager): untaxed, arrives whole.
- **Everything else** (factory to distributor, distributor to claimant, wallet to wallet): untaxed.
- A buy so small that 2% rounds to zero delivers the whole amount and pays no tax.

### What does not exist

No mint after the constructor, no burnFrom, no pause, no blacklist or freeze, no owner, no setters,
no proxy, no `delegatecall`, no `selfdestruct`. Every parameter is a compile-time constant.

## Launch and operational responsibilities

- The launch factory is the deployer: it receives the whole supply, sends the swarm's 10% to the
  launch's Merkle distributor, seeds the pool with 90% (`economics.poolBps` 9000) through the
  PoolManager, and forwards any remainder to `economics.remainderTo`. The token moves all of these
  flows whole because none of them is sent by the PoolManager.
- `launch.json` carries the manifest values given in the brief. `pool.initialPrice` is provenance
  only; the deployer derives the opening price from `initialMarketCapWei` (2,500 IMD) and the
  deployed currency order.
- The tax wallet is an externally owned address supplied by the requester. Tax arrives as plain SBEE
  balance; nothing in the contract can redirect it.

## Assumptions

- Buys are recognised purely by `from == POOL_MANAGER`. Any other contract that holds SBEE and pays
  it out (a router that custodies tokens, another venue) is treated as an ordinary wallet and is not
  taxed. Uniswap v4 swaps always pay out from the PoolManager, so pool buys are always taxed.
- Transfers the PoolManager makes to the tax wallet itself are delivered whole.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins solc 0.8.26, evm_version cancun, optimizer on, `bytecode_hash = "none"`.
Smoke tests live in `test/SBEEToken.t.sol`; the full fuzz and invariant suite is a separate
assignment.
