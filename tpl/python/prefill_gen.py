import sys
c = open(sys.argv[1], encoding="utf-8").read()
n = (100000 * 4 + len(c) - 1) // len(c)
open(sys.argv[2], "w", encoding="utf-8").write((c + "\n") * n)
