# MIDAS Madagascar – HPC Calibration Guide (UEA Ada)

## Resource Estimates

### Per-run memory
| Component | Size |
|-----------|------|
| Agent array (5000 agents × ~40 fields) | ~25 MB |
| Migration matrix (22×22×1040 timesteps) | ~4 MB |
| Utility layers / map data | ~50 MB |
| MATLAB overhead per worker | ~200 MB |
| **Total per worker (safe estimate)** | **~500 MB** |

### Job sizing recommendations

| Scenario | Workers | RAM request | Walltime | Runs per job |
|----------|---------|-------------|----------|--------------|
| Test / debug | 1 | 8 GB | 2:00:00 | 5 |
| Round 1 calibration | 20 | 120 GB | 12:00:00 | 200 |
| Round 2+ calibration | 20 | 120 GB | 8:00:00 | 200 |

*Use `--partition=compute-64-512` for large-memory jobs on Ada.*

### Timing estimate
With 3,000-6,000 agents over 1985–2050 (260 years × 4 timesteps/year = 1040 steps):
- ~5-15 minutes per run on a single core
- 200 runs / 20 parallel workers = ~10 runs per worker = ~100-150 min walltime
- Request 12 hours for safety

---

## Quick-start: First calibration round

```bash
# 1. SSH to Ada
ssh f.heslop@ada.uea.ac.uk

# 2. Transfer files (from local machine)
rsync -avz --exclude='Outputs/*.mat' \
  "C:/Users/Jack/OneDrive - University of East Anglia/ISF - Migration modelling consultancy/MIDAS-Madagascar/" \
  f.heslop@ada.uea.ac.uk:~/MIDAS-Madagascar/

# 3. Run setup
cd ~/MIDAS-Madagascar
bash HPC/setup_hpc.sh

# 4. Check available MATLAB versions
module avail matlab

# 5. Edit submit_calibration.sh if needed (update MATLAB version, partition)
nano HPC/submit_calibration.sh

# 6. Submit
sbatch HPC/submit_calibration.sh

# 7. Monitor
squeue -u f.heslop
tail -f logs/midas_calib_<JOBID>.out
```

---

## Calibration workflow

```
Round 1: runMIDASExperiment_parallel.m (200 runs, wide uniform priors)
    ↓
    Outputs/*.mat   (200 result files)
    ↓
Round 1 eval: cd "Calibration Testing" && matlab -r "buildNextRound; exit"
    ↓
    updatedMCParams.mat  (narrowed bounds, top 5% of runs)
    ↓
Round 2: runMIDASExperiment_parallel.m (200 runs, narrow priors)
    ↓
    [repeat 3-5 rounds until r² stabilises]
```

### Running buildNextRound on Ada
```bash
cd ~/MIDAS-Madagascar/Calibration\ Testing
matlab -nodisplay -nosplash -r "buildNextRound; exit"
```
Copy `updatedMCParams.mat` back to the MIDAS root before re-submitting.

---

## File transfer commands

```bash
# Transfer files TO Ada
rsync -avz --progress \
  "C:/Users/Jack/OneDrive - University of East Anglia/ISF - Migration modelling consultancy/MIDAS-Madagascar/" \
  f.heslop@ada.uea.ac.uk:~/MIDAS-Madagascar/

# Transfer results FROM Ada (after calibration run)
rsync -avz --include='*.mat' --include='*/' --exclude='*' \
  f.heslop@ada.uea.ac.uk:~/MIDAS-Madagascar/Outputs/ \
  "C:/Users/Jack/OneDrive - .../MIDAS-Madagascar/Outputs/"

# Transfer just the updated calibration file
scp f.heslop@ada.uea.ac.uk:~/MIDAS-Madagascar/Calibration\ Testing/updatedMCParams.mat \
  "C:/Users/Jack/OneDrive - .../MIDAS-Madagascar/"
```

---

## UEA Ada partitions

| Partition | Max cores | Max RAM | Max walltime | Notes |
|-----------|-----------|---------|--------------|-------|
| `compute-24-96` | 24 | 96 GB | 72h | Standard compute |
| `compute-64-512` | 64 | 512 GB | 72h | High-memory jobs |
| `short-24-96` | 24 | 96 GB | 4h | Fast turnaround |

For MIDAS calibration, `compute-64-512` is recommended (need >96 GB for 20 workers).

---

## Troubleshooting

**MATLAB licence errors:** UEA has a limited MATLAB parallel licence pool. If `parpool` fails, reduce workers or contact IT.

**Out of memory:** Reduce `nWorkers` in `submit_calibration.sh` or reduce `modelParameters.numAgents` range.

**Jobs stuck in queue:** Check partition availability with `sinfo`. During busy periods use `short-24-96` with fewer workers.

**Runs taking too long:** Reduce `modelRuns` in `runMIDASExperiment_parallel.m` for test runs, or reduce `numAgents` lower bound.
