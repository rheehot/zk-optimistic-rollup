const Poseidon = artifacts.require('Poseidon');
const ZkOPRU = artifacts.require('ZkOptimisticRollUp');

module.exports = function(deployer, _, accounts) {
  deployer.link(Poseidon, ZkOPRU);
  deployer.deploy(ZkOPRU, accounts[0]);
};
