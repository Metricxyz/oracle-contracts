// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimeMs} from "../oracles/utils/TimeMs.sol";

interface IOffchainOracle {
    struct PriceGuard {
        uint128 min;
        uint128 max;
    } // 128+128 = 256

    /// @param price      Mid, 8 decimals.
    /// @param spread0    Bid/ask spread in 0.01-bps units (fraction × 1e6): 100 = 1 bp, 10_000 = 1%.
    ///                   `type(uint16).max` (65_535) is the reserved STALL sentinel — feed inactive
    ///                   (RWA market closed, compressed 0xFF/0xFF marker). Pyth/Chainlink saturate at
    ///                   65_534, losing the original uncertainty; consumers must halt at that value
    ///                   too. APP rejects spread0 >= 65_534; the plain provider has a lower 5% cap.
    /// @param spread1    ⚠️ NOT uniform across oracle families, and no in-repo provider reads it.
    ///                   `CompressedOracleV1` returns a second, independently decoded spread (the
    ///                   slot packs two codebook indices per feed). `ChainlinkOracle` and the Pyth
    ///                   Lazer path hardcode `0xFFFF` here to mean "unused" — which is bit-identical
    ///                   to the stall sentinel. An integrator reading `spread1` through
    ///                   `integratorPrice` must therefore branch on the oracle's `kind`, or it will
    ///                   read a permanent stall on two of the three lanes and 6.5535% of phantom
    ///                   uncertainty on the third. Prefer `spread0`.
    /// @param timestampMs Observation time in milliseconds; `price()` returns it in SECONDS.
    struct OracleData {
        uint64 price;
        uint16 spread0;
        uint16 spread1;
        TimeMs timestampMs;
    } // 64+16+16+56=152

    function getOracleData(bytes32 feedId) external view returns (OracleData memory data);
    function getOracleDataBulk(bytes32[] calldata feedId) external view returns (OracleData[] memory data);

    function priceGuard(bytes32 feedId) external view returns (uint128 min, uint128 max);

    event PriceGuardUpdated(bytes32 indexed feedId, uint128 minPrice, uint128 maxPrice);
    event StateGuardUpdated(bytes32 indexed feedId, address indexed stateGuard);
    event StateGuardPending(bytes32 indexed feedId, address indexed stateGuard);
    event PendingStateGuardDeleted(bytes32 indexed feedId);
    event StateGuardDeleted(bytes32 indexed feedId);

    /// @notice Emitted once per feed whose stored price is ACTUALLY advanced by an accepted update. A
    ///         monotonic-rejected (older-or-equal) push writes nothing and emits nothing. This is the
    ///         quote-side key of the off-chain builder's (oracle, feed) join: FeedUpdated(feedId)
    ///         sequences the maker update ahead of a matching PriceRead(pool, feedId) on the same
    ///         oracle. Only feedId is load-bearing for the join, so the event carries nothing else —
    ///         a consumer that wants the maker's quote reads it via the price path. Emitted by every
    ///         oracle family on write.
    event FeedUpdated(bytes32 indexed feedId);

    /// @notice Emitted when a single feed inside a multi-feed push is skipped because its timestamp
    ///         is further ahead of block time than the oracle's drift tolerance. The rest of the
    ///         batch still stores: a signed packet cannot be repackaged by the relayer, so one
    ///         publisher with a fast clock must not be able to halt fresh updates for every feed it
    ///         shares a packet with. Emitted instead of reverting, so the skip stays observable —
    ///         a push that silently writes nothing is indistinguishable from a successful one.
    event FeedSkippedFutureTimestamp(bytes32 indexed feedId);

    // Read-access control
    event PriceRead(address indexed reader, bytes32 indexed feedId);
    event PoolRegistered(bytes32 indexed feedId, address indexed pool, address indexed payer, uint256 fee);
    event RegistrationFeeUpdated(uint256 oldFee, uint256 newFee);
    event ApprovedFactoryAdded(address indexed factory);
    event ApprovedFactoryRemoved(address indexed factory);
    event BlacklistUpdated(address indexed account, bool blacklisted);
    event IntegratorUpdated(address indexed integrator, bool approved);
    event EthWithdrawn(address indexed to, uint256 amount);

    error BadCalldataLength();
    error DeadlineExceeded();
    error FeedNotFound(bytes32 feedId);
    error InvalidAuthority(address authority);
    error InvalidGuard(address guard);

    // Read-access control
    error Blacklisted(address account);
    error InsufficientFee(uint256 sent, uint256 required);
    error NotAPool(address pool);
    error NotRegistered(bytes32 feedId, address pool);
    error FactoryNotApproved(address factory);
    error FactoryAlreadyApproved(address factory);
    error InvalidInSwap();
    error NotWhitelisted(address account);
    error AlreadyIntegrator(address integrator);
    error NotIntegrator(address integrator);
}
