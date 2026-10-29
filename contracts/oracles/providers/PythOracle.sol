// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {OracleBase} from "./OracleBase.sol";
import {LazerConsumer, PythLazerStructs} from "../utils/LazerConsumer.sol";

import {IPythOracleV1} from "../../interfaces/IPythOracleV1.sol";
import {IOffchainOracle} from "../../interfaces/IOffchainOracle.sol";

contract PythOracle is OracleBase, IPythOracleV1, LazerConsumer {
    using SafeCast for uint256;

    string public constant version = "0.0.5";

    constructor(
        address _owner,
        address _lazerAddress,
        uint256 maxTimeDrift,
        uint32 usdConversionFeedId,
        uint8[] memory expectedProperties
    )
        OracleBase(_owner, maxTimeDrift)
        LazerConsumer(_lazerAddress, maxTimeDrift, usdConversionFeedId, expectedProperties)
    {}

    /*
     *
     * Views
     * 
     */

    /// @dev Raw stored data for the gated read paths (price(feedId, factory), integratorPrice).
    ///      Public getters (getOracleData / getOracleDataBulk / price(bytes32)) are disabled in OracleBase.
    function _oracleDataRaw(bytes32 feedId) internal view override returns (OracleData memory) {
        return oracleData[feedId];
    }

    /*
     *
     * Main logic
     * 
     */

    function registerFeeds(
        bytes32[] calldata pythLazerFeedIds,
        address[] calldata baseTokens,
        address[] calldata quoteTokens
    ) external onlyRole(REGISTRAR_ROLE) {
        require(pythLazerFeedIds.length == baseTokens.length && baseTokens.length == quoteTokens.length, LengthMismatch());
        for (uint256 i; i < pythLazerFeedIds.length; ++i) {
            _registerFeed(pythLazerFeedIds[i], baseTokens[i], quoteTokens[i]);
        }
    }

    function registerFeed(
        bytes32 pythLazerFeedId,
        address baseToken,
        address quoteToken
    ) public onlyRole(REGISTRAR_ROLE) {
        _registerFeed(pythLazerFeedId, baseToken, quoteToken);
    }

    function _registerFeed(
        bytes32 pythLazerFeedId,
        address baseToken,
        address quoteToken
    ) internal {
        require(uint256(pythLazerFeedId) < type(uint32).max, LazerIdOverflow(pythLazerFeedId));
        require(_addFeedId(pythLazerFeedId), FeedAlreadyExists(pythLazerFeedId));
        _setBaseAndQuoteTokens(pythLazerFeedId, baseToken, quoteToken);

        emit FeedRegistered(
            pythLazerFeedId,
            baseToken,
            quoteToken,
            address(0), // stateGuard — not set at registration
            0,          // minPrice
            0,          // maxPrice
            ""          // misc
        );
    }

    /// calldata format: [deadline:4][feedsLength:2][feedIds:feedsLength×4][priceUpdate:rest]
    fallback() payable external override {
        uint256 end;
        uint256 deadline;

        assembly ("memory-safe") {
            deadline := shr(224, calldataload(0)) // first 4 bytes
            end := calldatasize()
        }
        _ensureDeadline(deadline);


        uint256 feedsLength;
        assembly ("memory-safe") {
            feedsLength := shr(240, calldataload(4)) // 2 byte at offset 4
        }

        uint32[] memory updateFeedIds = new uint32[](feedsLength);
        assembly ("memory-safe") {
            let dst := add(updateFeedIds, 32)  // skip length slot
            let src := 6                       // offset after deadline(4) + feedsLength(2)
            
            for { let i := 0 } lt(i, feedsLength) { i := add(i, 1) } {
                // load 32 bytes, shift right to get uint32 from high bits
                mstore(dst, shr(224, calldataload(src)))
                dst := add(dst, 32)
                src := add(src, 4)
            }
        }

        uint256 priceUpdateOffset = 6 + feedsLength * 4;
        bytes calldata priceUpdate;
        assembly ("memory-safe") {
            priceUpdate.offset := priceUpdateOffset
            priceUpdate.length := sub(end, priceUpdateOffset)
        }

        _verifyAndStore(feedIds, oracleData, updateFeedIds, priceUpdate);
    }

    receive() external override payable {}
}
