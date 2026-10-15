// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IOffchainOracle} from "../../interfaces/IOffchainOracle.sol";
import {IOracleParams} from "../../interfaces/IOracleParams.sol";
import {IPool} from "../../interfaces/IPoolFactory.sol";
import {IPricedOracle} from "../../interfaces/IPricedOracle.sol";
import {OracleBase} from "../providers/OracleBase.sol";

/// @notice Prices tokenized stocks whose redemption ratio is an on-chain multiplier — ERC-8056 "Scaled UI
///         Amount" tokens: Robinhood Stock Tokens (Robinhood Chain) and Coinbase B20 Assets (Base). Design
///         notes, deployment and failure modes: docs/multiplier-oracle.md.
///
///         Two kinds of feed:
///         - Stock feed (token + params adapter) — what this contract exists for:
///               price(token/USD) = price(share/USD) × multiplier / 1e18,   stalled while paused
///           The multiplier and the issuer's pause flag come from the params adapter of the token's family.
///         - Passthrough feed (token = 0, params = 0): the underlying price as is — no multiplier, no
///           adapter, so the adapter allow-list does not apply to it. It is not a stock feed. It exists
///           only because a synthetic AnchoredPriceProvider reads both legs of a pair from one oracle: a
///           stock token quoted in USDC is priced as (stock feed token/USD) ÷ (passthrough feed USDC/USD).
///           A single-leg provider (token/USD, USDC taken as $1) needs no passthrough feed at all.
///
///         Why a multiplier. It is the number of shares one whole token redeems for. It moves on
///         corporate actions — a reinvested dividend nudges it up, an N:1 split multiplies it by N — while
///         raw ERC-20 balances never change. Upstream feeds (Pyth, Chainlink) price the share, not the
///         token, so a pool reading them directly drifts by every dividend and breaks on every split.
///
///         Params adapters. A stock feed names the adapter of its token family, answering
///         `getOracleParams(token) → (multiplier, paused)`:
///         - B20AssetParams: Coinbase B20 Assets on Base, through the issuer's OracleRegistry (the call
///           Chainlink's Coinbase total-return feeds gate on).
///         - RobinhoodStockTokenParams: Robinhood Stock Tokens, which report `uiMultiplier()` and
///           `oraclePaused()` themselves.
///         Another token family plugs in with its own adapter, without touching this contract. Adapters are
///         ADMIN-curated: a stock feed can only be created on an allow-listed adapter, and every read checks
///         the allow-list again, so removing an adapter stalls every stock feed built on it at once — the
///         kill switch for an adapter found faulty. Adding it back resumes them.
///
///         Trust model. The issuer is trusted outright; this contract adds no judgement of its own. The
///         share price and the multiplier never change at the same instant, so the issuer's pause flag is
///         what makes the product safe: while it is set, the stock feed's reads return the stall (mid 0,
///         spread STALL_SPREAD — pools halt swaps, withdrawals stay open), and quoting resumes by itself
///         when the issuer clears it. An adapter read that fails or returns a zero multiplier stalls that
///         stock feed too. A read that fails the access checks reverts instead (see `price`). The flag
///         only protects tokens whose issuer operates it: bind a stock feed to the adapter of the token's
///         own family. Issuer key compromise (unbacked mints, a forged multiplier) is out of this
///         contract's reach; bound it at the pool, e.g. with a flow limit.
///
///         Integration. A feed's id is the hash of (underlying feed, token, params); anyone can create one,
///         a stock feed only on an allow-listed adapter. This contract serves the same attributed
///         `price(feedId, pool)` and `priceGuard(feedId)` surface as the providers oracles, so
///         AnchoredPriceProvider, PriceProvider, their factories and the pools read it as they read those.
///         Pool access is gated exactly like the underlying (in-swap binding, blacklist,
///         registration on the underlying feed) and `register` is forwarded, so the underlying oracle's
///         registration fees and blacklist stay the single source of truth. Going live takes allow-listing
///         the adapters here and whitelisting this oracle as an integrator on the underlying oracle — its
///         pool gate binds the read to the direct caller, so it cannot be proxied. Providers created through
///         the anchored factory additionally need this oracle on the factory's allow-list; a provider
///         deployed directly does not.
contract MultiplierOracle is AccessControl, IPricedOracle {
    using EnumerableSet for EnumerableSet.AddressSet;

    string public constant version = "1.1.0";
    /// @notice Oracle family discriminator (the same `kind` vocabulary as the providers oracles), so
    ///         off-chain introspection and the anchored factory's allow-list curation can tell this lane apart.
    string public constant kind = "multiplier";
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint8 public constant decimals = 8;

    uint256 internal constant WAD = 1e18;
    /// @notice Gas forwarded to a params adapter. Both shipped adapters need a fraction of it: with
    ///         cold state, about 15k on Base and 23k on Robinhood Chain, schedule reads included.
    ///         B20: the issuer registry (which reads the token precompile) plus the token's
    ///         `effectiveAt()`; Robinhood: `uiMultiplier()` and `oraclePaused()` through the token's
    ///         proxy plus the same `effectiveAt()`. While a change is pending, both also read
    ///         `newUIMultiplier()` (ScheduledMultiplier). The headroom covers an upgraded token
    ///         implementation. Bounds what an adapter, or the token behind it, can burn on a read.
    uint256 public constant ADAPTER_GAS_LIMIT = 200_000;
    /// @dev Stall sentinel of the oracle family; providers halt on it. 65_534 is the saturated spread
    ///      (upstream uncertainty lost), which providers reject as well.
    uint16 internal constant STALL_SPREAD = type(uint16).max;
    uint16 internal constant SATURATED_SPREAD = type(uint16).max - 1;

    /// @dev Stock feed: token and params both set. Passthrough feed: both zero (see the contract notes).
    struct Feed {
        bytes32 underlying; // feed id on UNDERLYING: the share (stock feed) or e.g. USDC/USD (passthrough)
        address token; // stock feed: the multiplier-based token; passthrough feed: address(0)
        IOracleParams params; // stock feed: an allow-listed adapter of the token's family; passthrough: 0
    }

    /// @notice The providers oracle (Pyth / Chainlink lane) holding the underlying feeds.
    OracleBase public immutable UNDERLYING;

    mapping(bytes32 => Feed) public feeds;
    /// @notice Feeds the admin has stopped: a read of a stopped feed returns the stall (mid 0,
    ///         spread STALL_SPREAD) until the feed is re-enabled; access failures still revert. The finest
    ///         kill switch here, below removeParamsAdapter (a whole token family), and the only one on
    ///         this contract that reaches a passthrough feed.
    mapping(bytes32 => bool) public feedDisabled;
    /// @dev ADMIN-curated params adapters feeds may bind to (and keep reading through).
    EnumerableSet.AddressSet private _paramsAdapters;

    event FeedCreated(bytes32 indexed feedId, bytes32 indexed underlying, address indexed token, address params);
    event ParamsAdapterAdded(address indexed adapter);
    event ParamsAdapterRemoved(address indexed adapter);
    event FeedDisabled(bytes32 indexed feedId, bool disabled);
    /// @dev Same signature as IOffchainOracle.PriceRead, so read attribution indexes identically.
    event PriceRead(address indexed reader, bytes32 indexed feedId);

    error ZeroAddress();
    error BadFeedConfig();
    error ParamsAdapterNotAllowed(address adapter);
    error ParamsAdapterAlreadyAllowed(address adapter);

    constructor(address admin, OracleBase underlying) {
        require(admin != address(0) && address(underlying) != address(0), ZeroAddress());
        _grantRole(ADMIN_ROLE, admin);
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        UNDERLYING = underlying;
    }

    // ── Params adapter allow-list (admin) ────────────────────────────────

    function addParamsAdapter(IOracleParams adapter) external onlyRole(ADMIN_ROLE) {
        require(address(adapter) != address(0), ZeroAddress());
        require(_paramsAdapters.add(address(adapter)), ParamsAdapterAlreadyAllowed(address(adapter)));
        emit ParamsAdapterAdded(address(adapter));
    }

    /// @notice Also stalls every existing stock feed bound to `adapter` until it is added back.
    function removeParamsAdapter(IOracleParams adapter) external onlyRole(ADMIN_ROLE) {
        require(_paramsAdapters.remove(address(adapter)), ParamsAdapterNotAllowed(address(adapter)));
        emit ParamsAdapterRemoved(address(adapter));
    }

    function isParamsAdapter(IOracleParams adapter) external view returns (bool) {
        return _paramsAdapters.contains(address(adapter));
    }

    function paramsAdapterCount() external view returns (uint256) {
        return _paramsAdapters.length();
    }

    function getParamsAdapters(uint256 start, uint256 end) external view returns (address[] memory) {
        return _paramsAdapters.values(start, end);
    }

    // ── Per-feed kill switch (admin) ────────────────────────────────────

    /// @notice Stops (or resumes) one feed: while disabled, its reads return the stall. Works on stock and
    ///         passthrough feeds alike, and leaves every other feed on the same adapter or underlying
    ///         untouched. `createFeed` still returns a disabled feed.
    function setFeedDisabled(bytes32 feedId, bool disabled) external onlyRole(ADMIN_ROLE) {
        _feed(feedId); // reverts FeedNotFound for an unknown id
        feedDisabled[feedId] = disabled;
        emit FeedDisabled(feedId, disabled);
    }

    // ── Feeds ────────────────────────────────────────────────────────────

    function feedIdOf(bytes32 underlyingFeedId, address token, IOracleParams params) public pure returns (bytes32) {
        return keccak256(abi.encode(underlyingFeedId, token, params));
    }

    /// @notice Creates a feed, or returns it if it already exists. Permissionless: a feed holds no state
    ///         beyond its binding, which its id commits to.
    ///         - Stock feed: `token` and `params` both set; `params` must be on the adapter allow-list.
    ///         - Passthrough feed (the quote leg of a synthetic provider): `token` and `params` both zero;
    ///           no adapter, so no allow-list check.
    ///         Reverts BadFeedConfig on a zero `underlyingFeedId` or when exactly one of `token` / `params`
    ///         is set, and ParamsAdapterNotAllowed on a stock feed with an adapter off the allow-list.
    function createFeed(bytes32 underlyingFeedId, address token, IOracleParams params)
        external
        returns (bytes32 feedId)
    {
        feedId = feedIdOf(underlyingFeedId, token, params);
        if (feeds[feedId].underlying != bytes32(0)) return feedId;
        require(
            underlyingFeedId != bytes32(0) && (token == address(0)) == (address(params) == address(0)), BadFeedConfig()
        );
        require(
            address(params) == address(0) || _paramsAdapters.contains(address(params)),
            ParamsAdapterNotAllowed(address(params))
        );
        feeds[feedId] = Feed({underlying: underlyingFeedId, token: token, params: params});
        emit FeedCreated(feedId, underlyingFeedId, token, address(params));
    }

    // ── Reads ────────────────────────────────────────────────────────────

    /// @notice Attributed on-chain read for pools, gated like the underlying `price(feedId, pool)`: the
    ///         caller must not be blacklisted on UNDERLYING and, unless `tx.origin == address(0)` (as in
    ///         an off-chain call made with a zero sender), `pool` must report `inSwap() == msg.sender`,
    ///         must not be blacklisted and must be registered for the underlying feed. With a zero
    ///         origin these pool checks are skipped and `pool` is only logged.
    /// @dev    Reverts on an unknown feed (FeedNotFound), on the access checks above (Blacklisted,
    ///         InvalidInSwap, NotRegistered), and when UNDERLYING's `integratorPrice` reverts (no data
    ///         for the underlying feed, this oracle not whitelisted as an integrator, or blacklisted
    ///         there). Every data condition stalls instead (mid 0, spread STALL_SPREAD; spread1 is
    ///         passed through): a disabled feed, an underlying mid of 0, a saturated or stalled
    ///         underlying spread, a price-guard breach, and on a stock feed an adapter off the
    ///         allow-list, an adapter failure, the paused flag, a zero multiplier or a scaled mid of 0.
    function price(bytes32 feedId, address pool)
        external
        override
        returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)
    {
        Feed memory f = _feed(feedId);
        require(!UNDERLYING.blacklisted(msg.sender), IOffchainOracle.Blacklisted(msg.sender));
        if (tx.origin != address(0)) {
            require(pool != address(0) && IPool(pool).inSwap() == msg.sender, IOffchainOracle.InvalidInSwap());
            require(!UNDERLYING.blacklisted(pool), IOffchainOracle.Blacklisted(pool));
            require(UNDERLYING.registeredPool(f.underlying, pool), IOffchainOracle.NotRegistered(feedId, pool));
        }

        (mid, spread, spread1, refTime) = UNDERLYING.integratorPrice(f.underlying);
        (uint128 guardMin, uint128 guardMax) = UNDERLYING.priceGuard(f.underlying);
        bool usable = !feedDisabled[feedId] && mid != 0 && spread < SATURATED_SPREAD && mid >= guardMin
            && (guardMax == 0 || mid <= guardMax);
        if (usable && f.token != address(0)) {
            (bool ok, uint256 multiplier) = _issuerMultiplier(f.params, f.token);
            // The spread is relative, so it carries over to the scaled mid unchanged.
            mid = ok ? Math.mulDiv(mid, multiplier, WAD) : 0;
            usable = mid != 0;
        }
        if (!usable) (mid, spread) = (0, STALL_SPREAD);
        emit PriceRead(pool, feedId);
    }

    /// @notice No provider-side guard: the underlying feed's guard is enforced inside `price`, against
    ///         the share price it was configured for.
    function priceGuard(bytes32) external pure returns (uint128 min, uint128 max) {
        return (0, 0);
    }

    /// @notice Registers `pool` for the underlying of `feedId` on the underlying oracle (fee forwarded).
    function register(bytes32 feedId, address pool, address factory) external payable {
        UNDERLYING.register{value: msg.value}(_feed(feedId).underlying, pool, factory);
    }

    function registeredPool(bytes32 feedId, address pool) external view returns (bool) {
        return UNDERLYING.registeredPool(_feed(feedId).underlying, pool);
    }

    // ── Internals ────────────────────────────────────────────────────────

    function _feed(bytes32 feedId) internal view returns (Feed memory f) {
        f = feeds[feedId];
        require(f.underlying != bytes32(0), IOffchainOracle.FeedNotFound(feedId));
    }

    /// @dev The issuer's multiplier for `token`, and false while the issuer has the feed paused, the
    ///      adapter is off the allow-list or cannot answer. Every failure stalls instead of reverting:
    ///      the call is capped at ADAPTER_GAS_LIMIT and at most 64 bytes of its output are copied, so a
    ///      large return or revert payload cannot run the read out of gas, and an answer whose bool word
    ///      is not 0 or 1 counts as malformed.
    function _issuerMultiplier(IOracleParams params, address token)
        internal
        view
        returns (bool ok, uint256 multiplier)
    {
        if (!_paramsAdapters.contains(address(params))) return (false, 0);
        address adapter = address(params);
        bytes4 sel = IOracleParams.getOracleParams.selector;
        bool success;
        uint256 retSize;
        uint256 m;
        uint256 p;
        assembly ("memory-safe") {
            // Scratch beyond the free-memory pointer; never updated, so this is memory-safe. Input is
            // consumed before output is written, so in/out may share ptr. Output is capped at 0x40 bytes:
            // a larger return or revert payload is NOT copied (only returndatasize() reports it).
            let ptr := mload(0x40)
            mstore(ptr, sel)
            mstore(add(ptr, 0x04), token)
            success := staticcall(ADAPTER_GAS_LIMIT, adapter, ptr, 0x24, ptr, 0x40)
            retSize := returndatasize()
            m := mload(ptr)
            p := mload(add(ptr, 0x20))
        }
        if (!success || retSize != 64 || p > 1) return (false, 0);
        multiplier = m;
        ok = p == 0 && m != 0;
    }
}
