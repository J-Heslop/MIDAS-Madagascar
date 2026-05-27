% run_calibration.m
% Batch entry point for SLURM-launched MIDAS calibration on UEA Hali.
%
% Invoked from HPC/submit_calibration.sh as:
%     matlab -nodisplay -nosplash -batch "run_calibration"
%
% Why this file exists:
%   The previous SLURM script passed the calibration body inline as a
%   multi-line -batch '...' argument. On Hali (MATLAB 2024b module load),
%   that argument was being stripped before reaching the matlab binary,
%   leaving MATLAB to launch with no command. Job 2576195 (29 Apr 2026)
%   ran for ~2 h producing no output and the .out log contained:
%       [Warning: No MATLAB command specified for -r command line argument.]
%   Putting the batch body in its own .m file (single-token -batch
%   argument) sidesteps the wrapper's argument handling.
%
% Array-task handling:
%   When launched as part of a SLURM array, this script reads
%   SLURM_ARRAY_TASK_ID and SLURM_ARRAY_TASK_COUNT to seed the RNG with
%   the task ID (so each task draws disjoint, reproducible parameter
%   samples) and to compute its share of numTotalRuns. When run outside
%   an array context (taskId == 0), it falls back to a single-shot
%   calibration and uses the full numTotalRuns.
%
% Expected cwd: the MIDAS project root, set by the SLURM script via
%     cd "$SLURM_SUBMIT_DIR/../MIDAS"
% Required files in cwd: runMIDASExperiment_parallel.m and the three
% MIDAS source directories it addpath's.

fprintf('=== run_calibration.m entered at %s ===\n', datestr(now));
fprintf('Working directory: %s\n', pwd);

% ----- Worker count from SLURM (default 20) -----
nWorkers = str2double(getenv('SLURM_CPUS_PER_TASK'));
if isnan(nWorkers) || nWorkers < 1
    nWorkers = 20;
end
fprintf('Using %d parallel workers (from SLURM_CPUS_PER_TASK).\n', nWorkers);

% ----- Array context -----
arrayId  = str2double(getenv('SLURM_ARRAY_TASK_ID'));
arrayCnt = str2double(getenv('SLURM_ARRAY_TASK_COUNT'));
arrayJob = getenv('SLURM_ARRAY_JOB_ID');
if isnan(arrayId);  arrayId  = 0; end   % 0 = non-array single-shot run
if isnan(arrayCnt); arrayCnt = 1; end
fprintf('SLURM_ARRAY_JOB_ID  = %s\n', arrayJob);
fprintf('SLURM_ARRAY_TASK_ID = %d (of %d tasks)\n', arrayId, arrayCnt);

% ----- Calibration sizing -----
% Two knobs drive the campaign size:
%   numTotalDraws  = number of UNIQUE parameter combinations sampled across
%                    the array. Each draw produces nRealisations runs.
%   nRealisations  = how many times each parameter set is replicated with
%                    a different RNG seed. buildNextRound.m averages metric
%                    scores across these realisations before scoring/narrowing,
%                    so seed-driven noise in any single run cancels out.
%
% Multi-realisation (nRealisations >= 2) becomes important as the parameter
% space narrows in later rounds, when parameter sets are close to each other
% and individual-run noise can otherwise dominate the score. From round 4
% onward we use nRealisations = 3.
%
% Total runs across the array = numTotalDraws * nRealisations.
%
% IMPORTANT wall-clock constraint: each task does
%     drawsPerTask * nRealisations parfor iterations
% on a fixed pool of (typically 20) workers. If that product exceeds the
% worker count, the parfor will queue extra iterations sequentially,
% potentially doubling wall-clock and risking the 12-hour SLURM budget.
% Sizing rule of thumb:
%     numTotalDraws / arrayCnt * nRealisations  <=  SLURM_CPUS_PER_TASK
% Defaults below: 300 / 50 * 3 = 18 iterations per task on 20 workers.
%
% Edit both numbers here when changing the campaign size, and update
% --array=1-N%K in submit_calibration.sh accordingly.
numTotalDraws = 1000;
nRealisations = 3;

if arrayId == 0
    drawsPerTask = numTotalDraws;
else
    drawsPerTask = ceil(numTotalDraws / arrayCnt);
end
fprintf(['numTotalDraws = %d, nRealisations = %d, drawsPerTask = %d, ' ...
         'total iterations this task = %d\n'], ...
         numTotalDraws, nRealisations, drawsPerTask, drawsPerTask * nRealisations);

% ----- Sanity check -----
if exist('runMIDASExperiment_parallel.m', 'file') ~= 2
    error('run_calibration:missingRunner', ...
          'runMIDASExperiment_parallel.m not found in %s', pwd);
end

% ----- Run -----
% addpath / parpool / RNG seeding are handled inside runMIDASExperiment_parallel.
runMIDASExperiment_parallel(nWorkers, arrayId, drawsPerTask, nRealisations);

fprintf('=== run_calibration.m completed at %s ===\n', datestr(now));
