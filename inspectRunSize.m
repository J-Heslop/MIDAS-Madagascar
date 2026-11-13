function inspectRunSize(runFile)
% inspectRunSize  --  where are the 7 GB in a projection output file?
%
%   inspectRunSize('Outputs_SSP2/MC_Run_T001_D001_R1_2026-08-24.mat')
%
% WHY THIS EXISTS
% Projection files are ~7 GB against ~66 MB for calibration runs, roughly a
% 100x increase. Two causes are plausible and they multiply:
%
%   (a) VOLUME. The per-agent per-timestep histories scale as
%       (agents ever created) x timesteps. Projections run 410 timesteps
%       over 100 years with SSP population growth; calibration ran 170 over
%       40 with far fewer births. Perhaps 15-20x on its own.
%
%   (b) FORMAT. Projection files are -v7.3 (HDF5), calibration files were
%       v7. HDF5 gives every cell in a cell array its own dataset and
%       header, so cell-heavy variables inflate several-fold relative to
%       v7's whole-variable compression.
%
% This measures which it is, per field, so the slimming decision is made on
% evidence rather than on the above reasoning being correct.
%
% RUN THIS ON THE HPC. Loading a 7 GB file needs more RAM than a laptop has,
% and the whole point is to avoid transferring it.

if nargin < 1 || isempty(runFile)
    error('inspectRunSize:noFile', 'Pass the path to one MC_Run_*.mat file.');
end

d = dir(runFile);
if isempty(d)
    error('inspectRunSize:missing', 'Not found: %s', runFile);
end
fprintf('File: %s\n', runFile);
fprintf('On disk: %.2f GB\n\n', d.bytes / 1e9);

fprintf('Loading (this may take a few minutes)...\n');
t0 = tic;
S = load(runFile);
fprintf('Loaded in %.1f s\n\n', toc(t0));

if ~isfield(S, 'output')
    fprintf('No ''output'' variable. Present: %s\n', strjoin(fieldnames(S)', ', '));
    return;
end

% ---- in-memory size of every top-level field of output -------------------
% NOTE: this is UNCOMPRESSED size in RAM, which is not the same as bytes on
% disk. It ranks the fields correctly, which is what the decision needs, but
% do not read the GB figures as disk savings -- confirm those by actually
% writing a slimmed file and comparing (slimRunOutputs.m reports both).
o = S.output;
f = fieldnames(o);
bytes = zeros(numel(f), 1);
for k = 1:numel(f)
    v = o.(f{k}); %#ok<NASGU>
    w = whos('v');
    bytes(k) = w.bytes;
end

[~, ord] = sort(bytes, 'descend');
total = sum(bytes);

% Fields no Julia post-processing script reads. Established by grepping the
% Write-up/Julia scripts directory on 2026-08-24: agentSummary is not read by
% any script, and chain_audit.jl states MAT.jl cannot parse it at all.
neverRead = {'agentSummary', 'portfolioHistory', 'aspirationHistory', ...
             'distressTrace', 'bufferTrace'};

fprintf('%-28s %12s %8s  %s\n', 'field', 'MB in RAM', 'share', 'used by Julia?');
fprintf('%s\n', repmat('-', 1, 70));
for k = ord'
    tag = 'yes';
    if ismember(f{k}, neverRead); tag = 'NO -- droppable'; end
    fprintf('%-28s %12.1f %7.1f%%  %s\n', f{k}, bytes(k)/1e6, ...
            100 * bytes(k) / total, tag);
end
fprintf('%s\n', repmat('-', 1, 70));
fprintf('%-28s %12.1f\n\n', 'TOTAL', total/1e6);

droppable = sum(bytes(ismember(f, neverRead)));
fprintf('Droppable (never read by any Julia script): %.1f MB, %.1f%% of the total.\n', ...
        droppable/1e6, 100 * droppable / total);

% ---- agentSummary column breakdown --------------------------------------
% If agentSummary dominates, it is worth knowing which column does, because
% consideredHistory (every candidate portfolio, every agent, every timestep)
% is expected to be most of it and is the least defensible thing to store.
if isfield(o, 'agentSummary') && istable(o.agentSummary)
    A = o.agentSummary;
    cn = A.Properties.VariableNames;
    cb = zeros(numel(cn), 1);
    for k = 1:numel(cn)
        v = A.(cn{k}); %#ok<NASGU>
        w = whos('v');
        cb(k) = w.bytes;
    end
    [~, cord] = sort(cb, 'descend');
    fprintf('\n=== agentSummary columns (%d agents) ===\n', height(A));
    fprintf('%-28s %12s %8s\n', 'column', 'MB in RAM', 'share');
    for k = cord'
        fprintf('%-28s %12.1f %7.1f%%\n', cn{k}, cb(k)/1e6, ...
                100 * cb(k) / max(sum(cb), eps));
    end
end

% ---- shape of what we are keeping ---------------------------------------
% Sanity: the retained aggregate arrays should be small. If any of these is
% itself in the GB range, slimming will not save what we expect.
fprintf('\n=== retained fields: dimensions ===\n');
keepCheck = {'agentCount_all','agentCount_pop','agentCount_ag', ...
             'outMigrations','inMigrations','migrations','migrationMatrix', ...
             'distressMigrations','foodInsecureCount_ag','foodInsecureCount_all', ...
             'utilityHistory','trappedHistory','countAgentsPerLayer','bufferMean'};
for k = 1:numel(keepCheck)
    if isfield(o, keepCheck{k})
        v = o.(keepCheck{k}); %#ok<NASGU>
        w = whos('v');
        fprintf('  %-24s %-20s %8.2f MB\n', keepCheck{k}, ...
                mat2str(size(o.(keepCheck{k}))), w.bytes/1e6);
    else
        fprintf('  %-24s ABSENT\n', keepCheck{k});
    end
end
end
