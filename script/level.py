#!/usr/bin/env python3
"""Namaran difficulty draw.

A local and CI authoring aid like script/odai.py (never deployed). Draws a
difficulty for each LANG/TYPE combo, so that the namaran-daily skill writes
each drill to a level chosen for it, not one it picked itself. A model asked
to "pick at random" drifts toward the middle and toward what it wrote last;
a script does neither, and its pick shows up verbatim in the workflow log.

Usage:
  script/level.py [LANG/TYPE ...]

  LANG/TYPE pairs default to all 15 (5 languages x 3 exercise types).

The four levels are animals, not stars (doc/requirements.md §7):

  hedgehog   ハリネズミ   基礎   44.7%
  peacock    孔雀         標準   27.6%
  bison      バイソン     高度   17.1%
  whale      クジラ       特級   10.6%

Each probability is the one above it divided by the golden ratio, and the
four add up to 100%: φ^0 + φ^-1 + φ^-2 + φ^-3 = √5, so level k comes up
with probability φ^-k / √5.

Every combo is drawn on its own, and nothing looks at what earlier days
drew. A day of fifteen whales is a legitimate outcome and is published as
such: the distribution holds over time, not within a day, and evening it
out by hand would make the draw mean nothing.

Output: one line per combo, "LANG/TYPE<TAB>LEVEL", in the order given.
"""

import secrets
import sys

from namaran import LEVELS, parse_combos, wants_help

# Per mille, so the draw is exact integer arithmetic: 447 + 276 + 171 + 106.
WEIGHTS = dict(zip(LEVELS, (447, 276, 171, 106)))


def draw():
    roll = secrets.randbelow(sum(WEIGHTS.values()))
    for level, weight in WEIGHTS.items():
        if roll < weight:
            return level
        roll -= weight
    raise AssertionError("unreachable")


def main(args):
    wants_help(args)
    for lang, typ in parse_combos(args):
        print(f"{lang}/{typ}\t{draw()}")


if __name__ == "__main__":
    main(sys.argv[1:])
