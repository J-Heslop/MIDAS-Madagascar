% run_slim.m
% Batch entry point for slimRunOutputs under SLURM, mirroring the pattern in
% run_calibration.m: a single-token -batch argument, with configuration read
% from the environment rather than passed inline. See the note at the top of
% run_calibration.m for why an inline multi-line -batch body does not survive
% the module wrapper on Hali.
%
% Environment:
%   SLIM_DIR          directory of MC_Run_*.mat  (required, e.g. Outputs_SSP2)
%   SLIM_APPLY        1 to write files, 0 for a dry run   (default 0)
%   SLIM_DELETE       1 to delete originals after a verified write (default 0)
%   SLIM_KEEP_INTACT  number of agent-level exemplars to leave alone (default 2)
%
% Deliberately defaults to the SAFE setting on every switch. A forgotten
% variable produces a dry run that deletes nothing, rather than an
% irreversible pass over 1.5 TB of results.

fprintf('=== run_slim.m entered at %s ===\n', datestr(now));
fprintf('Working directory: %s\n', pwd);

slimDir = getenv('SLIM_DIR');
if isempty(slimDir)
    error('run_slim:noDir', ...
          'SLIM_DIR not set -- pass --export=ALL,SLIM_DIR=Outputs_SSP2');
end

envFlag = @(name, default) ...
    localEnvFlag(name, default);

doApply  = envFlag('SLIM_APPLY',  false);
doDelete = envFlag('SLIM_DELETE', false);

keepIntact = str2double(getenv('SLIM_KEEP_INTACT'));
if isnan(keepIntact) || keepIntact < 0; keepIntact = 2; end

% Skip files modified within this many minutes -- they may still be being
% written by a running projection task. Set SLIM_MIN_AGE=30 when slimming a
% scenario whose array has not finished.
minAge = str2double(getenv('SLIM_MIN_AGE'));
if isnan(minAge) || minAge < 0; minAge = 0; end

% Deleting originals only makes sense if we are also writing replacements.
% Guard rather than trust the submission line, because the failure mode is
% total and silent.
if doDelete && ~doApply
    error('run_slim:deleteWithoutApply', ...
          'SLIM_DELETE=1 with SLIM_APPLY=0 would delete originals without writing slim files.');
end

shard     = str2double(getenv('SLURM_ARRAY_TASK_ID'));
numShards = str2double(getenv('SLURM_ARRAY_TASK_COUNT'));
if isnan(shard);     shard     = 0; end
if isnan(numShards); numShards = 1; end

fprintf('SLIM_DIR         = %s\n', slimDir);
fprintf('SLIM_APPLY       = %d\n', doApply);
fprintf('SLIM_DELETE      = %d\n', doDelete);
fprintf('SLIM_KEEP_INTACT = %d\n', keepIntact);
fprintf('SLIM_MIN_AGE     = %d min\n', minAge);
fprintf('shard %d of %d\n\n', shard, numShards);

slimRunOutputs(slimDir, ...
    'Apply',           doApply, ...
    'DeleteOriginals', doDelete, ...
    'KeepIntact',      keepIntact, ...
    'MinAgeMinutes',   minAge, ...
    'Shard',           shard, ...
    'NumShards',       numShards);

fprintf('=== run_slim.m completed at %s ===\n', datestr(now));

function tf = localEnvFlag(name, default)
    raw = getenv(name);
    if isempty(raw)
        tf = default;
        return;
    end
    v = str2double(raw);
    if isnan(v)
        tf = any(strcmpi(raw, {'true', 'yes', 'on'}));
    else
        tf = v ~= 0;
    end
end
