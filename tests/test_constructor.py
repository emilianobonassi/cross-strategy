import pytest
import brownie
from brownie import Wei
from brownie import config


def test_double_init(strategy, strategist):
    with brownie.reverts("Strategy already initialized"):
        strategy.init(
            strategist,
            strategist,
            strategist,
            strategist,
            strategist,
            strategist
        )


def test_double_init_no_proxy(strategyDeployer, vault, strategist):
    strategy = strategyDeployer(vault, False)
    with brownie.reverts("Strategy already initialized"):
        strategy.init(
            strategist,
            strategist,
            strategist,
            strategist,
            strategist,
            strategist
        )
