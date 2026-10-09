// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {SBEEToken} from "../src/SBEEToken.sol";

/// @notice Smoke tests for the SBEE launch token: deployment, supply, and the three transfer paths.
/// @dev The full suite (fuzz and invariants) is written by a separate assignment.
contract SBEETokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant TAX_WALLET = 0xF74C1a2e29169A06d2f785bC440ee3725A5DD965;

    address deployer = makeAddr("factory");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address swarm = makeAddr("swarmDistributor");

    SBEEToken token;

    event BuyTaxed(address indexed buyer, uint256 grossAmount, uint256 taxAmount);

    function setUp() public {
        vm.prank(deployer);
        token = new SBEEToken();
    }

    // ---------------------------------------------------------------- deployment and supply

    function test_metadata() public view {
        assertEq(token.name(), "Swarm Bee");
        assertEq(token.symbol(), "SBEE");
        assertEq(token.decimals(), 18);
    }

    function test_mintsFullSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_nothingMintedToSwarmOrTaxWalletOrPoolManager() public view {
        assertEq(token.balanceOf(swarm), 0);
        assertEq(token.balanceOf(TAX_WALLET), 0);
        assertEq(token.balanceOf(POOL_MANAGER), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_constantsAreFixed() public view {
        assertEq(token.POOL_MANAGER(), POOL_MANAGER);
        assertEq(token.TAX_WALLET(), TAX_WALLET);
        assertEq(token.BUY_TAX_BPS(), 200);
        assertEq(token.POOL_FEE(), 12_500); // 1.25%
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    // ---------------------------------------------------------------- transfer paths

    function test_walletToWalletTransferIsUntaxed() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 400e18));
        assertEq(token.balanceOf(bob), 400e18);
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.balanceOf(TAX_WALLET), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferToPoolManagerIsUntaxed() public {
        // The factory's seed: 90% of the supply into the PoolManager, arriving whole.
        uint256 seed = (SUPPLY * 9_000) / 10_000;
        vm.prank(deployer);
        assertTrue(token.transfer(POOL_MANAGER, seed));
        assertEq(token.balanceOf(POOL_MANAGER), seed);
        assertEq(token.balanceOf(TAX_WALLET), 0);

        // A sell: a holder sends into the PoolManager, arriving whole.
        vm.prank(deployer);
        token.transfer(alice, 1_000e18);
        vm.prank(alice);
        assertTrue(token.transfer(POOL_MANAGER, 1_000e18));
        assertEq(token.balanceOf(POOL_MANAGER), seed + 1_000e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(TAX_WALLET), 0);
    }

    function test_transferFromPoolManagerTakesTwoPercent() public {
        vm.prank(deployer);
        token.transfer(POOL_MANAGER, 10_000e18);

        vm.expectEmit(true, true, true, true, address(token));
        emit BuyTaxed(alice, 1_000e18, 20e18);
        vm.prank(POOL_MANAGER);
        assertTrue(token.transfer(alice, 1_000e18));

        assertEq(token.balanceOf(alice), 980e18, "buyer receives 98%");
        assertEq(token.balanceOf(TAX_WALLET), 20e18, "tax wallet receives 2%");
        assertEq(token.balanceOf(POOL_MANAGER), 9_000e18, "pool manager is debited the gross amount");
        assertEq(token.totalSupply(), SUPPLY, "tax does not change supply");
    }

    function test_transferFromPoolManagerViaTransferFromTakesTwoPercent() public {
        // Uniswap v4 pays out with transfer(), but an approved spender pulling from the PoolManager is a
        // buy just the same.
        vm.prank(deployer);
        token.transfer(POOL_MANAGER, 10_000e18);
        vm.prank(POOL_MANAGER);
        token.approve(bob, 500e18);

        vm.prank(bob);
        assertTrue(token.transferFrom(POOL_MANAGER, alice, 500e18));
        assertEq(token.balanceOf(alice), 490e18);
        assertEq(token.balanceOf(TAX_WALLET), 10e18);
        assertEq(token.allowance(POOL_MANAGER, bob), 0);
    }

    function test_tinyBuyBelowOneBpsUnitIsNotTaxedButStillDelivered() public {
        vm.prank(deployer);
        token.transfer(POOL_MANAGER, 1_000e18);
        vm.prank(POOL_MANAGER);
        token.transfer(alice, 49); // 49 * 200 / 10000 rounds to 0
        assertEq(token.balanceOf(alice), 49);
        assertEq(token.balanceOf(TAX_WALLET), 0);
    }

    // ---------------------------------------------------------------- failure paths

    function test_transferExceedingBalanceReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 11e18));
        token.transfer(bob, 11e18);
    }

    function test_buyExceedingPoolManagerBalanceReverts() public {
        vm.prank(deployer);
        token.transfer(POOL_MANAGER, 100e18);
        vm.prank(POOL_MANAGER);
        vm.expectRevert();
        token.transfer(alice, 101e18);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1e18));
        token.transferFrom(alice, bob, 1e18);
    }

    // ---------------------------------------------------------------- no admin surface

    function test_noAdminOrMintFunctionsExist() public {
        string[14] memory signatures = [
            "owner()",
            "mint(address,uint256)",
            "mint(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "setTaxWallet(address)",
            "setTax(uint256)",
            "setPoolManager(address)",
            "blacklist(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], deployer, uint256(1));
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }
}
