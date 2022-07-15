// TODO: this whole /oracle/implementation directory should be restructured to separate the DVM and the OO.

// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../../common/implementation/AncillaryData.sol";
import "../../common/implementation/MultiCaller.sol";

import "../interfaces/FinderInterface.sol";
import "../interfaces/OracleInterface.sol";
import "../interfaces/OracleAncillaryInterface.sol";
import "../interfaces/OracleGovernanceInterface.sol";
import "../interfaces/VotingV2Interface.sol";
import "../interfaces/IdentifierWhitelistInterface.sol";
import "./Registry.sol";
import "./ResultComputationV2.sol";
import "./VoteTimingV2.sol";
import "./Staker.sol";
import "./Constants.sol";
import "./SlashingLibrary.sol";
import "./SpamGuardIdentifierLib.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title Voting system for Oracle.
 * @dev Handles receiving and resolving price requests via a commit-reveal voting scheme.
 */

contract VotingV2 is
    Staker,
    OracleInterface,
    OracleAncillaryInterface, // Interface to support ancillary data with price requests.
    OracleGovernanceInterface, // Interface to support governance requests.
    VotingV2Interface,
    MultiCaller
{
    using SafeMath for uint256;
    using VoteTimingV2 for VoteTimingV2.Data;
    using ResultComputationV2 for ResultComputationV2.Data;

    /****************************************
     *        VOTING DATA STRUCTURES        *
     ****************************************/

    // Identifies a unique price request for which the Oracle will always return the same value.
    // Tracks ongoing votes as well as the result of the vote.

    struct PriceRequest {
        bytes32 identifier;
        uint256 time;
        // A map containing all votes for this price in various rounds.
        mapping(uint256 => VoteInstance) voteInstances;
        // If in the past, this was the voting round where this price was resolved. If current or the upcoming round,
        // this is the voting round where this price will be voted on, but not necessarily resolved.
        uint256 lastVotingRound;
        // The pendingRequestIndex in the `pendingPriceRequests` that references this PriceRequest. A value of UINT_MAX
        // means that this PriceRequest is resolved and has been cleaned up from `pendingPriceRequests`.
        uint256 pendingRequestIndex;
        // Each request has a unique requestIndex number that is used to order all requests. This is the index within
        // the priceRequestIds array and is incremented on each request.
        uint256 priceRequestIndex;
        bool isGovernance;
        bytes ancillaryData;
    }

    struct VoteInstance {
        // Maps (voterAddress) to their submission.
        mapping(address => VoteSubmission) voteSubmissions;
        // The data structure containing the computed voting results.
        ResultComputationV2.Data resultComputation;
    }

    struct VoteSubmission {
        // A bytes32 of `0` indicates no commit or a commit that was already revealed.
        bytes32 commit;
        // The hash of the value that was revealed.
        // Note: this is only used for computation of rewards.
        bytes32 revealHash;
    }

    struct Round {
        uint256 gatPercentage; // Gat rate set for this round.
        uint256 cumulativeActiveStakeAtRound; // Total staked tokens at the start of the round.
    }

    // Represents the status a price request has.
    enum RequestStatus {
        NotRequested, // Was never requested.
        Active, // Is being voted on in the current round.
        Resolved, // Was resolved in a previous round.
        Future // Is scheduled to be voted on in a future round.
    }

    // Only used as a return value in view methods -- never stored in the contract.
    struct RequestState {
        RequestStatus status;
        uint256 lastVotingRound;
    }

    /****************************************
     *          INTERNAL TRACKING           *
     ****************************************/

    // Maps round numbers to the rounds.
    mapping(uint256 => Round) public rounds;

    // Maps price request IDs to the PriceRequest struct.
    mapping(bytes32 => PriceRequest) internal priceRequests;

    bytes32[] public priceRequestIds;

    mapping(uint256 => uint256) public deletedRequests;

    // Price request ids for price requests that haven't yet been marked as resolved.
    // These requests may be for future rounds.
    bytes32[] internal pendingPriceRequests;

    VoteTimingV2.Data public voteTiming;

    // Percentage of the total token supply that must be used in a vote to
    // create a valid price resolution. 1 == 100%.
    uint256 public gatPercentage;

    // Reference to the Finder.
    FinderInterface private immutable finder;

    // Reference to Slashing Library.
    SlashingLibrary public slashingLibrary;

    // If non-zero, this contract has been migrated to this address. All voters and
    // financial contracts should query the new address only.
    address public migratedAddress;

    // Max value of an unsigned integer.
    uint256 private constant UINT_MAX = ~uint256(0);

    // Max length in bytes of ancillary data that can be appended to a price request.
    // As of December 2020, the current Ethereum gas limit is 12.5 million. This requestPrice function's gas primarily
    // comes from computing a Keccak-256 hash in _encodePriceRequest and writing a new PriceRequest to
    // storage. We have empirically determined an ancillary data limit of 8192 bytes that keeps this function
    // well within the gas limit at ~8 million gas. To learn more about the gas limit and EVM opcode costs go here:
    // - https://etherscan.io/chart/gaslimit
    // - https://github.com/djrtwo/evm-opcode-gas-costs
    uint256 public constant ancillaryBytesLimit = 8192;

    /****************************************
     *          SLASHING TRACKERS           *
     ****************************************/

    uint256 public lastRequestIndexConsidered;

    // Only used as a return value in view methods -- never stored in the contract.
    struct SlashingTracker {
        uint256 wrongVoteSlashPerToken;
        uint256 noVoteSlashPerToken;
        uint256 totalSlashed;
        uint256 totalCorrectVotes;
    }

    /****************************************
     *        SPAM DELETION TRACKERS        *
     ****************************************/

    uint256 spamDeletionProposalBond;

    struct SpamDeletionRequest {
        uint256[2][] spamRequestIndices;
        uint256 requestTime;
        bool executed;
        address proposer;
    }

    // Maps round numbers to the spam deletion request.
    SpamDeletionRequest[] internal spamDeletionProposals;

    /****************************************
     *                EVENTS                *
     ****************************************/

    event VoteCommitted(
        address indexed voter,
        address indexed caller,
        uint256 roundId,
        bytes32 indexed identifier,
        uint256 time,
        bytes ancillaryData
    );

    event EncryptedVote(
        address indexed voter,
        uint256 indexed roundId,
        bytes32 indexed identifier,
        uint256 time,
        bytes ancillaryData,
        bytes encryptedVote
    );

    event VoteRevealed(
        address indexed voter,
        address indexed caller,
        uint256 roundId,
        bytes32 indexed identifier,
        uint256 time,
        int256 price,
        bytes ancillaryData,
        uint256 numTokens
    );

    event RewardsRetrieved(
        address indexed voter,
        uint256 indexed roundId,
        bytes32 indexed identifier,
        uint256 time,
        bytes ancillaryData,
        uint256 numTokens
    );

    event PriceRequestAdded(uint256 indexed roundId, bytes32 indexed identifier, uint256 time, bytes ancillaryData);

    event PriceResolved(
        uint256 indexed roundId,
        bytes32 indexed identifier,
        uint256 time,
        int256 price,
        bytes ancillaryData
    );

    // /**
    //  * @notice Construct the Voting contract.
    //  * @param _phaseLength length of the commit and reveal phases in seconds.
    //  * @param _gatPercentage of the total token supply that must be used in a vote to create a valid price resolution.
    //  * @param _votingToken address of the UMA token contract used to commit votes.
    //  * @param _finder keeps track of all contracts within the system based on their interfaceName.
    //  * @param _timerAddress Contract that stores the current time in a testing environment.
    //  * Must be set to 0x0 for production environments that use live time.
    //  */
    constructor(
        uint256 _emissionRate,
        uint256 _spamDeletionProposalBond,
        uint256 _unstakeCoolDown,
        uint256 _phaseLength,
        uint256 _minRollToNextRoundLength,
        uint256 _gatPercentage,
        address _votingToken,
        address _finder,
        address _timerAddress,
        address _slashingLibrary
    ) Staker(_emissionRate, _unstakeCoolDown, _votingToken, _timerAddress) {
        voteTiming.init(_phaseLength, _minRollToNextRoundLength);
        require(_gatPercentage <= 1e18, "GAT percentage must be <= 100%");
        gatPercentage = _gatPercentage;
        finder = FinderInterface(_finder);
        slashingLibrary = SlashingLibrary(_slashingLibrary);
        setSpamDeletionProposalBond(_spamDeletionProposalBond);
    }

    /***************************************
                    MODIFIERS
    ****************************************/

    modifier onlyRegisteredContract() {
        if (migratedAddress != address(0)) {
            require(msg.sender == migratedAddress, "Caller must be migrated address");
        } else {
            Registry registry = Registry(finder.getImplementationAddress(OracleInterfaces.Registry));
            require(registry.isContractRegistered(msg.sender), "Called must be registered");
        }
        _;
    }

    modifier onlyIfNotMigrated() {
        require(migratedAddress == address(0), "Only call this if not migrated");
        _;
    }

    /****************************************
     *          STAKING FUNCTIONS           *
     ****************************************/

    function updateTrackers(address voterAddress) public {
        _updateTrackers(voterAddress);
    }

    function updateTrackersRange(address voterAddress, uint256 indexTo) public {
        require(voterStakes[voterAddress].lastRequestIndexConsidered < indexTo, "IndexTo not after last request");
        require(indexTo <= priceRequestIds.length, "Bad indexTo");

        _updateAccountSlashingTrackers(voterAddress, indexTo);
    }

    function _updateTrackers(address voterAddress) internal override {
        _updateAccountSlashingTrackers(voterAddress, priceRequestIds.length);
        super._updateTrackers(voterAddress);
    }

    function getStartingIndexForStaker() internal view override returns (uint256) {
        return priceRequestIds.length - (inActiveReveal() ? 0 : pendingPriceRequests.length);
    }

    function inActiveReveal() public view override returns (bool) {
        return (currentActiveRequests() && getVotePhase() == Phase.Reveal);
    }

    function _updateAccountSlashingTrackers(address voterAddress, uint256 indexTo) internal {
        uint256 currentRoundId = voteTiming.computeCurrentRoundId(getCurrentTime());
        VoterStake storage voterStake = voterStakes[voterAddress];
        // Note the method below can hit a gas limit of there are a LOT of requests from the last time this was run.
        // A future version of this should bound how many requests to look at per call to avoid gas limit issues.

        // Traverse all requests from the last considered request. For each request see if the voter voted correctly or
        // not. Based on the outcome, attribute the associated slash to the voter.
        int256 slash = 0;
        for (
            uint256 requestIndex = voterStake.lastRequestIndexConsidered;
            requestIndex < indexTo;
            requestIndex = unsafe_inc(requestIndex)
        ) {
            if (deletedRequests[requestIndex] != 0) requestIndex = deletedRequests[requestIndex] + 1;
            if (requestIndex > indexTo - 1) break; // This happens if the last element was a rolled vote.
            PriceRequest storage priceRequest = priceRequests[priceRequestIds[requestIndex]];
            VoteInstance storage voteInstance = priceRequest.voteInstances[priceRequest.lastVotingRound];

            // If the request status is not resolved then: a) Either we are still in the current voting round, in which
            // case break the loop and stop iterating (all subsequent requests will be in the same state by default) or
            // b) we have gotten to a rolled vote in which case we need to update some internal trackers for this vote
            // and set this within the deletedRequests mapping so the next time we hit this it is skipped.
            if (!_resolvePriceRequest(priceRequest, voteInstance, currentRoundId)) {
                // If the request is not resolved and the lastVotingRound less than the current round then the vote
                // must have been rolled. In this case, update the internal trackers for this vote.
                if (priceRequest.lastVotingRound < currentRoundId) {
                    priceRequest.lastVotingRound = currentRoundId;
                    deletedRequests[requestIndex] = requestIndex;
                    priceRequest.priceRequestIndex = priceRequestIds.length;
                    priceRequestIds.push(priceRequestIds[requestIndex]);
                    _updateAccountSlashingTrackers(voterAddress, priceRequestIds.length);
                }
                // Else, we are simply evaluating a request that is still actively being voted on. In this case, break as
                // all subsequent requests within the array must be in the same state and cant have any slashing applied.
                break;
            }

            uint256 totalCorrectVotes = voteInstance.resultComputation.getTotalCorrectlyVotedTokens();

            (uint256 wrongVoteSlash, uint256 noVoteSlash) =
                slashingLibrary.calcSlashing(
                    rounds[priceRequest.lastVotingRound].cumulativeActiveStakeAtRound,
                    voteInstance.resultComputation.totalVotes,
                    totalCorrectVotes,
                    priceRequest.isGovernance
                );

            uint256 totalSlashed =
                ((noVoteSlash *
                    (rounds[priceRequest.lastVotingRound].cumulativeActiveStakeAtRound -
                        voteInstance.resultComputation.totalVotes)) / 1e18) +
                    ((wrongVoteSlash * (voteInstance.resultComputation.totalVotes - totalCorrectVotes)) / 1e18);

            // The voter did not reveal or did not commit. Slash at noVote rate.
            if (voteInstance.voteSubmissions[voterAddress].revealHash == 0)
                slash -= int256((voterStake.activeStake * noVoteSlash) / 1e18);

                // The voter did not vote with the majority. Slash at wrongVote rate.
            else if (
                !voteInstance.resultComputation.wasVoteCorrect(voteInstance.voteSubmissions[voterAddress].revealHash)
            )
                slash -= int256((voterStake.activeStake * wrongVoteSlash) / 1e18);

                // The voter voted correctly. Receive a pro-rate share of the other voters slashed amounts as a reward.
            else slash += int256((((voterStake.activeStake * totalSlashed)) / totalCorrectVotes));

            // If this is not the last price request to apply and the next request in the batch is from a subsequent
            // round then apply the slashing now. Else, do nothing and apply the slashing after the loop concludes.
            // This acts to apply slashing within a round as independent actions: multiple votes within the same round

            // should not impact each other but subsequent rounds should impact each other. We need to consider the
            // deletedRequests mapping when finding the next index as the next request may have been deleted or rolled.
            uint256 nextRequestIndex =
                deletedRequests[requestIndex + 1] != 0 ? deletedRequests[requestIndex + 1] + 1 : requestIndex + 1;
            if (
                slash != 0 &&
                indexTo > nextRequestIndex &&
                priceRequest.lastVotingRound != priceRequests[priceRequestIds[nextRequestIndex]].lastVotingRound
            ) {
                applySlashToVoter(slash, voterStake);
                slash = 0;
            }
            voterStake.lastRequestIndexConsidered = requestIndex + 1;
        }

        if (slash != 0) applySlashToVoter(slash, voterStake);
    }

    function applySlashToVoter(int256 slash, VoterStake storage voterStake) internal {
        if (slash + int256(voterStake.activeStake) > 0)
            voterStake.activeStake = uint256(int256(voterStake.activeStake) + slash);
        else voterStake.activeStake = 0;
    }

    /****************************************
     *       SPAM DELETION FUNCTIONS        *
     ****************************************/

    function signalRequestsAsSpamForDeletion(uint256[2][] calldata spamRequestIndices) public {
        votingToken.transferFrom(msg.sender, address(this), spamDeletionProposalBond);
        uint256 currentTime = getCurrentTime();
        uint256 runningValidationIndex;
        uint256 spamRequestIndicesLength = spamRequestIndices.length;
        for (uint256 i = 0; i < spamRequestIndicesLength; i = unsafe_inc(i)) {
            uint256[2] memory spamRequestIndex = spamRequestIndices[i];
            // Check request end index is greater than start index.
            require(spamRequestIndex[0] <= spamRequestIndex[1], "Bad start index");

            // check the endIndex is less than the total number of requests.
            require(spamRequestIndex[1] < priceRequestIds.length, "Bad end index");

            // Validate index continuity. This checks that each sequential element within the spamRequestIndices
            // array is sequently and increasing in size.
            require(spamRequestIndex[1] > runningValidationIndex, "Bad index continuity");
            runningValidationIndex = spamRequestIndex[1];
        }

        spamDeletionProposals.push(SpamDeletionRequest(spamRequestIndices, currentTime, false, msg.sender));
        uint256 proposalId = spamDeletionProposals.length - 1;

        bytes32 identifier = SpamGuardIdentifierLib._constructIdentifier(proposalId);

        _requestPrice(identifier, currentTime, "", true);
    }

    function executeSpamDeletion(uint256 proposalId) public {
        require(spamDeletionProposals[proposalId].executed == false, "Already executed");
        spamDeletionProposals[proposalId].executed = true;
        bytes32 identifier = SpamGuardIdentifierLib._constructIdentifier(proposalId);

        (bool hasPrice, int256 resolutionPrice, ) =
            _getPriceOrError(identifier, spamDeletionProposals[proposalId].requestTime, "");
        require(hasPrice, "Price not yet resolved");

        // If the price is 1e18 then the spam deletion request was correctly voted on to delete the requests.
        if (resolutionPrice == 1e18) {
            // Delete the price requests associated with the spam.
            for (uint256 i = 0; i < spamDeletionProposals[proposalId].spamRequestIndices.length; i = unsafe_inc(i)) {
                uint256 startIndex = spamDeletionProposals[proposalId].spamRequestIndices[uint256(i)][0];
                uint256 endIndex = spamDeletionProposals[proposalId].spamRequestIndices[uint256(i)][1];
                for (uint256 j = startIndex; j <= endIndex; j++) {
                    bytes32 requestId = priceRequestIds[j];
                    // Remove from pendingPriceRequests.
                    uint256 lastIndex = pendingPriceRequests.length - 1;
                    PriceRequest storage lastPriceRequest = priceRequests[pendingPriceRequests[lastIndex]];
                    lastPriceRequest.pendingRequestIndex = priceRequests[requestId].pendingRequestIndex;
                    pendingPriceRequests[priceRequests[requestId].pendingRequestIndex] = pendingPriceRequests[
                        lastIndex
                    ];
                    pendingPriceRequests.pop();

                    // Remove the request from the priceRequests mapping.
                    delete priceRequests[requestId];
                }

                // Set the deletion request jump mapping. This enables the for loops that iterate over requests to skip
                // the deleted requests via a "jump" over the removed elements from the array.
                deletedRequests[startIndex] = endIndex;
            }

            // Return the spamDeletionProposalBond.
            votingToken.transfer(spamDeletionProposals[proposalId].proposer, spamDeletionProposalBond);
        }
        // Else, the spam deletion request was voted down. In this case we send the spamDeletionProposalBond to the store.
        else {
            votingToken.transfer(finder.getImplementationAddress(OracleInterfaces.Store), spamDeletionProposalBond);
        }
    }

    function setSpamDeletionProposalBond(uint256 _spamDeletionProposalBond) public onlyOwner() {
        spamDeletionProposalBond = _spamDeletionProposalBond;
    }

    function getSpamDeletionRequest(uint256 spamDeletionRequestId) public view returns (SpamDeletionRequest memory) {
        return spamDeletionProposals[spamDeletionRequestId];
    }

    /****************************************
     *  PRICE REQUEST AND ACCESS FUNCTIONS  *
     ****************************************/

    /**
     * @notice Enqueues a request (if a request isn't already present) for the given `identifier`, `time` pair.
     * @dev Time must be in the past and the identifier must be supported. The length of the ancillary data
     * is limited such that this method abides by the EVM transaction gas limit.
     * @param identifier uniquely identifies the price requested. eg BTC/USD (encoded as bytes32) could be requested.
     * @param time unix timestamp for the price request.
     * @param ancillaryData arbitrary data appended to a price request to give the voters more info from the caller.
     */
    function requestPrice(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData
    ) public override onlyRegisteredContract() {
        _requestPrice(identifier, time, ancillaryData, false);
    }

    /**
     * @notice Enqueues a governance action request (if a request isn't already present) for the given `identifier`, `time` pair.
     * @dev Time must be in the past and the identifier must be supported. The length of the ancillary data
     * is limited such that this method abides by the EVM transaction gas limit.
     * @param identifier uniquely identifies the price requested. eg BTC/USD (encoded as bytes32) could be requested.
     * @param time unix timestamp for the price request.
     * @param ancillaryData arbitrary data appended to a price request to give the voters more info from the caller.
     */
    function requestGovernanceAction(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData
    ) public override onlyOwner() {
        _requestPrice(identifier, time, ancillaryData, true);
    }

    /**
     * @notice Enqueues a request (if a request isn't already present) for the given `identifier`, `time` pair.
     * @dev Time must be in the past and the identifier must be supported. The length of the ancillary data
     * is limited such that this method abides by the EVM transaction gas limit.
     * @param identifier uniquely identifies the price requested. eg BTC/USD (encoded as bytes32) could be requested.
     * @param time unix timestamp for the price request.
     * @param ancillaryData arbitrary data appended to a price request to give the voters more info from the caller.
     * @param isGovernance indicates whether the request is for a governance action.
     */
    function _requestPrice(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData,
        bool isGovernance
    ) internal {
        uint256 blockTime = getCurrentTime();
        require(time <= blockTime, "Can only request in past");
        require(
            isGovernance || _getIdentifierWhitelist().isIdentifierSupported(identifier),
            "Unsupported identifier request"
        );
        require(ancillaryData.length <= ancillaryBytesLimit, "Invalid ancillary data");

        bytes32 priceRequestId = _encodePriceRequest(identifier, time, ancillaryData);
        PriceRequest storage priceRequest = priceRequests[priceRequestId];
        uint256 currentRoundId = voteTiming.computeCurrentRoundId(blockTime);

        RequestStatus requestStatus = _getRequestStatus(priceRequest, currentRoundId);

        if (requestStatus == RequestStatus.NotRequested) {
            // Price has never been requested.
            // If the price request is a governance action then always place it in the following round. If the price
            // request is a normal request then either place it in the next round or the following round based off
            // the minRolllToNextRoundLength.
            uint256 roundIdToVoteOnPriceRequest =
                isGovernance ? currentRoundId + 1 : voteTiming.computeRoundToVoteOnPriceRequest(blockTime);
            PriceRequest storage newPriceRequest = priceRequests[priceRequestId];
            newPriceRequest.identifier = identifier;
            newPriceRequest.time = time;
            newPriceRequest.lastVotingRound = roundIdToVoteOnPriceRequest;
            newPriceRequest.pendingRequestIndex = pendingPriceRequests.length;
            newPriceRequest.priceRequestIndex = priceRequestIds.length;
            newPriceRequest.ancillaryData = ancillaryData;
            newPriceRequest.isGovernance = isGovernance;

            pendingPriceRequests.push(priceRequestId);
            priceRequestIds.push(priceRequestId);
            emit PriceRequestAdded(roundIdToVoteOnPriceRequest, identifier, time, ancillaryData);
        }
    }

    // Overloaded method to enable short term backwards compatibility. Will be deprecated in the next DVM version.
    function requestPrice(bytes32 identifier, uint256 time) public override {
        requestPrice(identifier, time, "");
    }

    /**
     * @notice Whether the price for `identifier` and `time` is available.
     * @dev Time must be in the past and the identifier must be supported.
     * @param identifier uniquely identifies the price requested. eg BTC/USD (encoded as bytes32) could be requested.
     * @param time unix timestamp of for the price request.
     * @param ancillaryData arbitrary data appended to a price request to give the voters more info from the caller.
     * @return _hasPrice bool if the DVM has resolved to a price for the given identifier and timestamp.
     */
    function hasPrice(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData
    ) public view override onlyRegisteredContract() returns (bool) {
        (bool _hasPrice, , ) = _getPriceOrError(identifier, time, ancillaryData);
        return _hasPrice;
    }

    // Overloaded method to enable short term backwards compatibility. Will be deprecated in the next DVM version.
    function hasPrice(bytes32 identifier, uint256 time) public view override returns (bool) {
        return hasPrice(identifier, time, "");
    }

    /**
     * @notice Gets the price for `identifier` and `time` if it has already been requested and resolved.
     * @dev If the price is not available, the method reverts.
     * @param identifier uniquely identifies the price requested. eg BTC/USD (encoded as bytes32) could be requested.
     * @param time unix timestamp of for the price request.
     * @param ancillaryData arbitrary data appended to a price request to give the voters more info from the caller.
     * @return int256 representing the resolved price for the given identifier and timestamp.
     */
    function getPrice(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData
    ) public view override onlyRegisteredContract() returns (int256) {
        (bool _hasPrice, int256 price, string memory message) = _getPriceOrError(identifier, time, ancillaryData);

        // If the price wasn't available, revert with the provided message.
        require(_hasPrice, message);
        return price;
    }

    // Overloaded method to enable short term backwards compatibility. Will be deprecated in the next DVM version.
    function getPrice(bytes32 identifier, uint256 time) public view override returns (int256) {
        return getPrice(identifier, time, "");
    }

    /**
     * @notice Gets the status of a list of price requests, identified by their identifier and time.
     * @dev If the status for a particular request is NotRequested, the lastVotingRound will always be 0.
     * @param requests array of type PendingRequest which includes an identifier and timestamp for each request.
     * @return requestStates a list, in the same order as the input list, giving the status of each of the specified price requests.
     */
    function getPriceRequestStatuses(PendingRequestAncillary[] memory requests)
        public
        view
        returns (RequestState[] memory)
    {
        RequestState[] memory requestStates = new RequestState[](requests.length);
        uint256 currentRoundId = voteTiming.computeCurrentRoundId(getCurrentTime());
        for (uint256 i = 0; i < requests.length; i = unsafe_inc(i)) {
            PriceRequest storage priceRequest =
                _getPriceRequest(requests[i].identifier, requests[i].time, requests[i].ancillaryData);

            RequestStatus status = _getRequestStatus(priceRequest, currentRoundId);

            // If it's an active request, its true lastVotingRound is the current one, even if it hasn't been updated.
            if (status == RequestStatus.Active) requestStates[i].lastVotingRound = currentRoundId;
            else requestStates[i].lastVotingRound = priceRequest.lastVotingRound;
            requestStates[i].status = status;
        }
        return requestStates;
    }

    // Overloaded method to enable short term backwards compatibility. Will be deprecated in the next DVM version.
    function getPriceRequestStatuses(PendingRequest[] memory requests) public view returns (RequestState[] memory) {
        PendingRequestAncillary[] memory requestsAncillary = new PendingRequestAncillary[](requests.length);

        for (uint256 i = 0; i < requests.length; i = unsafe_inc(i)) {
            requestsAncillary[i].identifier = requests[i].identifier;
            requestsAncillary[i].time = requests[i].time;
            requestsAncillary[i].ancillaryData = "";
        }
        return getPriceRequestStatuses(requestsAncillary);
    }

    /****************************************
     *            VOTING FUNCTIONS          *
     ****************************************/

    /**
     * @notice Commit a vote for a price request for `identifier` at `time`.
     * @dev `identifier`, `time` must correspond to a price request that's currently in the commit phase.
     * Commits can be changed.
     * @dev Since transaction data is public, the salt will be revealed with the vote. While this is the system’s
     * expected behavior, voters should never reuse salts. If someone else is able to guess the voted price and knows
     * that a salt will be reused, then they can determine the vote pre-reveal.
     * @param identifier uniquely identifies the committed vote. EG BTC/USD price pair.
     * @param time unix timestamp of the price being voted on.
     * @param ancillaryData arbitrary data appended to a price request to give the voters more info from the caller.
     * @param hash keccak256 hash of the `price`, `salt`, voter `address`, `time`, current `roundId`, and `identifier`.
     */
    function commitVote(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData,
        bytes32 hash
    ) public override onlyIfNotMigrated() {
        uint256 currentRoundId = voteTiming.computeCurrentRoundId(getCurrentTime());
        address voter = getVoterFromDelegate(msg.sender);
        _updateTrackers(voter);
        // At this point, the computed and last updated round ID should be equal.
        uint256 blockTime = getCurrentTime();
        require(hash != bytes32(0), "Invalid provided hash");
        // Current time is required for all vote timing queries.
        require(voteTiming.computeCurrentPhase(blockTime) == Phase.Commit, "Cannot commit in reveal phase");

        PriceRequest storage priceRequest = _getPriceRequest(identifier, time, ancillaryData);
        require(
            _getRequestStatus(priceRequest, currentRoundId) == RequestStatus.Active,
            "Cannot commit inactive request"
        );

        VoteInstance storage voteInstance = priceRequest.voteInstances[currentRoundId];
        voteInstance.voteSubmissions[voter].commit = hash;

        emit VoteCommitted(voter, msg.sender, currentRoundId, identifier, time, ancillaryData);
    }

    // Overloaded method to enable short term backwards compatibility. Will be deprecated in the next DVM version.
    function commitVote(
        bytes32 identifier,
        uint256 time,
        bytes32 hash
    ) public override onlyIfNotMigrated() {
        commitVote(identifier, time, "", hash);
    }

    /**
     * @notice Reveal a previously committed vote for `identifier` at `time`.
     * @dev The revealed `price`, `salt`, `address`, `time`, `roundId`, and `identifier`, must hash to the latest `hash`
     * that `commitVote()` was called with. Only the committer can reveal their vote.
     * @param identifier voted on in the commit phase. EG BTC/USD price pair.
     * @param time specifies the unix timestamp of the price being voted on.
     * @param price voted on during the commit phase.
     * @param ancillaryData arbitrary data appended to a price request to give the voters more info from the caller.
     * @param salt value used to hide the commitment price during the commit phase.
     */
    function revealVote(
        bytes32 identifier,
        uint256 time,
        int256 price,
        bytes memory ancillaryData,
        int256 salt
    ) public override onlyIfNotMigrated() {
        // Note: computing the current round is required to disallow people from revealing an old commit after the round is over.
        uint256 currentRoundId = voteTiming.computeCurrentRoundId(getCurrentTime());
        _freezeRoundVariables(currentRoundId);
        VoteInstance storage voteInstance =
            _getPriceRequest(identifier, time, ancillaryData).voteInstances[currentRoundId];
        address voter = getVoterFromDelegate(msg.sender);
        VoteSubmission storage voteSubmission = voteInstance.voteSubmissions[voter];

        // Scoping to get rid of a stack too deep errors for require messages.
        {
            // Can only reveal in the reveal phase.
            require(voteTiming.computeCurrentPhase(getCurrentTime()) == Phase.Reveal, "Cannot reveal in commit phase");
            // 0 hashes are disallowed in the commit phase, so they indicate a different error.
            // Cannot reveal an uncommitted or previously revealed hash
            require(voteSubmission.commit != bytes32(0), "Invalid hash reveal");

            // Check that the hash that was committed matches to the one that was revealed. Note that if the voter had
            // delegated this means that they must reveal with the same account they had committed with.
            require(
                keccak256(abi.encodePacked(price, salt, msg.sender, time, ancillaryData, currentRoundId, identifier)) ==
                    voteSubmission.commit,
                "Revealed data != commit hash"
            );
        }

        delete voteSubmission.commit;

        // Get the voter's snapshotted balance. Since balances are returned pre-scaled by 10**18, we can directly
        // initialize the Unsigned value with the returned uint.
        uint256 balance = voterStakes[voter].activeStake;

        // Set the voter's submission.
        voteSubmission.revealHash = keccak256(abi.encode(price));

        // Add vote to the results.
        voteInstance.resultComputation.addVote(price, balance);

        emit VoteRevealed(voter, msg.sender, currentRoundId, identifier, time, price, ancillaryData, balance);
    }

    // Overloaded method to enable short term backwards compatibility. Will be deprecated in the next DVM version.
    function revealVote(
        bytes32 identifier,
        uint256 time,
        int256 price,
        int256 salt
    ) public override {
        revealVote(identifier, time, price, "", salt);
    }

    /**
     * @notice commits a vote and logs an event with a data blob, typically an encrypted version of the vote
     * @dev An encrypted version of the vote is emitted in an event `EncryptedVote` to allow off-chain infrastructure to
     * retrieve the commit. The contents of `encryptedVote` are never used on chain: it is purely for convenience.
     * @param identifier unique price pair identifier. Eg: BTC/USD price pair.
     * @param time unix timestamp of for the price request.
     * @param ancillaryData arbitrary data appended to a price request to give the voters more info from the caller.
     * @param hash keccak256 hash of the price you want to vote for and a `int256 salt`.
     * @param encryptedVote offchain encrypted blob containing the voters amount, time and salt.
     */
    function commitAndEmitEncryptedVote(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData,
        bytes32 hash,
        bytes memory encryptedVote
    ) public override {
        commitVote(identifier, time, ancillaryData, hash);

        uint256 roundId = voteTiming.computeCurrentRoundId(getCurrentTime());
        emit EncryptedVote(msg.sender, roundId, identifier, time, ancillaryData, encryptedVote);
    }

    // Overloaded method to enable short term backwards compatibility. Will be deprecated in the next DVM version.
    function commitAndEmitEncryptedVote(
        bytes32 identifier,
        uint256 time,
        bytes32 hash,
        bytes memory encryptedVote
    ) public override {
        commitVote(identifier, time, "", hash);

        commitAndEmitEncryptedVote(identifier, time, "", hash, encryptedVote);
    }

    function setDelegate(address delegate) public {
        voterStakes[msg.sender].delegate = delegate;
    }

    function setDelegator(address delegator) public {
        delegateToStaker[msg.sender] = delegator;
    }

    /****************************************
     *        VOTING GETTER FUNCTIONS       *
     ****************************************/

    function getVoterFromDelegate(address caller) public view returns (address) {
        if (
            delegateToStaker[caller] != address(0) && // The delegate chose to be a delegate for the staker.
            voterStakes[delegateToStaker[caller]].delegate == caller // The staker chose the delegate.
        ) return delegateToStaker[caller];
        else return caller;
    }

    /**
     * @notice Gets the queries that are being voted on this round.
     * @return pendingRequests array containing identifiers of type `PendingRequest`.
     * and timestamps for all pending requests.
     */
    function getPendingRequests() public view override returns (PendingRequestAncillary[] memory) {
        uint256 blockTime = getCurrentTime();
        uint256 currentRoundId = voteTiming.computeCurrentRoundId(blockTime);

        // Solidity memory arrays aren't resizable (and reading storage is expensive). Hence this hackery to filter
        // `pendingPriceRequests` only to those requests that have an Active RequestStatus.
        PendingRequestAncillary[] memory unresolved = new PendingRequestAncillary[](pendingPriceRequests.length);
        uint256 numUnresolved = 0;

        for (uint256 i = 0; i < pendingPriceRequests.length; i = unsafe_inc(i)) {
            PriceRequest storage priceRequest = priceRequests[pendingPriceRequests[i]];
            if (_getRequestStatus(priceRequest, currentRoundId) == RequestStatus.Active) {
                unresolved[numUnresolved] = PendingRequestAncillary({
                    identifier: priceRequest.identifier,
                    time: priceRequest.time,
                    ancillaryData: priceRequest.ancillaryData
                });
                numUnresolved++;
            }
        }

        PendingRequestAncillary[] memory pendingRequests = new PendingRequestAncillary[](numUnresolved);
        for (uint256 i = 0; i < numUnresolved; i = unsafe_inc(i)) {
            pendingRequests[i] = unresolved[i];
        }
        return pendingRequests;
    }

    function currentActiveRequests() public view returns (bool) {
        uint256 blockTime = getCurrentTime();
        uint256 currentRoundId = voteTiming.computeCurrentRoundId(blockTime);
        for (uint256 i = 0; i < pendingPriceRequests.length; i = unsafe_inc(i)) {
            if (_getRequestStatus(priceRequests[pendingPriceRequests[i]], currentRoundId) == RequestStatus.Active)
                return true;
        }
        return false;
    }

    /**
     * @notice Returns the current voting phase, as a function of the current time.
     * @return Phase to indicate the current phase. Either { Commit, Reveal, NUM_PHASES_PLACEHOLDER }.
     */
    function getVotePhase() public view override returns (Phase) {
        return voteTiming.computeCurrentPhase(getCurrentTime());
    }

    /**
     * @notice Returns the current round ID, as a function of the current time.
     * @return uint256 representing the unique round ID.
     */
    function getCurrentRoundId() public view override returns (uint256) {
        return voteTiming.computeCurrentRoundId(getCurrentTime());
    }

    function getRoundEndTime(uint256 roundId) public view returns (uint256) {
        return voteTiming.computeRoundEndTime(roundId);
    }

    function getNumberOfPriceRequests() public view returns (uint256) {
        return priceRequestIds.length;
    }

    function requestSlashingTrackers(uint256 requestIndex) public view returns (SlashingTracker memory) {
        uint256 currentRoundId = voteTiming.computeCurrentRoundId(getCurrentTime());
        PriceRequest storage priceRequest = priceRequests[priceRequestIds[requestIndex]];

        if (_getRequestStatus(priceRequest, currentRoundId) != RequestStatus.Resolved)
            return SlashingTracker(0, 0, 0, 0);

        VoteInstance storage voteInstance = priceRequest.voteInstances[priceRequest.lastVotingRound];

        uint256 totalVotes = voteInstance.resultComputation.totalVotes;
        uint256 totalCorrectVotes = voteInstance.resultComputation.getTotalCorrectlyVotedTokens();
        uint256 stakedAtRound = rounds[priceRequest.lastVotingRound].cumulativeActiveStakeAtRound;

        (uint256 wrongVoteSlash, uint256 noVoteSlash) =
            slashingLibrary.calcSlashing(stakedAtRound, totalVotes, totalCorrectVotes, priceRequest.isGovernance);

        uint256 totalSlashed =
            ((noVoteSlash * (stakedAtRound - totalVotes)) / 1e18) +
                ((wrongVoteSlash * (totalVotes - totalCorrectVotes)) / 1e18);

        return SlashingTracker(wrongVoteSlash, noVoteSlash, totalSlashed, totalCorrectVotes);
    }

    /****************************************
     *        OWNER ADMIN FUNCTIONS         *
     ****************************************/

    /**
     * @notice Disables this Voting contract in favor of the migrated one.
     * @dev Can only be called by the contract owner.
     * @param newVotingAddress the newly migrated contract address.
     */
    function setMigrated(address newVotingAddress) external override onlyOwner {
        migratedAddress = newVotingAddress;
    }

    /**
     * @notice Resets the Gat percentage. Note: this change only applies to rounds that have not yet begun.
     * @dev This method is public because calldata structs are not currently supported by solidity.
     * @param newGatPercentage sets the next round's Gat percentage.
     */
    function setGatPercentage(uint256 newGatPercentage) public override onlyOwner {
        require(newGatPercentage < 1e18, "GAT percentage must be < 100%");
        gatPercentage = newGatPercentage;
    }

    // Here for abi compatibility. to be removed.
    function setRewardsExpirationTimeout(uint256 NewRewardsExpirationTimeout) public override onlyOwner {}

    /**
     * @notice Changes the slashing library used by this contract.
     * @param _newSlashingLibrary new slashing library address.
     */
    function setSlashingLibrary(address _newSlashingLibrary) public override onlyOwner {
        slashingLibrary = SlashingLibrary(_newSlashingLibrary);
    }

    /****************************************
     *    PRIVATE AND INTERNAL FUNCTIONS    *
     ****************************************/

    // Returns the price for a given identifer. Three params are returns: bool if there was an error, int to represent
    // the resolved price and a string which is filled with an error message, if there was an error or "".
    function _getPriceOrError(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData
    )
        internal
        view
        returns (
            bool,
            int256,
            string memory
        )
    {
        PriceRequest storage priceRequest = _getPriceRequest(identifier, time, ancillaryData);
        uint256 currentRoundId = voteTiming.computeCurrentRoundId(getCurrentTime());

        RequestStatus requestStatus = _getRequestStatus(priceRequest, currentRoundId);
        if (requestStatus == RequestStatus.Active) {
            return (false, 0, "Current voting round not ended");
        } else if (requestStatus == RequestStatus.Resolved) {
            VoteInstance storage voteInstance = priceRequest.voteInstances[priceRequest.lastVotingRound];
            (, int256 resolvedPrice) =
                voteInstance.resultComputation.getResolvedPrice(_computeGat(priceRequest.lastVotingRound));
            return (true, resolvedPrice, "");
        } else if (requestStatus == RequestStatus.Future) {
            return (false, 0, "Price is still to be voted on");
        } else {
            return (false, 0, "Price was never requested");
        }
    }

    function _getPriceRequest(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData
    ) private view returns (PriceRequest storage) {
        return priceRequests[_encodePriceRequest(identifier, time, ancillaryData)];
    }

    function _encodePriceRequest(
        bytes32 identifier,
        uint256 time,
        bytes memory ancillaryData
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(identifier, time, ancillaryData));
    }

    function _freezeRoundVariables(uint256 roundId) private {
        // Only freeze the round if this is the first request in the round.
        if (rounds[roundId].gatPercentage == 0) {
            // Set the round gat percentage to the current global gat rate.
            rounds[roundId].gatPercentage = gatPercentage;

            // Store the cumulativeActiveStake at this roundId to work out slashing and voting trackers.
            rounds[roundId].cumulativeActiveStakeAtRound = cumulativeActiveStake;
        }
    }

    function _resolvePriceRequest(
        PriceRequest storage priceRequest,
        VoteInstance storage voteInstance,
        uint256 currentRoundId
    ) private returns (bool) {
        // We are currently either in the voting round for the request or voting is yet to begin.
        if (currentRoundId <= priceRequest.lastVotingRound) return false;

        // If the request has been previously resolved, return true.
        if (priceRequest.pendingRequestIndex == UINT_MAX) return true;

        // Else, check if the price can be resolved.
        (bool isResolvable, int256 resolvedPrice) =
            voteInstance.resultComputation.getResolvedPrice(_computeGat(priceRequest.lastVotingRound));

        // If it's not resolvable return false.
        if (!isResolvable) return false;

        // Else, the request is resolvable. Remove the element from the pending request and update pendingRequestIndex
        // within the price request struct to make the next entry into this method a no-op for this request.
        uint256 lastIndex = pendingPriceRequests.length - 1;
        PriceRequest storage lastPriceRequest = priceRequests[pendingPriceRequests[lastIndex]];
        lastPriceRequest.pendingRequestIndex = priceRequest.pendingRequestIndex;
        pendingPriceRequests[priceRequest.pendingRequestIndex] = pendingPriceRequests[lastIndex];
        pendingPriceRequests.pop();

        priceRequest.pendingRequestIndex = UINT_MAX;
        emit PriceResolved(
            priceRequest.lastVotingRound,
            priceRequest.identifier,
            priceRequest.time,
            resolvedPrice,
            priceRequest.ancillaryData
        );
        return true;
    }

    function _computeGat(uint256 roundId) internal view returns (uint256) {
        // Nothing staked at the round  - return max value to err on the side of caution.
        if (rounds[roundId].cumulativeActiveStakeAtRound == 0) return type(uint256).max;

        // Grab the cumulative staked at the voting round.
        uint256 stakedAtRound = rounds[roundId].cumulativeActiveStakeAtRound;

        // Multiply the total supply at the cumulative staked by the gatPercentage to get the GAT in number of tokens.
        return (stakedAtRound * rounds[roundId].gatPercentage) / 1e18;
    }

    function _getRequestStatus(PriceRequest storage priceRequest, uint256 currentRoundId)
        private
        view
        returns (RequestStatus)
    {
        if (priceRequest.lastVotingRound == 0) return RequestStatus.NotRequested;
        else if (priceRequest.lastVotingRound < currentRoundId) {
            VoteInstance storage voteInstance = priceRequest.voteInstances[priceRequest.lastVotingRound];
            (bool isResolved, ) =
                voteInstance.resultComputation.getResolvedPrice(_computeGat(priceRequest.lastVotingRound));

            return isResolved ? RequestStatus.Resolved : RequestStatus.Active;
        } else if (priceRequest.lastVotingRound == currentRoundId) return RequestStatus.Active;
        // Means than priceRequest.lastVotingRound > currentRoundId
        else return RequestStatus.Future;
    }

    function unsafe_inc(uint256 x) internal pure returns (uint256) {
        unchecked { return x + 1; }
    }

    function _getIdentifierWhitelist() private view returns (IdentifierWhitelistInterface supportedIdentifiers) {
        return IdentifierWhitelistInterface(finder.getImplementationAddress(OracleInterfaces.IdentifierWhitelist));
    }
}