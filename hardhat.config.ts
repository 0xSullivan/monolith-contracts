import dotenv from 'dotenv';
import path from 'path';
import { HardhatUserConfig } from 'hardhat/config';
import 'hardhat-gas-reporter';
import 'hardhat-preprocessor';
import 'solidity-coverage';
import 'hardhat-contract-sizer';

import '@typechain/hardhat';
import '@nomiclabs/hardhat-etherscan';
import '@nomicfoundation/hardhat-chai-matchers';
import '@nomiclabs/hardhat-ethers';
import '@openzeppelin/hardhat-upgrades';



dotenv.config({ path: path.join(__dirname, './.env') });

const config: HardhatUserConfig = {
  defaultNetwork: 'hardhat',
  gasReporter: {
    currency: 'USD',
    enabled: true,
    excludeContracts: [],
    src: './contracts',
  },
  networks: {
    hardhat: {
      gas: 'auto',
    },
    local: {
      url: 'http://127.0.0.1:8545',
    },
    arbitrum: {
      url: process.env.ARBITRUM_RPC!,
      accounts: [
        process.env.DEPLOYER_PRIVATE_KEY!,
        process.env.SETTER_PRIVATE_KEY!
      ],
      gas: 'auto',
      gasPrice: 100_000_000,
      gasMultiplier: 1.2,
    },
  },
  solidity: {
    compilers: [
      {
        version: '0.8.16',
        settings: {
          // viaIR: true,
          metadata: {
            // Not including the metadata hash
            // https://github.com/paulrberg/solidity-template/issues/31
            bytecodeHash: 'none',
          },
          // Disable the optimizer when debugging
          // https://hardhat.org/hardhat-network/#solidity-optimizer-support
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
  etherscan: {
    apiKey: process.env.ARBITRUM_KEY!,
  },
};

export default config;
