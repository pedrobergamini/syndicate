require('dotenv').config()
const hre = require("hardhat");
const ethers = hre.ethers

const DeployUtils = require('./lib/DeployUtils')
let deployUtils

async function main() {
  deployUtils = new DeployUtils(ethers)
  const chainId = await deployUtils.currentChainId()
  let [, , localSuperAdmin] = await ethers.getSigners();

  const network = chainId === 1 ? 'ethereum'
      : chainId == 42 ? 'kovan'
          : 'localhost'

  const superAdmin = chainId === '1337'
      ? localSuperAdmin.address
      : process.env.SUPER_ADMIN

  console.log('Deploying EscrowedSyndicateERC20...')
  const SSYN = await ethers.getContractFactory("EscrowedSyndicateERC20")
  const ssyn = await SSYN.deploy(superAdmin)
  await ssyn.deployed()

  console.log(`
To verify EscrowedSyndicateERC20 source code:
    
  npx hardhat verify --show-stack-traces \\
      --network ${network} \\
      ${ssyn.address}  \\
      ${superAdmin.address}
      
`)

  console.log('EscrowedSyndicateERC20 deployed at', ssyn.address)
  await deployUtils.saveDeployed(chainId, ['EscrowedSyndicateERC20'], [ssyn.address])
}

main()
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error);
      process.exit(1);
    });
