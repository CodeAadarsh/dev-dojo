# First Assertions

## The setup

A teammate shipped a tiny `Account` class. It looks fine. It has **no tests**. Your job is not to change the code — it's to *pin it down* with a test suite so that the next person who touches `Account` can't silently break it.

This challenge grades your tests the only honest way: it runs them against the correct `Account`, then against several **buggy versions** of `Account` with one thing broken in each. A good test suite does two things at once:

- **Passes** on the correct code.
- **Fails** on every broken version (it *catches* the bug).

A suite that passes on everything — correct or broken — is worthless, and the verifier will tell you so. This is exactly how real test quality is measured (it's called mutation testing). Weak, vague assertions get exposed immediately.

## The code under test

`setup.sh` plants this into your work directory as `bank.py` (you can read it):

```python
class Account:
    def __init__(self, balance=0):
        if balance < 0:
            raise ValueError("initial balance cannot be negative")
        self.balance = balance

    def deposit(self, amount):
        if amount <= 0:
            raise ValueError("deposit must be positive")
        self.balance += amount
        return self.balance

    def withdraw(self, amount):
        if amount <= 0:
            raise ValueError("withdrawal must be positive")
        if amount > self.balance:
            raise ValueError("insufficient funds")
        self.balance -= amount
        return self.balance
```

## The spec (what your tests must pin down)

1. A new `Account()` starts at balance `0`; `Account(100)` starts at `100`.
2. Creating an account with a **negative** balance raises `ValueError`.
3. `deposit(amount)` increases the balance and **returns the new balance**.
4. `deposit` with an amount `<= 0` raises `ValueError`.
5. `withdraw(amount)` decreases the balance and **returns the new balance**.
6. `withdraw` with an amount `<= 0` raises `ValueError`.
7. `withdraw` of **more than the balance** raises `ValueError` (no overdraft).

## Your mission

Write tests in `test_bank.py` (a starter is planted for you). Use:

- **Arrange–Act–Assert** structure.
- Specific equality assertions (`assert account.balance == 70`), not vague truthiness.
- `pytest.raises(ValueError)` for every rule that must reject bad input.

Then run the verifier. It passes only when your suite passes on the correct `Account` **and** catches every planted bug.

## Verify & flag

```bash
bash courses/course-36-python-testing/challenges/01-first-assertions/setup.sh
# ... write your tests in ~/.kube-dojo-work/01-first-assertions/test_bank.py ...
bash courses/course-36-python-testing/challenges/01-first-assertions/verify.sh
```

The flag has the form `KUBE{...}` and is printed when every check passes.
