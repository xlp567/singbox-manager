"""Shared cancellation boundary; never confuse a cancelled form with a failure."""


class Cancelled(Exception):
    """A deliberate cancellation or end of interactive input."""


def check_cancel(value):
    if value.strip() == '/cancel':
        raise Cancelled()
    return value


def read_input(label):
    return check_cancel(input(label))
