// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {NetworkConfig} from "./NetworkConfig.sol";
import {AnchoredProviderFactory} from "../contracts/AnchoredProviderFactory.sol";
import {IAnchoredProviderFactory} from "../contracts/interfaces/IAnchoredProviderFactory.sol";

/// @notice Create ONE Anchored Price Provider through an already-deployed AnchoredProviderFactory.
///         Permissionless: anyone can create a provider whose params lie inside the factory's
///         envelope for the base feed's class; the caller becomes the provider owner. The base feed
///         does not need data yet: creation succeeds without reading the oracle, and the provider
///         reads revert (`FeedNotFound` from the reference oracle) until the feed's first update lands — see
///         docs/anchored-price-provider-quickstart.md Step 1.
///
/// ENV (required):
///   PRIVATE_KEY       – creator key; becomes the provider owner
///   NETWORK           – key into script/config/networks.json (ethereum | base | …)
///   BASE_FEED_ID      – base feed id (decimal Pyth Lazer id or 0x-hex; stored as bytes32)
///   BASE_TOKEN        – base token address (mandatory — the oracles are token-free)
///   QUOTE_TOKEN       – quote token address (mandatory; must differ from BASE_TOKEN)
///   MIN_MARGIN        – per-side floor, BPS_BASE_U scale (1 bps = 1e14); must sit in the envelope
///   MAX_REF_STALENESS – seconds; must sit in the envelope
///
/// ENV (optional, sensible defaults):
///   REFERENCE         – "pyth" (default) | "chainlink": which deployed oracle to anchor to
///   REFERENCE_ORACLE          – explicit oracle address (overrides REFERENCE)
///   ANCHORED_PROVIDER_FACTORY – explicit factory address (overrides networks.json
///                               deployments.anchoredProviderFactory)
///   QUOTE_FEED_ID     – second feed for a synthetic base/quote ratio (default 0 = single feed)
///   MAX_SPREAD_MULT   – per-leg spread-multiplier ceiling, BPS_BASE_U scale (default 1e18 = 1.0×;
///                       must be >= 1e18 and <= the envelope's spreadMultMax)
///   MUTABLE_PARAMS    – "true" enables the tunable variant (confidence + per-leg knobs); default false
///   MARGIN_STEP       – shaping bias for the mutable variant, int256, |x| < 1e18 (default 0)
///
/// ENV (optional, initial config applied AT CONSTRUCTION — same validation as the setters; for the
/// immutable variant these are permanent, for the customizable variant they are the starting point):
///   SOURCE            – custom quote source (default 0 = reference mode)
///   BASE_MAX_STALENESS / QUOTE_MAX_STALENESS – per-leg reference staleness, seconds
///                       (default MAX_REF_STALENESS; each must be <= MAX_REF_STALENESS)
///   BASE_SPREAD_MULT / QUOTE_SPREAD_MULT     – per-leg spread multiplier, BPS_BASE_U scale
///                       (default 1e18 = 1.0×; each must be <= MAX_SPREAD_MULT; < 1e18 tightens)
///
/// Usage:
///   NETWORK=base BASE_FEED_ID=397 BASE_TOKEN=0xcbB7… QUOTE_TOKEN=0x8335… \
///   MIN_MARGIN=100000000000000 MAX_REF_STALENESS=60 \
///   PRIVATE_KEY=0x… forge script script/CreateAnchoredProvider.s.sol --rpc-url base --broadcast
///   (or the thin wrapper: … ./script/create-anchored-provider.sh)
contract CreateAnchoredProvider is NetworkConfig {
    uint256 constant BPS_BASE_U = 1e18;

    function run() external {
        uint256 creatorKey = vm.envUint("PRIVATE_KEY");
        string memory network = vm.envString("NETWORK");

        // ── resolve factory + reference oracle (env override → networks.json) ──
        address factory = vm.envOr("ANCHORED_PROVIDER_FACTORY", address(0));
        if (factory == address(0)) factory = _deployment(network, "anchoredProviderFactory");
        require(factory != address(0) && factory.code.length > 0, "factory not deployed on this network");

        address oracle = vm.envOr("REFERENCE_ORACLE", address(0));
        if (oracle == address(0)) {
            string memory ref = vm.envOr("REFERENCE", string("pyth"));
            string memory key = keccak256(bytes(ref)) == keccak256("chainlink") ? "dataStreamsOracle" : "pythOracle";
            // Tolerant: an absent entry means that reference is not available on this network, which
            // is what the require below reports. `_deployment` would panic on the missing path first.
            oracle = _deploymentOrZero(network, key);
        }
        require(oracle != address(0) && oracle.code.length > 0, "reference oracle not deployed");

        // ── params ──
        bytes32 baseFeedId = bytes32(vm.envUint("BASE_FEED_ID"));
        bytes32 quoteFeedId = bytes32(vm.envOr("QUOTE_FEED_ID", uint256(0)));
        uint256 minMargin = vm.envUint("MIN_MARGIN");
        uint256 maxRefStaleness = vm.envUint("MAX_REF_STALENESS");
        uint256 maxSpreadMult = vm.envOr("MAX_SPREAD_MULT", BPS_BASE_U);
        bool mutableParams = vm.envOr("MUTABLE_PARAMS", false);
        int256 marginStep = vm.envOr("MARGIN_STEP", int256(0));
        address baseToken = vm.envAddress("BASE_TOKEN");
        address quoteToken = vm.envAddress("QUOTE_TOKEN");

        // Initial config set AT CONSTRUCTION (source + per-leg knobs). Defaults are the plain
        // 1.0×/shared-staleness configuration: no source, both staleness bounds = maxRefStaleness, 1.0× mults.
        IAnchoredProviderFactory.InitialConfig memory init = IAnchoredProviderFactory.InitialConfig({
            source: vm.envOr("SOURCE", address(0)),
            baseMaxStaleness: vm.envOr("BASE_MAX_STALENESS", maxRefStaleness),
            quoteMaxStaleness: vm.envOr("QUOTE_MAX_STALENESS", maxRefStaleness),
            baseSpreadMult: vm.envOr("BASE_SPREAD_MULT", BPS_BASE_U),
            quoteSpreadMult: vm.envOr("QUOTE_SPREAD_MULT", BPS_BASE_U)
        });

        console.log("Network:            ", network);
        console.log("Factory:            ", factory);
        console.log("Reference oracle:   ", oracle);
        console.log("Base feed id:       ", uint256(baseFeedId));
        console.log(
            "Quote feed id:      ", uint256(quoteFeedId), quoteFeedId == bytes32(0) ? "(single feed)" : "(synthetic)"
        );
        console.log("minMargin:          ", minMargin);
        console.log("maxRefStaleness (s):", maxRefStaleness);
        console.log("maxSpreadMult:      ", maxSpreadMult);
        console.log("mutableParams:      ", mutableParams);

        AnchoredProviderFactory apf = AnchoredProviderFactory(factory);
        vm.startBroadcast(creatorKey);
        address provider = apf.createAnchoredProvider(
            oracle,
            baseFeedId,
            quoteFeedId,
            minMargin,
            maxRefStaleness,
            maxSpreadMult,
            mutableParams,
            marginStep,
            baseToken,
            quoteToken,
            init
        );
        vm.stopBroadcast();

        console.log("");
        console.log("Anchored Price Provider created at:", provider);
        console.log("  owner:", vm.addr(creatorKey));
        console.log("  isProvider() =", apf.isProvider(provider));
        console.log("  (public-pool eligibility check: factory.isProvider(provider) == true)");
    }
}
