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
nRealisations = 1;

% ENV OVERRIDES. The drought-scale sweep needs a much smaller campaign than a
% calibration round -- 16 draws at one pinned scale value, not 1000 across the
% whole space -- and editing these numbers between submissions is not safe:
% %N throttling means tasks start over many hours and each reads this file as
% it begins, so an edit would silently reassign any task that had not yet
% started. Passing them in the environment keeps every submission
% self-describing and lets sweep points run concurrently with each other.
% Unset leaves the values above untouched.
envDraws = str2double(getenv('NUM_DRAWS'));
if ~isnan(envDraws) && envDraws >= 1
    numTotalDraws = round(envDraws);
    fprintf('numTotalDraws overridden to %d by NUM_DRAWS.\n', numTotalDraws);
end
envReal = str2double(getenv('N_REALISATIONS'));
if ~isnan(envReal) && envReal >= 1
    nRealisations = round(envReal);
    fprintf('nRealisations overridden to %d by N_REALISATIONS.\n', nRealisations);
end

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

% ----- Distress overlay arm (0-7) -----
% Selects which trigger variant runMIDASExperiment_parallel uses and
% which output folder it writes to. Override by setting DISTRESS_ARM
% in the SLURM submission environment, e.g.:
%     sbatch --export=ALL,DISTRESS_ARM=2 HPC/submit_calibration_batch.sh
% 0 = TRUE BASELINE: distress overlay fully disabled.
% 1-4 = Variants A-D. 5 = Variant E (income-shock trigger).
% 6 = Variant F (income shock AND unmet post-buffer shortfall; auto-enables
% the buffer). 7 = ORACLE (exogenous agYF-conditioned trigger; DIAGNOSTIC
% upper bound only -- do not use for production/projection runs).
% LOCAL_DEMAND_COUPLING (0-1), POSITIVE_SPEI_SCALE (0-1), BUFFER (0/1) and
% LIVELIHOOD_ATTACH (0/1) are read separately inside the runner.
%
% Defaults to 0 (clean baseline) if unset. NB: this default used to be 1
% (Variant A), which meant every run submitted without DISTRESS_ARM --
% including intended baselines and all EXPECTATION_ARM runs -- silently
% had the Variant A distress overlay ACTIVE.
distressArm = str2double(getenv('DISTRESS_ARM'));
if isnan(distressArm) || ~ismember(distressArm, [0 1 2 3 4 5 6 7])
    distressArm = 0;
    fprintf('DISTRESS_ARM env var unset or invalid; defaulting to 0 (overlay OFF, clean baseline).\n');
else
    fprintf('DISTRESS_ARM env var = %d (passed through to runner).\n', distressArm);
end

% ----- Expectation-formation arm (0-4) -----
% Selects which expectation mechanism formExpectation uses (see
% formExpectation.m). Override with EXPECTATION_ARM in the SLURM
% submission environment, e.g.:
%   sbatch --export=ALL,EXPECTATION_ARM=1 HPC/submit_calibration_batch.sh
% Defaults to 0 (baseline MIDAS sampling) if unset.
% FALLBACK CORRECTED 2026-09-04. This used to reset to 0 on an unset OR
% invalid variable, silently and identically. Two problems with that.
%
% A hard-coded 0 here overrides whatever readParameters.m declares, so
% changing the model's default expectation rule in the one place a reader
% would look for it had NO EFFECT on a campaign -- the same class of failure
% as LOCAL_DEMAND_COUPLING and DISTRESS_ARM, both already corrected above.
% Every campaign to date therefore ran arm 0: uniform sampling across the
% agent's entire history, with no recency weighting. Under that rule a
% drought in the current year enters an agent's expectation with probability
% of order a few per cent, so the comparative migration channel is close to
% blind to recent conditions by construction, while the distress channel --
% which reads realised income and wealth directly -- is not.
%
% And a typo silently produced a DIFFERENT MODEL rather than a failed job.
% An out-of-range value is now a hard error.
% PATH FIRST (2026-09-05). runMIDASExperiment_parallel does its own addpath,
% but not until it is called at the bottom of this file -- and resolving the
% expectation arm below needs readParameters NOW. Under `matlab -batch` the
% source folders are not on the path at this point, so readParameters was
% undefined, the call threw, and the guard below reported a stale cluster copy
% for what was actually a path problem. It went unnoticed locally because an
% interactive session already has the folders on the path from earlier runs.
%
% Adding them here is harmless: addpath is idempotent, and
% runMIDASExperiment_parallel re-adds them (and pushes them to the workers)
% regardless.
for pDir = {'./Override_Core_MIDAS_Code', './Application_Specific_MIDAS_Code', ...
            './Core_MIDAS_Code'}
    if exist(pDir{1}, 'dir')
        addpath(pDir{1});
    end
end
if exist('readParameters', 'file') ~= 2
    error('run_calibration:readParametersNotOnPath', ...
        ['readParameters is not on the MATLAB path from %s. Expected it in ' ...
         './Application_Specific_MIDAS_Code. Check the working directory: ' ...
         'the submit script cds to $SLURM_SUBMIT_DIR/../MIDAS.'], pwd);
end

% DISTINGUISH "readParameters says 0" FROM "readParameters FAILED" (2026-09-05).
% This catch previously swallowed any exception and left mpDefaults empty,
% which fell through to defaultArm = 0 and then raised the stale-copy error
% below -- blaming a stale file for what might have been a broken one. The
% two need different fixes, so report which actually happened.
mpDefaults = []; readParamsErr = [];
try
    [~, mpDefaults] = readParameters([]);
catch readParamsErr %#ok<CTCH>
    mpDefaults = [];
end
if ~isempty(readParamsErr)
    error('run_calibration:readParametersFailed', ...
        ['readParameters([]) THREW rather than returning defaults, so the ' ...
         'expectation arm could not be resolved. This is a broken or ' ...
         'incompatible readParameters.m, not a stale one.\n\n' ...
         'Original error (%s):\n  %s\n\nAt: %s line %d'], ...
        readParamsErr.identifier, readParamsErr.message, ...
        readParamsErr.stack(1).name, readParamsErr.stack(1).line);
end
if isempty(mpDefaults) || ~isfield(mpDefaults, 'expectationArm')
    error('run_calibration:noExpectationArmField', ...
        ['readParameters returned defaults with no expectationArm field. ' ...
         'The cluster copy predates the expectation-arm work entirely.']);
end
defaultArm = 0;
if ~isempty(mpDefaults) && isfield(mpDefaults, 'expectationArm')
    defaultArm = mpDefaults.expectationArm;
end

rawExpArm = getenv('EXPECTATION_ARM');
if isempty(rawExpArm)
    expectationArm = defaultArm;
    fprintf(['EXPECTATION_ARM not set -- using the readParameters default, ' ...
             'arm %d.\n'], expectationArm);
else
    expectationArm = str2double(rawExpArm);
    if isnan(expectationArm) || ~ismember(expectationArm, [0 1 2 3 4])
        error('run_calibration:badExpectationArm', ...
              ['EXPECTATION_ARM = "%s" is not one of 0-4. Fix the submission ' ...
               'script. Refusing to fall back silently, because the old ' ...
               'behaviour was to reset to arm 0 -- a different expectation ' ...
               'rule -- without warning.'], rawExpArm);
    end
    fprintf('EXPECTATION_ARM = %d (from environment).\n', expectationArm);
end
% ARM 0 IS NOW AN ERROR UNLESS ASKED FOR EXPLICITLY (2026-09-05).
%
% This was a warning. A warning is not enough: on 2026-09-04 the drought-scale
% sweep ran all six points under arm 0 because readParameters.m had not been
% copied to the cluster alongside run_calibration.m, the warning scrolled past
% in a log nobody reads until afterwards, and 96 runs measured the drought
% scale factor under a decision rule that cannot see recent drought.
%
% Arm 0 samples an agent's whole history uniformly, so the weight on the
% current year is 1/(cycles elapsed) -- about 1% by 2085. It is no longer the
% intended model. Reaching it by ACCIDENT, which is what a stale
% readParameters.m does, must fail the job immediately rather than quietly
% producing a campaign that has to be thrown away.
%
% Deliberate use is still available: export EXPECTATION_ARM=0.
if expectationArm == 0 && isempty(rawExpArm)
    error('run_calibration:staleExpectationDefault', ...
        ['expectationArm resolved to 0 from the readParameters.m default, ' ...
         'which is almost certainly a STALE COPY -- the intended default is ' ...
         'arm 4 (adaptive expectations with recency weighting).\n\n' ...
         'Check the cluster copy:\n' ...
         '    grep -n "expectationArm = " Application_Specific_MIDAS_Code/readParameters.m\n\n' ...
         'Under arm 0 agents sample their whole history uniformly, so recent ' ...
         'drought is nearly invisible to the comparative migration decision ' ...
         'and any drought-sensitivity result is close to guaranteed null.\n\n' ...
         'To run arm 0 deliberately, export EXPECTATION_ARM=0.']);
elseif expectationArm == 0
    warning('run_calibration:baselineExpectation', ...
        ['expectationArm = 0 requested EXPLICITLY via EXPECTATION_ARM. ' ...
         'Agents sample their whole history uniformly, with no recency ' ...
         'weighting. This is the legacy baseline, not the current model.']);
end

% ----- Run -----
% addpath / parpool / RNG seeding are handled inside runMIDASExperiment_parallel.
runMIDASExperiment_parallel(nWorkers, arrayId, drawsPerTask, nRealisations, distressArm, expectationArm);

fprintf('=== run_calibration.m completed at %s ===\n', datestr(now));
