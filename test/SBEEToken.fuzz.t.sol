// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {SBEEToken} from "../src/SBEEToken.sol";

/// @notice Property tests over the SBEE transfer rules, and the failure paths the smoke tests leave out.
/// @dev The rule under test, from the brief's mechanics specification M1: only a transfer whose sender is
///      the Uniswap v4 PoolManager is taxed, at exactly 2% of the gross amount, paid to the fixed wallet;
///      every other transfer moves exactly what it says. The supply is fixed at 1e27 forever.
contract SBEETokenFuzzTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant TAX_BPS = 200;
    uint256 constant BPS = 10_000;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant TAX_WALLET = 0xF74C1a2e29169A06d2f785bC440ee3725A5DD965;
    address constant REMAINDER_TO = 0x000000000000000000000000000000000000dEaD;

    address factory = makeAddr("factory");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address distributor = makeAddr("merkleDistributor");

    SBEEToken token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event BuyTaxed(address indexed buyer, uint256 grossAmount, uint256 taxAmount);

    function setUp() public {
        vm.prank(factory);
        token = new SBEEToken();
    }

    function _tax(uint256 gross) internal pure returns (uint256) {
        return (gross * TAX_BPS) / BPS;
    }

    /// @dev Puts `amount` into the PoolManager the way the factory's seed does: a plain transfer, untaxed.
    function _fund(address who, uint256 amount) internal {
        if (who == factory) return;
        vm.prank(factory);
        token.transfer(who, amount);
    }

    // =============================================================== buys: sender is the PoolManager

    /// @dev For any gross amount the PoolManager can pay out: the buyer gets gross - floor(2%), the tax wallet
    ///      gets floor(2%), the PoolManager is debited the gross amount and nothing is created or lost.
    function testFuzz_buyPaysExactlyTwoPercentToTaxWallet(uint256 gross) public {
        gross = bound(gross, 0, SUPPLY);
        _fund(POOL_MANAGER, SUPPLY);

        uint256 tax = _tax(gross);
        vm.prank(POOL_MANAGER);
        assertTrue(token.transfer(alice, gross));

        assertEq(token.balanceOf(alice), gross - tax, "buyer net");
        assertEq(token.balanceOf(TAX_WALLET), tax, "tax wallet");
        assertEq(token.balanceOf(POOL_MANAGER), SUPPLY - gross, "pool manager debited gross");
        assertEq(token.totalSupply(), SUPPLY, "supply");
        assertEq(token.balanceOf(alice) + token.balanceOf(TAX_WALLET) + token.balanceOf(POOL_MANAGER), SUPPLY);
        // The tax is never more than 2% and never short by more than the rounding unit.
        assertLe(tax * BPS, gross * TAX_BPS, "tax never exceeds 2%");
        assertLt(gross * TAX_BPS - tax * BPS, BPS, "tax rounds down by less than one unit");
    }

    /// @dev The tax rounds to zero only below 50 wei, and from 50 wei up it is always at least 1 wei.
    function testFuzz_taxRoundingBoundaryAtFiftyWei(uint256 gross) public {
        gross = bound(gross, 0, 10_000);
        _fund(POOL_MANAGER, 10_000);
        vm.prank(POOL_MANAGER);
        token.transfer(alice, gross);
        if (gross < 50) {
            assertEq(token.balanceOf(TAX_WALLET), 0, "no tax below 50 wei");
            assertEq(token.balanceOf(alice), gross, "whole amount delivered");
        } else {
            assertGe(token.balanceOf(TAX_WALLET), 1, "tax from 50 wei up");
            assertEq(token.balanceOf(TAX_WALLET), gross / 50);
        }
    }

    /// @dev The two Transfer events a taxed buy emits add up to the gross amount, in the order tax then net,
    ///      and BuyTaxed carries the buyer, the gross and the tax. A tiny buy emits no BuyTaxed at all.
    function testFuzz_buyEmitsTaxThenNetTransfers(uint256 gross) public {
        gross = bound(gross, 0, SUPPLY);
        _fund(POOL_MANAGER, SUPPLY);
        uint256 tax = _tax(gross);

        vm.recordLogs();
        vm.prank(POOL_MANAGER);
        token.transfer(alice, gross);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        bytes32 taxedSig = keccak256("BuyTaxed(address,uint256,uint256)");
        uint256 transferred;
        uint256 taxedEvents;
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, address(token));
            if (logs[i].topics[0] == transferSig) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), POOL_MANAGER, "from");
                address to = address(uint160(uint256(logs[i].topics[2])));
                uint256 value = abi.decode(logs[i].data, (uint256));
                if (to == TAX_WALLET) assertEq(value, tax, "tax leg");
                else assertEq(to, alice, "net leg recipient");
                transferred += value;
            } else if (logs[i].topics[0] == taxedSig) {
                ++taxedEvents;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), alice, "buyer");
                (uint256 g, uint256 t) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(g, gross, "gross in event");
                assertEq(t, tax, "tax in event");
            }
        }
        assertEq(transferred, gross, "Transfer events sum to gross");
        assertEq(taxedEvents, tax == 0 ? 0 : 1, "BuyTaxed exactly when tax is nonzero");
    }

    /// @dev Pulling from the PoolManager with an allowance is a buy as well: taxed, and the allowance is
    ///      consumed for the gross amount, not the net.
    function testFuzz_transferFromPoolManagerIsTaxedAndSpendsGrossAllowance(uint256 gross, uint256 allowance) public {
        gross = bound(gross, 0, SUPPLY);
        allowance = bound(allowance, gross, type(uint256).max - 1); // a finite allowance, at least the gross
        _fund(POOL_MANAGER, SUPPLY);
        vm.prank(POOL_MANAGER);
        token.approve(bob, allowance);

        vm.prank(bob);
        assertTrue(token.transferFrom(POOL_MANAGER, alice, gross));
        assertEq(token.balanceOf(alice), gross - _tax(gross));
        assertEq(token.balanceOf(TAX_WALLET), _tax(gross));
        assertEq(token.allowance(POOL_MANAGER, bob), allowance - gross, "allowance spent for gross");
    }

    /// @dev Per-buy rounding: the tax wallet holds the sum of each buy's floored tax, which can be less than
    ///      2% of the total bought but never more, and buyers plus tax wallet always equal what left the pool.
    function testFuzz_manyBuysConserveAndNeverOverTax(uint256[8] memory amounts) public {
        _fund(POOL_MANAGER, SUPPLY);
        uint256 totalGross;
        uint256 totalTax;
        uint256 totalNet;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 gross = bound(amounts[i], 0, SUPPLY / amounts.length);
            address buyer = address(uint160(0xB0B0 + i));
            vm.prank(POOL_MANAGER);
            token.transfer(buyer, gross);
            totalGross += gross;
            totalTax += _tax(gross);
            totalNet += token.balanceOf(buyer);
        }
        assertEq(token.balanceOf(TAX_WALLET), totalTax, "tax wallet holds the sum of per-buy taxes");
        assertEq(totalNet + totalTax, totalGross, "buyers plus tax equal what left the pool");
        assertEq(token.balanceOf(POOL_MANAGER), SUPPLY - totalGross, "pool manager debited gross");
        assertLe(totalTax, _tax(totalGross), "per-buy rounding never over-taxes");
        assertEq(token.totalSupply(), SUPPLY);
    }

    // =============================================================== exemptions on the buy path

    /// @dev A payout from the PoolManager to the tax wallet itself arrives whole and emits no BuyTaxed.
    function testFuzz_poolManagerPayingTaxWalletIsWhole(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        _fund(POOL_MANAGER, SUPPLY);
        vm.recordLogs();
        vm.prank(POOL_MANAGER);
        token.transfer(TAX_WALLET, amount);
        assertEq(token.balanceOf(TAX_WALLET), amount);
        assertEq(token.balanceOf(POOL_MANAGER), SUPPLY - amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != keccak256("BuyTaxed(address,uint256,uint256)"), "no BuyTaxed");
        }
    }

    /// @dev A self-transfer by the PoolManager changes nothing and pays nothing.
    function testFuzz_poolManagerSelfTransferIsNoop(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        _fund(POOL_MANAGER, SUPPLY);
        vm.prank(POOL_MANAGER);
        assertTrue(token.transfer(POOL_MANAGER, amount));
        assertEq(token.balanceOf(POOL_MANAGER), SUPPLY);
        assertEq(token.balanceOf(TAX_WALLET), 0);
    }

    // =============================================================== sells and plain transfers: never taxed

    /// @dev Any holder sending any amount to the PoolManager delivers exactly that amount (sells, the seed).
    function testFuzz_transferToPoolManagerIsExact(address seller, uint256 amount) public {
        vm.assume(seller != address(0) && seller != POOL_MANAGER && seller != TAX_WALLET);
        amount = bound(amount, 0, SUPPLY);
        _fund(seller, amount);
        uint256 pmBefore = token.balanceOf(POOL_MANAGER);
        uint256 sellerBefore = token.balanceOf(seller);

        vm.prank(seller);
        assertTrue(token.transfer(POOL_MANAGER, amount));
        assertEq(token.balanceOf(POOL_MANAGER), pmBefore + amount, "arrives whole");
        assertEq(token.balanceOf(seller), sellerBefore - amount);
        assertEq(token.balanceOf(TAX_WALLET), 0, "no tax on a sell");
    }

    /// @dev Any transfer whose sender is not the PoolManager moves exactly `amount`, whoever the parties are
    ///      (including the tax wallet, the distributor, the factory, and self-transfers).
    function testFuzz_transferNotFromPoolManagerIsExact(address from, address to, uint256 amount) public {
        vm.assume(from != address(0) && from != POOL_MANAGER);
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        _fund(from, amount);

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 taxBefore = token.balanceOf(TAX_WALLET);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(from, to, amount);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer is a no-op");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender debited exactly");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient credited exactly");
        }
        if (to != TAX_WALLET && from != TAX_WALLET) assertEq(token.balanceOf(TAX_WALLET), taxBefore, "no tax");
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev transferFrom between ordinary parties is exact too, and spends exactly the amount of allowance.
    function testFuzz_transferFromNotFromPoolManagerIsExact(address spender, uint256 amount, uint256 allowance) public {
        vm.assume(spender != address(0));
        amount = bound(amount, 0, SUPPLY);
        allowance = bound(allowance, amount, type(uint256).max - 1);
        _fund(alice, amount);
        vm.prank(alice);
        token.approve(spender, allowance);

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(TAX_WALLET), 0);
        assertEq(token.allowance(alice, spender), allowance - amount);
    }

    /// @dev An infinite allowance is not decremented, from the PoolManager or from anyone else.
    function test_infiniteAllowanceIsNotConsumed() public {
        _fund(POOL_MANAGER, 1_000e18);
        vm.prank(POOL_MANAGER);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(POOL_MANAGER, alice, 100e18);
        assertEq(token.allowance(POOL_MANAGER, bob), type(uint256).max);
        assertEq(token.balanceOf(alice), 98e18);
        assertEq(token.balanceOf(TAX_WALLET), 2e18);
    }

    // =============================================================== the launch flows, as the factory runs them

    /// @dev The factory's three flows, in order: 10% to the Merkle distributor, 90% into the PoolManager, the
    ///      remainder to remainderTo. Each arrives whole and the tax wallet sees nothing. Then a claim out of
    ///      the distributor arrives whole as well.
    function test_launchFlowsArriveWhole() public {
        uint256 swarm = (SUPPLY * 1_000) / BPS;
        uint256 pool = (SUPPLY * 9_000) / BPS;

        vm.startPrank(factory);
        assertTrue(token.transfer(distributor, swarm));
        assertTrue(token.transfer(POOL_MANAGER, pool));
        assertTrue(token.transfer(REMAINDER_TO, token.balanceOf(factory)));
        vm.stopPrank();

        assertEq(token.balanceOf(distributor), swarm, "swarm share arrived short");
        assertEq(token.balanceOf(POOL_MANAGER), pool, "seed arrived short");
        assertEq(token.balanceOf(REMAINDER_TO), 0, "9000 + 1000 bps leave no remainder");
        assertEq(token.balanceOf(factory), 0);
        assertEq(token.balanceOf(TAX_WALLET), 0);

        vm.prank(distributor);
        assertTrue(token.transfer(alice, swarm));
        assertEq(token.balanceOf(alice), swarm, "claim arrived short");
        assertEq(token.totalSupply(), SUPPLY);
    }

    // =============================================================== failure paths

    /// @dev A buy whose gross exceeds the PoolManager's balance reverts as a whole: the tax leg is not kept
    ///      when the net leg cannot be paid, even though the PoolManager could cover the net leg alone.
    function test_buyRevertsAtomicallyWhenGrossExceedsBalanceButNetDoesNot() public {
        _fund(POOL_MANAGER, 99e18);
        vm.prank(POOL_MANAGER);
        // After the 2e18 tax leg the PoolManager holds 97e18 and owes 98e18.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, POOL_MANAGER, 97e18, 98e18)
        );
        token.transfer(alice, 100e18);
        assertEq(token.balanceOf(TAX_WALLET), 0, "no tax kept from a reverted buy");
        assertEq(token.balanceOf(POOL_MANAGER), 99e18);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev The PoolManager can pay out its entire balance: both legs fit exactly.
    function testFuzz_poolManagerCanPayOutWholeBalance(uint256 held) public {
        held = bound(held, 0, SUPPLY);
        _fund(POOL_MANAGER, held);
        vm.prank(POOL_MANAGER);
        assertTrue(token.transfer(alice, held));
        assertEq(token.balanceOf(POOL_MANAGER), 0);
        assertEq(token.balanceOf(alice) + token.balanceOf(TAX_WALLET), held);
    }

    /// @dev A buy to the zero address is refused before any tax moves.
    function test_buyToZeroAddressRevertsWithoutTaxing() public {
        _fund(POOL_MANAGER, 1_000e18);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 100e18);
        assertEq(token.balanceOf(TAX_WALLET), 0);
        assertEq(token.balanceOf(POOL_MANAGER), 1_000e18);
    }

    function test_transferToZeroAddressReverts() public {
        _fund(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    /// @dev Pulling from the PoolManager needs allowance for the gross amount: an allowance that covers only
    ///      the net amount is not enough, and nothing moves.
    function test_transferFromPoolManagerWithNetOnlyAllowanceReverts() public {
        _fund(POOL_MANAGER, 1_000e18);
        vm.prank(POOL_MANAGER);
        token.approve(bob, 98e18);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 98e18, 100e18)
        );
        token.transferFrom(POOL_MANAGER, alice, 100e18);
        assertEq(token.balanceOf(TAX_WALLET), 0);
        assertEq(token.balanceOf(POOL_MANAGER), 1_000e18);
    }

    /// @dev A sell larger than the holder's balance reverts: the PoolManager cannot be credited from nothing.
    function testFuzz_sellExceedingBalanceReverts(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - held);
        _fund(alice, held);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, held + excess)
        );
        token.transfer(POOL_MANAGER, held + excess);
    }

    // =============================================================== no admin surface, generalised

    /// @dev Every selector that is not part of the ERC-20 surface or a constant getter is rejected, from the
    ///      deployer and from the PoolManager alike, and rejecting it changes nothing. This is the general form
    ///      of "no owner, no mint, no pause, no blacklist, no setter".
    function testFuzz_unknownSelectorsAreRejectedAndChangeNothing(bytes4 selector, bytes memory tail) public {
        bytes4[17] memory known = [
            bytes4(keccak256("name()")),
            bytes4(keccak256("symbol()")),
            bytes4(keccak256("decimals()")),
            bytes4(keccak256("totalSupply()")),
            bytes4(keccak256("balanceOf(address)")),
            bytes4(keccak256("transfer(address,uint256)")),
            bytes4(keccak256("allowance(address,address)")),
            bytes4(keccak256("approve(address,uint256)")),
            bytes4(keccak256("transferFrom(address,address,uint256)")),
            bytes4(keccak256("TOTAL_SUPPLY()")),
            bytes4(keccak256("POOL_MANAGER()")),
            bytes4(keccak256("TAX_WALLET()")),
            bytes4(keccak256("BUY_TAX_BPS()")),
            bytes4(keccak256("BPS_DENOMINATOR()")),
            bytes4(keccak256("POOL_FEE()")),
            bytes4(0),
            bytes4(0)
        ];
        for (uint256 i; i < known.length; ++i) {
            vm.assume(selector != known[i]);
        }
        _fund(POOL_MANAGER, 1_000e18);

        bytes memory data = abi.encodePacked(selector, tail);
        address[3] memory callers = [factory, POOL_MANAGER, alice];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, "unknown selector accepted");
        }
        // Plain ETH is refused too: no receive, no fallback.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool sent,) = address(token).call{value: 1 wei}("");
        assertFalse(sent, "token accepted ETH");

        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(factory), SUPPLY - 1_000e18);
        assertEq(token.balanceOf(POOL_MANAGER), 1_000e18);
        assertEq(token.balanceOf(TAX_WALLET), 0);
    }

    /// @dev The constants the brief fixes, read back, and the fact that they are constants: the runtime
    ///      contains no SSTORE outside the ERC-20 bookkeeping would be hard to prove by opcode, so instead
    ///      every setter name a tax token has ever shipped is tried and refused. The existing smoke test covers
    ///      the common names; this adds the tax-specific ones.
    function test_taxParametersHaveNoSetters() public {
        string[12] memory signatures = [
            "setTaxWallet(address)",
            "setTaxRate(uint256)",
            "setBuyTax(uint256)",
            "setFee(uint256)",
            "setFees(uint256,uint256)",
            "updateTaxWallet(address)",
            "setMarketingWallet(address)",
            "excludeFromFee(address)",
            "setExcludedFromFee(address,bool)",
            "setPool(address)",
            "setPoolManager(address)",
            "removeTax()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, uint256(0));
            vm.prank(factory);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.TAX_WALLET(), TAX_WALLET);
        assertEq(token.POOL_MANAGER(), POOL_MANAGER);
        assertEq(token.BUY_TAX_BPS(), TAX_BPS);
        assertEq(token.BPS_DENOMINATOR(), BPS);
        assertEq(uint256(token.POOL_FEE()), 12_500);
    }
}
