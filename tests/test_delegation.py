import brownie
from brownie import Contract
from brownie import config
import math
from eth_abi import encode_single


def test_delegation(gov, token, vault, strategist, whale, strategy, chain, amount):
    ## set our delegate address
    strategy.setCvxDelegate(whale, {"from": gov})
    delegation_contract = Contract("0x469788fE6E9E9681C6ebF3bF78e7Fd26Fc015446")
    hex_string = encode_single("bytes32", b"cvx.eth")
    delegate = delegation_contract.delegation(strategy, hex_string)
    assert delegate == whale  # check that we delegated our funds to our whale friend
