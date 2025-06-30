// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import "./PropToken.sol" as PT;
import "./PropVault.sol" as PV;

/**
 * @title CrossChainManager
 * @dev Manages cross-chain operations using Chainlink CCIP
 */
contract CrossChainManager is CCIPReceiver, Ownable, ReentrancyGuard {
    struct CrossChainTransfer {
        uint256 propertyId;
        address from;
        address to;
        uint256 amount;
        uint64 sourceChainSelector;
        uint64 destinationChainSelector;
        bytes32 messageId;
        bool completed;
    }
    
  PT.PropToken public propertyToken;
  PV.PropVault public propertyVault;

    
    mapping(bytes32 => CrossChainTransfer) public crossChainTransfers;
    mapping(uint64 => address) public trustedRemotes;
    mapping(uint64 => bool) public supportedChains;
    
    uint256 public transferCounter;
    
    event CrossChainTransferInitiated(
        bytes32 indexed messageId,
        uint256 indexed propertyId,
        address indexed from,
        address to,
        uint256 amount,
        uint64 destinationChain
    );
    
    event CrossChainTransferCompleted(
        bytes32 indexed messageId,
        uint256 indexed propertyId,
        address indexed to,
        uint256 amount
    );
    
    event TrustedRemoteSet(uint64 indexed chainSelector, address remote);
    
    constructor(
        address _router, 
        address _propertyToken, 
        address _propertyVault,
        address initialOwner
    ) 
        CCIPReceiver(_router) 
        Ownable(initialOwner)
    {
        propertyToken = PT.PropToken(_propertyToken);
        propertyVault = PV.PropVault(payable(_propertyVault));
    }
    
    /**
     * @dev Get CCIP fee for cross-chain transfer
     */
    function getCCIPFee(
        uint64 _destinationChainSelector,
        uint256 _propertyId,
        address _to,
        uint256 _amount
    ) external view returns (uint256 fee) {
        require(supportedChains[_destinationChainSelector], "Unsupported destination chain");
        require(trustedRemotes[_destinationChainSelector] != address(0), "No trusted remote");
        
        // Prepare CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(trustedRemotes[_destinationChainSelector]),
            data: abi.encode(_propertyId, msg.sender, _to, _amount, transferCounter),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 300000})),
            feeToken: address(0) // Pay in native token
        });
        
        // Get fee
        fee = IRouterClient(getRouter()).getFee(_destinationChainSelector, message);
    }
    
    /**
     * @dev Initiate cross-chain token transfer
     */
    function initiateCrossChainTransfer(
        uint256 _propertyId,
        address _to,
        uint256 _amount,
        uint64 _destinationChainSelector
    ) external payable nonReentrant returns (bytes32 messageId) {
        require(supportedChains[_destinationChainSelector], "Unsupported destination chain");
        require(trustedRemotes[_destinationChainSelector] != address(0), "No trusted remote");
        require(propertyToken.balanceOf(msg.sender, _propertyId) >= _amount, "Insufficient balance");
        
        // Lock tokens on source chain
        propertyToken.safeTransferFrom(msg.sender, address(this), _propertyId, _amount, "");
        
        // Prepare CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(trustedRemotes[_destinationChainSelector]),
            data: abi.encode(_propertyId, msg.sender, _to, _amount, transferCounter++),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 300000})),
            feeToken: address(0) // Pay in native token
        });
        
        // Get fee and check payment
        uint256 fee = IRouterClient(getRouter()).getFee(_destinationChainSelector, message);
        require(msg.value >= fee, "Insufficient fee payment");
        
        // Send CCIP message
        messageId = IRouterClient(getRouter()).ccipSend{value: fee}(
            _destinationChainSelector,
            message
        );
        
        // Return excess payment
        if (msg.value > fee) {
            payable(msg.sender).transfer(msg.value - fee);
        }
        
        // Store transfer details
        crossChainTransfers[messageId] = CrossChainTransfer({
            propertyId: _propertyId,
            from: msg.sender,
            to: _to,
            amount: _amount,
            sourceChainSelector: 0, // Will be set by the destination
            destinationChainSelector: _destinationChainSelector,
            messageId: messageId,
            completed: false
        });
        
        emit CrossChainTransferInitiated(messageId, _propertyId, msg.sender, _to, _amount, _destinationChainSelector);
        
        return messageId;
    }
    
    /**
     * @dev Handle incoming cross-chain message
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        bytes32 messageId = message.messageId;
        uint64 sourceChainSelector = message.sourceChainSelector;
        
        require(trustedRemotes[sourceChainSelector] != address(0), "Untrusted source chain");
        require(
            abi.decode(message.sender, (address)) == trustedRemotes[sourceChainSelector],
            "Untrusted sender"
        );
        
        // Decode message data
        (uint256 propertyId, address from, address to, uint256 amount, uint256 transferId) = 
            abi.decode(message.data, (uint256, address, address, uint256, uint256));
        
        // Mint tokens on destination chain
        propertyToken.mint(to, propertyId, amount, "");
        
        // Record completed transfer
        crossChainTransfers[messageId] = CrossChainTransfer({
            propertyId: propertyId,
            from: from,
            to: to,
            amount: amount,
            sourceChainSelector: sourceChainSelector,
            destinationChainSelector: 0,
            messageId: messageId,
            completed: true
        });
        
        emit CrossChainTransferCompleted(messageId, propertyId, to, amount);
    }
    
    /**
     * @dev Set trusted remote for a chain
     */
    function setTrustedRemote(uint64 _chainSelector, address _remote) external onlyOwner {
        trustedRemotes[_chainSelector] = _remote;
        supportedChains[_chainSelector] = true;
        emit TrustedRemoteSet(_chainSelector, _remote);
    }
    
    /**
     * @dev Remove trusted remote for a chain
     */
    function removeTrustedRemote(uint64 _chainSelector) external onlyOwner {
        delete trustedRemotes[_chainSelector];
        supportedChains[_chainSelector] = false;
    }
    
    /**
     * @dev Get cross-chain transfer details
     */
    function getCrossChainTransfer(bytes32 _messageId) external view returns (CrossChainTransfer memory) {
        return crossChainTransfers[_messageId];
    }
    
    /**
     * @dev Check if chain is supported
     */
    function isChainSupported(uint64 _chainSelector) external view returns (bool) {
        return supportedChains[_chainSelector];
    }
    
    /**
     * @dev Get trusted remote for a chain
     */
    function getTrustedRemote(uint64 _chainSelector) external view returns (address) {
        return trustedRemotes[_chainSelector];
    }
    
    /**
     * @dev Emergency withdraw locked tokens
     */
    function emergencyWithdraw(uint256 _propertyId, uint256 _amount) external onlyOwner {
        propertyToken.safeTransferFrom(address(this), owner(), _propertyId, _amount, "");
    }
    
    /**
     * @dev Emergency withdraw native tokens
     */
    function emergencyWithdrawNative(uint256 _amount) external onlyOwner {
        require(address(this).balance >= _amount, "Insufficient balance");
        payable(owner()).transfer(_amount);
    }
    
    /**
     * @dev Update property token contract
     */
    function updatePropertyToken(address _newPropertyToken) external onlyOwner {
        propertyToken = PT.PropToken(_newPropertyToken);
    }
    
    /**
     * @dev Update property vault contract
     */
    function updatePropertyVault(address _newPropertyVault) external onlyOwner {
        propertyVault = PV.PropVault(payable(_newPropertyVault));
    }
    
    /**
     * @dev Receive function to accept Ether for CCIP fees
     */
    receive() external payable {}
}