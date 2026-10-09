// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "./vendor/v4-core/src/PoolManager.sol";
import {IPoolManager} from "./vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "./vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "./vendor/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "./vendor/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "./vendor/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "./vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "./vendor/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "./vendor/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "./vendor/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "./vendor/v4-core/src/libraries/FullMath.sol";
import {SwapMath} from "./vendor/v4-core/src/libraries/SwapMath.sol";
import {StateLibrary} from "./vendor/v4-core/src/libraries/StateLibrary.sol";
import {SBEEToken} from "../src/SBEEToken.sol";

/// @notice Stand-in for the chain's pair token (IMD), placed at its real address so the pool sorts its two
///         currencies the way Robinhood Chain will. Storage starts empty after `vm.etch`, so nothing is set in
///         a constructor; the test mints what traders need.
contract PairTokenStandIn {
    string public constant name = "IMD";
    string public constant symbol = "IMD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "IMD: balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "IMD: allowance");
        require(balanceOf[from] >= amount, "IMD: balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Stands in for the launch factory: deploys the token (so it is the deployer that receives the whole
///         supply), forwards the swarm's share and the remainder, and seeds the pool single-sided through the
///         PoolManager's unlock exactly as the factory does. It can also withdraw its position afterwards.
contract LaunchProbe is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function deployToken(bytes32 salt) external returns (SBEEToken) {
        return new SBEEToken{salt: salt}();
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24) {
        return manager.initialize(key, sqrtPriceX96);
    }

    /// @dev Adds (positive) or removes (negative) liquidity and settles whatever the position owes or is owed.
    function modifyLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        returns (BalanceDelta delta)
    {
        bytes memory result = manager.unlock(abi.encode(key, tickLower, tickUpper, liquidityDelta));
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta delta,) =
            manager.modifyLiquidity(key, ModifyLiquidityParams(tickLower, tickUpper, liquidityDelta, 0), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) internal {
        if (amount < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @notice An ordinary trader: nothing the token exempts. Buys and sells through the PoolManager, and can
///         choose how to receive what it is owed: take it, take it to someone else, keep it as ERC-6909
///         claims inside the PoolManager, or (to exercise the failure path) not pay at all.
contract Trader is IUnlockCallback {
    enum Mode {
        Take,
        TakeTo,
        MintClaims,
        SkipPayment
    }

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, Mode mode, address to)
        external
        returns (BalanceDelta)
    {
        bytes memory result = manager.unlock(abi.encode(uint8(0), key, zeroForOne, amountSpecified, mode, to));
        return abi.decode(result, (BalanceDelta));
    }

    function redeemClaims(Currency currency, uint256 amount, address to) external {
        manager.unlock(abi.encode(uint8(1), currency, amount, to));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        uint8 kind = abi.decode(data, (uint8));
        if (kind == 1) {
            (, Currency currency, uint256 amount, address recipient) =
                abi.decode(data, (uint8, Currency, uint256, address));
            manager.burn(address(this), currency.toId(), amount);
            manager.take(currency, recipient, amount);
            return "";
        }
        (, PoolKey memory key, bool zeroForOne, int256 amountSpecified, Mode mode, address to) =
            abi.decode(data, (uint8, PoolKey, bool, int256, Mode, address));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = manager.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");
        _settle(key.currency0, delta.amount0(), mode, to);
        _settle(key.currency1, delta.amount1(), mode, to);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount, Mode mode, address to) internal {
        if (amount < 0) {
            if (mode == Mode.SkipPayment) return;
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            if (mode == Mode.MintClaims) manager.mint(address(this), currency.toId(), uint256(uint128(amount)));
            else if (mode == Mode.TakeTo) manager.take(currency, to, uint256(uint128(amount)));
            else manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @notice The launch and the trading that follows it, run against a real Uniswap v4 PoolManager built in place
///         at the address the token hard-codes, with the launch pool's 1.25% fee. Every scenario runs twice,
///         once with SBEE as currency0 and once as currency1, because the live currency order depends on the
///         address the factory's CREATE2 gives the token and the token must behave the same either way.
contract SBEETokenSwapTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant TAX_BPS = 200;
    uint256 constant BPS = 10_000;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant TAX_WALLET = 0xF74C1a2e29169A06d2f785bC440ee3725A5DD965;
    address constant PAIRED = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127; // launch.json pool.pairedCurrency
    address constant REMAINDER_TO = 0x000000000000000000000000000000000000dEaD;
    address constant DISTRIBUTOR = address(0xD157);
    uint24 constant POOL_FEE = 12_500; // launch.json pool.fee, 1.25%
    int24 constant TICK_SPACING = 60; // launch.json pool.tickSpacing
    /// @dev launch.json pool.initialPrice: sqrtPriceX96 with SBEE as currency0.
    uint160 constant SQRT_PRICE_SBEE_AS_CURRENCY0 = 125270724187523965593206900;
    uint256 constant POOL_BPS = 9_000;
    uint256 constant SWARM_BPS = 1_000;

    IPoolManager manager;
    PairTokenStandIn pair;
    LaunchProbe factory;
    Trader trader;

    SBEEToken token;
    PoolKey key;
    bool sbeeIsCurrency0;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 seeded;

    event BuyTaxed(address indexed buyer, uint256 grossAmount, uint256 taxAmount);

    function setUp() public {
        // A working PoolManager at the address the token hard-codes. Built there rather than copied there,
        // because v4 records the address it was constructed at and refuses to run anywhere else.
        vm.etch(POOL_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool built, bytes memory runtime) = POOL_MANAGER.call("");
        require(built && runtime.length > 0, "pool manager could not be built in place");
        vm.etch(POOL_MANAGER, runtime);
        manager = IPoolManager(POOL_MANAGER);
        vm.label(POOL_MANAGER, "PoolManager");

        vm.etch(PAIRED, address(new PairTokenStandIn()).code);
        pair = PairTokenStandIn(PAIRED);
        vm.label(PAIRED, "IMD");
        vm.label(TAX_WALLET, "taxWallet");

        factory = new LaunchProbe(manager);
        trader = new Trader(manager);
        pair.mint(address(trader), 1_000_000e18);
    }

    // ================================================================ the launch, as the factory runs it

    /// @dev Deploys the token at an address on the requested side of the pair token, forwards the swarm's 10%,
    ///      opens the pool at the manifest price and seeds it single-sided with 90% of the supply.
    function _launch(bool wantSbeeAsCurrency0) internal {
        bytes32 initCodeHash = keccak256(type(SBEEToken).creationCode);
        for (uint256 i; i < 256; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = computeCreate2Address(salt, initCodeHash, address(factory));
            if ((predicted < PAIRED) == wantSbeeAsCurrency0) {
                token = factory.deployToken(salt);
                break;
            }
        }
        require(address(token) != address(0), "no salt gave the wanted currency order");
        sbeeIsCurrency0 = wantSbeeAsCurrency0;
        vm.label(address(token), "SBEE");
        assertEq(token.balanceOf(address(factory)), SUPPLY, "the deployer holds the whole supply");

        // Swarm share, whole.
        assertTrue(factory.move(token, DISTRIBUTOR, (SUPPLY * SWARM_BPS) / BPS));
        assertEq(token.balanceOf(DISTRIBUTOR), (SUPPLY * SWARM_BPS) / BPS);

        (Currency c0, Currency c1) = sbeeIsCurrency0
            ? (Currency.wrap(address(token)), Currency.wrap(PAIRED))
            : (Currency.wrap(PAIRED), Currency.wrap(address(token)));
        key = PoolKey(c0, c1, POOL_FEE, TICK_SPACING, IHooks(address(0)));

        uint160 sqrtPrice = sbeeIsCurrency0
            ? SQRT_PRICE_SBEE_AS_CURRENCY0
            : uint160(FullMath.mulDiv(1 << 96, 1 << 96, SQRT_PRICE_SBEE_AS_CURRENCY0));
        int24 tick = factory.initialize(key, sqrtPrice);

        uint256 allowed = (SUPPLY * POOL_BPS) / BPS;
        if (sbeeIsCurrency0) {
            // All SBEE: the whole range sits above the opening price.
            tickLower = (tick / TICK_SPACING + 1) * TICK_SPACING;
            tickUpper = TickMath.maxUsableTick(TICK_SPACING);
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
            liquidity = uint128(FullMath.mulDiv(allowed, FullMath.mulDiv(sqrtA, sqrtB, 1 << 96), sqrtB - sqrtA)) - 1;
        } else {
            // All SBEE (currency1): the whole range sits below the opening price.
            tickUpper = (tick / TICK_SPACING) * TICK_SPACING;
            if (tickUpper > tick) tickUpper -= TICK_SPACING;
            tickLower = TickMath.minUsableTick(TICK_SPACING);
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
            liquidity = uint128(FullMath.mulDiv(allowed, 1 << 96, sqrtB - sqrtA)) - 1;
        }

        uint256 before = token.balanceOf(address(factory));
        BalanceDelta delta = factory.modifyLiquidity(key, tickLower, tickUpper, int256(uint256(liquidity)));
        seeded = before - token.balanceOf(address(factory));

        // Single-sided: only SBEE went in, exactly what the position owed, and the PoolManager holds it whole.
        int128 owedSbee = sbeeIsCurrency0 ? delta.amount0() : delta.amount1();
        int128 owedPair = sbeeIsCurrency0 ? delta.amount1() : delta.amount0();
        assertEq(owedPair, 0, "the seed asked for the pair currency");
        assertEq(uint256(uint128(-owedSbee)), seeded, "the seed moved something other than what it owed");
        assertGt(seeded, 0, "the seed took nothing");
        assertLe(seeded, allowed, "the seed took more than the requester's pool share");
        assertGe(seeded, allowed - 1e6, "the seed took far less than the pool share");
        assertEq(token.balanceOf(POOL_MANAGER), seeded, "the seed arrived short");
        assertEq(token.balanceOf(TAX_WALLET), 0, "the seed was taxed");

        // Remainder to remainderTo, whole.
        uint256 rest = token.balanceOf(address(factory));
        assertTrue(factory.move(token, REMAINDER_TO, rest));
        assertEq(token.balanceOf(REMAINDER_TO), rest);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev What the pool itself will do with `pairIn` of the pair currency on a fresh launch: the single
    ///      swap step across the seeded range, with the 1.25% LP fee taken from the input.
    function _quoteFreshBuy(uint256 pairIn)
        internal
        view
        returns (uint256 grossSbeeOut, uint256 amountIn, uint256 feeAmount)
    {
        uint160 start = TickMath.getSqrtPriceAtTick(sbeeIsCurrency0 ? tickLower : tickUpper);
        uint160 target = TickMath.getSqrtPriceAtTick(sbeeIsCurrency0 ? tickUpper : tickLower);
        (, amountIn, grossSbeeOut, feeAmount) = SwapMath.computeSwapStep(start, target, liquidity, -int256(pairIn), POOL_FEE);
    }

    function _tax(uint256 gross) internal pure returns (uint256) {
        return (gross * TAX_BPS) / BPS;
    }

    function _sbeeDelta(BalanceDelta delta) internal view returns (int128) {
        return sbeeIsCurrency0 ? delta.amount0() : delta.amount1();
    }

    function _pairDelta(BalanceDelta delta) internal view returns (int128) {
        return sbeeIsCurrency0 ? delta.amount1() : delta.amount0();
    }

    /// @dev Buying SBEE means SBEE flows out of the pool: zeroForOne when SBEE is currency1.
    function _buyDirection() internal view returns (bool zeroForOne) {
        return !sbeeIsCurrency0;
    }

    // ================================================================ seed

    function _seedScenario(bool order) internal {
        _launch(order);
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, POOL_FEE, "pool fee is not 1.25%");
        assertEq(lpFee, token.POOL_FEE(), "token's POOL_FEE disagrees with the pool");
        assertEq(manager.getLiquidity(key.toId()), 0, "liquidity is active before the first buy"); // range is out of range until a buy
    }

    function test_seed_sbeeAsCurrency0() public {
        _seedScenario(true);
    }

    function test_seed_sbeeAsCurrency1() public {
        _seedScenario(false);
    }

    // ================================================================ buy: 1.25% pool fee, then 2% creator tax

    function _buyScenario(bool order) internal {
        _launch(order);
        uint256 pairIn = 1e18;
        (uint256 gross, uint256 amountIn, uint256 feeAmount) = _quoteFreshBuy(pairIn);
        uint256 tax = _tax(gross);
        assertGt(tax, 0, "scenario buy must be taxable");

        // The pool keeps 1.25% of the input as its fee; the rest buys SBEE.
        assertEq(amountIn + feeAmount, pairIn, "fee plus swapped input is the whole input");
        assertApproxEqAbs(feeAmount, (pairIn * POOL_FEE) / 1_000_000, 1, "pool fee is not 1.25% of the input");

        vm.expectEmit(true, true, true, true, address(token));
        emit BuyTaxed(address(trader), gross, tax);
        BalanceDelta delta = trader.swap(key, _buyDirection(), -int256(pairIn), Trader.Mode.Take, address(0));

        assertEq(int256(_sbeeDelta(delta)), int256(gross), "pool paid a different gross than quoted");
        assertEq(int256(_pairDelta(delta)), -int256(pairIn), "pool charged a different input than quoted");
        assertEq(token.balanceOf(address(trader)), gross - tax, "buyer did not receive 98% of the gross");
        assertEq(token.balanceOf(TAX_WALLET), tax, "tax wallet did not receive 2% of the gross");
        assertEq(token.balanceOf(POOL_MANAGER), seeded - gross, "pool manager debited other than the gross");
        assertEq(pair.balanceOf(POOL_MANAGER), pairIn, "pool manager did not receive the input");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_buyThroughPool_sbeeAsCurrency0() public {
        _buyScenario(true);
    }

    function test_buyThroughPool_sbeeAsCurrency1() public {
        _buyScenario(false);
    }

    /// @dev Any input size: the trader gets gross minus floor(2%), the tax wallet floor(2%), and the pool
    ///      manager's SBEE balance stays exactly what v4 believes it is.
    function _fuzzBuy(bool order, uint256 pairIn) internal {
        _launch(order);
        pairIn = bound(pairIn, 1e6, 100_000e18);
        BalanceDelta delta = trader.swap(key, _buyDirection(), -int256(pairIn), Trader.Mode.Take, address(0));
        uint256 gross = uint256(uint128(_sbeeDelta(delta)));
        assertEq(token.balanceOf(address(trader)), gross - _tax(gross));
        assertEq(token.balanceOf(TAX_WALLET), _tax(gross));
        assertEq(token.balanceOf(POOL_MANAGER), seeded - gross);
        assertEq(pair.balanceOf(POOL_MANAGER), uint256(uint128(-_pairDelta(delta))));
    }

    function testFuzz_buyAnyAmount_sbeeAsCurrency0(uint256 pairIn) public {
        _fuzzBuy(true, pairIn);
    }

    function testFuzz_buyAnyAmount_sbeeAsCurrency1(uint256 pairIn) public {
        _fuzzBuy(false, pairIn);
    }

    /// @dev An exact-output buy of 49 wei of SBEE: below the rounding unit, so no tax and the whole 49 arrive.
    function _microBuyScenario(bool order) internal {
        _launch(order);
        BalanceDelta delta = trader.swap(key, _buyDirection(), int256(49), Trader.Mode.Take, address(0));
        assertEq(int256(_sbeeDelta(delta)), 49);
        assertEq(token.balanceOf(address(trader)), 49, "micro buy arrived short");
        assertEq(token.balanceOf(TAX_WALLET), 0, "micro buy was taxed");
        assertEq(token.balanceOf(POOL_MANAGER), seeded - 49);
    }

    function test_microBuyBelowRoundingUnit_sbeeAsCurrency0() public {
        _microBuyScenario(true);
    }

    function test_microBuyBelowRoundingUnit_sbeeAsCurrency1() public {
        _microBuyScenario(false);
    }

    // ================================================================ sell: untaxed, settlement balances

    function _sellScenario(bool order) internal {
        _launch(order);
        trader.swap(key, _buyDirection(), -int256(1e18), Trader.Mode.Take, address(0));
        uint256 held = token.balanceOf(address(trader));
        uint256 taxBefore = token.balanceOf(TAX_WALLET);
        uint256 pmBefore = token.balanceOf(POOL_MANAGER);
        uint256 pairBefore = pair.balanceOf(address(trader));

        // Exact-input sell of everything the trader holds. If the token taxed this transfer the PoolManager's
        // settle() would come up short and unlock() would revert with CurrencyNotSettled.
        BalanceDelta delta = trader.swap(key, !_buyDirection(), -int256(held), Trader.Mode.Take, address(0));

        assertEq(int256(_sbeeDelta(delta)), -int256(held), "pool did not take the whole sell");
        assertGt(_pairDelta(delta), 0, "seller got no pair currency back");
        assertEq(token.balanceOf(address(trader)), 0, "seller kept something");
        assertEq(token.balanceOf(POOL_MANAGER), pmBefore + held, "sell arrived short at the pool manager");
        assertEq(token.balanceOf(TAX_WALLET), taxBefore, "a sell was taxed");
        assertEq(pair.balanceOf(address(trader)), pairBefore + uint256(uint128(_pairDelta(delta))));
        // The round trip cost the trader the pool fee twice and the creator tax once; it never pays out more
        // than it put in.
        assertLt(pair.balanceOf(address(trader)), 1_000_000e18, "round trip minted value");
    }

    function test_sellThroughPool_sbeeAsCurrency0() public {
        _sellScenario(true);
    }

    function test_sellThroughPool_sbeeAsCurrency1() public {
        _sellScenario(false);
    }

    /// @dev Selling more than held reverts inside settlement and leaves everything as it was.
    function _sellMoreThanHeldScenario(bool order) internal {
        _launch(order);
        trader.swap(key, _buyDirection(), -int256(1e18), Trader.Mode.Take, address(0));
        uint256 held = token.balanceOf(address(trader));
        uint256 pmBefore = token.balanceOf(POOL_MANAGER);
        vm.expectRevert();
        trader.swap(key, !_buyDirection(), -int256(held + 1), Trader.Mode.Take, address(0));
        assertEq(token.balanceOf(address(trader)), held);
        assertEq(token.balanceOf(POOL_MANAGER), pmBefore);
    }

    function test_sellMoreThanHeldReverts_sbeeAsCurrency0() public {
        _sellMoreThanHeldScenario(true);
    }

    function test_sellMoreThanHeldReverts_sbeeAsCurrency1() public {
        _sellMoreThanHeldScenario(false);
    }

    // ================================================================ failure path: a buy that is not paid for

    /// @dev The trader takes SBEE but never settles the pair currency: v4 reverts the whole unlock, so the tax
    ///      leg that ran inside it is rolled back too. No tax is ever kept from a buy that did not happen.
    function _unpaidBuyScenario(bool order) internal {
        _launch(order);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        trader.swap(key, _buyDirection(), -int256(1e18), Trader.Mode.SkipPayment, address(0));
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(TAX_WALLET), 0, "tax kept from a reverted buy");
        assertEq(token.balanceOf(POOL_MANAGER), seeded);
    }

    function test_unpaidBuyRevertsWithoutTax_sbeeAsCurrency0() public {
        _unpaidBuyScenario(true);
    }

    function test_unpaidBuyRevertsWithoutTax_sbeeAsCurrency1() public {
        _unpaidBuyScenario(false);
    }

    // ================================================================ claims: the tax is paid when SBEE leaves the pool manager

    /// @dev A buyer who keeps the output as ERC-6909 claims has not moved any SBEE yet: untaxed, and the pool
    ///      manager's balance is untouched. The 2% is taken the moment the claims are redeemed for real tokens.
    function _claimsScenario(bool order) internal {
        _launch(order);
        BalanceDelta delta = trader.swap(key, _buyDirection(), -int256(1e18), Trader.Mode.MintClaims, address(0));
        uint256 gross = uint256(uint128(_sbeeDelta(delta)));
        Currency sbee = Currency.wrap(address(token));

        assertEq(token.balanceOf(address(trader)), 0, "claims moved tokens");
        assertEq(token.balanceOf(TAX_WALLET), 0, "claims were taxed");
        assertEq(token.balanceOf(POOL_MANAGER), seeded, "claims changed the pool manager's balance");
        assertEq(manager.balanceOf(address(trader), sbee.toId()), gross, "claims not minted for the gross");

        vm.expectEmit(true, true, true, true, address(token));
        emit BuyTaxed(address(trader), gross, _tax(gross));
        trader.redeemClaims(sbee, gross, address(trader));

        assertEq(token.balanceOf(address(trader)), gross - _tax(gross), "redeemed claims not taxed 2%");
        assertEq(token.balanceOf(TAX_WALLET), _tax(gross));
        assertEq(token.balanceOf(POOL_MANAGER), seeded - gross);
        assertEq(manager.balanceOf(address(trader), sbee.toId()), 0);
    }

    function test_claimsDoNotBypassTheTax_sbeeAsCurrency0() public {
        _claimsScenario(true);
    }

    function test_claimsDoNotBypassTheTax_sbeeAsCurrency1() public {
        _claimsScenario(false);
    }

    // ================================================================ take to the tax wallet: the one exemption on the buy side

    /// @dev A buy delivered straight to the tax wallet arrives whole (the implementation exempts it, and the
    ///      README documents the exemption). No BuyTaxed is emitted; the pool manager is still debited the gross.
    function _takeToTaxWalletScenario(bool order) internal {
        _launch(order);
        vm.recordLogs();
        BalanceDelta delta = trader.swap(key, _buyDirection(), -int256(1e18), Trader.Mode.TakeTo, TAX_WALLET);
        uint256 gross = uint256(uint128(_sbeeDelta(delta)));
        assertEq(token.balanceOf(TAX_WALLET), gross, "payout to the tax wallet was taxed");
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(POOL_MANAGER), seeded - gross);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(token)) {
                assertTrue(logs[i].topics[0] != keccak256("BuyTaxed(address,uint256,uint256)"), "BuyTaxed emitted");
            }
        }
    }

    function test_takeToTaxWalletArrivesWhole_sbeeAsCurrency0() public {
        _takeToTaxWalletScenario(true);
    }

    function test_takeToTaxWalletArrivesWhole_sbeeAsCurrency1() public {
        _takeToTaxWalletScenario(false);
    }

    /// @dev A buy delivered to a third party is taxed and BuyTaxed names the recipient, not the swapper.
    function _takeToThirdPartyScenario(bool order) internal {
        _launch(order);
        address friend = makeAddr("friend");
        BalanceDelta delta = trader.swap(key, _buyDirection(), -int256(1e18), Trader.Mode.TakeTo, friend);
        uint256 gross = uint256(uint128(_sbeeDelta(delta)));
        assertEq(token.balanceOf(friend), gross - _tax(gross));
        assertEq(token.balanceOf(TAX_WALLET), _tax(gross));
        assertEq(token.balanceOf(address(trader)), 0);
    }

    function test_takeToThirdPartyIsTaxed_sbeeAsCurrency0() public {
        _takeToThirdPartyScenario(true);
    }

    function test_takeToThirdPartyIsTaxed_sbeeAsCurrency1() public {
        _takeToThirdPartyScenario(false);
    }

    // ================================================================ accounting over random trade sequences

    /// @dev A random sequence of buys and sells against the real pool. After every trade the pool manager's
    ///      actual SBEE balance equals what v4's deltas say it should be, the tax wallet holds exactly the sum
    ///      of the per-buy taxes, and the supply is unchanged. Afterwards the launch LP removes its whole
    ///      position: its payout from the pool manager is a transfer FROM the pool manager and is therefore
    ///      taxed like any other, and the pool manager ends holding only v4's own rounding dust.
    function _randomTradesScenario(bool order, uint256 seed) internal {
        _launch(order);
        uint256 expectedPm = seeded;
        uint256 expectedTax = 0;
        uint256 expectedTrader = 0;
        for (uint256 i; i < 6; ++i) {
            uint256 roll = uint256(keccak256(abi.encode(seed, i)));
            bool buy = expectedTrader == 0 || roll % 3 != 0;
            if (buy) {
                uint256 pairIn = bound(roll >> 8, 1e6, 10_000e18);
                BalanceDelta delta = trader.swap(key, _buyDirection(), -int256(pairIn), Trader.Mode.Take, address(0));
                uint256 gross = uint256(uint128(_sbeeDelta(delta)));
                expectedPm -= gross;
                expectedTax += _tax(gross);
                expectedTrader += gross - _tax(gross);
            } else {
                uint256 amount = bound(roll >> 8, 1, expectedTrader);
                BalanceDelta delta = trader.swap(key, !_buyDirection(), -int256(amount), Trader.Mode.Take, address(0));
                assertEq(int256(_sbeeDelta(delta)), -int256(amount));
                expectedPm += amount;
                expectedTrader -= amount;
            }
            assertEq(token.balanceOf(POOL_MANAGER), expectedPm, "pool manager balance drifted from v4's deltas");
            assertEq(token.balanceOf(TAX_WALLET), expectedTax, "tax wallet drifted from the sum of per-buy taxes");
            assertEq(token.balanceOf(address(trader)), expectedTrader, "trader balance drifted");
            assertEq(token.totalSupply(), SUPPLY);
        }

        // The LP withdraws everything. The payout is a transfer from the pool manager, so it is taxed 2%.
        uint256 factoryBefore = token.balanceOf(address(factory));
        BalanceDelta out = factory.modifyLiquidity(key, tickLower, tickUpper, -int256(uint256(liquidity)));
        uint256 grossOut = uint256(uint128(_sbeeDelta(out)));
        assertEq(token.balanceOf(address(factory)) - factoryBefore, grossOut - _tax(grossOut), "LP payout not taxed 2%");
        assertEq(token.balanceOf(TAX_WALLET), expectedTax + _tax(grossOut));
        assertEq(token.balanceOf(POOL_MANAGER), expectedPm - grossOut, "pool manager debited other than the gross");
        assertLe(token.balanceOf(POOL_MANAGER), 1e6, "SBEE stranded in the pool manager beyond rounding dust");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_randomTrades_sbeeAsCurrency0(uint256 seed) public {
        _randomTradesScenario(true, seed);
    }

    function testFuzz_randomTrades_sbeeAsCurrency1(uint256 seed) public {
        _randomTradesScenario(false, seed);
    }
}
