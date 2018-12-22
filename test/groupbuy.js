const util = require('util');
const crypto = require('crypto');
const { expect } = require('chai');

const Groupbuy = artifacts.require('Groupbuy');

function epoch() {
    return Math.floor(Date.now() / 1000);
}

function dump(object) {
    console.log(util.inspect(object, false, null, true));
}

contract('Groupbuy', (accounts) => {
    const OWNER = accounts[0];
    const MIN_FUNDING_WINDOW = 60 * 60 * 24 * 3; // 3 days
    const MIN_ORDERING_WINDOW = 60 * 60 * 24 * 5; // 5 days
    const PRODUCT_1 = '0x' + crypto.createHash('sha256').update('product_1').digest('hex');
    const PRODUCT_2 = '0x' + crypto.createHash('sha256').update('product_2').digest('hex');

    let groupbuy;

    beforeEach(async () => {
        groupbuy = await Groupbuy.new(
            MIN_FUNDING_WINDOW,
            MIN_ORDERING_WINDOW,
            {
                from: OWNER
            }
        );
    });

    it('should be able to initiate a new drop', async () => {
        const price = 10000;
        const minAmount = 500;
        const fundingDeadline = epoch() + MIN_FUNDING_WINDOW * 2;
        const orderingDeadline = fundingDeadline + MIN_ORDERING_WINDOW * 2;

        const result = await groupbuy.initiate(
            PRODUCT_1, // product identifier
            price,  // price
            minAmount,    // minimum amount
            fundingDeadline,
            orderingDeadline,
            {
                from: OWNER
            }
        );

        dump(result);

        const drop = await groupbuy.drops(PRODUCT_1);

        expect(drop.price.toNumber()).to.equal(price);
        expect(drop.minAmount.toNumber()).to.equal(minAmount);
        expect(drop.fundingDeadline.toNumber()).to.equal(fundingDeadline);
        expect(drop.orderingDeadline.toNumber()).to.equal(orderingDeadline);
        expect(drop.raised.toNumber()).to.equal(0);
        expect(drop.canceled).to.be.false;
        expect(drop.settled).to.be.false;
    });
});
