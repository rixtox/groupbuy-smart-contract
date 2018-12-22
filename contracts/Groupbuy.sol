pragma solidity ^0.5.0;

/*
                        Groupbuy Smart Contract
                             State-Machine

        +-------------+                         +--------------+
        |   Funding   |                         |   Ordering   |
        +=============+     raised >= price     +==============+
        |   - fund    | ----------------------> | - settleUp   |
        +-------------+                         +--------------+
        | - withdraw  |                         |  - cancel    |
        +-------------+  settleUp() not called  +--------------+
        |  - cancel   |        or cancel()            /|
        +-------------+                   \          / |
               |                           \        /  | settleUp()
               | raised < price             \      /   | called
               | or cancel()                 \    /    |
               |                              \  /     |
               v                               \/      v
        +--------------+                       / +-------------+
        |   Canceled   | <--------------------/  |   Settled   |
        +--------------+                         +-------------+
*/

contract Groupbuy {

    struct Drop {
        // Minimum price goal to be raised; Maximum amount
        // the owner is able to withdraw in the settlement
        uint price;

        // minimum amount to join
        uint minAmount;

        // Close time of the funding
        uint fundingDeadline;

        // Due time of the settlement
        uint orderingDeadline;

        // Cumulative fund raised
        uint raised;

        // Founder provides proof in the settlement.
        // It's the SHA-256 hash of some evidece of the order.
        bytes32 proof;

        // Funder set this field to cancel the drop.
        bool canceled;

        // Funder set this field to settle the drop.
        bool settled;

        // Record the address of all funders
        address payable[] funders;

        // Record amount received from all funders
        uint256[] funds;
    }

    enum State {
        Funding,
        Ordering,
        Settled,
        Canceled
    }

    // Person who creates the contract, and manages the drops
    address payable public owner;

    // Minimum time from drop creation to end of funding
    uint public minFundingWindow;

    // Minimum time from end of funding to end of ordering
    uint public minOrderingWindow;

    // List of ongoing drops. the key is the SHA-256 of product description.
    // The format of the description is irrelevant to the contract, but
    // generally it should include product name and listing url.
    mapping(bytes32 => Drop) public drops;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier dropExists(bytes32 product) {
        require(drops[product].price > 0, "Drop doesn't exist");
        _;
    }

    constructor(uint _minFundingWindow, uint _minOrderingWindow) public {
        owner = msg.sender;
        minFundingWindow = _minFundingWindow;
        minOrderingWindow = _minOrderingWindow;
    }

    function getState(bytes32 product)
        internal
        view
        returns (State)
    {
        Drop memory drop = drops[product];

        // Cancel the drop in owner's request
        if (drop.canceled) {
            return State.Canceled;
        }

        if (now < drop.fundingDeadline) {
            return State.Funding;
        }

        // Cancel the drop when raised less than the price
        if (drop.raised < drop.price) {
            return State.Canceled;
        }

        if (now < drop.orderingDeadline) {
            return State.Ordering;
        }

        // Cancel the drop if owner didn't call
        // settleUp before ordering deadline.
        if (!drop.settled) {
            return State.Canceled;
        }

        return State.Settled;
    }

    // Funders can fund a drop before the funding deadline.
    function fund(bytes32 product)
        public
        payable
        dropExists(product)
    {
        Drop memory drop = drops[product];
        require(getState(product) == State.Funding, "Unexpected state");

        uint i;
        for (i = 0; i < drop.funders.length; i++) {
            if (drop.funders[i] == msg.sender) {
                break;
            }
        }

        if (i == drop.funders.length) {
            drop.funders[i] = msg.sender;
        }

        require(drop.funds[i] + msg.value >= drop.minAmount, "Less than minimum amount");

        drop.funds[i] += msg.value;
        drop.raised += msg.value;
    }

    // Funder can withdraw funds from a drop before the funding deadline.
    function withdraw(bytes32 product, uint256 amount)
        public
        dropExists(product)
        returns (bool)
    {
        Drop storage drop = drops[product];
        require(getState(product) == State.Funding, "Unexpected state");

        uint i;
        for (i = 0; i < drop.funders.length; i++) {
            if (drop.funders[i] == msg.sender) {
                break;
            }
        }

        require(i < drop.funders.length, "Not a funder");
        require(amount <= drop.funds[i], "Amount exceeds funds");

        // Leave drop, refund all
        if (drop.funds[i] == amount) {
            drop.funders[i].transfer(amount);
            drop.raised -= amount;
            delete drop.funds[i];
            delete drop.funders[i];
        } else {
            // Make sure remaining funds still satisfy minimum amount
            require(drop.funds[i] - amount >= drop.minAmount, "Remaining funds less than minimum amount");
            drop.funders[i].transfer(amount);
            drop.raised -= amount;
        }

        return true;
    }

    // Founder can initiate a new drop at any time.
    function initiate(
        bytes32 product, uint price, uint minAmount,
        uint fundingDeadline, uint orderingDeadline
    )
        public
        onlyOwner()
        returns (bool)
    {
        Drop storage drop = drops[product];
        require(price > 0, "Price not set");
        require(drop.price == 0, "Drop exists");
        require(fundingDeadline > now + minFundingWindow, "Funding window is too small");
        require(orderingDeadline > fundingDeadline, "Ordering deadline is before funding deadline");
        require(orderingDeadline - fundingDeadline > minOrderingWindow, "Ordering window is too small");
        drop.price = price;
        drop.minAmount = minAmount;
        drop.fundingDeadline = fundingDeadline;
        drop.orderingDeadline = orderingDeadline;
        return true;
    }

    // Founder can only cancel a drop at funding and ordering state.
    // Raised funds will be refunded.
    function cancel(bytes32 product)
        public
        onlyOwner()
        dropExists(product)
    {
        State state = getState(product);
        require(state == State.Funding || state == State.Ordering, "Unexpected state");

        Drop storage drop = drops[product];

        // Refund
        for (uint i = drop.funders.length; i-- > 0;) {
            drop.funders[i].transfer(drop.funds[i]);
            delete drop.funds[i];
            delete drop.funders[i];
        }

        // Cancel drop
        drop.raised = 0;
        drop.canceled = true;
    }

    // Founder can settle up the drop before ordering deadline.
    // A proof of the expenditure is provided by the owner.
    function settleUp(bytes32 product, bytes32 proof, uint32 spent)
        public
        onlyOwner()
        dropExists(product)
        returns (bool)
    {
        Drop storage drop = drops[product];
        require(getState(product) == State.Ordering, "Unexpected state");
        require(spent <= drop.price, "Founder can't spend more than the product price");

        uint256 balance = drop.raised;
        owner.transfer(spent);
        balance -= spent;

        // Charge funders in weight of their funds, then refund their balance.
        for (uint i = drop.funders.length; i-- > 0;) {
            uint256 share = spent * drop.funds[i] / drop.raised;
            uint256 refund;

            if (share > drop.funds[i]) {
                refund = 0;
            } else {
                refund = drop.funds[i] - share;
            }

            if (balance < refund) {
                refund = balance;
            }

            drop.funders[i].transfer(refund);
            delete drop.funds[i];
            delete drop.funders[i];
        }

        drop.raised = 0;
        drop.proof = proof;
        drop.settled = true;
    }
}
