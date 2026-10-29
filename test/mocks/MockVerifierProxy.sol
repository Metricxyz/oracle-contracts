// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVerifierProxy} from "../../contracts/interfaces/IDataStreams.sol";

/// @notice Test double for the Data Streams VerifierProxy: echoes the payload as the "verified"
///         report blob and accepts the native verification fee.
contract MockVerifierProxy is IVerifierProxy {
    uint256 public received;

    function verify(bytes calldata payload, bytes calldata /* parameterPayload */)
        external
        payable
        override
        returns (bytes memory)
    {
        received += msg.value;
        return payload;
    }
}
