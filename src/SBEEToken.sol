// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Swarm Bee (SBEE)
/// @notice Fixed-supply ERC-20 with a 2% creator tax on buys from the Uniswap v4 PoolManager.
/// @dev Design, all of it fixed at deployment with no owner and no admin surface:
///  - The constructor mints the whole supply of 1,000,000,000 SBEE (1e27 minor units) once, to
///    `msg.sender`, which at launch is the launch factory. Nothing can mint afterwards.
///  - Every transfer whose sender is the Uniswap v4 PoolManager (a buy paid out of the pool) sends
///    2% of the amount to the fixed creator wallet and the remaining 98% to the recipient.
///  - Transfers TO the PoolManager (sells and the factory's pool seed) and all other transfers,
///    wallet to wallet or from the factory and the swarm's distributor, move exactly what they say.
///  - No selfdestruct, no delegatecall, no proxy, no pause, no blacklist, no burnFrom.
contract SBEEToken is ERC20 {
    /// @notice Whole supply in minor units: 1,000,000,000 SBEE at 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice The Uniswap v4 PoolManager on Robinhood Chain. Transfers it sends are buys.
    address public constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    /// @notice The wallet that receives the creator tax on every buy.
    address public constant TAX_WALLET = 0xF74C1a2e29169A06d2f785bC440ee3725A5DD965;

    /// @notice Creator tax on buys, in basis points of the transferred amount (2%).
    uint256 public constant BUY_TAX_BPS = 200;

    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The launch pool's fee in Uniswap v4 hundredths of a bip: 12500 = 1.25%.
    /// @dev Informational. The pool fee is a property of the pool the factory opens, which it opens
    ///      at the chain's launch fee of 1.25%; the token has no power over it and no way to change it.
    uint24 public constant POOL_FEE = 12_500;

    /// @notice Emitted on every taxed buy, with the amount withheld for the creator wallet.
    event BuyTaxed(address indexed buyer, uint256 grossAmount, uint256 taxAmount);

    constructor() ERC20("Swarm Bee", "SBEE") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @dev Routes every balance movement. Only a transfer sent by the PoolManager is taxed; mints,
    ///      sells, the seed and ordinary transfers fall straight through to the ERC-20 bookkeeping.
    function _update(address from, address to, uint256 value) internal override {
        if (from == POOL_MANAGER && to != POOL_MANAGER && to != TAX_WALLET) {
            uint256 tax = (value * BUY_TAX_BPS) / BPS_DENOMINATOR;
            if (tax != 0) {
                super._update(from, TAX_WALLET, tax);
                emit BuyTaxed(to, value, tax);
            }
            super._update(from, to, value - tax);
            return;
        }
        super._update(from, to, value);
    }
}
