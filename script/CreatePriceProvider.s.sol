// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {NetworkConfig} from "./NetworkConfig.sol";
import {PriceProviderFactory} from "../contracts/PriceProviderFactory.sol";
import {IPriceProvider} from "../contracts/interfaces/IPriceProvider.sol";

/// @notice Create ONE plain Price Provider through an already-deployed PriceProviderFactory.
///         Permissionless: anyone can call `createPriceProvider`, the caller becomes the provider
///         owner, and there is no admin allow-list/envelope to satisfy (unlike
///         AnchoredProviderFactory — see docs/price-provider-quickstart.md for how the two compare).
///         Three inputs shape the quote: the oracle's reported spread scaled by confidenceParam
///         (owner-settable post-create via factory.setConfidence, default 0), a fixed bid/ask step
///         (MARGIN_STEP, immutable) and a staleness bound (MAX_TIME_DELTA, immutable) — it does
///         NOT clamp to a reference band the way AnchoredPriceProvider does.
///
/// ENV (required):
///   PRIVATE_KEY    – creator key; becomes the provider owner
///   NETWORK        – key into script/config/networks.json (ethereum | …)
///   FEED_ID        – feed id (decimal or 0x-hex; stored as bytes32). Meaning depends on REFERENCE:
///                    the packed CompressedOracleV1 feedId (see feedIdOf on that contract) for
///                    "compressed", or the Pyth Lazer / Chainlink Data Streams feed id otherwise.
///   MARGIN_STEP    – per-side step, BPS_BASE_U scale (1e18 = 100%); strictly between -1e18 and
///                    1e18 (constructor reverts MarginStepOutOfBounds otherwise). 0 = no step.
///   MAX_TIME_DELTA – seconds; must be > 0 and <= 7 days (constructor reverts
///                    MaxTimeDeltaOutOfBounds otherwise)
///   BASE_TOKEN     – base token address (mandatory — providers never read a token from the oracle)
///   QUOTE_TOKEN    – quote token address (mandatory; must differ from BASE_TOKEN)
///
/// ENV (optional, sensible defaults):
///   REFERENCE      – "compressed" (default) | "pyth" | "chainlink": which deployed oracle to read
///   REFERENCE_ORACLE       – explicit oracle address (overrides REFERENCE)
///   PRICE_PROVIDER_FACTORY – explicit factory address (overrides networks.json
///                            deployments.priceProviderFactory)
///
/// Usage:
///   NETWORK=ethereum REFERENCE=pyth FEED_ID=397 BASE_TOKEN=0xcbB7… QUOTE_TOKEN=0xA0b8… \
///   MARGIN_STEP=0 MAX_TIME_DELTA=60 \
///   PRIVATE_KEY=0x… forge script script/CreatePriceProvider.s.sol --rpc-url ethereum --broadcast
///   (or the thin wrapper: … ./script/create-price-provider.sh)
contract CreatePriceProvider is NetworkConfig {
    function run() external {
        uint256 creatorKey = vm.envUint("PRIVATE_KEY");
        string memory network = vm.envString("NETWORK");

        // ── resolve factory + reference oracle (env override → networks.json) ──
        address factory = vm.envOr("PRICE_PROVIDER_FACTORY", address(0));
        if (factory == address(0)) factory = _deployment(network, "priceProviderFactory");
        require(factory != address(0) && factory.code.length > 0, "factory not deployed on this network");

        address oracle = vm.envOr("REFERENCE_ORACLE", address(0));
        if (oracle == address(0)) {
            string memory ref = vm.envOr("REFERENCE", string("compressed"));
            bytes32 refHash = keccak256(bytes(ref));
            string memory key = refHash == keccak256("pyth")
                ? "pythOracle"
                : refHash == keccak256("chainlink") ? "dataStreamsOracle" : "compressedOracle";
            // Tolerant: an absent entry means that reference is not available on this network, which
            // is what the require below reports. `_deployment` would panic on the missing path first.
            oracle = _deploymentOrZero(network, key);
        }
        require(oracle != address(0) && oracle.code.length > 0, "reference oracle not deployed");

        // ── params ──
        bytes32 feedId = bytes32(vm.envUint("FEED_ID"));
        int256 marginStep = vm.envInt("MARGIN_STEP");
        uint256 maxTimeDelta = vm.envUint("MAX_TIME_DELTA");
        address baseToken = vm.envAddress("BASE_TOKEN");
        address quoteToken = vm.envAddress("QUOTE_TOKEN");

        console.log("Network:            ", network);
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
        // getQuote() forwards msg.sender as `pool` to the underlying oracle's
        // price(feedId, pool). CompressedOracleV1 ignores `pool` entirely (no in-swap binding, open
        // read) so this call always works off-swap: it either returns a quote or reverts
        // FeedStalled while the feed has no data yet. PythOracle/ChainlinkOracle-backed providers
        // instead only serve registered pools mid-swap (`IPool(pool).inSwap()` binding), so an
        // off-swap read here is EXPECTED to revert and does not indicate a problem with the newly
        // created provider. Observed shapes: FeedNotFound while the feed has no data (fires first),
        // otherwise an empty revert (this script has no inSwap(), so the oracle's nested probe of
        // it fails before any named error is reached).
        try IPriceProvider(provider).getQuote() returns (uint128 bid, uint128 ask, uint128 referencePrice) {
            console.log("  sanity read: bid =", bid, "ask =", ask);
            console.log("  sanity read: reference =", referencePrice);
        } catch (bytes memory reason) {
            console.log("  sanity read reverted (see docs/price-provider-quickstart.md Step 1):");
            console.logBytes(reason);
        }
    }
}
