// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

import "../interfaces/IPool.sol";
import "../interfaces/ICorePool.sol";
import "./ReentrancyGuard.sol";
import "./SyndicatePoolFactory.sol";
import "../utils/SafeERC20.sol";
import "../token/SyntheticSyndicateERC20.sol";
import "../interfaces/IMigrator.sol";

/**
 * @title Syndicate Pool Base
 *        Original title: Illuvium Pool Base
 *
 * @notice An abstract contract containing common logic for any pool,
 *      be it a flash pool (temporary pool like SNX) or a core pool (permanent pool like SYNR/ETH or SYNR pool)
 *
 * @dev Deployment and initialization.
 *      Any pool deployed must be bound to the deployed pool factory (SyndicatePoolFactory)
 *      Additionally, 3 token instance addresses must be defined on deployment:
 *          - SYNR token address
 *          - sSYNR token address, used to mint sSYNR rewards
 *          - pool token address, it can be SYNR token address, SYNR/ETH pair address, and others
 *
 * @dev Pool weight defines the fraction of the yield current pool receives among the other pools,
 *      pool factory is responsible for the weight synchronization between the pools.
 * @dev The weight is logically 10% for SYNR pool and 90% for SYNR/ETH pool.
 *      Since Solidity doesn't support fractions the weight is defined by the division of
 *      pool weight by total pools weight (sum of all registered pools within the factory)
 *
 * @author Pedro Bergamini, reviewed by Basil Gorin
 * Adapted for Syn City by Superpower Labs
 */
abstract contract SyndicatePoolBase is IPool, SyndicateAware, ReentrancyGuard {
  uint256 public minLockTime = 16 weeks;

  IMigrator public migrator;

  /// @dev Token holder storage, maps token holder address to their data record
  mapping(address => User) public users;

  /// @dev Link to sSYNR ERC20 Token  SyntheticSyndicateERC20 instance
  address public immutable override ssynr;

  /// @dev Link to the pool factory SyndicatePoolFactory instance
  SyndicatePoolFactory public immutable factory;

  /// @dev Link to the pool token instance, for example SYNR or SYNR/ETH pair
  address public immutable override poolToken;

  /// @dev Pool weight, 100 for SYNR pool or 900 for SYNR/ETH
  uint32 public override weight;

  /// @dev Block number of the last yield distribution event
  uint64 public override lastYieldDistribution;

  /// @dev Used to calculate yield rewards
  /// @dev This value is different from "reward per token" used in locked pool
  /// @dev Note: stakes are different in duration and "weight" reflects that
  uint256 public override yieldRewardsPerWeight;

  /// @dev Used to calculate yield rewards, keeps track of the tokens weight locked in staking
  uint256 public override usersLockingWeight;

  uint256 public totalYieldReward;

  /**
   * @dev Stake weight is proportional to deposit amount and time locked, precisely
   *      "deposit amount wei multiplied by (fraction of the year locked plus one)"
   * @dev To avoid significant precision loss due to multiplication by "fraction of the year" [0, 1],
   *      weight is stored multiplied by 1e6 constant, as an integer
   * @dev Corner case 1: if time locked is zero, weight is deposit amount multiplied by 1e6
   * @dev Corner case 2: if time locked is one year, fraction of the year locked is one, and
   *      weight is a deposit amount multiplied by 2 * 1e6
   */
  // solhint-disable-next-line
  uint256 internal constant WEIGHT_MULTIPLIER = 1e6;

  /**
   * @dev When we know beforehand that staking is done for a year, and fraction of the year locked is one,
   *      we use simplified calculation and use the following constant instead previos one
   */
  // solhint-disable-next-line
  uint256 internal constant YEAR_STAKE_WEIGHT_MULTIPLIER = 2 * WEIGHT_MULTIPLIER;

  /**
   * @dev Rewards per weight are stored multiplied by 1e20, as integers.
   */
  // solhint-disable-next-line
  uint256 internal constant REWARD_PER_WEIGHT_MULTIPLIER = 1e20;

  /**
   * @dev Fired in _stake() and stake()
   *
   * @param _by an address which performed an operation, usually token holder
   * @param _from token holder address, the tokens will be returned to that address
   * @param amount amount of tokens staked
   */
  event Staked(address indexed _by, address indexed _from, uint256 amount);

  /**
   * @dev Fired in _updateStakeLock() and updateStakeLock()
   *
   * @param _by an address which performed an operation
   * @param depositId updated deposit ID
   * @param lockedFrom deposit locked from value
   * @param lockedUntil updated deposit locked until value
   */
  event StakeLockUpdated(address indexed _by, uint256 depositId, uint64 lockedFrom, uint64 lockedUntil);

  /**
   * @dev Fired in _unstake() and unstake()
   *
   * @param _by an address which performed an operation, usually token holder
   * @param _to an address which received the unstaked tokens, usually token holder
   * @param amount amount of tokens unstaked
   */
  event Unstaked(address indexed _by, address indexed _to, uint256 amount);

  /**
   * @dev Fired in _sync(), sync() and dependent functions (stake, unstake, etc.)
   *
   * @param _by an address which performed an operation
   * @param yieldRewardsPerWeight updated yield rewards per weight value
   * @param lastYieldDistribution usually, current block number
   */
  event Synchronized(address indexed _by, uint256 yieldRewardsPerWeight, uint64 lastYieldDistribution);

  /**
   * @dev Fired in _processRewards(), processRewards() and dependent functions (stake, unstake, etc.)
   *
   * @param _by an address which performed an operation
   * @param _to an address which claimed the yield reward
   * @param sSyn flag indicating if reward was paid (minted) in sSYNR
   * @param amount amount of yield paid
   */
  event YieldClaimed(address indexed _by, address indexed _to, bool sSyn, uint256 amount);

  /**
   * @dev Fired in setWeight()
   *
   * @param _by an address which performed an operation, always a factory
   * @param _fromVal old pool weight value
   * @param _toVal new pool weight value
   */
  event PoolWeightUpdated(address indexed _by, uint32 _fromVal, uint32 _toVal);

  modifier onlyFactoryOwner() {
    // verify function is executed by the factory owner
    require(factory.owner() == msg.sender, "access denied");
    _;
  }

  modifier poolAlive() {
    require(weight > 0, "pool disabled");
    _;
  }

  /**
   * @dev Overridden in sub-contracts to construct the pool
   *
   * @param _synr SYNR ERC20 Token SyndicateERC20 address
   * @param _ssynr sSYNR ERC20 Token  SyntheticSyndicateERC20 address
   * @param _factory Pool factory SyndicatePoolFactory instance/address
   * @param _poolToken token the pool operates on, for example SYNR or SYNR/ETH pair
   * @param _initBlock initial block used to calculate the rewards
   *      note: _initBlock can be set to the future effectively meaning _sync() calls will do nothing
   * @param _weight number representing a weight of the pool, actual weight fraction
   *      is calculated as that number divided by the total pools weight and doesn't exceed one
   */
  constructor(
    address _synr,
    address _ssynr,
    SyndicatePoolFactory _factory,
    address _poolToken,
    uint64 _initBlock,
    uint32 _weight
  ) SyndicateAware(_synr) {
    // verify the inputs are set
    require(_ssynr != address(0), "sSYNR address not set");
    require(address(_factory) != address(0), "SYNR Pool fct address not set");
    require(_poolToken != address(0), "pool token address not set");
    require(_initBlock > 0, "init block not set");
    require(_weight > 0, "pool weight not set");

    // verify sSYNR instance supplied
    require(
      SyntheticSyndicateERC20(_ssynr).TOKEN_UID() == 0xac3051b8d4f50966afb632468a4f61483ae6a953b74e387a01ef94316d6b7d62,
      "unexpected sSYNR TOKEN_UID"
    );
    // verify SyndicatePoolFactory instance supplied
    require(
      _factory.FACTORY_UID() == 0xc5cfd88c6e4d7e5c8a03c0f0f03af23c0918d8e82cac196f57466af3fd4a5ec7,
      "unexpected FACTORY_UID"
    );

    // save the inputs into internal state variables
    ssynr = _ssynr;
    factory = _factory;
    poolToken = _poolToken;
    weight = _weight;

    // init the dependent internal state variables
    lastYieldDistribution = _initBlock;
  }

  function setMigrator(IMigrator _migrator) external onlyFactoryOwner {
    require(address(_migrator) != address(0), "migrator cannot be 0x0");
    migrator = _migrator;
  }

  function migrate() external {
    require(weight == 0, "disable pool first");
    require(address(migrator) != address(0), "migrator not set");
    User storage user = users[msg.sender];
    require(user.tokenAmount != 0, "no tokens to migrate");
    migrator.receiveDeposits(msg.sender, user);
    uint256 tokenToMigrate;
    for (uint256 i = user.deposits.length; i > 0; i--) {
      if (!user.deposits[i - 1].isYield) {
        tokenToMigrate += user.deposits[i - 1].tokenAmount;
      }
      user.deposits.pop();
    }
    SyndicateERC20(synr).transfer(address(migrator), tokenToMigrate);
    delete users[msg.sender];
  }

  /**
   * @notice Calculates current yield rewards value available for address specified
   *
   * @param _staker an address to calculate yield rewards value for
   * @return calculated yield reward value for the given address
   */
  function pendingYieldRewards(address _staker) external view override returns (uint256) {
    // `newYieldRewardsPerWeight` will store stored or recalculated value for `yieldRewardsPerWeight`
    uint256 newYieldRewardsPerWeight;

    // if smart contract state was not updated recently, `yieldRewardsPerWeight` value
    // is outdated and we need to recalculate it in order to calculate pending rewards correctly
    if (blockNumber() > lastYieldDistribution && usersLockingWeight != 0) {
      uint256 endBlock = factory.endBlock();
      uint256 multiplier = blockNumber() > endBlock ? endBlock - lastYieldDistribution : blockNumber() - lastYieldDistribution;
      uint256 synRewards = (multiplier * weight * factory.synrPerBlock()) / factory.totalWeight();

      // recalculated value for `yieldRewardsPerWeight`
      newYieldRewardsPerWeight = rewardToWeight(synRewards, usersLockingWeight) + yieldRewardsPerWeight;
    } else {
      // if smart contract state is up to date, we don't recalculate
      newYieldRewardsPerWeight = yieldRewardsPerWeight;
    }

    // based on the rewards per weight value, calculate pending rewards;
    User storage user = users[_staker];
    uint256 pending = weightToReward(user.totalWeight, newYieldRewardsPerWeight) - user.subYieldRewards;
    return pending;
  }

  /**
   * @notice Returns total staked token balance for the given address
   *
   * @param _user an address to query balance for
   * @return total staked token balance
   */
  function balanceOf(address _user) external view override returns (uint256) {
    // read specified user token amount and return
    return users[_user].tokenAmount;
  }

  /**
   * @notice Returns information on the given deposit for the given address
   *
   * @dev See getDepositsLength
   *
   * @param _user an address to query deposit for
   * @param _depositId zero-indexed deposit ID for the address specified
   * @return deposit info as Deposit structure
   */
  function getDeposit(address _user, uint256 _depositId) external view override returns (Deposit memory) {
    // read deposit at specified index and return
    return users[_user].deposits[_depositId];
  }

  /**
   * @notice Returns number of deposits for the given address. Allows iteration over deposits.
   *
   * @dev See getDeposit
   *
   * @param _user an address to query deposit length for
   * @return number of deposits for the given address
   */
  function getDepositsLength(address _user) external view override returns (uint256) {
    // read deposits array length and return
    return users[_user].deposits.length;
  }

  /**
   * @notice Stakes specified amount of tokens for the specified amount of time,
   *      and pays pending yield rewards if any
   *
   * @dev Requires amount to stake to be greater than zero
   *
   * @param _amount amount of tokens to stake
   * @param _lockUntil stake period as unix timestamp; zero means no locking
   * @param _useSSYN a flag indicating if previous reward to be paid as sSYNR
   */
  function stake(
    uint256 _amount,
    uint64 _lockUntil,
    bool _useSSYN
  ) external override {
    // delegate call to an internal function
    _stake(msg.sender, _amount, _lockUntil, _useSSYN, false);
  }

  /**
   * @notice Unstakes specified amount of tokens, and pays pending yield rewards if any
   *
   * @dev Requires amount to unstake to be greater than zero
   *
   * @param _depositId deposit ID to unstake from, zero-indexed
   * @param _amount amount of tokens to unstake
   * @param _useSSYN a flag indicating if reward to be paid as sSYNR
   */
  function unstake(
    uint256 _depositId,
    uint256 _amount,
    bool _useSSYN
  ) external override {
    // delegate call to an internal function
    _unstake(msg.sender, _depositId, _amount, _useSSYN);
  }

  /**
   * @notice Extends locking period for a given deposit
   *
   * @dev Requires new lockedUntil value to be:
   *      higher than the current one, and
   *      in the future, but
   *      no more than 1 year in the future
   *
   * @param depositId updated deposit ID
   * @param lockedUntil updated deposit locked until value
   * @param useSSYN used for _processRewards check if it should use SYNR or sSYNR
   */
  function updateStakeLock(
    uint256 depositId,
    uint64 lockedUntil,
    bool useSSYN
  ) external {
    // delegate call to an internal function
    _updateStakeLock(msg.sender, depositId, lockedUntil, useSSYN);
  }

  /**
   * @notice Service function to synchronize pool state with current time
   *
   * @dev Can be executed by anyone at any time, but has an effect only when
   *      at least one block passes between synchronizations
   * @dev Executed internally when staking, unstaking, processing rewards in order
   *      for calculations to be correct and to reflect state progress of the contract
   * @dev When timing conditions are not met (executed too frequently, or after factory
   *      end block), function doesn't throw and exits silently
   */
  function sync() external override {
    // delegate call to an internal function
    _sync();
  }

  /**
   * @notice Service function to calculate and pay pending yield rewards to the sender
   *
   * @dev Can be executed by anyone at any time, but has an effect only when
   *      executed by deposit holder and when at least one block passes from the
   *      previous reward processing
   * @dev Executed internally when staking and unstaking, executes sync() under the hood
   *      before making further calculations and payouts
   * @dev When timing conditions are not met (executed too frequently, or after factory
   *      end block), function doesn't throw and exits silently
   *
   * @param _useSSYN flag indicating whether to mint sSYNR token as a reward or not;
   *      when set to true - sSYNR reward is minted immediately and sent to sender,
   *      when set to false - new SYNR reward deposit gets created if pool is an SYNR pool
   *      (poolToken is SYNR token), or new pool deposit gets created together with sSYNR minted
   *      when pool is not an SYNR pool (poolToken is not an SYNR token)
   */
  function processRewards(bool _useSSYN) external virtual override {
    // delegate call to an internal function
    _processRewards(msg.sender, _useSSYN, true);
  }

  /**
   * @dev Executed by the factory to modify pool weight; the factory is expected
   *      to keep track of the total pools weight when updating
   *
   * @dev Set weight to zero to disable the pool
   *
   * @param _weight new weight to set for the pool
   */
  function setWeight(uint32 _weight) external override {
    // verify function is executed by the factory
    require(msg.sender == address(factory), "access denied");

    // emit an event logging old and new weight values
    emit PoolWeightUpdated(msg.sender, weight, _weight);

    // set the new weight value
    weight = _weight;
  }

  /**
   * @dev Similar to public pendingYieldRewards, but performs calculations based on
   *      current smart contract state only, not taking into account any additional
   *      time/blocks which might have passed
   *
   * @param _staker an address to calculate yield rewards value for
   * @return pending calculated yield reward value for the given address
   */
  function _pendingYieldRewards(address _staker) internal view returns (uint256 pending) {
    // read user data structure into memory
    User storage user = users[_staker];

    // and perform the calculation using the values read
    return weightToReward(user.totalWeight, yieldRewardsPerWeight) - user.subYieldRewards;
  }

  function setMinLockTime(uint256 _minLockTime) external {
    require(_minLockTime < 365 days, "invalid minLockTime");
    minLockTime = _minLockTime;
  }

  /**
   * @dev Used internally, mostly by children implementations, see stake()
   *
   * @param _staker an address which stakes tokens and which will receive them back
   * @param _amount amount of tokens to stake
   * @param _lockUntil stake period as unix timestamp; zero means no locking
   * @param _useSSYN a flag indicating if previous reward to be paid as sSYNR
   * @param _isYield a flag indicating if that stake is created to store yield reward
   *      from the previously unstaked stake
   */
  function _stake(
    address _staker,
    uint256 _amount,
    uint64 _lockUntil,
    bool _useSSYN,
    bool _isYield
  ) internal virtual poolAlive {
    // validate the inputs
    require(_amount > 0, "SyndicatePoolBase: zero amount");
    // we need to the limit of max locking time to limit the yield bonus
    require(
      _lockUntil >= now256() + minLockTime && _lockUntil - now256() <= 365 days,
      "SyndicatePoolBase: invalid lock interval"
    );
    // update smart contract state
    _sync();

    // get a link to user data struct, we will write to it later
    User storage user = users[_staker];
    // process current pending rewards if any
    if (user.tokenAmount > 0) {
      _processRewards(_staker, _useSSYN, false);
    }

    // in most of the cases added amount `addedAmount` is simply `_amount`
    // however for deflationary tokens this can be different
    // read the current balance
    uint256 previousBalance = IERC20(poolToken).balanceOf(address(this));
    // transfer `_amount`; note: some tokens may get burnt here
    transferPoolTokenFrom(address(msg.sender), address(this), _amount);
    // read new balance, usually this is just the difference `previousBalance - _amount`
    uint256 newBalance = IERC20(poolToken).balanceOf(address(this));
    // calculate real amount taking into account deflation
    uint256 addedAmount = newBalance - previousBalance;

    // set the `lockFrom` and `lockUntil` taking into account that
    // zero value for `_lockUntil` means "no locking" and leads to zero values
    // for both `lockFrom` and `lockUntil`
    uint64 lockFrom = _lockUntil > 0 ? uint64(now256()) : 0;
    uint64 lockUntil = _lockUntil;

    // stake weight formula rewards for locking
    uint256 stakeWeight = (((lockUntil - lockFrom) * WEIGHT_MULTIPLIER) / 365 days + WEIGHT_MULTIPLIER) * addedAmount;

    // makes sure stakeWeight is valid
    assert(stakeWeight > 0);

    // create and save the deposit (append it to deposits array)
    Deposit memory deposit = Deposit({
      tokenAmount: addedAmount,
      weight: stakeWeight,
      lockedFrom: lockFrom,
      lockedUntil: lockUntil,
      isYield: _isYield
    });
    // deposit ID is an index of the deposit in `deposits` array
    user.deposits.push(deposit);

    // update user record
    user.tokenAmount += addedAmount;
    user.totalWeight += stakeWeight;
    user.subYieldRewards = weightToReward(user.totalWeight, yieldRewardsPerWeight);

    // update global variable
    usersLockingWeight += stakeWeight;

    // emit an event
    emit Staked(msg.sender, _staker, _amount);
  }

  /**
   * @dev Used internally, mostly by children implementations, see unstake()
   *
   * @param _staker an address which unstakes tokens (which previously staked them)
   * @param _depositId deposit ID to unstake from, zero-indexed
   * @param _amount amount of tokens to unstake
   * @param _useSSYN a flag indicating if reward to be paid as sSYNR
   */
  function _unstake(
    address _staker,
    uint256 _depositId,
    uint256 _amount,
    bool _useSSYN
  ) internal virtual poolAlive {
    // verify an amount is set
    require(_amount > 0, "zero amount");

    // get a link to user data struct, we will write to it later
    User storage user = users[_staker];
    // get a link to the corresponding deposit, we may write to it later
    Deposit storage stakeDeposit = user.deposits[_depositId];
    // deposit structure may get deleted, so we save isYield flag to be able to use it
    bool isYield = stakeDeposit.isYield;

    // verify available balance
    // if staker address ot deposit doesn't exist this check will fail as well
    require(stakeDeposit.tokenAmount >= _amount, "amount exceeds stake");

    // update smart contract state
    _sync();
    // and process current pending rewards if any
    _processRewards(_staker, _useSSYN, false);

    // recalculate deposit weight
    uint256 previousWeight = stakeDeposit.weight;
    uint256 newWeight = (((stakeDeposit.lockedUntil - stakeDeposit.lockedFrom) * WEIGHT_MULTIPLIER) /
      365 days +
      WEIGHT_MULTIPLIER) * (stakeDeposit.tokenAmount - _amount);

    // update the deposit, or delete it if its depleted
    if (stakeDeposit.tokenAmount - _amount == 0) {
      delete user.deposits[_depositId];
    } else {
      stakeDeposit.tokenAmount -= _amount;
      stakeDeposit.weight = newWeight;
    }

    // update user record
    user.tokenAmount -= _amount;
    user.totalWeight = user.totalWeight - previousWeight + newWeight;
    user.subYieldRewards = weightToReward(user.totalWeight, yieldRewardsPerWeight);

    // update global variable
    usersLockingWeight = usersLockingWeight - previousWeight + newWeight;

    // if the deposit was created by the pool itself as a yield reward
    if (isYield) {
      // mint the yield via the factory
      factory.mintYieldTo(msg.sender, _amount);
    } else {
      // otherwise just return tokens back to holder
      transferPoolToken(msg.sender, _amount);
    }

    // emit an event
    emit Unstaked(msg.sender, _staker, _amount);
  }

  /**
   * @dev Used internally, mostly by children implementations, see sync()
   *
   * @dev Updates smart contract state (`yieldRewardsPerWeight`, `lastYieldDistribution`),
   *      updates factory state via `updateSYNPerBlock`
   */
  function _sync() internal virtual poolAlive {
    // update SYNR per block value in factory if required
    if (factory.shouldUpdateRatio()) {
      factory.updateSYNPerBlock();
    }
    // check bound conditions and if these are not met -
    // exit silently, without emitting an event
    uint256 endBlock = factory.endBlock();
    if (lastYieldDistribution >= endBlock) {
      return;
    }
    if (blockNumber() <= lastYieldDistribution) {
      return;
    }
    // if locking weight is zero - update only `lastYieldDistribution` and exit
    if (usersLockingWeight == 0) {
      lastYieldDistribution = uint64(blockNumber());
      return;
    }
    // to calculate the reward we need to know how many blocks passed, and reward per block
    uint256 currentBlock = blockNumber() > endBlock ? endBlock : blockNumber();
    uint256 blocksPassed = currentBlock - lastYieldDistribution;
    uint256 synrPerBlock = factory.synrPerBlock();

    // calculate the reward
    uint256 synReward = (blocksPassed * synrPerBlock * weight) / factory.totalWeight();

    totalYieldReward += synReward;

    // update rewards per weight and `lastYieldDistribution`
    yieldRewardsPerWeight += rewardToWeight(synReward, usersLockingWeight);
    lastYieldDistribution = uint64(currentBlock);

    // emit an event
    emit Synchronized(msg.sender, yieldRewardsPerWeight, lastYieldDistribution);
  }

  /**
   * @dev Used internally, mostly by children implementations, see processRewards()
   *
   * @param _staker an address which receives the reward (which has staked some tokens earlier)
   * @param _useSSYN flag indicating whether to mint sSYNR token as a reward or not, see processRewards()
   * @param _withUpdate flag allowing to disable synchronization (see sync()) if set to false
   * @return pendingYield the rewards calculated and optionally re-staked
   */
  function _processRewards(
    address _staker,
    bool _useSSYN,
    bool _withUpdate
  ) internal virtual poolAlive returns (uint256 pendingYield) {
    // update smart contract state if required
    if (_withUpdate) {
      _sync();
    }

    // calculate pending yield rewards, this value will be returned
    pendingYield = _pendingYieldRewards(_staker);

    // if pending yield is zero - just return silently
    if (pendingYield == 0) return 0;

    // get link to a user data structure, we will write into it later
    User storage user = users[_staker];

    // if sSYNR is requested
    if (_useSSYN) {
      // - mint sSYNR
      mintSSyn(_staker, pendingYield);
    } else if (poolToken == synr) {
      // calculate pending yield weight,
      // 2e6 is the bonus weight when staking for 1 year
      uint256 depositWeight = pendingYield * YEAR_STAKE_WEIGHT_MULTIPLIER;

      // if the pool is SYNR Pool - create new SYNR deposit
      // and save it - push it into deposits array
      Deposit memory newDeposit = Deposit({
        tokenAmount: pendingYield,
        lockedFrom: uint64(now256()),
        lockedUntil: uint64(now256() + 365 days), // staking yield for 1 year
        weight: depositWeight,
        isYield: true
      });
      user.deposits.push(newDeposit);

      // update user record
      user.tokenAmount += pendingYield;
      user.totalWeight += depositWeight;

      // update global variable
      usersLockingWeight += depositWeight;
    } else {
      // for other pools - stake as pool
      address synPool = factory.getPoolAddress(synr);
      ICorePool(synPool).stakeAsPool(_staker, pendingYield);
    }

    // update users's record for `subYieldRewards` if requested
    if (_withUpdate) {
      user.subYieldRewards = weightToReward(user.totalWeight, yieldRewardsPerWeight);
    }

    // emit an event
    emit YieldClaimed(msg.sender, _staker, _useSSYN, pendingYield);
  }

  /**
   * @dev See updateStakeLock()
   *
   * @param _staker an address to update stake lock
   * @param _depositId updated deposit ID
   * @param _lockedUntil updated deposit locked until value
   * @param _useSSYN used for _processRewards check if it should use SYNR or sSYNR
   */
  function _updateStakeLock(
    address _staker,
    uint256 _depositId,
    uint64 _lockedUntil,
    bool _useSSYN
  ) internal virtual poolAlive {
    // synchronizes pool state
    _sync();
    // validate the input time
    require(_lockedUntil > now256(), "lock should be in the future");
    // get a link to user data struct, we will write to it later
    User storage user = users[_staker];
    if (user.tokenAmount > 0) {
      _processRewards(_staker, _useSSYN, false);
    }
    // get a link to the corresponding deposit, we may write to it later
    Deposit storage stakeDeposit = user.deposits[_depositId];

    // validate the input against deposit structure
    require(_lockedUntil > stakeDeposit.lockedUntil, "invalid new lock");

    // verify locked from and locked until values
    if (stakeDeposit.lockedFrom == 0) {
      require(_lockedUntil - now256() <= 365 days, "max lock period is 365 days");
      stakeDeposit.lockedFrom = uint64(now256());
    } else {
      require(_lockedUntil - stakeDeposit.lockedFrom <= 365 days, "max lock period is 365 days");
    }

    // update locked until value, calculate new weight
    stakeDeposit.lockedUntil = _lockedUntil;
    uint256 newWeight = (((stakeDeposit.lockedUntil - stakeDeposit.lockedFrom) * WEIGHT_MULTIPLIER) /
      365 days +
      WEIGHT_MULTIPLIER) * stakeDeposit.tokenAmount;

    // save previous weight
    uint256 previousWeight = stakeDeposit.weight;
    // update weight
    stakeDeposit.weight = newWeight;

    // update user total weight, sub yield rewards and global locking weight
    user.totalWeight = user.totalWeight - previousWeight + newWeight;
    user.subYieldRewards = weightToReward(user.totalWeight, yieldRewardsPerWeight);
    usersLockingWeight = usersLockingWeight - previousWeight + newWeight;

    // emit an event
    emit StakeLockUpdated(_staker, _depositId, stakeDeposit.lockedFrom, _lockedUntil);
  }

  /**
   * @dev Converts stake weight (not to be mixed with the pool weight) to
   *      SYNR reward value, applying the 10^12 division on weight
   *
   * @param _weight stake weight
   * @param rewardPerWeight SYNR reward per weight
   * @return reward value normalized to 10^12
   */
  function weightToReward(uint256 _weight, uint256 rewardPerWeight) public pure returns (uint256) {
    // apply the formula and return
    return (_weight * rewardPerWeight) / REWARD_PER_WEIGHT_MULTIPLIER;
  }

  /**
   * @dev Converts reward SYNR value to stake weight (not to be mixed with the pool weight),
   *      applying the 10^12 multiplication on the reward
   *      - OR -
   * @dev Converts reward SYNR value to reward/weight if stake weight is supplied as second
   *      function parameter instead of reward/weight
   *
   * @param reward yield reward
   * @param rewardPerWeight reward/weight (or stake weight)
   * @return stake weight (or reward/weight)
   */
  function rewardToWeight(uint256 reward, uint256 rewardPerWeight) public pure returns (uint256) {
    // apply the reverse formula and return
    return (reward * REWARD_PER_WEIGHT_MULTIPLIER) / rewardPerWeight;
  }

  /**
   * @dev Testing time-dependent functionality is difficult and the best way of
   *      doing it is to override block number in helper test smart contracts
   *
   * @return `block.number` in mainnet, custom values in testnets (if overridden)
   */
  function blockNumber() public view virtual returns (uint256) {
    // return current block number
    return block.number;
  }

  /**
   * @dev Testing time-dependent functionality is difficult and the best way of
   *      doing it is to override time in helper test smart contracts
   *
   * @return `block.timestamp` in mainnet, custom values in testnets (if overridden)
   */
  function now256() public view virtual returns (uint256) {
    // return current block timestamp
    return block.timestamp;
  }

  /**
   * @dev Executes  SyntheticSyndicateERC20.mint(_to, _values)
   *      on the bound  SyntheticSyndicateERC20 instance
   *
   * @dev Reentrancy safe due to the  SyntheticSyndicateERC20 design
   */
  // solhint-disable-next-line
  function mintSSyn(address _to, uint256 _value) internal {
    // just delegate call to the target
    SyntheticSyndicateERC20(ssynr).mint(_to, _value);
  }

  /**
   * @dev Executes SafeERC20.safeTransfer on a pool token
   *
   * @dev Reentrancy safety enforced via `ReentrancyGuard.nonReentrant`
   */
  // solhint-disable-next-line
  function transferPoolToken(address _to, uint256 _value) internal nonReentrant {
    // just delegate call to the target
    SafeERC20.safeTransfer(IERC20(poolToken), _to, _value);
  }

  /**
   * @dev Executes SafeERC20.safeTransferFrom on a pool token
   *
   * @dev Reentrancy safety enforced via `ReentrancyGuard.nonReentrant`
   */
  // solhint-disable-next-line
  function transferPoolTokenFrom(
    address _from,
    address _to,
    uint256 _value
  ) internal nonReentrant {
    // just delegate call to the target
    SafeERC20.safeTransferFrom(IERC20(poolToken), _from, _to, _value);
  }
}
