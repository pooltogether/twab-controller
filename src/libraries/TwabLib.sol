// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.17;

import "forge-std/console.sol";

import "./ExtendedSafeCastLib.sol";
import "./OverflowSafeComparatorLib.sol";
import "./RingBufferLib.sol";
import "./ObservationLib.sol";

/**
 * @notice Struct ring buffer parameters for single user Account
 * @param balance       Current balance for an Account
 * @param nextTwabIndex Next uninitialized or updatable ring buffer checkpoint storage slot
 * @param cardinality   Current total "initialized" ring buffer checkpoints for single user AccountDetails.
 *                          Used to set initial boundary conditions for an efficient binary search.
 */
struct AccountDetails {
  uint112 balance;
  uint112 delegateBalance;
  uint16 nextTwabIndex;
  uint16 cardinality;
}

/// @notice Combines account details with their twab history
/// @param details The account details
/// @param twabs The history of twabs for this account
struct Account {
  AccountDetails details;
  ObservationLib.Observation[365] twabs;
}

/**
 * @title  PoolTogether V4 TwabLib (Library)
 * @author PoolTogether Inc Team
 * @dev    Time-Weighted Average Balance Library for ERC20 tokens.
 * @notice This TwabLib adds on-chain historical lookups to a user(s) time-weighted average balance.
 *             Each user is mapped to an Account struct containing the TWAB history (ring buffer) and
 *             ring buffer parameters. Every token.transfer() creates a new TWAB checkpoint. The new TWAB
 *             checkpoint is stored in the circular ring buffer, as either a new checkpoint or rewriting
 *             a previous checkpoint with new parameters. The TwabLib (using existing blocktimes of 1block/15sec)
 *             guarantees minimum 7.4 years of search history.
 */
library TwabLib {
  using OverflowSafeComparatorLib for uint32;
  using ExtendedSafeCastLib for uint256;

  /**
   * @notice Sets max ring buffer length in the Account.twabs Observation list.
   *             As users transfer/mint/burn tickets new Observation checkpoints are
   *             recorded. The current max cardinality guarantees a seven year minimum,
   *             of accurate historical lookups with current estimates of 1 new block
   *             every 15 seconds - assuming each block contains a transfer to trigger an
   *             observation write to storage.
   * @dev    The user Account.AccountDetails.cardinality parameter can NOT exceed
   *             the max cardinality variable. Preventing "corrupted" ring buffer lookup
   *             pointers and new observation checkpoints.
   *
   *             The MAX_CARDINALITY in fact guarantees at least 1 year of records:

   *             The SPONSORSHIP_ADDRESS delegates to a dead address.
   */
  uint16 public constant MAX_CARDINALITY = 365; // 1 year
  address public constant SPONSORSHIP_ADDRESS = address(1); // Dead address

  function increaseBalance(
    Account storage _account,
    uint112 _amount
  ) internal view returns (AccountDetails memory accountDetails) {
    AccountDetails memory _accountDetails = _account.details;
    _accountDetails.balance = _accountDetails.balance + _amount;
    accountDetails = _accountDetails;
  }

  function decreaseBalance(
    Account storage _account,
    uint112 _amount,
    string memory _revertMessage
  ) internal view returns (AccountDetails memory accountDetails) {
    AccountDetails memory _accountDetails = _account.details;
    require(_accountDetails.balance >= _amount, _revertMessage);
    unchecked {
      _accountDetails.balance -= _amount;
    }
    accountDetails = _accountDetails;
  }

  /// @notice Increases an account's delegateBalance and records a new twab.
  /// @param _account The account whose delegateBalance will be increased
  /// @param _amount The amount to increase the delegateBalance by
  /// @param _currentTime The current time
  /// @return accountDetails The new AccountDetails
  /// @return twab The user's latest TWAB
  /// @return isNew Whether the TWAB is new
  function increaseDelegateBalance(
    Account storage _account,
    uint112 _amount,
    uint32 _currentTime
  )
    internal
    returns (
      AccountDetails memory accountDetails,
      ObservationLib.Observation memory twab,
      bool isNew
    )
  {
    AccountDetails memory _accountDetails = _account.details;
    (accountDetails, twab, isNew) = _nextTwab(_account.twabs, _accountDetails, _currentTime);
    accountDetails.delegateBalance = _accountDetails.delegateBalance + _amount;
  }

  /**
   * @notice Calculates the next TWAB checkpoint for an account with a decreasing delegateBalance.
   * @dev    With Account struct and amount decreasing calculates the next TWAB observable checkpoint.
   * @param _account        Account whose delegateBalance will be decreased
   * @param _amount         Amount to decrease the delegateBalance by
   * @param _revertMessage  Revert message for insufficient delegateBalance
   * @return accountDetails Updated Account.details struct
   * @return twab           TWAB observation (with decreasing average)
   * @return isNew          Whether TWAB is new or calling twice in the same block
   */
  function decreaseDelegateBalance(
    Account storage _account,
    uint112 _amount,
    string memory _revertMessage,
    uint32 _currentTime
  )
    internal
    returns (
      AccountDetails memory accountDetails,
      ObservationLib.Observation memory twab,
      bool isNew
    )
  {
    AccountDetails memory _accountDetails = _account.details;

    require(_accountDetails.delegateBalance >= _amount, _revertMessage);

    (accountDetails, twab, isNew) = _nextTwab(_account.twabs, _accountDetails, _currentTime);
    unchecked {
      accountDetails.delegateBalance -= _amount;
    }
  }

  /**
   * @notice Calculates the average balance held by a user for a given time frame.
   * @dev    Finds the average balance between start and end timestamp epochs.
   *             Validates the supplied end time is within the range of elapsed time i.e. less then timestamp of now.
   * @param _twabs          Individual user Observation recorded checkpoints passed as storage pointer
   * @param _accountDetails User AccountDetails struct loaded in memory
   * @param _startTime      Start of timestamp range as an epoch
   * @param _endTime        End of timestamp range as an epoch
   * @param _currentTime    Block.timestamp
   * @return Average balance of user held between epoch timestamps start and end
   */
  function getAverageDelegateBalanceBetween(
    ObservationLib.Observation[MAX_CARDINALITY] storage _twabs,
    AccountDetails memory _accountDetails,
    uint32 _startTime,
    uint32 _endTime,
    uint32 _currentTime
  ) internal view returns (uint256) {
    uint32 endTime = _endTime > _currentTime ? _currentTime : _endTime;

    return
      _getAverageDelegateBalanceBetween(_twabs, _accountDetails, _startTime, endTime, _currentTime);
  }

  /// @notice Retrieves the oldest TWAB
  /// @param _twabs The storage array of twabs
  /// @param _accountDetails The TWAB account details
  /// @return index The index of the oldest TWAB in the twabs array
  /// @return twab The oldest TWAB
  function oldestTwab(
    ObservationLib.Observation[MAX_CARDINALITY] storage _twabs,
    AccountDetails memory _accountDetails
  ) internal view returns (uint16 index, ObservationLib.Observation memory twab) {
    index = _accountDetails.nextTwabIndex;
    twab = _twabs[index];

    // If the TWAB is not initialized we go to the beginning of the TWAB circular buffer at index 0
    if (twab.timestamp == 0) {
      index = 0;
      twab = _twabs[0];
    }
  }

  /// @notice Retrieves the newest TWAB
  /// @param _twabs The storage array of twabs
  /// @param _accountDetails The TWAB account details
  /// @return index The index of the newest TWAB in the twabs array
  /// @return twab The newest TWAB
  function newestTwab(
    ObservationLib.Observation[MAX_CARDINALITY] storage _twabs,
    AccountDetails memory _accountDetails
  ) internal view returns (uint16 index, ObservationLib.Observation memory twab) {
    index = uint16(RingBufferLib.newestIndex(_accountDetails.nextTwabIndex, MAX_CARDINALITY));
    twab = _twabs[index];
  }

  /// @notice Retrieves amount at `_targetTime` timestamp
  /// @param _twabs List of TWABs to search through.
  /// @param _accountDetails Accounts details
  /// @param _targetTime Timestamp at which the reserved TWAB should be for.
  /// @return uint256 TWAB amount at `_targetTime`.
  function getDelegateBalanceAt(
    ObservationLib.Observation[MAX_CARDINALITY] storage _twabs,
    AccountDetails memory _accountDetails,
    uint32 _targetTime,
    uint32 _currentTime
  ) internal returns (uint256) {
    uint32 timeToTarget = _targetTime > _currentTime ? _currentTime : _targetTime;
    return _getDelegateBalanceAt(_twabs, _accountDetails, timeToTarget, _currentTime);
  }

  /// @notice Calculates the average balance held by a user for a given time frame.
  /// @param _startTime The start time of the time frame.
  /// @param _endTime The end time of the time frame.
  /// @return The average balance that the user held during the time frame.
  function _getAverageDelegateBalanceBetween(
    ObservationLib.Observation[MAX_CARDINALITY] storage _twabs,
    AccountDetails memory _accountDetails,
    uint32 _startTime,
    uint32 _endTime,
    uint32 _currentTime
  ) private view returns (uint256) {
    (uint16 oldestTwabIndex, ObservationLib.Observation memory oldTwab) = oldestTwab(
      _twabs,
      _accountDetails
    );

    (uint16 newestTwabIndex, ObservationLib.Observation memory newTwab) = newestTwab(
      _twabs,
      _accountDetails
    );

    ObservationLib.Observation memory startTwab = _calculateTwab(
      _twabs,
      _accountDetails,
      newTwab,
      oldTwab,
      newestTwabIndex,
      oldestTwabIndex,
      _startTime,
      _currentTime
    );

    ObservationLib.Observation memory endTwab = _calculateTwab(
      _twabs,
      _accountDetails,
      newTwab,
      oldTwab,
      newestTwabIndex,
      oldestTwabIndex,
      _endTime,
      _currentTime
    );

    // Difference in amount / time
    return
      (endTwab.amount - startTwab.amount) /
      OverflowSafeComparatorLib.checkedSub(endTwab.timestamp, startTwab.timestamp, _currentTime);
  }

  /**
   * @notice Searches TWAB history and calculate the difference between amount(s)/timestamp(s) to return average balance
   *             between the Observations closes to the supplied targetTime.
   * @param _twabs          Individual user Observation recorded checkpoints passed as storage pointer
   * @param _accountDetails User AccountDetails struct loaded in memory
   * @param _targetTime     Target timestamp to filter Observations in the ring buffer binary search
   * @param _currentTime    Block.timestamp
   * @return uint256 Time-weighted average amount between two closest observations.
   */
  function _getDelegateBalanceAt(
    ObservationLib.Observation[MAX_CARDINALITY] storage _twabs,
    AccountDetails memory _accountDetails,
    uint32 _targetTime,
    uint32 _currentTime
  ) private returns (uint256) {
    uint16 newestTwabIndex;
    ObservationLib.Observation memory afterOrAt;
    ObservationLib.Observation memory beforeOrAt;
    (newestTwabIndex, beforeOrAt) = newestTwab(_twabs, _accountDetails);

    // If `_targetTime` is chronologically after the newest TWAB, we can simply return the current balance
    if (beforeOrAt.timestamp.lte(_targetTime, _currentTime)) {
      return _accountDetails.delegateBalance;
    }

    uint16 oldestTwabIndex;
    // Now, set before to the oldest TWAB
    (oldestTwabIndex, beforeOrAt) = oldestTwab(_twabs, _accountDetails);

    // If `_targetTime` is chronologically before the oldest TWAB, we can early return
    if (_targetTime.lt(beforeOrAt.timestamp, _currentTime)) {
      return 0;
    }

    // Otherwise, we perform the `binarySearch`
    (beforeOrAt, afterOrAt) = ObservationLib.binarySearch(
      _twabs,
      newestTwabIndex,
      oldestTwabIndex,
      _targetTime,
      _accountDetails.cardinality,
      _currentTime
    );

    // Sum the difference in amounts and divide by the difference in timestamps.
    // The time-weighted average balance uses time measured between two epoch timestamps as
    // a constaint on the measurement when calculating the time weighted average balance.
    return
      (afterOrAt.amount - beforeOrAt.amount) /
      OverflowSafeComparatorLib.checkedSub(afterOrAt.timestamp, beforeOrAt.timestamp, _currentTime);
  }

  /**
   * @notice Calculates a user TWAB for a target timestamp using the historical TWAB records.
   *             The balance is linearly interpolated: amount differences / timestamp differences
   *             using the simple (after.amount - before.amount / end.timestamp - start.timestamp) formula.
   * /** @dev    Binary search in _calculateTwab fails when searching out of bounds. Thus, before
   *             searching we exclude target timestamps out of range of newest/oldest TWAB(s).
   *             IF a search is before or after the range we "extrapolate" a Observation from the expected state.
   * @param _twabs           Individual user Observation recorded checkpoints passed as storage pointer
   * @param _accountDetails  User AccountDetails struct loaded in memory
   * @param _newestTwab      Newest TWAB in history (end of ring buffer)
   * @param _oldestTwab      Olderst TWAB in history (end of ring buffer)
   * @param _newestTwabIndex Pointer in ring buffer to newest TWAB
   * @param _oldestTwabIndex Pointer in ring buffer to oldest TWAB
   * @param _targetTimestamp Epoch timestamp to calculate for time (T) in the TWAB
   * @param _time            Block.timestamp
   * @return accountDetails Updated Account.details struct
   */
  function _calculateTwab(
    ObservationLib.Observation[MAX_CARDINALITY] storage _twabs,
    AccountDetails memory _accountDetails,
    ObservationLib.Observation memory _newestTwab,
    ObservationLib.Observation memory _oldestTwab,
    uint16 _newestTwabIndex,
    uint16 _oldestTwabIndex,
    uint32 _targetTimestamp,
    uint32 _time
  ) private view returns (ObservationLib.Observation memory) {
    // If `_targetTimestamp` is chronologically after the newest TWAB, we extrapolate a new one
    if (_newestTwab.timestamp.lt(_targetTimestamp, _time)) {
      return _computeNextTwab(_newestTwab, _accountDetails.delegateBalance, _targetTimestamp);
    }

    if (_newestTwab.timestamp == _targetTimestamp) {
      return _newestTwab;
    }

    if (_oldestTwab.timestamp == _targetTimestamp) {
      return _oldestTwab;
    }

    // If `_targetTimestamp` is chronologically before the oldest TWAB, we create a zero twab
    if (_targetTimestamp.lt(_oldestTwab.timestamp, _time)) {
      return ObservationLib.Observation({ amount: 0, timestamp: _targetTimestamp });
    }

    // Otherwise, both timestamps must be surrounded by twabs.
    (
      ObservationLib.Observation memory beforeOrAtStart,
      ObservationLib.Observation memory afterOrAtStart
    ) = ObservationLib.binarySearch(
        _twabs,
        _newestTwabIndex,
        _oldestTwabIndex,
        _targetTimestamp,
        _accountDetails.cardinality,
        _time
      );

    // NOTE: Is this a safe cast?
    uint112 heldBalance = uint112(
      (afterOrAtStart.amount - beforeOrAtStart.amount) /
        OverflowSafeComparatorLib.checkedSub(
          afterOrAtStart.timestamp,
          beforeOrAtStart.timestamp,
          _time
        )
    );

    return _computeNextTwab(beforeOrAtStart, heldBalance, _targetTimestamp);
  }

  /**
   * @notice Calculates the next TWAB using the newestTwab and updated balance.
   * @dev    Storage of the TWAB obersation is managed by the calling function and not _computeNextTwab.
   * @param _currentTwab    Newest Observation in the Account.twabs list
   * @param _currentBalance User balance at time of most recent (newest) checkpoint write
   * @param _time           Current block.timestamp
   * @return TWAB Observation
   */
  function _computeNextTwab(
    ObservationLib.Observation memory _currentTwab,
    uint112 _currentBalance,
    uint32 _time
  ) private pure returns (ObservationLib.Observation memory) {
    // TODO: HERE WE NEED TO HANDLE WHERE WE"RE OVERWRITING RATHER THAN ADDING A NEW.
    // New twab amount = last twab amount (or zero) + (current amount * elapsed seconds)
    return
      ObservationLib.Observation({
        amount: _currentTwab.amount +
          _currentBalance *
          (_time.checkedSub(_currentTwab.timestamp, _time)),
        timestamp: _time
      });
  }

  /// @notice Sets a new TWAB Observation at the next available index and returns the new account details.
  /// @dev Note that if _currentTime is before the last observation timestamp, it appears as an overflow
  /// @param _twabs The twabs array to insert into
  /// @param _accountDetails The current account details
  /// @param _currentTime The current time
  /// @return accountDetails The new account details
  /// @return twab The newest twab (may or may not be brand-new)
  /// @return isNew Whether the newest twab was created by this call
  function _nextTwab(
    ObservationLib.Observation[MAX_CARDINALITY] storage _twabs,
    AccountDetails memory _accountDetails,
    uint32 _currentTime
  )
    private
    returns (
      AccountDetails memory accountDetails,
      ObservationLib.Observation memory twab,
      bool isNew
    )
  {
    (, ObservationLib.Observation memory _newestTwab) = newestTwab(_twabs, _accountDetails);

    // if we're in the same block, return
    if (_newestTwab.timestamp == _currentTime) {
      return (_accountDetails, _newestTwab, false);
    }

    ObservationLib.Observation memory newTwab = _computeNextTwab(
      _newestTwab,
      _accountDetails.delegateBalance,
      _currentTime
    );

    // TODO: HERE WE NEED TO OVERWRITE OR NAH
    _twabs[_accountDetails.nextTwabIndex] = newTwab;

    AccountDetails memory nextAccountDetails = push(_accountDetails);

    return (nextAccountDetails, newTwab, true);
  }

  /// @notice "Pushes" a new element on the AccountDetails ring buffer, and returns the new AccountDetails
  /// @param _accountDetails The account details from which to pull the   cardinality and next index
  /// @return The new AccountDetails
  function push(
    AccountDetails memory _accountDetails
  ) internal pure returns (AccountDetails memory) {
    _accountDetails.nextTwabIndex = uint16(
      RingBufferLib.nextIndex(_accountDetails.nextTwabIndex, MAX_CARDINALITY)
    );

    // Prevent the Account specific cardinality from exceeding the MAX_CARDINALITY.
    // The ring buffer length is limited by MAX_CARDINALITY. IF the account.cardinality
    // exceeds the max cardinality, new observations would be incorrectly set or the
    // observation would be out of "bounds" of the ring buffer. Once reached the
    // AccountDetails.cardinality will continue to be equal to max cardinality.
    if (_accountDetails.cardinality < MAX_CARDINALITY) {
      _accountDetails.cardinality += 1;
    }

    return _accountDetails;
  }
}