// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OracleBase} from "../../contracts/oracles/providers/OracleBase.sol";
import {IOffchainOracle} from "../../contracts/interfaces/IOffchainOracle.sol";
import {toTimeMs} from "../../contracts/oracles/utils/TimeMs.sol";

/// @notice Minimal concrete OracleBase for tests: real access-gated `price(feedId, pool)`
///         gating with settable per-feed oracle data. Registrationless like the real oracles —
///         a feed exists once its data is written (no verified push needed).
contract TestOracle is OracleBase {
    constructor(address _owner, uint256 maxTimeDrift) OracleBase(_owner, maxTimeDrift) {}

    function setData(bytes32 feedId, uint64 price_, uint16 spread0_, uint16 spread1_, uint256 refTimeSec) external {
        oracleData[feedId] = IOffchainOracle.OracleData({
            price: price_, spread0: spread0_, spread1: spread1_, timestampMs: toTimeMs(refTimeSec * 1000)
        });
    }
}
