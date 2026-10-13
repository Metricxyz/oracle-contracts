// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @dev Oracle family discriminator — every oracle in this repo exposes it as a public constant.
interface IOracleKind {
    function kind() external view returns (string memory);
}

/// @dev The AnchoredProviderFactory introspection surface the deploy scripts share: the class
///      constant (identity probe), the auto-generated envelopes getter (not part of the public
///      interface) and the allow-list enumeration.
interface IApfIntrospect {
    function DEFAULT_CLASS() external view returns (bytes32);
    function envelopes(bytes32 classId) external view returns (uint256, uint256, uint256, uint256, uint256, bool);
    function oracleCount() external view returns (uint256);
    function getOracles(uint256 start, uint256 end) external view returns (address[] memory);
}

/// @notice Shared config reader/writer for the provider-creation scripts.
///         Reads from `script/config/networks.json` — a single file
///         containing per-network config keyed by network name.
///
/// JSON structure:
///   {
///     "<network>": {
///       "deployments": { "priceProviderFactory": "0x...", "pythOracle": "0x...", ... },
///
///       // Optional, deploy-time-only sections — not present in every checked-in config
///       // (a network's own deploy tooling populates these; the provider-creation scripts
///       // only ever read "deployments"):
///       "access":      { "admins": ["0x..."] },
///       "oracle":      { "maxTimeDrift": 60, "expectedProperties": [0,4,5,12] }
///     }
///   }
abstract contract NetworkConfig is Script {
    string constant NETWORKS_JSON = "script/config/networks.json";

    // ── reads ───────────────────────────────────────────────────────

    function _configJson() internal view returns (string memory) {
        return vm.readFile(NETWORKS_JSON);
    }

    function _deployment(string memory network, string memory key) internal view returns (address) {
        return abi.decode(vm.parseJson(_configJson(), string.concat(".", network, ".deployments.", key)), (address));
    }

    /// @dev Same as `_deployment`, but returns 0 instead of reverting when the key is absent for this
    ///      network. `vm.parseJson` on a missing path yields empty bytes and `abi.decode` then reverts,
    ///      so every OPTIONAL contract must be read through here: not every chain carries every
    ///      contract, and an entry appears only once that contract is deployed there.
    function _deploymentOrZero(string memory network, string memory key) internal view returns (address) {
        try vm.parseJsonAddress(_configJson(), string.concat(".", network, ".deployments.", key)) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    function _admins(string memory network) internal view returns (address[] memory) {
        return abi.decode(vm.parseJson(_configJson(), string.concat(".", network, ".access.admins")), (address[]));
    }

    function _oracleMaxTimeDrift(string memory network) internal view returns (uint256) {
        return abi.decode(vm.parseJson(_configJson(), string.concat(".", network, ".oracle.maxTimeDrift")), (uint256));
    }

    function _oracleExpectedProperties(string memory network) internal view returns (uint8[] memory) {
        return
            abi.decode(
                vm.parseJson(_configJson(), string.concat(".", network, ".oracle.expectedProperties")), (uint8[])
            );
    }

    // ── AnchoredProviderFactory introspection (shared by the deploy/redeploy scripts) ──

    /// @dev "Configured" = the DEFAULT_CLASS envelope exists. setEnvelope is the LAST transaction of
    ///      a factory's initial config (after the addOracle calls), so an existing envelope is a
    ///      strong hint the sequence completed. It is only a reading of the current envelope: it
    ///      does not prove which transactions ran, and an envelope can be removed later.
    ///
    ///      The identity probe guards the callers: code at an address read from networks.json is not
    ///      proof it is OUR factory — a typo'd or stale entry can point at someone else's contract.
    ///      A foreign contract would have to echo the exact class constant to get past this —
    ///      refuse to mirror from or send admin transactions into anything failing it.
    function _isConfigured(address factory) internal view returns (bool) {
        IApfIntrospect apf = IApfIntrospect(factory);
        require(
            apf.DEFAULT_CLASS() == keccak256("AnchoredProviderFactory.DEFAULT_CLASS"),
            "target does not answer like an AnchoredProviderFactory - refusing to touch it"
        );
        (,,,,, bool exists) = apf.envelopes(apf.DEFAULT_CLASS());
        return exists;
    }

    /// @dev True when the factory's live allow-list contains ANY oracle of this `kind()` — a lane
    ///      is mirrored as a policy, not as an address, so the mirror survives the lane's own oracle
    ///      being redeployed to a fresh address in the same wave. The try/catch keeps an allow-list
    ///      entry that does not expose kind() (or is not an oracle at all) from reverting the run.
    function _laneListed(address apfAddr, bytes32 kindHash) internal view returns (bool) {
        IApfIntrospect factory = IApfIntrospect(apfAddr);
        address[] memory listed = factory.getOracles(0, factory.oracleCount());
        for (uint256 i; i < listed.length; ++i) {
            try IOracleKind(listed[i]).kind() returns (string memory k) {
                if (keccak256(bytes(k)) == kindHash) return true;
            } catch {}
        }
        return false;
    }

    // ── writes ──────────────────────────────────────────────────────

    function _writeDeployment(string memory network, string memory key, address addr) internal {
        // Only persist on a real broadcast. A dry-run / simulation must NOT mutate the registry:
        // CREATE3 addresses are deterministic and already logged by the caller, so a dry-run would
        // otherwise overwrite live deployment addresses with not-yet-deployed predicted ones.
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console.log("Dry-run: registry NOT updated (pass --broadcast to persist)", network, key);
            return;
        }
        vm.writeJson(vm.toString(addr), NETWORKS_JSON, string.concat(".", network, ".deployments.", key));
    }
}
