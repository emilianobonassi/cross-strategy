# @version ^0.2.8
"""
@title CurveMetaPoolCalculator
@author Emiliano Bonassi
@license N/A
@notice Helper Curve Contracts
"""

from vyper.interfaces import ERC20

interface Curve:
    def balances(i: uint256) -> uint256: view
    def fee() -> uint256: view
    def future_A_time() -> uint256: view
    def future_A() -> uint256: view
    def initial_A() -> uint256: view
    def initial_A_time() -> uint256: view

FEE_DENOMINATOR: constant(uint256) = 10 ** 10
PRECISION: constant(uint256) = 10 ** 18  # The precision to convert to
N_COINS: constant(int128) = 3
RATES: constant(uint256[N_COINS]) = [1000000000000000000, 1000000000000000000000000000000, 1000000000000000000000000000000]
LENDING_PRECISION: constant(uint256) = 10 ** 18

@view
@internal
def _xp(curve: address) -> uint256[N_COINS]:
    result: uint256[N_COINS] = RATES
    for i in range(N_COINS):
        result[i] = result[i] * Curve(curve).balances(i) / LENDING_PRECISION
    return result

@view
@internal
def _A(curve: address) -> uint256:
    """
    Handle ramping A up or down
    """
    t1: uint256 = Curve(curve).future_A_time()
    A1: uint256 = Curve(curve).future_A()

    if block.timestamp < t1:
        A0: uint256 = Curve(curve).initial_A()
        t0: uint256 = Curve(curve).initial_A_time()
        # Expressions in uint256 cannot have negative numbers, thus "if"
        if A1 > A0:
            return A0 + (A1 - A0) * (block.timestamp - t0) / (t1 - t0)
        else:
            return A0 - (A0 - A1) * (block.timestamp - t0) / (t1 - t0)

    else:  # when t1 == 0 or block.timestamp >= t1
        return A1

@pure
@internal
def get_D(xp: uint256[N_COINS], amp: uint256) -> uint256:
    S: uint256 = 0
    for _x in xp:
        S += _x
    if S == 0:
        return 0

    Dprev: uint256 = 0
    D: uint256 = S
    Ann: uint256 = amp * N_COINS
    for _i in range(255):
        D_P: uint256 = D
        for _x in xp:
            D_P = D_P * D / (_x * N_COINS)  # If division by 0, this will be borked: only withdrawal will work. And that is good
        Dprev = D
        D = (Ann * S + D_P * N_COINS) * D / ((Ann - 1) * D + (N_COINS + 1) * D_P)
        # Equality with the precision of 1
        if D > Dprev:
            if D - Dprev <= 1:
                break
        else:
            if Dprev - D <= 1:
                break
    return D

@view
@internal
def get_y(curve: address, i: int128, j: int128, x: uint256, xp_: uint256[N_COINS]) -> uint256:
    # x in the input is converted to the same price/precision

    assert i != j       # dev: same coin
    assert j >= 0       # dev: j below zero
    assert j < N_COINS  # dev: j above N_COINS

    # should be unreachable, but good for safety
    assert i >= 0
    assert i < N_COINS

    amp: uint256 = self._A(curve)
    D: uint256 = self.get_D(xp_, amp)
    c: uint256 = D
    S_: uint256 = 0
    Ann: uint256 = amp * N_COINS

    _x: uint256 = 0
    for _i in range(N_COINS):
        if _i == i:
            _x = x
        elif _i != j:
            _x = xp_[_i]
        else:
            continue
        S_ += _x
        c = c * D / (_x * N_COINS)
    c = c * D / (Ann * N_COINS)
    b: uint256 = S_ + D / Ann  # - D
    y_prev: uint256 = 0
    y: uint256 = D
    for _i in range(255):
        y_prev = y
        y = (y*y + c) / (2 * y + b - D)
        # Equality with the precision of 1
        if y > y_prev:
            if y - y_prev <= 1:
                break
        else:
            if y_prev - y <= 1:
                break
    return y

@view
@external
def get_dx(curve: address, i: int128, j: int128, dy: uint256) -> uint256:
    if dy == 0:
        return 0
    # dx and dy in c-units
    rates: uint256[N_COINS] = RATES
    xp: uint256[N_COINS] = self._xp(curve)

    y: uint256 = xp[j] - (dy * FEE_DENOMINATOR / (FEE_DENOMINATOR - Curve(curve).fee())) * rates[j] / PRECISION
    x: uint256 = self.get_y(curve, j, i, y, xp)
    dx: uint256 = (x - xp[i]) * PRECISION / rates[i]
    return dx

@view
@external
def get_dy(curve: address, i: int128, j: int128, dx: uint256) -> uint256:
    if dx == 0:
        return 0
    # dx and dy in c-units
    rates: uint256[N_COINS] = RATES
    xp: uint256[N_COINS] = self._xp(curve)

    x: uint256 = xp[i] + (dx * rates[i] / PRECISION)
    y: uint256 = self.get_y(curve, i, j, x, xp)
    dy: uint256 = (xp[j] - y - 1) * PRECISION / rates[j]
    _fee: uint256 = Curve(curve).fee() * dy / FEE_DENOMINATOR
    return dy - _fee