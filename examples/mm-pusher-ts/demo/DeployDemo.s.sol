// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PythLazer} from "pyth-lazer-sdk/PythLazer.sol";

import {CompressedOracleV1} from "../../../contracts/oracles/compressed/CompressedOracle.sol";
import {PythOracle} from "../../../contracts/oracles/providers/PythOracle.sol";

/// Local demo deploy for BOTH pusher lanes (anvil). NOT a production script.
/// The PythLazer proxy owner MUST be the broadcasting EOA: vm.prank does not survive
/// --broadcast, and updateTrustedSigner is onlyOwner. Do not pass --sender with a
/// mismatched --private-key.
///
/// Purpose: stand up one local instance of EACH oracle the TS package talks
/// to — CompressedOracleV1 (no external deps) and PythOracle behind a real
/// PythLazer proxy (mirroring how it's actually deployed) — so
/// `demo/anvil-demo.sh` can drive every script against a live chain without
/// touching any real network.
///
/// What happens: deploys CompressedOracleV1 directly; deploys a PythLazer
/// implementation + TransparentUpgradeableProxy in front of it and registers
/// DEMO_SIGNER_PK's address as the trusted Lazer signer (the SAME key
/// `src/pyth/lazer.ts`'s `DEMO_SIGNER_PRIVATE_KEY` derives, so
/// `demo/build-demo-update.ts`'s locally-signed envelopes verify against
/// this proxy); deploys PythOracle wired to that proxy and funds it with
/// PYTH_FEE_FUND wei (covers ~1000 pushes at the 1-wei Lazer verification
/// fee each); finally prints a one-line JSON of the three deployed
/// addresses to stdout for the shell driver to `grep`/parse.
///
/// Inputs/outputs/env: no env vars read directly — `vm.startBroadcast()`
/// picks up `--private-key`/`--sender` from the `forge script` CLI
/// invocation (see `demo/anvil-demo.sh`). Output: one JSON line on stdout,
/// `{"compressedOracle":"0x..","pythOracle":"0x..","pythLazer":"0x.."}`.
///
/// Place in the package: invoked by `demo/anvil-demo.sh` right after anvil
/// comes up; its stdout is parsed to export
/// COMPRESSED_ORACLE_ADDRESS/PYTH_ORACLE_ADDRESS for every subsequent
/// `scripts/*.ts` invocation in the demo run.
contract DeployDemo is Script {
    uint256 constant DEMO_SIGNER_PK = uint256(keccak256("lazer-test-signer"));
    uint256 constant MAX_TIME_DRIFT_SECONDS = 60; // same as the repo's own tests
    uint256 constant SIGNER_EXPIRES_AT = 3000000000000000; // effectively never (same as tests)
    uint256 constant PYTH_FEE_FUND = 1000 wei; // covers 1000 pushes at 1 wei each

    function run() external {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        CompressedOracleV1 compressed = new CompressedOracleV1(deployer, MAX_TIME_DRIFT_SECONDS);

        PythLazer lazerImpl = new PythLazer();
        TransparentUpgradeableProxy lazerProxy = new TransparentUpgradeableProxy(
            address(lazerImpl), deployer, abi.encodeWithSelector(PythLazer.initialize.selector, deployer)
        );
        PythLazer(address(lazerProxy)).updateTrustedSigner(vm.addr(DEMO_SIGNER_PK), SIGNER_EXPIRES_AT);

        uint8[] memory props = new uint8[](4);
        props[0] = 0; // Price
        props[1] = 4; // Exponent
        props[2] = 5; // Confidence
        props[3] = 12; // FeedUpdateTimestamp
        PythOracle pyth = new PythOracle(deployer, address(lazerProxy), MAX_TIME_DRIFT_SECONDS, props);

        (bool ok,) = address(pyth).call{value: PYTH_FEE_FUND}("");
        require(ok, "funding PythOracle failed");

        vm.stopBroadcast();

        console2.log(
            string.concat(
                '{"compressedOracle":"',
                vm.toString(address(compressed)),
                '","pythOracle":"',
                vm.toString(address(pyth)),
                '","pythLazer":"',
                vm.toString(address(lazerProxy)),
                '"}'
            )
        );
    }
}
