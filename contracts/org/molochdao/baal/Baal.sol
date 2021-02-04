// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface MemberAction {
    function memberBurn(address member, uint256 votes) external; // vote-weighted member burn - e.g., "ragequit" to claim capital
    function memberMint(address member, uint256 amount) external; // amount-weighted member vote mint - e.g., submit direct "tribute" for votes
}

contract ReentrancyGuard { // call wrapper for reentrancy check - see https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/ReentrancyGuard.sol
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

contract Baal is ReentrancyGuard {
    address[] public memberList; // array of member accounts summoned or added by proposal
    address[] public contactList; // array of contacts
    uint256 public proposalCount; // counter for proposals submitted 
    uint256 public totalSupply; // counter for member votes minted - erc20 compatible
    uint256 public minVotingPeriod; // min period proposal voting in epoch time
    uint256 public maxVotingPeriod; // max period for proposal voting in epoch time
    uint8 constant public decimals = 18; // decimals for erc20 vote accounting - 18 is default for ETH
    string public name; // name for erc20 vote accounting
    string public symbol; // symbol for erc20 vote accounting
    
    mapping(address => uint256) public balanceOf; // mapping member accounts to votes
    mapping(address => bool) public contractList; // mapping contract approved for member calls 
    mapping(address => bool) public contacts; // mapping of approved addresses for proposals
    mapping(address => mapping(uint256 => bool)) public voted; // mapping proposal number to whether member voted 
    mapping(uint256 => Proposal) public proposals; // mapping proposal number to struct details
    
    event SubmitProposal(address indexed proposer, address indexed target, uint256 proposal, uint256 value, bytes data, uint8 membership, string details); // emits when member submits proposal 
    event SubmitVote(address indexed member, uint256 proposal, bool approve); // emits when member submits vote on proposal
    event ProcessProposal(uint256 proposal); // emits when proposal is processed and finalized
    event Receive(address indexed sender, uint256 value); // emits when ether (ETH) is received
    event Transfer(address indexed from, address indexed to, uint256 amount); // emits when member votes are minted or burned
    event ProcessMemberProposal(address indexed from, address indexed to, uint256 amount, uint256 proposal);
    event ProcessMemberKick(address indexed from, address indexed to, uint256 amount, uint256 proposal);
    
    struct Proposal {
        address target; // account that receives low-level call `data` and ETH `value` - if `membership` is `true` and data `length` is 0, the account that will receive `value` votes - otherwise, the account that will lose votes
        uint256 value; // ETH sent from Baal to execute approved proposal low-level call - if `membership` is `true` and data `length` is 0, reflects `votes` to grant member
        uint256 noVotes; // counter for member no votes to calculate approval on processing
        uint256 yesVotes; // counter for member yes votes to calculate approval on processing
        uint256 votingEnds; // termination date for proposal in seconds since epoch - derived from votingPeriod
        bytes data; // raw data sent to `target` account for low-level call
        uint8 membership; // 0 - not membership, 1 - add shares, 2 - burn shares, 3 - add contact
        bool processed; // flags whether proposal has been processed and executed
        string details; // context for proposal - could be IPFS hash, plaintext, or JSON
    }
    
    /// @dev deploy Baal and create initial array of member accounts with specific vote weights
    /// @param summoners Accounts to add as members
    /// @param votes Voting weight per member
    /// @param _minVotingPeriod Min Voting period in seconds for members to cast votes on proposals
    /// @param _minVotingPeriod Max Voting period in seconds for members to cast votes on proposals
    /// @param _name Name for erc20 vote accounting
    /// @param _symbol Symbol for erc20 vote accounting
    constructor(address[] memory summoners, uint256[] memory votes, uint256 _minVotingPeriod, uint256 _maxVotingPeriod, string memory _name, string memory _symbol) {
        for (uint256 i = 0; i < summoners.length; i++) {
             totalSupply += votes[i]; // total votes incremented by summoning
             minVotingPeriod = _minVotingPeriod; 
             maxVotingPeriod = _maxVotingPeriod; 
             name = _name;
             symbol = _symbol;
             balanceOf[summoners[i]] = votes[i]; // vote weights granted to member
             memberList.push(summoners[i]); // update list of member accounts
             emit Transfer(address(this), summoners[i], votes[i]); // event reflects mint of erc20 votes
        }
    }
    
    /// @dev Submit proposal for member approval within voting period
    /// @param target Account that receives low-level call `data` and ETH `value` - if `membership`, the account that will receive `value` votes - if `removal`, the account that will lose votes
    /// @param value ETH sent from Baal to execute approved proposal low-level call - if `membership`, reflects `votes` to grant member
    /// @param data Raw data sent to `target` account for low-level call 
    /// @param membership Flags whether proposal involves adding member votes - if `false`, then stage transaction to remove member votes
    /// @param details Context for proposal - could be IPFS hash, plaintext, or JSON
    function submitProposal(address target, uint256 value, uint256 votingLength, bytes calldata data, uint8 membership, string calldata details) external nonReentrant returns (uint256 count) {
        require(balanceOf[msg.sender] > 0 || contacts[msg.sender] == true, "Baal:: Must be a member or contact");
        require(votingLength >= minVotingPeriod && votingLength <= maxVotingPeriod, "Baal:: Voting period too long or short");
        
        proposalCount++;
        uint256 proposal = proposalCount;
        
        proposals[proposal] = Proposal(target, value, 0, 0, block.timestamp + votingLength, data, membership, false, details); // push params into proposal struct - start timer
        
        emit SubmitProposal(msg.sender, target, proposal, value, data, membership, details);
        return proposal;
    }
    
    /// @dev Submit vote - caller must have uncast votes - proposal must exist, be unprocessed, and voting period cannot be finished
    /// @param proposal Number of proposal in `proposals` mapping to cast vote on 
    /// @param approve If `true`, member will cast `yesVotes` onto proposal - if `false, `noVotes` will be cast
    function submitVote(uint256 proposal, bool approve) external nonReentrant returns (uint256 count) {
        require(proposal <= proposalCount, "!exist");
        require(proposals[proposal].votingEnds >= block.timestamp, "finished");
        require(!proposals[proposal].processed, "processed");
        require(balanceOf[msg.sender] > 0, "!active");
        require(!voted[msg.sender][proposal], "voted");
        
        if (approve) {proposals[proposal].yesVotes += balanceOf[msg.sender];} // cast yes votes
        else {proposals[proposal].noVotes += balanceOf[msg.sender];} // cast no votes
        voted[msg.sender][proposal] = true; // reflect member voted
        
        emit SubmitVote(msg.sender, proposal, approve);
        return proposal;
    }
    
    /// @dev Process proposal and execute low-level call or membership management - proposal must exist, be unprocessed, and voting period must be finished
    /// @param proposal Number of proposal in `proposals` mapping to process for execution
    function processProposal(uint256 proposal) external nonReentrant returns (bool success, bytes memory retData) {
        require(processingReady(proposal), "Baal:: !ready for processing");
        require(proposals[proposal].membership == 0, "Baal:: membership proposal");
      
        bool _didPass = didPass(proposal);
        if (_didPass){
            (bool callSuccess, bytes memory returnData) = proposals[proposal].target.call{value: proposals[proposal].value}(proposals[proposal].data); // execute low-level call
            require(callSuccess, "Baal:: action failed");
            return (callSuccess, returnData); // return call success and data
        }
        
        proposals[proposal].processed = true; // reflect proposal processed
        emit ProcessProposal(proposal);
    }
    
    
    /// @dev Process proposal for membership management - proposal must exist, be unprocessed, and voting period must be finished
    /// @param proposal Number of proposal in `proposals` mapping to process for execution
    function processMemberProposal(uint256 proposal) external nonReentrant returns (uint256 shares) {
        require(processingReady(proposal), "Baal:: !ready for processing");
        require(proposals[proposal].membership == 1, "Baal:: !membership proposal");
        
        bool _didPass = didPass(proposal);
        if (_didPass) { // check if proposal approved by members
            address target = proposals[proposal].target;
            uint256 value = proposals[proposal].value;
                
            if(balanceOf[target] == 0) {memberList.push(target);} // update list of member accounts if new
                
            totalSupply += value; // add to total member votes
            balanceOf[target] += value; // add to member votes
            
            return(value);
        }
        
        proposals[proposal].processed = true; // reflect proposal processed
        emit ProcessMemberProposal(address(this), proposals[proposal].target, proposals[proposal].value, proposal); // event reflects mint of erc20 votes
    }
    
    function processMemberKick(uint256 proposal) external nonReentrant returns (bool success) {
        require(processingReady(proposal), "Baal:: !ready for processing");
        require(proposals[proposal].membership == 2 && proposals[proposal].data.length == 0, "Baal:: !membership kick proposal");

        bool _didPass = didPass(proposal);

        if (_didPass) {
            address target = proposals[proposal].target;
            uint256 balance = balanceOf[target];
                
            totalSupply -= balance; // subtract from total member votes
            balanceOf[target] = 0; // reset member votes
                
            return(true);
        }
        
        proposals[proposal].processed = true; // reflect proposal processed
        emit ProcessMemberKick(address(this), proposals[proposal].target, proposals[proposal].value, proposal); // event reflects mint of erc20 votes
    }
    
    function processNewContact(uint256 proposal) external nonReentrant returns (bool success) {
        require(processingReady(proposal), "Baal:: !ready for processing");
        require(proposals[proposal].membership == 3 && proposals[proposal].data.length == 0, "Baal:: !contact");

        bool _didPass = didPass(proposal);

        if (_didPass) {
            
            address target = proposals[proposal].target;
            contacts[target] = true;
            contactList.push(target);
            
            return(true);
        }
        
        proposals[proposal].processed = true; // reflect proposal processed
        
        emit ProcessMemberKick(address(this), proposals[proposal].target, proposals[proposal].value, proposal); // event reflects mint of erc20 votes
    }
    
    /// @dev Execute member action against external contract - caller must have votes
    /// @param target Account to call to trigger component transaction
    /// @param amount Number of member votes to involve in transaction
    /// @param mint Confirm whether transaction involves mint - if `false,` then perform balance-based burn
    function memberAction(address target, uint256 amount, bool mint) external nonReentrant {
        require(balanceOf[msg.sender] > 0, "!active");
        require(contractList[target], "!listed");  
        if (mint) {
            MemberAction(target).memberMint(msg.sender, amount);
            totalSupply += amount; // add to total member votes
            balanceOf[msg.sender] += amount; // add to member votes
            emit Transfer(address(this), msg.sender, amount); // event reflects mint of erc20 votes
        } else {    
            MemberAction(target).memberBurn(msg.sender, amount);
            totalSupply -= amount; // subtract from total member votes
            balanceOf[msg.sender] -= amount; // subtract member votes
            emit Transfer(address(this), address(0), amount); // event reflects burn of erc20 votes
        }
    }
    
     /// @dev Checks if proposal passed
    function didPass(uint256 proposal) internal view returns (bool) {
        require(proposals[proposal].yesVotes > proposals[proposal].noVotes, "Baal::proposal failed");
        return true;
    }
    
    /// @dev Checks if proposal is ready to be processed (allows for possible early execution)
    function processingReady(uint256 proposal) internal view returns (bool) {
        require(proposal <= proposalCount, "Baal::!exist");
        require(!proposals[proposal].processed, "Baal:: already processed");
        require(proposalCount == 1 || proposals[proposalCount-1].processed, "previous proposal must be processed");
        
        uint256 halfShares = totalSupply / 2;
        
        if(proposals[proposal].votingEnds >= block.timestamp){ // voting period done
            return true;
        } else if(proposals[proposal].yesVotes > halfShares ) { // early execution b/c of 50%+
            return true;
        } else {
            return false; //not ready
        }
    }
    
    /// @dev Return array list of member accounts in Baal
    function getMembers() external view returns (address[] memory membership) {
        return memberList;
    }
    
        /// @dev Return array list of member accounts in Baal
    function getContacts() external view returns (address[] memory allContacts) {
        return contactList;
    }
    
    /// @dev fallback to collect received ether into Baal
    receive() external payable {emit Receive(msg.sender, msg.value);}
}
