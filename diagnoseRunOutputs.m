function diagnoseRunOutputs(runDir)
% diagnoseRunOutputs  --  why are most MC_Run files ~3 kB instead of ~66 MB?
%
%   diagnoseRunOutputs('Outputs_SSP2')
%
% WHAT A SMALL FILE MEANS
% saveToFile is called ONLY after midasMainLoop returns (runMIDASExperiment_
% parallel.m:721); a thrown error is caught and NOTHING is written. So a small
% MC_Run file is not a crash and not a partial write -- the run completed and
% produced a nearly-empty result. MATLAB's save compresses, so arrays that are
% all zeros collapse to a few kB. A 3 kB file is consistent with a simulation
% that ran to completion with no agents, no migrations, or both.
%
% Since some runs succeeded and most did not, the cause is almost certainly
% PARAMETRIC. This compares the sampled inputs of the good runs against the
% bad ones and reports which parameters separate them, which is faster than
% reasoning about the model.

if nargin < 1 || isempty(runDir); runDir = 'Outputs_SSP2'; end
files = dir(fullfile(runDir, 'MC_Run_*.mat'));
if isempty(files)
    error('diagnoseRunOutputs:none', 'No MC_Run_*.mat in %s', runDir);
end

sz = [files.bytes]' / 1e6;
fprintf('%d files. Size (MB): min %.3f, median %.3f, max %.2f\n', ...
        numel(files), min(sz), median(sz), max(sz));

% Split on an order-of-magnitude gap rather than a fixed threshold.
big = sz > max(sz) / 10;
fprintf('  %d large (>%.1f MB), %d small\n\n', sum(big), max(sz)/10, sum(~big));
if ~any(big)
    warning('No large files at all -- every run is degenerate.');
end

% ---- what is actually inside a small file -----------------------------
iSmall = find(~big, 1);
if ~isempty(iSmall)
    f = fullfile(files(iSmall).folder, files(iSmall).name);
    fprintf('=== CONTENTS OF A SMALL FILE: %s ===\n', files(iSmall).name);
    S = load(f);
    if ~isfield(S, 'output')
        fprintf('  NO output variable -- only: %s\n', strjoin(fieldnames(S)', ', '));
    else
        o = S.output;
        chk = {'agentCount_all','agentCount_pop','agentCount_ag','migrations', ...
               'migrationMatrix','outMigrations','countAgentsPerLayer','agentSummary'};
        for k = 1:numel(chk)
            if ~isfield(o, chk{k})
                fprintf('  %-22s ABSENT\n', chk{k});
            else
                v = o.(chk{k});
                fprintf('  %-22s size %-18s sum %.4g\n', chk{k}, ...
                        mat2str(size(v)), sum(double(v(:)), 'omitnan'));
            end
        end
        % The decisive question: did the population survive?
        if isfield(o, 'agentCount_all')
            tot = sum(double(o.agentCount_all(:)));
            if tot == 0
                fprintf(['\n  POPULATION IS ZERO across every year. The run executed but\n' ...
                         '  contained no counted agents -- look at initialisation and the\n' ...
                         '  working-age gate before anything else.\n']);
            end
        end
        % Horizon check: 2085 runs should be 410 timesteps / 100 years.
        if isfield(o, 'outMigrations')
            fprintf('\n  timesteps (outMigrations dim 2): %d   (expect 410 for endYear 2085)\n', ...
                    size(o.outMigrations, 2));
        end
        if isfield(o, 'agentCount_all')
            fprintf('  years (agentCount_all dim 2):    %d   (expect ~100)\n', ...
                    size(o.agentCount_all, 2));
        end
    end
end

% ---- which parameters separate good runs from bad ----------------------
fprintf('\n=== PARAMETERS: GOOD vs DEGENERATE RUNS ===\n');
names = {}; goodV = []; badV = [];
for k = 1:numel(files)
    S = load(fullfile(files(k).folder, files(k).name), 'input');
    if ~isfield(S, 'input'); continue; end
    inp = S.input;
    if istable(inp)
        nm = inp.parameterNames; vv = inp.parameterValues;
    elseif isstruct(inp) && isfield(inp, 'parameterNames')
        nm = inp.parameterNames; vv = inp.parameterValues;
    else
        continue;
    end
    nm = string(nm);
    if isempty(names); names = nm; end
    if numel(nm) ~= numel(names); continue; end
    if big(k); goodV(end+1, :) = vv(:)'; else; badV(end+1, :) = vv(:)'; end %#ok<AGROW>
end

if isempty(goodV) || isempty(badV)
    fprintf('  Need at least one of each to compare (good %d, bad %d).\n', ...
            size(goodV, 1), size(badV, 1));
    return;
end

% Rank by separation: how far the good-run mean sits from the bad-run
% distribution, in bad-run standard deviations. With few good runs this is
% indicative, not a test -- it points at what to look at.
sep = zeros(numel(names), 1);
for j = 1:numel(names)
    s = std(badV(:, j));
    if s <= 0 || isnan(s); sep(j) = 0; else; sep(j) = abs(mean(goodV(:, j)) - mean(badV(:, j))) / s; end
end
[~, ord] = sort(sep, 'descend');
fprintf('%-46s %10s %10s %8s\n', 'parameter', 'good mean', 'bad mean', 'sep(SD)');
for j = ord(1:min(12, numel(ord)))'
    fprintf('%-46s %10.4g %10.4g %8.2f\n', names(j), ...
            mean(goodV(:, j)), mean(badV(:, j)), sep(j));
end
fprintf(['\nA parameter near the top with a large separation is the likely cause.\n' ...
         'Check whether the good runs sit at one end of its sampled range.\n']);
end
