// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

/*import "./IERC20.sol";
import "./SafeERC20.sol";
import "./EnumerableSet.sol";*/
import "./SafeMath.sol";
//import "./Ownable.sol";
import "./SafeERC20.sol";
import "./SAVENFT.sol";

contract SAVENFTFarm is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of SAVENFTs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accSAVENFTPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws tokens to a pool. Here's what happens:
        //   1. The pool's `accSAVENFTPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }
    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. SAVENFTs to distribute per block.
        uint256 lastRewardBlock; // Last block number that SAVENFTs distribution occurs.
        uint256 accSAVENFTPerShare; // Accumulated SAVENFTs per share, times 1e9.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }
    // The SAVENFT TOKEN!
    SAVENFT public savenft;
    // Dev address.
    address public devaddr;
    // Deposit Fee address
    address public feeAddress;
    // address to receive the team rewards
    //address public teamRewardsReceiver;
    // Block number when bonus SAVENFTs period ends.
    uint256 public bonusEndBlock;
    // SAVENFT tokens created per block.
    uint256 public saveNftPerBlock;
    // Bonus muliplier for early SAVENFTs makers.
    uint256 public constant BONUS_MULTIPLIER = 10;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when SAVENFT mining starts.
    uint256 public startBlock;

    // team share, normalised by 10000
    //uint256 public teamShare;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);

    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    event SetDev(address indexed user, address indexed _devaddr);

    constructor(
        SAVENFT _savenft,
        address _devaddr,
        //address _teamRewardsReceiver,
        uint256 _saveNftPerBlock,
        //uint256 _teamShare,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) public {
        feeAddress = msg.sender;
        savenft = _savenft;
        devaddr = _devaddr;
        saveNftPerBlock = _saveNftPerBlock;
        //teamShare = _teamShare;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
        //teamRewardsReceiver = _teamRewardsReceiver;
    }

    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "farm: pool do not exists");
        _;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    modifier onlyDev() {
        require(msg.sender == devaddr, "farm: wrong developer");
        _;
    }

    // Add a new token to the pool. Can only be called by the owner.
    // XXX DO NOT add the same token more than once. Rewards will be messed up if you do.
    function checkPoolDuplicate(IERC20 _token) public view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "add: existing pool?");
        }
    }

    function add(
        uint256 _allocPoint,
        IERC20 _token,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) public onlyDev {
        if (_withUpdate) {
            massUpdatePools();
        }
        checkPoolDuplicate(_token);
        require(_depositFeeBP <= 500, "add: invalid deposit fee basis points");
        uint256 lastRewardBlock =
            block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                token: _token,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accSAVENFTPerShare: 0, 
                depositFeeBP: _depositFeeBP
            })
        );
    }

    // Update the given pool's SAVENFT allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) public onlyDev {
        require(_depositFeeBP <= 500, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        if (poolInfo[_pid].allocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint
                .sub(poolInfo[_pid].allocPoint)
                .add(_allocPoint);
            poolInfo[_pid].allocPoint = _allocPoint;
        }
        
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        require(_from <= _to, "_from must be less than or equal to _to");
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return
                bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                    _to.sub(bonusEndBlock)
                );
        }
    }

    // View function to see pending SAVENFTs on frontend.
    function pendingSAVENFT(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSAVENFTPerShare = pool.accSAVENFTPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        
        
        
        if (block.number > pool.lastRewardBlock && tokenSupply != 0) {
            uint256 multiplier =
                getMultiplier(pool.lastRewardBlock, block.number);
            uint256 savenftReward =
                multiplier.mul(saveNftPerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );
            accSAVENFTPerShare = accSAVENFTPerShare.add(
                savenftReward.mul(1e9).div(tokenSupply)
            );
        }
        return user.amount.mul(accSAVENFTPerShare).div(1e9).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        
        // rewards end after 30 days
        if((block.number > startBlock + 30 days) && saveNftPerBlock != 0)
            saveNftPerBlock = 0;
        
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 savenftReward =
            multiplier.mul(saveNftPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            );

        // staker share
        //uint256 teamReward = savenftReward.mul(teamShare).div(10000);
        
       /* if(savenft.balanceOf(address(this)) >= teamReward)
            savenft.transfer(teamRewardsReceiver, teamReward); */

        pool.accSAVENFTPerShare = pool.accSAVENFTPerShare.add(
            savenftReward.mul(1e9).div(tokenSupply)
        );
        
        pool.lastRewardBlock = block.number;
        
        
        // mint reward for stakers
        //savenft.mint(address(this), savenftReward.sub(teamReward));
        // mint reward of the team
       // savenft.mint(teamRewardsReceiver, teamReward);
    }

    // Deposit Tokens for SAVENFT allocation.
    function deposit(uint256 _pid, uint256 _amount) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending =
                user.amount.mul(pool.accSAVENFTPerShare).div(1e9).sub(
                    user.rewardDebt
                );
            if (pending > 0) {
                safeSAVENFTTransfer(msg.sender, pending);
            }
        }
        
        
        
        if (_amount > 0) {
            pool.token.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.token.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        
        
        
        //user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accSAVENFTPerShare).div(1e9);

        //pool.token.safeTransferFrom(address(msg.sender), address(this), _amount);

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw tokens
    function withdraw(uint256 _pid, uint256 _amount) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending =
            user.amount.mul(pool.accSAVENFTPerShare).div(1e9).sub(
                user.rewardDebt
            );

        user.rewardDebt = user.amount.mul(pool.accSAVENFTPerShare).div(1e9);

        if (pending > 0) {
            //safeSAVENFTTransfer(msg.sender, pending);

            // if claim withing 30 days of farm start take 10% fee else 0%
            if(block.number <= startBlock + 30 days) {
                uint256 fee = pending.mul(10).div(100);
                
                safeSAVENFTTransfer(msg.sender, pending.sub(fee));
                safeSAVENFTTransfer(devaddr, fee);

            }
            else
                safeSAVENFTTransfer(msg.sender, pending);
        }
        
        

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(address(msg.sender), _amount);
        }
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // claim SAVENFT tokens
    function claim(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount > 0, "No Rewards to claim");
        updatePool(_pid);
        uint256 pending =
            user.amount.mul(pool.accSAVENFTPerShare).div(1e9).sub(
                user.rewardDebt
            );
        user.rewardDebt = user.amount.mul(pool.accSAVENFTPerShare).div(1e9);
        
        if (pending > 0) {
            // if claim withing 30 days of farm start take 10% fee else 0%
            if(block.number <= startBlock + 30 days) {
                uint256 fee = pending.mul(10).div(100);
                
                safeSAVENFTTransfer(msg.sender, pending.sub(fee));
                safeSAVENFTTransfer(devaddr, fee);

            }
            else
                safeSAVENFTTransfer(msg.sender, pending);
        }
        
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amt = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(address(msg.sender), amt);
        emit EmergencyWithdraw(msg.sender, _pid, amt);
    }

    // Safe SAVENFTs transfer function, just in case if rounding error causes pool to not have enough SAVENFT.
    function safeSAVENFTTransfer(address _to, uint256 _amount) internal {
        uint256 savenftBal = savenft.balanceOf(address(this));
        if (_amount > savenftBal) {
            savenft.transfer(_to, savenftBal);
        } else {
            savenft.transfer(_to, _amount);
        }
    }

    function changeSaveNFTPerBlock(uint256 _newRate) public onlyDev {
        require(msg.sender == devaddr, "dev: wut?");
        saveNftPerBlock = _newRate;
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public onlyDev {
        devaddr = _devaddr;
        emit SetDev(msg.sender, _devaddr);
    }
    
    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        feeAddress = _feeAddress;
    }

    // 1000000 is 100%
    /*function updateTeamShare(uint256 _newShare) public onlyDev {
        require(_newShare > 0 && _newShare < 1000000, "Wrong Values");
        teamShare = _newShare;
    }*/
}