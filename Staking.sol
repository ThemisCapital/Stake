// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./library/SafeMath.sol";
import "./interface/IERC20.sol";
import "./interface/ITHSERC20.sol";
import "./interface/IWarmup.sol";
import "./interface/IDistributor.sol";
import "./interface/IScFarmForInvter.sol";
import "./interface/IScFarmForStaker.sol";
import "./interface/IThsFarmForInvter.sol";
import "./interface/IStakingRewardRelease.sol";
import "./interface/IPresaleReleaseV1.sol";

import "./library/Address.sol";
import "./library/SafeERC20.sol";

import "hardhat/console.sol";

contract ThemisStaking is OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public THS;
    address public sTHS;

    enum CONTRACTS {
        DISTRIBUTOR,
        WARMUP,
        LOCKER
    }

    struct Epoch {
        uint256 length;
        uint256 number;
        uint256 endBlock;
        uint256 distribute;
    }

    struct Claim {
        uint256 deposit;
        uint256 gons;
        uint256 expiry;
        bool lock;
    }

    Epoch public epoch;
    mapping(address => Claim) public warmupInfo;

    address public distributor;

    address public locker;
    uint256 public totalBonus;

    address public warmupContract; //
    uint256 public warmupPeriod;

    address public scFarmForInvter;
    bool public scFarmForInvterSwaitch;
    address public scFarmForStaker;
    bool public scFarmForStakerSwaitch;
    address public stakingRewardRelease;
    bool public stakingRewardReleaseSwaitch;
    mapping(address => uint256) public stakingAmountOf;
    address public thsFarmForInviter;
    bool public thsFarmForInviterSwitch;
    address public presaleReleaseV1;
    bool public presaleReleaseV1Switch;
    address public loanContract;

    //event
    event Rebase(uint256 profit, uint256 epoch);
    event Stake(uint256 amount, address recipient);
    event Unstake(uint256 amount, bool trigger);

    // constructor() initializer {}

    function initialize(
        address _THS,
        address _sTHS,
        uint256 _epochLength,
        uint256 _firstEpochNumber,
        uint256 _firstEpochBlock
    ) public initializer {
        __Ownable_init();
        require(_THS != address(0));
        THS = _THS;
        require(_sTHS != address(0));
        sTHS = _sTHS;

        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            endBlock: _firstEpochBlock,
            distribute: 0
        });
    }

    function stake(uint256 _amount, address _recipient)
        external
        returns (bool)
    {
        rebase();

        IERC20(THS).safeTransferFrom(msg.sender, address(this), _amount);

        Claim memory info = warmupInfo[_recipient];
        require(!info.lock, "Deposits for account are locked");

        warmupInfo[_recipient] = Claim({
            deposit: info.deposit.add(_amount),
            gons: info.gons.add(ITHSERC20(sTHS).gonsForBalance(_amount)),
            expiry: epoch.number.add(warmupPeriod),
            lock: false
        });

        IERC20(sTHS).safeTransfer(warmupContract, _amount);
        emit Stake(_amount, _recipient);
        return true;
    }

    function claim(address _recipient) public {
        Claim memory info = warmupInfo[_recipient];
        if (epoch.number >= info.expiry && info.expiry != 0) {
            delete warmupInfo[_recipient];
            uint256 sthsAmount = ITHSERC20(sTHS).balanceForGons(info.gons);
            IWarmup(warmupContract).retrieve(_recipient, sthsAmount);
            if (loanContract != msg.sender)
                _changeStakeAmount(_recipient, sthsAmount, 0);
        }
    }

    function forfeit() external {
        Claim memory info = warmupInfo[msg.sender];
        delete warmupInfo[msg.sender];

        IWarmup(warmupContract).retrieve(
            address(this),
            ITHSERC20(sTHS).balanceForGons(info.gons)
        );
        IERC20(THS).safeTransfer(msg.sender, info.deposit);
    }

    function toggleDepositLock() external {
        warmupInfo[msg.sender].lock = !warmupInfo[msg.sender].lock;
    }

    function unstake(uint256 _amount, bool _trigger) external {
        if (_trigger) {
            rebase();
        }

        uint256 rewardAmount = 0;
        if (loanContract != msg.sender) {
            uint256 stakedAmount = stakingAmountOf[msg.sender];
            require(_amount <= stakedAmount, "amount too large");
            rewardAmount = IERC20(sTHS).balanceOf(msg.sender).sub(stakedAmount);
            _changeStakeAmount(msg.sender, 0, _amount);
            _sendTHSReward(msg.sender, rewardAmount);
        }

        uint256 sThsFromSender = rewardAmount.add(_amount);
        IERC20(sTHS).safeTransferFrom(
            msg.sender,
            address(this),
            sThsFromSender
        );
        IERC20(THS).safeTransfer(msg.sender, _amount);
        emit Unstake(_amount, _trigger);
    }

    function index() public view returns (uint256) {
        return ITHSERC20(sTHS).index();
    }

    function rebase() public {
        if (epoch.endBlock <= block.number) {
            ITHSERC20(sTHS).rebase(epoch.distribute, epoch.number);

            epoch.endBlock = epoch.endBlock.add(epoch.length);
            epoch.number++;

            if (distributor != address(0)) {
                IDistributor(distributor).distribute();
            }

            uint256 balance = contractBalance();

            uint256 staked = ITHSERC20(sTHS).circulatingSupply();

            if (balance <= staked) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub(staked);
            }

            emit Rebase(epoch.distribute, epoch.number);
        }
    }

    function _changeStakeAmount(
        address _staker,
        uint256 _increaseAmount,
        uint256 _decreaseAmount
    ) private {
        uint256 beforeAmount = stakingAmountOf[_staker];
        if (_increaseAmount > 0) {
            stakingAmountOf[_staker] = beforeAmount.add(_increaseAmount);
        } else if (_decreaseAmount > 0) {
            stakingAmountOf[_staker] = beforeAmount.sub(_decreaseAmount);
        }

        uint256 afterAmount = stakingAmountOf[_staker];
        if (scFarmForInvterSwaitch) {
            IScFarmForInvter(scFarmForInvter).changeStakeAmount(
                _staker,
                afterAmount
            );
        }
        if (scFarmForStakerSwaitch) {
            IScFarmForStaker(scFarmForStaker).changeStakeAmount(
                _staker,
                afterAmount
            );
        }
        if (thsFarmForInviterSwitch) {
            IThsFarmForInvter(thsFarmForInviter).changeStakeAmount(
                _staker,
                afterAmount
            );
        }

        if (presaleReleaseV1Switch) {
            IPresaleReleaseV1(presaleReleaseV1).changeStakeAmount(
                _staker,
                afterAmount
            );
        }
    }

    function _sendTHSReward(address _receiptor, uint256 _rewardAmount) private {
        if (_rewardAmount == 0) return;
        if (stakingRewardReleaseSwaitch) {
            IStakingRewardRelease(stakingRewardRelease).addReward(
                _receiptor,
                _rewardAmount
            );

            IERC20(THS).safeTransfer(stakingRewardRelease, _rewardAmount);
        } else {
            IERC20(THS).safeTransfer(_receiptor, _rewardAmount);
        }
    }

    function contractBalance() public view returns (uint256) {
        return IERC20(THS).balanceOf(address(this)).add(totalBonus);
    }

    function giveLockBonus(uint256 _amount) external {
        require(msg.sender == locker);
        totalBonus = totalBonus.add(_amount);
        IERC20(sTHS).safeTransfer(locker, _amount);
    }

    function returnLockBonus(uint256 _amount) external {
        require(msg.sender == locker);
        totalBonus = totalBonus.sub(_amount);
        IERC20(sTHS).safeTransferFrom(locker, address(this), _amount);
    }

    function setContract(CONTRACTS _contract, address _address)
        external
        onlyOwner
    {
        if (_contract == CONTRACTS.DISTRIBUTOR) {
            // 0
            distributor = _address;
        } else if (_contract == CONTRACTS.WARMUP) {
            // 1
            require(
                warmupContract == address(0),
                "Warmup cannot be set more than once"
            );
            warmupContract = _address;
        } else if (_contract == CONTRACTS.LOCKER) {
            // 2
            require(
                locker == address(0),
                "Locker cannot be set more than once"
            );
            locker = _address;
        }
    }

    function setWarmup(uint256 _warmupPeriod) external onlyOwner {
        warmupPeriod = _warmupPeriod;
    }

    function setScFarmForInvter(address _contract, bool _switch)
        external
        onlyOwner
    {
        if (_switch)
            require(address(0) != _contract, "not support zero address");
        scFarmForInvter = _contract;
        scFarmForInvterSwaitch = _switch;
    }

    function setScFarmForStaker(address _contract, bool _switch)
        external
        onlyOwner
    {
        if (_switch)
            require(address(0) != _contract, "not support zero address");
        scFarmForStaker = _contract;
        scFarmForStakerSwaitch = _switch;
    }

    function setStakingRewardRelease(address _contract, bool _switch)
        external
        onlyOwner
    {
        if (_switch)
            require(address(0) != _contract, "not support zero address");
        stakingRewardRelease = _contract;
        stakingRewardReleaseSwaitch = _switch;
    }

    function setPresaleReleaseV1(address _contract, bool _switch)
        external
        onlyOwner
    {
        if (_switch)
            require(address(0) != _contract, "not support zero address");
        presaleReleaseV1 = _contract;
        presaleReleaseV1Switch = _switch;
    }

    function setThsFarmForInviter(address _contract, bool _switch)
        external
        onlyOwner
    {
        if (_switch)
            require(address(0) != _contract, "not support zero address");
        thsFarmForInviter = _contract;
        thsFarmForInviterSwitch = _switch;
    }

    function getNextDistribute() external view returns (uint256 distribute_) {
        return epoch.distribute;
    }

    function setLoanContract(address _contract) external onlyOwner {
        loanContract = _contract;
    }

    function getStakingAmount(address _addr) external view returns(uint256 stakingAmount_){
        return stakingAmountOf[_addr];
    }
}
