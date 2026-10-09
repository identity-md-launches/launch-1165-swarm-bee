// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SBEEToken} from "../src/SBEEToken.sol";

/// @notice Drives the token with random transfers, transferFroms and approvals among a fixed cast of actors
///         that includes the PoolManager and the tax wallet, and keeps a ghost ledger of what the brief says
///         every balance must be afterwards.
/// @dev The ghost ledger IS the specification: a transfer sent by the PoolManager to anyone but itself or the
///      tax wallet is split floor(2%) / rest; every other transfer moves exactly its amount. Any sequence on
///      which the token disagrees with the ledger is a finding. The handler never reverts on purpose (amounts
///      are bounded to balances, recipients are never the zero address), so `fail_on_revert` can be on and a
///      revert the handler did not expect is itself a failure.
contract SBEEHandler is Test {
    uint256 constant TAX_BPS = 200;
    uint256 constant BPS = 10_000;

    SBEEToken public immutable token;
    address public immutable POOL_MANAGER;
    address public immutable TAX_WALLET;

    address[] public actors;
    mapping(address => uint256) public ghostBalance;

    uint256 public ghostGrossBought;
    uint256 public ghostTaxCollected;
    uint256 public ghostNetDelivered;
    uint256 public buys;
    uint256 public taxedBuys;
    uint256 public sells;
    uint256 public plainTransfers;
    uint256 public adminAttempts;

    constructor(SBEEToken token_, address factory, address[] memory others) {
        token = token_;
        POOL_MANAGER = token_.POOL_MANAGER();
        TAX_WALLET = token_.TAX_WALLET();
        actors.push(factory);
        actors.push(POOL_MANAGER);
        actors.push(TAX_WALLET);
        for (uint256 i; i < others.length; ++i) {
            actors.push(others[i]);
        }
        ghostBalance[factory] = token_.totalSupply();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev What the brief says a transfer does to balances.
    function _apply(address from, address to, uint256 value) internal {
        if (from == POOL_MANAGER && to != POOL_MANAGER && to != TAX_WALLET) {
            uint256 tax = (value * TAX_BPS) / BPS;
            ghostBalance[from] -= value;
            ghostBalance[TAX_WALLET] += tax;
            ghostBalance[to] += value - tax;
            ghostGrossBought += value;
            ghostTaxCollected += tax;
            ghostNetDelivered += value - tax;
            ++buys;
            if (tax != 0) ++taxedBuys;
        } else {
            ghostBalance[from] -= value;
            ghostBalance[to] += value;
            if (to == POOL_MANAGER && from != POOL_MANAGER) ++sells;
            else ++plainTransfers;
        }
    }

    /// @notice transfer() between any two actors, for any amount the sender can afford (including 0 and all).
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        require(token.transfer(to, amount), "transfer returned false");
        _apply(from, to, amount);
    }

    /// @notice Small amounts around the 50 wei rounding boundary, so the fuzzer visits tax == 0 and tax == 1.
    function transferSmall(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, 200);
        if (token.balanceOf(from) < amount) return;
        vm.prank(from);
        require(token.transfer(to, amount), "transfer returned false");
        _apply(from, to, amount);
    }

    /// @notice transferFrom() by any actor on behalf of any actor, with an allowance granted for exactly the
    ///         amount so the pull must succeed and leave the allowance at zero.
    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.approve(spender, amount);
        vm.prank(spender);
        require(token.transferFrom(from, to, amount), "transferFrom returned false");
        require(token.allowance(from, spender) == 0, "allowance not fully spent");
        _apply(from, to, amount);
    }

    /// @notice Approvals move no balance.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        vm.prank(_actor(ownerSeed));
        token.approve(_actor(spenderSeed), amount);
    }

    /// @notice Anyone, including the deployer and the PoolManager, tries an administrative call. None exists,
    ///         so every attempt must fail and the ledger is untouched.
    function attemptAdmin(uint256 callerSeed, uint256 which, uint256 arg) external {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "setTaxWallet(address)",
            "setBuyTax(uint256)",
            "setPoolManager(address)",
            "transferOwnership(address)",
            "excludeFromFee(address)",
            "withdraw()",
            "sweep(address)"
        ];
        address target = _actor(arg);
        bytes memory data = abi.encodeWithSignature(signatures[which % signatures.length], target, arg);
        vm.prank(_actor(callerSeed));
        (bool ok,) = address(token).call(data);
        require(!ok, "an administrative call succeeded");
        ++adminAttempts;
    }
}

contract SBEETokenInvariantTest is StdInvariant, Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    address factory = makeAddr("factory");
    SBEEToken token;
    SBEEHandler handler;

    function setUp() public {
        vm.prank(factory);
        token = new SBEEToken();

        address[] memory others = new address[](4);
        others[0] = makeAddr("alice");
        others[1] = makeAddr("bob");
        others[2] = makeAddr("merkleDistributor");
        others[3] = 0x000000000000000000000000000000000000dEaD; // economics.remainderTo
        handler = new SBEEHandler(token, factory, others);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = SBEEHandler.transfer.selector;
        selectors[1] = SBEEHandler.transferSmall.selector;
        selectors[2] = SBEEHandler.transferFrom.selector;
        selectors[3] = SBEEHandler.approve.selector;
        selectors[4] = SBEEHandler.attemptAdmin.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyIsFixedForever() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyBalanceMatchesTheSpecificationLedger() public view {
        uint256 n = handler.actorCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address actor = handler.actors(i);
            uint256 actual = token.balanceOf(actor);
            assertEq(actual, handler.ghostBalance(actor), "a balance disagrees with the brief");
            sum += actual;
        }
        assertEq(sum, SUPPLY, "actors' balances do not sum to the supply: tokens leaked or appeared");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_buyAccountingConserves() public view {
        uint256 gross = handler.ghostGrossBought();
        uint256 tax = handler.ghostTaxCollected();
        assertEq(handler.ghostNetDelivered() + tax, gross, "net plus tax is not gross");
        assertLe(tax * 10_000, gross * 200, "more than 2% taxed in total");
        // Per-buy flooring loses at most one rounding unit per buy.
        assertLe(gross * 200 - tax * 10_000, handler.buys() * 10_000, "tax short by more than rounding");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_taxWalletOnlyGainsFromBuysAndPlainTransfers() public view {
        // The tax wallet's balance is fully explained by the ledger; in particular no sell or plain transfer
        // credited it with a hidden fee.
        assertEq(token.balanceOf(handler.TAX_WALLET()), handler.ghostBalance(handler.TAX_WALLET()));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_constantsNeverMove() public view {
        assertEq(token.POOL_MANAGER(), 0x8366a39CC670B4001A1121B8F6A443A643e40951);
        assertEq(token.TAX_WALLET(), 0xF74C1a2e29169A06d2f785bC440ee3725A5DD965);
        assertEq(token.BUY_TAX_BPS(), 200);
        assertEq(uint256(token.POOL_FEE()), 12_500);
    }
}
