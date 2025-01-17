// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.16;

import "../../interfaces/SlashingLibraryInterface.sol";

/**
 * @title Slashing Library contract that executes no slashing for any actions. Used in tests.
 */

contract ZeroedSlashingSlashingLibraryTest is SlashingLibraryInterface {
    function calcWrongVoteSlashPerToken(
        uint256 totalStaked,
        uint256 totalVotes,
        uint256 totalCorrectVotes
    ) public pure returns (uint256) {
        return 0;
    }

    function calcWrongVoteSlashPerTokenGovernance(
        uint256 totalStaked,
        uint256 totalVotes,
        uint256 totalCorrectVotes
    ) public pure returns (uint256) {
        return 0;
    }

    function calcNoVoteSlashPerToken(
        uint256 totalStaked,
        uint256 totalVotes,
        uint256 totalCorrectVotes
    ) public pure returns (uint256) {
        return 0;
    }

    function calcSlashing(
        uint256 totalStaked,
        uint256 totalVotes,
        uint256 totalCorrectVotes,
        bool isGovernance
    ) external pure returns (uint256 wrongVoteSlashPerToken, uint256 noVoteSlashPerToken) {
        return (
            isGovernance
                ? calcWrongVoteSlashPerTokenGovernance(totalStaked, totalVotes, totalCorrectVotes)
                : calcWrongVoteSlashPerToken(totalStaked, totalVotes, totalCorrectVotes),
            calcNoVoteSlashPerToken(totalStaked, totalVotes, totalCorrectVotes)
        );
    }
}
