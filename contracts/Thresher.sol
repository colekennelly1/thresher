/*
* Thresher accumulates small deposits until there are enough to fund a full Tornado.cash
* deposit.
*
* The problem: Tornado.cash deposits and withdrawals are fixed-size, with a minimum
* size (0.1 ETH in the case of ether). Anybody that uses tornado properly will accumulate
* less-than-minimum amounts of ETH in different addresses and be unable to spend
* them without compromising privacy.
*
* Solution: Accumulated 0.1 ETH or more, then redeposits 0.1 ETH into Tornado.cash with
* one of the deposit's notes, picked fairly at random (e.g. if you deposit 0.09 ETH
* your note has a 90% chance of being picked).
*
* Winners are picked as a side effect of processing a new deposit at some current block height N.
*
* The hash of block N-1 is used as the random seed to pick a winner. However, to make cheating by
* miners even more costly, only deposits received before block N-1 can win.
*
* I haven't run the numbers, but it is almost certainly not in the miners' financial interest
* to cheat; proof-of-work makes it expensive to recompute a block hash, much more expensive than
* the 0.1 ETH a miner might gain by cheating.
*
* Furthermore, even if miner of block N-1 tries to generate a winning block hash, they would need
* to have a confirmed deposit in block N-2 (or earlier) to be eligible to win. When they submitted
* that transaction they'd have to pay transaction fees, which they will lose if they don't end up
* mining block N-1.
*/

pragma solidity ^0.5.8;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Tornado {
    uint256 public denonimation;
    function deposit(bytes32 _commitment) external payable;
}

/*
* Double-ended queue of entries.
* Functions not used by Thresher (like popRight()) have been removed
* (resurrect them from git history if necessary)
*/
contract EntryDeque {
    struct Entry {
        uint256 amount;
        bytes32 commitment; // aka tornado.cash 'note' / pedersen commitment
        uint256 blockNumber;
    }
    mapping(uint256 => Entry) internal entries;
    uint256 internal nFirst = 2**255;
    uint256 internal nLast = nFirst - 1;

    function empty() internal view returns (bool) {
        return nLast < nFirst;
    }

    function first() internal view returns (uint256 _amount, bytes32 _commitment, uint256 _blockNumber) {
        require(!empty());

        _amount = entries[nFirst].amount;
        _commitment = entries[nFirst].commitment;
        _blockNumber = entries[nFirst].blockNumber;
    }

    function popFirst() internal {
        require(!empty());

        delete entries[nFirst];
        nFirst += 1;
    }

    function pushLast(uint256 _amount, bytes32 _commitment, uint256 _blockNumber) internal {
        nLast += 1;
        entries[nLast] = Entry(_amount, _commitment, _blockNumber);
    }
}

contract Thresher is EntryDeque, ReentrancyGuard {
    address public tornadoAddress;
    bytes32 public randomHash;

    event Win(bytes32 indexed commitment);
    event Lose(bytes32 indexed commitment);

    /**
      @dev The constructor
      @param _tornadoAddress the Tornado.cash contract that will receive accumulated deposits
    **/
    constructor(address payable _tornadoAddress) public {
        tornadoAddress = _tornadoAddress;
        randomHash = keccak256(abi.encode("Eleven!"));

        // Sanity check:
        require(Tornado(tornadoAddress).denonimation() > 0);
    }

    /**
      @dev Deposit funds. The caller must send less than or equal to the Tornado.cash denonimation
      @param _commitment Forwarded to Tornado if this deposit 'wins'
    **/
    function deposit(bytes32 _commitment) external payable nonReentrant {
        Tornado tornado = Tornado(tornadoAddress);
        uint256 payoutThreshold = tornado.denonimation();

        uint256 v = msg.value;
        require(v <= payoutThreshold, "Deposit amount too large");

        // Q: Any reason to fail if the msg.value is tiny (e.g. 1 wei)?
        // I can't see any reason to enforce a minimum; gas costs make attacks
        // expensive.
        // Q: any reason to check gasleft(), or just let the deposit fail if
        // the user doesn't include enough gas for the tornado deposit?

        uint256 currentBlock = block.number;
        pushLast(v, _commitment, currentBlock);

        if (address(this).balance < payoutThreshold) {
            return;
        }

        bool winner = false;
        uint256 amount;
        bytes32 commitment;
        uint256 blockNumber;
        bytes32 hash = randomHash;
        
        // Maximum one payout per deposit, because multiple tornado deposits could cost a lot of gas
        // ... but usability is better (faster win/didn't win decisions) if we keep going until
        // we either pay out or don't have any entries old enough to pay out:
        while (!winner) {
            (amount, commitment, blockNumber) = first();
            if (blockNumber > currentBlock-2) {
                break;
            }
            popFirst();

            // a different hash is computed for every entry to make it more difficult for somebody
            // to arrange for their own entries to win
            bytes32 b = hash ^ blockhash(currentBlock-1);
            hash = keccak256(abi.encodePacked(b));
            if (amount >= pickWinningThreshold(randomHash, payoutThreshold)) {
                winner = true;
            }
            else {
                emit Lose(commitment);
            }
        }
        randomHash = hash;
        if (winner) {
           tornado.deposit.value(payoutThreshold)(commitment);
           emit Win(commitment);
        }
    }

    function pickWinningThreshold(bytes32 hash, uint256 max) internal pure returns (uint256) {
        return uint256(hash) % max;

        /*
         Lets talk about modulo bias here, because I know somebody is going to complain.
         We could do this:
              https://github.com/pooltogether/pooltogether-contracts/blob/master/contracts/UniformRandomNumber.sol
         ... but is the extra code worth the gas cost?
         Lets play computer with uint256 (2**256) and the 10*17 (0.1 eth) threshold: compute
         how many values we should skip to avoid any bias:
         min = (2**256 - 10**17) % 10**17
             84007913129639936L  <<- The first 840 quadrillion hashes are biased!  But:
         2**256 / 84007913129639936L
              1378347407090416896591674552386804332932494391328937058907953L
         This is how many times we'd need to call this routine before running into modulo bias and
         choosing another number from the 2**256 range. The universe will be long dead before that happens,
         so using UniformRandomNumber.sol instead of the one-liner here would effectively be adding dead code.
        */
    }
}
