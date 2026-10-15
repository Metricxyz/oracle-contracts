// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVerifierProxy} from "../../contracts/interfaces/IDataStreams.sol";

/// @notice Test double for the Data Streams VerifierProxy: echoes the payload as the "verified"
///         report blob and accepts the native verification fee.
contract MockVerifierProxy is IVerifierProxy {
    uint256 public received;

    /// @notice Simulates a FeeManager that quotes a NONZERO per-report fee. Zero (the default)
    ///         reproduces the assumption the deployment actually relies on. Settable so a test can
    ///         demonstrate what happens on a chain where on-chain Data Streams billing is live —
    ///         `received += msg.value` alone can never do that, since it holds for any fee.
    uint256 public requiredFee;

    error InsufficientVerificationFee(uint256 sent, uint256 required);

    function setRequiredFee(uint256 fee) external {
        requiredFee = fee;
    }

    function verify(
        bytes calldata payload,
        bytes calldata /* parameterPayload */
    )
        external
        payable
        override
        returns (bytes memory)
    {
        if (msg.value < requiredFee) revert InsufficientVerificationFee(msg.value, requiredFee);
        received += msg.value;
        return payload;
    }

    /// @notice v0.5.1 fee-free path: echoes the payload, takes no fee.
    function verifyView(bytes calldata payload) external pure override returns (bytes memory) {
        return payload;
    }
}
