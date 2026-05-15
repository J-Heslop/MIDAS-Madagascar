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
% Target total runs across the whole array. Edit here when you change
% the campaign size (and update --array=1-N%K in submit_calibration.sh).
numTotalRuns = 1000;
if arrayId == 0
    runsPerTask = numTotalRuns;
else
    runsPerTask = ceil(numTotalRuns / arrayCnt);
end
fprintf('numTotalRuns = %d, runsPerTask = %d\n', numTotalRuns, runsPerTask);

% ----- Sanity check -----
if exist('runMIDASExperiment_parallel.m', 'file') ~= 2
    error('run_calibration:missingRunner', ...
          'runMIDASExperiment_parallel.m not found in %s', pwd);
end

% ----- Run -----
% addpath / parpool / RNG seeding are handled inside runMIDASExperiment_parallel.
runMIDASExperiment_parallel(nWorkers, arrayId, runsPerTask);

fprintf('=== run_calibration.m completed at %s ===\n', datestr(now));
