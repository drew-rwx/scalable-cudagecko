#!/usr/bin/env python3

import matplotlib.pyplot as plt
import matplotlib.lines as lines
import numpy as np
import statistics

# constants
RUNS = 3
MAX_GPUS = 3
BYTE_COUNT = 3273481150 * 2217921712

def read_my_file(file):
    with open(file, "r") as fin:
        data = fin.read()
        return data

def write_my_file(file, data):
    # make data writable
    write_data = []
    for d in data:
        write_data.append(str(d) + "\n")

    # write the data
    with open(file, "w") as fout:
        fout.writelines(write_data)

data = read_my_file("../tacc_scripts/medium.out")
data = data.split("~~~")

baseline_data = data[0]
baseline_data = baseline_data.splitlines()
baseline_times = []

for r in range(RUNS):
    time = baseline_data[r * 3]
    time = time.split()[-1]
    m, _, s = time.partition('m')
    s = s[0:-1]

    m = float(m) * 60
    s = float(s)

    time = m + s
    baseline_times.append(time)

baseline_time = statistics.mean(baseline_times)
print(f"Baseline run time (s): {baseline_time:.2f}")

gpu_1_data = data[1]
gpu_1_data = gpu_1_data.splitlines()
gpu_1_data = gpu_1_data[1:]
gpu_1_times = []

for r in range(RUNS):
    time = gpu_1_data[r * 3]
    time = time.split()[-1]
    m, _, s = time.partition('m')
    s = s[0:-1]

    m = float(m) * 60
    s = float(s)

    time = m + s
    gpu_1_times.append(time)

gpu_1_time = statistics.mean(gpu_1_times)
print(f"1 GPU run time (s): {gpu_1_time:.2f}")

gpu_2_data = data[2]
gpu_2_data = gpu_2_data.splitlines()
gpu_2_data = gpu_2_data[1:]
gpu_2_times = []

for r in range(RUNS):
    time = gpu_2_data[r * 3]
    time = time.split()[-1]
    m, _, s = time.partition('m')
    s = s[0:-1]

    m = float(m) * 60
    s = float(s)

    time = m + s
    gpu_2_times.append(time)

gpu_2_time = statistics.mean(gpu_2_times)
print(f"2 GPU run time (s): {gpu_2_time:.2f}")

gpu_3_data = data[3]
gpu_3_data = gpu_3_data.splitlines()
gpu_3_data = gpu_3_data[1:]
gpu_3_times = []

for r in range(RUNS):
    time = gpu_3_data[r * 3]
    time = time.split()[-1]
    m, _, s = time.partition('m')
    s = s[0:-1]

    m = float(m) * 60
    s = float(s)

    time = m + s
    gpu_3_times.append(time)

gpu_3_time = statistics.mean(gpu_3_times)
print(f"3 GPU run time (s): {gpu_3_time:.2f}")

#
# make figures
#

SHOW_FIGURES = True
BLOCK_ON_SHOW = False

# throughput

# set font
plt.rcParams['font.family'] = 'serif'
plt.rcParams['font.serif'] = ['CMU Serif']

fig, ax = plt.subplots(figsize=(5, 5))

baseline_thp = BYTE_COUNT / baseline_time / 1000 / 1000 / 1000 / 1000
gpu_1_thp = BYTE_COUNT / gpu_1_time / 1000 / 1000 / 1000 / 1000
gpu_2_thp = BYTE_COUNT / gpu_2_time / 1000 / 1000 / 1000 / 1000
gpu_3_thp = BYTE_COUNT / gpu_3_time / 1000 / 1000 / 1000 / 1000

print(f"Baseline: {baseline_thp:.2f} Tera-monomers/s")
print(f"1 GPU: {gpu_1_thp:.2f} Tera-monomers/s")
print(f"2 GPU: {gpu_2_thp:.2f} Tera-monomers/s")
print(f"3 GPU: {gpu_3_thp:.2f} Tera-monomers/s")


ax.bar(1, baseline_thp, 0.2, label='Original', color='red')
ax.bar(2, gpu_1_thp, 0.2, label='1 GPU', color='blue')
ax.bar(3, gpu_2_thp, 0.2, label='2 GPU', color='blue')
ax.bar(4, gpu_3_thp, 0.2, label='3 GPU', color='blue')

plt.yticks(np.arange(0, 56001, 2000))

ax.set_xlabel("Program Version", fontsize=12)
ax.set_ylabel("Throughput (Tera-monomers/s)", fontsize=12)

# y: size of numbers, x: remove ticks
ax.tick_params(axis='y', labelsize=10)
ax.tick_params(axis='x', length=0, labelsize=0)

# legend
ax.legend()

# grid lines
ax.yaxis.grid(True, linestyle='--', linewidth=0.5)
ax.set_axisbelow(True)

# title
plt.title("Throughput—Medium")

plt.tight_layout()
plt.savefig("../figures/throughput-medium.pdf")
if SHOW_FIGURES:
    plt.show(block=BLOCK_ON_SHOW)

# speedup

# set font
plt.rcParams['font.family'] = 'serif'
plt.rcParams['font.serif'] = ['CMU Serif']

fig, ax = plt.subplots(figsize=(5, 5))

ax.plot([1, 2, 3], [gpu_1_time / gpu_1_time, gpu_1_time / gpu_2_time, gpu_1_time / gpu_3_time], 0.2, color='black', marker='.')

plt.xticks(np.arange(1, MAX_GPUS+1, 1))
plt.yticks(np.arange(0, 3.1, 0.5))

plt.xlim(0.5, MAX_GPUS + 0.5)
plt.ylim(0, 3.1)

ax.set_xlabel("Number of GPUs", fontsize=12)
ax.set_ylabel("Speedup", fontsize=12)

# y: size of numbers, x: remove ticks
ax.tick_params(axis='y', labelsize=10)
ax.tick_params(axis='x', length=0)

# legend
# ax.legend()

# grid lines
ax.yaxis.grid(True, linestyle='--', linewidth=0.5)
ax.set_axisbelow(True)

# title
plt.title("Speedup—Medium")

plt.tight_layout()
if SHOW_FIGURES:
    plt.show(block=BLOCK_ON_SHOW)
plt.savefig("../figures/speedup-medium.pdf")

# wait for input to show the figures
if SHOW_FIGURES:
    input()
