const hre = require("hardhat");

const NETWORK_CONFIG = {
  bscTestnet: {
    label: "BSC Testnet",
    router: "0x1b81D678ffb9C0263b24A97847620C99d213eB14",
    quoter: "0xbC203d7f83677c7ed3F7acEc959963E7F4ECC5C2",
  },
  bscMainnet: {
    label: "BSC Mainnet",
    router: "0x13f4EA83D0bd40E75C8222255bc855a974568Dd4",
    quoter: "0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997",
  },
};

async function main() {
  const networkName = hre.network.name;
  const networkConfig = NETWORK_CONFIG[networkName];

  if (networkConfig === undefined) {
    throw new Error(
      `Unsupported network "${networkName}". Use --network bscTestnet or --network bscMainnet.`,
    );
  }

  const [deployer] = await hre.ethers.getSigners();

  if (deployer === undefined) {
    throw new Error("No deployer account found. Set PRIVATE_KEY in your environment.");
  }

  const feeRecipient = process.env.FEE_RECIPIENT || deployer.address;
  const feeBps = BigInt(process.env.FEE_BPS || "30");

  console.log(`Network: ${networkConfig.label} (${networkName})`);
  console.log("Deployer:", deployer.address);
  console.log("Router:", networkConfig.router);
  console.log("Quoter:", networkConfig.quoter);
  console.log("Fee recipient:", feeRecipient);
  console.log("Fee bps:", feeBps.toString());

  const Swapper = await hre.ethers.getContractFactory("PancakeSwapV3Swapper");
  const swapper = await Swapper.deploy(
    networkConfig.router,
    networkConfig.quoter,
    feeRecipient,
    feeBps
  );

  await swapper.waitForDeployment();

  const contractAddress = await swapper.getAddress();
  const deploymentTx = swapper.deploymentTransaction();

  console.log("Deployment tx:", deploymentTx?.hash ?? "unavailable");
  console.log("PancakeSwapV3Swapper deployed to:", contractAddress);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
