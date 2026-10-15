// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PriceProviderFactory} from "../contracts/PriceProviderFactory.sol";
import {IPriceProvider} from "../contracts/interfaces/IPriceProvider.sol";

/// @notice Create ONE plain Price Provider through an already-deployed PriceProviderFactory.
///         Permissionless: anyone can call `createPriceProvider`, the caller becomes the provider
///         owner, and there is no admin allow-list/envelope to satisfy (unlike
///         AnchoredProviderFactory — see "Choose a price provider" in docs/oracle-overview.md for
///         how the two compare). Three inputs shape the quote: the oracle's reported spread scaled
///         by confidenceParam (settable post-create by the owner or an updater via
///         factory.setConfidence, default 0), a fixed bid/ask step
///         (MARGIN_STEP, immutable) and a staleness bound (MAX_TIME_DELTA, immutable) — it does
///         NOT clamp to a reference band the way AnchoredPriceProvider does.
///
/// ENV (required):
///   PRIVATE_KEY    – creator key; becomes the provider owner
///   PRICE_PROVIDER_FACTORY – factory address (docs/DEPLOYMENTS.md)
///   REFERENCE_ORACLE       – oracle address the provider reads (docs/DEPLOYMENTS.md)
///   FEED_ID        – feed id (decimal or 0x-hex; stored as bytes32). Meaning depends on the oracle:
///                    the packed CompressedOracleV1 feedId (see feedIdOf on that contract), the
///                    Pyth Lazer / Chainlink Data Streams feed id, or a MultiplierOracle feed id.
///   MARGIN_STEP    – per-side step, BPS_BASE_U scale (1e18 = 100%); strictly between -1e18 and
///                    1e18 (constructor reverts MarginStepOutOfBounds otherwise). 0 = no step.
///   MAX_TIME_DELTA – seconds; must be > 0 and <= 7 days (constructor reverts
///                    MaxTimeDeltaOutOfBounds otherwise)
///   BASE_TOKEN     – base token address (mandatory — providers never read a token from the oracle)
///   QUOTE_TOKEN    – quote token address (mandatory; must differ from BASE_TOKEN)
///
/// Usage:
///   PRICE_PROVIDER_FACTORY=0x… REFERENCE_ORACLE=0x… \
///   FEED_ID=397 BASE_TOKEN=0xcbB7… QUOTE_TOKEN=0xA0b8… \
///   MARGIN_STEP=0 MAX_TIME_DELTA=60 \
///   PRIVATE_KEY=0x… forge script script/CreatePriceProvider.s.sol --rpc-url ethereum --broadcast
///   (or the thin wrapper: … ./script/create-price-provider.sh)
contract CreatePriceProvider is Script {
    function run() external {
        uint256 creatorKey = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("PRICE_PROVIDER_FACTORY");
        require(factory.code.length > 0, "factory not deployed on this network");
        address oracle = vm.envAddress("REFERENCE_ORACLE");
        require(oracle.code.length > 0, "reference oracle not deployed on this network");

        // ── params ──
        bytes32 feedId = bytes32(vm.envUint("FEED_ID"));
        int256 marginStep = vm.envInt("MARGIN_STEP");
        uint256 maxTimeDelta = vm.envUint("MAX_TIME_DELTA");
        address baseToken = vm.envAddress("BASE_TOKEN");
        address quoteToken = vm.envAddress("QUOTE_TOKEN");

        console.log("Factory:            ", factory);
        console.log("Reference oracle:   ", oracle);
        console.log("Feed id:            ", uint256(feedId));
        console.log("marginStep:         ", marginStep);
        console.log("maxTimeDelta (s):   ", maxTimeDelta);
        console.log("baseToken:          ", baseToken);
        console.log("quoteToken:         ", quoteToken);

        PriceProviderFactory ppf = PriceProviderFactory(factory);
        vm.startBroadcast(creatorKey);
        address provider = ppf.createPriceProvider(oracle, feedId, marginStep, maxTimeDelta, baseToken, quoteToken);
        vm.stopBroadcast();

        console.log("");
        console.log("Price Provider created at:", provider);
        console.log("  owner:", vm.addr(creatorKey));
        console.log("  isProvider() =", ppf.isProvider(provider));

        // ── post-create sanity read ──
        // getQuote() forwards msg.sender (this script) as `pool` to the oracle's price(feedId, pool).
        // CompressedOracleV1 ignores `pool` (open read), so off-swap the read returns a quote or
        // reverts with:
        //   - FeedStalled (from the provider) while the feed holds no fresh, usable price: a
        //     never-written slot or a stall-marked position (both read with refTime 0, so stale), an
        //     observation older than MAX_TIME_DELTA or in the future, a zero mid (a never-written
        //     position in a written slot), or a mid outside the feed's price guard;
        //   - FeedNotFound (from the oracle) for a malformed feed id: another chain's id, a position
        //     above 3 or a zero creator.
        // PythOracle/ChainlinkOracle-backed providers serve only registered pools mid-swap
        // (`IPool(pool).inSwap()` binding), so this off-swap read is EXPECTED to revert and does not
        // indicate a problem with the newly created provider: FeedNotFound while the feed holds no
        // observation (checked first), otherwise an empty revert (this script has no inSwap(), so the
        // oracle's call to it fails before any named error is reached). A MultiplierOracle-backed
        // provider is gated the same way: FeedNotFound while the feed id was not created on the
        // MultiplierOracle, otherwise the same empty revert (the pool checks run before the
        // underlying oracle is read).
        try IPriceProvider(provider).getQuote() returns (uint128 bid, uint128 ask, uint128 referencePrice) {
            console.log("  sanity read: bid =", bid, "ask =", ask);
            console.log("  sanity read: reference =", referencePrice);
        } catch (bytes memory reason) {
            console.log("  sanity read reverted (see docs/price-provider-quickstart.md Step 2):");
            console.logBytes(reason);
        }
    }
}
