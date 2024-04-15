#!/usr/bin/env python3

import matplotlib.pyplot as plt
import matplotlib.lines as lines
import numpy as np
import statistics

# constants
RUNS = 3
MAX_THREADS = 16

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

data = read_my_file("all-runs.out")
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
BLOCK_ON_SHOW = True

# runtime

# set font
plt.rcParams['font.family'] = 'serif'
plt.rcParams['font.serif'] = ['CMU Serif']

fig, ax = plt.subplots(figsize=(5, 5))

ax.bar(1, baseline_time, 0.2, label='Original', color='red')
ax.bar(2, gpu_1_time, 0.2, label='1 GPU', color='blue')
ax.bar(3, gpu_2_time, 0.2, label='2 GPU', color='blue')
ax.bar(4, gpu_3_time, 0.2, label='3 GPU', color='blue')

# plt.xticks(x + width / 2, ['4 Proc.', '8 Proc.', '12 Proc.', '16 Proc.'])
plt.yticks(np.arange(0, 1501, 100))

ax.set_xlabel("Program Version", fontsize=12)
ax.set_ylabel("Runtime (s)", fontsize=12)

# y: size of numbers, x: remove ticks
ax.tick_params(axis='y', labelsize=10)
ax.tick_params(axis='x', length=0, labelsize=0)

# legend
ax.legend()

# grid lines
ax.yaxis.grid(True, linestyle='--', linewidth=0.5)
ax.set_axisbelow(True)

# title
plt.title("Homo sapiens (233 MB)-Otolemur Garnettii (2.4 GB)")

plt.tight_layout()
plt.savefig("runtime.pdf")
if SHOW_FIGURES:
    plt.show(block=BLOCK_ON_SHOW)

quit()

#
# CODE FOR ANDREW'S GC PROGRAMMING FIGURES
#

# thread runtime

# set font
plt.rcParams['font.family'] = 'serif'
plt.rcParams['font.serif'] = ['CMU Serif']

fig, ax = plt.subplots(figsize=(5, 5))

ax.plot(thd_count, thd_runtime, 0.2, color='black', marker='.')

plt.xticks(np.arange(1, MAX_THREADS+1, 1))
plt.yticks(np.arange(0, 7.1, 0.5))

plt.xlim(0.5, MAX_THREADS + 0.5)
plt.ylim(0, 7)

ax.set_xlabel("Number of Threads", fontsize=12)
ax.set_ylabel("Runtime (s)", fontsize=12)

# y: size of numbers, x: remove ticks
ax.tick_params(axis='y', labelsize=10)
ax.tick_params(axis='x', length=0)

# legend
# ax.legend()

# grid lines
ax.yaxis.grid(True, linestyle='--', linewidth=0.5)
ax.set_axisbelow(True)

plt.tight_layout()
if SHOW_FIGURES:
    plt.show(block=False)
plt.savefig("thd-runtime.pdf")


# thread energy

# set font
plt.rcParams['font.family'] = 'serif'
plt.rcParams['font.serif'] = ['CMU Serif']

fig, ax = plt.subplots(figsize=(5, 5))

ax.plot(thd_count, thd_energy, 0.2, color='black', marker='.')

plt.xticks(np.arange(1, MAX_THREADS+1, 1))
plt.yticks(np.arange(0, 161, 10))

plt.xlim(0.5, MAX_THREADS + 0.5)
plt.ylim(0, 160)

ax.set_xlabel("Number of Threads", fontsize=12)
ax.set_ylabel("Energy (Ws)", fontsize=12)

# y: size of numbers, x: remove ticks
ax.tick_params(axis='y', labelsize=10)
ax.tick_params(axis='x', length=0)

# legend
# ax.legend()

# grid lines
ax.yaxis.grid(True, linestyle='--', linewidth=0.5)
ax.set_axisbelow(True)

plt.tight_layout()
if SHOW_FIGURES:
    plt.show(block=False)
plt.savefig("thd-energy.pdf")


# wait for input to show the figures
if SHOW_FIGURES:
    input()
