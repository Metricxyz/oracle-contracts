// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {MultiplierOracle} from "../../../contracts/oracles/multiplier/MultiplierOracle.sol";
import {B20AssetParams} from "../../../contracts/oracles/multiplier/B20AssetParams.sol";
import {RobinhoodStockTokenParams} from "../../../contracts/oracles/multiplier/RobinhoodStockTokenParams.sol";
import {AnchoredPriceProvider} from "../../../contracts/AnchoredPriceProvider.sol";
import {PriceProvider} from "../../../contracts/PriceProvider.sol";
import {IAnchoredProviderFactory} from "../../../contracts/interfaces/IAnchoredProviderFactory.sol";
import {IOffchainOracle} from "../../../contracts/interfaces/IOffchainOracle.sol";
import {IOracleParams} from "../../../contracts/interfaces/IOracleParams.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {TestOracle} from "../../utils/TestOracle.sol";
import {MockPoolFactory} from "../../mocks/MockPoolFactory.sol";
import {MockPool} from "../../mocks/MockPool.sol";

/// @notice Coinbase B20 Asset without the ERC-8056 schedule getters: `multiplier()` only. Etched at a
///         real B20 Asset address, so its storage starts empty until set.
contract MockB20Asset {
    uint256 public multiplier;

    function setMultiplier(uint256 m) external {
        multiplier = m;
    }
}

/// @notice Mirrors Coinbase's OracleRegistry: multiplier read live from the token, pause flag set by the
///         issuer around corporate actions.
contract MockOracleRegistry is IOracleParams {
    mapping(address => bool) internal _paused;

    function getOracleParams(address token) external view returns (uint256 multiplier, bool paused) {
        paused = _paused[token];
        multiplier = MockB20Asset(token).multiplier();
    }

    function setOraclePaused(address token, bool paused) external {
        _paused[token] = paused;
    }
}

/// @notice Robinhood Stock Token surface: ERC-8056 `uiMultiplier()` and the issuer's `oraclePaused()`.
contract MockStockToken {
    uint256 public uiMultiplier = 1e18;
    bool public oraclePaused;

    function setUiMultiplier(uint256 m) external {
        uiMultiplier = m;
    }

    function setOraclePaused(bool p) external {
        oraclePaused = p;
    }
}

/// @notice A token with an ERC-8056 schedule, as Robinhood Stock Tokens and B20 Assets have:
///         `uiMultiplier()` / `multiplier()` switch to the announced value by themselves at
///         `effectiveAt`, as the live tokens do. Storage starts empty when etched, hence `setCurrent`.
contract MockScheduledStockToken {
    uint256 public current = 1e18;
    uint256 public newUIMultiplier = 1e18;
    uint256 public effectiveAt;
    bool public oraclePaused;

    function setCurrent(uint256 m) external {
        current = m;
    }

    function schedule(uint256 next, uint256 at) external {
        newUIMultiplier = next;
        effectiveAt = at;
    }

    function setOraclePaused(bool p) external {
        oraclePaused = p;
    }

    function uiMultiplier() public view returns (uint256) {
        return effectiveAt != 0 && block.timestamp >= effectiveAt ? newUIMultiplier : current;
    }

    /// @dev The B20 name of the same value; Coinbase's OracleRegistry reads this one.
    function multiplier() external view returns (uint256) {
        return uiMultiplier();
    }
}

/// @notice A token whose schedule getters can each answer validly, with nothing, with 16 bytes, with
///         64 bytes, or with a revert, as a non-reverting fallback, a precompile or a broken token might.
contract MockOddScheduleToken {
    uint8 public constant VALID = 0;
    uint8 public constant EMPTY = 1;
    uint8 public constant SHORT = 2;
    uint8 public constant LONG = 3;
    uint8 public constant REVERTS = 4;

    uint8 public atMode;
    uint8 public nextMode;
    uint256 public at;

    function set(uint8 atMode_, uint8 nextMode_, uint256 at_) external {
        (atMode, nextMode, at) = (atMode_, nextMode_, at_);
    }

    function uiMultiplier() external pure returns (uint256) {
        return 1e18;
    }

    function multiplier() external pure returns (uint256) {
        return 1e18;
    }

    function oraclePaused() external pure returns (bool) {
        return false;
    }

    function effectiveAt() external view returns (uint256) {
        _answer(atMode, at);
    }

    function newUIMultiplier() external view returns (uint256) {
        _answer(nextMode, 1.02e18);
    }

    function _answer(uint8 mode, uint256 value) internal pure {
        assembly {
            mstore(0, value)
            mstore(0x20, value)
            switch mode
            case 1 { return(0, 0) }
            case 2 { return(0, 16) }
            case 3 { return(0, 64) }
            case 4 { revert(0, 32) }
            default { return(0, 32) }
        }
    }
}

/// @notice An ERC-8056 token without the pause getter.
contract MockScaledOnly {
    uint256 public uiMultiplier = 1e18;
}

/// @notice A token whose multiplier read reverts with a payload of a chosen size; the Robinhood adapter
///         bubbles that revert data up to the oracle.
contract MockRevertBombToken {
    uint256 public size;

    function setSize(uint256 s) external {
        size = s;
    }

    function uiMultiplier() external view returns (uint256) {
        uint256 s = size;
        assembly {
            revert(0, s)
        }
    }

    function oraclePaused() external pure returns (bool) {
        return false;
    }
}

/// @notice An adapter that burns all the gas it is given.
contract MockGasBurnerParams is IOracleParams {
    function getOracleParams(address) external pure returns (uint256, bool) {
        while (true) {}
        return (0, false);
    }
}

/// @notice An adapter whose answer starts with a valid (multiplier, paused) pair but runs to `size` bytes.
contract MockHugeAnswerParams {
    uint256 public size = 64;

    function setSize(uint256 s) external {
        size = s;
    }

    function getOracleParams(address) external view returns (uint256, bool) {
        uint256 s = size;
        assembly {
            mstore(0, 1000000000000000000)
            mstore(0x20, 0)
            return(0, s)
        }
    }
}

/// @notice An adapter answering 64 bytes whose bool word is neither 0 nor 1.
contract MockNonCanonicalBoolParams {
    function getOracleParams(address) external pure returns (uint256, bool) {
        assembly {
            mstore(0, 1000000000000000000)
            mstore(0x20, 2)
            return(0, 0x40)
        }
    }
}

/// @notice Reads a feed off-chain style (tx.origin 0 skips the pool gate) under a gas budget, and
///         reports a revert as a distinct outcome from a stall.
contract BudgetedReader {
    function read(MultiplierOracle o, bytes32 feed, uint256 gasBudget)
        external
        returns (bool reverted, uint256 mid, uint256 spread)
    {
        (bool ok, bytes memory ret) =
            address(o).call{gas: gasBudget}(abi.encodeCall(MultiplierOracle.price, (feed, address(0))));
        if (!ok) return (true, 0, 0);
        (mid, spread,,) = abi.decode(ret, (uint256, uint256, uint16, uint256));
    }
}

contract MultiplierOracleTest is Test {
    enum Issuer {
        Coinbase,
        Robinhood
    }

    uint256 private constant Q64 = 1 << 64;
    uint256 private constant WAD = 1e18;
    uint16 private constant STALL = type(uint16).max;
    uint16 private constant SPREAD = 100; // 1 bp
    uint256 private constant T0 = 1_000_000;

    /// @dev Coinbase AAPLc on Base — a genuine B20 Asset address (the mock is etched there).
    address private constant AAPLC_TOKEN = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    bytes32 private constant AAPL = keccak256("pyth:Equity.US.AAPL/USD");
    bytes32 private constant USDC = keccak256("pyth:Crypto.USDC/USD");

    TestOracle private underlying;
    MockPoolFactory private poolFactory;
    MultiplierOracle private oracle;
    bytes32 private usdcPt;

    MockB20Asset private cbToken;
    MockOracleRegistry private cbRegistry;
    B20AssetParams private cbParams;
    bytes32 private cbFeed;

    MockStockToken private rhToken;
    RobinhoodStockTokenParams private rhParams;
    bytes32 private rhFeed;

    /// @dev This contract plays both the pool and the provider reading through it.
    address private inSwapAs;

    function inSwap() external view returns (address) {
        return inSwapAs;
    }

    function setUp() public {
        vm.warp(T0);
        vm.deal(address(this), 1 ether);

        underlying = new TestOracle(address(this), 60);
        poolFactory = new MockPoolFactory();
        underlying.addApprovedFactory(address(poolFactory));

        oracle = new MultiplierOracle(address(this), underlying);
        underlying.addIntegrator(address(oracle)); // the only admin step on the existing oracle

        vm.etch(AAPLC_TOKEN, address(new MockB20Asset()).code);
        cbToken = MockB20Asset(AAPLC_TOKEN);
        cbToken.setMultiplier(1e18);
        cbRegistry = new MockOracleRegistry();
        cbParams = new B20AssetParams(cbRegistry);
        oracle.addParamsAdapter(cbParams);
        cbFeed = oracle.createFeed(AAPL, AAPLC_TOKEN, cbParams);

        rhToken = new MockStockToken();
        rhParams = new RobinhoodStockTokenParams();
        oracle.addParamsAdapter(rhParams);
        rhFeed = oracle.createFeed(AAPL, address(rhToken), rhParams);

        usdcPt = oracle.createFeed(USDC, address(0), IOracleParams(address(0)));

        poolFactory.setPool(address(this), true);
        oracle.register{value: 1}(cbFeed, address(this), address(poolFactory)); // registers AAPL underneath
        oracle.register{value: 1}(usdcPt, address(this), address(poolFactory));
        inSwapAs = address(this);
    }

    // ── helpers ──────────────────────────────────────────────────────────

    function _feed(Issuer i) internal view returns (bytes32) {
        return i == Issuer.Coinbase ? cbFeed : rhFeed;
    }

    function _token(Issuer i) internal view returns (address) {
        return i == Issuer.Coinbase ? address(cbToken) : address(rhToken);
    }

    function _setMultiplier(Issuer i, uint256 m) internal {
        if (i == Issuer.Coinbase) cbToken.setMultiplier(m);
        else rhToken.setUiMultiplier(m);
    }

    function _setPaused(Issuer i, bool p) internal {
        if (i == Issuer.Coinbase) cbRegistry.setOraclePaused(address(cbToken), p);
        else rhToken.setOraclePaused(p);
    }

    /// @dev A fresh underlying print one second later.
    function _print(uint64 p) internal {
        vm.warp(vm.getBlockTimestamp() + 1);
        underlying.setData(AAPL, p, SPREAD, 0, vm.getBlockTimestamp());
    }

    function _assertStalled(bytes32 feed) internal {
        (uint256 mid, uint256 spread,,) = oracle.price(feed, address(this));
        assertEq(mid, 0, "stalled mid");
        assertEq(spread, STALL, "stall sentinel");
    }

    function _assertQuotes(bytes32 feed, uint256 expected) internal {
        (uint256 mid, uint256 spread,,) = oracle.price(feed, address(this));
        assertEq(mid, expected, "scaled mid");
        assertEq(spread, SPREAD, "spread carried over");
    }

    // ── scenarios, run for every issuer ──────────────────────────────────

    function _scales(Issuer i) internal {
        _setMultiplier(i, 1.02e18);
        _print(250e8);
        _assertQuotes(_feed(i), 255e8);
    }

    /// @dev The issuer is trusted outright: a multiplier it publishes is applied as is, at once.
    function _appliedAsPublished(Issuer i) internal {
        _print(200e8);
        _assertQuotes(_feed(i), 200e8);
        _setMultiplier(i, 1.5e18);
        _assertQuotes(_feed(i), 300e8);
    }

    function _stallsWhilePaused(Issuer i) internal {
        _print(200e8);
        _setPaused(i, true);
        _assertStalled(_feed(i));
        _setPaused(i, false);
        _assertQuotes(_feed(i), 200e8);
    }

    /// @dev 4:1 split under the issuer's procedure: pause, flip the multiplier, wait for the market to
    ///      reprice the share, unpause. Neither half-applied state is ever quoted.
    function _split(Issuer i) internal {
        _print(200e8);
        _assertQuotes(_feed(i), 200e8);

        _setPaused(i, true);
        _setMultiplier(i, 4e18);
        _print(201e8); // pre-split share price: x4 would quote 804
        _assertStalled(_feed(i));
        _print(50.25e8);
        _assertStalled(_feed(i));

        _setPaused(i, false);
        _assertQuotes(_feed(i), 201e8);
    }

    function _dividend(Issuer i) internal {
        _print(200e8);
        _setPaused(i, true);
        _setMultiplier(i, 1.003e18);
        _print(199.4e8); // ex-dividend
        _assertStalled(_feed(i));

        _setPaused(i, false);
        _assertQuotes(_feed(i), 199.9982e8);
    }

    function _zeroMultiplierStalls(Issuer i) internal {
        _print(200e8);
        _setMultiplier(i, 0);
        _assertStalled(_feed(i));
    }

    /// @dev An unmodified AnchoredPriceProvider quoting token/USDC as the synthetic token/USD ÷ USDC/USD,
    ///      both legs read through this oracle by a pool mid-swap.
    function _endToEnd(Issuer i) internal {
        AnchoredPriceProvider app = new AnchoredPriceProvider(
            address(this),
            address(oracle),
            _feed(i),
            usdcPt,
            5e13, // 0.5 bps min margin
            60,
            WAD,
            false,
            int256(0),
            _token(i),
            address(0xCAFE),
            IAnchoredProviderFactory.InitialConfig({
                source: address(0),
                baseMaxStaleness: 60,
                quoteMaxStaleness: 60,
                baseSpreadMult: WAD,
                quoteSpreadMult: WAD
            })
        );
        MockPool pool = new MockPool(address(app));
        poolFactory.setPool(address(pool), true);
        oracle.register{value: 1}(_feed(i), address(pool), address(poolFactory));
        oracle.register{value: 1}(usdcPt, address(pool), address(poolFactory));

        _setMultiplier(i, 1.02e18);
        _print(250e8);
        underlying.setData(USDC, 1e8, SPREAD, 0, vm.getBlockTimestamp());
        (uint128 bid, uint128 ask, uint128 ref) = pool.getQuote();
        assertEq(ref, 255 * Q64, "reference = share price x multiplier");
        assertLt(bid, ref);
        assertGt(ask, ref);

        // Corporate action in flight: the provider halts.
        _setPaused(i, true);
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        pool.getQuote();

        // Split applied on both sides, issuer unpauses: quoting resumes at a continuous price.
        _setMultiplier(i, 4.08e18);
        _print(62.5e8);
        underlying.setData(USDC, 1e8, SPREAD, 0, vm.getBlockTimestamp());
        _setPaused(i, false);
        (,, ref) = pool.getQuote();
        assertEq(ref, 255 * Q64);
    }

    function test_Scales_Coinbase() public {
        _scales(Issuer.Coinbase);
    }

    function test_Scales_Robinhood() public {
        _scales(Issuer.Robinhood);
    }

    function test_AppliedAsPublished_Coinbase() public {
        _appliedAsPublished(Issuer.Coinbase);
    }

    function test_AppliedAsPublished_Robinhood() public {
        _appliedAsPublished(Issuer.Robinhood);
    }

    function test_StallsWhilePaused_Coinbase() public {
        _stallsWhilePaused(Issuer.Coinbase);
    }

    function test_StallsWhilePaused_Robinhood() public {
        _stallsWhilePaused(Issuer.Robinhood);
    }

    function test_Split_Coinbase() public {
        _split(Issuer.Coinbase);
    }

    function test_Split_Robinhood() public {
        _split(Issuer.Robinhood);
    }

    function test_Dividend_Coinbase() public {
        _dividend(Issuer.Coinbase);
    }

    function test_Dividend_Robinhood() public {
        _dividend(Issuer.Robinhood);
    }

    function test_ZeroMultiplierStalls_Coinbase() public {
        _zeroMultiplierStalls(Issuer.Coinbase);
    }

    function test_ZeroMultiplierStalls_Robinhood() public {
        _zeroMultiplierStalls(Issuer.Robinhood);
    }

    function test_EndToEnd_Coinbase() public {
        _endToEnd(Issuer.Coinbase);
    }

    function test_EndToEnd_Robinhood() public {
        _endToEnd(Issuer.Robinhood);
    }

    // ── params adapters ──────────────────────────────────────────────────

    function test_B20AssetParams_ReadsTheIssuerRegistry() public {
        cbToken.setMultiplier(1.02e18);
        cbRegistry.setOraclePaused(AAPLC_TOKEN, true);
        (uint256 m, bool paused) = cbParams.getOracleParams(AAPLC_TOKEN);
        assertEq(m, 1.02e18);
        assertTrue(paused);
        assertEq(address(cbParams.REGISTRY()), address(cbRegistry));
    }

    function test_B20AssetParams_RejectsAnythingButB20Assets() public {
        vm.expectRevert(abi.encodeWithSelector(B20AssetParams.NotB20Asset.selector, address(rhToken)));
        cbParams.getOracleParams(address(rhToken));
        // B20 STABLECOIN variant (byte 11 = 0x01): no multiplier.
        address stable = 0xb200000000000000000001c2E324D24D7eEcD1fb;
        vm.expectRevert(abi.encodeWithSelector(B20AssetParams.NotB20Asset.selector, stable));
        cbParams.getOracleParams(stable);

        vm.expectRevert(B20AssetParams.ZeroAddress.selector);
        new B20AssetParams(IOracleParams(address(0)));
    }

    function test_RobinhoodStockTokenParams_ReadsTheToken() public {
        rhToken.setUiMultiplier(1.000566080061092436e18); // Robinhood AAPL's live multiplier
        rhToken.setOraclePaused(true);
        (uint256 m, bool paused) = rhParams.getOracleParams(address(rhToken));
        assertEq(m, 1.000566080061092436e18);
        assertTrue(paused);
    }

    /// @dev An adapter that cannot answer stalls the feed instead of reverting the read: a token of the
    ///      wrong family behind either adapter, an ERC-8056 token without the pause getter, and a
    ///      B20-shaped address with nothing behind it.
    function test_AdapterThatCannotAnswerStalls() public {
        _print(200e8);
        _assertStalled(oracle.createFeed(AAPL, address(rhToken), cbParams));
        _assertStalled(oracle.createFeed(AAPL, AAPLC_TOKEN, rhParams));
        _assertStalled(oracle.createFeed(AAPL, address(new MockScaledOnly()), rhParams));
        _assertStalled(oracle.createFeed(AAPL, 0xb200000000000000000000000000000000000001, cbParams));
    }

    // ── scheduled multiplier (ERC-8056: Robinhood and B20) ──

    /// @dev A B20-shaped address (top 11 bytes 0xb2 + ten zero bytes) for the Coinbase schedule mock.
    address private constant SCHEDULED_B20 = 0xB2000000000000000000005C4ed01E5c4ED01E5C;

    /// @dev A token with an ERC-8056 schedule behind the issuer's adapter. For Coinbase the mock is etched
    ///      at a B20 address and read through the registry, which passes its `multiplier()` through.
    function _scheduledFeed(Issuer i) internal returns (MockScheduledStockToken token, bytes32 feed) {
        if (i == Issuer.Robinhood) {
            token = new MockScheduledStockToken();
            feed = oracle.createFeed(AAPL, address(token), rhParams);
        } else {
            vm.etch(SCHEDULED_B20, address(new MockScheduledStockToken()).code);
            token = MockScheduledStockToken(SCHEDULED_B20);
            feed = oracle.createFeed(AAPL, SCHEDULED_B20, cbParams);
        }
        token.setCurrent(1e18);
    }

    /// @dev The issuer's pause flag: on the token for Robinhood, in the registry for Coinbase.
    function _pauseScheduled(Issuer i, MockScheduledStockToken token) internal {
        if (i == Issuer.Robinhood) token.setOraclePaused(true);
        else cbRegistry.setOraclePaused(address(token), true);
    }

    /// A pending dividend-sized change is priced at the announced multiplier at once, so there is no
    /// step left at `effectiveAt` (the live AAPL reinvestment on Robinhood: +5.66 bp).
    function _pendingDividendIsAppliedAtOnce(Issuer i) internal {
        (MockScheduledStockToken token, bytes32 feed) = _scheduledFeed(i);
        _print(250e8);
        _assertQuotes(feed, 250e8);

        uint256 at = vm.getBlockTimestamp() + 1 hours;
        token.schedule(1.000566e18, at);
        _assertQuotes(feed, 250.1415e8); // announced value, before effectiveAt

        vm.warp(at + 1);
        underlying.setData(AAPL, 250e8, SPREAD, 0, vm.getBlockTimestamp());
        _assertQuotes(feed, 250.1415e8); // no step when it takes effect
    }

    /// A pending split stalls the feed until it takes effect; from there on the issuer's flag guards.
    function _pendingSplitStallsUntilEffective(Issuer i) internal {
        (MockScheduledStockToken token, bytes32 feed) = _scheduledFeed(i);
        _print(250e8);
        uint256 at = vm.getBlockTimestamp() + 1 hours;
        token.schedule(4e18, at); // 4:1 split
        _assertStalled(feed);

        vm.warp(at + 1);
        underlying.setData(AAPL, 62.5e8, SPREAD, 0, vm.getBlockTimestamp());
        _assertQuotes(feed, 250e8); // 62.5 x 4: continuous once the share has split too
    }

    /// The small/large boundary sits at exactly SMALL_CHANGE_BPS (10%) of the current multiplier.
    function _scheduleBoundaryIsTenPercent(Issuer i) internal {
        (MockScheduledStockToken token, bytes32 feed) = _scheduledFeed(i);
        _print(100e8);
        uint256 at = vm.getBlockTimestamp() + 1 hours;

        token.schedule(1.1e18, at);
        _assertQuotes(feed, 110e8); // exactly 10%: applied
        token.schedule(1.1e18 + 1, at);
        _assertStalled(feed); // just over: stalls
        token.schedule(0.9e18, at);
        _assertQuotes(feed, 90e8); // a 10% decrease is applied too
    }

    /// A schedule that has already taken effect is not pending: the token's own multiplier applies.
    function _elapsedScheduleIsNotPending(Issuer i) internal {
        (MockScheduledStockToken token, bytes32 feed) = _scheduledFeed(i);
        _print(100e8);
        token.schedule(3e18, vm.getBlockTimestamp()); // effective now
        _assertQuotes(feed, 300e8);
    }

    /// The issuer's flag still stalls the feed while a small change is pending.
    function _pauseFlagStillAppliesWithAPendingChange(Issuer i) internal {
        (MockScheduledStockToken token, bytes32 feed) = _scheduledFeed(i);
        _print(100e8);
        token.schedule(1.0005e18, vm.getBlockTimestamp() + 1 hours);
        _pauseScheduled(i, token);
        _assertStalled(feed);
    }

    /// For every issuer, a pending change is acted on whatever its lead time: a small one
    /// announced ten days ahead is priced at once, and a split announced ten days ahead pauses at once,
    /// including after the market has split the share and before the multiplier follows.
    function _anyLeadTimeIsActedOn(Issuer i) internal {
        (MockScheduledStockToken token, bytes32 feed) = _scheduledFeed(i);
        _print(100e8);
        uint256 at = vm.getBlockTimestamp() + 10 days;

        token.schedule(1.02e18, at); // small, ten days ahead
        _assertQuotes(feed, 102e8);

        token.schedule(4e18, at); // 4:1 split, ten days ahead
        _assertStalled(feed);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        underlying.setData(AAPL, 25e8, SPREAD, 0, vm.getBlockTimestamp()); // the share split first
        _assertStalled(feed); // 25 x 1 would underprice the token 4x: still paused

        vm.warp(at + 1);
        underlying.setData(AAPL, 25e8, SPREAD, 0, vm.getBlockTimestamp());
        _assertQuotes(feed, 100e8); // 25 x 4 once the multiplier follows
    }

    /// Each schedule getter answering anything but a single 32-byte word (nothing, 16 or 64 bytes, a
    /// revert) reads as "no schedule": the issuer's current answer is used, and nothing reverts.
    function _oddScheduleAnswersReadAsAbsent(Issuer i) internal {
        address token;
        bytes32 feed;
        if (i == Issuer.Robinhood) {
            token = address(new MockOddScheduleToken());
            feed = oracle.createFeed(AAPL, token, rhParams);
        } else {
            token = SCHEDULED_B20;
            vm.etch(token, address(new MockOddScheduleToken()).code);
            feed = oracle.createFeed(AAPL, token, cbParams);
        }
        MockOddScheduleToken odd = MockOddScheduleToken(token);
        _print(100e8);
        uint256 at = vm.getBlockTimestamp() + 1 hours;

        odd.set(0, 0, at);
        _assertQuotes(feed, 102e8); // both valid: the +2% change is applied
        for (uint8 mode = 1; mode <= 4; ++mode) {
            odd.set(mode, 0, at); // effectiveAt() malformed
            _assertQuotes(feed, 100e8);
            odd.set(0, mode, at); // newUIMultiplier() malformed
            _assertQuotes(feed, 100e8);
        }
    }

    /// A huge announced multiplier is a large change: the adapter answers paused, without overflowing.
    function _hugeAnnouncedMultiplierPauses(Issuer i) internal {
        (MockScheduledStockToken token,) = _scheduledFeed(i);
        token.schedule(type(uint256).max, vm.getBlockTimestamp() + 1 hours);
        (uint256 m, bool paused) =
            (i == Issuer.Robinhood ? IOracleParams(rhParams) : IOracleParams(cbParams)).getOracleParams(address(token));
        assertEq(m, 1e18);
        assertTrue(paused);
    }

    function test_AnyLeadTimeIsActedOn_Coinbase() public {
        _anyLeadTimeIsActedOn(Issuer.Coinbase);
    }

    function test_AnyLeadTimeIsActedOn_Robinhood() public {
        _anyLeadTimeIsActedOn(Issuer.Robinhood);
    }

    function test_OddScheduleAnswersReadAsAbsent_Coinbase() public {
        _oddScheduleAnswersReadAsAbsent(Issuer.Coinbase);
    }

    function test_OddScheduleAnswersReadAsAbsent_Robinhood() public {
        _oddScheduleAnswersReadAsAbsent(Issuer.Robinhood);
    }

    function test_HugeAnnouncedMultiplierPauses_Coinbase() public {
        _hugeAnnouncedMultiplierPauses(Issuer.Coinbase);
    }

    function test_HugeAnnouncedMultiplierPauses_Robinhood() public {
        _hugeAnnouncedMultiplierPauses(Issuer.Robinhood);
    }

    function test_AdaptersReportVersion120() public view {
        assertEq(cbParams.version(), "1.2.0");
        assertEq(rhParams.version(), "1.2.0");
    }

    function test_PendingDividendIsAppliedAtOnce_Coinbase() public {
        _pendingDividendIsAppliedAtOnce(Issuer.Coinbase);
    }

    function test_PendingDividendIsAppliedAtOnce_Robinhood() public {
        _pendingDividendIsAppliedAtOnce(Issuer.Robinhood);
    }

    function test_PendingSplitStallsUntilEffective_Coinbase() public {
        _pendingSplitStallsUntilEffective(Issuer.Coinbase);
    }

    function test_PendingSplitStallsUntilEffective_Robinhood() public {
        _pendingSplitStallsUntilEffective(Issuer.Robinhood);
    }

    function test_ScheduleBoundaryIsTenPercent_Coinbase() public {
        _scheduleBoundaryIsTenPercent(Issuer.Coinbase);
    }

    function test_ScheduleBoundaryIsTenPercent_Robinhood() public {
        _scheduleBoundaryIsTenPercent(Issuer.Robinhood);
    }

    function test_ElapsedScheduleIsNotPending_Coinbase() public {
        _elapsedScheduleIsNotPending(Issuer.Coinbase);
    }

    function test_ElapsedScheduleIsNotPending_Robinhood() public {
        _elapsedScheduleIsNotPending(Issuer.Robinhood);
    }

    function test_PauseFlagStillAppliesWithAPendingChange_Coinbase() public {
        _pauseFlagStillAppliesWithAPendingChange(Issuer.Coinbase);
    }

    function test_PauseFlagStillAppliesWithAPendingChange_Robinhood() public {
        _pauseFlagStillAppliesWithAPendingChange(Issuer.Robinhood);
    }

    /// A B20 Asset without schedule getters: the registry's answer is used as is.
    function test_B20WithoutScheduleGettersUsesRegistryAnswer() public {
        _print(100e8);
        cbToken.setMultiplier(1.5e18);
        _assertQuotes(cbFeed, 150e8); // MockB20Asset has no newUIMultiplier()/effectiveAt()
    }

    /// @dev Reads `feed` through a budgeted off-chain call and requires a stall, not a revert.
    function _assertStallsUnderBudget(bytes32 feed, uint256 gasBudget) internal {
        BudgetedReader reader = new BudgetedReader();
        vm.prank(address(reader), address(0));
        (bool reverted, uint256 mid, uint256 spread) = reader.read(oracle, feed, gasBudget);
        assertFalse(reverted, "read reverted instead of stalling");
        assertEq(mid, 0, "stalled mid");
        assertEq(spread, STALL, "stall sentinel");
    }

    /// A token behind the Robinhood adapter reverting with a large payload stalls the read at every
    /// size: the output copy is capped at 64 bytes. The sizes cover the ranges where copying the whole
    /// payload would exhaust the budget (1M: about 380-460 KB; 3M: about 690-840 KB).
    function test_LargeRevertPayloadStalls() public {
        _print(200e8);
        MockRevertBombToken bomb = new MockRevertBombToken();
        bytes32 feed = oracle.createFeed(AAPL, address(bomb), rhParams);
        uint256[6] memory sizes = [uint256(32), 100_000, 400_000, 450_000, 700_000, 800_000];
        uint256[2] memory budgets = [uint256(1_000_000), 3_000_000];
        for (uint256 b; b < budgets.length; ++b) {
            for (uint256 i; i < sizes.length; ++i) {
                bomb.setSize(sizes[i]);
                _assertStallsUnderBudget(feed, budgets[b]);
            }
        }
    }

    /// An adapter that burns its gas is cut off at ADAPTER_GAS_LIMIT, and the read stalls.
    function test_GasBurningAdapterStalls() public {
        _print(200e8);
        MockGasBurnerParams burner = new MockGasBurnerParams();
        oracle.addParamsAdapter(burner);
        bytes32 feed = oracle.createFeed(AAPL, address(rhToken), burner);
        _assertStallsUnderBudget(feed, 1_000_000);
        _assertStallsUnderBudget(feed, 30_000_000);
    }

    /// An answer longer than 64 bytes is malformed, however valid its first two words, and is never
    /// copied in full: even a large one stalls.
    function test_OversizedAnswerStalls() public {
        _print(200e8);
        MockHugeAnswerParams huge = new MockHugeAnswerParams();
        oracle.addParamsAdapter(IOracleParams(address(huge)));
        bytes32 feed = oracle.createFeed(AAPL, address(rhToken), IOracleParams(address(huge)));
        _assertQuotes(feed, 200e8); // exactly 64 bytes: a valid answer
        huge.setSize(96);
        _assertStalled(feed);
        huge.setSize(300_000);
        _assertStallsUnderBudget(feed, 3_000_000);
    }

    /// A bool word other than 0 or 1 is malformed: the read stalls instead of reverting in decode.
    function test_NonCanonicalBoolStalls() public {
        _print(200e8);
        MockNonCanonicalBoolParams bad = new MockNonCanonicalBoolParams();
        oracle.addParamsAdapter(IOracleParams(address(bad)));
        _assertStalled(oracle.createFeed(AAPL, address(rhToken), IOracleParams(address(bad))));
    }

    // ── underlying ───────────────────────────────────────────────────────

    function test_PassthroughFeedIsUnscaled() public {
        underlying.setData(USDC, 0.9998e8, 7, 0, vm.getBlockTimestamp());
        (uint256 mid, uint256 spread,, uint256 refTime) = oracle.price(usdcPt, address(this));
        assertEq(mid, 0.9998e8);
        assertEq(spread, 7);
        assertEq(refTime, vm.getBlockTimestamp());
    }

    function test_UnderlyingGuardAndStallAreEnforced() public {
        underlying.setPriceGuard(AAPL, 100e8, 300e8);
        _print(350e8);
        _assertStalled(rhFeed);
        _print(50e8);
        _assertStalled(rhFeed); // below the guard's min
        _print(250e8);
        _assertQuotes(rhFeed, 250e8);

        vm.warp(vm.getBlockTimestamp() + 1);
        underlying.setData(AAPL, 250e8, STALL, 0, vm.getBlockTimestamp());
        _assertStalled(rhFeed);

        (uint128 gMin, uint128 gMax) = oracle.priceGuard(rhFeed);
        assertEq(gMin, 0);
        assertEq(gMax, 0);
    }

    /// A saturated underlying spread (65 534, upstream uncertainty lost) stalls like the sentinel; one
    /// below it still quotes, with the spread carried over.
    function test_SaturatedUnderlyingSpreadStalls() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        underlying.setData(AAPL, 250e8, STALL - 1, 0, vm.getBlockTimestamp());
        _assertStalled(rhFeed);

        vm.warp(vm.getBlockTimestamp() + 1);
        underlying.setData(AAPL, 250e8, STALL - 2, 0, vm.getBlockTimestamp());
        (uint256 mid, uint256 spread,,) = oracle.price(rhFeed, address(this));
        assertEq(mid, 250e8);
        assertEq(spread, STALL - 2);
    }

    /// A plain PriceProvider reads the stock feed the same way an AnchoredPriceProvider does.
    function test_EndToEnd_PlainPriceProvider() public {
        PriceProvider pp =
            new PriceProvider(address(this), address(oracle), rhFeed, int256(0), 60, address(rhToken), address(0xCAFE));
        pp.setConfidenceParam(10_000); // 1x the underlying spread (this contract plays the factory)
        MockPool pool = new MockPool(address(pp));
        poolFactory.setPool(address(pool), true);
        oracle.register{value: 1}(rhFeed, address(pool), address(poolFactory));

        _setMultiplier(Issuer.Robinhood, 1.02e18);
        _print(250e8);
        (uint128 bid, uint128 ask, uint128 ref) = pool.getQuote();
        assertEq(ref, 255 * Q64, "reference = share price x multiplier");
        assertLt(bid, ref);
        assertGt(ask, ref);

        _setPaused(Issuer.Robinhood, true);
        vm.expectRevert(PriceProvider.FeedStalled.selector);
        pool.getQuote();
    }

    // ── feeds and access ─────────────────────────────────────────────────

    function test_CreateFeedIsPermissionlessDeterministicAndIdempotent() public {
        assertEq(oracle.feedIdOf(AAPL, address(rhToken), rhParams), rhFeed);
        vm.prank(makeAddr("anyone"));
        assertEq(oracle.createFeed(AAPL, address(rhToken), rhParams), rhFeed, "existing feed returned");

        vm.expectRevert(MultiplierOracle.BadFeedConfig.selector);
        oracle.createFeed(bytes32(0), address(rhToken), rhParams);
        vm.expectRevert(MultiplierOracle.BadFeedConfig.selector);
        oracle.createFeed(AAPL, address(rhToken), IOracleParams(address(0)));
        vm.expectRevert(MultiplierOracle.BadFeedConfig.selector);
        oracle.createFeed(AAPL, address(0), rhParams);

        bytes32 unknown = oracle.feedIdOf(keccak256("pyth:unknown"), address(rhToken), rhParams);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, unknown));
        oracle.price(unknown, address(this));
    }

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(MultiplierOracle.ZeroAddress.selector);
        new MultiplierOracle(address(this), TestOracle(payable(address(0))));
        vm.expectRevert(MultiplierOracle.ZeroAddress.selector);
        new MultiplierOracle(address(0), underlying);
    }

    // ── params adapter allow-list ────────────────────────────────────────

    function test_FeedsCanOnlyBindAllowListedAdapters() public {
        RobinhoodStockTokenParams rogue = new RobinhoodStockTokenParams();
        vm.expectRevert(abi.encodeWithSelector(MultiplierOracle.ParamsAdapterNotAllowed.selector, address(rogue)));
        oracle.createFeed(AAPL, address(rhToken), rogue);

        oracle.addParamsAdapter(rogue);
        _print(200e8);
        _assertQuotes(oracle.createFeed(AAPL, address(rhToken), rogue), 200e8);
    }

    /// @dev Removing an adapter is the kill switch: every feed on it stalls until it is added back.
    function test_RemovingAnAdapterStallsItsFeeds() public {
        _print(200e8);
        _assertQuotes(rhFeed, 200e8);

        vm.expectEmit(true, false, false, false, address(oracle));
        emit MultiplierOracle.ParamsAdapterRemoved(address(rhParams));
        oracle.removeParamsAdapter(rhParams);
        _assertStalled(rhFeed);
        _assertQuotes(cbFeed, 200e8); // other adapters are unaffected
        vm.expectRevert(abi.encodeWithSelector(MultiplierOracle.ParamsAdapterNotAllowed.selector, address(rhParams)));
        oracle.createFeed(keccak256("pyth:other"), address(rhToken), rhParams);

        oracle.addParamsAdapter(rhParams);
        _assertQuotes(rhFeed, 200e8);
    }

    /// One feed can be stopped without touching the rest of its family: another token on the same
    /// adapter keeps quoting. Re-enabling resumes it, and createFeed still returns the disabled feed.
    function test_DisablingAFeedStallsOnlyThatFeed() public {
        _print(200e8);
        MockStockToken other = new MockStockToken();
        other.setUiMultiplier(2e18);
        bytes32 otherFeed = oracle.createFeed(AAPL, address(other), rhParams); // same adapter as rhFeed

        vm.expectEmit(true, false, false, true, address(oracle));
        emit MultiplierOracle.FeedDisabled(rhFeed, true);
        oracle.setFeedDisabled(rhFeed, true);
        assertTrue(oracle.feedDisabled(rhFeed));
        _assertStalled(rhFeed);
        _assertQuotes(otherFeed, 400e8); // same family, still quoting
        _assertQuotes(cbFeed, 200e8);
        assertEq(oracle.createFeed(AAPL, address(rhToken), rhParams), rhFeed);

        oracle.setFeedDisabled(rhFeed, false);
        _assertQuotes(rhFeed, 200e8);
    }

    /// A passthrough feed has no adapter, so this switch is the only one on this contract that stops it.
    function test_DisablingAPassthroughFeedStallsIt() public {
        vm.warp(vm.getBlockTimestamp() + 1);
        underlying.setData(USDC, 1e8, SPREAD, 0, vm.getBlockTimestamp());
        (uint256 mid,,,) = oracle.price(usdcPt, address(this));
        assertEq(mid, 1e8);

        oracle.setFeedDisabled(usdcPt, true);
        _assertStalled(usdcPt);
    }

    function test_FeedDisableIsAdminOnlyAndNeedsAnExistingFeed() public {
        address stranger = makeAddr("stranger");
        bytes32 role = oracle.ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        oracle.setFeedDisabled(rhFeed, true);

        bytes32 unknown = keccak256("no such feed");
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.FeedNotFound.selector, unknown));
        oracle.setFeedDisabled(unknown, true);
    }

    function test_AllowListIsAdminCuratedAndEnumerable() public {
        assertTrue(oracle.isParamsAdapter(cbParams));
        assertEq(oracle.paramsAdapterCount(), 2);
        address[] memory adapters = oracle.getParamsAdapters(0, 2);
        assertEq(adapters[0], address(cbParams));
        assertEq(adapters[1], address(rhParams));

        vm.expectRevert(
            abi.encodeWithSelector(MultiplierOracle.ParamsAdapterAlreadyAllowed.selector, address(cbParams))
        );
        oracle.addParamsAdapter(cbParams);
        vm.expectRevert(MultiplierOracle.ZeroAddress.selector);
        oracle.addParamsAdapter(IOracleParams(address(0)));
        RobinhoodStockTokenParams unknown = new RobinhoodStockTokenParams();
        vm.expectRevert(abi.encodeWithSelector(MultiplierOracle.ParamsAdapterNotAllowed.selector, address(unknown)));
        oracle.removeParamsAdapter(unknown);

        address stranger = makeAddr("stranger");
        bytes memory unauthorized = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, oracle.ADMIN_ROLE()
        );
        vm.expectRevert(unauthorized);
        vm.prank(stranger);
        oracle.addParamsAdapter(unknown);
        vm.expectRevert(unauthorized);
        vm.prank(stranger);
        oracle.removeParamsAdapter(cbParams);
    }

    function test_GateMirrorsTheUnderlying() public {
        _print(200e8);

        inSwapAs = address(0xBEEF);
        vm.expectRevert(IOffchainOracle.InvalidInSwap.selector);
        oracle.price(rhFeed, address(this));
        inSwapAs = address(this);

        bytes32 otherUnderlying = keccak256("pyth:other");
        underlying.setData(otherUnderlying, 10e8, SPREAD, 0, vm.getBlockTimestamp());
        bytes32 unregistered = oracle.createFeed(otherUnderlying, address(rhToken), rhParams);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.NotRegistered.selector, unregistered, address(this)));
        oracle.price(unregistered, address(this));

        underlying.setBlacklist(address(this), true);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.Blacklisted.selector, address(this)));
        oracle.price(rhFeed, address(this));
    }

    /// The provider (caller) and the pool are checked against the blacklist separately: in the test
    /// above one address plays both, so each check is pinned down here on its own.
    function test_GateBlacklistsProviderAndPoolSeparately() public {
        _print(200e8);
        address provider = makeAddr("provider");
        inSwapAs = provider; // this contract is the pool; the provider is another address

        vm.prank(provider);
        (uint256 mid,,,) = oracle.price(rhFeed, address(this));
        assertEq(mid, 200e8);

        underlying.setBlacklist(provider, true);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.Blacklisted.selector, provider));
        oracle.price(rhFeed, address(this));
        underlying.setBlacklist(provider, false);

        underlying.setBlacklist(address(this), true);
        vm.prank(provider);
        vm.expectRevert(abi.encodeWithSelector(IOffchainOracle.Blacklisted.selector, address(this)));
        oracle.price(rhFeed, address(this));
    }

    function test_OffchainSimulationBypassesTheGate() public {
        _print(200e8);
        vm.prank(makeAddr("simulator"), address(0));
        (uint256 mid,,,) = oracle.price(rhFeed, address(0));
        assertEq(mid, 200e8);
    }

    function test_RegisterForwardsToTheUnderlyingFeed() public {
        address pool2 = makeAddr("pool2");
        poolFactory.setPool(pool2, true);
        assertFalse(oracle.registeredPool(rhFeed, pool2));
        oracle.register{value: 1}(rhFeed, pool2, address(poolFactory));
        assertTrue(oracle.registeredPool(rhFeed, pool2));
        assertTrue(oracle.registeredPool(cbFeed, pool2), "same underlying, same registration");
        assertTrue(underlying.registeredPool(AAPL, pool2));
    }
}
