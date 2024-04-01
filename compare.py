#!/usr/bin/env python3

import sys
import itertools

if len(sys.argv) < 3:
	exit("usage: compare.py CSV_FILE_1 CSV_FILE_2 [--show]")

def read_my_file(file):
    with open(file, "r") as fin:
        data = fin.read()
        return data

f1_name = sys.argv[1]
f2_name = sys.argv[2]

f1 = read_my_file(f1_name).strip()
f2 = read_my_file(f2_name).strip()

f1 = f1.splitlines()
f2 = f2.splitlines()

f1 = f1[17:]
f2 = f2[17:]

f1.sort()
f2.sort()

common = [x for x in f1 if x in f2]
unique_f1 = [x for x in f1 if x not in common]
unique_f2 = [x for x in f2 if x not in common]
unique = itertools.zip_longest(unique_f1, unique_f2, fillvalue='---')


print(f'{f1_name}: {len(f1)} (total) {len(unique_f1)} (unique)')
print(f'{f2_name}: {len(f2)} (total) {len(unique_f2)} (unique)')
print(f'Frags in common: {len(common)}')
print('~~~')

if len(sys.argv) == 4 and sys.argv[3] == '--show':
	print(f'{f1_name} unique frags : {f2_name} unique frags')
	for x, y in unique:
		print(f'{x} ::: {y}')