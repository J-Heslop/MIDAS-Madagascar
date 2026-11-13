function slimRunOutputs(runDir, varargin)
% slimRunOutputs  --  strip never-read per-agent histories from projection files
%
%   slimRunOutputs('Outputs_SSP2')                     % dry run, reports only
%   slimRunOutputs('Outputs_SSP2', 'Apply', true)      % write _slim files
%   slimRunOutputs('Outputs_SSP2', 'Apply', true, 'DeleteOriginals', true)
%
% RUN THIS ON THE HPC, not after downloading. It exists to make the download
% possible in the first place.
%
% WHAT IS DROPPED AND WHY
% The DROP list below is every output field that no script in
% Write-up/Julia scripts reads. Established by grep on 2026-08-24; chain_audit.jl
% additionally records that MAT.jl cannot parse the agentSummary table at all,
% so it has never been available to the post-processing even in principle.
%
%   agentSummary        table, 11 cell columns, one entry per agent per
%                       timestep -- includes consideredHistory, every
%                       candidate portfolio every agent evaluated every step
%   portfolioHistory    per-agent per-timestep
%   aspirationHistory   per-agent per-timestep
%   distressTrace       per-event trace, written for the local diagnostic runs
%   bufferTrace         per-event trace, same
%
% This is a BLACKLIST, not a whitelist, deliberately. A whitelist silently
% discards any field added later that nobody remembered to list; a blacklist
% fails safe by keeping the unknown.
%
% WHAT THIS COSTS YOU -- READ BEFORE SETTING DeleteOriginals
% agentSummary is the ONLY per-agent record in the output. Aggregate counts
% cannot be disaggregated back to individuals. If any planned figure needs
% agent-level trajectories -- wealth paths, individual move sequences,
% portfolio switching at the household level -- that figure becomes
% impossible once the originals are gone. The aggregate time series retained
% here support location-level and national-level results only.
%
% For that reason DeleteOriginals defaults to false, and even when true this
% keeps the first KeepIntact files of each directory untouched as exemplars,
% so the option of an agent-level figure survives at reduced sample size.

p = inputParser;
addParameter(p, 'Apply', false, @islogical);
addParameter(p, 'DeleteOriginals', false, @islogical);
addParameter(p, 'KeepIntact', 2, @isnumeric);   % full files to preserve
addParameter(p, 'Drop', {'agentSummary', 'portfolioHistory', ...
                         'aspirationHistory', 'distressTrace', 'bufferTrace'});
% SHARDING for SLURM array use. Task j of n handles files j, j+n, j+2n, ...
% Files are independent -- separate reads, separate writes, no shared state --
% so sharding is safe and needs no coordination between tasks. Shard 0 (the
% default) means "this process handles everything", which is what an
% interactive or single-node run wants.
addParameter(p, 'Shard', 0, @isnumeric);
addParameter(p, 'NumShards', 1, @isnumeric);
% MinAgeMinutes guards against slimming a file that MATLAB is still writing.
% A 7 GB -v7.3 save takes minutes, during which the file exists at partial
% size; reading it then would yield a truncated slim copy, and with
% DeleteOriginals the good original would be removed straight afterwards.
% Skipping anything modified recently avoids that window. Set to 30 or more
% when slimming a directory that a running array is still writing to; 0 is
% correct once the campaign for that scenario has finished.
addParameter(p, 'MinAgeMinutes', 0, @isnumeric);
parse(p, varargin{:});
opt = p.Results;

if nargin < 1 || isempty(runDir); runDir = 'Outputs_SSP2'; end
files = dir(fullfile(runDir, 'MC_Run_*.mat'));
files = files(~contains({files.name}, '_slim'));   % never re-slim a slim file
if isempty(files)
    error('slimRunOutputs:none', 'No MC_Run_*.mat in %s', runDir);
end

fprintf('%s: %d files, %.1f GB total\n', runDir, numel(files), ...
        sum([files.bytes]) / 1e9);
fprintf('Dropping: %s\n', strjoin(opt.Drop, ', '));
if ~opt.Apply
    fprintf('\nDRY RUN. Nothing will be written. Pass ''Apply'', true to act.\n');
end
fprintf('Preserving the first %d file(s) intact as agent-level exemplars.\n', ...
        opt.KeepIntact);

% Which global indices this process is responsible for. KeepIntact is applied
% to the GLOBAL index before sharding, so the exemplars are the same files
% whatever the array size -- otherwise the set preserved would silently change
% when NumShards changed.
if opt.Shard > 0
    myIdx = opt.Shard:opt.NumShards:numel(files);
    fprintf('Shard %d of %d: handling %d of %d files.\n', ...
            opt.Shard, opt.NumShards, numel(myIdx), numel(files));
else
    myIdx = 1:numel(files);
end
fprintf('\n');

totalBefore = 0; totalAfter = 0; nDone = 0; nFailed = 0;

for k = myIdx
    src = fullfile(files(k).folder, files(k).name);
    [~, base, ext] = fileparts(files(k).name);
    dst = fullfile(files(k).folder, [base '_slim' ext]);

    if k <= opt.KeepIntact
        fprintf('%3d/%3d  %-46s KEPT INTACT (exemplar)\n', k, numel(files), base);
        continue;
    end
    if exist(dst, 'file')
        fprintf('%3d/%3d  %-46s slim already exists, skipping\n', k, numel(files), base);
        continue;
    end
    if opt.MinAgeMinutes > 0
        ageMin = (now - files(k).datenum) * 24 * 60;
        if ageMin < opt.MinAgeMinutes
            fprintf('%3d/%3d  %-46s MODIFIED %.0f min ago, may still be writing -- skipped\n', ...
                    k, numel(files), base, ageMin);
            continue;
        end
    end

    try
        t0 = tic;
        S = load(src);
        if ~isfield(S, 'output')
            fprintf('%3d/%3d  %-46s NO output field, skipped\n', k, numel(files), base);
            continue;
        end

        input  = S.input; %#ok<NASGU>
        output = S.output;
        present = intersect(opt.Drop, fieldnames(output));
        output = rmfield(output, present);

        % Record what was removed, so a slimmed file is self-documenting and
        % a later reader is not left wondering whether the field was never
        % written or was stripped afterwards.
        output.slimmedFields = present;
        output.slimmedOn     = datestr(now);

        if ~opt.Apply
            % Measure the saving without keeping the file.
            tmp = [tempname '.mat'];
            save(tmp, 'input', 'output', '-v7.3');
            dd = dir(tmp); after = dd.bytes; delete(tmp);
        else
            save(dst, 'input', 'output', '-v7.3');
            dd = dir(dst);
            if isempty(dd) || dd.bytes < 1e4
                error('slimRunOutputs:badWrite', 'Slim file suspiciously small');
            end
            % Verify the retained fields survived the round trip before any
            % deletion is even considered.
            vars = who('-file', dst);
            if ~ismember('output', vars)
                error('slimRunOutputs:noOutput', 'output missing from %s', dst);
            end
            after = dd.bytes;
            if opt.DeleteOriginals
                delete(src);
            end
        end

        totalBefore = totalBefore + files(k).bytes;
        totalAfter  = totalAfter  + after;
        nDone = nDone + 1;
        fprintf('%3d/%3d  %-46s %7.2f GB -> %6.1f MB  (%4.1fx, %.0f s)\n', ...
                k, numel(files), base, files(k).bytes/1e9, after/1e6, ...
                files(k).bytes / max(after, 1), toc(t0));

    catch ME
        nFailed = nFailed + 1;
        fprintf('%3d/%3d  %-46s FAILED: %s\n', k, numel(files), base, ME.message);
    end
end

fprintf('\n%d slimmed, %d failed.\n', nDone, nFailed);
if nDone > 0
    fprintf('%.1f GB -> %.2f GB  (%.0fx reduction)\n', ...
            totalBefore/1e9, totalAfter/1e9, totalBefore / max(totalAfter, 1));
    if ~opt.Apply
        fprintf('\nThat was a DRY RUN -- the originals are untouched.\n');
    elseif ~opt.DeleteOriginals
        fprintf(['\nOriginals kept. Check a slim file opens in Julia, THEN re-run\n' ...
                 'with ''DeleteOriginals'', true to reclaim the quota.\n']);
    end
end
end
