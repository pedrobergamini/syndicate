const {expect, assert} = require("chai")

describe("Integration Test", function () {
  async function deployContract(name, ...args) {
    console.log(name, " being deployed");
    let Contract = await ethers.getContractFactory(name);
    console.log(name, " got artifact");
    let contract = await Contract.deploy(...args);
    console.log(name, " deployed at ", contract.address);
    return contract;
  }

  function normalize(val, n = 18) {
    return '' + val + '0'.repeat(n)
  }

  it("should verify that the entire process works", async function () {

    const maxTotalSupply = 10000000000; // 10 billions
    let [deployer, fundOwner, superAdmin, user1, user2, marketplace, treasury] = await ethers.getSigners();
    const SSYN = await ethers.getContractFactory("SyntheticSyndicateERC20");
    const ssyn = await SSYN.deploy(superAdmin.address);
    const SYN = await ethers.getContractFactory("SyndicateERC20");
    const syn = await SYN.deploy(fundOwner.address, maxTotalSupply, superAdmin.address);

    const Swapper = await ethers.getContractFactory("SynSwapper");
    const swapper = await Swapper.deploy(superAdmin.address, syn.address, ssyn.address);

    let features = (await syn.FEATURE_TRANSFERS_ON_BEHALF()) +
        (await syn.FEATURE_TRANSFERS()) +
        (await syn.FEATURE_UNSAFE_TRANSFERS()) +
        (await syn.FEATURE_DELEGATIONS()) +
        (await syn.FEATURE_DELEGATIONS_ON_BEHALF());
    await syn.updateFeatures(features)
    await syn.connect(fundOwner).transfer(user1.address, normalize(20000));
    expect((await syn.balanceOf(user1.address)) / 1e18).equal(20000);

    const PoolFactory = await ethers.getContractFactory("SyndicatePoolFactory");

    // deploy factory
    const poolFactory = await PoolFactory.deploy(syn.address, ssyn.address,
        normalize(990), // synPerBlock
        91252, // blockPerUpdate, decrease reward by 3%
        await ethers.provider.getBlockNumber(),
        await ethers.provider.getBlockNumber() + 7120725);

    const createPoolTx = await poolFactory.createPool(syn.address, await ethers.provider.getBlockNumber(), 1);
    await expect((await syn.userRoles(deployer.address)).toString()).equal('115792089237316195423570985008687907853269984665640564039457584007913129639935');
    await syn.connect(superAdmin).updateRole(deployer.address, 0);
    await expect((await syn.userRoles(deployer.address)).toString()).equal('0');

    const corePoolAddress = await poolFactory.getPoolAddress(syn.address);
    const SyndicateCorePool = await ethers.getContractFactory("SyndicateCorePool");
    const corePool = await SyndicateCorePool.attach(corePoolAddress);

    await ssyn.connect(superAdmin).updateRole(corePoolAddress, await syn.ROLE_TOKEN_CREATOR()); // 9
    await syn.connect(user1).approve(corePool.address, normalize(10000));
    expect((await syn.allowance(user1.address, corePool.address)) / 1e18).equal(10000);

    expect(await ssyn.balanceOf(user1.address)).equal(0);
    await corePool.connect(user1).stake(normalize(1000),
        (await ethers.provider.getBlock()).timestamp + 365 * 24 * 3600, true);
    expect((await ssyn.balanceOf(user1.address))).equal(0);

    await corePool.connect(user1).stake(normalize(1000),
        (await ethers.provider.getBlock()).timestamp + 365 * 24 * 3600, true);
    expect(await ssyn.balanceOf(user1.address)).equal('989999505000000000000')

    expect(await corePool.pendingYieldRewards(user1.address)).equal(0);
    await network.provider.send("evm_mine");

    expect((await corePool.pendingYieldRewards(user1.address)) / 1e18).equal(989.999505);
    await network.provider.send("evm_mine"); // 13
    expect((await corePool.pendingYieldRewards(user1.address)) / 1e18).equal(1979.99901);

    expect((await syn.balanceOf(user1.address)) / 1e18).equal(18000);
    await network.provider.send("evm_increaseTime", [366 * 24 * 3600])
    await network.provider.send("evm_mine")
    await corePool.connect(user1).processRewards(true);

    let unstakeTx = await corePool.connect(user1).unstake(0, normalize(500), true);
    expect((await syn.balanceOf(user1.address)) / 1e18).equal(18500);
    expect((await ssyn.balanceOf(user1.address)) / 1e18).equal(5939.9970299999995);
    await corePool.connect(user1).processRewards(true);
    await syn.connect(fundOwner).delegate(fundOwner.address);
    expect((await syn.balanceOf(fundOwner.address)) / 1e18).equal(6999980000);
    expect((await syn.getVotingPower(fundOwner.address)) / 1e18).equal(6999980000);
    expect((await syn.getVotingPower(user1.address)) / 1e18).equal(0);
    await corePool.delegate(user1.address);
    await expect((await syn.getVotingPower(user1.address)) / 1e18).equal(1500);

    await expect(ssyn.connect(user1).transfer(marketplace.address, normalize(10000))).revertedWith("sSYN: Non Allowed Receiver");
    await ssyn.connect(superAdmin).updateRole(marketplace.address, await ssyn.ROLE_WHITE_LISTED_RECEIVER());
    await ssyn.connect(user1).transfer(marketplace.address, normalize(1000));
    expect((await ssyn.balanceOf(marketplace.address)) / 1e18).equal(1000);

    features =
        (await syn.FEATURE_TRANSFERS()) + (await syn.FEATURE_UNSAFE_TRANSFERS() + (await syn.FEATURE_DELEGATIONS())
            + (await syn.FEATURE_DELEGATIONS_ON_BEHALF()));
    await syn.connect(superAdmin).updateFeatures(features)
    await expect(syn.connect(user1).approve(marketplace.address, normalize(5000))).revertedWith("SYN: spender not allowed");
    await syn.connect(superAdmin).updateRole(marketplace.address, await syn.ROLE_WHITE_LISTED_SPENDER());
    await syn.connect(user1).approve(marketplace.address, normalize(5000));
    await syn.connect(marketplace).transferFrom(user1.address, user2.address, normalize(5000));
    expect((await syn.balanceOf(user2.address)) / 1e18).equal(5000);

    // swaps

    // allows treasury to be the receiver of the swap
    await ssyn.connect(superAdmin).updateRole(treasury.address, await ssyn.ROLE_WHITE_LISTED_RECEIVER());
    await syn.connect(superAdmin).updateRole(treasury.address, await syn.ROLE_TREASURY());

    // allows swapper to do the swap
    await ssyn.connect(superAdmin).updateRole(swapper.address, await ssyn.ROLE_TOKEN_DESTROYER());
    await syn.connect(superAdmin).updateRole(swapper.address, await syn.ROLE_TOKEN_CREATOR());

    await ssyn.connect(marketplace).transfer(treasury.address, normalize(1000));

    let ssynAmount = await ssyn.balanceOf(treasury.address)
    expect(ssynAmount/ 1e18).equal(1000);
    await swapper.connect(superAdmin).swap(treasury.address, ssynAmount)
    expect((await ssyn.balanceOf(treasury.address)) / 1e18).equal(0);
    expect((await syn.balanceOf(treasury.address)) / 1e18).equal(1000);

  })

})
