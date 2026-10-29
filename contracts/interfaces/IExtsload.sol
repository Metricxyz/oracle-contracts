// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title IExtsload
/// @notice Interface for external storage reading (Uniswap V4 pattern)
/// @dev Allows reading arbitrary storage slots from the contract
interface IExtsload {
  /// @notice Read a single storage slot
  /// @param slot The storage slot to read
  /// @return value The value stored in the slot
  function extsload(bytes32 slot) external view returns (bytes32 value);

  /// @notice Read multiple storage slots
  /// @param slots Array of storage slots to read
  /// @return values Array of values from each slot
  function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values);

  /// @notice Read a contiguous range of storage slots
  /// @param startSlot The starting slot
  /// @param nSlots Number of slots to read
  /// @return values Array of values from each slot
  function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory values);
}
