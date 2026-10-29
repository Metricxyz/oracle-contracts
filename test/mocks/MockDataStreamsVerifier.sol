// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVerifierProxy} from "../../contracts/interfaces/IDataStreams.sol";

/// @notice Test double that mimics the real Chainlink VerifierProxy: it extracts the report blob from
///         a full DON-signed report (the exact bytes the Data Streams API returns) and accepts the
///         native fee. It does NOT check signatures — fine for decode/normalize/store tests with real
///         report payloads.
contract MockDataStreamsVerifier is IVerifierProxy {
    function verify(bytes calldata payload, bytes calldata /* parameterPayload */)
        external
        payable
        override
        returns (bytes memory reportData)
    {
        // full report = abi.encode(bytes32[3] context, bytes reportData, bytes32[] rs, bytes32[] ss, bytes32 rawVs)
        (, reportData) = abi.decode(payload, (bytes32[3], bytes));
    }
}
